// SPDX-License-Identifier: GPL-3.0-only
import Foundation

protocol NativeMediaDownloading: Sendable {
    func download(source: NativeMediaSource, destination: URL, maximumBytes: Int64) async throws
}

struct NativeMediaHTTPDownload: NativeMediaDownloading {
    func download(source: NativeMediaSource, destination: URL, maximumBytes: Int64) async throws {
        try await NativeMediaTransfer(source: source, destination: destination, maximumBytes: maximumBytes).run()
    }
}

/// A transfer has one serial queue for URLSession callbacks, cancellation, and file writes.
/// Response bodies are streamed to a file and never buffered as a whole by URLSession.
private final class NativeMediaTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let source: NativeMediaSource
    private let destination: URL
    private let maximumBytes: Int64
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
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
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

    init(source: NativeMediaSource, destination: URL, maximumBytes: Int64) {
        self.source = source; self.destination = destination; self.maximumBytes = maximumBytes
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
                        guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                            attributes: [.posixPermissions: 0o600]) else { throw NativeMediaError.storage }
                        handle = try FileHandle(forWritingTo: destination)
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
        let expected = response.expectedContentLength
        if expected > maximumBytes { completionHandler(.cancel); finish(NativeMediaError.tooLarge); return }
        if http.statusCode == 206 {
            guard let value = http.value(forHTTPHeaderField: "Content-Range"),
                  let parsed = Self.completeRange(value), parsed == expected, parsed > 0 else {
                completionHandler(.cancel); finish(NativeMediaError.invalidResponse); return
            }
        }
        expectedBytes = expected >= 0 ? expected : nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard Int64(data.count) <= maximumBytes - bytes else { finish(NativeMediaError.tooLarge); return }
        do {
            try handle?.write(contentsOf: data)
            bytes += Int64(data.count)
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
        try? handle?.close()
        handle = nil
        task?.cancel()
        session.invalidateAndCancel()
        let continuation = continuation
        self.continuation = nil
        if let error { continuation?.resume(throwing: error) }
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
