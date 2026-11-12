// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private struct PrefetchFixtureService: CatalogService {
    let prepare: @Sendable (String) async throws -> PlaybackSource
    func home(page: Int) async throws -> SeriesPage { .init(items: [], page: page, hasMore: false) }
    func search(query: String, page: Int) async throws -> SeriesPage { try await home(page: page) }
    func detail(id: String) async throws -> SeriesDetail { throw CatalogError.unavailablePlayback }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource { try await prepare(episodeID) }
}

private actor PrefetchFixtureBytes: NativeRangeFetching {
    let bytes: Data
    var ranges: [Range<Int>] = []
    init(_ bytes: Data) { self.bytes = bytes }
    func fetch(range: Range<Int>) async throws -> NativeRangeResponse {
        try Task.checkCancellation()
        ranges.append(range)
        let actual = range.lowerBound..<min(bytes.count, range.upperBound)
        return .init(data: bytes.subdata(in: actual), range: actual, totalLength: bytes.count, validators: .init(etag: "prefetch"))
    }
}

private actor PrefetchFixtureProbe {
    let source: PlaybackSource
    var calls: [String] = []
    var cancelled = 0
    private var preparations: [String: CheckedContinuation<PlaybackSource, any Error>] = [:]
    private var entered: Set<String> = []
    private var entryWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    init(_ source: PlaybackSource) { self.source = source }
    func prepare(_ id: String) async throws -> PlaybackSource {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                preparations[id] = continuation
                calls.append(id); entered.insert(id)
                entryWaiters.removeValue(forKey: id)?.forEach { $0.resume() }
                // Cancellation may precede installing this continuation. The actor-side
                // cancellation callback also uses removeValue so it can complete only once.
                if Task.isCancelled { cancel(id) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func waitUntilEntered(_ id: String) async {
        if entered.contains(id) { return }
        await withCheckedContinuation { entryWaiters[id, default: []].append($0) }
    }
    func complete(_ id: String) { preparations.removeValue(forKey: id)?.resume(returning: source) }
    private func cancel(_ id: String) {
        guard let preparation = preparations.removeValue(forKey: id) else { return }
        cancelled += 1
        preparation.resume(throwing: CancellationError())
    }
}

private actor PrefetchOwnershipGate {
    let source: PlaybackSource
    var calls: [String] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    init(_ source: PlaybackSource) { self.source = source }
    func prepare(_ id: String) async throws -> PlaybackSource {
        calls.append(id)
        await withCheckedContinuation { releaseContinuation = $0 }
        try Task.checkCancellation()
        return source
    }
    func release() { releaseContinuation?.resume(); releaseContinuation = nil }
}

struct PlaybackPrefetchTests {
    private func nativeSource() -> NativeMediaSource {
        .init(url: URL(string: "https://unit.fqnovelvod.com/prefetch.mp4")!, contentKey: nil,
              userAgent: "Fixture", codec: "h264", quality: "1080p")
    }

    private func playbackSource() async throws -> PlaybackSource {
        let fixture = streamFixture(payload: Data(repeating: 0x41, count: 2 * 1024 * 1024), samples: 1)
        let stream = try await NativeProgressiveMedia().prepare(source: nativeSource(), fetcher: PrefetchFixtureBytes(fixture.data))
        return .init(url: stream.assetURL, nativeStream: stream)
    }

    @Test func policySkipMakesNoRequestAndSupersedingPrefetchCancelsOnlyTheOldOperation() async throws {
        let probe = PrefetchFixtureProbe(try await playbackSource())
        let service = PrefetchFixtureService { try await probe.prepare($0) }
        let prefetch = NativePlaybackPrefetch()
        #expect(try await prefetch.prepare(seriesID: "1", episodeID: "2", service: service, allowed: false) == .skipped)
        #expect(await probe.calls.isEmpty)
        let first = Task { try await prefetch.prepare(seriesID: "1", episodeID: "2", service: service) }
        await probe.waitUntilEntered("2")
        let second = Task { try await prefetch.prepare(seriesID: "1", episodeID: "3", service: service) }
        await probe.waitUntilEntered("3")
        await probe.complete("3")
        #expect(try await second.value == .prepared)
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await probe.calls == ["2", "3"])
        #expect(await probe.cancelled == 1)
    }

    @Test func cancellingTheCallerCancelsPreparationAndDoesNotReportPrepared() async throws {
        let probe = PrefetchFixtureProbe(try await playbackSource())
        let service = PrefetchFixtureService { try await probe.prepare($0) }
        let prefetch = NativePlaybackPrefetch()
        let task = Task { try await prefetch.prepare(seriesID: "1", episodeID: "2", service: service) }
        await probe.waitUntilEntered("2")
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await probe.cancelled == 1)
    }

    @Test func productionPrefetchBudgetPropagatesToNativeHeaderPreparation() async throws {
        var size = UInt32(1_100_008).bigEndian
        let padding = withUnsafeBytes(of: &size) { Data($0) } + Data("free".utf8) + Data(count: 1_100_000)
        let fixture = streamFixture(payload: Data(repeating: 0x42, count: 2 * 1024 * 1024), samples: 1, extraTable: padding)
        let bytes = PrefetchFixtureBytes(fixture.data)
        let media = NativeProgressiveMedia(makeFetcher: { _ in bytes })
        let source = nativeSource()
        let service = PrefetchFixtureService { id in
            let stream = try await media.prepare(source: source, episodeID: id)
            return .init(url: stream.assetURL, nativeStream: stream)
        }
        await #expect(throws: PlaybackPrefetchError.budgetExceeded) {
            try await NativePlaybackPrefetch().prepare(seriesID: "1", episodeID: "2", service: service)
        }
        #expect(await bytes.ranges == [0..<(256 * 1024)])
        #expect(await media.reusableEntryCount == 0)
    }

    @Test func anAlreadyCancelledCallerCannotCancelANewerOwnedPreparation() async throws {
        let gate = PrefetchOwnershipGate(try await playbackSource())
        let service = PrefetchFixtureService { try await gate.prepare($0) }
        let prefetch = NativePlaybackPrefetch()
        let active = Task { try await prefetch.prepare(seriesID: "1", episodeID: "2", service: service) }
        for _ in 0..<500 {
            if await !gate.calls.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let stale = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await prefetch.prepare(seriesID: "1", episodeID: "3", service: service)
        }
        await #expect(throws: CancellationError.self) { try await stale.value }
        await gate.release()
        #expect(try await active.value == .prepared)
        #expect(await gate.calls == ["2"])
    }
    @Test func formalOpeningIsFetchedAndHandedOffOnceWithoutAnotherSourceLookup() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x31, count: 3 * 1024 * 1024), samples: 1)
        let bytes = PrefetchFixtureBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: nativeSource(), fetcher: bytes)
        let service = PrefetchFixtureService { _ in .init(url: stream.assetURL, nativeStream: stream) }
        let prefetch = NativePlaybackPrefetch()
        #expect(try await prefetch.prepare(seriesID: "1", episodeID: "2", service: service,
            warmOpening: true, playbackRate: 2) == .prepared)
        #expect(await prefetch.takePrepared(seriesID: "1", episodeID: "2", preference: .dataSaver) == nil)
        let prepared = try #require(await prefetch.takePrepared(seriesID: "1", episodeID: "2", preference: .automatic))
        #expect(prepared.nativeStream?.id == stream.id)
        let before = await bytes.ranges.count
        _ = try await stream.read(range: 300_000..<1_500_000)
        #expect(await bytes.ranges.count == before)
        #expect(await prefetch.takePrepared(seriesID: "1", episodeID: "2") == nil)
    }

}
