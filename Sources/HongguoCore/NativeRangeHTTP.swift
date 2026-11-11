// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum NativeProgressiveError: Error, Sendable, Equatable, LocalizedError {
    case unsupportedRange, invalidRange, changedSource, unsupportedLayout, headerTooLarge, auxiliaryLimit
    public var errorDescription: String? {
        switch self {
        case .unsupportedRange: "來源暫不支援分段載入，無法立即播放。"
        case .invalidRange: "影片分段回應不完整，請重試。"
        case .changedSource: "影片來源已變更，請重新載入。"
        case .unsupportedLayout: "目前影片結構不支援漸進播放。"
        case .headerTooLarge, .auxiliaryLimit: "影片播放索引超出支援範圍。"
        }
    }
}

struct NativeRangeValidators: Sendable, Equatable {
    var etag: String?
    var lastModified: String?
    init(etag: String? = nil, lastModified: String? = nil) { self.etag = etag; self.lastModified = lastModified }
    func accepts(_ next: Self) -> Bool {
        (etag == nil || etag == next.etag) && (lastModified == nil || lastModified == next.lastModified)
    }
}

struct NativeRangeResponse: Sendable {
    let data: Data
    let range: Range<Int>
    let totalLength: Int
    let validators: NativeRangeValidators
}

protocol NativeRangeFetching: Sendable {
    func fetch(range: Range<Int>) async throws -> NativeRangeResponse
}

enum NativeRangeHeaders {
    struct Parsed {
        let range: Range<Int>
        let totalLength: Int
        let validators: NativeRangeValidators
    }
    static func parse(_ response: HTTPURLResponse, requested: Range<Int>, knownTotal: Int?, validators: NativeRangeValidators?,
                      approvedRedirectURL: URL? = nil) throws -> Parsed {
        guard requested.lowerBound >= 0, requested.upperBound > requested.lowerBound else { throw NativeProgressiveError.invalidRange }
        if response.statusCode == 401 { throw CatalogError.unauthorized }
        if response.statusCode == 403 { throw CatalogError.httpStatus(403) }
        if let reason = NativeMediaPolicy.rejection(of: response.url),
           reason != .host || response.url != approvedRedirectURL {
            NativeMediaPolicy.report(reason, stage: .rangeResponse, status: response.statusCode)
            throw NativeMediaError.unsafeURL
        }
        guard response.statusCode == 206 else {
            if response.statusCode == 200 { throw NativeProgressiveError.unsupportedRange }
            throw NativeMediaError.httpStatus(response.statusCode)
        }
        let mime = response.mimeType?.lowercased() ?? ""
        guard !mime.hasPrefix("text/"), mime != "application/json", !mime.hasSuffix("+json"),
              response.value(forHTTPHeaderField: "Content-Encoding").map({ $0.lowercased() == "identity" }) ?? true,
              let raw = response.value(forHTTPHeaderField: "Content-Range") else { throw NativeProgressiveError.invalidRange }
        let pieces = raw.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count == 2, pieces[0] == "bytes" else { throw NativeProgressiveError.invalidRange }
        let halves = pieces[1].split(separator: "/", omittingEmptySubsequences: false)
        guard halves.count == 2, let total = Int(halves[1]), total > 0 else { throw NativeProgressiveError.invalidRange }
        let bounds = halves[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let lower = Int(bounds[0]), let last = Int(bounds[1]),
              lower == requested.lowerBound, lower >= 0, lower < total,
              last == min(requested.upperBound - 1, total - 1) else { throw NativeProgressiveError.invalidRange }
        let actual = lower..<(last + 1)
        guard response.expectedContentLength < 0 || response.expectedContentLength == Int64(actual.count) else { throw NativeProgressiveError.invalidRange }
        let next = NativeRangeValidators(etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"))
        guard knownTotal.map({ $0 == total }) ?? true, validators?.accepts(next) ?? true else { throw NativeProgressiveError.changedSource }
        return Parsed(range: actual, totalLength: total, validators: next)
    }
}

/// Reuses a single ephemeral session per stream. All callbacks and mutable
/// request state share one queue; at most two Range transactions are active.
final class NativeRangeHTTP: NSObject, NativeRangeFetching, URLSessionDataDelegate, @unchecked Sendable {
    private final class Transfer: @unchecked Sendable {
        let id = UUID()
        let range: Range<Int>
        var continuation: CheckedContinuation<NativeRangeResponse, any Error>?
        var task: URLSessionDataTask?
        var metadata: NativeRangeHeaders.Parsed?
        var data = Data()
        var cancelled = false
        var finished = false
        var redirects = 0
        var approvedRedirectURL: URL?
        init(range: Range<Int>) { self.range = range }
    }
    private let source: NativeMediaSource
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.range-http")
    private let configuration: URLSessionConfiguration
    private var transfers: [UUID: Transfer] = [:]
    private var taskIDs: [Int: UUID] = [:]
    private var waiting: [UUID] = []
    private var active = 0
    private var knownTotal: Int?
    private var validators: NativeRangeValidators?
    private var terminalError: (any Error)?
    private lazy var session: URLSession = {
        let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
        return URLSession(configuration: configuration, delegate: self, delegateQueue: operations)
    }()

    init(source: NativeMediaSource, configuration: URLSessionConfiguration = .ephemeral) throws {
        try NativeMediaPolicy.validate(source)
        self.source = source
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.configuration.httpCookieStorage = nil
        self.configuration.httpShouldSetCookies = false
        self.configuration.urlCredentialStorage = nil
        self.configuration.urlCache = nil
        self.configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.configuration.timeoutIntervalForRequest = 15
        self.configuration.timeoutIntervalForResource = 20
        self.configuration.httpMaximumConnectionsPerHost = 2
        super.init()
    }

    func fetch(range: Range<Int>) async throws -> NativeRangeResponse {
        try Task.checkCancellation()
        guard range.lowerBound >= 0, range.upperBound > range.lowerBound, range.count <= 8 * 1024 * 1024 else { throw NativeProgressiveError.invalidRange }
        let transfer = Transfer(range: range)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    transfer.continuation = continuation
                    transfers[transfer.id] = transfer
                    if transfer.cancelled { finish(transfer, error: CancellationError()); return }
                    if let terminalError { finish(transfer, error: terminalError); return }
                    waiting.append(transfer.id)
                    startWaiting()
                }
            }
        } onCancel: {
            self.queue.async { [self] in
                transfer.cancelled = true
                if transfer.continuation != nil { finish(transfer, error: CancellationError()) }
            }
        }
        try Task.checkCancellation()
        return response
    }

    private func startWaiting() {
        while active < 2, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let transfer = transfers[id], !transfer.finished else { continue }
            if let terminalError { finish(transfer, error: terminalError); continue }
            if let knownTotal, transfer.range.lowerBound >= knownTotal { finish(transfer, error: NativeProgressiveError.invalidRange); continue }
            var request = URLRequest(url: source.url)
            request.setValue("bytes=\(transfer.range.lowerBound)-\(transfer.range.upperBound - 1)", forHTTPHeaderField: "Range")
            request.setValue(source.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            // If-Range also prevents combining bytes from a changed CDN object.
            if let value = validators?.etag ?? validators?.lastModified { request.setValue(value, forHTTPHeaderField: "If-Range") }
            let task = session.dataTask(with: request)
            transfer.task = task; taskIDs[task.taskIdentifier] = id
            active += 1; task.resume()
        }
    }

    private func transfer(_ task: URLSessionTask) -> Transfer? {
        guard let id = taskIDs[task.taskIdentifier] else { return nil }; return transfers[id]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(dataTask), !transfer.finished, let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        do {
            let metadata = try NativeRangeHeaders.parse(http, requested: transfer.range, knownTotal: knownTotal,
                                                        validators: validators, approvedRedirectURL: transfer.approvedRedirectURL)
            knownTotal = metadata.totalLength
            if validators == nil { validators = metadata.validators }
            else {
                if validators?.etag == nil { validators?.etag = metadata.validators.etag }
                if validators?.lastModified == nil { validators?.lastModified = metadata.validators.lastModified }
            }
            transfer.metadata = metadata
            transfer.data.reserveCapacity(metadata.range.count)
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            if Self.isTerminal(error) { retire(session, with: error) }
            else { finish(transfer, error: error) }
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let transfer = transfer(dataTask), !transfer.finished else { return }
        guard let metadata = transfer.metadata, data.count <= metadata.range.count - transfer.data.count else { finish(transfer, error: NativeProgressiveError.invalidRange); return }
        transfer.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = transfer(task), !transfer.finished else { return }
        if transfer.cancelled { finish(transfer, error: CancellationError()) }
        else if error != nil { finish(transfer, error: NativeMediaError.network) }
        else if let metadata = transfer.metadata, transfer.data.count == metadata.range.count {
            finish(transfer, response: NativeRangeResponse(data: transfer.data, range: metadata.range, totalLength: metadata.totalLength, validators: metadata.validators))
        } else { finish(transfer, error: NativeProgressiveError.invalidRange) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let transfer = transfer(task), !transfer.finished else { completionHandler(nil); return }
        transfer.redirects += 1
        let priorApprovedURL = transfer.approvedRedirectURL
        transfer.approvedRedirectURL = nil
        if let reason = NativeMediaPolicy.redirectRejection(of: request.url, hops: transfer.redirects) {
            let fromSource = transfer.redirects == 1 && response.url == source.url
                && NativeMediaPolicy.allowsScheduledCDNRedirect(from: source.url, to: request.url)
            let fromRelay = transfer.redirects == 2 && response.url == priorApprovedURL
                && NativeMediaPolicy.allowsScheduledCDNRelay(from: priorApprovedURL, to: request.url)
            guard reason == .host, response.statusCode == 302, fromSource || fromRelay else {
                completionHandler(nil)
                NativeMediaPolicy.report(reason, stage: .rangeRedirect, status: response.statusCode, hops: transfer.redirects)
                retire(session, with: NativeMediaError.unsafeURL)
                return
            }
            // The extra destination is valid only for this individual Range request.
            transfer.approvedRedirectURL = request.url
        }
        var safe = request
        safe.httpMethod = "GET"; safe.httpBody = nil
        safe.setValue(nil, forHTTPHeaderField: "Authorization"); safe.setValue(nil, forHTTPHeaderField: "Cookie")
        safe.setValue(source.userAgent, forHTTPHeaderField: "User-Agent")
        safe.setValue("https://novel.snssdk.com/", forHTTPHeaderField: "Referer")
        safe.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        safe.setValue("bytes=\(transfer.range.lowerBound)-\(transfer.range.upperBound - 1)", forHTTPHeaderField: "Range")
        completionHandler(safe)
    }

    private static func isTerminal(_ error: any Error) -> Bool {
        if case CatalogError.unauthorized = error { return true }
        if case CatalogError.httpStatus(403) = error { return true }
        if case NativeProgressiveError.changedSource = error { return true }
        if case NativeMediaError.unsafeURL = error { return true }
        return false
    }

    private func retire(_ session: URLSession, with error: any Error) {
        stopAll(error)
        session.invalidateAndCancel()
    }

    private func stopAll(_ error: any Error) {
        guard terminalError == nil else { return }
        terminalError = error
        for transfer in Array(transfers.values) { finish(transfer, error: error, startNext: false) }
        waiting.removeAll()
    }

    private func finish(_ transfer: Transfer, response: NativeRangeResponse? = nil, error: (any Error)? = nil, startNext: Bool = true) {
        guard !transfer.finished else { return }; transfer.finished = true
        if let task = transfer.task { taskIDs.removeValue(forKey: task.taskIdentifier); active -= 1; task.cancel() }
        transfers.removeValue(forKey: transfer.id)
        let continuation = transfer.continuation; transfer.continuation = nil
        if let error { continuation?.resume(throwing: error) }
        else if let response { continuation?.resume(returning: response) }
        else { continuation?.resume(throwing: NativeProgressiveError.invalidRange) }
        if startNext { startWaiting() }
    }

    /// Called when the owning stream is released. Queued work has its own
    /// continuations and remains alive until cancellation has been delivered.
    func close() { queue.async { [self] in retire(session, with: CancellationError()) } }
}
