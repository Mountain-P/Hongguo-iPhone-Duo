// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct EpisodePrefetchTests {
    private func context(_ elapsed: Double, rate: Float = 1, buffer: Double = 12,
                         allowed: Bool = true) -> EpisodePrefetchState.Context {
        .init(elapsed: elapsed, duration: 100, rate: rate, bufferedAhead: buffer, allowed: allowed)
    }

    @Test func aRetriedOpeningExpiresDuringPlaybackAndAnAlreadyWarmOpeningKeepsItsOriginalDeadline() {
        var state = EpisodePrefetchState()
        let tail = context(80, rate: 2, buffer: 20)
        func tick(_ now: Double) -> EpisodePrefetchState.Decision {
            state.update(episodeID: "1", nextEpisodeID: "2", context: tail, now: now)
        }
        #expect(tick(0) == .prepare("2"))
        state.failed(episodeID: "1", nextEpisodeID: "2", error: CatalogError.httpStatus(503), now: 0)
        #expect(tick(1) == .prepare("2"))
        state.prepared(episodeID: "1", nextEpisodeID: "2", expiresAt: 46)
        #expect(tick(40) == .none)
        #expect(state.suspend() == .cancel)
        #expect(tick(45) == .prepare("2"))
        state.prepared(episodeID: "1", nextEpisodeID: "2", expiresAt: 46)
        #expect(tick(45.9) == .none)
        #expect(tick(46) == .prepare("2"))
        #expect(tick(47) == .none)
        state.prepared(episodeID: "1", nextEpisodeID: "2", expiresAt: nil)
        #expect(tick(600) == .none)
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
    @Test func aFullyBufferedTailCanWarmTheNextOpeningThirtyWallSecondsEarly() {
        var state = EpisodePrefetchState()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(40, rate: 2, buffer: 59)) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(40, rate: 2, buffer: 60)) == .prepare("2"))
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(42, rate: 2, buffer: 30)) == .cancel)
    }

    @Test func oneTransientFailureRetriesAfterBackoffOnlyWhileTheSameTailIsHealthy() {
        var state = EpisodePrefetchState()
        let eligible = context(80, rate: 2, buffer: 20)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: eligible, now: 0) == .prepare("2"))
        state.failed(episodeID: "1", nextEpisodeID: "2", error: CatalogError.network, now: 0)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: eligible, now: 0.99) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(80, rate: 2, buffer: 1), now: 1) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: eligible, now: 2) == .prepare("2"))
        for tick in 3...29 {
            #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: eligible, now: Double(tick)) == .none)
        }
    }

    @Test func repeatedFailuresStopAndACompletedOldRequestCannotAffectTheNewCandidate() {
        var state = EpisodePrefetchState()
        for second in [0.0, 1.0, 4.0] {
            #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90), now: second) == .prepare("2"))
            state.failed(episodeID: "1", nextEpisodeID: "2", error: CatalogError.httpStatus(503), now: second)
        }
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90), now: 20) == .none)
        #expect(state.update(episodeID: "2", nextEpisodeID: "3", context: context(90), now: 21) == .prepare("3"))
        state.failed(episodeID: "1", nextEpisodeID: "2", error: CatalogError.unauthorized, now: 21)
        #expect(state.update(episodeID: "2", nextEpisodeID: "3", context: context(90), now: 22) == .none)
    }

    @Test func terminalErrorsDoNotRetryWhenNetworkOrPauseChangesEligibility() {
        var state = EpisodePrefetchState()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90), now: 0) == .prepare("2"))
        state.failed(episodeID: "1", nextEpisodeID: "2", error: CatalogError.unauthorized, now: 0)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90, allowed: false), now: 1) == .none)
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90), now: 10) == .none)
        _ = state.reset()
        #expect(state.update(episodeID: "1", nextEpisodeID: "2", context: context(90), now: 11) == .prepare("2"))
    }
}
