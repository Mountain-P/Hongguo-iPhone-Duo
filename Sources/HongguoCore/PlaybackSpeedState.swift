// SPDX-License-Identifier: GPL-3.0-only

/// Playback rate selection and temporary/locked hold gestures, independent of a player.
public struct PlaybackSpeedState: Sendable, Equatable {
    public private(set) var normalRate: Float = 1
    public private(set) var isPressing = false
    public private(set) var isLocked = false

    public var effectiveRate: Float { isPressing || isLocked ? 2 : normalRate }

    public init() {}

    public mutating func selectRate(_ rate: Float) {
        guard rate.isFinite, (0.25...4).contains(rate) else { return }
        normalRate = rate
        isPressing = false
        isLocked = false
    }

    public mutating func beginHold() { isPressing = true }

    /// Releasing a gesture or cancelling it in the background preserves an existing lock.
    public mutating func endHold() { isPressing = false }

    public mutating func lock() {
        isLocked = true
        isPressing = false
    }

    public mutating func unlock() {
        isLocked = false
        isPressing = false
    }
}
