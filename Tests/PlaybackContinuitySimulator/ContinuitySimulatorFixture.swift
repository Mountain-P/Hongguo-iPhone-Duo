import Foundation

// Isolated simulator target only. Never copied into the release checkout.
public actor ContinuitySimulatorFixture {
    private let bytes: Data
    private let lowBytes: Data
    private let mode: String
    public private(set) var routeCount = 0
    public private(set) var requestedQualities: [String] = []
    public init(file: URL, lowFile: URL, mode: String) throws {
        self.bytes = try Data(contentsOf: file); self.lowBytes = try Data(contentsOf: lowFile); self.mode = mode
    }
    public func service(quality: NativePlaybackQuality) -> NativeCatalogService {
        NativeCatalogService(transport: URLSessionTransport(), quality: quality, prepareSource: { [self] _, _, _, quality in
            let stream = try await self.makeStream(quality: quality)
            return .init(url: stream.assetURL, nativeStream: stream)
        })
    }
    private func makeStream(quality: NativePlaybackQuality) async throws -> NativeMediaStream {
        routeCount += 1; requestedQualities.append(quality.rawValue)
        let route = routeCount
        if mode == "cancel", route == 2 { try await Task.sleep(for: .seconds(5)) }
        let lower = quality == .dataSaver
        let source = NativeMediaSource(url: URL(string: "https://fixture.fqnovelvod.com/route\(route).mp4")!,
            contentKey: nil, userAgent: "Fixture", codec: "h264", quality: lower ? "90p" : "180p", preference: quality,
            width: lower ? 160 : 320, height: lower ? 90 : 180)
        return try await NativeProgressiveMedia.shared.prepare(source: source,
            fetcher: Fetch(fixture: self, route: route, lower: lower), diskCache: .shared)
    }
    private func fetch(_ range: Range<Int>, route: Int, lower: Bool) async throws -> NativeRangeResponse {
        let stallAfter = route == 1 ? 2_097_152 : 4_718_592
        let failedRoute = route == 1 || (mode == "smooth" && route == 2)
        if failedRoute, range.lowerBound >= stallAfter {
            if mode == "terminal" || mode == "cancel" { throw NativeProgressiveError.changedSource }
            try await Task.sleep(for: .seconds(65))
        }
        try await Task.sleep(for: .milliseconds(20))
        let data = lower ? lowBytes : bytes
        let actual = range.lowerBound..<min(data.count, range.upperBound)
        return .init(data: data.subdata(in: actual), range: actual, totalLength: data.count,
            validators: .init(etag: "\"fixture-\(route)\""))
    }
    private struct Fetch: NativeRangeFetching {
        let fixture: ContinuitySimulatorFixture
        let route: Int
        let lower: Bool
        func fetch(range: Range<Int>) async throws -> NativeRangeResponse {
            try await fixture.fetch(range, route: route, lower: lower)
        }
    }
}
