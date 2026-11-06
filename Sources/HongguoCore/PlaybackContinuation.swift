import Foundation

/// A manual playback entry point, including continuation and explicit episode replay.
public struct PlaybackContinuation: Hashable, Sendable {
    public let episode: Episode
    public let seconds: Double

    public static func preferred(seriesID: String, episodes: [Episode], record: WatchRecord?) -> PlaybackContinuation? {
        let available = episodes.enumerated().filter { $0.element.isAvailable }.sorted {
            if $0.element.number != $1.element.number { return $0.element.number < $1.element.number }
            return $0.offset < $1.offset
        }.map(\.element)
        guard let first = available.first else { return nil }
        guard let record, record.series.id == seriesID,
              let index = available.firstIndex(where: { $0.id == record.episode.id }) else {
            return selected(seriesID: seriesID, episode: first, record: nil)
        }
        let next = record.isEpisodeCompleted && available.indices.contains(index + 1) ? available[index + 1] : available[index]
        return selected(seriesID: seriesID, episode: next, record: record)
    }

    public static func selected(seriesID: String, episode: Episode, record: WatchRecord?) -> PlaybackContinuation? {
        guard episode.isAvailable else { return nil }
        let seconds: Double
        if let record, record.series.id == seriesID, record.episode.id == episode.id,
           !record.isEpisodeCompleted, record.seconds.isFinite, record.seconds >= 0 {
            seconds = record.seconds
        } else {
            seconds = 0
        }
        return PlaybackContinuation(episode: episode, seconds: seconds)
    }
}
