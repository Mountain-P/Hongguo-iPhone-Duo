import AVFoundation
import Foundation
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

        init(_ request: AVAssetResourceLoadingRequest, offset: Int64, length: Int, allToEnd: Bool) {
            self.request = request
            self.offset = offset
            self.requestedLength = Int64(length)
            self.allToEnd = allToEnd
        }
    }

    private let sourceURL: URL
    private let headers: [String: String]
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.media")
    private var pending: [Int: Pending] = [:]
    private var tasks: [ObjectIdentifier: URLSessionDataTask] = [:]
    private var stopped = false
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

    init(url: URL, headers: [String: String]) {
        self.sourceURL = url
        self.headers = headers
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
            for entry in pending.values {
                entry.request.finishLoading(with: Self.failure("播放已停止。"))
            }
            pending.removeAll()
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
        let length = Int(remaining)
        let allToEnd = dataRequest?.requestsAllDataToEndOfResource ?? false
        guard let range = MediaByteRange.requestHeader(offset: offset, length: length, allToEnd: allToEnd) else {
            loadingRequest.finishLoading(with: Self.failure("影片資料範圍無效。"))
            return true
        }

        var request = URLRequest(url: sourceURL)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(range, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let task = session.dataTask(with: request)
        pending[task.taskIdentifier] = Pending(loadingRequest, offset: offset, length: length, allToEnd: allToEnd)
        tasks[ObjectIdentifier(loadingRequest)] = task
        task.resume()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel loadingRequest: AVAssetResourceLoadingRequest) {
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
            finish(dataTask, error: Self.failure(http.statusCode == 401 ? "影片授權已失效，請檢查服務口令。" : "影片服務暫時無法提供資料。"))
            completionHandler(.cancel)
            return
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(MediaByteRange.parse)
        guard (http.statusCode == 206 && contentRange?.start == entry.offset)
                || (http.statusCode == 200 && entry.offset == 0) else {
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
        entry.request.dataRequest?.respond(with: data.prefix(count))
        entry.delivered += Int64(count)
        if entry.delivered >= target { finish(dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let entry = pending[task.taskIdentifier], let dataTask = task as? URLSessionDataTask else { return }
        if error != nil || entry.delivered != entry.targetLength {
            finish(dataTask, error: Self.failure("影片連線中斷，請重試。"))
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
        redirected.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if MediaByteRange.sameOrigin(sourceURL, destination) {
            for (name, value) in headers { redirected.setValue(value, forHTTPHeaderField: name) }
        }
        completionHandler(redirected)
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
