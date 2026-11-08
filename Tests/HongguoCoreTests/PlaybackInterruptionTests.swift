// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PlaybackInterruptionTests {
    private enum ActivationFailure: Error { case audioBusy }

    @Test func queuedEndRespectsTheLatestPauseAndSceneIntent() {
        let policy = PlaybackInterruptionPolicy()
        var speed = PlaybackSpeedState()
        speed.requestPlayback()
        #expect(policy.shouldAdvanceAfterEnd(sceneActive: true, wantsPlayback: speed.wantsPlayback, autoNext: true))
        speed.pause()
        #expect(!policy.shouldAdvanceAfterEnd(sceneActive: true, wantsPlayback: speed.wantsPlayback, autoNext: true))
        speed.requestPlayback()
        #expect(!policy.shouldAdvanceAfterEnd(sceneActive: false, wantsPlayback: speed.wantsPlayback, autoNext: true))
        #expect(!policy.shouldAdvanceAfterEnd(sceneActive: true, wantsPlayback: speed.wantsPlayback, autoNext: false))
    }

    @Test func interruptionRevokesBoostAndPlayIntentUntilAnExplicitLaterPlay() {
        var policy = PlaybackInterruptionPolicy()
        var speed = PlaybackSpeedState()
        speed.selectRate(1.5); speed.requestPlayback(); speed.beginHold()
        if policy.receive(.began) == .pause { speed.pause() }
        #expect(!speed.wantsPlayback && !speed.isPressing)
        #expect(speed.effectiveRate == 1.5)
        #expect(!policy.permitsPlayback(sceneActive: true))
        #expect(!policy.shouldAdvanceAfterEnd(sceneActive: true, wantsPlayback: true, autoNext: true))
        #expect(policy.receive(.ended) == .none)
        #expect(!speed.wantsPlayback)
        #expect(policy.permitsPlayback(sceneActive: true))
        speed.requestPlayback()
        #expect(policy.shouldAdvanceAfterEnd(sceneActive: true, wantsPlayback: speed.wantsPlayback, autoNext: true))
    }

    @Test func disconnectPausesButOrdinaryRouteChangesDoNotAndCannotEndAnInterruption() {
        var policy = PlaybackInterruptionPolicy()
        var speed = PlaybackSpeedState()
        speed.requestPlayback()
        #expect(policy.receive(.otherRouteChange) == .none)
        #expect(speed.wantsPlayback)
        if policy.receive(.oldDeviceUnavailable) == .pause { speed.pause() }
        #expect(!speed.wantsPlayback)
        #expect(policy.permitsPlayback(sceneActive: true))
        _ = policy.receive(.began)
        #expect(policy.receive(.otherRouteChange) == .none)
        #expect(policy.isInterrupted)
        #expect(policy.receive(.ended) == .none)
        #expect(!policy.permitsPlayback(sceneActive: false))
        #expect(!speed.wantsPlayback)
    }

    @Test func manualActivationRecoversAMissingEndWithoutChangingPausedIntent() {
        var policy = PlaybackInterruptionPolicy()
        var speed = PlaybackSpeedState()
        speed.selectRate(1.5); speed.requestPlayback(); speed.lock()
        if policy.receive(.began) == .pause { speed.pause() }
        #expect(!policy.permitsPlayback(sceneActive: false))
        // Returning to the foreground alone neither clears the interruption nor plays.
        #expect(!policy.permitsPlayback(sceneActive: true))
        #expect(!speed.wantsPlayback)

        var activations = 0
        #expect(policy.activateForUserPlayback(sceneActive: true) { activations += 1 })
        #expect(activations == 1)
        #expect(policy.permitsPlayback(sceneActive: true))
        #expect(!speed.wantsPlayback)
        #expect(speed.isLocked && speed.effectiveRate == 2 && speed.normalRate == 1.5)
        speed.requestPlayback()
        #expect(policy.shouldAdvanceAfterEnd(sceneActive: true, wantsPlayback: speed.wantsPlayback, autoNext: true))
    }

    @Test func deniedAudioActivationKeepsTheInterruptionAndAllowsManualRetry() {
        var policy = PlaybackInterruptionPolicy()
        var speed = PlaybackSpeedState()
        speed.requestPlayback()
        if policy.receive(.began) == .pause { speed.pause() }
        var activations = 0
        #expect(throws: ActivationFailure.audioBusy) {
            try policy.activateForUserPlayback(sceneActive: true) {
                activations += 1
                throw ActivationFailure.audioBusy
            }
        }
        #expect(activations == 1)
        #expect(policy.isInterrupted)
        #expect(!policy.permitsPlayback(sceneActive: true))
        #expect(!speed.wantsPlayback)

        #expect(policy.activateForUserPlayback(sceneActive: true) { activations += 1 })
        #expect(activations == 2)
        #expect(!policy.isInterrupted)
        #expect(!speed.wantsPlayback)
    }

    @Test func backgroundCommandsNeverAskForAudioOrClearAnInterruption() throws {
        for interrupted in [false, true] {
            var policy = PlaybackInterruptionPolicy()
            if interrupted { _ = policy.receive(.began) }
            var activations = 0
            let allowed = try policy.activateForUserPlayback(sceneActive: false) {
                activations += 1
                throw ActivationFailure.audioBusy
            }
            #expect(!allowed)
            #expect(activations == 0)
            #expect(policy.isInterrupted == interrupted)
            #expect(!policy.permitsPlayback(sceneActive: false))
        }
    }

    @Test func manualPlayReactivatesAudioEvenWithoutAnInterruptionNotification() {
        var policy = PlaybackInterruptionPolicy()
        var activations = 0
        #expect(policy.activateForUserPlayback(sceneActive: true) { activations += 1 })
        #expect(activations == 1)
        #expect(!policy.isInterrupted)
        #expect(policy.permitsPlayback(sceneActive: true))

        #expect(throws: ActivationFailure.audioBusy) {
            try policy.activateForUserPlayback(sceneActive: true) {
                activations += 1
                throw ActivationFailure.audioBusy
            }
        }
        #expect(activations == 2)
        #expect(!policy.isInterrupted)
    }

    @Test func repeatedInterruptionCyclesAndLateEndEventsKeepExplicitPlaybackIntent() {
        var policy = PlaybackInterruptionPolicy()
        var speed = PlaybackSpeedState()
        var activations = 0
        for _ in 0..<3 {
            speed.requestPlayback()
            for _ in 0..<2 {
                if policy.receive(.began) == .pause { speed.pause() }
            }
            #expect(policy.isInterrupted && !speed.wantsPlayback)
            #expect(policy.activateForUserPlayback(sceneActive: true) { activations += 1 })
            #expect(!speed.wantsPlayback)
            // A late ended notification must not independently start playback.
            #expect(policy.receive(.ended) == .none)
            #expect(!speed.wantsPlayback)
            speed.requestPlayback()
            #expect(policy.permitsPlayback(sceneActive: true) && speed.wantsPlayback)
            #expect(policy.receive(.ended) == .none)
            #expect(speed.wantsPlayback)
        }
        #expect(activations == 3)
    }
}
