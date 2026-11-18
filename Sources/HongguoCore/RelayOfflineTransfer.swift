import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Ordinary MP4 transfer; transport credentials stay bound to the relay origin.
enum RelayOfflineTransfer {
    static func download(_ source: PlaybackSource, to destination: URL, maximumBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        let delegate = TransferDelegate(origin: source.url, maximumBytes: maximumBytes, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: source.url)
        for (name, value) in source.headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let file: URL, response: URLResponse
        do { (file, response) = try await session.download(for: request, delegate: delegate) }
        catch {
            try Task.checkCancellation()
            if delegate.exceeded { throw NativeMediaError.tooLarge }
            throw CatalogError.network
        }
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if (response as? HTTPURLResponse)?.statusCode == 401 { throw CatalogError.unauthorized }
            throw CatalogError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? 502)
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        guard Int64(data.count) <= maximumBytes else { throw NativeMediaError.tooLarge }
        do { try NativeMP4.validateOfflineClear(data: data, maximumBytes: maximumBytes) }
        catch is NativeMediaError {
            // A server adapter can be repaired independently. Keep this failure
            // retryable, while still rejecting the incomplete/encrypted file.
            throw CatalogError.malformedResponse
        }
        try Task.checkCancellation()
        // moveItem refuses an existing destination; OfflineDownloads owns publication.
        try FileManager.default.moveItem(at: file, to: destination)
        progress(Int64(data.count), Int64(data.count))
    }

    private final class TransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let origin: URL
        let maximumBytes: Int64
        let progress: @Sendable (Int64, Int64?) -> Void
        private let lock = NSLock()
        private var limitExceeded = false
        var exceeded: Bool { lock.withLock { limitExceeded } }
        init(origin: URL, maximumBytes: Int64, progress: @escaping @Sendable (Int64, Int64?) -> Void) {
            self.origin = origin; self.maximumBytes = maximumBytes; self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            if totalBytesWritten > maximumBytes || totalBytesExpectedToWrite > maximumBytes {
                lock.withLock { limitExceeded = true }; downloadTask.cancel(); return
            }
            progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, sameOrigin(origin, url), url.user == nil, url.password == nil else {
                completionHandler(nil); return
            }
            completionHandler(request)
        }
    }
}
