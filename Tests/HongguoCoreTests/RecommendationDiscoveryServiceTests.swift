import Foundation
import Testing
@testable import HongguoCore

struct RecommendationDiscoveryServiceTests {
    @Test func firstPageReturnsOnlyTheBaseWhileSupplementalWorkersAreStillBlocked() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: false)])
        let side = SideProbe()
        let service = RecommendationDiscoveryService(base: base, category: .realDrama,
            ranking: { try await side.ranking($0) }, releases: { try await side.releases($0) })
        let first = try await service.home(page: 1)
        #expect(first.items.map(\.id) == ["1"] && first.hasMore)
        #expect(side.cancellations.count == 0)
        let labels = await service.provenance(for: ["1"])
        #expect(labels["1"]?.source == .category)
        let next = Task { try await service.home(page: 2) }
        try await wait { await side.pendingCount == 2 }
        await side.releaseRank(ids: ["10"])
        await side.releaseNew(ids: ["20"])
        let second = try await next.value
        #expect(second.items.map(\.id) == ["10", "20"] && !second.hasMore)
        #expect(await base.homeRequests == [1])
    }

    @Test func eachCategoryUsesOnlyItsOwnBoardAndComicNeverCallsNewReleases() async throws {
        for category in DirectWebService.Category.allCases {
            let base = BaseProbe([1: page(1, ["1"], more: false)])
            let calls = SideCalls()
            let service = RecommendationDiscoveryService(base: base, category: category,
                ranking: { board in await calls.rank(board); return discovery(["10"]) },
                releases: { kind in await calls.new(kind); return discovery(["20"]) })
            _ = try await service.home(page: 1)
            let result = try await service.home(page: 2)
            let expected: DiscoveryRanking = category == .realDrama ? .realDrama : category == .comicDrama ? .comicDrama : .aiDrama
            #expect(await calls.boards == [expected])
            if category == .comicDrama {
                #expect(await calls.newCategories.isEmpty)
                #expect(result.items.map(\.id) == ["10"])
            } else {
                #expect(await calls.newCategories == [category == .realDrama ? .realDrama : .aiDrama])
            }
            let labels = await service.provenance(for: result.items.map(\.id))
            #expect(labels.values.allSatisfy { $0.category == category })
        }
    }

    @Test func crossSourceDuplicatesAreStableAndDoNotModifyOriginalTagsOrBadges() async throws {
        let base = BaseProbe([1: page(1, ["1", "2"], more: true), 2: page(2, ["2", "3"], more: false)])
        let service = RecommendationDiscoveryService(base: base, category: .realDrama,
            ranking: { _ in discovery(["2", "4", "5"]) }, releases: { _ in discovery(["4", "6"]) })
        let first = try await service.home(page: 1), next = try await service.home(page: 2)
        #expect(first.items.map(\.id) == ["1", "2"])
        #expect(next.items.map(\.id) == ["3", "4", "6", "5"])
        #expect(Set((first.items + next.items).map(\.id)).count == 6)
        #expect(next.items.allSatisfy { $0.tags == ["原題材"] && $0.badge == "原標籤" })
        let labels = await service.provenance(for: ["3", "4", "5", "6", "unknown"])
        #expect(labels["3"]?.source == .category && labels["4"]?.source == .newRelease)
        #expect(labels["5"]?.source == .ranking && labels["6"]?.source == .newRelease)
        #expect(labels["unknown"] == nil)
        #expect(try await service.home(page: 2) == next)
        #expect(await base.homeRequests == [1, 2])
    }

    @Test func fullBasePagesAndBothSidePoolsDrainWithoutDroppingItemsOrRefetchingAnEndedBase() async throws {
        let base = BaseProbe([1: page(1, numbers(1...100), more: true), 2: page(2, numbers(101...200), more: false)])
        let service = RecommendationDiscoveryService(base: base, category: .realDrama,
            ranking: { _ in discovery(numbers(1001...1060)) }, releases: { _ in discovery(numbers(2001...2060)) })
        var all: [String] = [], more = true, number = 1
        while more {
            let result = try await service.home(page: number)
            #expect(result.items.count <= 100 && result.page == number)
            all += result.items.map(\.id); more = result.hasMore; number += 1
            #expect(number < 20)
        }
        #expect(all.count == 280 && Set(all).count == 280)
        #expect(Set(numbers(1...200)).isSubset(of: Set(all)))
        #expect(await base.homeRequests == [1, 2])
    }

    @Test func failedOrMalformedSideSourcesFallBackToTheBaseAndTerminate() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: true), 2: page(2, ["2"], more: false)])
        let service = RecommendationDiscoveryService(base: base, category: .realDrama,
            ranking: { _ in throw CatalogError.httpStatus(503) },
            releases: { _ in .init(items: [.init(series: Series(id: "bad", title: "invalid"))], page: 9, hasMore: true) })
        _ = try await service.home(page: 1)
        let result = try await service.home(page: 2)
        #expect(result.items.map(\.id) == ["2"] && !result.hasMore)
        #expect(await base.homeRequests == [1, 2])
    }

    @Test func anUncooperativeSideWorkerCannotHoldTheDeadlineOrPublishAfterTimeout() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: false)])
        let side = SideProbe()
        let service = RecommendationDiscoveryService(base: base, category: .realDrama, supplementalTimeout: .seconds(2),
            ranking: { try await side.ranking($0) }, releases: { try await side.releases($0) })
        _ = try await service.home(page: 1)
        // These providers deliberately remain suspended after cancellation. A structured
        // join of the provider tasks would never return from the following request.
        let next = Task { try await service.home(page: 2) }
        try await wait { await side.pendingCount == 2 }
        let result = try await next.value
        #expect(result.items.isEmpty && !result.hasMore)
        #expect(await side.pendingCount == 2)
        await side.releaseRank(ids: ["777"]); await side.releaseNew(ids: ["888"])
        #expect(try await service.home(page: 2) == result)
        #expect(await service.provenance(for: ["777", "888"]).isEmpty)
    }

    @Test func cancellingAPageReturnsBeforeItsUncooperativeBaseAndAllowsRetryOfTheSameCursor() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: true)], blocked: [2])
        let service = plain(base)
        _ = try await service.home(page: 1)
        let cancelled = Task { try await service.home(page: 2) }
        try await wait { await base.pendingCount(2) == 1 }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(await base.pendingCount(2) == 1)
        let retry = Task { try await service.home(page: 2) }
        try await wait { await base.pendingCount(2) == 2 }
        await base.release(2, value: page(2, ["777"], more: false))
        await base.release(2, value: page(2, ["2"], more: false))
        let result = try await retry.value
        #expect(result.items.map(\.id) == ["2"] && !result.hasMore)
        #expect(await service.provenance(for: ["777"]).isEmpty)
        #expect(await base.homeRequests == [1, 2, 2])
    }

    @Test func reloadingPageOneCancelsTheOldSideGenerationWithoutAcceptingItsLateItems() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: false)])
        let side = SideProbe()
        let service = RecommendationDiscoveryService(base: base, category: .comicDrama,
            ranking: { try await side.ranking($0) }, releases: { _ in Issue.record("Comic must not request new releases"); return discovery([]) })
        _ = try await service.home(page: 1)
        let stale = Task { try await service.home(page: 2) }
        try await wait { await side.pendingCount == 1 }
        await base.set(page(1, ["2"], more: false))
        let refreshed = try await service.home(page: 1)
        #expect(refreshed.items.map(\.id) == ["2"])
        await #expect(throws: CancellationError.self) { try await stale.value }
        let next = Task { try await service.home(page: 2) }
        try await wait { await side.pendingCount == 2 }
        await side.releaseRank(ids: ["777"])
        await side.releaseRank(ids: ["888"])
        let result = try await next.value
        #expect(result.items.map(\.id) == ["888"])
        #expect(await service.provenance(for: ["1", "777"]).isEmpty)
    }

    @Test func cancellingTheWaitingConsumerCancelsBothSupplementalWorkers() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: false)]), side = SideProbe()
        let service = RecommendationDiscoveryService(base: base, category: .realDrama,
            ranking: { try await side.ranking($0) }, releases: { try await side.releases($0) })
        _ = try await service.home(page: 1)
        let next = Task { try await service.home(page: 2) }
        try await wait { await side.pendingCount == 2 }
        next.cancel()
        await #expect(throws: CancellationError.self) { try await next.value }
        try await wait { side.cancellations.count == 2 }
        await side.releaseRank(ids: ["777"]); await side.releaseNew(ids: ["888"])
        let retry = try await service.home(page: 2)
        #expect(retry.items.isEmpty && !retry.hasMore)
        #expect(await base.homeRequests == [1])
    }

    @Test func badBasePageDoesNotAdvanceAndOutOfOrderPagesAreRejected() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: true), 2: page(9, ["2"], more: false)])
        let service = plain(base)
        _ = try await service.home(page: 1)
        await #expect(throws: CatalogError.invalidPage) { try await service.home(page: 4) }
        await #expect(throws: CatalogError.malformedResponse) { try await service.home(page: 2) }
        await base.set(page(2, ["2"], more: false))
        #expect(try await service.home(page: 2).items.map(\.id) == ["2"])
        #expect(await base.homeRequests == [1, 2, 2])
    }

    @Test func provenanceAndSourcePaginationStayBounded() async throws {
        let pages = Dictionary(uniqueKeysWithValues: (1...100).map { number in
            (number, page(number, numbers((number * 100)...(number * 100 + 99)), more: true))
        })
        let base = BaseProbe(pages), service = plain(base)
        var ids: [String] = []
        for number in 1...100 {
            let result = try await service.home(page: number)
            ids += result.items.map(\.id)
            #expect(result.hasMore == (number < 100))
        }
        let recent = await service.provenance(for: Array(ids.suffix(512)))
        #expect(recent.count == RecommendationDiscoveryService.maximumProvenanceEntries)
        #expect(await service.provenance(for: Array(ids.prefix(512))).isEmpty)
        await #expect(throws: CatalogError.invalidPage) { try await service.home(page: 101) }
    }

    @Test func searchDetailAndPlaybackStillUseTheCapturedBase() async throws {
        let base = BaseProbe([1: page(1, ["1"], more: false)]), service = plain(base)
        #expect(try await service.search(query: "query", page: 2).items.first?.id == "9")
        #expect(try await service.detail(id: "8").series.id == "8")
        let playback = try await service.playback(seriesID: "8", episodeID: "81", fresh: true)
        #expect(playback.headers["Test"] == "base")
        #expect(await base.forwarded == ["search:query:2", "detail:8", "playback:8:81:true"])
    }

    private func plain(_ base: BaseProbe) -> RecommendationDiscoveryService {
        .init(base: base, category: .realDrama,
              ranking: { _ in throw CatalogError.network }, releases: { _ in throw CatalogError.network })
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Expected source did not enter its controlled barrier")
        throw CancellationError()
    }
}

private func numbers(_ range: ClosedRange<Int>) -> [String] { range.map(String.init) }
private func series(_ id: String) -> Series { .init(id: id, title: "劇\(id)", badge: "原標籤", tags: ["原題材"]) }
private func page(_ number: Int, _ ids: [String], more: Bool) -> SeriesPage { .init(items: ids.map(series), page: number, hasMore: more) }
private func discovery(_ ids: [String]) -> DiscoveryPage {
    .init(items: ids.enumerated().map { .init(series: series($0.element), rank: $0.offset + 1) }, page: 1, hasMore: false)
}

private actor BaseProbe: CatalogService {
    private var pages: [Int: SeriesPage]
    private let blocked: Set<Int>
    private var pending: [Int: [CheckedContinuation<SeriesPage, any Error>]] = [:]
    private(set) var homeRequests: [Int] = []
    private(set) var forwarded: [String] = []
    init(_ pages: [Int: SeriesPage], blocked: Set<Int> = []) { self.pages = pages; self.blocked = blocked }
    func home(page: Int) async throws -> SeriesPage {
        homeRequests.append(page)
        if blocked.contains(page) { return try await withCheckedThrowingContinuation { pending[page, default: []].append($0) } }
        return pages[page] ?? SeriesPage(items: [], page: page, hasMore: false)
    }
    func search(query: String, page: Int) async throws -> SeriesPage { forwarded.append("search:\(query):\(page)"); return .init(items: [series("9")], page: page, hasMore: false) }
    func detail(id: String) async throws -> SeriesDetail { forwarded.append("detail:\(id)"); return .init(series: series(id), episodes: []) }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        forwarded.append("playback:\(seriesID):\(episodeID):\(fresh)")
        return .init(url: URL(string: "https://example.invalid/test.mp4")!, headers: ["Test": "base"])
    }
    func pendingCount(_ page: Int) -> Int { pending[page]?.count ?? 0 }
    func set(_ value: SeriesPage) { pages[value.page] = value }
    func release(_ page: Int, value: SeriesPage) { pending[page]?.removeFirst().resume(returning: value) }
}

private actor SideCalls {
    private(set) var boards: [DiscoveryRanking] = []
    private(set) var newCategories: [NewReleaseCategory] = []
    func rank(_ value: DiscoveryRanking) { boards.append(value) }
    func new(_ value: NewReleaseCategory) { newCategories.append(value) }
}

/// Intentionally does not cooperate with cancellation, until explicitly released.
private actor SideProbe {
    nonisolated let cancellations = CancellationCounter()
    private var ranked: [CheckedContinuation<DiscoveryPage, any Error>] = []
    private var recent: [CheckedContinuation<DiscoveryPage, any Error>] = []
    var pendingCount: Int { ranked.count + recent.count }
    func ranking(_ board: DiscoveryRanking) async throws -> DiscoveryPage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { ranked.append($0) }
        } onCancel: { self.cancellations.increment() }
    }
    func releases(_ category: NewReleaseCategory) async throws -> DiscoveryPage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { recent.append($0) }
        } onCancel: { self.cancellations.increment() }
    }
    func releaseRank(ids: [String]) { ranked.removeFirst().resume(returning: discovery(ids)) }
    func releaseNew(ids: [String]) { recent.removeFirst().resume(returning: discovery(ids)) }
}

private final class CancellationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
