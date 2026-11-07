// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PlaybackDoubleTapTests {
    @Test func leftAndRightAreasStayRelativeToTheCurrentSurfaceSize() {
        // Outer, unfolded portrait and unfolded landscape widths use the same regions.
        for width: Double in [320, 693, 1_071] {
            #expect(PlaybackDoubleTap.side(x: width * 0.25, width: width) == .backward)
            #expect(PlaybackDoubleTap.side(x: width * 0.75, width: width) == .forward)
        }
    }

    @Test func midpointAndSurfaceEdgesHaveOneDeterministicOwner() {
        let width: Double = 693
        let midpoint = width / 2
        #expect(PlaybackDoubleTap.side(x: 0, width: width) == .backward)
        #expect(PlaybackDoubleTap.side(x: midpoint.nextDown, width: width) == .backward)
        #expect(PlaybackDoubleTap.side(x: midpoint, width: width) == .forward)
        #expect(PlaybackDoubleTap.side(x: width, width: width) == .forward)
        #expect(PlaybackDoubleTap.side(x: -Double.leastNonzeroMagnitude, width: width) == nil)
        #expect(PlaybackDoubleTap.side(x: width.nextUp, width: width) == nil)
    }

    @Test func invalidOrUnavailableGeometryCannotProduceASeekDirection() {
        for invalid: Double in [.nan, .infinity, -.infinity] {
            #expect(PlaybackDoubleTap.side(x: invalid, width: 320) == nil)
            #expect(PlaybackDoubleTap.side(x: 100, width: invalid) == nil)
        }
        #expect(PlaybackDoubleTap.side(x: 0, width: 0) == nil)
        #expect(PlaybackDoubleTap.side(x: 0, width: -320) == nil)
    }

    @Test func recognizedSidesRequestOnlyTenSecondsInTheirOwnDirection() {
        #expect(PlaybackDoubleTap.seekOffset(side: .backward) == -10)
        #expect(PlaybackDoubleTap.seekOffset(side: .forward) == 10)
    }

    @Test func relativeSeekUsesTheClockWhenNoSeekIsPending() {
        #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                            offset: -10, duration: 120) == 30)
        #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                            offset: 10, duration: 120) == 50)
    }

    @Test func rapidSeeksAccumulateAndCanReverseWhileTheClockStillLags() {
        let first = PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                                offset: 10, duration: 120)
        let second = PlaybackRelativeSeek.target(current: 40, pendingTarget: first,
                                                 offset: 10, duration: 120)
        let third = PlaybackRelativeSeek.target(current: 40, pendingTarget: second,
                                                offset: -10, duration: 120)
        #expect(first == 50)
        #expect(second == 60)
        #expect(third == 50)
    }

    @Test func pendingTargetIsAuthoritativeEvenWhenTheClockIsUnavailable() {
        #expect(PlaybackRelativeSeek.target(current: .nan, pendingTarget: 60,
                                            offset: -10, duration: 120) == 50)
        #expect(PlaybackRelativeSeek.target(current: .infinity, pendingTarget: 60,
                                            offset: 10, duration: 120) == 70)
        for invalid: Double in [.nan, .infinity, -.infinity] {
            #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: invalid,
                                                offset: 10, duration: 120) == nil)
        }
    }

    @Test func seeksClampAtBothEndsAndCanImmediatelyReverseAwayFromTheBoundary() {
        #expect(PlaybackRelativeSeek.target(current: 5, pendingTarget: nil,
                                            offset: -10, duration: 120) == 0)
        #expect(PlaybackRelativeSeek.target(current: 115, pendingTarget: nil,
                                            offset: 10, duration: 120) == 120)
        #expect(PlaybackRelativeSeek.target(current: 115, pendingTarget: 120,
                                            offset: -10, duration: 120) == 110)
        #expect(PlaybackRelativeSeek.target(current: 5, pendingTarget: 0,
                                            offset: 10, duration: 120) == 10)
    }

    @Test func boundariesZeroOffsetAndSubMillisecondMovesDoNotSeek() {
        #expect(PlaybackRelativeSeek.target(current: 0, pendingTarget: nil,
                                            offset: -10, duration: 120) == nil)
        #expect(PlaybackRelativeSeek.target(current: 115, pendingTarget: 120,
                                            offset: 10, duration: 120) == nil)
        #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                            offset: 0, duration: 120) == nil)
        #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                            offset: 0.0005, duration: 120) == nil)
    }

    @Test func invalidRelativeSeekInputsAndArithmeticOverflowAreRejected() {
        for invalid: Double in [.nan, .infinity, -.infinity] {
            #expect(PlaybackRelativeSeek.target(current: invalid, pendingTarget: nil,
                                                offset: 10, duration: 120) == nil)
            #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                                offset: invalid, duration: 120) == nil)
            #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                                offset: 10, duration: invalid) == nil)
        }
        for invalidDuration: Double in [0, -120] {
            #expect(PlaybackRelativeSeek.target(current: 40, pendingTarget: nil,
                                                offset: 10, duration: invalidDuration) == nil)
        }
        #expect(PlaybackRelativeSeek.target(current: .greatestFiniteMagnitude, pendingTarget: nil,
                                            offset: .greatestFiniteMagnitude,
                                            duration: .greatestFiniteMagnitude) == nil)
    }
}
