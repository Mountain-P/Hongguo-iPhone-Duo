import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Standalone catalogue and playback. All network traffic goes directly to the source platform.
/// A listed episode is eligible for a playback request; the playback response can still deny access.
public struct NativeCatalogService: CatalogService {
    private let website: DirectWebService
    private let transport: any HTTPTransport
    private let cache = NativeCatalogCache()
    public private(set) var playbackQuality: NativePlaybackQuality
    private let prepare: @Sendable (_ episodeID: String, _ contentType: String, _ fresh: Bool, _ quality: NativePlaybackQuality) async throws -> PlaybackSource

    public init(category: DirectWebService.Category = .realDrama, transport: any HTTPTransport = URLSessionTransport(),
                quality: NativePlaybackQuality = .automatic) {
        self.website = DirectWebService(category: category, transport: transport)
        self.transport = transport
        self.playbackQuality = quality
        self.prepare = { episodeID, contentType, fresh, quality in
            let source = try await NativeSourceResolver.shared.resolve(episodeID: episodeID, contentType: contentType, fresh: fresh, quality: quality)
            let stream = try await NativeProgressiveMedia.shared.preparePlayback(source: source, episodeID: episodeID, fresh: fresh)
            return PlaybackSource(url: stream.assetURL, nativeStream: stream)
        }
    }

    /// Allows deterministic catalogue/binding tests without registering an identity or downloading media.
    init(category: DirectWebService.Category = .realDrama, transport: any HTTPTransport,
         prepare: @escaping @Sendable (String, String, Bool) async throws -> URL) {
        self.website = DirectWebService(category: category, transport: transport)
        self.transport = transport
        self.playbackQuality = .automatic
        self.prepare = { episodeID, contentType, fresh, _ in
            PlaybackSource(url: try await prepare(episodeID, contentType, fresh))
        }
    }

    init(category: DirectWebService.Category = .realDrama, transport: any HTTPTransport,
         quality: NativePlaybackQuality = .automatic,
         prepareSource: @escaping @Sendable (String, String, Bool, NativePlaybackQuality) async throws -> PlaybackSource) {
        self.website = DirectWebService(category: category, transport: transport)
        self.transport = transport
        self.playbackQuality = quality
        self.prepare = prepareSource
    }

    /// Keeps the same validated catalogue cache and transport while selecting a rendition.
    public func selectingPlaybackQuality(_ quality: NativePlaybackQuality) -> NativeCatalogService {
        var copy = self
        copy.playbackQuality = quality
        return copy
    }

    public func home(page: Int) async throws -> SeriesPage {
        try Task.checkCancellation()
        return try await website.home(page: page)
    }

    public func search(query: String, page: Int) async throws -> SeriesPage {
        try Task.checkCancellation()
        return try await website.search(query: query, page: page)
    }

    public func detail(id: String) async throws -> SeriesDetail {
        try await loadDetail(id: id).detail
    }

    /// Stages a playable MP4 from an available rendition of this exact episode.
    public func downloadOffline(seriesID: String, episodeID: String, to destination: URL, maximumBytes: Int64,
                                progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws {
        try await downloadOffline(seriesID: seriesID, episodeID: episodeID, to: destination, maximumBytes: maximumBytes,
                                  resolve: { episodeID, contentType, quality in
            try await NativeJSRuntime().resolve(episodeID: episodeID, contentType: contentType,
                                                quality: quality, offlineDirect: true)
        }, resolvePlayable: { episodeID, contentType, quality in
            try await NativeJSRuntime().resolve(episodeID: episodeID, contentType: contentType, quality: quality)
        }, downloader: NativeMediaHTTPDownload(), progress: progress)
    }

    func downloadOffline(seriesID: String, episodeID: String, to destination: URL, maximumBytes: Int64,
                         resolve: @Sendable (String, String, NativePlaybackQuality) async throws -> NativeMediaSource,
                         resolvePlayable: (@Sendable (String, String, NativePlaybackQuality) async throws -> NativeMediaSource)? = nil,
                         downloader: any NativeOfflineMediaDownloading,
                         progress: @escaping @Sendable (Int64, Int64?) async -> Void) async throws {
        try validateID(seriesID)
        try validateID(episodeID)
        try Task.checkCancellation()
        let file = try NativeOfflineFile(destination: destination, maximumBytes: maximumBytes)
        let entry: NativeCatalogEntry
        do {
            entry = try await loadDetail(id: seriesID)
        } catch where PlaybackRecovery.shouldRetry(error, attempt: 0) {
            entry = try await loadDetail(id: seriesID)
        }
        guard entry.detail.series.id == seriesID,
              let episode = entry.detail.episodes.first(where: { $0.id == episodeID }) else { throw CatalogError.invalidID }
        guard episode.isAvailable else { throw CatalogError.protectedPlayback }

        func resolveSource() async throws -> NativeMediaSource {
            try Task.checkCancellation()
            do {
                return try await resolve(episodeID, entry.contentType, playbackQuality)
            } catch let error as NativeSourceError where error.code == "OFFLINE_CLEAR_UNAVAILABLE" {
                guard let resolvePlayable else { throw error }
                try Task.checkCancellation()
                return try await resolvePlayable(episodeID, entry.contentType, playbackQuality)
            }
        }

        let source = try await resolveSource()
        do {
            try await file.write(source: source, downloader: downloader, progress: progress)
        } catch where PlaybackRecovery.shouldRetryAssetRead(error) {
            // The writer removed the partial file. Resolve this episode again
            // before opening a fresh file so bytes from two versions cannot mix.
            let refreshed = try await resolveSource()
            try await file.write(source: refreshed, downloader: downloader, progress: progress)
        }
    }

    public func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        try validateID(seriesID)
        try validateID(episodeID)
        try Task.checkCancellation()
        let entry: NativeCatalogEntry
        if let cached = await cache.entry(for: seriesID) { entry = cached }
        else { entry = try await loadDetail(id: seriesID) }
        // Never resolve an arbitrary vid under a different series or infer it from a search card.
        guard entry.detail.series.id == seriesID,
              entry.detail.episodes.contains(where: { $0.id == episodeID }) else { throw CatalogError.invalidID }
        try Task.checkCancellation()
        let source: PlaybackSource
        do {
            source = try await prepare(episodeID, entry.contentType, fresh, playbackQuality)
        } catch let error where !fresh && NativePrefetchContext.maximumBytes == nil &&
            ((error as? NativeMediaError) == .unsafeURL || (error as? NativeProgressiveError) == .changedSource) {
            // Discard the rejected address or inconsistent ranges. A fresh
            // preparation starts over for the same episode and checks every response.
            try Task.checkCancellation()
            source = try await prepare(episodeID, entry.contentType, true, playbackQuality)
        }
        try Task.checkCancellation()
        if let stream = source.nativeStream {
            guard source.url == stream.assetURL, stream.totalLength > 0, source.headers.isEmpty else {
                throw CatalogError.unsafePlaybackURL
            }
            return source
        }
        // Local preparation remains an explicit test/tool path, never a remote URL fallback.
        let url = source.url
        guard url.isFileURL, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw CatalogError.unsafePlaybackURL
        }
        return source
    }

    private func loadDetail(id: String) async throws -> NativeCatalogEntry {
        try validateID(id)
        try Task.checkCancellation()
        var components = URLComponents(url: DirectWebService.siteURL.appendingPathComponent("detail"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "series_id", value: id)]
        var request = URLRequest(url: components.url!)
        request.setValue(DirectWebService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(DirectWebService.siteURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data = try await load(request, using: transport)
        guard let html = String(data: data, encoding: .utf8) else { throw CatalogError.malformedResponse }
        let entry = try NativeCatalogParser.detail(html: html, seriesID: id)
        try Task.checkCancellation()
        await cache.store(entry)
        return entry
    }
}

struct NativeCatalogEntry: Sendable {
    let detail: SeriesDetail
    let contentType: String
}

enum NativeCatalogParser {
    static func detail(html: String, seriesID: String) throws -> NativeCatalogEntry {
        let payload = try WebsiteParser.seriesPayload(html: html, seriesID: seriesID)
        guard let raw = payload["vid_list"] as? [Any], !raw.isEmpty, raw.count <= 5000 else {
            throw CatalogError.malformedResponse
        }
        let ids = raw.map { string($0) }
        try ids.forEach(validateID)
        guard Set(ids).count == ids.count else { throw CatalogError.malformedResponse }
        let contentType = payload["content_type"].map { string($0) } ?? "1004"
        guard (1...16).contains(contentType.utf8.count), contentType.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw CatalogError.malformedResponse
        }
        let series = try WebsiteParser.card(payload)
        // accessible_episode_cnt describes the website preview, not the native model endpoint.
        // Request-time denials from the source are still terminal and propagate to the player.
        let episodes = ids.enumerated().map { Episode(id: $0.element, number: $0.offset + 1, title: "第 \($0.offset + 1) 集") }
        let discovery = try? ArtistDiscoveryParser.metadata(html: html, seriesID: seriesID)
        return NativeCatalogEntry(detail: SeriesDetail(series: series, episodes: episodes, discovery: discovery), contentType: contentType)
    }
}

private actor NativeCatalogCache {
    private var entries: [String: (value: NativeCatalogEntry, created: Date)] = [:]
    private let lifetime: TimeInterval = 300

    func entry(for seriesID: String) -> NativeCatalogEntry? {
        guard let entry = entries[seriesID], Date().timeIntervalSince(entry.created) < lifetime else {
            entries.removeValue(forKey: seriesID)
            return nil
        }
        return entry.value
    }

    func store(_ entry: NativeCatalogEntry) {
        entries[entry.detail.series.id] = (entry, Date())
        while entries.count > 32, let oldest = entries.min(by: { $0.value.created < $1.value.created })?.key {
            entries.removeValue(forKey: oldest)
        }
    }
}
