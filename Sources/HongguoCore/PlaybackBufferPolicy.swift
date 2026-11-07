// SPDX-License-Identifier: GPL-3.0-only

/// A preferred media-duration target, not a guarantee of buffered data or a startup gate.
/// One instance belongs to one player item; reset when that item is removed.
public struct PlaybackBufferPolicy: Sendable, Equatable {
    public private(set) var targetMediaSeconds: Double = 0
    public private(set) var hasWaited = false

    public init() {}

    /// A shorter temporary rate or a recovered stall never shrinks the current item's target.
    @discardableResult
    public mutating func update(isPreview: Bool, rate: Float, waiting: Bool = false) -> Double {
        guard rate.isFinite, rate > 0 else { return targetMediaSeconds }
        hasWaited = hasWaited || waiting
        let wallSeconds: Double = isPreview ? (hasWaited ? 12 : 8) : (hasWaited ? 45 : 30)
        let cap: Double = isPreview ? 30 : 120
        let requested = min(cap, wallSeconds * max(1, Double(rate)))
        targetMediaSeconds = max(targetMediaSeconds, requested)
        return targetMediaSeconds
    }

    public mutating func reset() {
        targetMediaSeconds = 0
        hasWaited = false
    }
}
