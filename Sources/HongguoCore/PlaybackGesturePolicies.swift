// SPDX-License-Identifier: GPL-3.0-only

/// One vertical gesture. The caller supplies translations from its original touch point.
/// This type never changes an episode; only `end` can return a destination, once.
public struct EpisodeSwipeState: Sendable, Equatable {
    public enum Direction: Sendable, Equatable { case previous, next }
    public enum BlockedReason: Sendable, Equatable {
        case firstEpisode, lastEpisode, unavailableEpisode, conflictingGesture, invalidInput
    }
    public struct Feedback: Sendable, Equatable {
        public let direction: Direction?
        public let progress: Double
        public let targetIndex: Int?
        public let blockedReason: BlockedReason?
        public let isArmed: Bool
    }

    public private(set) var isActive = true
    public private(set) var feedback = Feedback(direction: nil, progress: 0, targetIndex: nil,
                                               blockedReason: nil, isArmed: false)
    private let currentIndex: Int
    private let episodeAvailability: [Bool]
    private var disqualification: BlockedReason?

    public init(currentIndex: Int, episodeAvailability: [Bool]) {
        self.currentIndex = currentIndex
        self.episodeAvailability = episodeAvailability
    }

    @discardableResult
    public mutating func update(horizontal: Double, vertical: Double,
                                isHolding: Bool = false, isScrubbing: Bool = false) -> Feedback {
        guard isActive else { return feedback }
        if !horizontal.isFinite || !vertical.isFinite || !episodeAvailability.indices.contains(currentIndex) {
            disqualification = .invalidInput
        } else if isHolding || isScrubbing {
            disqualification = .conflictingGesture
        }
        guard horizontal.isFinite, vertical.isFinite else {
            feedback = Feedback(direction: nil, progress: 0, targetIndex: nil,
                                blockedReason: disqualification, isArmed: false)
            return feedback
        }

        let distance = abs(vertical)
        let horizontalDistance = abs(horizontal)
        let isVertical = distance > 0 && (horizontalDistance == 0 || distance / horizontalDistance > 1.2)
        guard isVertical else {
            feedback = Feedback(direction: nil, progress: 0, targetIndex: nil,
                                blockedReason: disqualification, isArmed: false)
            return feedback
        }

        let direction: Direction = vertical < 0 ? .next : .previous
        var target: Int?
        var blocked = disqualification
        if blocked == nil {
            if direction == .previous {
                if currentIndex == 0 { blocked = .firstEpisode }
                else { target = currentIndex - 1 }
            } else {
                if currentIndex == episodeAvailability.count - 1 { blocked = .lastEpisode }
                else { target = currentIndex + 1 }
            }
            if let target, !episodeAvailability[target] { blocked = .unavailableEpisode }
        }
        feedback = Feedback(direction: direction, progress: min(distance / 90, 1), targetIndex: target,
                            blockedReason: blocked, isArmed: distance > 90 && blocked == nil)
        return feedback
    }

    /// Re-check the final translation; crossing the threshold earlier does not commit a returned drag.
    public mutating func end(horizontal: Double, vertical: Double,
                             isHolding: Bool = false, isScrubbing: Bool = false) -> Int? {
        guard isActive else { return nil }
        let result = update(horizontal: horizontal, vertical: vertical,
                            isHolding: isHolding, isScrubbing: isScrubbing)
        isActive = false
        return result.isArmed ? result.targetIndex : nil
    }

    public mutating func cancel() {
        isActive = false
        feedback = Feedback(direction: nil, progress: 0, targetIndex: nil, blockedReason: nil, isArmed: false)
    }
}

/// A seek preview, independent of AVPlayer. `end` returns one seek; `cancel` returns none.
/// Horizontal input is cumulative translation, while sensitivity applies only to each new delta.
public struct FineScrubbingState: Sendable, Equatable {
    public enum Sensitivity: Sendable, Equatable {
        case full, half, quarter, tenth
        public var multiplier: Double {
            switch self {
            case .full: 1
            case .half: 0.5
            case .quarter: 0.25
            case .tenth: 0.1
            }
        }
    }

    public let initialPosition: Double
    public let duration: Double
    public private(set) var position: Double
    public private(set) var sensitivity: Sensitivity = .full
    public private(set) var isActive: Bool
    private let trackWidth: Double
    private var lastHorizontalTranslation: Double = 0

    public init(position: Double, duration: Double, trackWidth: Double) {
        let valid = position.isFinite && duration.isFinite && duration > 0 && trackWidth.isFinite && trackWidth > 0
        let origin = valid ? min(max(position, 0), duration) : 0
        self.initialPosition = origin
        self.position = origin
        self.duration = duration.isFinite && duration > 0 ? duration : 0
        self.trackWidth = trackWidth
        self.isActive = valid
    }

    /// Upward distance is measured from the seek track; negative values retain full sensitivity.
    /// Invalid samples are ignored without changing either the preview or the previous translation.
    @discardableResult
    public mutating func update(horizontalTranslation: Double, upwardDistance: Double) -> Double? {
        guard isActive, horizontalTranslation.isFinite, upwardDistance.isFinite else { return nil }
        switch upwardDistance {
        case 150...: sensitivity = .tenth
        case 100...: sensitivity = .quarter
        case 50...: sensitivity = .half
        default: sensitivity = .full
        }
        let delta = horizontalTranslation - lastHorizontalTranslation
        lastHorizontalTranslation = horizontalTranslation
        let seconds = delta / trackWidth * sensitivity.multiplier * duration
        position = min(max(position + seconds, 0), duration)
        return position
    }

    public mutating func end() -> Double? {
        guard isActive else { return nil }
        isActive = false
        return position
    }

    public mutating func cancel() {
        guard isActive else { return }
        isActive = false
        position = initialPosition
    }
}
