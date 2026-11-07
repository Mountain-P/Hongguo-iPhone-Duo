// SPDX-License-Identifier: GPL-3.0-only

/// A bounded, transient preview transform. It never changes the media source or playhead.
public struct PreviewZoomState: Sendable, Equatable {
    public static let minimumScale: Double = 0.5
    public static let maximumScale: Double = 3
    public private(set) var scale: Double
    public private(set) var isPinching = false
    private var initialScale: Double
    private var previousMagnification: Double = 1

    public init(scale: Double = 1) {
        let valid = scale.isFinite && scale > 0 ? Self.clamped(scale) : 1
        self.scale = valid; self.initialScale = valid
    }

    /// Duplicate began events cannot move the rollback anchor of the same gesture.
    @discardableResult
    public mutating func beginPinch() -> Bool {
        guard !isPinching else { return false }
        isPinching = true; initialScale = scale; previousMagnification = 1
        return true
    }

    /// Input is the recognizer's cumulative scale. Applying each new ratio means a
    /// reversed pinch leaves a clamped boundary immediately instead of sticking there.
    @discardableResult
    public mutating func updatePinch(magnification: Double) -> Double? {
        guard isPinching, magnification.isFinite, magnification > 0 else { return nil }
        let ratio = magnification / previousMagnification
        previousMagnification = magnification
        scale = Self.clamped(scale * ratio)
        return scale
    }

    public mutating func endPinch() { isPinching = false }

    public mutating func cancelPinch() {
        guard isPinching else { return }
        scale = initialScale; isPinching = false
    }

    public mutating func zoomIn() { setScale(scale * 1.25) }
    public mutating func zoomOut() { setScale(scale / 1.25) }
    public mutating func reset() { setScale(1) }

    /// A menu command ends ownership by the old gesture; late changed events are ignored.
    public mutating func setScale(_ value: Double) {
        guard value.isFinite, value > 0 else { return }
        isPinching = false; scale = Self.clamped(value); initialScale = scale
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, minimumScale), maximumScale)
    }
}
