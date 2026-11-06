// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private final class SourceCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
private actor SourceCounter {
    var calls = 0
    func next() -> Int { calls += 1; return calls }
}

struct NativeSourceCacheTests {
    private func source(_ count: Int) -> NativeMediaSource {
        .init(url: URL(string: "https://unit.fqnovelvod.com/video.mp4")!, contentKey: nil, userAgent: "Fixture", codec: "h264", quality: String(count))
    }
    @Test func successCacheHasTTLAndFreshBypassAndContentTypeIsolation() async throws {
        let clock = SourceCacheClock(), counter = SourceCounter()
        let resolver = NativeSourceResolver(now: { clock.now() }, resolve: { _, _ in source(await counter.next()) })
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(try await resolver.resolve(episodeID: "100", fresh: true).quality == "2")
        #expect(try await resolver.resolve(episodeID: "100", contentType: "1006").quality == "3")
        clock.advance(121)
        #expect(try await resolver.resolve(episodeID: "100").quality == "4")
    }
    @Test func sixteenEntryLimitUsesLRUAndCancellationCannotPopulateCache() async throws {
        let counter = SourceCounter()
        let resolver = NativeSourceResolver(resolve: { _, _ in source(await counter.next()) })
        for id in 100..<116 { _ = try await resolver.resolve(episodeID: String(id)) }
        _ = try await resolver.resolve(episodeID: "100")
        _ = try await resolver.resolve(episodeID: "116")
        #expect(await counter.calls == 17)
        _ = try await resolver.resolve(episodeID: "101")
        #expect(await counter.calls == 18)
        let cancelledCounter = SourceCounter()
        let cancelledResolver = NativeSourceResolver(resolve: { _, _ in
            let count = await cancelledCounter.next()
            if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            return source(count)
        })
        let task = Task { try await cancelledResolver.resolve(episodeID: "100") }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await cancelledResolver.resolve(episodeID: "100").quality == "2")
    }
}
