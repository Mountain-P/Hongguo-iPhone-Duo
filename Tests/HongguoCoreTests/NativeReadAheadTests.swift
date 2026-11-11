import Testing
import HongguoCore
@testable import HongguoPlayback

private actor BusyReadAheadProbe {
    private let failures: Int
    private(set) var requests: [Range<Int>] = []

    init(failures: Int) { self.failures = failures }

    func prefetch(_ range: Range<Int>) throws {
        requests.append(range)
        if requests.count <= failures { throw NativeMediaError.busy }
    }
}

@Suite struct NativeReadAheadTests {
    private let chunk = 512 * 1024

    @Test func aBusyCacheRetriesTheSameRangeWithNoNewDemand() async throws {
        let probe = BusyReadAheadProbe(failures: 2)
        let range = chunk..<(2 * chunk)
        try await NativeMediaAssetLoader.prefetchWithBackoff(range) { try await probe.prefetch($0) }
        #expect(await probe.requests == [range, range, range])
    }

    @Test func aCacheThatStaysBusyStopsAfterFourRetries() async {
        let probe = BusyReadAheadProbe(failures: 5)
        let range = chunk..<(2 * chunk)
        await #expect(throws: NativeMediaError.busy) {
            try await NativeMediaAssetLoader.prefetchWithBackoff(range) { try await probe.prefetch($0) }
        }
        #expect(await probe.requests == Array(repeating: range, count: 5))
    }

    @Test(arguments: [(rate: Float(1), count: 4), (rate: Float(2), count: 8)])
    func memoryReadAheadStaysWithinItsRateBudgetFromAnUnalignedCursor(rate: Float, count: Int) throws {
        var window = NativeMediaAssetLoader.ReadAheadWindow()
        let length = 10 * chunk
        let cursor = chunk + 1
        window.extend(after: cursor, totalLength: length, memoryOnly: true, playbackRate: rate)
        window.skipConsumedChunks(before: cursor)
        var confirmed: Range<Int>?
        for index in 1...count {
            let candidate = window.nextRange(after: confirmed, totalLength: length)
            let next = try #require(candidate)
            #expect(next == (index * chunk)..<((index + 1) * chunk))
            confirmed = next
        }
        let next = window.nextRange(after: confirmed, totalLength: length)
        #expect(next == nil)
    }

    @Test func temporaryFailureKeepsTheAttemptedChunkEligibleAtTheNextDemand() throws {
        var window = NativeMediaAssetLoader.ReadAheadWindow()
        let length = 10 * chunk
        let initialDemandEnd = chunk + 1
        window.extend(after: initialDemandEnd, totalLength: length)
        window.skipConsumedChunks(before: initialDemandEnd)
        let firstAttempt = window.nextRange(after: nil, totalLength: length)
        let first = try #require(firstAttempt)
        #expect(first == chunk..<(2 * chunk))

        // A failed worker returns without confirming that first range. Playback can
        // deliver another slice in the same chunk before the next speculative run.
        let laterDemandEnd = chunk + chunk / 2
        window.extend(after: laterDemandEnd, totalLength: length)
        window.skipConsumedChunks(before: laterDemandEnd)
        let retryAttempt = window.nextRange(after: nil, totalLength: length)
        let retried = try #require(retryAttempt)
        #expect(retried == first)
        let next = window.nextRange(after: retried, totalLength: length)
        #expect(next == (2 * chunk)..<(3 * chunk))
    }

    @Test func laterDemandDoesNotRetryChunksPlaybackHasAlreadyConsumed() throws {
        var window = NativeMediaAssetLoader.ReadAheadWindow()
        let length = 10 * chunk
        window.extend(after: 1, totalLength: length)
        let attempted = window.nextRange(after: nil, totalLength: length)
        #expect(attempted == 0..<chunk)

        window.extend(after: chunk + 1, totalLength: length)
        window.skipConsumedChunks(before: chunk + 1)
        let next = window.nextRange(after: nil, totalLength: length)
        #expect(next == chunk..<(2 * chunk))
    }

    @Test func aLateReadAheadCompletionCannotMoveTheWindowBehindPlayback() throws {
        var window = NativeMediaAssetLoader.ReadAheadWindow()
        let length = 10 * chunk
        window.extend(after: 1, totalLength: length)
        let first = window.nextRange(after: nil, totalLength: length)
        let attempted = try #require(first)

        let demandEnd = 3 * chunk + 1
        window.extend(after: demandEnd, totalLength: length)
        window.skipConsumedChunks(before: demandEnd)
        let next = window.nextRange(after: attempted, totalLength: length)
        #expect(next == (3 * chunk)..<(4 * chunk))
    }

    @Test func confirmingTheFinalPartialChunkFinishesTheWindow() throws {
        var window = NativeMediaAssetLoader.ReadAheadWindow()
        let length = chunk + 120
        window.extend(after: chunk + 1, totalLength: length)
        window.skipConsumedChunks(before: chunk + 1)
        let finalAttempt = window.nextRange(after: nil, totalLength: length)
        let final = try #require(finalAttempt)
        #expect(final == chunk..<length)
        let next = window.nextRange(after: final, totalLength: length)
        #expect(next == nil)
        #expect(!window.hasPendingRange)
    }
}
