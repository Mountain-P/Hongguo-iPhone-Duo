// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum NewReleaseCategory: String, CaseIterable, Codable, Sendable {
    case realDrama
    case aiDrama
}

public enum NewReleaseError: Error, LocalizedError, Equatable, Sendable {
    case timeout
    case rejected
    case httpStatus(Int)
    case malformedResponse
    case network

    public var errorDescription: String? {
        switch self {
        case .timeout: "新劇片單載入逾時，請重試。"
        case .rejected: "來源暫未提供新劇片單，請稍後重試。"
        case .httpStatus(let status): "新劇來源暫時無法使用（HTTP \(status)），請稍後重試。"
        case .malformedResponse: "新劇來源資料格式已變更，請稍後重試。"
        case .network: "無法連線至新劇來源，請稍後重試。"
        }
    }
}

/// A bounded snapshot of the source's last-seven-days catalogue, not a release calendar.
/// Each request has an isolated anonymous metadata profile and fetches at most two pages.
public actor NativeNewReleaseService {
    private struct Entry { let value: DiscoveryPage; let expires: Date }
    private var cache: [NewReleaseCategory: Entry] = [:]
    private var requests: [NewReleaseCategory: UUID] = [:]
    private let now: @Sendable () -> Date
    private let load: @Sendable (NewReleaseCategory) async throws -> DiscoveryPage

    public init() {
        now = Date.init
        load = { try await NativeJSRuntime().newReleases(category: $0) }
    }

    init(now: @escaping @Sendable () -> Date = Date.init,
         load: @escaping @Sendable (NewReleaseCategory) async throws -> DiscoveryPage) {
        self.now = now; self.load = load
    }

    public func releases(category: NewReleaseCategory, fresh: Bool = false) async throws -> DiscoveryPage {
        try Task.checkCancellation()
        if !fresh, let entry = cache[category], entry.expires > now() { return entry.value }
        cache.removeValue(forKey: category)
        let request = UUID(); requests[category] = request
        do {
            // Calls are isolated: cancelling one screen never cancels another caller's runtime.
            let result = try await load(category)
            try Task.checkCancellation()
            if requests[category] == request {
                requests.removeValue(forKey: category)
                // Empty snapshots are not retained after a transient empty source response.
                if !result.items.isEmpty { cache[category] = Entry(value: result, expires: now().addingTimeInterval(60)) }
            }
            return result
        } catch {
            if requests[category] == request { requests.removeValue(forKey: category) }
            throw error
        }
    }

    /// Pending requests may finish for their caller but cannot repopulate the cleared cache.
    public func clearCache() { cache.removeAll(); requests.removeAll() }
}

enum NativeNewReleaseParser {
    static func parse(_ raw: String) throws -> DiscoveryPage {
        guard raw.utf8.count <= 1024 * 1024, let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw NewReleaseError.malformedResponse }
        if let error = value["error"] as? String {
            if let status = value["status"] as? Int, (400...599).contains(status) { throw NewReleaseError.httpStatus(status) }
            switch error {
            case "ETIMEDOUT", "APP_TIMEOUT", "TimeoutError": throw NewReleaseError.timeout
            case "APP_BUSINESS": throw NewReleaseError.rejected
            case "APP_SCHEMA", "APP_CURSOR", "APP_INPUT", "INVALID_RESPONSE": throw NewReleaseError.malformedResponse
            default: throw NewReleaseError.network
            }
        }
        guard let rows = value["items"] as? [[String: Any]], rows.count <= 100 else { throw NewReleaseError.malformedResponse }
        var seen: Set<String> = []
        let items = rows.compactMap { row -> DiscoveryItem? in
            guard let id = row["id"] as? String, (try? validateID(id)) != nil,
                  let rawTitle = row["title"] as? String else { return nil }
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 300, seen.insert(id).inserted else { return nil }
            let count = row["episodeCount"] as? Int ?? 0
            let tags = (row["tags"] as? [String] ?? []).filter { !$0.isEmpty && $0.count <= 160 }.prefix(4)
            let description = String((row["description"] as? String ?? "").prefix(2_000))
            let status = row["statusText"] as? String ?? ""
            let series = Series(id: id, title: title, cover: safeCover(row["cover"] as? String ?? ""),
                                description: description, badge: (1...5_000).contains(count) ? "\(count) 集" : "", tags: Array(tags))
            return DiscoveryItem(series: series, statusText: ["今日上新", "新剧"].contains(status) ? status : "")
        }
        guard rows.isEmpty || !items.isEmpty else { throw NewReleaseError.malformedResponse }
        return DiscoveryPage(items: items, page: 1, hasMore: false, updatedText: "近7天上新 · 近期片單，最多100部")
    }

    private static func safeCover(_ raw: String) -> String {
        guard raw.utf8.count <= 4_096, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased(),
              ["fqnovelpic.com", "byteimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return "" }
        return raw
    }
}
