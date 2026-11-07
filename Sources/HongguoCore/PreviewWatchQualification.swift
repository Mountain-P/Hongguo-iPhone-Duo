// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Counts sampled, eligible wall time for this card's lifetime, never its media position.
public struct PreviewWatchQualification: Sendable {
    public private(set) var eligibleSeconds: TimeInterval = 0
    public private(set) var isQualified = false
    public private(set) var requiredSeconds: TimeInterval = 10
    private var lastInstant: TimeInterval?
    private var wasEligible = false
    private let now: @Sendable () -> TimeInterval
    /// A missed sample is unknown time; do not credit suspension or long scheduling gaps.
    public static let maximumSampleGap: TimeInterval = 1

    public init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    /// Returns true only on the first transition to qualified. Call at eligibility boundaries too.
    @discardableResult
    public mutating func update(isEligible: Bool, duration: Double) -> Bool {
        requiredSeconds = duration.isFinite && duration > 0 ? min(10, max(1, duration * 0.9)) : 10
        let instant = now()
        guard instant.isFinite else { wasEligible = false; lastInstant = nil; return false }
        if let previous = lastInstant {
            let delta = instant - previous
            if wasEligible, delta > 0, delta <= Self.maximumSampleGap {
                eligibleSeconds = min(10, eligibleSeconds + delta)
            }
            // A malformed/backward clock must not credit the same interval twice.
            lastInstant = max(previous, instant)
        } else { lastInstant = instant }
        wasEligible = isEligible
        guard !isQualified, eligibleSeconds >= requiredSeconds else { return false }
        isQualified = true
        return true
    }
}
