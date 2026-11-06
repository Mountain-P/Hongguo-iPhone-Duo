import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads the public website's own catalogue and explicitly available VideoObject media.
/// Protected previews are never presented as complete episodes.
public struct DirectWebService: CatalogService {
    public enum Category: String, CaseIterable, Codable, Sendable {
        case realDrama = "real-drama"
        case comicDrama = "comic-drama"
        case aiDrama = "ai-drama"
    }

    public let category: Category
    private let transport: any HTTPTransport
    public static let siteURL = URL(string: "https://hongguoduanju.com")!
    public static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    public init(category: Category = .realDrama, transport: any HTTPTransport = URLSessionTransport()) {
        self.category = category; self.transport = transport
    }

    public func home(page: Int) async throws -> SeriesPage {
        try validatePage(page)
        let data = try await get("category/\(category.rawValue)", query: [.init(name: "page", value: String(page))])
        return try WebsiteParser.catalog(html: html(data), category: category.rawValue, page: page)
    }

    public func search(query: String, page: Int) async throws -> SeriesPage {
        try validatePage(page)
        let keyword = try normalizedQuery(query)
        let data = try await get("api/search/result", query: [.init(name: "aid", value: "8662"), .init(name: "query", value: keyword), .init(name: "page", value: String(page))])
        return try WebsiteParser.search(data: data, page: page)
    }

    public func detail(id: String) async throws -> SeriesDetail {
        try validateID(id)
        do {
            return try WebsiteParser.detail(html: html(await get("player/\(id)")), seriesID: id)
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // The website sometimes serves a healthy detail page while its player edge is unavailable.
            return try WebsiteParser.detail(html: html(await get("detail", query: [.init(name: "series_id", value: id)])), seriesID: id)
        }
    }

    public func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        try validateID(seriesID); try validateID(episodeID)
        var request = makeRequest("player/\(seriesID)/\(episodeID)")
        if fresh { request.setValue("no-cache", forHTTPHeaderField: "Cache-Control") }
        let data = try await load(request, using: transport)
        let url = try WebsiteParser.playback(html: html(data), seriesID: seriesID, episodeID: episodeID)
        return PlaybackSource(url: url, headers: ["User-Agent": Self.userAgent, "Referer": Self.siteURL.absoluteString + "/"])
    }

    private func html(_ data: Data) throws -> String {
        guard let html = String(data: data, encoding: .utf8) else { throw CatalogError.malformedResponse }
        return html
    }

    private func makeRequest(_ path: String, query: [URLQueryItem] = []) -> URLRequest {
        var components = URLComponents(url: Self.siteURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.siteURL.absoluteString + "/", forHTTPHeaderField: "Referer")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("text/html,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        return request
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await load(makeRequest(path, query: query), using: transport)
    }
}

public enum WebsiteParser {
    /// Parses a balanced JSON literal; it never evaluates source-page JavaScript.
    public static func routerData(html: String) throws -> [String: Any] {
        guard html.utf8.count <= 16 * 1024 * 1024,
              let assignment = html.range(of: #"(?:window\.)?_ROUTER_DATA\s*=\s*\{"#, options: .regularExpression),
              let beginning = html[assignment].lastIndex(of: "{") else { throw CatalogError.malformedResponse }
        var depth = 0
        var quoted = false
        var escaped = false
        var cursor = beginning
        while cursor < html.endIndex {
            let character = html[cursor]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else {
                if character == "\"" { quoted = true }
                else if character == "{" { depth += 1 }
                else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return try dictionary(Data(html[beginning...cursor].utf8))
                    }
                }
            }
            cursor = html.index(after: cursor)
        }
        throw CatalogError.malformedResponse
    }

    public static func catalog(html: String, category: String = "real-drama", page: Int = 1) throws -> SeriesPage {
        let loader = try loaders(html)
        let section = loader.values.compactMap { $0 as? [String: Any] }.first {
            let route = $0["categoryRoute"] as? [String: Any]
            return string(route?["contentType"]) == category
        }
        guard let section, section["isSuccess"] as? Bool != false,
              let rows = section["recommendList"] as? [[String: Any]] else { throw CatalogError.malformedResponse }
        let items = try cards(rows)
        let pagination = section["pagination"] as? [String: Any]
        let currentPage = integer(pagination?["pageNum"]) ?? page
        let totalPages = integer(pagination?["totalPages"])
        return SeriesPage(items: items, page: currentPage,
                          hasMore: currentPage < 100 && (totalPages.map { currentPage < $0 } ?? !items.isEmpty))
    }

    public static func search(data: Data, page: Int = 1) throws -> SeriesPage {
        let object = try dictionary(data)
        if object["code"] is String { throw CatalogError.malformedResponse }
        guard let rows = object["searchList"] as? [[String: Any]] else { throw CatalogError.malformedResponse }
        let items = try cards(rows)
        let currentPage = integer(object["pageNum"]) ?? page
        let hasMore = object["hasMore"] as? Bool ?? integer(object["totalPages"]).map { currentPage < $0 } ?? false
        return SeriesPage(items: items, page: currentPage, hasMore: hasMore && currentPage < 100)
    }

    public static func detail(html: String, seriesID: String) throws -> SeriesDetail {
        let detail = try seriesPayload(html: html, seriesID: seriesID)
        guard let raw = detail["vid_list"] as? [Any], !raw.isEmpty, raw.count <= 5000 else { throw CatalogError.malformedResponse }
        let ids = raw.map { string($0) }
        try ids.forEach(validateID)
        guard Set(ids).count == ids.count else { throw CatalogError.malformedResponse }
        let accessible = integer(detail["accessible_episode_cnt"])
        if let accessible, accessible < 0 { throw CatalogError.malformedResponse }
        let series = try card(detail)
        return SeriesDetail(series: series, episodes: ids.enumerated().map { index, id in
            Episode(id: id, number: index + 1, title: "第 \(index + 1) 集", isAvailable: accessible.map { index < $0 } ?? true)
        }, discovery: try? ArtistDiscoveryParser.metadata(html: html, seriesID: seriesID))
    }

    /// The website and the native playback API use the same authoritative series/vid binding.
    /// Availability is interpreted by each consumer rather than by this metadata parser.
    static func seriesPayload(html: String, seriesID: String) throws -> [String: Any] {
        try validateID(seriesID)
        let loader = try loaders(html)
        guard let data = (loader["player_(series_id)/page"] ?? loader["player_(series_id)/(vid)/page"] ?? loader["detail_page"]) as? [String: Any],
              data["isSuccess"] as? Bool != false, let detail = data["seriesDetail"] as? [String: Any],
              string(detail["series_id"]) == seriesID,
              data["series_id"] == nil || string(data["series_id"]) == seriesID else { throw CatalogError.malformedResponse }
        return detail
    }

    public static func playback(html: String, seriesID: String, episodeID: String) throws -> URL {
        try validateID(seriesID); try validateID(episodeID)
        let loader = try loaders(html)
        guard let data = loader["player_(series_id)/(vid)/page"] as? [String: Any],
              data["isSuccess"] as? Bool != false,
              string(data["series_id"]) == seriesID, string(data["vid"]) == episodeID,
              let detail = data["seriesDetail"] as? [String: Any], string(detail["series_id"]) == seriesID else { throw CatalogError.malformedResponse }
        if data["protectedPlayback"] as? Bool == true { throw CatalogError.protectedPlayback }
        guard let seo = data["publicVideoSeo"] as? [String: Any], seo["available"] as? Bool == true,
              string(seo["itemId"]) == episodeID, string(seo["seriesId"]) == seriesID else { throw CatalogError.unavailablePlayback }

        let expression = try NSRegularExpression(pattern: #"<script\b([^>]*)>([\s\S]*?)</script\s*>"#, options: .caseInsensitive)
        let range = NSRange(html.startIndex..., in: html)
        for match in expression.matches(in: html, range: range) {
            guard let attributesRange = Range(match.range(at: 1), in: html), let bodyRange = Range(match.range(at: 2), in: html),
                  html[attributesRange].range(of: #"\btype\s*=\s*["']application/ld\+json["']"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let object = try? JSONSerialization.jsonObject(with: Data(html[bodyRange].utf8)) else { continue }
            for video in videoObjects(object) {
                let content = cleanedURLString(video["contentUrl"])
                guard let media = URL(string: content), isPublicMediaURL(media),
                      matchesPlayer(string(video["url"]), media: media, seriesID: seriesID, episodeID: episodeID),
                      video["@id"] == nil || matchesPlayer(string(video["@id"]), media: media, seriesID: seriesID, episodeID: episodeID) else { continue }
                return media
            }
        }
        throw CatalogError.unavailablePlayback
    }

    private static func loaders(_ html: String) throws -> [String: Any] {
        guard let loader = try routerData(html: html)["loaderData"] as? [String: Any] else { throw CatalogError.malformedResponse }
        return loader
    }

    private static func cards(_ rows: [[String: Any]]) throws -> [Series] {
        guard rows.count <= 500 else { throw CatalogError.malformedResponse }
        var seen: Set<String> = []
        let result = rows.compactMap { try? card($0) }.filter { seen.insert($0.id).inserted }
        guard rows.isEmpty || !result.isEmpty else { throw CatalogError.malformedResponse }
        return result
    }

    static func card(_ row: [String: Any]) throws -> Series {
        let nested = row["video_data"] as? [String: Any]
        let value = (nested?.isEmpty == false ? nested : nil) ?? row
        let id = string(value["series_id"] ?? row["series_id"] ?? row["keyword"])
        try validateID(id)
        let title = string(value["series_name"] ?? value["series_title"] ?? row["name"] ?? value["title"])
        guard !title.isEmpty else { throw CatalogError.malformedResponse }
        let count = integer(value["episode_cnt"]) ?? 0
        let label = string(value["episode_right_text"])
        let rawCover = cleanedURLString(value["series_cover"] ?? value["cover"])
        let cover = URL(string: rawCover).map { ["https", "http"].contains($0.scheme ?? "") ? rawCover : "" } ?? ""
        return Series(id: id, title: title, cover: cover, description: string(value["series_intro"]),
                      badge: label.isEmpty && count > 0 ? "全 \(count) 集" : label, tags: tags(value["tags"] ?? value["category_list"]))
    }

    private static func videoObjects(_ object: Any) -> [[String: Any]] {
        if let array = object as? [Any] { return array.flatMap(videoObjects) }
        guard let object = object as? [String: Any] else { return [] }
        var result: [[String: Any]] = string(object["@type"]) == "VideoObject" ? [object] : []
        if let graph = object["@graph"] { result += videoObjects(graph) }
        return result
    }

    private static func matchesPlayer(_ value: String, media: URL, seriesID: String, episodeID: String) -> Bool {
        guard let page = URL(string: value), sameOrigin(page, DirectWebService.siteURL), page.user == nil, page.password == nil else { return false }
        if page.path == "/player/\(seriesID)/\(episodeID)" { return true }
        return page.path == "/player/\(seriesID)" && sameOrigin(media, DirectWebService.siteURL) && media.path.hasPrefix("/video/public/\(episodeID)/")
    }

    private static func isPublicMediaURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.fragment == nil, let rawHost = url.host?.lowercased(), !rawHost.isEmpty, url.absoluteString.count <= 16384 else { return false }
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Media must come from an Internet domain or public IPv4 address, never a LAN endpoint.
        guard host.contains("."), !host.hasSuffix(".local"), !host.hasSuffix(".localhost"), !host.hasSuffix(".internal"),
              !host.contains(":"), host.range(of: #"^[a-z0-9.-]+$"#, options: .regularExpression) != nil else { return false }
        let parts = host.split(separator: ".")
        if let last = parts.last, last.allSatisfy(\.isNumber) {
            guard parts.count == 4 else { return false }
            let bytes = parts.compactMap { Int($0) }
            guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }),
                  zip(parts, bytes).allSatisfy({ String($0.0) == String($0.1) }) else { return false }
            let a = bytes[0], b = bytes[1]
            guard a != 0, a != 10, a != 127, a < 224,
                  !(a == 169 && b == 254), !(a == 172 && (16...31).contains(b)),
                  !(a == 192 && b == 168), !(a == 100 && (64...127).contains(b)),
                  !(a == 198 && (18...19).contains(b)) else { return false }
        }
        return true
    }
}
