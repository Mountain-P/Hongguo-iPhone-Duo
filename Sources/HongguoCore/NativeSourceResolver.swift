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
        case "BUSINESS_REJECTED", "HTTP_401", "HTTP_403": "來源目前未授權提供本集播放。"
        case "ETIMEDOUT": "影片準備逾時，請重試。"
        case "APP_INPUT": "分集或內容類型無效。"
        default: "影片來源暫時無法使用，請稍後重試。"
        }
    }
}

public actor NativeSourceResolver {
    public static let shared = NativeSourceResolver()
    private struct Entry { let source: NativeMediaSource; let expires: Date; var access: UInt64 }
    private var cache: [String: Entry] = [:]
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

    public func resolve(episodeID: String, contentType: String = "1004", fresh: Bool = false,
                        quality: NativePlaybackQuality = .automatic) async throws -> NativeMediaSource {
        try Task.checkCancellation()
        guard episodeID.range(of: #"^\d{1,30}$"#, options: .regularExpression) != nil,
              contentType.range(of: #"^\d{1,16}$"#, options: .regularExpression) != nil else { throw NativeSourceError(code: "APP_INPUT") }
        let key = episodeID + ":" + contentType + ":" + quality.rawValue
        if !fresh, var entry = cache[key], entry.expires > now() {
            access &+= 1; entry.access = access; cache[key] = entry; return entry.source
        }
        cache.removeValue(forKey: key)
        let request = UUID(); requests[key] = request
        do {
            // Pending work is request-isolated: cancelling one caller cannot stop another.
            let source = try await resolveSource(episodeID, contentType, quality)
            try Task.checkCancellation()
            guard source.preference == quality else { throw NativeSourceError(code: "INVALID_RESPONSE") }
            if requests[key] == request {
                requests.removeValue(forKey: key)
                access &+= 1; cache[key] = Entry(source: source, expires: now().addingTimeInterval(120), access: access)
                while cache.count > 16, let oldest = cache.min(by: { $0.value.access < $1.value.access }) { cache.removeValue(forKey: oldest.key) }
            }
            return source
        } catch {
            if requests[key] == request { requests.removeValue(forKey: key) }
            throw error
        }
    }
}
