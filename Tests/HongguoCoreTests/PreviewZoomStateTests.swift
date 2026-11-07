// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PreviewZoomStateTests {
    @Test func pinchUsesTheCurrentScaleAndCumulativeRecognizerRatios() {
        var state = PreviewZoomState(scale: 1.5)
        let began = state.beginPinch()
        #expect(began)
        #expect(abs((state.updatePinch(magnification: 1.2) ?? 0) - 1.8) < 0.000_001)
        #expect(abs((state.updatePinch(magnification: 1.4) ?? 0) - 2.1) < 0.000_001)
        state.endPinch()
        #expect(!state.isPinching)
        #expect(state.updatePinch(magnification: 2) == nil)
        #expect(abs(state.scale - 2.1) < 0.000_001)
    }

    @Test func clampedPinchesReverseImmediatelyAtBothBounds() {
        var state = PreviewZoomState()
        state.beginPinch()
        #expect(state.updatePinch(magnification: 10) == 3)
        #expect(state.updatePinch(magnification: 5) == 1.5)
        #expect(state.updatePinch(magnification: 0.1) == 0.5)
        #expect(state.updatePinch(magnification: 0.2) == 1)
    }

    @Test func cancellationRestoresOnlyThisPinchsStartingScale() {
        var state = PreviewZoomState(scale: 2)
        state.beginPinch(); _ = state.updatePinch(magnification: 0.5)
        state.cancelPinch()
        #expect(state.scale == 2 && !state.isPinching)
        #expect(state.updatePinch(magnification: 1.5) == nil)
        state.beginPinch(); _ = state.updatePinch(magnification: 1.25); state.endPinch()
        state.cancelPinch()
        #expect(state.scale == 2.5)
    }

    @Test func duplicateBeginDoesNotReplaceTheOriginalRollbackAnchor() {
        var state = PreviewZoomState()
        let began = state.beginPinch()
        #expect(began)
        _ = state.updatePinch(magnification: 2)
        let repeated = state.beginPinch()
        #expect(!repeated)
        _ = state.updatePinch(magnification: 2.5)
        state.cancelPinch()
        #expect(state.scale == 1)
    }

    @Test func invalidSamplesCannotCorruptTheScaleOrTheIncrementalAnchor() {
        var state = PreviewZoomState()
        state.beginPinch(); _ = state.updatePinch(magnification: 1.5)
        for invalid: Double in [.nan, .infinity, -.infinity, 0, -1] {
            #expect(state.updatePinch(magnification: invalid) == nil)
            #expect(state.scale == 1.5)
        }
        #expect(state.updatePinch(magnification: 2) == 2)
    }

    @Test func menuCommandsAreBoundedAndSupersedeAnInFlightGesture() {
        var state = PreviewZoomState()
        for _ in 0..<30 { state.zoomIn() }
        #expect(state.scale == 3)
        for _ in 0..<30 { state.zoomOut() }
        #expect(state.scale == 0.5)
        state.beginPinch(); _ = state.updatePinch(magnification: 2)
        state.reset()
        #expect(state.scale == 1 && !state.isPinching)
        #expect(state.updatePinch(magnification: 4) == nil)
        state.cancelPinch()
        #expect(state.scale == 1)
    }

    @Test func constructionAndExplicitScaleChangesRejectInvalidValues() {
        for invalid: Double in [.nan, .infinity, -.infinity, 0, -1] {
            var state = PreviewZoomState(scale: invalid)
            #expect(state.scale == 1)
            state.setScale(invalid)
            #expect(state.scale == 1)
        }
        #expect(PreviewZoomState(scale: 100).scale == 3)
        #expect(PreviewZoomState(scale: 0.01).scale == 0.5)
    }

    @Test func extremeFinitePinchRatiosSaturateWithoutNaN() {
        var state = PreviewZoomState()
        state.beginPinch()
        #expect(state.updatePinch(magnification: .leastNonzeroMagnitude) == 0.5)
        #expect(state.updatePinch(magnification: .greatestFiniteMagnitude) == 3)
        #expect(state.updatePinch(magnification: .leastNonzeroMagnitude) == 0.5)
        state.cancelPinch()
        #expect(state.scale == 1)
    }
}
