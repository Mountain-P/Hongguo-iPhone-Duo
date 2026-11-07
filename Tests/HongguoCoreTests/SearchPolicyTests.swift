import Foundation
import Testing
@testable import HongguoCore

struct SearchPolicyTests {
    @Test func queryNormalizesWidthButKeepsWordingCaseAndPunctuation() throws {
        #expect(try SearchText.query("  總裁 ＡＩ & 第二季  ") == "總裁 AI & 第二季")
        #expect(try SearchText.query(String(repeating: "劇", count: 80)).count == 80)
        for invalid in ["", " \n ", "劇\n名", "劇\u{0000}名", String(repeating: "劇", count: 81)] {
            #expect(throws: CatalogError.invalidQuery) { try SearchText.query(invalid) }
        }
    }

    @Test func alternateIsOneChineseSpellingAndDoesNotTransliterateOtherScripts() {
        #expect(SearchText.alternateQuery(for: "總裁與龍") == "总裁与龙")
        #expect(SearchText.alternateQuery(for: "总裁与龙") == "總裁與龍")
        #expect(SearchText.alternateQuery(for: "AI 2026 & café") == nil)
        #expect(SearchText.alternateQuery(for: " ") == nil)
    }

    @Test func localComparisonMatchesSimplifiedTraditionalWidthCaseAndWhitespace() {
        #expect(SearchText.comparisonKey("  總裁  ＡＩ\n第二季 ") == SearchText.comparisonKey("总裁 ai 第二季"))
        #expect(SearchText.comparisonKey("龍與愛") == "龙与爱")
        #expect(SearchText.comparisonKey("a&b") != SearchText.comparisonKey("a b"))
        #expect(SearchText.comparisonKey("第2季") != SearchText.comparisonKey("第3季"))
    }

    @Test func originalResultsHavePriorityAndDoNotTriggerAlternateSearch() async throws {
        let service = SearchFixture(pages: ["總裁": [.init(items: [series("10")], page: 1, hasMore: true)]])
        let result = try await SearchQueryPlan(query: "總裁").firstPage(using: service)
        #expect(result.page.items.map(\.id) == ["10"])
        #expect(!result.usedAlternate)
        #expect(result.effectiveQuery == "總裁")
        #expect(await service.calls == [.init(query: "總裁", page: 1)])
    }

    @Test func emptyPageWithMoreSourcePagesKeepsTheOriginalQuery() async throws {
        let service = SearchFixture(pages: ["總裁": [.init(items: [], page: 1, hasMore: true)]])
        let result = try await SearchQueryPlan(query: "總裁").firstPage(using: service)
        #expect(result.page.hasMore)
        #expect(result.effectiveQuery == "總裁")
        #expect(await service.calls.count == 1)
    }

    @Test func aCompleteEmptyResultAllowsExactlyOneSequentialAlternate() async throws {
        let service = SearchFixture()
        let result = try await SearchQueryPlan(query: "總裁").firstPage(using: service)
        #expect(result.page.items.isEmpty)
        #expect(result.usedAlternate)
        #expect(result.originalQuery == "總裁")
        #expect(result.effectiveQuery == "总裁")
        #expect(await service.calls == [.init(query: "總裁", page: 1), .init(query: "总裁", page: 1)])
    }

    @Test func alternateResultCarriesTheQueryNeededForTheNextPage() async throws {
        let service = SearchFixture(pages: ["总裁": [.init(items: [series("10")], page: 1, hasMore: true)]])
        let result = try await SearchQueryPlan(query: "總裁").firstPage(using: service)
        #expect(result.usedAlternate)
        #expect(result.page.items.map(\.id) == ["10"])
        #expect(result.effectiveQuery == "总裁")
        #expect(result.page.hasMore)
        _ = try await service.search(query: result.effectiveQuery, page: 2)
        #expect(await service.calls.last == .init(query: "总裁", page: 2))
    }

    @Test func sourceErrorsAreNotRetriedAsAChangedQuery() async throws {
        for error in [CatalogError.httpStatus(403), .network, .malformedResponse] {
            let service = SearchFixture(failure: error)
            await #expect(throws: error) { try await SearchQueryPlan(query: "總裁").firstPage(using: service) }
            #expect(await service.calls == [.init(query: "總裁", page: 1)])
        }
    }

    @Test func cancellationAfterTheOriginalResponseCannotStartAnAlternate() async throws {
        let service = SearchFixture(cancelOn: "總裁")
        let task = Task { try await SearchQueryPlan(query: "總裁").firstPage(using: service) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await service.calls == [.init(query: "總裁", page: 1)])
        #expect(!Task.isCancelled)
    }

    @Test func cancellationAfterTheAlternateResponseCannotPublishIt() async throws {
        let service = SearchFixture(cancelOn: "总裁")
        let task = Task { try await SearchQueryPlan(query: "總裁").firstPage(using: service) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await service.calls.count == 2)
    }

    @Test func wrongSourcePageIsRejectedBeforeAnyFallback() async throws {
        let service = SearchFixture(responsePage: 2)
        await #expect(throws: CatalogError.malformedResponse) {
            try await SearchQueryPlan(query: "總裁").firstPage(using: service)
        }
        #expect(await service.calls.count == 1)
    }

    @Test func facetsOnlyDescribeExplicitLoadedTagsAndCountEachSeriesOnce() {
        let items = [series("10", tags: ["愛情", "爱情", "都市"]),
                     series("20", tags: ["爱情"]), series("20", tags: ["AI"]), series("30")]
        let facets = SearchResultFiltering.facets(in: items)
        #expect(facets.map(\.title) == ["愛情", "都市"])
        #expect(facets.map(\.count) == [2, 1])
        #expect(!facets.contains { ["真人", "漫劇", "AI"].contains($0.title) })
    }

    @Test func localTagFilteringPreservesOrderAndAllRetainsUntaggedResults() throws {
        let items = [series("30"), series("10", tags: ["愛情"]), series("20", tags: ["爱情"]), series("10", tags: ["都市"])]
        let facet = try #require(SearchResultFiltering.facets(in: items).first)
        #expect(SearchResultFiltering.apply(.tag(facet.id), to: items).map(\.id) == ["10", "20"])
        #expect(SearchResultFiltering.apply(.all, to: items).map(\.id) == ["30", "10", "20"])
        #expect(SearchResultFiltering.apply(.tag("unknown"), to: items).isEmpty)
    }

    @Test func invalidTagsAndFacetLimitsCannotCreateFakeClassifications() {
        let tags = ["", "  ", "都市\n戀愛", String(repeating: "長", count: 41)] + (1...100).map { "題材\($0)" }
        let items = [series("10", tags: tags)]
        #expect(SearchResultFiltering.facets(in: items).count == 24)
        #expect(SearchResultFiltering.facets(in: items, limit: Int.max).count == 48)
        #expect(SearchResultFiltering.facets(in: items, limit: -1).isEmpty)
        #expect(SearchResultFiltering.facets(in: items).first?.title == "題材1")
    }

    private func series(_ id: String, tags: [String] = []) -> Series { .init(id: id, title: "劇\(id)", tags: tags) }
}

private actor SearchFixture: CatalogService {
    struct Call: Equatable, Sendable { let query: String; let page: Int }
    private let pages: [String: [SeriesPage]]
    private let failure: CatalogError?
    private let cancelOn: String?
    private let responsePage: Int?
    private(set) var calls: [Call] = []
    init(pages: [String: [SeriesPage]] = [:], failure: CatalogError? = nil, cancelOn: String? = nil, responsePage: Int? = nil) {
        self.pages = pages; self.failure = failure; self.cancelOn = cancelOn; self.responsePage = responsePage
    }
    func search(query: String, page: Int) async throws -> SeriesPage {
        calls.append(.init(query: query, page: page))
        if let failure { throw failure }
        if cancelOn == query { withUnsafeCurrentTask { $0?.cancel() } }
        var result = pages[query]?.first { $0.page == page } ?? .init(items: [], page: page, hasMore: false)
        if let responsePage { result.page = responsePage }
        return result
    }
    func home(page: Int) async throws -> SeriesPage { throw CatalogError.invalidConfiguration }
    func detail(id: String) async throws -> SeriesDetail { throw CatalogError.invalidID }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource { throw CatalogError.unavailablePlayback }
}
