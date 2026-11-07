// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PlaybackBufferPolicyTests {
    @Test func formalTargetsKeepWallTimeAllowanceAtNormalAndAcceleratedRates() {
        for (rate, expected): (Float, Double) in [(0.75, 30), (1, 30), (1.5, 45), (2, 60), (4, 120)] {
            var policy = PlaybackBufferPolicy()
            #expect(policy.update(isPreview: false, rate: rate) == expected)
            #expect(!policy.hasWaited)
        }
    }

    @Test func previewHasSmallerTargetsAndItsOwnUpperBound() {
        for (rate, expected): (Float, Double) in [(0.75, 8), (1, 8), (1.5, 12), (2, 16), (4, 30)] {
            var policy = PlaybackBufferPolicy()
            #expect(policy.update(isPreview: true, rate: rate) == expected)
        }
    }

    @Test func aWaitingObservationRaisesAndPermanentlyRetainsTheItemsTier() {
        var formal = PlaybackBufferPolicy()
        #expect(formal.update(isPreview: false, rate: 2) == 60)
        #expect(formal.update(isPreview: false, rate: 2, waiting: true) == 90)
        #expect(formal.update(isPreview: false, rate: 2) == 90)
        #expect(formal.hasWaited)
        var preview = PlaybackBufferPolicy()
        #expect(preview.update(isPreview: true, rate: 1, waiting: true) == 12)
        #expect(preview.update(isPreview: true, rate: 2) == 24)
    }

    @Test func holdReleaseUnlockAndRapidSelectionsCannotOscillateTheTarget() {
        var speed = PlaybackSpeedState()
        var policy = PlaybackBufferPolicy()
        #expect(policy.update(isPreview: false, rate: speed.effectiveRate) == 30)
        speed.beginHold()
        #expect(policy.update(isPreview: false, rate: speed.effectiveRate) == 60)
        speed.lock(); speed.endHold(); speed.unlock()
        #expect(policy.update(isPreview: false, rate: speed.effectiveRate) == 60)
        for rate: Float in [0.75, 1.5, 1, 2, 1] {
            speed.selectRate(rate)
            #expect(policy.update(isPreview: false, rate: speed.effectiveRate) == 60)
        }
        #expect(!speed.wantsPlayback)
    }

    @Test func itemReplacementResetsBothTargetAndPriorWaitingHistory() {
        var policy = PlaybackBufferPolicy()
        #expect(policy.update(isPreview: false, rate: 2, waiting: true) == 90)
        policy.reset()
        #expect(policy.targetMediaSeconds == 0 && !policy.hasWaited)
        #expect(policy.update(isPreview: false, rate: 1) == 30)
        policy.reset()
        #expect(policy.update(isPreview: true, rate: 1) == 8)
    }

    @Test func promotionKeepsTheSameItemsWaitingHistoryAndRaisesToFormalBudget() {
        var policy = PlaybackBufferPolicy()
        #expect(policy.update(isPreview: true, rate: 2, waiting: true) == 24)
        #expect(policy.update(isPreview: false, rate: 2) == 90)
        #expect(policy.hasWaited)
    }

    @Test func largeValidRatesSaturateAndMalformedRatesCannotChangeState() {
        var formal = PlaybackBufferPolicy()
        #expect(formal.update(isPreview: false, rate: .greatestFiniteMagnitude, waiting: true) == 120)
        var preview = PlaybackBufferPolicy()
        #expect(preview.update(isPreview: true, rate: .greatestFiniteMagnitude, waiting: true) == 30)
        for rate: Float in [0, -1, .nan, .infinity, -.infinity] {
            var fresh = PlaybackBufferPolicy()
            #expect(fresh.update(isPreview: false, rate: rate, waiting: true) == 0)
            #expect(!fresh.hasWaited)
            var existing = PlaybackBufferPolicy()
            _ = existing.update(isPreview: true, rate: 1)
            let before = existing
            _ = existing.update(isPreview: false, rate: rate, waiting: true)
            #expect(existing == before)
        }
    }
}
