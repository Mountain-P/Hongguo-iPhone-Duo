// SPDX-License-Identifier: GPL-3.0-only
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import HongguoCore

private actor ArtistTransport: HTTPTransport {
    let body: Data
    let status: Int
    private(set) var requests: [URLRequest] = []
    init(_ body: String, status: Int = 200) { self.body = Data(body.utf8); self.status = status }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ArtistCancellationTransport: HTTPTransport {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true; waiters.forEach { $0.resume() }; waiters.removeAll()
        try await Task.sleep(for: .seconds(30))
        throw CatalogError.network
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

struct ArtistDiscoveryTests {
    @Test func artistUsesOfficialBoundProfileAndPreservesPublicWorkOrder() async throws {
        let transport = ArtistTransport(try artistHTML())
        let profile = try await ArtistDiscoveryService(transport: transport).artist(id: "200")
        #expect(profile.artist == Artist(id: "200", name: "測試演員", avatar: "https://p3-novel.byteimg.com/avatar.image", role: "演員"))
        #expect(profile.biography == "來源提供的公開介紹")
        #expect(profile.works.map(\.id) == ["302", "301"])
        #expect(profile.works[0].tags == ["都市"])
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://hongguoduanju.com/character/200")
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func profileRejectsWrongPersonMalformedRowsAndInvalidRequestIDs() async throws {
        for html in [try artistHTML(person: "201"), try artistHTML(userPerson: "201"),
                     try artistHTML(rows: Array(repeating: artistWork("301"), count: 501)),
                     try artistHTML(rows: [["series_id": "../300", "series_title": "invalid"]])] {
            #expect(throws: CatalogError.malformedResponse) { try ArtistDiscoveryParser.artist(html: html, id: "200") }
        }
        let transport = ArtistTransport(try artistHTML())
        let service = ArtistDiscoveryService(transport: transport)
        await #expect(throws: CatalogError.invalidID) { try await service.artist(id: "../200") }
        #expect(await transport.requests.isEmpty)
        let denied = ArtistDiscoveryService(transport: ArtistTransport("", status: 403))
        await #expect(throws: CatalogError.httpStatus(403)) { try await denied.artist(id: "200") }
    }

    @Test func existingDetailLoadsCastSocialAndOnlyOfficialRelatedWithoutExtraHTTP() async throws {
        let html = try enrichedDetailHTML()
        let transport = ArtistTransport(html)
        let detail = try await NativeCatalogService(transport: transport).detail(id: "100")
        #expect(await transport.requests.count == 1)
        #expect(detail.episodes.map(\.id) == ["101", "102"])
        let metadata = try #require(detail.discovery)
        #expect(metadata.artists == [.init(id: "200", name: "測試演員", avatar: "https://p3-novel.byteimg.com/avatar.image", role: "饰 主角")])
        #expect(metadata.related.map(\.id) == ["302", "301"])
        #expect(!metadata.related.contains { $0.id == "999" || $0.id == "100" })
        #expect(metadata.ratingText == "9.5")
        #expect(metadata.heatText == "123萬熱度")
        #expect(metadata.likeText == "1,234")
        #expect(metadata.favoriteText == "1")
        #expect(metadata.releaseText == "2024-01-01")
        let website = try WebsiteParser.detail(html: html, seriesID: "100")
        #expect(website.discovery == metadata)
        #expect(website.episodes.map(\.isAvailable) == [true, false])
    }

    @Test func malformedOptionalEnrichmentNeverBreaksPrimaryEpisodesOrInventsRelated() throws {
        for deferred in ["<script data-fn-name='mergeLoaderData' data-fn-args='invalid-json'></script>",
                         try recommendationScript(route: "wrong-route"),
                         try recommendationScript(key: "wrong-key"),
                         try recommendationScript(groups: ["hot_list": [artistWork("999")]])] {
            let html = try enrichedDetailHTML(deferred: deferred)
            let detail = try NativeCatalogParser.detail(html: html, seriesID: "100").detail
            #expect(detail.episodes.map(\.id) == ["101", "102"])
            #expect(detail.discovery?.related.isEmpty == true)
            #expect(detail.discovery?.artists.first?.id == "200")
            #expect(detail.discovery?.ratingText == "9.5")
        }
    }

    @Test func unsafeOrUnreliableMetadataIsOmittedAndWrongSeriesStillFails() throws {
        var raw = detailSection()
        var series = raw["seriesDetail"] as! [String: Any]
        series["first_visible_time"] = "1704038400000" // milliseconds must not be mistaken for seconds.
        series["celebrities"] = [["celebrity_id": "../200", "nickname": "invalid"],
                                  ["celebrity_id": "201", "nickname": "安全名字", "avatar": "https://user:secret@example.test/a", "sub_title": "來源角色"]]
        raw["seriesDetail"] = series
        raw["seriesSocialInfo"] = ["rating": 999, "series_like_count": true, "series_favorite_count": -1]
        let html = try routerHTML(["detail_page": raw])
        let metadata = try ArtistDiscoveryParser.metadata(html: html, seriesID: "100")
        #expect(metadata.ratingText.isEmpty && metadata.likeText.isEmpty && metadata.favoriteText.isEmpty && metadata.releaseText.isEmpty)
        #expect(metadata.artists.count == 1 && metadata.artists[0].avatar.isEmpty)
        #expect(metadata.artists[0].role == "來源角色")
        #expect(throws: CatalogError.malformedResponse) { try ArtistDiscoveryParser.metadata(html: html, seriesID: "999") }
    }

    @Test func olderSavedDetailsDecodeWithoutDiscoveryAndNewMetadataRoundTrips() throws {
        let old = Data(#"{"series":{"id":"100","title":"舊紀錄","cover":"","description":"","badge":"","tags":[]},"episodes":[]}"#.utf8)
        #expect(try JSONDecoder().decode(SeriesDetail.self, from: old).discovery == nil)
        let detail = try WebsiteParser.detail(html: enrichedDetailHTML(), seriesID: "100")
        #expect(try JSONDecoder().decode(SeriesDetail.self, from: JSONEncoder().encode(detail)) == detail)
    }

    @Test func cancellingArtistRequestPropagatesCancellation() async throws {
        let transport = ArtistCancellationTransport()
        let service = ArtistDiscoveryService(transport: transport)
        let task = Task { try await service.artist(id: "200") }
        await transport.waitUntilStarted(); task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private func artistWork(_ id: String) -> [String: Any] {
    ["series_id": id, "series_title": "來源作品 \(id)", "series_cover": "https://p3-novel.byteimg.com/cover.image",
     "series_intro": "來源簡介", "episode_cnt": 12, "category_list": [["category_id": "1", "name": "都市"]]]
}

private func artistHTML(person: String = "200", userPerson: String = "200", rows: [[String: Any]]? = nil) throws -> String {
    try routerHTML(["character_(id)/page": ["person_id": person, "req": ["isSuccess": true],
        "userInfo": ["person_id": userPerson, "user_name": "測試演員", "user_avatar": "https://p3-novel.byteimg.com/avatar.image",
                     "description": "來源提供的公開介紹", "subtitle_list": ["演員"]],
        "videoList": rows ?? [artistWork("302"), artistWork("301"), artistWork("302")]]])
}

private func detailSection() -> [String: Any] {
    ["isSuccess": true, "seriesDetail": ["series_id": "100", "series_name": "測試短劇", "vid_list": ["101", "102"],
        "accessible_episode_cnt": 1, "first_visible_time": "1704038400", "celebrities": [
            ["celebrity_id": "200", "nickname": "測試演員", "avatar": "https://p3-novel.byteimg.com/avatar.image", "sub_title": "饰 主角"],
            ["celebrity_id": "200", "nickname": "重複演員"]]],
     "recommendations": [:], "seriesSocialInfo": ["rating": 9.5, "hot_score_data": ["text": "123萬熱度"],
                                                    "series_like_count": 1234, "series_favorite_count": 1]]
}

private func enrichedDetailHTML(deferred: String? = nil) throws -> String {
    try routerHTML(["detail_page": detailSection()]) + (deferred ?? recommendationScript())
}

private func recommendationScript(route: String = "detail_page", key: String = "recommendations", groups: [String: Any]? = nil) throws -> String {
    let groups = groups ?? ["related_list": [artistWork("302"), artistWork("100"), artistWork("301"), artistWork("302")],
                            "hot_list": [artistWork("999")]]
    let payload: [String: Any] = ["recommendationGroups": groups, "videoList": [artistWork("999")]]
    let encoded = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
    let args: [Any] = [route, [["key": key, "routerDataFnName": "p", "routerDataFnArgs": [encoded]]]]
    let attribute = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
        .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    return "<script data-fn-name='mergeLoaderData' data-fn-args='\(attribute)'></script>"
}

private func routerHTML(_ loader: [String: Any]) throws -> String {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: ["loaderData": loader]), as: UTF8.self)
    return "<script>window._ROUTER_DATA = \(json);</script>"
}
