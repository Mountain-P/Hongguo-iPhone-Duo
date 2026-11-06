// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private actor DiscoveryTransport: HTTPTransport {
    let body: Data
    let status: Int
    let cancelOnRead: Bool
    var requests: [URLRequest] = []
    init(_ body: String, status: Int = 200, cancelOnRead: Bool = false) {
        self.body = Data(body.utf8); self.status = status; self.cancelOnRead = cancelOnRead
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: [:])!)
    }
}

struct DiscoveryTests {
    private let card: [String: Any] = ["series_id": "7701935931787316286", "series_name": "合成測試", "series_cover": "https://example.test/poster.jpg", "episode_cnt": 102, "tags": ["家庭"]]
    private var rankCard: [String: Any] { ["seriesId": "7701935931787316286", "id": "7701935931787316286", "rank": 1, "title": "合成排行榜", "cover": "https://example.test/poster.jpg", "episodeCount": 102,
        "heatText": "8339万热度", "scoreText": "评分9.5", "statusTags": ["新剧"], "tags": ["家庭"], "episodeVids": ["100", "101", "102"]] }

    @Test func categoryUsesBoundRouteAndReturnsDynamicGenresWithoutChangingCards() async throws {
        let body = try categoryHTML(genre: "romance", page: 2)
        let transport = DiscoveryTransport(body)
        let result = try await WebDiscoveryService(transport: transport).category(category: .realDrama, genre: "romance", page: 2)
        #expect(result.page == 2 && result.hasMore)
        #expect(result.items.map(\.id) == ["7701935931787316286"])
        #expect(result.items.first?.series.badge == "全 102 集")
        #expect(result.genres == [.init(id: "romance", title: "爱情"), .init(id: "sci-fi", title: "科幻")])
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://hongguoduanju.com/category/real-drama/romance?page=2")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        var labeled = card
        labeled["episode_right_text"] = "全102集"
        let normal = try DiscoveryParser.category(html: categoryHTML(rows: [labeled]), category: .realDrama, genre: nil, page: 1)
        #expect(normal.items.first?.series.badge == "全102集")
        #expect(normal.items.first?.statusText == "")
    }

    @Test func invalidGenreAndPageNeverReachTheNetwork() async throws {
        let transport = DiscoveryTransport("unused"), service = WebDiscoveryService(transport: DiscoveryTransport("unused"))
        for slug in ["../rank/hot-drama", "https://attacker.test", "romance?page=2", "爱情", "a\n", String(repeating: "a", count: 81)] {
            await #expect(throws: CatalogError.invalidQuery) { try await WebDiscoveryService(transport: transport).category(category: .realDrama, genre: slug) }
        }
        await #expect(throws: CatalogError.invalidPage) { try await service.ranking(board: .all, page: 0) }
        await #expect(throws: CatalogError.invalidPage) { try await WebDiscoveryService(transport: transport).category(category: .realDrama, page: 101) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func categoryRejectsWrongKindSlugCanonicalAndPage() throws {
        let cases: [String] = [
            try categoryHTML(kind: "ai-drama", genre: "romance", page: 2),
            try categoryHTML(genre: "family", page: 2),
            try categoryHTML(genre: "romance", page: 2, canonical: "/category/ai-drama/romance"),
            try categoryHTML(genre: "romance", page: 2, canonicalURL: "https://attacker.test/category/real-drama/romance"),
            try categoryHTML(genre: "romance", page: 1)
        ]
        for html in cases {
            #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.category(html: html, category: .realDrama, genre: "romance", page: 2) }
        }
        #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.category(html: categoryHTML(genre: "romance"), category: .realDrama, genre: nil, page: 1) }
    }

    @Test func singleQuotedDeferredRankingPreservesOfficialMetadataAndUpdatedText() async throws {
        let html = try rankHTML(singleQuoted: true)
        let transport = DiscoveryTransport(html)
        let page = try await WebDiscoveryService(transport: transport).ranking(board: .all)
        let item = try #require(page.items.first)
        #expect(item.rank == 1)
        #expect(item.heatText == "8339万热度")
        #expect(item.scoreText == "评分9.5")
        #expect(item.statusText == "新剧")
        // episodeVids contains only public samples; explicit episodeCount stays authoritative.
        #expect(item.series.badge == "全 102 集")
        #expect(page.updatedText == "11月7日已更新")
        #expect(page.page == 1 && page.hasMore)
        #expect(await transport.requests.first?.url?.path == "/rank/hot-drama")
    }

    @Test func doubleQuotedNumericEntitiesAndInlineRankingAreAccepted() throws {
        let double = try rankHTML(singleQuoted: false).replacingOccurrences(of: "&quot;", with: "&#34;")
        #expect(try DiscoveryParser.ranking(html: double, board: .all, page: 1).items.count == 1)
        let inline = try rankHTML(board: .comicDrama, page: 2, inline: true)
        let parsed = try DiscoveryParser.ranking(html: inline, board: .comicDrama, page: 2)
        #expect(parsed.page == 2 && parsed.hasMore)
        let merged = try rankHTML(merged: true)
        #expect(try DiscoveryParser.ranking(html: merged, board: .all, page: 1).items.count == 1)
        for board in DiscoveryRanking.allCases {
            #expect(try DiscoveryParser.ranking(html: rankHTML(board: board), board: board, page: 1).items.count == 1)
        }
        let wrongAlias = try rankHTML().replacingOccurrences(of: #""rankKey":"hongguo""#, with: #""rankKey":"real""#)
        #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.ranking(html: wrongAlias, board: .all, page: 1) }
    }

    @Test func rankingNeverAcceptsAnotherRouteContentSlotBoardOrPage() throws {
        for html in [try rankHTML(payloadRoute: "rank_hot-ai-drama/page"), try rankHTML(contentKey: "recommendations"),
                     try rankHTML(board: .aiDrama), try rankHTML(page: 2), try rankHTML(isSuccess: false)] {
            #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.ranking(html: html, board: .all, page: 1) }
        }
        let aliasConflict = rankCard.merging(["id": "999"]) { _, right in right }
        #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.ranking(html: rankHTML(rows: [aliasConflict]), board: .all, page: 1) }
    }

    @Test func rowsAndPayloadSizesAreBoundedAndDuplicateIDsAreCollapsed() throws {
        let repeated = try rankHTML(rows: [rankCard, rankCard])
        #expect(try DiscoveryParser.ranking(html: repeated, board: .all, page: 1).items.count == 1)
        #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.ranking(html: rankHTML(rows: Array(repeating: rankCard, count: 501)), board: .all, page: 1) }
        #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.category(html: categoryHTML(rows: Array(repeating: card, count: 501)), category: .realDrama, genre: nil, page: 1) }
        let tooLarge = String(repeating: " ", count: DiscoveryParser.maximumBytes + 1)
        #expect(throws: CatalogError.malformedResponse) { try DiscoveryParser.category(html: tooLarge, category: .realDrama, genre: nil, page: 1) }
    }

    @Test func explicitHTTPDenialAndCancellationArePreserved() async throws {
        let denied = WebDiscoveryService(transport: DiscoveryTransport("binary-error", status: 403))
        await #expect(throws: CatalogError.httpStatus(403)) { try await denied.ranking(board: .all) }
        let transport = DiscoveryTransport(try rankHTML(), cancelOnRead: true)
        let task = Task { try await WebDiscoveryService(transport: transport).ranking(board: .all) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func deferredHelperBindsRecommendationsToRequestedRouteAndKey() throws {
        let payload: [String: Any] = ["related_list": [card]]
        let direct: [Any] = ["detail_page", "recommendations", payload]
        let merged: [Any] = ["detail_page", [["key": "recommendations", "routerDataFnName": "p", "routerDataFnArgs": [try json(payload)]]]]
        for (name, args) in [("r", direct), ("mergeLoaderData", merged)] {
            let encoded = try json(args).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            let html = "<script data-fn-args='" + encoded + "' data-fn-name='" + name + "'>mustNeverExecute()</script>"
            let parsed = try DiscoveryParser.deferredContent(html, route: "detail_page", key: "recommendations")
            let result = try #require(parsed)
            #expect((result["related_list"] as? [[String: Any]])?.first?["series_id"] as? String == "7701935931787316286")
            #expect(try DiscoveryParser.deferredContent(html, route: "other_detail", key: "recommendations") == nil)
            #expect(try DiscoveryParser.deferredContent(html, route: "detail_page") == nil)
        }
    }

    private func categoryHTML(kind: String = "real-drama", genre: String? = nil, page: Int = 1, canonical: String? = nil, canonicalURL: String? = nil, rows: [[String: Any]]? = nil) throws -> String {
        let path = "/category/" + kind + (genre.map { "/" + $0 } ?? "")
        var route: [String: Any] = ["contentType": kind, "canonicalPath": canonical ?? path]
        if let genre { route["slug"] = genre }
        let data: [String: Any] = ["isSuccess": true, "categoryRoute": route, "canonicalUrl": canonicalURL ?? "https://hongguoduanju.com" + path,
            "pagination": ["pageNum": page, "totalPages": 5], "recommendList": rows ?? [card],
            "selectorList": [["items": [["selector_item_id": "romance", "show_name": "爱情"], ["selector_item_id": "sci-fi", "show_name": "科幻"],
                ["selector_item_id": "romance", "show_name": "duplicate"], ["selector_item_id": "../unsafe", "show_name": "invalid"]]]]]
        return "<script>window._ROUTER_DATA=" + (try json(["loaderData": ["category_$": data]])) + ";throw new Error('must never execute');</script>"
    }

    private func rankHTML(board: DiscoveryRanking = .all, page: Int = 1, inline: Bool = false, singleQuoted: Bool = true,
                          payloadRoute: String? = nil, contentKey: String = "content", isSuccess: Bool = true,
                          rows: [[String: Any]]? = nil, merged: Bool = false) throws -> String {
        let key = "rank_" + board.rawValue + "/page"
        let payload: [String: Any] = ["isSuccess": isSuccess, "rankList": rows ?? [rankCard], "pagination": ["pageNum": page, "totalPages": 5]]
        let aliases: [DiscoveryRanking: String] = [.all: "hongguo", .realDrama: "real", .comicDrama: "comic", .aiDrama: "ai"]
        let base: [String: Any] = ["rankKey": aliases[board]!, "pageNum": page, "updatedText": "11月7日已更新",
            "canonicalUrl": "https://hongguoduanju.com/rank/" + board.rawValue, "content": inline ? payload : [:]]
        let router = "<script>window._ROUTER_DATA=" + (try json(["loaderData": [key: base]])) + ";</script>"
        if inline { return router }
        let args: [Any] = merged ? [payloadRoute ?? key, [["key": contentKey, "routerDataFnName": "p", "routerDataFnArgs": [try json(payload)]]]] : [payloadRoute ?? key, contentKey, payload]
        let encoded = try json(args).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#x27;")
        let quote = singleQuoted ? "'" : "\""
        return router + "<script data-fn-args=" + quote + encoded + quote + " defer data-extra='>' data-fn-name='" + (merged ? "mergeLoaderData" : "r") + "'>notExecuted()</script>"
    }

    private func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
}
