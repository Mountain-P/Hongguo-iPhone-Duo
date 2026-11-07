import Foundation
import Combine
import HongguoCore

struct RecommendationFeedMedia: Identifiable {
    let id = UUID()
    let series: Series
    let episode: Episode
    let service: any CatalogService
}


@MainActor
final class RecommendationPreviewModel: ObservableObject {
    @Published private(set) var queue = RecommendationPreviewQueue()
    @Published private(set) var media: [String: RecommendationFeedMedia] = [:]
    @Published private(set) var reasonByID: [String: String] = [:]
    @Published private(set) var sourceLabelByID: [String: String] = [:]
    private(set) var rankingScope: LibraryScope?
    private var rankingProfile: PersonalizedRecommendationProfile?
    @Published private(set) var lease: RecommendationFeedActivation.Lease?
    @Published private(set) var loadingID: String?
    @Published private(set) var detailErrors: [String: String] = [:]
    @Published private(set) var isLoadingPage = false
    @Published private(set) var pageError: String?
    private(set) var revision: UUID?
    private(set) var filterRevision: UUID?
    private var preferences = RecommendationPreferences()
    private var catalogue: (any CatalogService)?
    private var playback: (any CatalogService)?
    private var activation = RecommendationFeedActivation()
    private var catalogueGeneration = UUID()
    private(set) var catalogueTask: Task<Void, Never>?
    private(set) var detailTask: Task<Void, Never>?
    private var detailGeneration = UUID()
    private var recentMediaIDs: [String] = []
    private let prefetcher = NativePlaybackPrefetch()
    private(set) var prefetchTask: Task<Void, Never>?
    private var prefetchSeriesID: String?
    private var prefetchGeneration = UUID()
    private var prefetchAllowed = false
    private var startedPreviewIDs: Set<String> = []

    var items: [Series] { queue.items }
    var current: Series? { queue.current }

    func configure(revision: UUID, filterRevision: UUID, preferences: RecommendationPreferences,
                   profile: PersonalizedRecommendationProfile, scope: LibraryScope,
                   catalogue: any CatalogService, playback: any CatalogService) {
        invalidateSource()
        self.revision = revision; self.filterRevision = filterRevision; self.preferences = preferences
        rankingScope = scope; rankingProfile = profile
        self.catalogue = catalogue; self.playback = playback
    }

    func updatePreferences(_ preferences: RecommendationPreferences) { self.preferences = preferences }

    @discardableResult
    func excludeNotInterested(_ preferences: RecommendationPreferences,
                              preferredCurrentID: String? = nil) -> RecommendationPreviewQueue.ExclusionChange {
        self.preferences = preferences
        if let preferredCurrentID { queue.select(seriesID: preferredCurrentID) }
        let change = queue.excludeNotInterested(using: preferences)
        if let lease, preferences.isNotInterested(seriesID: lease.seriesID)
            || (change.currentChanged && lease.seriesID != change.currentID) {
            activation.invalidate(); self.lease = nil
            detailGeneration = UUID(); detailTask?.cancel(); detailTask = nil; loadingID = nil
        }
        if change.currentChanged || prefetchSeriesID.map({ preferences.isNotInterested(seriesID: $0) }) == true {
            cancelAdjacentPrefetch()
        }
        pruneMedia(); refreshReasons()
        if let lease, startedPreviewIDs.contains(lease.seriesID) { prepareAdjacent(to: lease) }
        return change
    }

    func updateRankingProfile(_ profile: PersonalizedRecommendationProfile, scope: LibraryScope) {
        guard rankingScope == scope, rankingProfile != profile else { return }
        rankingProfile = profile
        refreshReasons()
    }

    private func refreshReasons() {
        guard let rankingScope, let rankingProfile else { reasonByID = [:]; return }
        var reasons: [String: String] = [:]
        for item in PersonalizedRecommendation.rank(queue.items, using: rankingProfile, scope: rankingScope) {
            if let reason = item.reason { reasons[item.series.id] = reason.displayText }
        }
        // Updating explanations never changes the queue's current card or source pagination.
        reasonByID = reasons
    }

    func configureFailure(_ error: any Error, revision: UUID) {
        invalidateSource(); self.revision = revision; pageError = error.localizedDescription
    }

    func invalidateSource() {
        suspend(); queue.reset(); media = [:]; recentMediaIDs = []; detailErrors = [:]; startedPreviewIDs = []
        revision = nil; filterRevision = nil; catalogue = nil; playback = nil; pageError = nil
        rankingScope = nil; rankingProfile = nil; reasonByID = [:]; sourceLabelByID = [:]
    }

    func suspend() {
        cancelAdjacentPrefetch()
        activation.invalidate(); lease = nil
        detailGeneration = UUID()
        detailTask?.cancel(); detailTask = nil; loadingID = nil
        catalogueGeneration = UUID(); catalogueTask?.cancel(); catalogueTask = nil
        queue.cancelPageRequest(); isLoadingPage = false
    }

    func update(selectedID: String?, isIdle: Bool, isActive: Bool, isSceneActive: Bool, isDetailPresented: Bool) {
        let validID = selectedID.flatMap { id in queue.items.contains(where: { $0.id == id }) ? id : nil }
        let next = activation.update(selectedID: validID, isIdle: isIdle, isActive: isActive,
                                     isSceneActive: isSceneActive, isDetailPresented: isDetailPresented)
        guard next != lease else { return }
        cancelAdjacentPrefetch()
        detailGeneration = UUID()
        detailTask?.cancel(); detailTask = nil; loadingID = nil
        lease = next
        guard let next else { return }
        queue.select(seriesID: next.seriesID)
        prepare(next)
        loadMoreIfNeeded()
    }

    func retry(seriesID: String) {
        guard let lease, lease.seriesID == seriesID else { return }
        detailTask?.cancel(); detailTask = nil
        media.removeValue(forKey: seriesID); detailErrors.removeValue(forKey: seriesID)
        prepare(lease)
    }

    func loadInitial() {
        guard items.isEmpty, queue.hasMore else { return }
        loadPage()
    }

    /// Only an explicit reload restarts a fully consumed empty catalogue.
    func reloadEmptyCatalogue() {
        guard items.isEmpty else { return }
        suspend(); queue.reset(); pageError = nil
        loadInitial()
    }

    func loadMoreIfNeeded(force: Bool = false) {
        guard queue.hasMore,
              force || queue.currentIndex.map({ $0 >= max(queue.items.count - 3, 0) }) == true else { return }
        loadPage()
    }

    private func loadPage() {
        guard let catalogue, let profile = rankingProfile, let scope = rankingScope,
              catalogueTask == nil, queue.hasMore else { return }
        let request = catalogueGeneration
        let previousTail = queue.items.last?.id
        isLoadingPage = true; pageError = nil
        catalogueTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.catalogueGeneration == request { self.isLoadingPage = false; self.catalogueTask = nil }
            }
            do {
                for _ in 0..<3 {
                    // A cancelled task can start after a replacement configured the queue.
                    // Reject it before it can claim that replacement's pending page.
                    try Task.checkCancellation()
                    guard self.catalogueGeneration == request else { return }
                    guard let pageRequest = self.queue.beginPageRequest() else { return }
                    let result = try await catalogue.home(page: pageRequest.page)
                    try Task.checkCancellation()
                    guard self.catalogueGeneration == request else { return }
                    let origins = await (catalogue as? any RecommendationProvenanceProviding)?.provenance(for: result.items.map(\.id)) ?? [:]
                    try Task.checkCancellation()
                    guard self.catalogueGeneration == request else { return }
                    guard try self.queue.receive(result, for: pageRequest, preferences: self.preferences, ranking: {
                        PersonalizedRecommendation.rank($0, using: profile, scope: scope).map(\.series)
                    }) else { throw CancellationError() }
                    for item in result.items {
                        if let origin = origins[item.id], origin.source != .category {
                            self.sourceLabelByID[item.id] = origin.label
                        }
                    }
                    self.refreshReasons()
                    self.pruneMedia()
                    if self.queue.items.last?.id != previousTail || !self.queue.hasMore { return }
                }
                self.pageError = "這幾頁沒有符合偏好的新劇，可載入更多或調整推薦偏好。"
            } catch is CancellationError {
                if self.catalogueGeneration == request { self.queue.cancelPageRequest() }
            } catch {
                guard self.catalogueGeneration == request, !Task.isCancelled else { return }
                self.queue.cancelPageRequest(); self.pageError = error.localizedDescription
            }
        }
    }

    private func prepare(_ lease: RecommendationFeedActivation.Lease) {
        guard let playback, isRetained(seriesID: lease.seriesID) else { return }
        if media[lease.seriesID] != nil {
            touch(lease.seriesID)
            if startedPreviewIDs.contains(lease.seriesID) { prepareAdjacent(to: lease) }
            return
        }
        detailGeneration = UUID()
        let request = detailGeneration
        loadingID = lease.seriesID; detailErrors.removeValue(forKey: lease.seriesID)
        detailTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activation.accepts(lease), self.detailGeneration == request {
                    self.loadingID = nil; self.detailTask = nil
                }
            }
            do {
                try Task.checkCancellation()
                guard self.activation.accepts(lease), self.detailGeneration == request,
                      self.isRetained(seriesID: lease.seriesID) else { return }
                let detail: SeriesDetail
                if let bridge = playback as? BridgeService { detail = try await bridge.verifiedDetail(id: lease.seriesID) }
                else { detail = try await playback.detail(id: lease.seriesID) }
                try Task.checkCancellation()
                guard self.activation.accepts(lease), self.detailGeneration == request,
                      self.isRetained(seriesID: lease.seriesID) else { return }
                let episode = try RecommendationPreviewQueue.firstEpisode(in: detail, expectedSeriesID: lease.seriesID)
                self.media[lease.seriesID] = RecommendationFeedMedia(series: detail.series, episode: episode, service: playback)
                self.touch(lease.seriesID)
            } catch is CancellationError { return }
            catch {
                if self.activation.accepts(lease), self.detailGeneration == request, !Task.isCancelled {
                    self.detailErrors[lease.seriesID] = error.localizedDescription
                }
            }
        }
    }

    private func touch(_ id: String) {
        recentMediaIDs.removeAll { $0 == id }; recentMediaIDs.append(id)
        while recentMediaIDs.count > 3 { media.removeValue(forKey: recentMediaIDs.removeFirst()) }
        pruneMedia()
    }

    private func pruneMedia() {
        let retained = Set(queue.items.map(\.id))
        media = media.filter { retained.contains($0.key) }
        recentMediaIDs.removeAll { !retained.contains($0) }
        detailErrors = detailErrors.filter { retained.contains($0.key) }
        startedPreviewIDs.formIntersection(retained)
        sourceLabelByID = sourceLabelByID.filter { retained.contains($0.key) }
    }

    func setPrefetchAllowed(_ allowed: Bool) {
        guard allowed != prefetchAllowed else { return }
        prefetchAllowed = allowed
        if !allowed { cancelAdjacentPrefetch() }
        else if let lease, startedPreviewIDs.contains(lease.seriesID) { prepareAdjacent(to: lease) }
    }

    func didStartPreview(seriesID: String) {
        guard isRetained(seriesID: seriesID) else { return }
        startedPreviewIDs.insert(seriesID)
        guard let lease, lease.seriesID == seriesID else { return }
        prepareAdjacent(to: lease)
    }

    func discardPrefetchCache() {
        cancelAdjacentPrefetch()
        let prefetcher = prefetcher
        Task { await prefetcher.clear() }
    }

    private func cancelAdjacentPrefetch() {
        prefetchGeneration = UUID()
        prefetchTask?.cancel(); prefetchTask = nil; prefetchSeriesID = nil
    }

    private func isRetained(seriesID: String) -> Bool {
        !preferences.isNotInterested(seriesID: seriesID) && queue.items.contains(where: { $0.id == seriesID })
    }

    private func prepareAdjacent(to lease: RecommendationFeedActivation.Lease) {
        guard prefetchAllowed, prefetchTask == nil, let playback,
              let current = items.firstIndex(where: { $0.id == lease.seriesID }), items.indices.contains(current + 1) else { return }
        let next = items[current + 1]
        guard preferences.allows(seriesID: next.id) else { return }
        let request = UUID(); prefetchGeneration = request
        prefetchSeriesID = next.id
        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { if self.prefetchGeneration == request { self.prefetchTask = nil; self.prefetchSeriesID = nil } }
            do {
                // Give active playback first use of the connection and ignore quick flicks.
                try await Task.sleep(for: .milliseconds(400))
                guard self.prefetchAllowed, self.prefetchGeneration == request, self.activation.accepts(lease),
                      self.isRetained(seriesID: next.id) else { return }
                let media: RecommendationFeedMedia
                if let cached = self.media[next.id] { media = cached }
                else {
                    let detail = try await playback.detail(id: next.id)
                    try Task.checkCancellation()
                    guard self.prefetchGeneration == request, self.activation.accepts(lease),
                          self.isRetained(seriesID: next.id) else { return }
                    let episode = try RecommendationPreviewQueue.firstEpisode(in: detail, expectedSeriesID: next.id)
                    media = RecommendationFeedMedia(series: detail.series, episode: episode, service: playback)
                    self.media[next.id] = media; self.touch(next.id)
                }
                try Task.checkCancellation()
                guard self.prefetchAllowed, self.prefetchGeneration == request, self.activation.accepts(lease),
                      self.isRetained(seriesID: next.id) else { return }
                _ = try await self.prefetcher.prepare(seriesID: next.id, episodeID: media.episode.id, service: playback)
            } catch { /* Speculative work never becomes a visible playback error. */ }
        }
    }
}

