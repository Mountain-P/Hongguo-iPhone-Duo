// SPDX-License-Identifier: GPL-3.0-only

/// A bounded, once-per-eligible-window decision; media preparation itself owns cancellation.
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
    private var requestedEpisode: String?
    private var currentEpisode: String?
    public init() {}

    public mutating func update(episodeID: String, nextEpisodeID: String?, context: Context) -> Decision {
        let remaining = context.duration - context.elapsed
        guard context.allowed, let nextEpisodeID, nextEpisodeID != episodeID,
              context.elapsed.isFinite, context.elapsed >= 0, context.duration.isFinite, context.duration > 0,
              context.rate.isFinite, (0.25...4).contains(context.rate),
              remaining > 0, context.bufferedAhead.isFinite,
              context.bufferedAhead >= min(remaining, 12 * max(1, Double(context.rate))),
              remaining / Double(context.rate) <= 12 else { return reset() }
        guard currentEpisode != episodeID || requestedEpisode != nextEpisodeID else { return .none }
        currentEpisode = episodeID; requestedEpisode = nextEpisodeID
        return .prepare(nextEpisodeID)
    }

    @discardableResult
    public mutating func reset() -> Decision {
        let hadRequest = requestedEpisode != nil
        requestedEpisode = nil; currentEpisode = nil
        return hadRequest ? .cancel : .none
    }
}
