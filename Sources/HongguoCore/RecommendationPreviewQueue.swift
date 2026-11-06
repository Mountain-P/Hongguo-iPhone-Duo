import Foundation

/// A bounded cursor over real catalogue pages. Previewing never mutates a user's library.
public struct RecommendationPreviewQueue: Sendable {
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
        generation = UUID(); pendingPage = nil; seenIDs = []
        items = []; currentIndex = nil; page = 0; hasMore = true
    }

    public mutating func beginPageRequest() -> PageRequest? {
        guard pendingPage == nil, hasMore, page < Self.maximumPages else { return nil }
        let request = PageRequest(page: page + 1, generation: generation)
        pendingPage = request
        return request
    }

    /// False means the request was cancelled or belongs to a replaced source.
    @discardableResult
    public mutating func receive(_ result: SeriesPage, for request: PageRequest) throws -> Bool {
        guard pendingPage == request, request.generation == generation else { return false }
        guard result.page == request.page, result.items.count <= Self.maximumPageItems else {
            throw CatalogError.malformedResponse
        }
        for series in result.items {
            try validateID(series.id)
            guard !series.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CatalogError.malformedResponse }
        }
        var seen = seenIDs
        let additions = result.items.filter { seen.insert($0.id).inserted }
        guard seen.count <= Self.maximumSeenIDs else { throw CatalogError.responseTooLarge }
        var combined = items + additions
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
