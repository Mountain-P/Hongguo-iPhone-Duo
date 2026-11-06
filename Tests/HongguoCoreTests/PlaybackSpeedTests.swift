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
}
