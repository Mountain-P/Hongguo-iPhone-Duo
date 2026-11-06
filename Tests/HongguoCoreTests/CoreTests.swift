import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HongguoCore

private actor MockTransport: HTTPTransport {
    let body: Data
    let status: Int
    private(set) var requests: [URLRequest] = []

    init(_ body: String, status: Int = 200) { self.body = Data(body.utf8); self.status = status }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!)
    }
}

@MainActor
struct CoreTests {
    @Test
    func testServerConfigurationRejectsCredentialAndCleartextInternetURLs() throws {
        for url in ["https://user:pass@example.com", "https://example.com?token=secret", "https://example.com#secret", "ftp://example.com", "http://example.com", "http://8.8.8.8", "http://172.32.1.1"] {
            expectThrows(try ServerConfiguration(baseURL: url), url)
        }
        for url in ["http://192.168.1.8:8787", "http://10.1.2.3:8787", "http://172.16.1.1", "http://localhost:8787", "http://nas.local:8787", "http://[::1]:8787", "https://example.com/bridge/"] {
            expectNoThrow(try ServerConfiguration(baseURL: url), url)
        }
        expectThrows(try ServerConfiguration(baseURL: "https://example.com", token: "abc\r\nX-Injected: yes"))
        expectEqual(try ServerConfiguration(baseURL: " https://EXAMPLE.com/bridge/// ").baseURL.absoluteString, "https://example.com/bridge")
    }

    @Test
    func testBridgeSearchEncodesKeywordAndPreservesStringIDsAndTags() async throws {
        let transport = MockTransport(#"{"items":[{"id":"90071992547409931234","title":"測試","tags":"都市 · 愛情"}],"page":2}"#)
        let service = BridgeService(configuration: try .init(baseURL: "https://example.com/bridge", token: "test-secret"), transport: transport)
        let result = try await service.search(query: "a&b + c", page: 2)
        expectEqual(result.items[0].id, "90071992547409931234")
        expectEqual(result.items[0].tags, ["都市", "愛情"])
        let requests = await transport.requests
        let request = try unwrap(requests.first)
        let components = try unwrap(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        expectEqual(request.url?.path, "/bridge/api/search")
        expectEqual(components.queryItems?.first(where: { $0.name == "q" })?.value, "a&b + c")
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-secret")
    }

    @Test
    func testBridgeRejectsCrossOriginPlaybackBeforeTokenLeavesService() async throws {
        for path in ["https://attacker.example/video.mp4", "//attacker.example/video.mp4", "http://example.com/video.mp4", "https://user@example.com/video.mp4"] {
            let payload = String(data: try JSONSerialization.data(withJSONObject: ["path": path, "contentType": "video/mp4"]), encoding: .utf8)!
            let transport = MockTransport(payload)
            let service = BridgeService(configuration: try .init(baseURL: "https://example.com", token: "test-secret"), transport: transport)
            do { _ = try await service.playback(seriesID: "100", episodeID: "200", fresh: false); recordFailure(path) }
            catch { expectEqual(error as? CatalogError, .unsafePlaybackURL) }
            let count = await transport.requests.count
            expectEqual(count, 1)
        }
    }

    @Test
    func testBridgePlaybackCarriesTokenAndFreshRequest() async throws {
        let transport = MockTransport(#"{"path":"/api/episodes/200/stream","contentType":"video/mp4"}"#)
        let service = BridgeService(configuration: try .init(baseURL: "https://example.com", token: "test-secret"), transport: transport)
        let source = try await service.playback(seriesID: "100", episodeID: "200", fresh: true)
        expectEqual(source.url.absoluteString, "https://example.com/api/episodes/200/stream")
        expectEqual(source.headers["Authorization"], "Bearer test-secret")
        let requests = await transport.requests
        let request = try unwrap(requests.first)
        expectEqual(request.url?.query, "fresh=1")
    }

    @Test
    func testBridgePlaybackPreservesReverseProxyPrefix() async throws {
        let cases = [
            ("/api/episodes/200/stream", "/bridge/api/episodes/200/stream"),
            ("api/episodes/200/stream", "/bridge/api/episodes/200/stream"),
            ("/bridge/api/episodes/200/stream", "/bridge/api/episodes/200/stream"),
            ("bridge/api/episodes/200/stream", "/bridge/api/episodes/200/stream"),
            ("https://example.com/api/episodes/200/stream", "/api/episodes/200/stream")
        ]
        for (returnedPath, expectedPath) in cases {
            let payload = String(data: try JSONSerialization.data(withJSONObject: ["path": returnedPath, "contentType": "video/mp4"]), encoding: .utf8)!
            let transport = MockTransport(payload)
            let service = BridgeService(configuration: try .init(baseURL: "https://example.com/bridge", token: "test-secret"), transport: transport)
            let source = try await service.playback(seriesID: "100", episodeID: "200", fresh: false)
            expectEqual(source.url.path, expectedPath, returnedPath)
            expectEqual(source.headers["Authorization"], "Bearer test-secret")
        }
        let transport = MockTransport(#"{"path":"/api/episodes/200/stream?test=a%26b","contentType":"video/mp4"}"#)
        let source = try await BridgeService(configuration: .init(baseURL: "https://example.com/bridge"), transport: transport)
            .playback(seriesID: "100", episodeID: "200", fresh: false)
        expectEqual(source.url.path, "/bridge/api/episodes/200/stream")
        expectEqual(URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a&b")
    }

    @Test
    func testInvalidInputMakesNoNetworkRequest() async throws {
        let transport = MockTransport("{}")
        let service = BridgeService(configuration: try .init(baseURL: "https://example.com"), transport: transport)
        do { _ = try await service.detail(id: "../secret"); recordFailure() } catch { expectEqual(error as? CatalogError, .invalidID) }
        do { _ = try await service.search(query: "   ", page: 1); recordFailure() } catch { expectEqual(error as? CatalogError, .invalidQuery) }
        do { _ = try await service.home(page: 0); recordFailure() } catch { expectEqual(error as? CatalogError, .invalidPage) }
        let count = await transport.requests.count
        expectEqual(count, 0)
    }

    @Test
    func testHTTPErrorDoesNotEchoCredentialBearingServerBody() async throws {
        let transport = MockTransport(#"{"error":"https://example.com?token=secret-value"}"#, status: 502)
        let service = BridgeService(configuration: try .init(baseURL: "https://example.com"), transport: transport)
        do { _ = try await service.home(page: 1); recordFailure() }
        catch {
            expectEqual(error as? CatalogError, .httpStatus(502))
            expectFalse(error.localizedDescription.contains("secret-value"))
        }
    }

    @Test
    func testRouterExtractionHandlesBracesInsideEscapedStrings() throws {
        let html = #"<script>window._ROUTER_DATA = {"loaderData":{"message":"a } brace and \"quoted\" { text","next":{"ok":true}}}; someUntrustedFunction();</script>"#
        let object = try WebsiteParser.routerData(html: html)
        let loader = try unwrap(object["loaderData"] as? [String: Any])
        expectEqual(loader["message"] as? String, #"a } brace and "quoted" { text"#)
        expectThrows(try WebsiteParser.routerData(html: "window._ROUTER_DATA = {\"loaderData\":"))
    }

    @Test
    func testCatalogUsesRequestedCategoryAndDeduplicatesCards() throws {
        let html = routerHTML(["category_page": ["categoryRoute": ["contentType": "real-drama"], "recommendList": [webCard(), webCard()], "pagination": ["pageNum": 2, "totalPages": 4]]])
        let page = try WebsiteParser.catalog(html: html, page: 2)
        expectEqual(page.items.count, 1)
        expectEqual(page.items[0].id, "100000000000000001")
        expectTrue(page.hasMore)
        expectThrows(try WebsiteParser.catalog(html: html, category: "comic-drama"))
    }

    @Test
    func testWebsiteSearchDistinguishesEmptyResultsFromChangedSchema() throws {
        let payload = try JSONSerialization.data(withJSONObject: ["searchList": [["video_data": webCard()]], "hasMore": true, "pageNum": 1])
        let page = try WebsiteParser.search(data: payload)
        expectEqual(page.items.first?.tags, ["都市", "愛情"])
        expectTrue(page.hasMore)
        let empty = try WebsiteParser.search(data: Data(#"{"searchList":[],"hasMore":false}"#.utf8))
        expectTrue(empty.items.isEmpty)
        expectThrows(try WebsiteParser.search(data: Data(#"{"searchList":[{"unexpected":"value"}]}"#.utf8)))
        expectThrows(try WebsiteParser.search(data: Data(#"{"code":"ERROR","message":"secret upstream details"}"#.utf8)))
    }

    @Test
    func testDetailBindsEpisodeListToRequestedSeriesAndAvailability() throws {
        var detail = webCard(); detail["vid_list"] = ["200", "201", "202"]; detail["accessible_episode_cnt"] = 2
        let html = routerHTML(["player_(series_id)/page": ["series_id": "100000000000000001", "seriesDetail": detail]])
        let result = try WebsiteParser.detail(html: html, seriesID: "100000000000000001")
        expectEqual(result.episodes.map(\.isAvailable), [true, true, false])
        expectEqual(result.episodes.map(\.number), [1, 2, 3])
        expectThrows(try WebsiteParser.detail(html: html, seriesID: "999"))
        detail["vid_list"] = ["200", "200"]
        expectThrows(try WebsiteParser.detail(html: routerHTML(["detail_page": ["seriesDetail": detail]]), seriesID: "100000000000000001"))
    }

    @Test
    func testPublicPlaybackBindsVideoObjectAndRejectsProtectedPreview() throws {
        let html = playerHTML()
        let url = try WebsiteParser.playback(html: html, seriesID: "100", episodeID: "200")
        expectEqual(url.absoluteString, "https://hongguoduanju.com/video/public/200/resource.mp4")
        expectThrows(try WebsiteParser.playback(html: playerHTML(protected: true), seriesID: "100", episodeID: "200")) { error in
            expectEqual(error as? CatalogError, .protectedPlayback)
        }
        expectThrows(try WebsiteParser.playback(html: html, seriesID: "100", episodeID: "201"))
        expectThrows(try WebsiteParser.playback(html: playerHTML(pageURL: "https://hongguoduanju.com/player/100/999"), seriesID: "100", episodeID: "200"))
        expectThrows(try WebsiteParser.playback(html: playerHTML(mediaURL: "http://192.168.1.2/private", pageURL: "https://hongguoduanju.com/player/100/200"), seriesID: "100", episodeID: "200"))
        expectThrows(try WebsiteParser.playback(html: playerHTML(mediaURL: "https://cdn.example.com/other.mp4"), seriesID: "100", episodeID: "200"))
    }

    @Test
    func testDirectRequestsUseOfficialOriginAndEncodedSearch() async throws {
        let transport = MockTransport(#"{"searchList":[],"hasMore":false}"#)
        let service = DirectWebService(transport: transport)
        _ = try await service.search(query: "測試&第二", page: 1)
        let requests = await transport.requests
        let request = try unwrap(requests.first)
        expectEqual(request.url?.host, "hongguoduanju.com")
        expectEqual(request.url?.path, "/api/search/result")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        expectEqual(components?.queryItems?.first(where: { $0.name == "query" })?.value, "測試&第二")
        expectNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    private func webCard() -> [String: Any] {
        ["series_id": "100000000000000001", "series_name": "我的短劇", "series_cover": "https://cdn.example.com/cover.jpg", "episode_cnt": 3,
         "series_intro": "這是簡介", "tags": ["都市", ["name": "愛情"]]]
    }

    private func routerHTML(_ loader: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["loaderData": loader], options: [.sortedKeys])
        return "<script>window._ROUTER_DATA = \(String(data: data, encoding: .utf8)!);</script>"
    }

    private func playerHTML(protected: Bool = false, mediaURL: String = "https://hongguoduanju.com/video/public/200/resource.mp4", pageURL: String = "https://hongguoduanju.com/player/100") -> String {
        let data: [String: Any] = ["series_id": "100", "vid": "200", "seriesDetail": ["series_id": "100"], "protectedPlayback": protected,
                                  "publicVideoSeo": ["available": true, "itemId": "200", "seriesId": "100"]]
        let video: [String: Any] = ["@type": "VideoObject", "url": pageURL, "@id": pageURL, "contentUrl": mediaURL]
        let ld = String(data: try! JSONSerialization.data(withJSONObject: video), encoding: .utf8)!
        return routerHTML(["player_(series_id)/(vid)/page": data]) + "<script type=\"application/ld+json\">\(ld)</script>"
    }
}

private struct MissingValue: Error {}

private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    guard let value else { Issue.record("Required value missing", sourceLocation: sourceLocation); throw MissingValue() }
    return value
}
private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, "\(message)", sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, "\(message)", sourceLocation: sourceLocation)
}
private func expectFalse(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!value, sourceLocation: sourceLocation)
}
private func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func recordFailure(_ message: String = "Unexpected success", sourceLocation: SourceLocation = #_sourceLocation) {
    Issue.record("\(message)", sourceLocation: sourceLocation)
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation, _ handler: (any Error) -> Void = { _ in }) {
    do { _ = try expression(); Issue.record("Expected failure: \(message)", sourceLocation: sourceLocation) }
    catch { handler(error) }
}
private func expectNoThrow<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression() }
    catch { Issue.record("Unexpected error: \(error), \(message)", sourceLocation: sourceLocation) }
}
