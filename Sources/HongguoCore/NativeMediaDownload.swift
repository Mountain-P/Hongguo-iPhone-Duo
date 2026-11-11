// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Darwin

protocol NativeMediaDownloading: Sendable {
    func download(source: NativeMediaSource, destination: URL, maximumBytes: Int64) async throws
}

protocol NativeOfflineMediaDownloading: Sendable {
    func downloadOffline(source: NativeMediaSource, destination: URL, maximumBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws
}

struct NativeMediaHTTPDownload: NativeMediaDownloading, NativeOfflineMediaDownloading {
    let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .ephemeral) { self.configuration = configuration }

    func download(source: NativeMediaSource, destination: URL, maximumBytes: Int64) async throws {
        try await NativeMediaTransfer(source: source, destination: destination, maximumBytes: maximumBytes,
                                      configuration: configuration).run()
    }

    func downloadOffline(source: NativeMediaSource, destination: URL, maximumBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try await NativeMediaTransfer(source: source, destination: destination, maximumBytes: maximumBytes,
                                      configuration: configuration, offlineProgress: progress).run()
    }
}

/// Stages only an authorized clear rendition. The caller owns the completed staging URL.
struct NativeOfflineFile: Sendable {
    private let destination: URL
    private let workspace: URL
    private let staging: URL
    private let maximumBytes: Int64

    init(destination: URL, maximumBytes: Int64) throws {
        guard maximumBytes > 0 else { throw NativeMediaError.tooLarge }
        guard destination.isFileURL, destination.user == nil, destination.password == nil,
              destination.host == nil || destination.host == "localhost",
              destination.query == nil, destination.fragment == nil, !destination.hasDirectoryPath,
              !destination.path.contains("\0") else { throw NativeMediaError.storage }
        let directory = destination.deletingLastPathComponent()
        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory else { throw NativeMediaError.storage }
        var info = stat()
        guard lstat(destination.path, &info) != 0, errno == ENOENT else { throw NativeMediaError.storage }
        self.destination = destination
        self.workspace = directory.appendingPathComponent(UUID().uuidString + ".offline-part", isDirectory: true)
        self.staging = workspace.appendingPathComponent("media")
        self.maximumBytes = min(maximumBytes, Int64(NativeMediaStore.maximumBytes))
    }

    func write(source: NativeMediaSource, downloader: any NativeOfflineMediaDownloading,
               progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws {
        try Task.checkCancellation()
        try NativeMediaPolicy.validate(source)
        guard source.contentKey == nil else { throw NativeSourceError(code: "OFFLINE_CLEAR_UNAVAILABLE") }

        guard mkdir(workspace.path, S_IRWXU) == 0 else { throw NativeMediaError.storage }
        defer {
            _ = Darwin.unlink(staging.path)
            _ = Darwin.rmdir(workspace.path)
        }
        let updates = AsyncStream<(Int64, Int64?)>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observer = Task {
            for await (received, expected) in updates.stream {
                guard !Task.isCancelled else { break }
                await progress(received, expected)
            }
        }
        do {
            try await withTaskCancellationHandler {
                try await downloader.downloadOffline(source: source, destination: staging, maximumBytes: maximumBytes) {
                    _ = updates.continuation.yield(($0, $1))
                }
                updates.continuation.finish()
                await observer.value
                try Task.checkCancellation()
            } onCancel: { observer.cancel() }
        } catch {
            updates.continuation.finish()
            observer.cancel()
            await observer.value
            if Task.isCancelled { throw CancellationError() }
            if let safe = error as? NativeMediaError { throw safe }
            if let safe = error as? CatalogError { throw safe }
            if error is CancellationError { throw CancellationError() }
            throw NativeMediaError.storage
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: staging.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular,
              let size = attributes?[.size] as? NSNumber, size.int64Value > 0 else { throw NativeMediaError.invalidResponse }
        guard size.int64Value <= maximumBytes else { throw NativeMediaError.tooLarge }
        guard let data = try? Data(contentsOf: staging, options: .mappedIfSafe), Int64(data.count) == size.int64Value else {
            throw NativeMediaError.storage
        }
        try NativeMP4.validateOfflineClear(data: data, codec: source.codec)
        try Task.checkCancellation()
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw NativeMediaError.storage }
    }
}

/// A transfer has one serial queue for URLSession callbacks, cancellation, and file writes.
/// Response bodies are streamed to a file and never buffered as a whole by URLSession.
private final class NativeMediaTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: NativeMediaSource
    private let destination: URL
    private let maximumBytes: Int64
    private let configuration: URLSessionConfiguration
    private let offlineProgress: (@Sendable (Int64, Int64?) -> Void)?
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.native-download")
    private var continuation: CheckedContinuation<Void, any Error>?
    private var task: URLSessionDataTask?
    private var handle: FileHandle?
    private var bytes: Int64 = 0
    private var expectedBytes: Int64?
    private var finished = false
    private var cancelled = false
    private var redirects = 0
    private lazy var session: URLSession = {
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 2
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }()

    init(source: NativeMediaSource, destination: URL, maximumBytes: Int64,
         configuration: URLSessionConfiguration,
         offlineProgress: (@Sendable (Int64, Int64?) -> Void)? = nil) {
        self.source = source; self.destination = destination; self.maximumBytes = maximumBytes
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.offlineProgress = offlineProgress
        super.init()
    }

    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async { [self] in
                    self.continuation = continuation
                    if cancelled { finish(CancellationError()); return }
                    do {
                        let descriptor = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
                        guard descriptor >= 0 else { throw NativeMediaError.storage }
                        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                        var request = URLRequest(url: source.url)
                        request.setValue(source.userAgent, forHTTPHeaderField: "User-Agent")
                        request.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
                        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                        task = session.dataTask(with: request)
                        task?.resume()
                    } catch { finish(NativeMediaError.storage) }
                }
            }
        } onCancel: {
            self.queue.async { [self] in
                cancelled = true
                if continuation != nil { finish(CancellationError()) }
            }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard !finished, let http = response as? HTTPURLResponse, let url = http.url, NativeMediaPolicy.allows(url) else {
            completionHandler(.cancel); finish(NativeMediaError.invalidResponse); return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            completionHandler(.cancel)
            if http.statusCode == 401 { finish(CatalogError.unauthorized) }
            else if http.statusCode == 403 { finish(CatalogError.httpStatus(403)) }
            else { finish(NativeMediaError.httpStatus(http.statusCode)) }
            return
        }
        let contentType = http.mimeType?.lowercased() ?? ""
        guard contentType != "text/html", contentType != "application/json", !contentType.hasSuffix("+json") else {
            completionHandler(.cancel); finish(NativeMediaError.invalidResponse); return
        }
        if offlineProgress != nil {
            let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased() ?? "identity"
            guard encoding == "identity", ["video/mp4", "application/mp4", "application/octet-stream"].contains(contentType) else {
                completionHandler(.cancel); finish(NativeMediaError.invalidResponse); return
            }
        }
        let expected = response.expectedContentLength
        if expected > maximumBytes { completionHandler(.cancel); finish(NativeMediaError.tooLarge); return }
        if http.statusCode == 206 {
            guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = Self.completeRange(value), parsed == expected, parsed > 0 else {
                completionHandler(.cancel); finish(NativeMediaError.invalidResponse); return
            }
        }
        expectedBytes = expected >= 0 ? expected : nil
        offlineProgress?(0, expectedBytes)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard Int64(data.count) <= maximumBytes - bytes else { finish(NativeMediaError.tooLarge); return }
        if let expectedBytes, Int64(data.count) > expectedBytes - bytes { finish(NativeMediaError.invalidResponse); return }
        do {
            guard let handle else { throw NativeMediaError.storage }
            try handle.write(contentsOf: data)
            bytes += Int64(data.count)
            offlineProgress?(bytes, expectedBytes)
        } catch { finish(NativeMediaError.storage) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard !finished else { return }
        if cancelled { finish(CancellationError()) }
        else if error != nil { finish(NativeMediaError.network) }
        else if bytes == 0 || expectedBytes.map({ $0 != bytes }) == true { finish(NativeMediaError.invalidResponse) }
        else { finish(nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        redirects += 1
        guard !finished, redirects <= 3, let url = request.url, NativeMediaPolicy.allows(url) else {
            completionHandler(nil); finish(NativeMediaError.unsafeURL); return
        }
        var safe = request
        safe.setValue(source.userAgent, forHTTPHeaderField: "User-Agent")
        safe.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
        safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        safe.setValue(nil, forHTTPHeaderField: "Authorization")
        safe.setValue(nil, forHTTPHeaderField: "Cookie")
        completionHandler(safe)
    }

    private func finish(_ error: (any Error)?) {
        guard !finished else { return }
        finished = true
        var failure = error
        do {
            if failure == nil, offlineProgress != nil { try handle?.synchronize() }
            try handle?.close()
        } catch {
            if failure == nil { failure = NativeMediaError.storage }
        }
        handle = nil
        task?.cancel()
        session.invalidateAndCancel()
        let continuation = continuation
        self.continuation = nil
        if let failure { continuation?.resume(throwing: failure) }
        else { continuation?.resume() }
    }

    private static func completeRange(_ value: String) -> Int64? {
        let pieces = value.split(separator: " ")
        guard pieces.count == 2, pieces[0].lowercased() == "bytes" else { return nil }
        let range = pieces[1].split(separator: "/")
        guard range.count == 2, let total = Int64(range[1]), total > 0 else { return nil }
        let bounds = range[0].split(separator: "-")
        guard bounds.count == 2, bounds[0] == "0", let end = Int64(bounds[1]), end == total - 1 else { return nil }
        return total
    }
}
