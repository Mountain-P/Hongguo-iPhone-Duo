// SPDX-License-Identifier: GPL-3.0-only

/// An episode can recover from separate stalls after sustained playback resumes.
/// Replacing the player item preserves the episode's recovery limit.
public struct PlaybackStallRecoveryState: Sendable, Equatable {
    public enum Action: Sendable, Equatable { case none, reload, stopWaiting }

    public struct Context: Sendable, Equatable {
        public let time: Double
        public let position: Double
        public let waiting: Bool
        public let wantsPlayback: Bool
        public let sceneActive: Bool
        public let isReady: Bool
        public let isSeeking: Bool
        public let networkAvailable: Bool

        public init(time: Double, position: Double, waiting: Bool, wantsPlayback: Bool,
                    sceneActive: Bool, isReady: Bool, isSeeking: Bool, networkAvailable: Bool) {
            self.time = time; self.position = position; self.waiting = waiting
            self.wantsPlayback = wantsPlayback; self.sceneActive = sceneActive
            self.isReady = isReady; self.isSeeking = isSeeking; self.networkAvailable = networkAvailable
        }
    }

    private static let maximumRecoveries = 3
    private static let minimumRecoveryProgress = 10.0

    public var hasAttemptedRecovery: Bool { recoveryCount > 0 }
    public private(set) var isExhausted = false
    private var recoveryCount = 0
    private var canReload = true
    private var playbackProgressStart: Double?
    private var lastPlaybackPosition: Double?
    private var waitingSince: Double?
    private var anchorPosition: Double?
    private var lastTime: Double?

    public init() {}

    /// Time is monotonic seconds. Advancing media or any ineligible state starts a new window.
    public mutating func update(_ context: Context) -> Action {
        guard context.time.isFinite, context.time >= 0,
              lastTime.map({ context.time >= $0 }) ?? true else {
            clearWindow()
            clearPlaybackProgress()
            return .none
        }
        lastTime = context.time
        guard !isExhausted, context.position.isFinite, context.position >= 0,
              context.wantsPlayback, context.sceneActive,
              context.isReady, !context.isSeeking, context.networkAvailable else {
            clearWindow()
            clearPlaybackProgress()
            return .none
        }
        guard context.waiting else { clearWindow(); return .none }
        clearPlaybackProgress()
        if let anchorPosition, abs(context.position - anchorPosition) > 0.05 {
            clearWindow()
        }
        if waitingSince == nil {
            waitingSince = context.time
            anchorPosition = context.position
        }
        guard let waitingSince, context.time - waitingSince >= 12 else { return .none }
        if requestReload() { return .reload }
        clearWindow()
        isExhausted = true
        return .stopWaiting
    }

    /// A failed ready item and the stall watchdog consume the same recovery slot.
    public mutating func requestReload() -> Bool {
        guard !isExhausted, canReload, recoveryCount < Self.maximumRecoveries else { return false }
        recoveryCount += 1
        canReload = false
        clearWindow()
        clearPlaybackProgress()
        return true
    }

    /// Call from the periodic media clock while playback is active and not seeking.
    public mutating func recordPlaybackProgress(at position: Double) {
        guard !isExhausted, !canReload, recoveryCount < Self.maximumRecoveries else { return }
        guard position.isFinite, position >= 0 else { clearPlaybackProgress(); return }
        // The observer samples once per media second. Start over after a clock jump.
        if let lastPlaybackPosition, !(0...4).contains(position - lastPlaybackPosition) {
            playbackProgressStart = nil
        }
        lastPlaybackPosition = position
        if playbackProgressStart == nil { playbackProgressStart = position }
        if let playbackProgressStart, position - playbackProgressStart >= Self.minimumRecoveryProgress {
            canReload = true
            clearPlaybackProgress()
        }
    }

    public mutating func reset() { self = Self() }

    private mutating func clearWindow() {
        waitingSince = nil
        anchorPosition = nil
    }

    private mutating func clearPlaybackProgress() {
        playbackProgressStart = nil
        lastPlaybackPosition = nil
    }
}

/// A spinner is presentation only; this policy never commands a player or delays playback.
public struct BufferingIndicatorPolicy: Sendable, Equatable {
    private var waitingSince: Double?
    private var lastTime: Double?

    public init() {}

    public mutating func update(waiting: Bool, eligible: Bool, at time: Double) -> Bool {
        guard time.isFinite, time >= 0, lastTime.map({ time >= $0 }) ?? true else {
            waitingSince = nil
            return false
        }
        lastTime = time
        guard waiting, eligible else { waitingSince = nil; return false }
        if waitingSince == nil { waitingSince = time }
        return time - (waitingSince ?? time) >= 0.45
    }

    public mutating func reset() { self = Self() }
}

/// Media seconds reported as actually loaded by the player, never a desired buffer target.
public struct PlaybackBufferedRange: Sendable, Equatable {
    public let start: Double
    public let end: Double
    public init(start: Double, end: Double) { self.start = start; self.end = end }

    public func startFraction(duration: Double) -> Double {
        guard duration.isFinite, duration > 0, start.isFinite else { return 0 }
        return min(max(start / duration, 0), 1)
    }

    public func endFraction(duration: Double) -> Double {
        guard duration.isFinite, duration > 0, end.isFinite else { return 0 }
        return min(max(end / duration, 0), 1)
    }
}

public enum PlaybackBufferedRanges {
    /// Work and output are limited to the first 128 ranges. Gaps remain gaps.
    public static func normalized(_ ranges: [PlaybackBufferedRange], duration: Double) -> [PlaybackBufferedRange] {
        guard duration.isFinite, duration > 0 else { return [] }
        let valid = ranges.prefix(128).compactMap { range -> PlaybackBufferedRange? in
            guard range.start.isFinite, range.end.isFinite, range.end > range.start else { return nil }
            let start = min(max(range.start, 0), duration)
            let end = min(max(range.end, 0), duration)
            return end > start ? .init(start: start, end: end) : nil
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var result: [PlaybackBufferedRange] = []
        for range in valid {
            if let previous = result.last, range.start <= previous.end {
                result[result.count - 1] = .init(start: previous.start, end: max(previous.end, range.end))
            } else {
                result.append(range)
            }
        }
        return result
    }
}
