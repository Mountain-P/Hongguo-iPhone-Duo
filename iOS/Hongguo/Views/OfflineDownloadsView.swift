import SwiftUI
import HongguoCore

@MainActor
final class OfflineDownloadModel: ObservableObject {
    static let scope = "native.public.v1"

    @Published private(set) var items: [OfflineDownloadItem] = []
    @Published private(set) var isReady = false
    @Published private(set) var storageUnavailable = false
    @Published var error: String?

    private var storage: OfflineDownloads?
    private var observation: Task<Void, Never>?
    private var progressWrite: Task<Void, Never>?
    private let openStorage: @Sendable () throws -> OfflineDownloads

    init(openStorage: @escaping @Sendable () throws -> OfflineDownloads = {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            .appendingPathComponent("OfflineEpisodes.v1", isDirectory: true)
        return try OfflineDownloads(directory: directory) { item, destination, maximumBytes, progress in
            try await NativeCatalogService().downloadOffline(seriesID: item.key.seriesID, episodeID: item.key.episodeID,
                to: destination, maximumBytes: maximumBytes, progress: progress)
        }
    }) {
        self.openStorage = openStorage
    }

    deinit { observation?.cancel() }

    func startObserving() {
        guard observation == nil else { return }
        if storageUnavailable { error = nil }
        storageUnavailable = false
        let openStorage = self.openStorage
        let existing = storage
        observation = Task { [weak self] in
            defer { self?.observation = nil }
            do {
                let library: OfflineDownloads
                if let existing { library = existing }
                else {
                    library = try await Task.detached(priority: .utility) { try openStorage() }.value
                    self?.storage = library
                }
                let updates = await library.updates()
                await library.start()
                for await current in updates {
                    self?.items = current.filter { $0.key.scope == Self.scope }
                    self?.isReady = true
                }
            } catch {
                self?.storageUnavailable = true
                self?.error = "暫時無法開啟離線片庫。請解鎖裝置，或確認儲存空間後再試。"
            }
        }
    }

    func item(seriesID: String, episodeID: String) -> OfflineDownloadItem? {
        items.first { $0.key.seriesID == seriesID && $0.key.episodeID == episodeID }
    }

    func enqueue(series: Series, episodes: [Episode]) async -> Bool {
        guard let storage else { return false }
        do {
            let entries = episodes.filter(\.isAvailable).map { episode in
                let key = OfflineDownloadKey(scope: Self.scope, seriesID: series.id, episodeID: episode.id)
                return OfflineDownloadItem(key: key, seriesTitle: series.title, episodeNumber: episode.number,
                                           episodeTitle: episode.title)
            }
            try await storage.enqueue(entries)
            return true
        } catch {
            report(error)
            return false
        }
    }

    func cancel(_ key: OfflineDownloadKey) async {
        do { try await storage?.cancel(key) }
        catch { report(error) }
    }

    func retry(_ key: OfflineDownloadKey) async {
        do { try await storage?.retry(key) }
        catch { report(error) }
    }

    func delete(_ key: OfflineDownloadKey) async {
        do { try await storage?.delete(key) }
        catch { report(error) }
    }

    func playback(_ item: OfflineDownloadItem) async -> OfflinePlaybackRoute? {
        guard let storage else { return nil }
        // Wait for the last progress write when reopening immediately after close.
        await progressWrite?.value
        let snapshot = await storage.snapshot()
        let saved = snapshot.filter {
            $0.key.seriesID == item.key.seriesID && $0.key.scope == item.key.scope && $0.state == .completed
        }
        guard let selected = saved.first(where: { $0.key == item.key }) else {
            error = "這一集的離線檔案無法播放，請重新下載。"
            return nil
        }
        let episodes = saved.sorted {
            ($0.episodeNumber, $0.key.episodeID) < ($1.episodeNumber, $1.key.episodeID)
        }.map { Episode(id: $0.key.episodeID, number: $0.episodeNumber, title: $0.episodeTitle) }
        let detail = SeriesDetail(series: .init(id: item.key.seriesID, title: item.seriesTitle), episodes: episodes)
        let resume = selected.duration > 0 && selected.position >= selected.duration - 0.25 ? 0 : selected.position
        return OfflinePlaybackRoute(detail: detail, episodeID: item.key.episodeID, resume: resume,
            service: OfflinePlaybackService(detail: detail, scope: item.key.scope, storage: storage)) {
                [weak self] episode, position, duration in
                self?.recordProgress(seriesID: item.key.seriesID, episodeID: episode.id, position: position, duration: duration)
            }
    }

    private func recordProgress(seriesID: String, episodeID: String, position: Double, duration: Double) {
        guard let storage else { return }
        let key = OfflineDownloadKey(scope: Self.scope, seriesID: seriesID, episodeID: episodeID)
        let previous = progressWrite
        progressWrite = Task { [weak self] in
            await previous?.value
            do { try await storage.recordProgress(for: key, position: position, duration: duration) }
            catch { self?.report(error) }
        }
    }

    private func report(_ failure: Error) {
        error = (failure as? LocalizedError)?.errorDescription ?? "離線操作失敗，請確認裝置的儲存空間後重試。"
    }
}

struct OfflinePlaybackService: CatalogService {
    let detail: SeriesDetail
    let scope: String
    let storage: OfflineDownloads

    func home(page: Int) async throws -> SeriesPage { .init(items: [], page: page, hasMore: false) }
    func search(query: String, page: Int) async throws -> SeriesPage { try await home(page: page) }
    func detail(id: String) async throws -> SeriesDetail {
        guard id == detail.series.id else { throw CatalogError.invalidID }
        return detail
    }

    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        guard seriesID == detail.series.id, detail.episodes.contains(where: { $0.id == episodeID }) else {
            throw CatalogError.invalidID
        }
        let key = OfflineDownloadKey(scope: scope, seriesID: seriesID, episodeID: episodeID)
        guard let url = try await storage.localURL(for: key) else { throw OfflinePlaybackError.missingFile }
        return .init(url: url)
    }
}

private enum OfflinePlaybackError: LocalizedError {
    case missingFile
    var errorDescription: String? { "這一集的離線檔案無法播放，請重新下載。" }
}

@MainActor
struct OfflinePlaybackRoute: Identifiable {
    let id = UUID()
    let detail: SeriesDetail
    let episodeID: String
    let resume: Double
    let service: OfflinePlaybackService
    let onProgress: (Episode, Double, Double) -> Void
    let session = PlaybackRouteSession()
}

@MainActor
struct OfflineEpisodeSelectionView: View {
    let detail: SeriesDetail
    @EnvironmentObject private var downloads: OfflineDownloadModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var submitting = false

    var body: some View {
        NavigationStack {
            List {
                if downloads.storageUnavailable {
                    Button("重新開啟離線片庫") { downloads.startObserving() }
                }
                Section {
                    ForEach(detail.episodes) { episode in
                        let item = downloads.item(seriesID: detail.series.id, episodeID: episode.id)
                        Button {
                            if selected.contains(episode.id) { selected.remove(episode.id) }
                            else { selected.insert(episode.id) }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(episodeLabel(episode.number, episode.title)).foregroundStyle(.primary)
                                    if let item { OfflineDownloadStatus(item: item) }
                                    else if !episode.isAvailable { Text("來源尚未開放").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if item == nil && episode.isAvailable {
                                    Image(systemName: selected.contains(episode.id) ? "checkmark.circle.fill" : "circle")
                                        .accessibilityHidden(true)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!downloads.isReady || submitting || item != nil || !episode.isAvailable)
                        .accessibilityAddTraits(selected.contains(episode.id) ? .isSelected : [])
                        .accessibilityIdentifier("offline.select.\(episode.id)")
                    }
                } header: {
                    Text(detail.series.title)
                } footer: {
                    Text("可下載來源提供的未加密影片。在「我的 → 離線下載」查看進度或管理已下載的集數。")
                }
            }
            .navigationTitle("選集下載")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(selected.isEmpty ? "下載" : "下載 \(selected.count) 集") {
                        let episodes = detail.episodes.filter { selected.contains($0.id) }
                        submitting = true
                        Task {
                            if await downloads.enqueue(series: detail.series, episodes: episodes) { dismiss() }
                            submitting = false
                        }
                    }
                    .disabled(selected.isEmpty || submitting || !downloads.isReady)
                    .accessibilityIdentifier("offline.enqueue")
                }
            }
            .alert("離線下載", isPresented: errorVisible) { Button("好") { downloads.error = nil } }
                message: { Text(downloads.error ?? "") }
        }
    }

    private var errorVisible: Binding<Bool> {
        Binding(get: { downloads.error != nil }, set: { if !$0 { downloads.error = nil } })
    }
}

@MainActor
struct OfflineDownloadsView: View {
    @EnvironmentObject private var downloads: OfflineDownloadModel
    @State private var route: OfflinePlaybackRoute?
    @State private var opening: OfflineDownloadKey?
    @State private var pendingDeletion: OfflineDownloadItem?

    var body: some View {
        List {
            if !downloads.isReady {
                if downloads.storageUnavailable {
                    Text(downloads.error ?? "離線片庫暫時無法開啟。")
                    Button("重新開啟離線片庫") { downloads.startObserving() }
                } else {
                    ProgressView("正在開啟離線片庫…")
                }
            } else if downloads.items.isEmpty {
                ContentUnavailableView("尚未下載劇集", systemImage: "arrow.down.circle",
                    description: Text("到劇集詳情選擇「選集下載」，即可在這裡離線觀看。"))
            }
            ForEach(groups, id: \.key) { group in
                Section(group.items.first?.seriesTitle ?? "") {
                    ForEach(group.items) { item in
                        row(item)
                    }
                }
            }
        }
        .navigationTitle("離線下載")
        .toolbar(.visible, for: .navigationBar)
        .fullScreenCover(item: Binding(get: { route }, set: { if $0 == nil { closePlayback() } })) { item in
            if let retained = item.session.resolve(make: {
                PlayerModel(series: item.detail.series, episodes: item.detail.episodes, initialEpisodeID: item.episodeID,
                            resumeSeconds: item.resume, service: item.service, onProgress: item.onProgress)
            }) {
                PlayerScreen(series: item.detail.series, episodes: item.detail.episodes, initialEpisodeID: item.episodeID,
                    resumeSeconds: item.resume, service: item.service, onProgress: item.onProgress, onClose: closePlayback,
                    retainedModel: retained, session: item.session)
                .id(item.id)
            }
        }
        .confirmationDialog("刪除離線下載？", isPresented: Binding(get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible, presenting: pendingDeletion) { item in
            Button("刪除", role: .destructive) { Task { await downloads.delete(item.key) } }
        } message: { item in
            Text("\(item.seriesTitle) · 第 \(item.episodeNumber) 集")
        }
        .alert("離線下載", isPresented: Binding(get: { downloads.isReady && downloads.error != nil },
            set: { if !$0 { downloads.error = nil } })) { Button("好") { downloads.error = nil } }
            message: { Text(downloads.error ?? "") }
    }

    private var groups: [(key: String, items: [OfflineDownloadItem])] {
        let grouped = Dictionary(grouping: downloads.items, by: \.key.seriesID)
        var seen = Set<String>()
        return downloads.items.map(\.key.seriesID).filter { seen.insert($0).inserted }.map { id in
            (id, grouped[id, default: []].sorted {
                ($0.episodeNumber, $0.key.episodeID) < ($1.episodeNumber, $1.key.episodeID)
            })
        }
    }

    private func row(_ item: OfflineDownloadItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(episodeLabel(item.episodeNumber, item.episodeTitle)).font(.headline)
            OfflineDownloadStatus(item: item)
            HStack(spacing: 12) {
                switch item.state {
                case .completed:
                    Button {
                        opening = item.key
                        Task {
                            route = await downloads.playback(item)
                            opening = nil
                        }
                    } label: {
                        Label(item.position > 0 && item.position < item.duration - 0.25 ? "繼續觀看" : "播放",
                              systemImage: "play.fill")
                    }
                    .disabled(opening != nil)
                    .accessibilityIdentifier("offline.play.\(item.key.episodeID)")
                    if opening == item.key { ProgressView() }
                case .queued, .downloading:
                    Button("取消") { Task { await downloads.cancel(item.key) } }
                        .accessibilityIdentifier("offline.cancel.\(item.key.episodeID)")
                case .failed, .cancelled:
                    Button("重試") { Task { await downloads.retry(item.key) } }
                        .accessibilityIdentifier("offline.retry.\(item.key.episodeID)")
                }
                if item.state != .queued && item.state != .downloading {
                    Button(role: .destructive) { pendingDeletion = item } label: {
                        Label("刪除", systemImage: "trash")
                    }
                    .accessibilityIdentifier("offline.delete.\(item.key.episodeID)")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func closePlayback() {
        route?.session.dispose()
        route = nil
    }
}

private struct OfflineDownloadStatus: View {
    let item: OfflineDownloadItem

    var body: some View {
        Group {
            switch item.state {
            case .queued: Text("等待下載")
            case .downloading:
                if let total = item.totalBytes, total > 0 {
                    let fraction = min(1, Double(item.receivedBytes) / Double(total))
                    ProgressView(value: fraction) {
                        Text(fraction == 1 ? "正在驗證影片…" : "下載中 · \(Int(fraction * 100))%")
                    }
                } else {
                    ProgressView(item.receivedBytes > 0 ? "下載中 · \(size)" : "正在取得來源…")
                }
            case .completed: Label("已下載 · \(size)", systemImage: "checkmark.circle.fill")
            case .failed: Text(item.failure ?? "下載失敗")
            case .cancelled: Text("已取消")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var size: String {
        ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
    }
}

private func episodeLabel(_ number: Int, _ title: String) -> String {
    let label = "第 \(number) 集"
    return title.isEmpty || title == label ? label : "\(label) · \(title)"
}
