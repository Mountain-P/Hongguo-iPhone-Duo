import Testing
@testable import HongguoPlayback

@Suite struct NativeReadAheadTests {
    private let chunk = 512 * 1024

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
