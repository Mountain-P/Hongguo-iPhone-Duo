import Foundation

/// A bounded cursor over real catalogue pages. Previewing never mutates a user's library.
public struct RecommendationPreviewQueue: Sendable {
    public struct ExclusionChange: Equatable, Sendable {
        public let removedIDs: Set<String>
        public let previousCurrentID: String?
        public let currentID: String?
        public var currentChanged: Bool { previousCurrentID != currentID }
    }
    public struct PageRequest: Hashable, Sendable {
        public let page: Int
        fileprivate let generation: UUID
        private let id: UUID
        fileprivate init(page: Int, generation: UUID) {
            self.page = page; self.generation = generation; id = UUID()
        }
    }

    public private(set) var items: [Series] = []
    public private(set) var currentIndex: Int?
    public private(set) var page = 0
    public private(set) var hasMore = true
    public let capacity: Int
    private var generation = UUID()
    private var pendingPage: PageRequest?
    private var seenIDs: Set<String> = []
    private var excludedIDs: Set<String> = []
    private static let maximumPages = 100
    private static let maximumPageItems = 100
    private static let maximumSeenIDs = 10_000

    public init(capacity: Int = 120) {
        self.capacity = min(max(capacity, Self.maximumPageItems + 1), 500)
    }

    public var current: Series? { currentIndex.flatMap { items.indices.contains($0) ? items[$0] : nil } }
    public var hasPrevious: Bool { currentIndex.map { $0 > 0 } ?? false }
    public var hasNext: Bool { currentIndex.map { $0 + 1 < items.count } ?? false }

    public mutating func reset() {
        generation = UUID(); pendingPage = nil; seenIDs = []; excludedIDs = []
        items = []; currentIndex = nil; page = 0; hasMore = true
    }

    /// A local prefix has no source cursor. The next request is still the real page 1.
    @discardableResult
    public mutating func restoreLocalPrefix(items restored: [Series], currentStableID: String,
                                           preferences: RecommendationPreferences? = nil) throws -> Bool {
        guard items.isEmpty, page == 0, pendingPage == nil,
              !restored.isEmpty, restored.count <= min(capacity, PreviewSessionStore.maximumItems) else {
            throw CatalogError.malformedResponse
        }
        for item in restored {
            try validateID(item.id)
            guard !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogError.malformedResponse }
        }
        guard let originalIndex = restored.firstIndex(where: { $0.id == currentStableID }) else { throw CatalogError.malformedResponse }
        var unique: Set<String> = []
        let allowed = restored.filter { unique.insert($0.id).inserted && (preferences?.allows(seriesID: $0.id) ?? true) }
        guard !allowed.isEmpty else { return false }
        let allowedIDs = Set(allowed.map(\.id))
        let target = allowedIDs.contains(currentStableID) ? currentStableID
            : restored.dropFirst(originalIndex + 1).first(where: { allowedIDs.contains($0.id) })?.id
                ?? restored.prefix(originalIndex).last(where: { allowedIDs.contains($0.id) })?.id
                ?? allowed[0].id
        reset()
        items = allowed; currentIndex = allowed.firstIndex(where: { $0.id == target }) ?? 0
        seenIDs = Set(allowed.map(\.id))
        excludedIDs = Set(preferences?.notInterestedIDs ?? [])
        return true
    }

    public mutating func beginPageRequest() -> PageRequest? {
        guard !Task.isCancelled, pendingPage == nil, hasMore, page < Self.maximumPages else { return nil }
        let request = PageRequest(page: page + 1, generation: generation)
        pendingPage = request
        return request
    }

    /// False means the request was cancelled or belongs to a replaced source.
    @discardableResult
    public mutating func receive(_ result: SeriesPage, for request: PageRequest,
                                 preferences: RecommendationPreferences? = nil,
                                 ranking: @Sendable ([Series]) -> [Series] = { $0 }) throws -> Bool {
        guard pendingPage == request, request.generation == generation else { return false }
        guard result.page == request.page, result.items.count <= Self.maximumPageItems else {
            throw CatalogError.malformedResponse
        }
        for series in result.items {
            try validateID(series.id)
            guard !series.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogError.malformedResponse }
        }
        var seen = seenIDs
        // Source pages still advance when every valid item was excluded by local choices.
        // Reset the queue when restoring/changing choices to revisit previously excluded IDs.
        let additions = result.items.filter {
            seen.insert($0.id).inserted && !excludedIDs.contains($0.id)
                && (preferences?.allows(seriesID: $0.id) ?? true)
        }
        guard seen.count <= Self.maximumSeenIDs else { throw CatalogError.responseTooLarge }
        // The current and visited cards remain anchored to their stable IDs.
        // Local ranking only changes a newly arrived batch after validation.
        let allowedIDs = Set(additions.map(\.id))
        var rankedIDs: Set<String> = []
        let ranked = ranking(additions).filter { allowedIDs.contains($0.id) && rankedIDs.insert($0.id).inserted }
        var combined = items + ranked
        var index = currentIndex ?? (combined.isEmpty ? nil : 0)
        if combined.count > capacity {
            let removeCount = combined.count - capacity
            // Never evict the current card or unvisited future cards to satisfy a prefetch.
            guard let current = index, removeCount <= current else { throw CatalogError.responseTooLarge }
            combined.removeFirst(removeCount)
            index = current - removeCount
        }
        items = combined; currentIndex = index; seenIDs = seen; page = result.page
        hasMore = result.hasMore && page < Self.maximumPages && seen.count < Self.maximumSeenIDs
        pendingPage = nil
        return true
    }

    public mutating func cancelPageRequest() { pendingPage = nil }

    /// Remove only explicit dislikes in place. Preview exposure never removes an existing card.
    /// The pending source page, its cursor and seen IDs remain valid; even a stale page caller
    /// without a fresh preferences snapshot cannot reinsert a currently excluded work.
    @discardableResult
    public mutating func excludeNotInterested(using preferences: RecommendationPreferences) -> ExclusionChange {
        excludedIDs = Set(preferences.notInterestedIDs)
        let previous = current?.id
        let removed = Set(items.filter { excludedIDs.contains($0.id) }.map(\.id))
        guard !removed.isEmpty else {
            return .init(removedIDs: [], previousCurrentID: previous, currentID: previous)
        }
        var replacement = previous
        if let index = currentIndex, let previous, removed.contains(previous) {
            replacement = items.dropFirst(index + 1).first(where: { !removed.contains($0.id) })?.id
                ?? items.prefix(index).last(where: { !removed.contains($0.id) })?.id
        }
        items.removeAll { removed.contains($0.id) }
        currentIndex = replacement.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        return .init(removedIDs: removed, previousCurrentID: previous, currentID: current?.id)
    }

    /// Scroll positions use stable series IDs; trimming older cards cannot retarget one.
    @discardableResult
    public mutating func select(seriesID: String) -> Series? {
        guard let index = items.firstIndex(where: { $0.id == seriesID }) else { return nil }
        currentIndex = index
        return items[index]
    }

    @discardableResult
    public mutating func move(by offset: Int) -> Series? {
        guard (-1...1).contains(offset), let index = currentIndex else { return nil }
        let next = index + offset
        guard items.indices.contains(next) else { return nil }
        currentIndex = next
        return items[next]
    }

    /// A preview is episode 1; an unavailable first episode never silently becomes episode 2.
    public static func firstEpisode(in detail: SeriesDetail, expectedSeriesID: String) throws -> Episode {
        guard detail.series.id == expectedSeriesID else { throw CatalogError.malformedResponse }
        guard let episode = detail.episodes.first(where: { $0.number == 1 && $0.isAvailable }) else {
            throw CatalogError.unavailablePlayback
        }
        return episode
    }
}
