// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PlaybackInterruptionTests {
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
}
