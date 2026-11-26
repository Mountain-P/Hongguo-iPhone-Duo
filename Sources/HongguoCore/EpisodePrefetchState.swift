// SPDX-License-Identifier: GPL-3.0-only

import Foundation

/// Only spend the retry budget on transient failures while the same next episode is relevant.
public struct EpisodePrefetchState: Sendable {
    public enum Decision: Sendable, Equatable { case none, cancel, prepare(String) }
    public struct Context: Sendable {
        public var elapsed: Double
        public var duration: Double
        public var rate: Float
        public var bufferedAhead: Double
        public var allowed: Bool

        public init(elapsed: Double, duration: Double, rate: Float, bufferedAhead: Double, allowed: Bool) {
            self.elapsed = elapsed; self.duration = duration; self.rate = rate
            self.bufferedAhead = bufferedAhead; self.allowed = allowed
        }
    }
    private var currentEpisode: String?
    private var nextEpisode: String?
    private var requested = false
    private var failureCount = 0
    private var retryAt: Double?
    private var stopped = false

    public init() {}

    public mutating func update(episodeID: String, nextEpisodeID: String?, context: Context,
                                now: Double = ProcessInfo.processInfo.systemUptime) -> Decision {
        let changed = currentEpisode != episodeID || nextEpisode != nextEpisodeID
        let replacedRequest = changed && requested
        if changed {
            self = Self()
            currentEpisode = episodeID
            nextEpisode = nextEpisodeID
        }
        let remaining = context.duration - context.elapsed
        guard context.allowed, let nextEpisodeID, nextEpisodeID != episodeID,
              context.elapsed.isFinite, context.elapsed >= 0, context.duration.isFinite, context.duration > 0,
              context.rate.isFinite, (0.25...4).contains(context.rate),
              remaining > 0, context.bufferedAhead.isFinite,
              context.bufferedAhead >= remaining, remaining / Double(context.rate) <= 30 else {
            let cancelled = suspend()
            return replacedRequest ? .cancel : cancelled
        }
        guard !requested, !stopped, retryAt.map({ now >= $0 }) ?? true else { return .none }
        requested = true
        return .prepare(nextEpisodeID)
    }

    public mutating func failed(episodeID: String, nextEpisodeID: String, error: any Error,
                                now: Double = ProcessInfo.processInfo.systemUptime) {
        guard currentEpisode == episodeID, nextEpisode == nextEpisodeID, requested else { return }
        requested = false
        failureCount += 1
        guard PlaybackRecovery.shouldRetry(error, attempt: 0), failureCount <= 2 else {
            stopped = true
            return
        }
        retryAt = now + (failureCount == 1 ? 1 : 3)
    }

    @discardableResult
    public mutating func suspend() -> Decision {
        let cancelled = requested
        requested = false
        return cancelled ? .cancel : .none
    }

    @discardableResult
    public mutating func reset() -> Decision {
        let decision = suspend()
        self = Self()
        return decision
    }
}
