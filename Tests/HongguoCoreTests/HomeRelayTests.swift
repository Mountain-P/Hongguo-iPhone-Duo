import Foundation
import Testing
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HongguoCore

private actor RelayHTTP: HTTPTransport {
    let status: Int
    let body: String
    var requests: [URLRequest] = []
    init(status: Int = 200, body: String = #"{"path":"/api/media/abcd.mp4","contentType":"video/mp4"}"#) {
        self.status = status; self.body = body
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
private actor DirectRelayFixture: CatalogService {
    var calls: [String] = []
    func home(page: Int) async throws -> SeriesPage { .init(items: [], page: page, hasMore: false) }
    func search(query: String, page: Int) async throws -> SeriesPage { .init(items: [], page: page, hasMore: false) }
    func detail(id: String) async throws -> SeriesDetail { throw CatalogError.unavailablePlayback }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        calls.append("\(seriesID)/\(episodeID)/\(fresh)")
        return .init(url: URL(string: "https://media.example.com/direct.mp4")!)
    }
}
struct HomeRelayTests {
    @Test func relaySendsEpisodeContextAndOnlyItsOwnToken() async throws {
        let http = RelayHTTP(), direct = DirectRelayFixture()
        let service = HomeRelayService(configuration: try .init(baseURL: "https://relay.example.com", token: "relay-secret"),
                                       direct: direct, transport: http)
        let source = try await service.playback(seriesID: "100", episodeID: "200", fresh: true)
        let request = try #require(await http.requests.first)
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first(where: { $0.name == "series_id" })?.value == "100")
        #expect(query?.first(where: { $0.name == "fresh" })?.value == "1")
        #expect(source.headers["Authorization"] == "Bearer relay-secret")
        #expect(source.url.host == "relay.example.com")
        #expect(await direct.calls.isEmpty)
    }
    @Test(arguments: [404, 408, 429, 500, 502, 503, 504])
    func transientFailureUsesDirectWithoutRelayCredentials(_ status: Int) async throws {
        let direct = DirectRelayFixture()
        let service = HomeRelayService(configuration: try .init(baseURL: "https://relay.example.com", token: "private"),
                                       direct: direct, transport: RelayHTTP(status: status))
        let source = try await service.playback(seriesID: "100", episodeID: "200", fresh: true)
        #expect(source.headers.isEmpty)
        #expect(source.url.host == "media.example.com")
        #expect(await direct.calls == ["100/200/true"])
    }
    @Test(arguments: [401, 403, 409])
    func denialsNeverSwitchProviders(_ status: Int) async throws {
        let direct = DirectRelayFixture()
        let service = HomeRelayService(configuration: try .init(baseURL: "https://relay.example.com"), direct: direct,
                                       transport: RelayHTTP(status: status))
        do {
            _ = try await service.playback(seriesID: "100", episodeID: "200", fresh: false)
            Issue.record("Expected refusal")
        } catch { #expect(error is CatalogError) }
        #expect(await direct.calls.isEmpty)
    }
    @Test func rejectsDifferentOriginAndDisablingFallbackIsRespected() async throws {
        for body in [#"{"path":"https://evil.example.com/video.mp4"}"#, #"{"path":"//evil.example.com/video.mp4"}"#] {
            let direct = DirectRelayFixture()
            let service = HomeRelayService(configuration: try .init(baseURL: "https://relay.example.com", token: "private"),
                                           direct: direct, transport: RelayHTTP(body: body))
            await #expect(throws: CatalogError.unsafePlaybackURL) { try await service.playback(seriesID: "100", episodeID: "200", fresh: false) }
            #expect(await direct.calls.isEmpty)
        }
        let direct = DirectRelayFixture()
        let service = HomeRelayService(configuration: try .init(baseURL: "https://relay.example.com"), allowsDirectFallback: false,
                                       direct: direct, transport: RelayHTTP(status: 503))
        await #expect(throws: CatalogError.httpStatus(503)) { try await service.playback(seriesID: "100", episodeID: "200", fresh: false) }
        #expect(await direct.calls.isEmpty)
    }
    @Test func legacyHealthDoesNotQualifyAsHomeRelay() async throws {
        let service = HomeRelayService(configuration: try .init(baseURL: "https://relay.example.com"),
                                       transport: RelayHTTP(body: #"{"service":"hongguotv","apiVersion":1}"#))
        await #expect(throws: CatalogError.incompatibleBridge) { try await service.verifyConnection() }
    }
}
