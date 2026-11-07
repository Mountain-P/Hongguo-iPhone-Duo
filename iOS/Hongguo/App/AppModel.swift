import SwiftUI
import CryptoKit
import Security
import Combine
import HongguoCore

enum CatalogSource: String, CaseIterable, Identifiable {
    case website, bridge
    var id: String { rawValue }
    var title: String { self == .website ? "內建目錄" : "自訂服務目錄" }
    var libraryNamespace: String { self == .website ? "direct" : "bridge" }
}

enum PlaybackMode: String, CaseIterable, Identifiable {
    case native, bridge
    var id: String { rawValue }
    var title: String { self == .native ? "內建播放" : "自訂播放服務" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var catalogSource: CatalogSource
    @Published private(set) var playbackMode: PlaybackMode
    @Published private(set) var nativePlaybackQuality: NativePlaybackQuality
    @Published private(set) var serverURL: String
    @Published private(set) var revision = UUID()
    @Published var searchHistory: [String]
    @Published private(set) var recommendationPreferences: RecommendationPreferences
    @Published private(set) var recommendationFilterRevision = UUID()
    @Published var isImmersivePlayback = false
    private let defaults = UserDefaults.standard
    private let library = AccountLibraryController()
    private var libraryObservation: AnyCancellable?

    var favorites: [Series] { library.favorites }
    var history: [WatchRecord] { library.history }
    var persistenceError: String? {
        get { library.persistenceError }
        set { library.persistenceError = newValue }
    }
    var accountProfile: AccountProfile? { library.accountProfile }
    var selectedLibraryOwner: LibraryOwner { library.selectedOwner }
    var hasAccount: Bool { library.accountProfile != nil }
    var showingAccountLibrary: Bool { library.showingAccountLibrary }
    var librarySyncing: Bool { library.syncing }
    var librarySyncPhase: String { library.syncPhase }
    var libraryMetadataLoading: Bool { library.loadingMetadata }
    var librarySyncError: String? { library.syncError }
    var lastLibrarySync: Date? { library.lastSync }
    var pendingSyncCount: Int { library.pendingCount }
    var retryRequiredSyncCount: Int { library.retryRequiredCount }
    var accountNeedsLogin: Bool { library.needsLogin }
    var libraryCoverageText: String? { library.coverageText }
    var canUseAccountLibrary: Bool { playbackMode == .native && hasAccount }

    init() {
        let initialPlayback = UserDefaults.standard.string(forKey: "playbackMode").flatMap(PlaybackMode.init(rawValue:)) ?? .native
        playbackMode = initialPlayback
        nativePlaybackQuality = NativePlaybackQualityStore.shared.load()
        let savedCatalog = UserDefaults.standard.string(forKey: "catalogSource")
        let legacyMode = UserDefaults.standard.string(forKey: "contentMode")
        catalogSource = savedCatalog.flatMap(CatalogSource.init(rawValue:))
            ?? (legacyMode == "bridge" ? .bridge : .website)
        if initialPlayback == .native { catalogSource = .website }
        serverURL = UserDefaults.standard.string(forKey: "serverURL") ?? ""
        searchHistory = UserDefaults.standard.stringArray(forKey: "searchHistory") ?? []
        let preferenceData = UserDefaults.standard.data(forKey: "recommendationPreferences.v1")
        recommendationPreferences = preferenceData.flatMap { data in
            guard data.count <= 256 * 1024 else { return nil as RecommendationPreferences? }
            return try? JSONDecoder().decode(RecommendationPreferences.self, from: data)
        } ?? .init()
        libraryObservation = library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        restoreLibrary()
    }

    private var libraryKey: String {
        let origin = playbackMode == .native ? "public" : serverURL
        let digest = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return "library.v1.\(playbackMode == .native ? "direct" : "bridge").\(digest)"
    }

    var isPlaybackConfigured: Bool { playbackMode == .native || !serverURL.isEmpty }

    func catalogService() throws -> any CatalogService {
        if catalogSource == .website { return NativeCatalogService(quality: nativePlaybackQuality) }
        return try playbackService()
    }

    func previewCatalogService() throws -> any CatalogService {
        if catalogSource == .website { return NativeCatalogService(category: recommendationPreferences.category, quality: nativePlaybackQuality) }
        return try playbackService()
    }

    func playbackService() throws -> any CatalogService {
        if playbackMode == .native { return NativeCatalogService(quality: nativePlaybackQuality) }
        guard !serverURL.isEmpty else { throw AppError.message("請先設定播放服務，才能查詢可選集數與播放影片。") }
        return BridgeService(configuration: try ServerConfiguration(baseURL: serverURL, token: token(for: serverURL)))
    }

    func token(for address: String) -> String { KeychainToken.read(account: address) }

    /// Verify the bridge contract before any URL/token is persisted. Cancellation leaves the existing configuration intact.
    func connect(address: String, token: String, catalogSource: CatalogSource) async throws -> Int {
        let configuration = try ServerConfiguration(baseURL: address, token: token)
        let count = try await BridgeService(configuration: configuration).verifyConnection()
        try Task.checkCancellation()
        let normalized = configuration.baseURL.absoluteString
        try KeychainToken.save(configuration.token, account: normalized)
        self.serverURL = normalized
        self.catalogSource = catalogSource
        self.playbackMode = .bridge
        defaults.set(PlaybackMode.bridge.rawValue, forKey: "playbackMode")
        defaults.set(catalogSource.rawValue, forKey: "catalogSource")
        defaults.set(normalized, forKey: "serverURL")
        restoreLibrary()
        revision = UUID()
        return count
    }

    func useWebsiteCatalog() {
        catalogSource = .website
        defaults.set(CatalogSource.website.rawValue, forKey: "catalogSource")
        restoreLibrary()
        revision = UUID()
    }

    func useNativePlayback() {
        playbackMode = .native
        catalogSource = .website
        defaults.set(PlaybackMode.native.rawValue, forKey: "playbackMode")
        defaults.set(CatalogSource.website.rawValue, forKey: "catalogSource")
        restoreLibrary()
        revision = UUID()
    }

    func setNativePlaybackQuality(_ quality: NativePlaybackQuality) {
        guard nativePlaybackQuality != quality else { return }
        nativePlaybackQuality = quality
        NativePlaybackQualityStore.shared.save(quality)
        // Existing players keep their captured service; the next load uses a new context.
        revision = UUID()
    }

    func isFavorite(_ series: Series) -> Bool { library.isFavorite(series) }

    func toggleFavorite(_ series: Series) {
        library.toggleFavorite(series)
    }

    func record(for series: Series) -> WatchRecord? { library.record(for: series) }

    func playbackProgressHandler(for series: Series, episodes: [Episode] = []) -> (Episode, Double, Double) -> Void {
        library.progressHandler(for: series, episodes: episodes)
    }

    func clearHistory() { library.clearHistory() }
    func removeHistory(_ series: Series) { library.removeHistory(series) }
    func removeHistory(seriesIDs: Set<String>) { library.removeHistory(seriesIDs: seriesIDs) }
    func removeFavorites(seriesIDs: Set<String>) { library.removeFavorites(seriesIDs: seriesIDs) }
    func selectLibraryOwner(_ owner: LibraryOwner) { library.selectOwner(owner) }
    func acceptAccountSession(_ session: AccountSession) { library.accept(session) }
    func synchronizeLibrary() async { await library.synchronize(userInitiated: true) }
    func resumeAccount() { library.scheduleSync(immediate: true) }
    func flushLibrary() async { await library.flush() }
    func signOut() { library.signOut() }
    func importGuestLibrary() { library.importGuest() }

    func setRecommendationCategory(_ category: DirectWebService.Category) {
        var next = recommendationPreferences; next.category = category
        saveRecommendationPreferences(next, changesFilter: true)
    }

    func setSkipsPreviewed(_ enabled: Bool) {
        var next = recommendationPreferences; next.skipsPreviewed = enabled
        saveRecommendationPreferences(next, changesFilter: true)
    }

    func setNotInterested(_ series: Series, value: Bool) {
        var next = recommendationPreferences
        do {
            try next.setNotInterested(seriesID: series.id, value: value)
            saveRecommendationPreferences(next, changesFilter: true)
        } catch { persistenceError = "無法更新這部劇的推薦偏好。" }
    }

    func markPreviewed(_ series: Series) {
        guard !recommendationPreferences.previewedIDs.contains(series.id) else { return }
        var next = recommendationPreferences
        do {
            try next.markPreviewed(seriesID: series.id)
            // Watching the current card never removes it from the live feed.
            saveRecommendationPreferences(next, changesFilter: false)
        } catch { /* A malformed external ID must not interrupt playback. */ }
    }

    func resetNotInterested() {
        var next = recommendationPreferences; next.clearNotInterested()
        saveRecommendationPreferences(next, changesFilter: true)
    }

    func resetPreviewed() {
        var next = recommendationPreferences; next.clearPreviewed()
        saveRecommendationPreferences(next, changesFilter: true)
    }

    private func saveRecommendationPreferences(_ preferences: RecommendationPreferences, changesFilter: Bool) {
        guard preferences != recommendationPreferences else { return }
        do {
            let data = try JSONEncoder().encode(preferences)
            defaults.set(data, forKey: "recommendationPreferences.v1")
            recommendationPreferences = preferences
            if changesFilter { recommendationFilterRevision = UUID() }
        } catch { persistenceError = "無法保存推薦偏好，原有設定已保留。" }
    }

    func rememberSearch(_ query: String) {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        searchHistory.removeAll { $0 == value }
        searchHistory.insert(value, at: 0)
        searchHistory = Array(searchHistory.prefix(12))
        defaults.set(searchHistory, forKey: "searchHistory")
    }

    func removeSearch(_ query: String) {
        searchHistory.removeAll { $0 == query }
        defaults.set(searchHistory, forKey: "searchHistory")
    }

    func clearSearchHistory() {
        searchHistory = []
        defaults.removeObject(forKey: "searchHistory")
    }

    private func restoreLibrary() {
        library.selectSource(libraryKey, legacy: defaults.data(forKey: libraryKey), allowsAccount: playbackMode == .native)
    }
}

private enum KeychainToken {
    static func read(account: String) -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "tw.mountainp.hongguo.bridge", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func save(_ token: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "tw.mountainp.hongguo.bridge", kSecAttrAccount as String: account]
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("無法更新服務口令。") }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AppError.message("無法將口令儲存到鑰匙圈。") }
        } else if status != errSecSuccess { throw AppError.message("無法更新鑰匙圈口令。") }
    }
}
