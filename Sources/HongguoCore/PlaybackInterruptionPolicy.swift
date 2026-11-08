// SPDX-License-Identifier: GPL-3.0-only

/// System audio events revoke playback intent; ending an interruption never grants it again.
public struct PlaybackInterruptionPolicy: Sendable, Equatable {
    public enum Event: Sendable { case began, ended, oldDeviceUnavailable, otherRouteChange }
    public enum Action: Sendable, Equatable { case pause, none }
    public private(set) var isInterrupted = false
    public init() {}

    public mutating func receive(_ event: Event) -> Action {
        switch event {
        case .began: isInterrupted = true; return .pause
        case .ended: isInterrupted = false; return .none
        case .oldDeviceUnavailable: return .pause
        case .otherRouteChange: return .none
        }
    }

    public func permitsPlayback(sceneActive: Bool) -> Bool { sceneActive && !isInterrupted }

    /// A manual play command may recover an interruption whose ending notification
    /// was missed while suspended, but only after the system grants audio again.
    /// Merely returning to the foreground never calls this or grants play intent.
    public mutating func activateForUserPlayback(sceneActive: Bool,
                                                activate: () throws -> Void) rethrows -> Bool {
        guard sceneActive else { return false }
        try activate()
        isInterrupted = false
        return true
    }

    public func shouldAdvanceAfterEnd(sceneActive: Bool, wantsPlayback: Bool, autoNext: Bool) -> Bool {
        permitsPlayback(sceneActive: sceneActive) && wantsPlayback && autoNext
    }
}
