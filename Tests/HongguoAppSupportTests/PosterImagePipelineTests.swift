import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import HongguoAppSupport

struct PosterImagePipelineTests {
    @Test func largeSyntheticPosterUsesThumbnailDecodedBytesAndOneSharedRequest() async throws {
        let source = try makeImage(width: 4096, height: 6144)
        let data = try encode(source, type: "public.jpeg")
        let baseline = PosterProbe(data: data)
        _ = try await baseline.data(for: url("baseline"), maximumBytes: data.count)
        _ = try await baseline.data(for: url("baseline"), maximumBytes: data.count)
        let probe = PosterProbe(data: data, gated: true)
        let pipeline = PosterImagePipeline(transport: probe)
        let first = Task { try await pipeline.image(for: url("large"), targetPixelSize: 512) }
        let second = Task { try await pipeline.image(for: url("large"), targetPixelSize: 512) }
        try await wait { await pipeline.statistics().imageConsumers == 2 }
        await probe.releaseAll()
        let image = try await first.value
        let other = try await second.value
        #expect(image === other)
        #expect(max(image.image.width, image.image.height) == 512)
        #expect(image.decodedByteCount < source.bytesPerRow * source.height / 50)
        #expect(await baseline.callCount == 2)
        #expect(await probe.callCount == 1)
        print("[PosterMeasurement] synthetic_source_decoded_bytes=\(source.bytesPerRow * source.height) thumbnail_decoded_bytes=\(image.decodedByteCount) independent_requests=\(await baseline.callCount) shared_requests=\(await probe.callCount)")
    }

    @Test func differentThumbnailSizesShareTheSameInFlightDownload() async throws {
        let probe = PosterProbe(data: try png(), gated: true)
        let pipeline = PosterImagePipeline(transport: probe)
        let first = Task { try await pipeline.image(for: url("sizes"), targetPixelSize: 64) }
        let second = Task { try await pipeline.image(for: url("sizes"), targetPixelSize: 128) }
        try await wait { await pipeline.statistics().downloadConsumers == 2 }
        #expect(await probe.callCount == 1)
        await probe.releaseAll()
        #expect(try await first.value.image.width == 64)
        #expect(try await second.value.image.width == 128)
    }

    @Test func cancellingOneConsumerDoesNotCancelTheOtherConsumer() async throws {
        let probe = PosterProbe(data: try png(), gated: true)
        let pipeline = PosterImagePipeline(transport: probe)
        let first = Task { try await pipeline.image(for: url("shared"), targetPixelSize: 64) }
        let second = Task { try await pipeline.image(for: url("shared"), targetPixelSize: 64) }
        try await wait { await pipeline.statistics().imageConsumers == 2 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await probe.cancelCount == 0)
        await probe.releaseAll()
        #expect(try await second.value.image.width == 64)
        #expect(await probe.callCount == 1)
    }

    @Test func cancellingOneSizeDoesNotCancelADifferentSizesDownload() async throws {
        let probe = PosterProbe(data: try png(), gated: true)
        let pipeline = PosterImagePipeline(transport: probe)
        let first = Task { try await pipeline.image(for: url("sizes-cancel"), targetPixelSize: 64) }
        let second = Task { try await pipeline.image(for: url("sizes-cancel"), targetPixelSize: 128) }
        try await wait { await pipeline.statistics().downloadConsumers == 2 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await probe.cancelCount == 0)
        await probe.releaseAll()
        #expect(try await second.value.image.width == 128)
    }

    @Test func cancellingTheLastConsumerStopsDownloadAndAllowsRetry() async throws {
        let probe = PosterProbe(data: try png(), gated: true)
        let pipeline = PosterImagePipeline(transport: probe)
        let first = Task { try await pipeline.image(for: url("cancel-all"), targetPixelSize: 64) }
        try await wait { await probe.callCount == 1 }
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await wait {
            let cancelled = await probe.cancelCount
            let stats = await pipeline.statistics()
            return cancelled == 1 && stats.activeRequests == 0
        }
        await probe.releaseAll()
        #expect(try await pipeline.image(for: url("cancel-all"), targetPixelSize: 64).image.width == 64)
        #expect(await probe.callCount == 2)
    }

    @Test func workConcurrencyAndPendingRequestsAreBounded() async throws {
        let probe = PosterProbe(data: try png(), gated: true)
        let pipeline = PosterImagePipeline(configuration: .init(maximumConcurrentRequests: 2, maximumPendingRequests: 3), transport: probe)
        let tasks = (1...3).map { n in Task { try await pipeline.image(for: url("concurrent\(n)"), targetPixelSize: 64) } }
        try await wait { await pipeline.statistics().queuedRequests == 1 }
        #expect(await probe.maximumActive == 2)
        await #expect(throws: PosterImageError.busy) { try await pipeline.image(for: url("over-pending"), targetPixelSize: 64) }
        await probe.releaseAll()
        for task in tasks { _ = try await task.value }
        #expect(await probe.maximumActive <= 2)
        #expect(await pipeline.statistics().activeRequests == 0)
    }

    @Test func cancelledQueuedWorkDoesNotConsumeASlotOrDownload() async throws {
        let probe = PosterProbe(data: try png(), gated: true)
        let pipeline = PosterImagePipeline(configuration: .init(maximumConcurrentRequests: 1), transport: probe)
        let first = Task { try await pipeline.image(for: url("active"), targetPixelSize: 64) }
        try await wait { await probe.callCount == 1 }
        let queued = Task { try await pipeline.image(for: url("queued"), targetPixelSize: 64) }
        try await wait { await pipeline.statistics().queuedRequests == 1 }
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        await probe.releaseAll()
        _ = try await first.value
        #expect(await probe.callCount == 1)
    }

    @Test func decodedByteBudgetAndEntryLRUEvictCompletedImages() async throws {
        let data = try png()
        let sample = try PosterImagePipeline.downsample(data, pixels: 64)
        let probe = PosterProbe(data: data)
        let pipeline = PosterImagePipeline(configuration: .init(maximumCacheBytes: sample.decodedByteCount + 1), transport: probe)
        _ = try await pipeline.image(for: url("budget1"), targetPixelSize: 64)
        _ = try await pipeline.image(for: url("budget2"), targetPixelSize: 64)
        let stats = await pipeline.statistics()
        #expect(stats.cachedImages == 1)
        #expect(stats.cachedDecodedBytes <= sample.decodedByteCount + 1)
        let lru = PosterImagePipeline(configuration: .init(maximumCacheEntries: 2), transport: probe)
        _ = try await lru.image(for: url("lru1"), targetPixelSize: 64)
        _ = try await lru.image(for: url("lru2"), targetPixelSize: 64)
        _ = try await lru.image(for: url("lru1"), targetPixelSize: 64)
        _ = try await lru.image(for: url("lru3"), targetPixelSize: 64)
        #expect(await lru.statistics().cachedImages == 2)
        _ = try await lru.image(for: url("lru2"), targetPixelSize: 64)
        #expect(await probe.calls(for: url("lru1")) == 1)
        #expect(await probe.calls(for: url("lru2")) == 2)
        await lru.clearMemoryCache()
        #expect(await lru.statistics().cachedDecodedBytes == 0)
    }

    @Test func malformedImageIsNotCachedAndTheNextAttemptCanSucceed() async throws {
        let probe = PosterProbe(data: Data("<html>not an image</html>".utf8))
        let pipeline = PosterImagePipeline(transport: probe)
        await #expect(throws: PosterImageError.invalidImage) { try await pipeline.image(for: url("retry"), targetPixelSize: 64) }
        #expect(await pipeline.statistics().cachedImages == 0)
        await probe.setData(try png())
        #expect(try await pipeline.image(for: url("retry"), targetPixelSize: 64).image.width == 64)
        #expect(await probe.callCount == 2)
    }

    @Test func oversizedPayloadAndUnsafeURLAreRejectedWithoutCaching() async throws {
        let probe = PosterProbe(data: Data(repeating: 0, count: 101))
        let pipeline = PosterImagePipeline(configuration: .init(maximumDownloadBytes: 100), transport: probe)
        await #expect(throws: PosterImageError.responseTooLarge) { try await pipeline.image(for: url("too-large"), targetPixelSize: 64) }
        for invalid in ["file:///tmp/poster.png", "https://user:password@example.invalid/image.png", "data:image/png,abc"] {
            let candidate = try #require(URL(string: invalid))
            await #expect(throws: PosterImageError.invalidURL) { try await pipeline.image(for: candidate, targetPixelSize: 64) }
        }
        #expect(await probe.callCount == 1)
        #expect(await pipeline.statistics().cachedDecodedBytes == 0)
    }

    @Test func distinctURLResultsAndCachedDimensionsCannotReplaceEachOther() async throws {
        let probe = PosterProbe(data: try png(width: 128, height: 64), gated: true)
        let pipeline = PosterImagePipeline(transport: probe)
        let old = Task { try await pipeline.image(for: url("old"), targetPixelSize: 64) }
        try await wait { await probe.callCount == 1 }
        await probe.setData(try png(width: 64, height: 128))
        let current = Task { try await pipeline.image(for: url("new"), targetPixelSize: 64) }
        try await wait { await probe.callCount == 2 }
        await probe.release(url("new"))
        #expect(try await current.value.image.height == 64)
        await probe.release(url("old"))
        #expect(try await old.value.image.width == 64)
        #expect(try await pipeline.image(for: url("new"), targetPixelSize: 64).image.height == 64)
        #expect(await probe.callCount == 2)
    }

    @Test func sourceOrientationIsAppliedDuringDownsampling() throws {
        let data = try encode(makeImage(width: 256, height: 128), type: "public.jpeg", orientation: 6)
        let image = try PosterImagePipeline.downsample(data, pixels: 128)
        #expect(image.image.width == 64)
        #expect(image.image.height == 128)
    }

    @Test func targetPixelsAndDeclaredSourcePixelCountAreCappedBeforeDecode() async throws {
        let probe = PosterProbe(data: try png())
        let pipeline = PosterImagePipeline(configuration: .init(maximumPixelDimension: 96), transport: probe)
        let image = try await pipeline.image(for: url("pixel-cap"), targetPixelSize: Int.max)
        #expect(max(image.image.width, image.image.height) == 96)
        var declaredHuge = try encode(makeImage(width: 16, height: 16), type: "public.jpeg")
        let marker = try #require(declaredHuge.range(of: Data([0xff, 0xc0])) ?? declaredHuge.range(of: Data([0xff, 0xc2])))
        for offset in [marker.lowerBound + 5, marker.lowerBound + 7] {
            var dimension = UInt16(8000).bigEndian
            withUnsafeBytes(of: &dimension) { declaredHuge.replaceSubrange(offset..<(offset + 2), with: $0) }
        }
        let source = try #require(CGImageSourceCreateWithData(declaredHuge as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 8000)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 8000)
        #expect(throws: PosterImageError.imageTooLarge) { try PosterImagePipeline.downsample(declaredHuge, pixels: 64) }
    }

    @Test func realSessionRejectsHTTPAndAdvertisedOrStreamedByteLimitsAndStripsHeaders() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PosterProtocol.self]
        config.httpAdditionalHeaders = ["Authorization": "synthetic-only", "Cookie": "synthetic-only", "X-Token": "synthetic-only"]
        let transport = PosterURLSessionTransport(configuration: config)
        let base = URL(string: "https://poster-fixture.invalid/\(UUID().uuidString)")!
        PosterProtocol.responses.set(base, .init(status: 403, body: Data()))
        await #expect(throws: PosterImageError.httpStatus(403)) { try await transport.data(for: base, maximumBytes: 100) }
        let advertised = base.appendingPathComponent("advertised")
        PosterProtocol.responses.set(advertised, .init(status: 200, body: Data(), advertisedLength: 101))
        await #expect(throws: PosterImageError.responseTooLarge) { try await transport.data(for: advertised, maximumBytes: 100) }
        let streamed = base.appendingPathComponent("streamed")
        PosterProtocol.responses.set(streamed, .init(status: 200, body: Data(repeating: 1, count: 101)))
        await #expect(throws: PosterImageError.responseTooLarge) { try await transport.data(for: streamed, maximumBytes: 100) }
        let success = base.appendingPathComponent("success")
        PosterProtocol.responses.set(success, .init(status: 200, body: Data([1, 2, 3])))
        #expect(try await transport.data(for: success, maximumBytes: 100) == Data([1, 2, 3]))
        let request = try #require(PosterProtocol.responses.request(success))
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "X-Token") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "image/*")
    }

    private func url(_ name: String) -> URL { URL(string: "https://poster-fixture.invalid/\(name).png")! }
    private func png(width: Int = 256, height: Int = 256) throws -> Data { try encode(makeImage(width: width, height: height)) }
    private func makeImage(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }
    private func encode(_ image: CGImage, type: String = "public.png", orientation: Int = 1) throws -> Data {
        let result = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(result, type as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return result as Data
    }
    private func wait(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("Poster fixture did not reach the expected state")
        throw PosterImageError.network
    }
}

private actor PosterProbe: PosterImageTransport {
    private var payload: Data
    private var gated: Bool
    private struct Pending { let url: URL; let continuation: CheckedContinuation<Void, any Error> }
    private var pending: [UUID: Pending] = [:]
    private var counts: [URL: Int] = [:]
    private(set) var callCount = 0
    private(set) var cancelCount = 0
    private var active = 0
    private(set) var maximumActive = 0
    init(data: Data, gated: Bool = false) { payload = data; self.gated = gated }
    func data(for url: URL, maximumBytes: Int) async throws -> Data {
        let data = payload, id = UUID()
        counts[url, default: 0] += 1; callCount += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await withTaskCancellationHandler {
            if gated {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { pending[id] = Pending(url: url, continuation: continuation) }
                }
            }
            try Task.checkCancellation()
        } onCancel: { Task { await self.cancel(id) } }
        return data
    }
    func calls(for url: URL) -> Int { counts[url, default: 0] }
    func setData(_ data: Data) { payload = data }
    func release(_ url: URL) {
        let ids = pending.filter { $0.value.url == url }.map(\.key)
        for id in ids { pending.removeValue(forKey: id)?.continuation.resume() }
    }
    func releaseAll() {
        gated = false
        let values = pending.values; pending = [:]
        for value in values { value.continuation.resume() }
    }
    private func cancel(_ id: UUID) {
        guard let value = pending.removeValue(forKey: id) else { return }
        cancelCount += 1; value.continuation.resume(throwing: CancellationError())
    }
}

private final class PosterProtocol: URLProtocol, @unchecked Sendable {
    struct Response: Sendable { let status: Int; let body: Data; var advertisedLength: Int? = nil }
    final class Responses: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [URL: Response] = [:]
        private var requests: [URL: URLRequest] = [:]
        func set(_ url: URL, _ value: Response) { lock.lock(); values[url] = value; lock.unlock() }
        func take(_ request: URLRequest) -> Response? {
            lock.lock(); defer { lock.unlock() }
            guard let url = request.url else { return nil }
            requests[url] = request
            return values.removeValue(forKey: url)
        }
        func request(_ url: URL) -> URLRequest? { lock.lock(); defer { lock.unlock() }; return requests[url] }
    }
    static let responses = Responses()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "poster-fixture.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let value = Self.responses.take(request), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        let headers = value.advertisedLength.map { ["Content-Length": String($0)] }
        let response = HTTPURLResponse(url: url, statusCode: value.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !value.body.isEmpty { client?.urlProtocol(self, didLoad: value.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
