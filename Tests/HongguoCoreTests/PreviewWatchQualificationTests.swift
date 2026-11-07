// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private final class PreviewWatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
    func set(_ instant: TimeInterval) { lock.withLock { value = instant } }
}

struct PreviewWatchQualificationTests {
    @Test func firstFrameAndRepeatedSamplesWithoutElapsedTimeDoNotQualify() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        for _ in 0..<100 { policy.update(isEligible: true, duration: 120) }
        #expect(policy.eligibleSeconds == 0)
        #expect(!policy.isQualified)
        advance(&policy, clock: clock, seconds: 9.75)
        #expect(!policy.isQualified)
        clock.advance(0.25)
        let newlyQualified = policy.update(isEligible: true, duration: 120)
        #expect(newlyQualified && policy.isQualified)
        #expect(policy.eligibleSeconds == 10)
    }

    @Test func nonPlayingBufferingPagingOrBackgroundIntervalsAreNotCredited() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        policy.update(isEligible: false, duration: 120)
        advance(&policy, clock: clock, seconds: 5, eligible: false)
        #expect(policy.eligibleSeconds == 0)
        policy.update(isEligible: true, duration: 120)
        advance(&policy, clock: clock, seconds: 3)
        for _ in 0..<4 {
            policy.update(isEligible: false, duration: 120)
            advance(&policy, clock: clock, seconds: 4, eligible: false)
            #expect(policy.eligibleSeconds == 3)
        }
        policy.update(isEligible: true, duration: 120)
        advance(&policy, clock: clock, seconds: 7)
        #expect(policy.isQualified)
    }

    @Test func shortFirstEpisodeCanQualifyAtNaturalEndUsingItsActualWallTime() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        policy.update(isEligible: true, duration: 4)
        #expect(abs(policy.requiredSeconds - 3.6) < 0.001)
        advance(&policy, clock: clock, seconds: 3.5, duration: 4)
        #expect(!policy.isQualified)
        clock.advance(0.25)
        let qualifiedAtClosingInterval = policy.update(isEligible: false, duration: 4)
        #expect(qualifiedAtClosingInterval)
        #expect(policy.eligibleSeconds == 3.75)
    }

    @Test func seekingOrAcceleratedMediaProgressCannotReplaceEligibleWallTime() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        policy.update(isEligible: true, duration: 4)
        // A seek to EOF changes media position, not this clock or its accumulated time.
        for _ in 0..<100 { policy.update(isEligible: true, duration: 4) }
        #expect(policy.eligibleSeconds == 0 && !policy.isQualified)
        // Four media seconds played at 2x are only two eligible wall seconds.
        advance(&policy, clock: clock, seconds: 2, duration: 4)
        policy.update(isEligible: false, duration: 4)
        #expect(policy.eligibleSeconds == 2 && !policy.isQualified)
        advance(&policy, clock: clock, seconds: 2, duration: 4, eligible: false)
        #expect(policy.eligibleSeconds == 2)
        policy.update(isEligible: true, duration: 4)
        advance(&policy, clock: clock, seconds: 1.75, duration: 4)
        #expect(policy.isQualified)

    }

    @Test func unknownDurationCanBecomeKnownWithoutLosingOrInventingWatchedTime() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        policy.update(isEligible: true, duration: 0)
        advance(&policy, clock: clock, seconds: 2, duration: 0)
        #expect(policy.requiredSeconds == 10 && !policy.isQualified)
        policy.update(isEligible: true, duration: 4)
        #expect(policy.eligibleSeconds == 2 && !policy.isQualified)
        advance(&policy, clock: clock, seconds: 1.75, duration: 4)
        #expect(policy.isQualified)

        var enoughBeforeMetadata = PreviewWatchQualification(now: { clock.now })
        enoughBeforeMetadata.update(isEligible: true, duration: 0)
        advance(&enoughBeforeMetadata, clock: clock, seconds: 5, duration: 0)
        let corrected = enoughBeforeMetadata.update(isEligible: true, duration: 4)
        #expect(corrected && enoughBeforeMetadata.isQualified)
        #expect(enoughBeforeMetadata.eligibleSeconds == 5)
    }

    @Test func durationCorrectionRaisesThresholdAndQualificationEmitsAtMostOnce() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        policy.update(isEligible: true, duration: 4)
        advance(&policy, clock: clock, seconds: 2, duration: 4)
        policy.update(isEligible: true, duration: 120)
        advance(&policy, clock: clock, seconds: 2)
        #expect(policy.requiredSeconds == 10 && !policy.isQualified)
        var transitions = 0
        for _ in 0..<40 {
            clock.advance(0.25)
            if policy.update(isEligible: true, duration: 120) { transitions += 1 }
        }
        #expect(transitions == 1 && policy.isQualified)
        clock.advance(0.25)
        let afterMetadataChange = policy.update(isEligible: false, duration: 0)
        #expect(!afterMetadataChange && policy.isQualified)
    }

    @Test func returningToTheSameCardRetainsTimeButANewCardStartsEmpty() {
        let clock = PreviewWatchClock()
        var retained = PreviewWatchQualification(now: { clock.now })
        retained.update(isEligible: true, duration: 120)
        advance(&retained, clock: clock, seconds: 6)
        retained.update(isEligible: false, duration: 120)
        clock.advance(60)
        retained.update(isEligible: true, duration: 120)
        #expect(retained.eligibleSeconds == 6)
        var replacement = PreviewWatchQualification(now: { clock.now })
        replacement.update(isEligible: true, duration: 120)
        advance(&retained, clock: clock, seconds: 4)
        #expect(retained.isQualified)
        #expect(replacement.eligibleSeconds == 0 && !replacement.isQualified)
    }

    @Test func missedSamplesAndBackwardClockDoNotCreditUnknownOrDuplicateIntervals() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        policy.update(isEligible: true, duration: 120)
        clock.advance(0.5); policy.update(isEligible: true, duration: 120)
        clock.set(-1); policy.update(isEligible: true, duration: 120)
        clock.set(0.75); policy.update(isEligible: true, duration: 120)
        #expect(policy.eligibleSeconds == 0.75)
        clock.advance(30); policy.update(isEligible: true, duration: 120)
        #expect(policy.eligibleSeconds == 0.75 && !policy.isQualified)
        clock.advance(0.25); policy.update(isEligible: true, duration: 120)
        #expect(policy.eligibleSeconds == 1)
        clock.set(.infinity); policy.update(isEligible: true, duration: 120)
        clock.set(31.25); policy.update(isEligible: true, duration: 120)
        #expect(policy.eligibleSeconds == 1)
    }

    @Test func invalidDurationUsesTenSecondsAndTinyClipsHaveAMinimumDwell() {
        let clock = PreviewWatchClock()
        var policy = PreviewWatchQualification(now: { clock.now })
        for duration in [Double.nan, .infinity, -1, 0] {
            policy.update(isEligible: false, duration: duration)
            #expect(policy.requiredSeconds == 10 && !policy.isQualified)
        }
        policy.update(isEligible: true, duration: 0.25)
        #expect(policy.requiredSeconds == 1)
        advance(&policy, clock: clock, seconds: 1, duration: 0.25)
        #expect(policy.isQualified)
    }

    private func advance(_ policy: inout PreviewWatchQualification, clock: PreviewWatchClock,
                         seconds: TimeInterval, duration: Double = 120, eligible: Bool = true) {
        var remaining = seconds
        while remaining > 0 {
            let step = min(0.25, remaining)
            clock.advance(step)
            policy.update(isEligible: eligible, duration: duration)
            remaining -= step
        }
    }
}
