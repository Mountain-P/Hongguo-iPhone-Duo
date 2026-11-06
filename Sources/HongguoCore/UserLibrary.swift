import Foundation

public enum UserLibraryError: Error, LocalizedError, Equatable, Sendable {
    case invalidScope, invalidRecord, invalidMutation, scopeMismatch, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalidScope, .scopeMismatch: "片庫所屬帳號或來源不符。"
        case .invalidRecord, .invalidMutation: "片庫資料不完整，原有資料已保留。"
        case .unsupportedVersion: "目前無法讀取這個版本的片庫資料。"
        }
    }
}

public enum LibraryOwner: Codable, Hashable, Sendable {
    case guest
    case account(id: String)
}

public struct LibraryScope: Codable, Hashable, Sendable {
    public let owner: LibraryOwner
    public let sourceID: String
    public init(owner: LibraryOwner, sourceID: String) { self.owner = owner; self.sourceID = sourceID }
}

public struct WatchRecord: Codable, Hashable, Identifiable, Sendable {
    public var series: Series
    public var episode: Episode
    public var seconds: Double
    public var duration: Double
    public var updatedAt: Date
    public var episodeCount: Int?
    public var id: String { series.id }
    public var progress: Double {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return 0 }
        return min(max(seconds / duration, 0), 1)
    }
    /// Completion of this episode is not evidence that all episodes were watched.
    public var isEpisodeCompleted: Bool { duration.isFinite && duration > 0 && progress >= 0.98 }

    public init(series: Series, episode: Episode, seconds: Double, duration: Double, updatedAt: Date = Date(), episodeCount: Int? = nil) {
        self.series = series; self.episode = episode; self.seconds = seconds; self.duration = duration
        self.updatedAt = updatedAt; self.episodeCount = episodeCount
    }
}

public struct LibrarySnapshot: Codable, Hashable, Sendable {
    public var favorites: [Series]
    public var history: [WatchRecord]
    public var episodeHistory: [WatchRecord]
    public init(favorites: [Series] = [], history: [WatchRecord] = [], episodeHistory: [WatchRecord] = []) {
        self.favorites = favorites; self.history = history; self.episodeHistory = episodeHistory
    }
    private enum CodingKeys: String, CodingKey { case favorites, history, episodeHistory }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        favorites = try values.decodeIfPresent([Series].self, forKey: .favorites) ?? []
        history = try values.decodeIfPresent([WatchRecord].self, forKey: .history) ?? []
        episodeHistory = try values.decodeIfPresent([WatchRecord].self, forKey: .episodeHistory) ?? []
    }
    public func validated() throws -> LibrarySnapshot { try LibraryRules.normalized(self) }
}

public struct FavoriteMutation: Codable, Hashable, Identifiable, Sendable {
    public let operationID: UUID
    public let series: Series
    public let isFavorite: Bool
    public let updatedAt: Date
    public var id: UUID { operationID }
    public var seriesID: String { series.id }
    public init(operationID: UUID = UUID(), series: Series, isFavorite: Bool, updatedAt: Date = Date()) {
        self.operationID = operationID; self.series = series; self.isFavorite = isFavorite; self.updatedAt = updatedAt
    }
}

public struct ProgressMutation: Codable, Hashable, Identifiable, Sendable {
    public let operationID: UUID
    public let seriesID: String
    /// nil is a local deletion intent, not a claim that an upstream delete API exists.
    public let record: WatchRecord?
    public let updatedAt: Date
    public var id: UUID { operationID }
    public var isDeletion: Bool { record == nil }
    public init(operationID: UUID = UUID(), seriesID: String, record: WatchRecord?, updatedAt: Date = Date()) {
        self.operationID = operationID; self.seriesID = seriesID; self.record = record; self.updatedAt = updatedAt
    }
}

/// A value model for one account and source. Persistence and network APIs live outside this type.
public struct LibraryState: Codable, Hashable, Sendable {
    public static let currentVersion = 2
    public private(set) var scope: LibraryScope
    public private(set) var snapshot: LibrarySnapshot
    public private(set) var pendingFavorites: [FavoriteMutation]
    public private(set) var pendingProgress: [ProgressMutation]
    // Deletions survive acknowledgement until a complete remote snapshot confirms them.
    private var favoriteTombstones: [String: Date]
    private var historyDeletionDates: [String: Date]
    // Retain completed-episode evidence even if the user later rewatches from zero.
    private var completedRecords: [WatchRecord]

    public var favorites: [Series] { snapshot.favorites }
    public var history: [WatchRecord] { snapshot.history }
    public var episodeHistory: [WatchRecord] { snapshot.episodeHistory }

    public init(scope: LibraryScope, snapshot: LibrarySnapshot = .init(), pendingFavorites: [FavoriteMutation] = [], pendingProgress: [ProgressMutation] = []) throws {
        try LibraryRules.validate(scope)
        self.scope = scope
        self.snapshot = try LibraryRules.normalized(snapshot)
        self.pendingFavorites = try LibraryRules.favorites(pendingFavorites)
        self.pendingProgress = try LibraryRules.progress(pendingProgress)
        favoriteTombstones = [:]; historyDeletionDates = [:]
        completedRecords = LibraryRules.episodes((snapshot.episodeHistory + snapshot.history).filter(\.isEpisodeCompleted))
        try applyStoredIntents()
    }

    public func record(for seriesID: String) -> WatchRecord? { snapshot.history.first { $0.series.id == seriesID } }
    public func isFavorite(_ seriesID: String) -> Bool { snapshot.favorites.contains { $0.id == seriesID } }

    /// Replace metadata for an existing series without creating a user operation or changing progress.
    public mutating func enrichSeries(_ series: Series) throws {
        try LibraryRules.validate(series)
        let id = series.id
        guard snapshot.favorites.contains(where: { $0.id == id })
                || snapshot.history.contains(where: { $0.series.id == id })
                || snapshot.episodeHistory.contains(where: { $0.series.id == id })
                || completedRecords.contains(where: { $0.series.id == id })
                || pendingFavorites.contains(where: { $0.seriesID == id })
                || pendingProgress.contains(where: { $0.record?.series.id == id }) else {
            throw UserLibraryError.invalidRecord
        }
        func enriched(_ record: WatchRecord) -> WatchRecord {
            guard record.series.id == id else { return record }
            var copy = record
            copy.series = series
            return copy
        }
        snapshot.favorites = snapshot.favorites.map { $0.id == id ? series : $0 }
        snapshot.history = snapshot.history.map(enriched)
        snapshot.episodeHistory = snapshot.episodeHistory.map(enriched)
        completedRecords = completedRecords.map(enriched)
        pendingFavorites = pendingFavorites.map { value in
            guard value.seriesID == id else { return value }
            return FavoriteMutation(operationID: value.operationID, series: series,
                                    isFavorite: value.isFavorite, updatedAt: value.updatedAt)
        }
        pendingProgress = pendingProgress.map { value in
            guard value.record?.series.id == id else { return value }
            return ProgressMutation(operationID: value.operationID, seriesID: value.seriesID,
                                    record: value.record.map(enriched), updatedAt: value.updatedAt)
        }
    }

    public mutating func record(_ value: WatchRecord) throws {
        try LibraryRules.validate(value)
        let before = record(for: value.series.id)
        snapshot = try LibraryRules.normalized(.init(favorites: snapshot.favorites,
            history: snapshot.history + [value], episodeHistory: snapshot.episodeHistory + [value]))
        if value.isEpisodeCompleted { completedRecords = LibraryRules.episodes(completedRecords + [value]) }
        if let latest = record(for: value.series.id), !LibraryRules.sameProgress(before, latest) {
            enqueue(ProgressMutation(seriesID: latest.series.id, record: latest, updatedAt: latest.updatedAt))
        }
    }

    public mutating func setFavorite(_ series: Series, isFavorite: Bool, at date: Date = Date()) throws {
        try LibraryRules.validate(series); try LibraryRules.validate(date)
        snapshot.favorites.removeAll { $0.id == series.id }
        if isFavorite {
            snapshot.favorites.insert(series, at: 0)
            favoriteTombstones.removeValue(forKey: series.id)
        } else { favoriteTombstones[series.id] = date }
        pendingFavorites.removeAll { $0.seriesID == series.id }
        pendingFavorites.append(FavoriteMutation(series: series, isFavorite: isFavorite, updatedAt: date))
    }

    public mutating func clearHistory(at date: Date = Date()) {
        guard (try? LibraryRules.validate(date)) != nil else { return }
        let ids = Set(snapshot.history.map { $0.series.id } + snapshot.episodeHistory.map { $0.series.id }
            + completedRecords.map { $0.series.id } + pendingProgress.map(\.seriesID))
        snapshot.history = []; snapshot.episodeHistory = []; completedRecords = []
        for id in ids.sorted() {
            historyDeletionDates[id] = date
            enqueue(ProgressMutation(seriesID: id, record: nil, updatedAt: date))
        }
    }

    public mutating func removeHistory(seriesID: String, at date: Date = Date()) {
        guard (try? validateID(seriesID)) != nil, (try? LibraryRules.validate(date)) != nil else { return }
        snapshot.history.removeAll { $0.series.id == seriesID }
        snapshot.episodeHistory.removeAll { $0.series.id == seriesID }
        completedRecords.removeAll { $0.series.id == seriesID }
        historyDeletionDates[seriesID] = date
        enqueue(ProgressMutation(seriesID: seriesID, record: nil, updatedAt: date))
    }

    /// Partial favorites are unioned. Only an explicitly complete pull may imply remote removal.
    /// Pending local operations always take precedence over a collection snapshot.
    public mutating func merge(remote: LibrarySnapshot, scope remoteScope: LibraryScope, favoritesAreComplete: Bool = false) throws {
        guard remoteScope == scope else { throw UserLibraryError.scopeMismatch }
        let incoming = try LibraryRules.normalized(remote)
        var copy = self
        let remoteFavoriteIDs = Set(incoming.favorites.map(\.id))
        let pendingFavoriteIDs = Set(copy.pendingFavorites.map(\.seriesID))
        if favoritesAreComplete {
            copy.snapshot.favorites.removeAll { !remoteFavoriteIDs.contains($0.id) && !pendingFavoriteIDs.contains($0.id) }
            copy.favoriteTombstones = copy.favoriteTombstones.filter {
                remoteFavoriteIDs.contains($0.key) || pendingFavoriteIDs.contains($0.key)
            }
        }
        copy.snapshot.favorites = LibraryRules.series(copy.snapshot.favorites + incoming.favorites.filter {
            copy.favoriteTombstones[$0.id] == nil
        })
        let blocked = Set(copy.pendingProgress.filter(\.isDeletion).map(\.seriesID))
        let allowed: (WatchRecord) -> Bool = { value in
            !blocked.contains(value.series.id) && (copy.historyDeletionDates[value.series.id].map { value.updatedAt > $0 } ?? true)
        }
        let remoteHistory = incoming.history.filter(allowed)
        let remoteEpisodes = incoming.episodeHistory.filter(allowed)
        copy.snapshot = try LibraryRules.normalized(.init(favorites: copy.snapshot.favorites,
            history: copy.snapshot.history + remoteHistory, episodeHistory: copy.snapshot.episodeHistory + remoteEpisodes))
        let proofs = (remote.episodeHistory + remote.history).filter { $0.isEpisodeCompleted && allowed($0) }
        copy.completedRecords = LibraryRules.episodes(copy.completedRecords + proofs)
        // If a remote record legitimately wins, a pending upload must never retain an older resume position.
        for pending in copy.pendingProgress where !pending.isDeletion {
            if let latest = copy.record(for: pending.seriesID), !LibraryRules.sameProgress(pending.record, latest) {
                copy.enqueue(ProgressMutation(seriesID: latest.series.id, record: latest, updatedAt: latest.updatedAt))
            }
        }
        try copy.applyFavoriteIntents()
        self = copy
    }

    /// Explicit copy only: ordinary merge rejects guest/account and cross-source mixing.
    /// The supplied guest value is never mutated or consumed.
    public mutating func importGuest(_ guest: LibraryState, at date: Date = Date()) throws {
        guard case .account = scope.owner, case .guest = guest.scope.owner,
              scope.sourceID == guest.scope.sourceID else { throw UserLibraryError.scopeMismatch }
        try LibraryRules.validate(date)
        let previousFavorites = Set(favorites.map(\.id))
        let previousHistory = Dictionary(uniqueKeysWithValues: history.map { ($0.series.id, $0) })
        var copy = self
        try copy.merge(remote: guest.snapshot, scope: scope)
        let permittedProofs = guest.completedRecords.filter { value in
            copy.historyDeletionDates[value.series.id].map { value.updatedAt > $0 } ?? true
        }
        copy.completedRecords = LibraryRules.episodes(copy.completedRecords + permittedProofs)
        for item in copy.favorites where !previousFavorites.contains(item.id) {
            try copy.setFavorite(item, isFavorite: true, at: date)
        }
        for value in copy.history where !LibraryRules.sameProgress(previousHistory[value.series.id], value) {
            copy.enqueue(ProgressMutation(seriesID: value.series.id, record: value, updatedAt: value.updatedAt))
        }
        self = copy
    }

    public mutating func acknowledgeFavorites(operationIDs: Set<UUID>) {
        pendingFavorites.removeAll { operationIDs.contains($0.operationID) }
    }
    public mutating func acknowledgeProgress(operationIDs: Set<UUID>) {
        pendingProgress.removeAll { operationIDs.contains($0.operationID) }
    }

    public func isSeriesCompleted(seriesID: String, episodes: [Episode]) -> Bool {
        guard !episodes.isEmpty, (try? validateID(seriesID)) != nil else { return false }
        let ids = episodes.map(\.id)
        guard Set(ids).count == ids.count, ids.allSatisfy({ (try? validateID($0)) != nil }) else { return false }
        let completed = Set(completedRecords.filter { $0.series.id == seriesID && $0.isEpisodeCompleted }.map { $0.episode.id })
        return Set(ids).isSubset(of: completed)
    }

    private mutating func enqueue(_ mutation: ProgressMutation) {
        pendingProgress.removeAll { $0.seriesID == mutation.seriesID }
        pendingProgress.append(mutation)
    }

    private mutating func applyFavoriteIntents() throws {
        snapshot.favorites.removeAll { favoriteTombstones[$0.id] != nil }
        for pending in pendingFavorites {
            snapshot.favorites.removeAll { $0.id == pending.seriesID }
            if pending.isFavorite {
                favoriteTombstones.removeValue(forKey: pending.seriesID)
                snapshot.favorites.insert(pending.series, at: 0)
            } else { favoriteTombstones[pending.seriesID] = pending.updatedAt }
        }
    }

    private mutating func applyStoredIntents() throws {
        try applyFavoriteIntents()
        snapshot.history.removeAll { value in historyDeletionDates[value.series.id].map { value.updatedAt <= $0 } ?? false }
        snapshot.episodeHistory.removeAll { value in historyDeletionDates[value.series.id].map { value.updatedAt <= $0 } ?? false }
        completedRecords.removeAll { value in historyDeletionDates[value.series.id].map { value.updatedAt <= $0 } ?? false }
        for pending in pendingProgress {
            if let value = pending.record {
                snapshot.history.append(value); snapshot.episodeHistory.append(value)
                if value.isEpisodeCompleted { completedRecords.append(value) }
            } else {
                historyDeletionDates[pending.seriesID] = pending.updatedAt
                snapshot.history.removeAll { $0.series.id == pending.seriesID }
                snapshot.episodeHistory.removeAll { $0.series.id == pending.seriesID }
                completedRecords.removeAll { $0.series.id == pending.seriesID }
            }
        }
        snapshot = try LibraryRules.normalized(snapshot)
        completedRecords = LibraryRules.episodes(completedRecords.filter(\.isEpisodeCompleted))
    }

    private enum CodingKeys: String, CodingKey {
        case version, scope, snapshot, pendingFavorites, pendingProgress, favoriteTombstones, historyDeletionDates, completedRecords
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard version == Self.currentVersion else { throw UserLibraryError.unsupportedVersion }
        try self.init(scope: values.decode(LibraryScope.self, forKey: .scope), snapshot: values.decode(LibrarySnapshot.self, forKey: .snapshot),
            pendingFavorites: values.decodeIfPresent([FavoriteMutation].self, forKey: .pendingFavorites) ?? [],
            pendingProgress: values.decodeIfPresent([ProgressMutation].self, forKey: .pendingProgress) ?? [])
        favoriteTombstones.merge(try values.decodeIfPresent([String: Date].self, forKey: .favoriteTombstones) ?? [:], uniquingKeysWith: max)
        historyDeletionDates.merge(try values.decodeIfPresent([String: Date].self, forKey: .historyDeletionDates) ?? [:], uniquingKeysWith: max)
        for (id, date) in favoriteTombstones.merging(historyDeletionDates, uniquingKeysWith: max) {
            guard (try? validateID(id)) != nil else { throw UserLibraryError.invalidRecord }
            try LibraryRules.validate(date)
        }
        let proofs = try values.decodeIfPresent([WatchRecord].self, forKey: .completedRecords) ?? []
        try proofs.forEach(LibraryRules.validate)
        completedRecords = LibraryRules.episodes(completedRecords + proofs.filter(\.isEpisodeCompleted))
        try applyStoredIntents()
    }
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(scope, forKey: .scope); try values.encode(snapshot, forKey: .snapshot)
        try values.encode(pendingFavorites, forKey: .pendingFavorites); try values.encode(pendingProgress, forKey: .pendingProgress)
        try values.encode(favoriteTombstones, forKey: .favoriteTombstones); try values.encode(historyDeletionDates, forKey: .historyDeletionDates)
        try values.encode(completedRecords, forKey: .completedRecords)
    }
}

private enum LibraryRules {
    private struct EpisodeKey: Hashable { let series: String; let episode: String }

    static func validate(_ scope: LibraryScope) throws {
        guard !scope.sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, scope.sourceID.utf8.count <= 4096,
              !scope.sourceID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw UserLibraryError.invalidScope }
        if case .account(let id) = scope.owner {
            guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, id.utf8.count <= 1024,
                  !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw UserLibraryError.invalidScope }
        }
    }
    static func validate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw UserLibraryError.invalidRecord }
    }
    static func validate(_ series: Series) throws {
        guard (try? validateID(series.id)) != nil, !series.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw UserLibraryError.invalidRecord
        }
    }
    static func validate(_ value: WatchRecord) throws {
        try validate(value.series); try validate(value.updatedAt)
        guard (try? validateID(value.episode.id)) != nil, value.episode.number > 0,
              value.seconds.isFinite, value.seconds >= 0, value.duration.isFinite, value.duration >= 0,
              value.episodeCount.map({ (1...5000).contains($0) }) ?? true else { throw UserLibraryError.invalidRecord }
    }
    static func normalized(_ value: LibrarySnapshot) throws -> LibrarySnapshot {
        try value.favorites.forEach(validate)
        try (value.history + value.episodeHistory).forEach(validate)
        let all = value.history + value.episodeHistory
        return LibrarySnapshot(favorites: series(value.favorites), history: histories(all), episodeHistory: episodes(value.episodeHistory + value.history))
    }
    static func series(_ values: [Series]) -> [Series] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0.id).inserted }
    }
    private static func winner(_ existing: WatchRecord, _ incoming: WatchRecord) -> WatchRecord {
        if incoming.updatedAt != existing.updatedAt { return incoming.updatedAt > existing.updatedAt ? incoming : existing }
        guard incoming.episode.id == existing.episode.id else { return existing }
        var result = incoming.seconds > existing.seconds ? incoming : existing
        if result.duration == 0 { result.duration = max(existing.duration, incoming.duration) }
        if result.episodeCount == nil { result.episodeCount = existing.episodeCount ?? incoming.episodeCount }
        return result
    }
    static func histories(_ values: [WatchRecord]) -> [WatchRecord] {
        var records: [String: WatchRecord] = [:], order: [String: Int] = [:]
        for (index, value) in values.enumerated() {
            if order[value.series.id] == nil { order[value.series.id] = index }
            records[value.series.id] = records[value.series.id].map { winner($0, value) } ?? value
        }
        return records.values.sorted {
            $0.updatedAt == $1.updatedAt ? order[$0.series.id, default: 0] < order[$1.series.id, default: 0] : $0.updatedAt > $1.updatedAt
        }
    }
    static func episodes(_ values: [WatchRecord]) -> [WatchRecord] {
        var records: [EpisodeKey: WatchRecord] = [:], order: [EpisodeKey: Int] = [:]
        for (index, value) in values.enumerated() {
            let key = EpisodeKey(series: value.series.id, episode: value.episode.id)
            if order[key] == nil { order[key] = index }
            records[key] = records[key].map { winner($0, value) } ?? value
        }
        return records.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return order[EpisodeKey(series: $0.series.id, episode: $0.episode.id), default: 0]
                < order[EpisodeKey(series: $1.series.id, episode: $1.episode.id), default: 0]
        }
    }
    static func favorites(_ values: [FavoriteMutation]) throws -> [FavoriteMutation] {
        var output: [FavoriteMutation] = []
        for value in values {
            try validate(value.series); try validate(value.updatedAt)
            if let index = output.firstIndex(where: { $0.seriesID == value.seriesID }) {
                if value.updatedAt >= output[index].updatedAt { output[index] = value }
            } else { output.append(value) }
        }
        return output
    }
    static func progress(_ values: [ProgressMutation]) throws -> [ProgressMutation] {
        var output: [ProgressMutation] = []
        for value in values {
            guard (try? validateID(value.seriesID)) != nil else { throw UserLibraryError.invalidMutation }
            try validate(value.updatedAt)
            if let record = value.record {
                try validate(record)
                guard record.series.id == value.seriesID else { throw UserLibraryError.invalidMutation }
            }
            if let index = output.firstIndex(where: { $0.seriesID == value.seriesID }) {
                if value.updatedAt >= output[index].updatedAt { output[index] = value }
            } else { output.append(value) }
        }
        return output
    }
    static func sameProgress(_ first: WatchRecord?, _ second: WatchRecord) -> Bool {
        guard let first else { return false }
        return first.series.id == second.series.id && first.episode.id == second.episode.id && first.seconds == second.seconds
            && first.duration == second.duration && first.updatedAt == second.updatedAt && first.episodeCount == second.episodeCount
    }
}
