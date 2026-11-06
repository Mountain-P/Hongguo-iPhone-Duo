// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PlaybackSpeedTests {
    @Test func holdTemporarilyAcceleratesAndReleaseRestoresSelectedRate() {
        var state = PlaybackSpeedState()
        #expect(state.normalRate == 1)
        #expect(state.effectiveRate == 1)
        state.selectRate(1.5)
        state.beginHold()
        #expect(state.normalRate == 1.5)
        #expect(state.isPressing)
        #expect(state.effectiveRate == 2)
        state.endHold()
        #expect(!state.isPressing)
        #expect(!state.isLocked)
        #expect(state.effectiveRate == 1.5)
    }

    @Test func committingLockPersistsAfterRelease() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.beginHold()
        state.lock()
        #expect(state.isLocked)
        #expect(!state.isPressing)
        state.endHold()
        #expect(state.effectiveRate == 2)
        #expect(state.normalRate == 1.5)
    }

    @Test func holdingAgainAndUnlockingImmediatelyRestoresSelectedRate() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.lock()
        state.beginHold()
        state.unlock()
        #expect(!state.isLocked)
        #expect(!state.isPressing)
        #expect(state.effectiveRate == 1.5)
        state.endHold()
        #expect(state.effectiveRate == 1.5)
    }

    @Test func backgroundCancellationClearsHoldAndPreservesAnExistingLock() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.beginHold()
        state.endHold()
        #expect(state.effectiveRate == 1.5)
        state.lock()
        state.beginHold()
        state.endHold()
        #expect(!state.isPressing)
        #expect(state.isLocked)
        #expect(state.effectiveRate == 2)
    }

    @Test func selectingManualRateClearsBothHoldAndLock() {
        var state = PlaybackSpeedState()
        state.lock()
        state.beginHold()
        state.selectRate(0.75)
        #expect(state.normalRate == 0.75)
        #expect(state.effectiveRate == 0.75)
        #expect(!state.isLocked)
        #expect(!state.isPressing)
        for boundary: Float in [0.25, 4] {
            state.selectRate(boundary)
            #expect(state.normalRate == boundary)
        }
    }

    @Test func invalidRatesPreserveEveryPartOfTheState() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.lock()
        state.beginHold()
        let previous = state
        for rate: Float in [.nan, .infinity, -.infinity, -1, 0, 0.249, 4.001] {
            state.selectRate(rate)
            #expect(state == previous)
        }
    }

    @Test func repeatedCommitAndReleaseCannotAccidentallyUnlock() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.beginHold()
        for _ in 0..<5 {
            state.lock()
            state.endHold()
            #expect(state.isLocked)
            #expect(!state.isPressing)
            #expect(state.effectiveRate == 2)
        }
        state.unlock()
        state.unlock()
        state.endHold()
        #expect(state.effectiveRate == 1.5)
    }

    @Test func rapidManualSelectionsUpdateAWaitingTransportWithoutFeedbackCommands() {
        var state = PlaybackSpeedState()
        state.requestPlayback()
        var requestedRate: Float = 1
        for rate: Float in [2, 1, 2, 1, 2, 1] {
            state.selectRate(rate)
            let command = state.rateAdjustment(transport: .waiting, currentRate: requestedRate,
                                               isReady: true, sceneActive: true)
            #expect(command == rate)
            requestedRate = command ?? requestedRate
            // A waiting/playing observation of that same request is not another
            // rate command, so it cannot feed a KVO -> rate -> KVO loop.
            for transport: PlaybackSpeedState.Transport in [.waiting, .playing, .playing] {
                #expect(state.rateAdjustment(transport: transport, currentRate: requestedRate,
                                             isReady: true, sceneActive: true) == nil)
            }
        }
    }

    @Test func holdLockAndUnlockRestoreTheNormalRateEvenDuringBuffering() {
        var state = PlaybackSpeedState()
        state.selectRate(1.25)
        state.requestPlayback()
        state.beginHold()
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 1.25,
                                     isReady: true, sceneActive: true) == 2)
        state.lock()
        state.endHold()
        #expect(state.effectiveRate == 2)
        state.beginHold()
        state.unlock()
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 2,
                                     isReady: true, sceneActive: true) == 1.25)
        state.endHold()
        #expect(state.effectiveRate == 1.25)
        state.lock()
        // Selecting the already saved normal rate is still an explicit unlock.
        state.selectRate(1.25)
        #expect(!state.isLocked)
        #expect(state.effectiveRate == 1.25)
    }

    @Test func changingSpeedWhilePausedNeverRestartsPlayback() {
        var state = PlaybackSpeedState()
        state.requestPlayback()
        state.pause()
        for rate: Float in [2, 1, 1.5, 2, 1] {
            state.selectRate(rate)
            #expect(state.effectiveRate == rate)
            for transport: PlaybackSpeedState.Transport in [.paused, .waiting, .playing] {
                #expect(state.rateAdjustment(transport: transport, currentRate: 0,
                                             isReady: true, sceneActive: true) == nil)
            }
        }
        state.beginHold()
        state.lock()
        #expect(!state.wantsPlayback)
        #expect(state.rateAdjustment(transport: .paused, currentRate: 0,
                                     isReady: true, sceneActive: true) == nil)
        state.unlock()
        state.requestPlayback()
        #expect(state.effectiveRate == 1)
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: true) == 1)
    }

    @Test func pausingWhileWaitingCancelsTheHoldAndIgnoresLateClockObservations() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.requestPlayback()
        state.beginHold()
        state.pause()
        #expect(!state.isPressing)
        #expect(!state.wantsPlayback)
        #expect(state.effectiveRate == 1.5)
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 2,
                                     isReady: true, sceneActive: true) == nil)
        state.requestPlayback()
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 2,
                                     isReady: true, sceneActive: true) == 1.5)
    }

    @Test func pauseAndSceneChangesRetainAnExplicitLockWithoutAutoplay() {
        var state = PlaybackSpeedState()
        state.selectRate(0.75)
        state.requestPlayback()
        state.lock()
        state.pause()
        #expect(state.isLocked)
        #expect(state.effectiveRate == 2)
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: true) == nil)
        state.requestPlayback()
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: false) == nil)
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: false, sceneActive: true) == nil)
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: true) == 2)
    }

    @Test func episodeReplacementDropsTemporaryBoostAndRequiresANewPlayRequest() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.requestPlayback()
        state.beginHold()
        state.prepareForItem()
        #expect(!state.isPressing)
        #expect(!state.wantsPlayback)
        #expect(state.effectiveRate == 1.5)
        #expect(state.rateAdjustment(transport: .playing, currentRate: 2,
                                     isReady: true, sceneActive: true) == nil)
        state.requestPlayback()
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 2,
                                     isReady: true, sceneActive: true) == 1.5)
        state.lock()
        state.prepareForItem()
        #expect(state.isLocked)
        #expect(!state.wantsPlayback)
        state.requestPlayback()
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: true) == 2)
    }

    @Test func automaticRecoveryPreservesPauseWhileExplicitRetryCanRequestPlayback() {
        var state = PlaybackSpeedState()
        state.selectRate(1.5)
        state.requestPlayback()
        state.beginHold()
        state.pause()
        let recoveryIntent = state.wantsPlayback
        state.prepareForItem(autoplay: recoveryIntent)
        #expect(!state.wantsPlayback)
        #expect(!state.isPressing)
        #expect(state.effectiveRate == 1.5)
        // Even a late ready/waiting observation after recovery cannot restart it.
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: true) == nil)
        state.prepareForItem(autoplay: true)
        #expect(state.wantsPlayback)
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: true) == 1.5)
    }

    @Test func backgroundPauseDuringRecoveryCancelsThePendingAutoplayIntent() {
        var state = PlaybackSpeedState()
        state.requestPlayback()
        state.lock()
        let recoveryIntent = state.wantsPlayback
        state.prepareForItem(autoplay: recoveryIntent)
        #expect(state.wantsPlayback)
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: false, sceneActive: true) == nil)
        state.pause()
        #expect(state.isLocked)
        #expect(!state.wantsPlayback)
        // Returning to the foreground and finishing the old load does not undo pause.
        #expect(state.rateAdjustment(transport: .waiting, currentRate: 0,
                                     isReady: true, sceneActive: true) == nil)
    }
}
