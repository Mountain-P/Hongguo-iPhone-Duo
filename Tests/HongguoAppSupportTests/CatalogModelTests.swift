import Foundation
import Testing
import HongguoCore
@testable import HongguoAppSupport

@MainActor
struct CatalogModelTests {
    @Test func aDuplicatePageDoesNotHideValidLaterResults() async {
        let service = CatalogPageProbe(pages: [
            1: .init(items: [series("10")], page: 1, hasMore: true),
            2: .init(items: [series("10")], page: 2, hasMore: true),
            3: .init(items: [series("20")], page: 3, hasMore: false)
        ])
        let model = CatalogModel()
        await model.load(service: service)
        await model.load(service: service)
        #expect(model.items.map(\.id) == ["10"])
        #expect(model.hasMore)
        await model.load(service: service)
        #expect(model.items.map(\.id) == ["10", "20"])
        #expect(!model.hasMore)
        #expect(await service.calls == [1, 2, 3])
    }

    @Test func aFailedPageKeepsExistingItemsAndRetriesThatPage() async {
        let service = CatalogPageProbe(pages: [
            1: .init(items: [series("10")], page: 1, hasMore: true),
            2: .init(items: [series("20")], page: 2, hasMore: false)
        ], failOnce: [2])
        let model = CatalogModel()
        await model.load(service: service)
        await model.load(service: service)
        #expect(model.items.map(\.id) == ["10"])
        #expect(model.error != nil)
        #expect(model.hasMore)
        await model.load(service: service)
        #expect(model.items.map(\.id) == ["10", "20"])
        #expect(model.error == nil)
        #expect(await service.calls == [1, 2, 2])
    }

    @Test func cancellingAndReplacingASourceRejectsTheOldReply() async {
        let old = CatalogPageProbe(pages: [1: .init(items: [series("10")], page: 1, hasMore: true)], suspendFirst: true)
        let replacement = CatalogPageProbe(pages: [1: .init(items: [series("90")], page: 1, hasMore: false)])
        let model = CatalogModel()
        let request = Task { await model.load(service: old) }
        await old.waitForRequest()
        model.cancel()
        await model.load(service: replacement, reset: true)
        await old.release()
        await request.value
        #expect(model.items.map(\.id) == ["90"])
        #expect(!model.hasMore)
        #expect(!model.isLoading)
        #expect(model.error == nil)
    }

    @Test func wrongPageCannotAdvanceTheCursorOrReplaceResults() async {
        let wrong = CatalogPageProbe(pages: [1: .init(items: [series("10")], page: 2, hasMore: false)])
        let valid = CatalogPageProbe(pages: [1: .init(items: [series("20")], page: 1, hasMore: false)])
        let model = CatalogModel()
        await model.load(service: wrong)
        #expect(model.items.isEmpty)
        #expect(model.error != nil)
        await model.load(service: valid)
        #expect(model.items.map(\.id) == ["20"])
        #expect(await valid.calls == [1])
    }

    @Test func cancelledResetCannotClearTheCurrentCatalogueOrSendARequest() async {
        let service = CatalogPageProbe(pages: [1: .init(items: [series("10")], page: 1, hasMore: false)])
        let model = CatalogModel()
        await model.load(service: service)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await model.load(service: service, reset: true)
        }
        await cancelled.value
        #expect(model.items.map(\.id) == ["10"])
        #expect(await service.calls == [1])
    }

    @Test func repeatingEmptyPagesStayBoundedWithoutSkippingSourcePages() async {
        let service = CatalogPageProbe(pages: [:], endlessEmpty: true)
        let model = CatalogModel()
        for _ in 1...101 { await model.load(service: service) }
        #expect(model.items.isEmpty)
        #expect(!model.hasMore)
        #expect(await service.calls == Array(1...100))
    }

    @Test func successfulEmptyPagesRemainLoadedAcrossACancelAndReturn() async {
        let service = CatalogPageProbe(pages: [
            1: .init(items: [], page: 1, hasMore: true),
            2: .init(items: [], page: 2, hasMore: true),
            3: .init(items: [series("30")], page: 3, hasMore: false)
        ])
        let model = CatalogModel()
        #expect(!model.hasLoadedPage)
        await model.load(service: service)
        await model.load(service: service)
        model.cancel()
        #expect(model.hasLoadedPage)
        #expect(model.items.isEmpty)
        #expect(model.hasMore)
        await model.load(service: service)
        #expect(model.items.map(\.id) == ["30"])
        #expect(await service.calls == [1, 2, 3])
    }

    private func series(_ id: String) -> Series { .init(id: id, title: "合成劇集 \(id)") }
}

private actor CatalogPageProbe: CatalogService {
    let pages: [Int: SeriesPage]
    var failOnce: Set<Int>
    var suspendFirst: Bool
    let endlessEmpty: Bool
    private(set) var calls: [Int] = []
    private var suspended: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(pages: [Int: SeriesPage], failOnce: Set<Int> = [], suspendFirst: Bool = false, endlessEmpty: Bool = false) {
        self.pages = pages; self.failOnce = failOnce; self.suspendFirst = suspendFirst; self.endlessEmpty = endlessEmpty
    }

    func home(page: Int) async throws -> SeriesPage {
        calls.append(page)
        if suspendFirst {
            suspendFirst = false
            await withCheckedContinuation { continuation in
                suspended = continuation
                for waiter in waiters { waiter.resume() }
                waiters = []
            }
        }
        if failOnce.remove(page) != nil { throw CatalogError.network }
        return pages[page] ?? .init(items: [], page: page, hasMore: endlessEmpty)
    }

    func search(query: String, page: Int) async throws -> SeriesPage { try await home(page: page) }
    func detail(id: String) async throws -> SeriesDetail { throw CatalogError.invalidID }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource { throw CatalogError.unavailablePlayback }

    func waitForRequest() async {
        if suspended != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() { suspended?.resume(); suspended = nil }
}
