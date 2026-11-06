// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct DiscoveryItem: Identifiable, Hashable, Sendable {
    public var series: Series
    public var rank: Int?
    public var heatText: String
    public var scoreText: String
    public var statusText: String
    public var id: String { series.id }
    public init(series: Series, rank: Int? = nil, heatText: String = "", scoreText: String = "", statusText: String = "") {
        self.series = series; self.rank = rank; self.heatText = heatText; self.scoreText = scoreText; self.statusText = statusText
    }
}

public struct DiscoveryGenre: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public init(id: String, title: String) { self.id = id; self.title = title }
}

public struct DiscoveryPage: Hashable, Sendable {
    public var items: [DiscoveryItem]
    public var page: Int
    public var hasMore: Bool
    public var genres: [DiscoveryGenre]
    public var updatedText: String
    public init(items: [DiscoveryItem], page: Int, hasMore: Bool, genres: [DiscoveryGenre] = [], updatedText: String = "") {
        self.items = items; self.page = page; self.hasMore = hasMore; self.genres = genres; self.updatedText = updatedText
    }
}

public enum DiscoveryRanking: String, CaseIterable, Codable, Sendable {
    case all = "hot-drama"
    case realDrama = "hot-real-drama"
    case comicDrama = "hot-comic-drama"
    case aiDrama = "hot-ai-drama"
}

public struct WebDiscoveryService: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func category(category: DirectWebService.Category, genre: String? = nil, page: Int = 1) async throws -> DiscoveryPage {
        try validatePage(page)
        let slug = genre.flatMap { $0.isEmpty ? nil : $0 }
        if let slug, !DiscoveryParser.validSlug(slug) { throw CatalogError.invalidQuery }
        let path = "/category/" + category.rawValue + (slug.map { "/" + $0 } ?? "")
        let html = try await fetch(path: path, page: page)
        try Task.checkCancellation()
        return try DiscoveryParser.category(html: html, category: category, genre: slug, page: page)
    }
    public func ranking(board: DiscoveryRanking, page: Int = 1) async throws -> DiscoveryPage {
        try validatePage(page)
        let html = try await fetch(path: "/rank/" + board.rawValue, page: page)
        try Task.checkCancellation()
        return try DiscoveryParser.ranking(html: html, board: board, page: page)
    }

    private func fetch(path: String, page: Int) async throws -> String {
        try Task.checkCancellation()
        var components = URLComponents(url: DirectWebService.siteURL.appendingPathComponent(path.dropFirst().description), resolvingAgainstBaseURL: false)!
        components.queryItems = page > 1 ? [.init(name: "page", value: String(page))] : nil
        var request = URLRequest(url: components.url!)
        request.setValue(DirectWebService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(DirectWebService.siteURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data = try await load(request, using: transport)
        try Task.checkCancellation()
        guard data.count <= DiscoveryParser.maximumBytes else { throw CatalogError.responseTooLarge }
        guard let html = String(data: data, encoding: .utf8) else { throw CatalogError.malformedResponse }
        return html
    }
}

/// Only parses JSON literals and HTML attributes. Source-page scripts are never evaluated.
enum DiscoveryParser {
    static let maximumBytes = 8 * 1024 * 1024
    static func validSlug(_ value: String) -> Bool {
        value.utf8.count <= 80 && value.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
            && value.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }

    static func category(html: String, category: DirectWebService.Category, genre: String?, page: Int) throws -> DiscoveryPage {
        let loader = try loaders(html)
        let expectedPath = "/category/" + category.rawValue + (genre.map { "/" + $0 } ?? "")
        let sections = loader.values.compactMap { $0 as? [String: Any] }.filter {
            string(($0["categoryRoute"] as? [String: Any])?["contentType"]) == category.rawValue
        }
        guard sections.count == 1, let data = sections.first, data["isSuccess"] as? Bool != false,
              let route = data["categoryRoute"] as? [String: Any],
              let rows = data["recommendList"] as? [[String: Any]], rows.count <= 500 else { throw CatalogError.malformedResponse }
        let returnedSlug = string(route["slug"])
        let returnedPath = string(route["canonicalPath"])
        if let genre {
            guard (!returnedSlug.isEmpty || !returnedPath.isEmpty),
                  returnedSlug.isEmpty || returnedSlug == genre,
                  returnedPath.isEmpty || returnedPath == expectedPath else { throw CatalogError.malformedResponse }
        } else {
            guard returnedSlug.isEmpty, returnedPath.isEmpty || returnedPath == expectedPath else { throw CatalogError.malformedResponse }
        }
        try canonical(data["canonicalUrl"], path: expectedPath)
        let more = try pagination(data["pagination"], page: page)
        let genres = try genres(data["selectorList"])
        var seen: Set<String> = []
        let items = rows.compactMap { row -> DiscoveryItem? in
            guard let series = try? WebsiteParser.card(row), seen.insert(series.id).inserted else { return nil }
            return DiscoveryItem(series: series, heatText: label(row["heatText"]), scoreText: label(row["scoreText"]), statusText: status(row))
        }
        guard rows.isEmpty || !items.isEmpty else { throw CatalogError.malformedResponse }
        try Task.checkCancellation()
        return DiscoveryPage(items: items, page: page, hasMore: more, genres: genres, updatedText: label(data["updatedText"]))
    }

    static func ranking(html: String, board: DiscoveryRanking, page: Int) throws -> DiscoveryPage {
        let loader = try loaders(html), key = "rank_" + board.rawValue + "/page"
        guard let base = loader[key] as? [String: Any], base["isSuccess"] as? Bool != false else { throw CatalogError.malformedResponse }
        if base["rankKey"] != nil {
            // The public route and its payload alias are different namespaces.
            let alias: String
            switch board {
            case .all: alias = "hongguo"
            case .realDrama: alias = "real"
            case .comicDrama: alias = "comic"
            case .aiDrama: alias = "ai"
            }
            guard string(base["rankKey"]) == alias else { throw CatalogError.malformedResponse }
        }
        if base["pageNum"] != nil { guard integer(base["pageNum"]) == page else { throw CatalogError.malformedResponse } }
        try canonical(base["canonicalUrl"], path: "/rank/" + board.rawValue)
        var content = base["content"] as? [String: Any]
        if content?["isSuccess"] as? Bool == false { throw CatalogError.malformedResponse }
        if content?["rankList"] == nil { content = try deferredContent(html, route: key) }
        guard let content, content["isSuccess"] as? Bool != false,
              let rows = content["rankList"] as? [[String: Any]], rows.count <= 500 else { throw CatalogError.malformedResponse }
        let more = try pagination(content["pagination"], page: page)
        var seen: Set<String> = []
        let items = rows.compactMap { row -> DiscoveryItem? in
            let id = string(row["seriesId"] ?? row["series_id"] ?? row["id"])
            guard (try? validateID(id)) != nil, let rank = integer(row["rank"]), rank > 0, rank <= 1_000_000,
                  [row["seriesId"], row["series_id"], row["id"]].compactMap({ $0 }).allSatisfy({ string($0) == id }) else { return nil }
            let normalized: [String: Any] = ["series_id": id, "series_name": row["title"] ?? row["seriesTitle"] ?? row["series_name"] ?? "",
                "series_cover": row["cover"] ?? row["seriesCover"] ?? row["series_cover"] ?? "",
                "series_intro": row["description"] ?? row["intro"] ?? "", "episode_cnt": row["episodeCount"] ?? row["episode_cnt"] ?? 0,
                "tags": row["tags"] ?? []]
            guard let series = try? WebsiteParser.card(normalized), seen.insert(id).inserted else { return nil }
            return DiscoveryItem(series: series, rank: rank, heatText: label(row["heatText"]), scoreText: label(row["scoreText"]), statusText: status(row))
        }
        guard rows.isEmpty || !items.isEmpty else { throw CatalogError.malformedResponse }
        try Task.checkCancellation()
        return DiscoveryPage(items: items, page: page, hasMore: more, updatedText: label(base["updatedText"]))
    }

    private static func loaders(_ html: String) throws -> [String: Any] {
        try Task.checkCancellation()
        guard html.utf8.count <= maximumBytes,
              let loader = try WebsiteParser.routerData(html: html)["loaderData"] as? [String: Any], loader.count <= 100 else { throw CatalogError.malformedResponse }
        return loader
    }

    private static func canonical(_ value: Any?, path: String) throws {
        let raw = string(value)
        guard !raw.isEmpty else { return }
        guard let url = URL(string: raw, relativeTo: DirectWebService.siteURL)?.absoluteURL,
              sameOrigin(url, DirectWebService.siteURL), url.user == nil, url.password == nil, url.fragment == nil,
              url.path == path else { throw CatalogError.malformedResponse }
    }

    private static func pagination(_ value: Any?, page: Int) throws -> Bool {
        guard let value = value as? [String: Any], let current = integer(value["pageNum"]), current == page,
              let total = integer(value["totalPages"]), total >= 0, total <= 100_000,
              total >= current || (total == 0 && current == 1) else { throw CatalogError.malformedResponse }
        return page < total && page < 100
    }

    private static func genres(_ value: Any?) throws -> [DiscoveryGenre] {
        guard let rows = value as? [[String: Any]] else { return [] }
        guard rows.count <= 64 else { throw CatalogError.malformedResponse }
        var seen: Set<String> = [], result: [DiscoveryGenre] = [], count = 0
        for row in rows {
            let options = row["items"] as? [[String: Any]] ?? []
            count += options.count
            guard count <= 512 else { throw CatalogError.malformedResponse }
            for option in options {
                let id = string(option["selector_item_id"]), title = label(option["show_name"], limit: 80)
                if validSlug(id), !title.isEmpty, seen.insert(id).inserted { result.append(.init(id: id, title: title)) }
            }
        }
        return result
    }

    private static func label(_ value: Any?, limit: Int = 256) -> String {
        guard let value = value as? String else { return "" }
        return String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }

    private static func status(_ value: [String: Any]) -> String {
        let tags = (value["statusTags"] as? [String] ?? []).prefix(8).map { label($0, limit: 80) }.filter { !$0.isEmpty }
        return tags.isEmpty ? label(value["statusText"]) : tags.joined(separator: " · ")
    }

    static func deferredContent(_ html: String, route: String, key: String = "content") throws -> [String: Any]? {
        try Task.checkCancellation()
        guard html.utf8.count <= maximumBytes else { throw CatalogError.malformedResponse }
        let scripts = try NSRegularExpression(pattern: #"<script\b((?:"[^"]*"|'[^']*'|[^'">])*)>"#, options: [.caseInsensitive])
        let attributes = try NSRegularExpression(pattern: #"([A-Za-z_:][A-Za-z0-9_:.\-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
        let matches = scripts.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard matches.count <= 512 else { throw CatalogError.malformedResponse }
        for script in matches {
            try Task.checkCancellation()
            guard let range = Range(script.range(at: 1), in: html) else { continue }
            let raw = String(html[range]); var values: [String: String] = [:]
            for attribute in attributes.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let name = Range(attribute.range(at: 1), in: raw),
                      let value = Range(attribute.range(at: attribute.range(at: 2).location == NSNotFound ? 3 : 2), in: raw) else { continue }
                values[String(raw[name]).lowercased()] = decodeEntities(String(raw[value]))
            }
            guard let name = values["data-fn-name"], ["r", "mergeLoaderData"].contains(name),
                  let encoded = values["data-fn-args"]?.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: encoded) as? [Any], args.first as? String == route else { continue }
            if name == "r", args.count == 3, args[1] as? String == key, let payload = args[2] as? [String: Any] { return payload }
            if name == "mergeLoaderData", args.count >= 2, let entries = args[1] as? [[String: Any]] {
                for entry in entries where entry["key"] as? String == key && entry["routerDataFnName"] as? String == "p" {
                    guard let params = entry["routerDataFnArgs"] as? [String], let text = params.first?.data(using: .utf8),
                          let payload = try? JSONSerialization.jsonObject(with: text) as? [String: Any] else { continue }
                    return payload
                }
            }
        }
        return nil
    }

    private static func decodeEntities(_ value: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: #"&(?:quot|apos|amp|lt|gt|#[0-9]{1,8}|#x[0-9a-fA-F]{1,8});"#) else { return value }
        let source = value as NSString
        let result = NSMutableString(capacity: source.length)
        var cursor = 0
        for match in expression.matches(in: value, range: NSRange(location: 0, length: source.length)) {
            result.append(source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            let entity = source.substring(with: match.range); let replacement: String?
            switch entity {
            case "&quot;": replacement = "\""
            case "&apos;": replacement = "'"
            case "&amp;": replacement = "&"
            case "&lt;": replacement = "<"
            case "&gt;": replacement = ">"
            default:
                let hex = entity.hasPrefix("&#x")
                let digits = entity.dropFirst(hex ? 3 : 2).dropLast()
                replacement = UInt32(digits, radix: hex ? 16 : 10).flatMap(UnicodeScalar.init).map(String.init)
            }
            result.append(replacement ?? entity)
            cursor = NSMaxRange(match.range)
        }
        result.append(source.substring(from: cursor))
        return result as String
    }
}
