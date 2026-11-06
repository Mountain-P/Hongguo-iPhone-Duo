// SPDX-License-Identifier: GPL-3.0-only

/// Playback rate selection and temporary/locked hold gestures, independent of a player.
public struct PlaybackSpeedState: Sendable, Equatable {
    public enum Transport: Sendable, Equatable { case paused, waiting, playing }
    public private(set) var normalRate: Float = 1
    public private(set) var isPressing = false
    public private(set) var isLocked = false
    public private(set) var wantsPlayback = false

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

    public mutating func requestPlayback() { wantsPlayback = true }

    /// Pausing or replacing an item cancels a temporary hold, retaining an explicit lock.
    public mutating func pause() { wantsPlayback = false; isPressing = false }
    public mutating func prepareForItem() { pause() }

    /// Rate changes may update an already requested waiting transport, but never start a paused one.
    /// An equal-rate KVO callback must not issue another playback command.
    public func rateAdjustment(transport: Transport, currentRate: Float, isReady: Bool, sceneActive: Bool) -> Float? {
        guard wantsPlayback, isReady, sceneActive, transport != .paused,
              !currentRate.isFinite || abs(currentRate - effectiveRate) > 0.0001 else { return nil }
        return effectiveRate
    }
}
