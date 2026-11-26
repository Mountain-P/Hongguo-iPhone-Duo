import Foundation
import Testing
@testable import HongguoCore

private final class PrefixFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let mode = url.lastPathComponent
        let prefixBytes = 512 * 1024
        let expected = mode == "double" ? prefixBytes * 2 : prefixBytes
        let total = mode == "short" ? 12 : 2 * 1024 * 1024
        let last = min(expected, total) - 1
        let correctRequest = request.value(forHTTPHeaderField: "Range") == "bytes=0-\(expected - 1)"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture"
        let status = correctRequest ? (mode == "full" ? 200 : 206) : 401
        let headers = ["Content-Type": "video/mp4", "ETag": mode == "weak" ? "W/\"A\"" : "\"A\"",
                       "Content-Length": String(last + 1), "Content-Range": "bytes 0-\(last)/\(total)"]
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 7, count: mode == "short-body" ? 7 : last + 1))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct RelayPlaybackOpeningTests {
    private func fetch(_ mode: String, rate: Float = 1) async throws -> RelayPlaybackOpening {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrefixFixtureProtocol.self]
        let source = PlaybackSource(url: URL(string: "https://relay.example/\(mode)")!,
                                    headers: ["Authorization": "Bearer fixture"])
        return try await RelayPlaybackOpening.fetch(source, rate: rate, configuration: config)
    }

    @Test func stagesOnlyTheBoundedPrefixAndKeepsTheExactRepresentation() async throws {
        let normal = try await fetch("normal")
        #expect(normal.bytes.count == 512 * 1024)
        #expect(normal.etag == "\"A\"")
        #expect(normal.totalLength == 2 * 1024 * 1024)
        let double = try await fetch("double", rate: 2)
        #expect(double.bytes.count == 1024 * 1024)
        let small = try await fetch("short")
        #expect(small.bytes.count == 12)
        #expect(small.totalLength == 12)
    }

    @Test func refusesUnversionedFullOrTruncatedResponses() async {
        await #expect(throws: CatalogError.malformedResponse) { try await fetch("weak") }
        await #expect(throws: CatalogError.httpStatus(200)) { try await fetch("full") }
        await #expect(throws: CatalogError.network) { try await fetch("short-body") }
    }
}
