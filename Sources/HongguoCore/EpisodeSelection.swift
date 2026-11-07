import Foundation

public enum EpisodeSelectionError: Error, LocalizedError, Equatable, Sendable {
    case invalidSeries, invalidEpisodes, invalidGroupSize, invalidNumber, episodeNotFound
    public var errorDescription: String? {
        switch self {
        case .invalidSeries, .invalidEpisodes: "來源的分集資料暫時無法分類，仍可使用原選集入口。"
        case .invalidGroupSize: "分集群組大小無效。"
        case .invalidNumber: "請輸入有效的整數集數。"
        case .episodeNotFound: "來源沒有提供這個集數。"
        }
    }
}

public struct EpisodeSelectionGroup: Hashable, Identifiable, Sendable {
    public let start: Int
    public let end: Int
    public let episodes: [Episode]
    public var id: Int { start }
}

/// Browsing and locating episodes only. Returning an unavailable episode never grants playback.
public struct EpisodeSelection: Sendable {
    public let seriesID: String
    public let episodes: [Episode]
    public let groups: [EpisodeSelectionGroup]
    public let groupSize: Int
    private let byID: [String: Episode]
    private let byNumber: [Int: Episode]

    public init(seriesID: String, episodes: [Episode], groupSize: Int = 30) throws {
        guard (try? validateID(seriesID)) != nil, seriesID.contains(where: { $0 != "0" }) else {
            throw EpisodeSelectionError.invalidSeries
        }
        guard (1...100).contains(groupSize) else { throw EpisodeSelectionError.invalidGroupSize }
        guard episodes.count <= 10_000 else { throw EpisodeSelectionError.invalidEpisodes }
        var ids: [String: Episode] = [:], numbers: [Int: Episode] = [:]
        for episode in episodes {
            guard (try? validateID(episode.id)) != nil, episode.id.contains(where: { $0 != "0" }),
                  (1...10_000).contains(episode.number), ids[episode.id] == nil, numbers[episode.number] == nil else {
                throw EpisodeSelectionError.invalidEpisodes
            }
            ids[episode.id] = episode; numbers[episode.number] = episode
        }
        let sorted = episodes.sorted { $0.number < $1.number }
        let maximum = sorted.last?.number ?? 0
        let buckets = Dictionary(grouping: sorted) { (($0.number - 1) / groupSize) * groupSize + 1 }
        self.seriesID = seriesID; self.episodes = sorted; self.groupSize = groupSize
        self.byID = ids; self.byNumber = numbers
        groups = buckets.keys.sorted().map { start in
            EpisodeSelectionGroup(start: start, end: min(start + groupSize - 1, maximum), episodes: buckets[start] ?? [])
        }
    }

    public func resolve(numberText: String) throws -> Episode {
        let text = numberText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(text), number > 0 else { throw EpisodeSelectionError.invalidNumber }
        guard let episode = byNumber[number] else { throw EpisodeSelectionError.episodeNotFound }
        return episode
    }

    public func group(containing episodeID: String) -> EpisodeSelectionGroup? {
        guard let episode = byID[episodeID] else { return nil }
        let start = ((episode.number - 1) / groupSize) * groupSize + 1
        return groups.first { $0.start == start }
    }

    public func resumeEpisode(record: WatchRecord?) -> Episode? {
        guard let record, record.series.id == seriesID else { return nil }
        return byID[record.episode.id]
    }
}

/// Explicit adjacent navigation for user gestures. It neither loads nor starts playback.
public enum EpisodeNavigation {
    public enum Direction: Hashable, Sendable { case previous, next }
    public enum Result: Hashable, Sendable {
        case episode(Episode)
        case first
        case last
        case unavailable(Episode)
        case missingCurrent
    }

    public static func adjacent(to currentEpisodeID: String?, in episodes: [Episode],
                                direction: Direction) -> Result {
        guard let currentEpisodeID, !currentEpisodeID.isEmpty,
              (1...10_000).contains(episodes.count),
              episodes.filter({ $0.id == currentEpisodeID }).count == 1 else { return .missingCurrent }
        let ordered = episodes.enumerated().sorted {
            if $0.element.number != $1.element.number { return $0.element.number < $1.element.number }
            return $0.offset < $1.offset
        }.map(\.element)
        guard let current = ordered.firstIndex(where: { $0.id == currentEpisodeID }) else { return .missingCurrent }
        let target: Int
        switch direction {
        case .previous:
            guard current > 0 else { return .first }
            target = current - 1
        case .next:
            guard current + 1 < ordered.count else { return .last }
            target = current + 1
        }
        let episode = ordered[target]
        return episode.isAvailable ? .episode(episode) : .unavailable(episode)
    }
}
