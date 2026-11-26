import AVFoundation
import Foundation
import HongguoCore
import UniformTypeIdentifiers

/// Adds media request headers through AVFoundation's public resource-loader API.
/// Bytes are forwarded as they arrive; an episode is never buffered in memory.
final class AuthenticatedMediaLoader: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    private final class Pending {
        let request: AVAssetResourceLoadingRequest
        let offset: Int64
        let requestedLength: Int64
        let allToEnd: Bool
        var delivered: Int64 = 0
        var targetLength: Int64?
        var totalLength: Int64?
        var etag: String?
        var retries = 0
        var networkStart: Double?

        init(_ request: AVAssetResourceLoadingRequest, offset: Int64, length: Int, allToEnd: Bool) {
            self.request = request
            self.offset = offset
            self.requestedLength = Int64(length)
            self.allToEnd = allToEnd
        }
    }

    private let sourceURL: URL
    private let headers: [String: String]
    private let opening: RelayPlaybackOpening?
    private let resumesInterruptedRanges: Bool
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.media")
    private var pending: [Int: Pending] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var retrying: [ObjectIdentifier: Pending] = [:]
    private var stopped = false
    private let statusLock = NSLock()
    private var terminalStatus: Int?
    private var lastValidatedRequest: Double?
    var lastValidatedForegroundRequestStartedAt: Double? { statusLock.withLock { lastValidatedRequest } }
    var lastTerminalStatus: Int? { statusLock.withLock { terminalStatus } }

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 3
        let operations = OperationQueue()
        operations.maxConcurrentOperationCount = 1
        operations.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }()

    init(url: URL, headers: [String: String], resumesInterruptedRanges: Bool = false, opening: RelayPlaybackOpening? = nil) {
        self.opening = opening
        self.sourceURL = url
        self.headers = headers
        self.resumesInterruptedRanges = resumesInterruptedRanges
        super.init()
    }

    func makeAsset() -> AVURLAsset {
        var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)!
        components.scheme = "hongguo-media"
        let asset = AVURLAsset(url: components.url!)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    func invalidate() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            for entry in Array(pending.values) + Array(retrying.values) {
                entry.request.finishLoading(with: Self.failure("播放已停止。"))
            }
            pending.removeAll()
            retrying.removeAll()
            tasks.removeAll()
            session.invalidateAndCancel()
        }
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped else { return false }
        let dataRequest = loadingRequest.dataRequest
        let offset = dataRequest.map { max($0.requestedOffset, $0.currentOffset) } ?? 0
        let alreadyDelivered = dataRequest.map { max(0, offset - $0.requestedOffset) } ?? 0
        let remaining = Int64(dataRequest?.requestedLength ?? 2) - alreadyDelivered
        guard remaining > 0 else {
            loadingRequest.finishLoading()
            return true
        }
        let entry = Pending(loadingRequest, offset: offset, length: Int(remaining),
                            allToEnd: dataRequest?.requestsAllDataToEndOfResource ?? false)
        if let opening {
            guard offset < opening.totalLength else {
                loadingRequest.finishLoading(with: Self.failure("影片資料範圍無效。"))
                return true
            }
            entry.totalLength = opening.totalLength
            entry.etag = opening.etag
            let target = entry.allToEnd ? opening.totalLength - offset : min(remaining, opening.totalLength - offset)
            entry.targetLength = target
            if let info = loadingRequest.contentInformationRequest {
                info.contentLength = opening.totalLength
                info.contentType = UTType.mpeg4Movie.identifier
                info.isByteRangeAccessSupported = true
            }
            if dataRequest == nil { loadingRequest.finishLoading(); return true }
            // Offset is absolute. A crossing request first consumes its cached bytes
            // and then fetches only the suffix, pinned to this representation.
            if offset < Int64(opening.bytes.count) {
                let count = min(target, Int64(opening.bytes.count) - offset)
                dataRequest?.respond(with: opening.bytes.subdata(in: Int(offset)..<Int(offset + count)))
                entry.delivered = count
                if count == target { loadingRequest.finishLoading(); return true }
            }
        }
        startRequest(entry)
        return true
    }

    private func startRequest(_ entry: Pending) {
        let remaining = (entry.targetLength ?? entry.requestedLength) - entry.delivered
        guard remaining > 0, remaining <= Int64(Int.max),
              let range = MediaByteRange.requestHeader(offset: entry.offset + entry.delivered,
                  length: Int(remaining), allToEnd: entry.allToEnd) else {
            entry.request.finishLoading(with: Self.failure("影片資料範圍無效。")); return
        }
        var request = URLRequest(url: sourceURL)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue(entry.etag, forHTTPHeaderField: "If-Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        entry.networkStart = ProcessInfo.processInfo.systemUptime
        let task = session.dataTask(with: request)
        pending[task.taskIdentifier] = entry
        tasks[ObjectIdentifier(entry.request)] = task
        task.resume()
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        retrying.removeValue(forKey: ObjectIdentifier(loadingRequest))
        guard let task = tasks.removeValue(forKey: ObjectIdentifier(loadingRequest)) else { return }
        pending.removeValue(forKey: task.taskIdentifier)
        task.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let entry = pending[dataTask.taskIdentifier], let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 200 || http.statusCode == 206 else {
            if [408, 429, 500, 502, 503, 504].contains(http.statusCode), retry(dataTask, entry: entry) {
                completionHandler(.cancel); return
            }
            if [401, 403, 404, 410].contains(http.statusCode) {
                statusLock.withLock {
                    // AVFoundation sometimes replaces the loader error with a generic item error.
                    if terminalStatus != 401 && terminalStatus != 403 { terminalStatus = http.statusCode }
                }
            }
            let error = NSError(domain: PlaybackRecovery.assetErrorDomain, code: http.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: http.statusCode == 401
                                    ? "影片授權已失效，請檢查服務口令。" : "影片服務暫時無法提供資料。"])
            finish(dataTask, error: error)
            completionHandler(.cancel)
            return
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(MediaByteRange.parse)
        guard (http.statusCode == 206 && contentRange?.start == entry.offset + entry.delivered)
                || (http.statusCode == 200 && entry.offset + entry.delivered == 0) else {
            finish(dataTask, error: Self.failure("影片服務未正確回應快轉所需的資料範圍。"))
            completionHandler(.cancel)
            return
        }
        let total = contentRange?.total ?? response.expectedContentLength
        guard total > 0, entry.offset < total else {
            finish(dataTask, error: Self.failure("影片長度無效。"))
            completionHandler(.cancel)
            return
        }
        let etag = http.value(forHTTPHeaderField: "ETag")
        guard entry.totalLength == nil || entry.totalLength == total,
              entry.etag == nil || entry.etag == etag else {
            finish(dataTask, error: Self.failure("影片版本已變更，請重新取源。"))
            completionHandler(.cancel); return
        }
        entry.totalLength = total
        entry.etag = etag
        if let info = entry.request.contentInformationRequest {
            info.contentLength = total
            info.contentType = response.mimeType.flatMap { UTType(mimeType: $0)?.identifier } ?? UTType.mpeg4Movie.identifier
            info.isByteRangeAccessSupported = http.statusCode == 206
                || http.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true
        }
        entry.targetLength = entry.allToEnd ? total - entry.offset : min(entry.requestedLength, total - entry.offset)
        if entry.request.dataRequest == nil {
            finish(dataTask)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let entry = pending[dataTask.taskIdentifier], let target = entry.targetLength else { return }
        let remaining = target - entry.delivered
        guard remaining > 0 else { finish(dataTask); return }
        let count = min(data.count, Int(min(remaining, Int64(Int.max))))
        if count > 0, let start = entry.networkStart {
            statusLock.withLock { lastValidatedRequest = max(lastValidatedRequest ?? start, start) }
            entry.networkStart = nil
        }
        entry.request.dataRequest?.respond(with: data.prefix(count))
        entry.delivered += Int64(count)
        if entry.delivered >= target { finish(dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = pending[task.taskIdentifier], let dataTask = task as? URLSessionDataTask else { return }
        if error != nil || entry.delivered != entry.targetLength {
            let network = error as? URLError
            let transient = error == nil || network.map {
                [.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
                 .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable].contains($0.code)
            } == true
            if transient, retry(dataTask, entry: entry) { return }
            let failure = transient && resumesInterruptedRanges ? NSError(domain: PlaybackRecovery.assetErrorDomain,
                code: PlaybackRecovery.transientAssetErrorCode, userInfo: [NSLocalizedDescriptionKey: "影片連線中斷，請重試。"]) : Self.failure("影片連線中斷，請重試。")
            finish(dataTask, error: failure)
        } else {
            finish(dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let destination = request.url,
              ["https", "http"].contains(destination.scheme?.lowercased() ?? ""),
              destination.user == nil, destination.password == nil,
              !(sourceURL.scheme?.lowercased() == "https" && destination.scheme?.lowercased() != "https") else {
            completionHandler(nil)
            return
        }
        let sensitive = headers.keys.contains { ["authorization", "cookie", "proxy-authorization"].contains($0.lowercased()) }
        guard !sensitive || MediaByteRange.sameOrigin(sourceURL, destination) else {
            completionHandler(nil)
            return
        }
        var redirected = request
        redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: "Range"), forHTTPHeaderField: "Range")
        redirected.setValue(task.originalRequest?.value(forHTTPHeaderField: "If-Range"), forHTTPHeaderField: "If-Range")
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if MediaByteRange.sameOrigin(sourceURL, destination) {
            for (name, value) in headers { redirected.setValue(value, forHTTPHeaderField: name) }
        }
        completionHandler(redirected)
    }

    /// Resume only an immutable, authenticated relay URL. A delivered prefix requires
    /// an unchanged ETag/total; retries never combine bytes from re-resolved sources.
    private func retry(_ task: URLSessionDataTask, entry: Pending) -> Bool {
        guard resumesInterruptedRanges, !stopped, entry.retries < 4,
              entry.delivered == 0 || entry.etag != nil else { return false }
        let delays: [Double] = [0.5, 1, 2, 5]
        let delay = delays[entry.retries]; entry.retries += 1
        let key = ObjectIdentifier(entry.request)
        pending.removeValue(forKey: task.taskIdentifier); tasks.removeValue(forKey: key)
        retrying[key] = entry
        task.cancel()
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped, self.retrying[key] === entry else { return }
            self.retrying.removeValue(forKey: key)
            self.startRequest(entry)
        }
        return true
    }

    private func finish(_ task: URLSessionDataTask, error: Error? = nil) {
        guard let entry = pending.removeValue(forKey: task.taskIdentifier) else { return }
        tasks.removeValue(forKey: ObjectIdentifier(entry.request))
        if let error { entry.request.finishLoading(with: error) }
        else { entry.request.finishLoading() }
        task.cancel()
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "HongguoMedia", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
