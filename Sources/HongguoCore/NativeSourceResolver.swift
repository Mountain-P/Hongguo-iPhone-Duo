// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct NativeMediaSource: Sendable {
    public let url: URL
    public let contentKey: Data?
    public let userAgent: String
    public let codec: String
    public let quality: String
    public let preference: NativePlaybackQuality
    public let qualityFallback: Bool
    public let width: Int?
    public let height: Int?

    public init(url: URL, contentKey: Data?, userAgent: String, codec: String, quality: String,
                preference: NativePlaybackQuality = .automatic, qualityFallback: Bool = false,
                width: Int? = nil, height: Int? = nil) {
        self.url = url; self.contentKey = contentKey; self.userAgent = userAgent
        self.codec = codec; self.quality = quality
        self.preference = preference; self.qualityFallback = qualityFallback
        self.width = width; self.height = height
    }
}

public struct NativeSourceError: Error, Sendable, LocalizedError {
    public let code: String
    public init(code: String) { self.code = code }
    public var errorDescription: String? {
        switch code {
        case "NO_COMPATIBLE_SOURCE", "QUALITY_UNAVAILABLE": "本集暫未提供 iPhone 支援的影片格式。"
        case "OFFLINE_CLEAR_UNAVAILABLE": "來源未提供可離線儲存的未加密 MP4。"
        case "BUSINESS_REJECTED", "HTTP_401", "HTTP_403": "來源目前未授權提供本集播放。"
        case "EMPTY_RESPONSE": "來源未回傳影片資料，請稍後重試。"
        case "HTTP_429": "來源暫時限制請求，請稍後重試。"
        case "ETIMEDOUT": "影片準備逾時，請重試。"
        case "APP_INPUT": "分集或內容類型無效。"
        default: "影片來源暫時無法使用，請稍後重試。"
        }
    }
}

public actor NativeSourceResolver {
    public static let shared = NativeSourceResolver()
    static let maximumPendingFlights = 16
    static let maximumWaitersPerFlight = 32
    private struct Entry { let source: NativeMediaSource; let expires: Date; var access: UInt64 }
    private final class CancellationToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        var isCancelled: Bool { lock.withLock { cancelled } }
    }
    private struct Waiter {
        let continuation: CheckedContinuation<NativeMediaSource, any Error>
        let cancellation: CancellationToken
    }
    private struct Flight {
        let key: String
        var task: Task<Void, Never>?
        var waiters: [UUID: Waiter]
    }
    private var cache: [String: Entry] = [:]
    private var flights: [UUID: Flight] = [:]
    private var joinable: [String: UUID] = [:]
    private var waiterFlights: [UUID: UUID] = [:]
    private var requests: [String: UUID] = [:]
    private var access: UInt64 = 0
    private let resolveSource: @Sendable (String, String, NativePlaybackQuality) async throws -> NativeMediaSource
    private let now: @Sendable () -> Date
    public init() {
        self.now = Date.init
        self.resolveSource = { try await NativeJSRuntime().resolve(episodeID: $0, contentType: $1, quality: $2) }
    }
    init(now: @escaping @Sendable () -> Date = Date.init, resolve: @escaping @Sendable (String, String) async throws -> NativeMediaSource) {
        self.now = now; self.resolveSource = { episode, type, _ in try await resolve(episode, type) }
    }

    init(now: @escaping @Sendable () -> Date = Date.init,
         resolveQuality: @escaping @Sendable (String, String, NativePlaybackQuality) async throws -> NativeMediaSource) {
        self.now = now; self.resolveSource = resolveQuality
    }

    deinit { for flight in flights.values { flight.task?.cancel() } }

    var pendingFlightCount: Int { flights.count }
    var pendingWaiterCount: Int { waiterFlights.count }

    public func resolve(episodeID: String, contentType: String = "1004", fresh: Bool = false,
                        quality: NativePlaybackQuality = .automatic) async throws -> NativeMediaSource {
        try Task.checkCancellation()
        guard episodeID.range(of: #"^\d{1,30}$"#, options: .regularExpression) != nil,
              contentType.range(of: #"^\d{1,16}$"#, options: .regularExpression) != nil else { throw NativeSourceError(code: "APP_INPUT") }
        let key = episodeID + ":" + contentType + ":" + quality.rawValue
        if !fresh, var entry = cache[key], entry.expires > now() {
            access &+= 1; entry.access = access; cache[key] = entry; return entry.source
        }
        let waiter = UUID(), cancellation = CancellationToken()
        let source: NativeMediaSource = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NativeMediaSource, any Error>) in
                guard !Task.isCancelled, !cancellation.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if !fresh, let id = joinable[key], var flight = flights[id] {
                    guard flight.waiters.count < Self.maximumWaitersPerFlight else {
                        continuation.resume(throwing: NativeSourceError(code: "SOURCE_BUSY")); return
                    }
                    flight.waiters[waiter] = Waiter(continuation: continuation, cancellation: cancellation)
                    flights[id] = flight; waiterFlights[waiter] = id
                    return
                }
                guard flights.count < Self.maximumPendingFlights else {
                    continuation.resume(throwing: NativeSourceError(code: "SOURCE_BUSY")); return
                }
                cache.removeValue(forKey: key)
                let id = UUID()
                requests[key] = id
                // A fresh request is never joined. It also prevents future callers from
                // joining an older flight, without cancelling that flight's existing readers.
                if fresh { joinable.removeValue(forKey: key) } else { joinable[key] = id }
                flights[id] = Flight(key: key, task: nil, waiters: [waiter: Waiter(continuation: continuation, cancellation: cancellation)])
                waiterFlights[waiter] = id
                let resolver = resolveSource
                let task = Task { [weak self] in
                    let result: Result<NativeMediaSource, any Error>
                    do {
                        let source = try await resolver(episodeID, contentType, quality)
                        try Task.checkCancellation()
                        guard source.preference == quality else { throw NativeSourceError(code: "INVALID_RESPONSE") }
                        result = .success(source)
                    } catch { result = .failure(error) }
                    await self?.complete(id: id, result: result)
                }
                flights[id]?.task = task
            }
        } onCancel: {
            // Mark synchronously so a completion queued before actor cleanup cannot cache
            // a result belonging only to cancelled consumers.
            cancellation.cancel()
            Task { await self.cancel(waiter: waiter) }
        }
        try Task.checkCancellation()
        return source
    }

    private func cancel(waiter: UUID) {
        guard let id = waiterFlights.removeValue(forKey: waiter), var flight = flights[id],
              let removed = flight.waiters.removeValue(forKey: waiter) else { return }
        removed.continuation.resume(throwing: CancellationError())
        guard flight.waiters.isEmpty else { flights[id] = flight; return }
        // Keep a cancelled worker counted until it acknowledges completion, so even an
        // uncooperative injected transport cannot create unbounded detached work.
        flights[id] = flight; flight.task?.cancel()
        if joinable[flight.key] == id { joinable.removeValue(forKey: flight.key) }
        if requests[flight.key] == id { requests.removeValue(forKey: flight.key) }
    }

    private func complete(id: UUID, result: Result<NativeMediaSource, any Error>) {
        guard let flight = flights.removeValue(forKey: id) else { return }
        let activeWaiters = flight.waiters.values.contains { !$0.cancellation.isCancelled }
        if requests[flight.key] == id {
            requests.removeValue(forKey: flight.key)
            if activeWaiters, case .success(let source) = result {
                access &+= 1; cache[flight.key] = Entry(source: source, expires: now().addingTimeInterval(120), access: access)
                while cache.count > 16, let oldest = cache.min(by: { $0.value.access < $1.value.access }) { cache.removeValue(forKey: oldest.key) }
            }
        }
        if joinable[flight.key] == id { joinable.removeValue(forKey: flight.key) }
        for (waiter, value) in flight.waiters {
            waiterFlights.removeValue(forKey: waiter)
            if value.cancellation.isCancelled { value.continuation.resume(throwing: CancellationError()) }
            else { value.continuation.resume(with: result) }
        }
    }
}
