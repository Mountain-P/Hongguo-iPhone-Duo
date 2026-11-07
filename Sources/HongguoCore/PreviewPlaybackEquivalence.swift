import Foundation

/// Suppresses a position choice only when both inputs express the same playback intent.
public enum PreviewPlaybackEquivalence {
    /// Inclusive. A difference greater than two seconds still requires an explicit choice.
    public static let positionTolerance: Double = 2

    public static func canContinueWithoutChoice(snapshot: PreviewPlaybackSnapshot, record: WatchRecord,
                                               detail: SeriesDetail) -> Bool {
        guard snapshot.seriesID == detail.series.id, record.series.id == snapshot.seriesID,
              record.episode.id == snapshot.episodeID,
              let episode = detail.episodes.first(where: { $0.id == snapshot.episodeID }), episode.isAvailable,
              snapshot.position.isFinite, snapshot.position >= 0,
              snapshot.duration.isFinite, snapshot.duration > 0,
              record.seconds.isFinite, record.seconds >= 0,
              record.duration.isFinite, record.duration >= 0 else { return false }
        let previewRecord = WatchRecord(series: detail.series, episode: episode,
                                        seconds: min(snapshot.position, snapshot.duration), duration: snapshot.duration)
        // Equal resolved positions alone are insufficient: an end-of-series replay or a
        // completed episode advancing to its successor must not hide a different intent.
        guard record.isEpisodeCompleted == previewRecord.isEpisodeCompleted,
              let saved = PlaybackContinuation.preferred(seriesID: snapshot.seriesID, episodes: detail.episodes, record: record),
              let preview = snapshot.continuation(in: detail), saved.episode.id == preview.episode.id else { return false }
        return abs(saved.seconds - preview.seconds) <= positionTolerance
    }
}
