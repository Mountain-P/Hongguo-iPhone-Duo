// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Serializes actual player seeks while retaining only the user's latest destination.
/// The owner decides whether playback should resume after the final completion.
public struct PlaybackSeekCoordinator: Sendable {
    public enum Kind: Sendable, Equatable {
        case relative, precise

        public var toleranceSeconds: Double { self == .relative ? 0.15 : 0 }
    }

    public struct Request: Sendable, Equatable {
        public let token: UUID
        public let target: Double
        public let kind: Kind
        public var toleranceSeconds: Double { kind.toleranceSeconds }

        fileprivate init(target: Double, kind: Kind) {
            token = UUID(); self.target = target; self.kind = kind
        }
    }

    private struct Destination: Sendable {
        let target: Double
        let kind: Kind
    }

    public private(set) var activeRequest: Request?
    private var queued: Destination?

    public init() {}

    /// Use this instead of the old player clock to accumulate relative skips.
    public var pendingTarget: Double? { queued?.target ?? activeRequest?.target }
    public var isSeeking: Bool { activeRequest != nil }

    /// Returns a command only when no seek is already active. The caller clamps
    /// targets to the current item's duration before submitting them.
    public mutating func submit(target: Double, kind: Kind) -> Request? {
        guard target.isFinite, target >= 0 else { return nil }
        guard let activeRequest else {
            let request = Request(target: target, kind: kind)
            self.activeRequest = request
            return request
        }
        if activeRequest.target == target,
           activeRequest.toleranceSeconds <= kind.toleranceSeconds {
            // Reversing back to the active destination cancels an obsolete queue.
            queued = nil
        } else {
            // Store only a destination; create its unique token if it is started.
            queued = Destination(target: target, kind: kind)
        }
        return nil
    }

    /// A failed seek still releases the slot and permits the latest request.
    /// Success/failure never changes playback intent. The owner uses `finished`
    /// only after checking that this token was the current active request.
    public mutating func complete(token: UUID, finished _: Bool) -> Request? {
        guard activeRequest?.token == token else { return nil }
        activeRequest = nil
        guard let destination = queued else { return nil }
        queued = nil
        let request = Request(target: destination.target, kind: destination.kind)
        activeRequest = request
        return request
    }

    /// Old completions cannot match a subsequent request's fresh UUID.
    public mutating func reset() {
        activeRequest = nil
        queued = nil
    }
}

/// A same-session reload retains the user's position, including the last frame.
/// Saved-history reopening alone applies the completed-episode replay heuristic.
public enum PlaybackResumeTarget {
    public static func target(position: Double, duration: Double, isLiveReload: Bool) -> Double? {
        guard position.isFinite, position >= 0, duration.isFinite, duration >= 0 else { return nil }
        guard duration > 0 else { return position }
        if isLiveReload { return min(position, duration) }
        if position >= duration - 1, position / duration >= 0.98 { return 0 }
        return min(position, max(duration - 0.5, 0))
    }
}
