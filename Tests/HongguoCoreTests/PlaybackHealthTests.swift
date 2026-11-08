// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PlaybackHealthTests {
    private func sample(_ time: Double, position: Double = 40, waiting: Bool = true,
                        wantsPlayback: Bool = true, sceneActive: Bool = true,
                        isReady: Bool = true, isSeeking: Bool = false,
                        networkAvailable: Bool = true) -> PlaybackStallRecoveryState.Context {
        .init(time: time, position: position, waiting: waiting, wantsPlayback: wantsPlayback,
              sceneActive: sceneActive, isReady: isReady, isSeeking: isSeeking,
              networkAvailable: networkAvailable)
    }

    @Test func sustainedWaitingReloadsOnceAndThenStopsOnceWithoutAnInfiniteLoop() {
        var state = PlaybackStallRecoveryState()
        #expect(state.update(sample(0)) == .none)
        #expect(state.update(sample(11.999)) == .none)
        #expect(state.update(sample(12)) == .reload)
        #expect(state.hasAttemptedRecovery && !state.isExhausted)
        #expect(state.update(sample(12.5, isReady: false)) == .none)
        #expect(state.update(sample(14)) == .none)
        #expect(state.update(sample(25.999)) == .none)
        #expect(state.update(sample(26)) == .stopWaiting)
        #expect(state.isExhausted)
        #expect(state.update(sample(100)) == .none)
    }

    @Test func pauseBackgroundSeekingOfflineAndPreparationCannotConsumeRecoveryBudget() {
        let blocked: [PlaybackStallRecoveryState.Context] = [
            sample(20, wantsPlayback: false), sample(20, sceneActive: false),
            sample(20, isReady: false), sample(20, isSeeking: true),
            sample(20, networkAvailable: false), sample(20, waiting: false)
        ]
        for context in blocked {
            var state = PlaybackStallRecoveryState()
            #expect(state.update(sample(0)) == .none)
            #expect(state.update(context) == .none)
            #expect(!state.hasAttemptedRecovery)
            #expect(state.update(sample(21)) == .none)
            #expect(state.update(sample(32.999)) == .none)
            #expect(state.update(sample(33)) == .reload)
        }
    }

    @Test func progressAndBackwardDiscontinuityRestartTheNoProgressWindow() {
        for position: Double in [41, 39] {
            var state = PlaybackStallRecoveryState()
            #expect(state.update(sample(0)) == .none)
            #expect(state.update(sample(11, position: position)) == .none)
            #expect(state.update(sample(22.999, position: position)) == .none)
            #expect(state.update(sample(23, position: position)) == .reload)
        }
    }

    @Test func smallClockMovementAccumulatesAgainstTheWindowAnchor() {
        var state = PlaybackStallRecoveryState()
        #expect(state.update(sample(0)) == .none)
        #expect(state.update(sample(4, position: 40.02)) == .none)
        #expect(state.update(sample(8, position: 40.04)) == .none)
        #expect(state.update(sample(11, position: 40.06)) == .none)
        #expect(state.update(sample(22.9, position: 40.06)) == .none)
        #expect(state.update(sample(23, position: 40.06)) == .reload)
    }

    @Test func laterOfflineOrPausedWindowsDoNotRestoreTheEpisodeBudget() {
        for offline in [true, false] {
            var state = PlaybackStallRecoveryState()
            _ = state.update(sample(0)); #expect(state.update(sample(12)) == .reload)
            let blocked = offline ? sample(15, networkAvailable: false) : sample(15, wantsPlayback: false)
            #expect(state.update(blocked) == .none)
            #expect(state.update(sample(30)) == .none)
            #expect(state.update(sample(42)) == .stopWaiting)
        }
    }

    @Test func explicitResetAllowsANewEpisodeOrManualRetryToRecoverAgain() {
        var state = PlaybackStallRecoveryState()
        _ = state.update(sample(0)); _ = state.update(sample(12))
        state.reset()
        #expect(!state.hasAttemptedRecovery && !state.isExhausted)
        #expect(state.update(sample(0)) == .none)
        #expect(state.update(sample(12)) == .reload)
    }

    @Test func invalidOrOldSamplesCannotTurnElapsedWallTimeIntoARecovery() {
        for context in [sample(.nan), sample(.infinity), sample(-1), sample(9),
                        sample(11, position: .nan), sample(11, position: .infinity), sample(11, position: -1)] {
            var state = PlaybackStallRecoveryState()
            _ = state.update(sample(10))
            #expect(state.update(context) == .none)
            #expect(state.update(sample(23)) == .none)
            #expect(state.update(sample(35)) == .reload)
        }
    }

    @Test func spinnerRequiresASustainedEligibleWaitAndDisappearsImmediatelyWhenItEnds() {
        var state = BufferingIndicatorPolicy()
        #expect(state.update(waiting: true, eligible: true, at: 0) == false)
        #expect(state.update(waiting: true, eligible: true, at: 0.449) == false)
        #expect(state.update(waiting: true, eligible: true, at: 0.45) == true)
        #expect(state.update(waiting: false, eligible: true, at: 0.46) == false)
        #expect(state.update(waiting: true, eligible: true, at: 1) == false)
        #expect(state.update(waiting: true, eligible: false, at: 2) == false)
        #expect(state.update(waiting: true, eligible: true, at: 3) == false)
        #expect(state.update(waiting: true, eligible: true, at: 3.5) == true)
    }

    @Test func separateBriefWaitsNeverAccumulateIntoASpinner() {
        var state = BufferingIndicatorPolicy()
        for start: Double in [0, 1, 2, 3] {
            #expect(state.update(waiting: true, eligible: true, at: start) == false)
            #expect(state.update(waiting: true, eligible: true, at: start + 0.2) == false)
            #expect(state.update(waiting: false, eligible: true, at: start + 0.3) == false)
        }
    }

    @Test func spinnerRejectsRegressedAndNonFiniteTimeAndResetDropsOldWaiting() {
        for invalid: Double in [0, .nan, .infinity, -.infinity, -1] {
            var state = BufferingIndicatorPolicy()
            _ = state.update(waiting: true, eligible: true, at: 1)
            #expect(state.update(waiting: true, eligible: true, at: invalid) == false)
            #expect(state.update(waiting: true, eligible: true, at: 3) == false)
            state.reset()
            #expect(state.update(waiting: true, eligible: true, at: 0) == false)
        }
    }

    @Test func bufferedRangesSortMergeClampAndKeepUnloadedGapsVisible() {
        let result = PlaybackBufferedRanges.normalized([
            .init(start: 40, end: 50), .init(start: 15, end: 22), .init(start: -2, end: 5),
            .init(start: 10, end: 18), .init(start: 22, end: 30), .init(start: 90, end: 120)
        ], duration: 100)
        #expect(result == [.init(start: 0, end: 5), .init(start: 10, end: 30),
                           .init(start: 40, end: 50), .init(start: 90, end: 100)])
        #expect(result[1].startFraction(duration: 100) == 0.1)
        #expect(result[1].endFraction(duration: 100) == 0.3)
    }

    @Test func invalidRangesAndDurationsNeverPaintInvalidGeometry() {
        let bad: [PlaybackBufferedRange] = [
            .init(start: .nan, end: 5), .init(start: 0, end: .infinity),
            .init(start: 5, end: 5), .init(start: 10, end: 3), .init(start: 101, end: 120),
            .init(start: -10, end: -2)
        ]
        #expect(PlaybackBufferedRanges.normalized(bad, duration: 100).isEmpty)
        for duration: Double in [0, -1, .nan, .infinity] {
            #expect(PlaybackBufferedRanges.normalized([.init(start: 0, end: 5)], duration: duration).isEmpty)
            #expect(PlaybackBufferedRange(start: 1, end: 5).startFraction(duration: duration) == 0)
        }
        #expect(PlaybackBufferedRange(start: -1, end: 120).startFraction(duration: 100) == 0)
        #expect(PlaybackBufferedRange(start: -1, end: 120).endFraction(duration: 100) == 1)
    }

    @Test func bufferInputAndOutputAreBoundedWithoutMergingSeparatedSegments() {
        let input = (0..<300).map { PlaybackBufferedRange(start: Double($0 * 2), end: Double($0 * 2 + 1)) }
        let result = PlaybackBufferedRanges.normalized(input, duration: 1_000)
        #expect(result.count == 128)
        #expect(result.last == .init(start: 254, end: 255))
    }
}
