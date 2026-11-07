// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct EpisodePrefetchTests {
    private func context(_ elapsed: Double, rate: Float = 1, buffer: Double = 12,
                         allowed: Bool = true) -> EpisodePrefetchState.Context {
        .init(elapsed: elapsed, duration: 100, rate: rate, bufferedAhead: buffer, allowed: allowed)
    }

    @Test func preparesOnceNearTheEndAndPauseOrPolicyRevocationCancelsItsWindow() {
        var state = EpisodePrefetchState()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(50)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(89)) == .prepare("2"))
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90, allowed: false)) == .cancel)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90, allowed: false)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90)) == .prepare("2"))
        #expect(state.reset() == .cancel)
        #expect(state.update(episodeID: "2", nextEpisodeID: "3", context: context(90)) == .prepare("3"))
    }

    @Test func selectedRateUsesWallTimeAndCurrentBufferingHasPriority() {
        var state = EpisodePrefetchState()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(80)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(80, rate: 2, buffer: 2)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(80, rate: 2, buffer: 19.99)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(80, rate: 2, buffer: 20)) == .prepare("2"))
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(80, rate: 2, buffer: 1)) == .cancel)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(80)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(95, rate: 0.75)) == .prepare("2"))
    }

    @Test func backwardsSeekEndAndUnavailableNextEpisodeClearSpeculativeWork() {
        var state = EpisodePrefetchState()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90)) == .prepare("2"))
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(10)) == .cancel)
        #expect(state.update(episodeID: "1", nextEpisodeID: nil, context: context(90)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "1", context: context(90)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(95)) == .prepare("2"))
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(99, buffer: 1)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(100)) == .cancel)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(.nan)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(95, rate: .infinity)) == .none)
    }

    @Test func twoTimesPlaybackNeedsTheWholeTailBeforeSharingNetworkWithTheNextItem() {
        var state = EpisodePrefetchState()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(76, rate: 2, buffer: 23.99)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(76, rate: 2, buffer: 24)) == .prepare("2"))
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(78, rate: 2, buffer: 21.99)) == .cancel)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(78, rate: 2, buffer: 22)) == .prepare("2"))
    }

    @Test func slowRatesKeepTheTwelveSecondMinimumAndShortCompleteTailsStillPrepare() {
        var state = EpisodePrefetchState()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(91, rate: 0.75, buffer: 8.99)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(91, rate: 0.75, buffer: 9)) == .prepare("2"))
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(99, rate: 2, buffer: 0.99)) == .cancel)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(99, rate: 2, buffer: 1)) == .prepare("2"))
    }
}
