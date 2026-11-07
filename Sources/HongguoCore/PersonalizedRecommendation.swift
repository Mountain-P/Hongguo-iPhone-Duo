import Foundation

/// An explanation based on an actual shared source tag, never an official recommendation claim.
public struct PersonalizedRecommendationReason: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case favorite, recentlyWatched, topicPreference }
    public let kind: Kind
    public let tag: String
    /// Explicit topic choices have no source work; both source fields are empty in that case.
    public let sourceSeriesID: String
    public let sourceTitle: String

    public var displayText: String {
        switch kind {
        case .favorite: "因你收藏《\(sourceTitle)》· \(tag)"
        case .recentlyWatched: "你最近看的《\(sourceTitle)》也有「\(tag)」"
        case .topicPreference: "你選擇多看「\(tag)」"
        }
    }
}

public struct PersonalizedRecommendationItem: Equatable, Sendable {
    public let series: Series
    public let reason: PersonalizedRecommendationReason?
}

/// A disposable profile for exactly one displayed library. It contains no playback positions,
/// timestamps, account credentials or preview-exposure signals, and is not sent to a service.
public struct PersonalizedRecommendationProfile: Equatable, Sendable {
    public static let maximumFavorites = 200
    public static let maximumHistoryRecords = 200
    public static let maximumTags = 64
    public static let maximumTagsPerSeries = 8
    public static let maximumEvidencePerTag = 6
    public static let historyLifetime: TimeInterval = 60 * 24 * 60 * 60

    public let scope: LibraryScope
    fileprivate var interests: [Interest] = []
    fileprivate var topicPreferences = RecommendationTopicPreferences()
    public var hasSignals: Bool { !interests.isEmpty || !topicPreferences.entries.isEmpty }
    public var isEmpty: Bool { !hasSignals }
    public var tagCount: Int { Set(interests.map(\.key) + topicPreferences.entries.map(\.key)).count }
    public var signalCount: Int { Set(interests.flatMap { $0.evidence.map(\.seriesID) }).count + topicPreferences.entries.count }

    public init(scope: LibraryScope, favorites: [Series], history: [WatchRecord], now: Date = Date(),
                topicPreferences: RecommendationTopicPreferences = .init()) {
        self.scope = scope
        guard RecommendationMetadata.validScope(scope), now.timeIntervalSince1970.isFinite else { return }
        self.topicPreferences = topicPreferences
        var seenSeries: Set<String> = []
        for series in favorites.prefix(Self.maximumFavorites) {
            guard RecommendationMetadata.validSeries(series), seenSeries.insert(series.id).inserted else { continue }
            add(series, kind: .favorite)
        }
        // The displayed library normally already has one newest record per series. Sorting also
        // handles injected/legacy arrays; a newer insufficient record cannot revive older evidence.
        let recent = history.prefix(Self.maximumHistoryRecords).enumerated().filter {
            $0.element.updatedAt.timeIntervalSince1970.isFinite
                && $0.element.updatedAt <= now.addingTimeInterval(300)
        }.sorted {
            if $0.element.updatedAt != $1.element.updatedAt { return $0.element.updatedAt > $1.element.updatedAt }
            return $0.offset < $1.offset
        }
        for entry in recent {
            let record = entry.element
            guard RecommendationMetadata.validSeries(record.series), seenSeries.insert(record.series.id).inserted,
                  record.updatedAt >= now.addingTimeInterval(-Self.historyLifetime),
                  Self.hasSufficientPosition(record) else { continue }
            add(record.series, kind: .recentlyWatched)
        }
    }

    /// A saved position is a weaker signal, not proof of dwell time, completion or liking.
    public static func hasSufficientPosition(_ record: WatchRecord) -> Bool {
        guard (try? validateID(record.episode.id)) != nil, record.episode.number > 0,
              record.seconds.isFinite, record.duration.isFinite,
              record.duration >= 30, record.duration <= 4 * 60 * 60,
              record.seconds >= 30, record.seconds <= record.duration,
              record.seconds / record.duration >= 0.5 else { return false }
        return true
    }

    fileprivate struct Evidence: Equatable, Sendable {
        let seriesID: String
        let title: String
        let kind: PersonalizedRecommendationReason.Kind
        var weight: Int { kind == .favorite ? 6 : 2 }
    }
    fileprivate struct Interest: Equatable, Sendable {
        let key: String
        var evidence: [Evidence]
    }

    private mutating func add(_ series: Series, kind: PersonalizedRecommendationReason.Kind) {
        let evidence = Evidence(seriesID: series.id,
                                title: String(series.title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)), kind: kind)
        for tag in RecommendationMetadata.tags(series.tags) {
            if let index = interests.firstIndex(where: { $0.key == tag.key }) {
                if interests[index].evidence.count < Self.maximumEvidencePerTag {
                    interests[index].evidence.append(evidence)
                }
            } else if interests.count < Self.maximumTags {
                interests.append(Interest(key: tag.key, evidence: [evidence]))
            }
        }
    }
}

/// Bounded, deterministic local ordering of the supplied public candidates only.
/// Callers apply this to new batches; they retain the currently playing card themselves.
public enum PersonalizedRecommendation {
    public static let maximumCandidates = 500

    public static func rank(_ candidates: [Series], using profile: PersonalizedRecommendationProfile,
                            scope: LibraryScope, recentSeries: [Series] = []) -> [PersonalizedRecommendationItem] {
        var seen: Set<String> = []
        let unique = candidates.prefix(maximumCandidates).filter {
            RecommendationMetadata.validSeries($0) && seen.insert($0.id).inserted
        }
        guard RecommendationMetadata.validScope(scope), scope == profile.scope else {
            return unique.map { .init(series: $0, reason: nil) }
        }
        let interests = Dictionary(uniqueKeysWithValues: profile.interests.map { ($0.key, $0) })
        var remaining = unique.enumerated().map { offset, series in
            candidate(series, sourceIndex: offset, interests: interests, topics: profile.topicPreferences)
        }
        // Only the committed queue tail is supplied by callers. There is no cross-request state
        // for failed, cancelled, excluded or replaced pages to leave behind.
        var recentTags: [String?] = recentSeries.suffix(2).map { series -> String? in
            guard RecommendationMetadata.validSeries(series) else { return nil }
            return candidate(series, sourceIndex: 0, interests: interests, topics: profile.topicPreferences).primaryTag
        }
        guard remaining.contains(where: { $0.score != 0 }) || !recentTags.isEmpty else {
            return unique.map { .init(series: $0, reason: nil) }
        }
        var output: [PersonalizedRecommendationItem] = []
        while !remaining.isEmpty {
            let avoid = recentTags.count == 2 && recentTags[0] != nil && recentTags[0] == recentTags[1]
                ? recentTags[0] : nil
            let hasPositive = remaining.contains { $0.score > 0 }
            let alternatives = remaining.indices.filter {
                avoid != nil && remaining[$0].primaryTag != avoid
                    && (remaining[$0].score > 0 || (!hasPositive && remaining[$0].score == 0))
                    && !remaining[$0].hasLessPreference
            }
            let eligible = alternatives.isEmpty ? Array(remaining.indices) : alternatives
            let best = eligible.min {
                if remaining[$0].score != remaining[$1].score { return remaining[$0].score > remaining[$1].score }
                return remaining[$0].sourceIndex < remaining[$1].sourceIndex
            }!
            // An explicitly reduced topic is never promoted into an exploration slot,
            // including a mixed-tag work whose positive interests offset its penalty.
            let exploration = output.count % 4 == 3
                ? remaining.firstIndex(where: { $0.score == 0 && !$0.hasLessPreference }) : nil
            let index = exploration ?? best
            let selected = remaining.remove(at: index)
            output.append(.init(series: selected.series, reason: selected.reason))
            recentTags.append(selected.primaryTag)
            if recentTags.count > 2 { recentTags.removeFirst() }
        }
        return output
    }

    private static func candidate(_ series: Series, sourceIndex: Int,
                                  interests: [String: PersonalizedRecommendationProfile.Interest],
                                  topics: RecommendationTopicPreferences) -> Candidate {
        let tags = RecommendationMetadata.tags(series.tags)
        var score = 0, bestWeight = 0, hasLessPreference = false
        var reason: PersonalizedRecommendationReason?, primaryTag: String?
        for tag in tags {
            // A work does not recommend itself merely because it is already in the library.
            let evidence = interests[tag.key]?.evidence.filter { $0.seriesID != series.id } ?? []
            let weight = min(evidence.reduce(0) { $0 + $1.weight }, 24)
            score += weight
            switch topics.preference(for: tag.key) {
            case .more:
                score += 12
                if weight + 12 > bestWeight {
                    bestWeight = weight + 12; primaryTag = tag.key
                    // An explicit choice has no invented source work or library evidence.
                    reason = .init(kind: .topicPreference, tag: tag.title, sourceSeriesID: "", sourceTitle: "")
                }
            case .less:
                score -= 32; hasLessPreference = true
            case .neutral:
                if weight > bestWeight, let source = evidence.first {
                    bestWeight = weight; primaryTag = tag.key
                    reason = .init(kind: source.kind, tag: tag.title, sourceSeriesID: source.seriesID, sourceTitle: source.title)
                }
            }
        }
        return Candidate(series: series, sourceIndex: sourceIndex, score: score,
                         primaryTag: primaryTag ?? tags.first?.key, hasLessPreference: hasLessPreference,
                         reason: score > 0 ? reason : nil)
    }

    private struct Candidate {
        let series: Series
        let sourceIndex: Int
        let score: Int
        let primaryTag: String?
        let hasLessPreference: Bool
        let reason: PersonalizedRecommendationReason?
    }
}

private enum RecommendationMetadata {
    static func validScope(_ scope: LibraryScope) -> Bool {
        guard validText(scope.sourceID, maximum: 512) else { return false }
        switch scope.owner {
        case .guest: return true
        case .account(let id): return validText(id, maximum: 256)
        }
    }

    static func validSeries(_ series: Series) -> Bool {
        (try? validateID(series.id)) != nil && series.id.contains(where: { $0 != "0" })
            && validText(series.title, maximum: 256)
    }

    static func validText(_ value: String, maximum: Int) -> Bool {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= maximum
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    static func tags(_ values: [String]) -> [(key: String, title: String)] {
        var result: [(key: String, title: String)] = [], seen: Set<String> = []
        for raw in values.prefix(32) {
            guard let tag = RecommendationTopicTag.normalized(raw), seen.insert(tag.key).inserted else { continue }
            result.append(tag)
            if result.count == PersonalizedRecommendationProfile.maximumTagsPerSeries { break }
        }
        return result
    }
}
