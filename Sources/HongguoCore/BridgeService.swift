import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ServerConfiguration: Hashable, Sendable {
    public let baseURL: URL
    public let token: String

    public init(baseURL: String, token: String = "") throws {
        let input = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.count <= 4096, !input.contains("\\"),
              var components = URLComponents(string: input),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.scheme?.lowercased() != "http" || Self.isLocalHost(host),
              token.count <= 4096, !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CatalogError.invalidConfiguration
        }
        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw CatalogError.invalidConfiguration }
        self.baseURL = url
        self.token = token.trimmingCharacters(in: .whitespaces)
    }

    public init(baseURL: URL, token: String = "") throws { try self.init(baseURL: baseURL.absoluteString, token: token) }

    private static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host == "::1" || host.hasSuffix(".local") { return true }
        if host.hasPrefix("fe80:") || host.hasPrefix("fc") && host.contains(":") || host.hasPrefix("fd") && host.contains(":") { return true }
        let components = host.split(separator: ".")
        let octets = components.compactMap { Int($0) }
        guard octets.count == 4, components.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        return octets[0] == 10 || octets[0] == 127 || octets[0] == 192 && octets[1] == 168
            || octets[0] == 172 && (16...31).contains(octets[1]) || octets[0] == 169 && octets[1] == 254
    }
}

public struct BridgeService: CatalogService {
    public let configuration: ServerConfiguration
    private let transport: any HTTPTransport

    public init(configuration: ServerConfiguration, transport: any HTTPTransport = URLSessionTransport()) {
        self.configuration = configuration; self.transport = transport
    }

    public func checkConnection() async throws {
        try Task.checkCancellation()
        do {
            let data = try await get("health")
            guard string(data["service"]) == "hongguotv", integer(data["apiVersion"]) == 1 else { throw CatalogError.incompatibleBridge }
        } catch CatalogError.malformedResponse {
            throw CatalogError.incompatibleBridge
        }
    }

    /// Verifies this bridge's protocol and catalogue response, not media availability.
    public func verifyConnection() async throws -> Int {
        try await checkConnection()
        try Task.checkCancellation()
        do {
            return try await home(page: 1).items.count
        } catch CatalogError.malformedResponse {
            throw CatalogError.incompatibleBridge
        }
    }

    /// Requires the expected bridge protocol before accepting a series/episode list.
    public func verifiedDetail(id: String) async throws -> SeriesDetail {
        try validateID(id)
        try await checkConnection()
        try Task.checkCancellation()
        do {
            return try await detail(id: id)
        } catch CatalogError.malformedResponse {
            throw CatalogError.incompatibleBridge
        }
    }

    public func home(page: Int) async throws -> SeriesPage {
        try validatePage(page)
        return try parsePage(await get("api/home", query: [.init(name: "page", value: String(page))]), page: page)
    }

    public func search(query: String, page: Int) async throws -> SeriesPage {
        try validatePage(page)
        let keyword = try normalizedQuery(query)
        return try parsePage(await get("api/search", query: [.init(name: "q", value: keyword), .init(name: "page", value: String(page))]), page: page)
    }

    public func detail(id: String) async throws -> SeriesDetail {
        try validateID(id)
        let data = try await get("api/series/\(id)")
        let series = try parseSeries(data)
        guard series.id == id, let rows = data["episodes"] as? [[String: Any]], !rows.isEmpty, rows.count <= 5000 else { throw CatalogError.malformedResponse }
        let episodes = try rows.enumerated().map { index, row in
            let id = string(row["id"]); try validateID(id)
            let number = integer(row["number"]) ?? index + 1
            guard number > 0 else { throw CatalogError.malformedResponse }
            let available: Bool
            if let value = row["isAvailable"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw CatalogError.malformedResponse
                }
                available = flag.boolValue
            } else {
                available = true
            }
            return Episode(id: id, number: number, title: string(row["title"]).isEmpty ? "第 \(number) 集" : string(row["title"]),
                           isAvailable: available)
        }
        guard Set(episodes.map(\.id)).count == episodes.count else { throw CatalogError.malformedResponse }
        return SeriesDetail(series: series, episodes: episodes)
    }

    public func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        try validateID(seriesID); try validateID(episodeID)
        let data = try await get("api/episodes/\(episodeID)/play", query: fresh ? [.init(name: "fresh", value: "1")] : [])
        let path = string(data["path"])
        let url = try playbackURL(path)
        let contentType = string(data["contentType"])
        guard contentType.isEmpty || contentType.lowercased() == "video/mp4" else { throw CatalogError.malformedResponse }
        return PlaybackSource(url: url, headers: authorizationHeaders, contentType: contentType.isEmpty ? "video/mp4" : contentType)
    }

    private func playbackURL(_ value: String) throws -> URL {
        guard !value.isEmpty, !value.hasPrefix("//"), let returned = URLComponents(string: value),
              returned.fragment == nil, returned.user == nil, returned.password == nil else { throw CatalogError.unsafePlaybackURL }
        if returned.scheme != nil || returned.host != nil {
            guard let url = returned.url, sameOrigin(url, configuration.baseURL) else { throw CatalogError.unsafePlaybackURL }
            return url
        }
        // The bridge returns paths relative to its own server root. Preserve a
        // reverse-proxy mount such as /bridge even when that path begins /api/.
        let responsePath = "/" + returned.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard responsePath != "/", !responsePath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CatalogError.unsafePlaybackURL
        }
        let prefix = configuration.baseURL.path
        let alreadyPrefixed = !prefix.isEmpty && (responsePath == prefix || responsePath.hasPrefix(prefix + "/"))
        var target = URLComponents(url: configuration.baseURL, resolvingAgainstBaseURL: false)!
        target.path = alreadyPrefixed ? responsePath : prefix + responsePath
        target.percentEncodedQuery = returned.percentEncodedQuery
        guard let url = target.url, sameOrigin(url, configuration.baseURL) else { throw CatalogError.unsafePlaybackURL }
        return url
    }

    private var authorizationHeaders: [String: String] {
        configuration.token.isEmpty ? [:] : ["Authorization": "Bearer \(configuration.token)"]
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> [String: Any] {
        var components = URLComponents(url: configuration.baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in authorizationHeaders { request.setValue(value, forHTTPHeaderField: key) }
        return try dictionary(await load(request, using: transport))
    }

    private func parsePage(_ data: [String: Any], page: Int) throws -> SeriesPage {
        guard let rows = data["items"] as? [[String: Any]], rows.count <= 500 else { throw CatalogError.malformedResponse }
        var seen: Set<String> = []
        let items = try rows.map(parseSeries).filter { seen.insert($0.id).inserted }
        return SeriesPage(items: items, page: integer(data["page"]) ?? page,
                          hasMore: (data["hasMore"] as? Bool ?? !items.isEmpty) && page < 100)
    }

    private func parseSeries(_ object: [String: Any]) throws -> Series {
        let id = string(object["id"]); try validateID(id)
        let title = string(object["title"])
        guard !title.isEmpty else { throw CatalogError.malformedResponse }
        return Series(id: id, title: title, cover: cleanedURLString(object["cover"]), description: string(object["description"]),
                      badge: string(object["badge"]), tags: tags(object["tags"]))
    }
}
