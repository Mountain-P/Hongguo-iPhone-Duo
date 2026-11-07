import Foundation

/// An in-memory handoff from a preview. Capturing this value does not save watch history.
public struct PreviewPlaybackSnapshot: Equatable, Sendable {
    public let seriesID: String
    public let episodeID: String
    public let position: Double
    public let duration: Double

    public init(seriesID: String, episodeID: String, position: Double, duration: Double) {
        self.seriesID = seriesID; self.episodeID = episodeID
        self.position = position; self.duration = duration
    }

    /// The latest catalogue is authoritative; a missing or locked preview is never substituted.
    public func continuation(in detail: SeriesDetail) -> PlaybackContinuation? {
        guard detail.series.id == seriesID,
              let episode = detail.episodes.first(where: { $0.id == episodeID }), episode.isAvailable else { return nil }
        let validTime = position.isFinite && position >= 0 && duration.isFinite && duration > 0
        let record = WatchRecord(series: detail.series, episode: episode,
                                 seconds: validTime ? min(position, duration) : 0,
                                 duration: validTime ? duration : 0)
        return PlaybackContinuation.preferred(seriesID: seriesID, episodes: detail.episodes, record: record)
    }
}
