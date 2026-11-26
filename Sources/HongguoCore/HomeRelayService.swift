import Foundation

/// Keeps catalogue/account identity independent from the media transport.
/// The relay owns source acquisition and returns ordinary authenticated MP4 ranges.
public struct HomeRelayService: CatalogService {
    private let relay: BridgeService
    private let direct: any CatalogService
    public let usesServerLibrary: Bool
    public let allowsDirectFallback: Bool

    public init(configuration: ServerConfiguration, usesServerLibrary: Bool = false,
                allowsDirectFallback: Bool = true,
                direct: any CatalogService = NativeCatalogService(),
                transport: any HTTPTransport = URLSessionTransport()) {
        relay = BridgeService(configuration: configuration, transport: transport, includesSeriesContext: true)
        self.direct = direct
        self.usesServerLibrary = usesServerLibrary
        self.allowsDirectFallback = allowsDirectFallback
    }

    public func servesMedia(at url: URL) -> Bool {
        sameOrigin(relay.configuration.baseURL, url)
    }

    public func verifyConnection() async throws -> Int { try await relay.verifyRelayConnection() }
    public func home(page: Int) async throws -> SeriesPage {
        try await (usesServerLibrary ? relay as any CatalogService : direct).home(page: page)
    }
    public func search(query: String, page: Int) async throws -> SeriesPage {
        try await (usesServerLibrary ? relay as any CatalogService : direct).search(query: query, page: page)
    }
    public func detail(id: String) async throws -> SeriesDetail {
        try await (usesServerLibrary ? relay as any CatalogService : direct).detail(id: id)
    }
    public func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        do { return try await relay.playback(seriesID: seriesID, episodeID: episodeID, fresh: fresh) }
        catch {
            try Task.checkCancellation()
            guard allowsDirectFallback, Self.canFallback(error) else { throw error }
            // Relay credentials never enter the direct provider or its request headers.
            return try await direct.playback(seriesID: seriesID, episodeID: episodeID, fresh: fresh)
        }
    }

    public func downloadOffline(seriesID: String, episodeID: String, to destination: URL, maximumBytes: Int64,
                                progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        do {
            let source = try await relay.playback(seriesID: seriesID, episodeID: episodeID, fresh: false)
            try await RelayOfflineTransfer.download(source, to: destination, maximumBytes: maximumBytes, progress: progress)
        } catch {
            try Task.checkCancellation()
            guard allowsDirectFallback, Self.canFallback(error), let native = direct as? NativeCatalogService else { throw error }
            try await native.downloadOffline(seriesID: seriesID, episodeID: episodeID, to: destination,
                                             maximumBytes: maximumBytes, progress: progress)
        }
    }

    static func canFallback(_ error: any Error) -> Bool {
        switch error as? CatalogError {
        case .network: return true
        case .httpStatus(let status): return [404, 408, 429, 500, 502, 503, 504, 507].contains(status)
        default: return false
        }
    }
}
