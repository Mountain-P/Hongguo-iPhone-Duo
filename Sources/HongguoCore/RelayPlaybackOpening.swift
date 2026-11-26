import Foundation

/// A bounded beginning of one immutable relay representation, for the next AVPlayer item.
public struct RelayPlaybackOpening: Sendable {
    public let bytes: Data
    public let totalLength: Int64
    public let etag: String

    static func fetch(_ source: PlaybackSource, rate: Float,
                      configuration: URLSessionConfiguration = .ephemeral) async throws -> Self {
        try Task.checkCancellation()
        try await PlaybackNetworkPriority.shared.waitForForeground()
        let limit = rate >= 2 ? 1024 * 1024 : 512 * 1024
        let result = AsyncThrowingStream<Self, any Error>.makeStream()
        let delegate = RelayPrefixTransfer(origin: source.url, limit: limit, result: result.continuation)
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source.url)
        request.allHTTPHeaderFields = source.headers
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        let task = session.dataTask(with: request)
        task.priority = URLSessionTask.lowPriority
        task.resume()
        var iterator = result.stream.makeAsyncIterator()
        let opening = try await iterator.next()
        try Task.checkCancellation()
        guard let opening else { throw CatalogError.network }
        return opening
    }
}

private final class RelayPrefixTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let origin: URL
    let limit: Int
    let result: AsyncThrowingStream<RelayPlaybackOpening, any Error>.Continuation
    // Accessed on the URLSession's serial delegate queue.
    private var bytes = Data()
    private var total: Int64 = 0
    private var etag = ""
    private var expected = 0

    init(origin: URL, limit: Int, result: AsyncThrowingStream<RelayPlaybackOpening, any Error>.Continuation) {
        self.origin = origin
        self.limit = limit
        self.result = result
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // The home relay returns a local versioned route, which never needs forwarding.
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url == origin else {
            result.finish(throwing: CatalogError.unsafePlaybackURL); completionHandler(.cancel); return
        }
        guard http.statusCode == 206 else {
            result.finish(throwing: CatalogError.httpStatus(http.statusCode)); completionHandler(.cancel); return
        }
        let range = http.value(forHTTPHeaderField: "Content-Range")?.split(separator: "/")
        let tag = NativeRangeValidators(etag: http.value(forHTTPHeaderField: "ETag")).strongETag
        guard let range, range.count == 2, let total = Int64(range[1]), total > 0,
              let tag, http.mimeType?.lowercased() == "video/mp4",
              (http.value(forHTTPHeaderField: "Content-Encoding") ?? "identity").lowercased() == "identity" else {
            result.finish(throwing: CatalogError.malformedResponse); completionHandler(.cancel); return
        }
        expected = Int(min(total, Int64(limit)))
        guard range[0] == "bytes 0-\(expected - 1)", http.expectedContentLength == Int64(expected) else {
            result.finish(throwing: CatalogError.malformedResponse); completionHandler(.cancel); return
        }
        self.total = total
        etag = tag
        bytes.reserveCapacity(expected)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= expected - bytes.count else {
            result.finish(throwing: CatalogError.responseTooLarge); dataTask.cancel(); return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { result.finish(throwing: error); return }
        guard expected > 0, bytes.count == expected else { result.finish(throwing: CatalogError.network); return }
        result.yield(.init(bytes: bytes, totalLength: total, etag: etag))
        result.finish()
    }
}
