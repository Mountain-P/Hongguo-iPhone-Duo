import Foundation

public struct Series: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var cover: String
    public var description: String
    public var badge: String
    public var tags: [String]

    public init(id: String, title: String, cover: String = "", description: String = "", badge: String = "", tags: [String] = []) {
        self.id = id; self.title = title; self.cover = cover
        self.description = description; self.badge = badge; self.tags = tags
    }
}

public struct Episode: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var number: Int
    public var title: String
    public var isAvailable: Bool

    public init(id: String, number: Int, title: String, isAvailable: Bool = true) {
        self.id = id; self.number = number; self.title = title; self.isAvailable = isAvailable
    }
}

public struct SeriesDetail: Codable, Hashable, Sendable {
    public var series: Series
    public var episodes: [Episode]
    public var discovery: SeriesDiscoveryMetadata?
    public init(series: Series, episodes: [Episode], discovery: SeriesDiscoveryMetadata? = nil) {
        self.series = series; self.episodes = episodes; self.discovery = discovery
    }
}

public struct SeriesPage: Codable, Hashable, Sendable {
    public var items: [Series]
    public var page: Int
    public var hasMore: Bool
    public init(items: [Series], page: Int, hasMore: Bool) { self.items = items; self.page = page; self.hasMore = hasMore }
}

public struct PlaybackSource: Hashable, Sendable {
    public var url: URL
    public var headers: [String: String]
    public var contentType: String
    public var nativeStream: NativeMediaStream?
    public init(url: URL, headers: [String: String] = [:], contentType: String = "video/mp4", nativeStream: NativeMediaStream? = nil) {
        self.url = url; self.headers = headers; self.contentType = contentType; self.nativeStream = nativeStream
    }
}

public protocol CatalogService: Sendable {
    func home(page: Int) async throws -> SeriesPage
    func search(query: String, page: Int) async throws -> SeriesPage
    func detail(id: String) async throws -> SeriesDetail
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource
}

public enum CatalogError: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration
    case invalidID
    case invalidPage
    case invalidQuery
    case unauthorized
    case network
    case httpStatus(Int)
    case incompatibleBridge
    case malformedResponse
    case responseTooLarge
    case protectedPlayback
    case unavailablePlayback
    case unsafePlaybackURL

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "請輸入有效的 HTTPS 服務網址（區域網路可使用 HTTP），且不要包含帳號、密碼或查詢參數。"
        case .invalidID: "劇集或分集編號無效。"
        case .invalidPage: "分頁編號無效。"
        case .invalidQuery: "請輸入 1 至 80 字的搜尋詞。"
        case .unauthorized: "服務存取口令不正確，請在設定中更新。"
        case .network: "無法連線，請檢查網路或服務網址後重試。"
        case .httpStatus(403): "來源服務拒絕存取，請確認服務權限或在官方平台觀看。"
        case .httpStatus(let status): "內容來源暫時無法使用（HTTP \(status)），請稍後重試。"
        case .incompatibleBridge: "此網址不是相容的紅果播放服務，或回應協定不符。請確認橋接服務與網址。"
        case .malformedResponse: "內容來源的資料格式已變更，請稍後重試。"
        case .responseTooLarge: "內容來源回傳的資料過大。"
        case .protectedPlayback: "這一集需要來源平台授權，請在紅果官方頁面觀看，或改用已設定的內容服務。"
        case .unavailablePlayback: "來源暫未提供這一集的公開影片，請稍後重試或在官方頁面觀看。"
        case .unsafePlaybackURL: "來源回傳的影片網址無效，已停止載入。"
        }
    }
}

func validateID(_ id: String) throws {
    guard (1...30).contains(id.utf8.count), id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw CatalogError.invalidID }
}

func validatePage(_ page: Int) throws {
    guard (1...100).contains(page) else { throw CatalogError.invalidPage }
}

func normalizedQuery(_ query: String) throws -> String {
    let value = query.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...80).contains(value.count) else { throw CatalogError.invalidQuery }
    return value
}
