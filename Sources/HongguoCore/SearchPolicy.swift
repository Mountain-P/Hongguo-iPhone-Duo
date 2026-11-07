import Foundation

public enum SearchText {
    /// Keep the user's wording and punctuation; only normalize Unicode width and surrounding space.
    public static func query(_ raw: String) throws -> String {
        let value = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...80).contains(value.count),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CatalogError.invalidQuery
        }
        return value
    }

    /// A device-local, tolerant matching key. It is never substituted for the original network query.
    public static func comparisonKey(_ text: String) -> String {
        let value = text.precomposedStringWithCompatibilityMapping
        let simplified = transform(value, reverse: false) ?? value
        return simplified.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Exactly one alternate spelling at most; this function never performs a request.
    public static func alternateQuery(for raw: String) -> String? {
        guard let original = try? query(raw) else { return nil }
        for reverse in [false, true] {
            guard let converted = transform(original, reverse: reverse),
                  let candidate = try? query(converted), candidate != original else { continue }
            return candidate
        }
        return nil
    }

    private static func transform(_ value: String, reverse: Bool) -> String? {
        let result = NSMutableString(string: value)
        // Foundation accepts ICU transform identifiers; no bundled conversion table or network is used.
        guard result.applyTransform(StringTransform("Traditional-Simplified"), reverse: reverse,
                                    range: NSRange(location: 0, length: result.length), updatedRange: nil) else { return nil }
        return result as String
    }
}

public struct SearchQueryResult: Sendable {
    public let page: SeriesPage
    public let originalQuery: String
    public let effectiveQuery: String
    public var usedAlternate: Bool { originalQuery != effectiveQuery }
}

/// Original query first. Only a complete, empty first page permits one alternate query on the same service.
public struct SearchQueryPlan: Equatable, Sendable {
    public let original: String
    public let alternate: String?

    public init(query: String) throws {
        original = try SearchText.query(query)
        alternate = SearchText.alternateQuery(for: original)
    }

    public func firstPage(using service: any CatalogService) async throws -> SearchQueryResult {
        try Task.checkCancellation()
        let first = try await service.search(query: original, page: 1)
        try Task.checkCancellation()
        guard first.page == 1 else { throw CatalogError.malformedResponse }
        guard first.items.isEmpty, !first.hasMore, let alternate else {
            return SearchQueryResult(page: first, originalQuery: original, effectiveQuery: original)
        }
        let fallback = try await service.search(query: alternate, page: 1)
        try Task.checkCancellation()
        guard fallback.page == 1 else { throw CatalogError.malformedResponse }
        return SearchQueryResult(page: fallback, originalQuery: original, effectiveQuery: alternate)
    }
}

public enum SearchResultFilter: Hashable, Sendable {
    case all
    case tag(String)
}

public struct SearchResultFacet: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let count: Int
}

/// Facets describe only tags explicitly supplied for the loaded results, never an inferred content type.
public enum SearchResultFiltering {
    public static func facets(in items: [Series], limit: Int = 24) -> [SearchResultFacet] {
        var order: [String] = [], titles: [String: String] = [:], counts: [String: Int] = [:]
        var seenSeries: Set<String> = []
        for item in items where seenSeries.insert(item.id).inserted {
            var seenTags: Set<String> = []
            for raw in item.tags {
                guard let tag = validTag(raw), seenTags.insert(tag.id).inserted else { continue }
                if titles[tag.id] == nil { order.append(tag.id); titles[tag.id] = tag.title }
                counts[tag.id, default: 0] += 1
            }
        }
        return order.prefix(max(0, min(limit, 48))).map {
            SearchResultFacet(id: $0, title: titles[$0] ?? $0, count: counts[$0] ?? 0)
        }
    }

    public static func apply(_ filter: SearchResultFilter, to items: [Series]) -> [Series] {
        var seen: Set<String> = []
        return items.filter { item in
            guard seen.insert(item.id).inserted else { return false }
            switch filter {
            case .all: return true
            case .tag(let key): return item.tags.contains { validTag($0)?.id == key }
            }
        }
    }

    private static func validTag(_ raw: String) -> (id: String, title: String)? {
        let title = raw.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(title.count),
              !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let id = SearchText.comparisonKey(title)
        guard !id.isEmpty else { return nil }
        return (id, title)
    }
}
