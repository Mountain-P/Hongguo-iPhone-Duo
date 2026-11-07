import Foundation

public enum LibraryFavoriteSort: String, CaseIterable, Sendable, Identifiable {
    case storedOrder, titleAscending, titleDescending
    public var id: String { rawValue }
    public var title: String {
        switch self { case .storedOrder: "片庫順序"; case .titleAscending: "名稱：正序"; case .titleDescending: "名稱：反序" }
    }
}

public enum LibraryHistorySort: String, CaseIterable, Sendable, Identifiable {
    case recent, oldest, titleAscending, progressDescending
    public var id: String { rawValue }
    public var title: String {
        switch self { case .recent: "最近觀看"; case .oldest: "最早觀看"; case .titleAscending: "名稱：正序"; case .progressDescending: "本集進度：由高至低" }
    }
}

public enum LibraryHistoryFilter: Sendable { case all, inProgress, completed }

/// Local-only presentation. Searching and sorting never change the saved library or sync queue.
public enum LibraryBrowser {
    public static func favorites(_ items: [Series], query: String = "", sort: LibraryFavoriteSort = .storedOrder) -> [Series] {
        let words = tokens(query)
        let result = items.filter { matches($0, words: words) }
        guard sort != .storedOrder else { return result }
        return result.sorted { sort == .titleDescending ? titleBefore($1, $0) : titleBefore($0, $1) }
    }

    public static func history(_ items: [WatchRecord], query: String = "", filter: LibraryHistoryFilter = .all,
                               sort: LibraryHistorySort = .recent) -> [WatchRecord] {
        let words = tokens(query)
        return items.filter { record in
            let allowed = switch filter { case .all: true; case .inProgress: !record.isEpisodeCompleted; case .completed: record.isEpisodeCompleted }
            return allowed && matches(record.series, words: words, extra: record.episode.title)
        }.sorted { a, b in
            switch sort {
            case .recent:
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            case .oldest:
                if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
            case .titleAscending: return titleBefore(a.series, b.series)
            case .progressDescending:
                if a.progress != b.progress { return a.progress > b.progress }
                if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
            }
            return idBefore(a.series.id, b.series.id)
        }
    }

    private static func tokens(_ query: String) -> [String] {
        normalized(String(query.prefix(80))).split(whereSeparator: \.isWhitespace).map(String.init)
    }
    private static func normalized(_ value: String) -> String {
        SearchText.comparisonKey(value).folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
    private static func matches(_ series: Series, words: [String], extra: String = "") -> Bool {
        guard !words.isEmpty else { return true }
        let text = normalized(([series.title, series.description, extra] + series.tags).joined(separator: " "))
        return words.allSatisfy { text.contains($0) }
    }
    private static func titleBefore(_ a: Series, _ b: Series) -> Bool {
        let order = a.title.compare(b.title, options: [.numeric, .caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                    locale: Locale(identifier: "zh_Hant_TW"))
        return order == .orderedSame ? idBefore(a.id, b.id) : order == .orderedAscending
    }
    private static func idBefore(_ a: String, _ b: String) -> Bool {
        let order = a.compare(b, options: .numeric, locale: Locale(identifier: "en_US_POSIX"))
        return order == .orderedSame ? a < b : order == .orderedAscending
    }
}

/// Prepare a complete value before the caller commits once to its captured scope.
public enum LibraryManagement {
    public static func removingHistory(seriesIDs: Set<String>, from state: LibraryState, at date: Date = Date()) throws -> LibraryState {
        try validate(seriesIDs, date: date)
        var result = state
        let known = Set(state.history.map { $0.series.id })
        for id in seriesIDs.intersection(known).sorted() { result.removeHistory(seriesID: id, at: date) }
        return result
    }
    public static func removingFavorites(seriesIDs: Set<String>, from state: LibraryState, at date: Date = Date()) throws -> LibraryState {
        try validate(seriesIDs, date: date)
        var result = state
        for series in state.favorites where seriesIDs.contains(series.id) {
            try result.setFavorite(series, isFavorite: false, at: date)
        }
        return result
    }
    private static func validate(_ ids: Set<String>, date: Date) throws {
        guard date.timeIntervalSince1970.isFinite else { throw UserLibraryError.invalidMutation }
        for id in ids { try validateID(id) }
    }
}
