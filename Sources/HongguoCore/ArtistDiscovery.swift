// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct Artist: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var avatar: String
    public var role: String
    public init(id: String, name: String, avatar: String = "", role: String = "") {
        self.id = id; self.name = name; self.avatar = avatar; self.role = role
    }
}

public struct SeriesDiscoveryMetadata: Codable, Hashable, Sendable {
    public var artists: [Artist]
    public var related: [Series]
    public var ratingText: String
    public var heatText: String
    public var likeText: String
    public var favoriteText: String
    public var releaseText: String
    public init(artists: [Artist] = [], related: [Series] = [], ratingText: String = "", heatText: String = "",
                likeText: String = "", favoriteText: String = "", releaseText: String = "") {
        self.artists = artists; self.related = related; self.ratingText = ratingText; self.heatText = heatText
        self.likeText = likeText; self.favoriteText = favoriteText; self.releaseText = releaseText
    }
}

public struct ArtistProfile: Codable, Hashable, Sendable {
    public var artist: Artist
    public var biography: String
    public var works: [Series]
    public init(artist: Artist, biography: String = "", works: [Series] = []) {
        self.artist = artist; self.biography = biography; self.works = works
    }
}

/// Reads the official public artist page. Works retain its supplied order and coverage.
public struct ArtistDiscoveryService: Sendable {
    private let transport: any HTTPTransport
    public init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }

    public func artist(id: String) async throws -> ArtistProfile {
        try validateID(id)
        try Task.checkCancellation()
        let url = DirectWebService.siteURL.appendingPathComponent("character").appendingPathComponent(id)
        var request = URLRequest(url: url)
        request.setValue(DirectWebService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(DirectWebService.siteURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let data = try await load(request, using: transport)
        try Task.checkCancellation()
        guard data.count <= DiscoveryParser.maximumBytes else { throw CatalogError.responseTooLarge }
        guard let html = String(data: data, encoding: .utf8) else { throw CatalogError.malformedResponse }
        let result = try ArtistDiscoveryParser.artist(html: html, id: id)
        try Task.checkCancellation()
        return result
    }
}

enum ArtistDiscoveryParser {
    static func artist(html: String, id: String) throws -> ArtistProfile {
        try validateID(id)
        guard html.utf8.count <= DiscoveryParser.maximumBytes,
              let loader = try WebsiteParser.routerData(html: html)["loaderData"] as? [String: Any],
              let page = loader["character_(id)/page"] as? [String: Any],
              page["isSuccess"] as? Bool != false,
              page["person_id"] as? String == id,
              let user = page["userInfo"] as? [String: Any], user["person_id"] as? String == id,
              let rows = page["videoList"] as? [[String: Any]], rows.count <= 500,
              (page["req"] as? [String: Any])?["isSuccess"] as? Bool != false else { throw CatalogError.malformedResponse }
        let name = text(user["user_name"], limit: 160)
        guard !name.isEmpty else { throw CatalogError.malformedResponse }
        let subtitles = (user["subtitle_list"] as? [String] ?? []).prefix(4).map { text($0, limit: 160) }.filter { !$0.isEmpty }
        let person = Artist(id: id, name: name, avatar: image(user["user_avatar"]), role: subtitles.joined(separator: " · "))
        let works = series(rows)
        guard rows.isEmpty || !works.isEmpty else { throw CatalogError.malformedResponse }
        return ArtistProfile(artist: person, biography: text(user["description"], limit: 4_000), works: works)
    }

    /// Optional enrichment uses only this already-fetched, series-bound page.
    static func metadata(html: String, seriesID: String) throws -> SeriesDiscoveryMetadata {
        let detail = try WebsiteParser.seriesPayload(html: html, seriesID: seriesID)
        let loader = try WebsiteParser.routerData(html: html)["loaderData"] as? [String: Any]
        let section = (loader?["player_(series_id)/page"] ?? loader?["player_(series_id)/(vid)/page"] ?? loader?["detail_page"]) as? [String: Any]
        let social = section?["seriesSocialInfo"] as? [String: Any] ?? [:]
        let credits = artists(detail["celebrities"])
        var recommendations = section?["recommendations"] as? [String: Any]
        if recommendations?["recommendationGroups"] == nil {
            recommendations = (try? DiscoveryParser.deferredContent(html, route: "detail_page", key: "recommendations")) ?? recommendations
        }
        let groups = recommendations?["recommendationGroups"] as? [String: Any]
        let rows = groups?["related_list"] as? [[String: Any]] ?? []
        // hot_list and generic videoList are deliberately not treated as related recommendations.
        let related = rows.count <= 100 ? series(rows).filter { $0.id != seriesID } : []
        let heat = text((social["hot_score_data"] as? [String: Any])?["text"], limit: 160)
        return SeriesDiscoveryMetadata(artists: credits, related: related, ratingText: rating(social["rating"]), heatText: heat,
                                       likeText: count(social["series_like_count"]), favoriteText: count(social["series_favorite_count"]),
                                       releaseText: releaseDate(detail["first_visible_time"]))
    }

    private static func artists(_ value: Any?) -> [Artist] {
        guard let rows = value as? [[String: Any]], rows.count <= 100 else { return [] }
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let id = row["celebrity_id"] as? String, (try? validateID(id)) != nil else { return nil }
            let name = text(row["nickname"], limit: 160)
            guard !name.isEmpty, seen.insert(id).inserted else { return nil }
            return Artist(id: id, name: name, avatar: image(row["avatar"]), role: text(row["sub_title"], limit: 160))
        }
    }

    private static func series(_ rows: [[String: Any]]) -> [Series] {
        var seen: Set<String> = []
        return rows.compactMap { row in
            guard let id = row["series_id"] as? String, (try? validateID(id)) != nil,
                  var card = try? WebsiteParser.card(row), card.title.count <= 300, seen.insert(card.id).inserted else { return nil }
            card.cover = image(card.cover)
            card.description = String(card.description.prefix(4_000))
            card.tags = card.tags.filter { $0.count <= 160 }.prefix(8).map { $0 }
            return card
        }
    }

    private static func text(_ value: Any?, limit: Int) -> String {
        guard let value = value as? String, value.count <= limit else { return "" }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func image(_ value: Any?) -> String {
        guard let value = value as? String, value.utf8.count <= 8_192, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.host != nil else { return "" }
        return value
    }

    private static func rating(_ value: Any?) -> String {
        guard let value, !isBoolean(value), let number = Double(string(value)), number.isFinite, number > 0, number <= 10 else { return "" }
        return String(format: number.rounded() == number ? "%.0f" : "%.1f", locale: Locale(identifier: "en_US_POSIX"), number)
    }

    private static func count(_ value: Any?) -> String {
        guard let value, !isBoolean(value) else { return "" }
        let raw = string(value)
        guard raw.range(of: #"^\d{1,15}$"#, options: .regularExpression) != nil, let number = Int64(raw) else { return "" }
        return number.formatted(.number.locale(Locale(identifier: "zh_TW")))
    }

    private static func releaseDate(_ value: Any?) -> String {
        guard let raw = value as? String, raw.range(of: #"^\d{10}$"#, options: .regularExpression) != nil,
              let seconds = TimeInterval(raw), (946_684_800...4_102_444_800).contains(seconds) else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    private static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
