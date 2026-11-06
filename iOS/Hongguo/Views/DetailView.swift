import SwiftUI
import HongguoCore

private struct PlaybackRoute: Identifiable {
    let id = UUID()
    let detail: SeriesDetail
    let episode: Episode
    let seconds: Double
    let service: any CatalogService
    let onProgress: (Episode, Double, Double) -> Void
}

@MainActor
struct DetailView: View {
    let series: Series
    @EnvironmentObject private var model: AppModel
    @State private var detail: SeriesDetail?
    @State private var error: String?
    @State private var isLoading = false
    @State private var loadID = UUID()
    @State private var lastLoadedKey = ""
    @State private var route: PlaybackRoute?
    @State private var loadedService: (any CatalogService)?
    @State private var showingPlaybackSetup = false
    @State private var showingAllEpisodes = false
    @State private var showingAllRelated = false
    private var current: Series { detail?.series ?? series }
    private var discovery: SeriesDiscoveryMetadata? { detail?.discovery }
    private var loadKey: String { "\(series.id):\(model.revision.uuidString)" }
    private var related: [Series] {
        var seen: Set<String> = [series.id]
        return (discovery?.related ?? []).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if loadedService != nil, let start = startEpisode {
                    Button { play(start) } label: {
                        Label(startLabel(for: start), systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                if !model.isPlaybackConfigured {
                    StatusCard(icon: "play.rectangle", title: "設定播放服務後開始觀看",
                               message: "官網目錄可以用來找劇；App 會向播放服務確認完整分集與取源結果，不使用網頁預覽的集數限制。",
                               actionTitle: "設定播放服務", action: { showingPlaybackSetup = true })
                }
                if let discovery { sourceFacts(discovery) }
                if !current.description.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("故事簡介").font(.headline)
                        Text(current.description).font(.subheadline).foregroundStyle(Theme.muted).lineSpacing(6)
                    }
                }
                if let discovery, !discovery.artists.isEmpty { artistSection(discovery.artists) }
                if isLoading { ProgressView("正在載入劇集…").frame(maxWidth: .infinity).padding() }
                if let error {
                    StatusCard(icon: "exclamationmark.circle", title: "無法取得劇集", message: error,
                               actionTitle: "重新載入", action: { Task { await load() } })
                    if model.isPlaybackConfigured {
                        Button("播放設定") { showingPlaybackSetup = true }.buttonStyle(.bordered)
                    }
                }
                if let detail, loadedService != nil { episodeSection(detail) }
                if !related.isEmpty { relatedSection }
                if let url = URL(string: "https://hongguoduanju.com/player/\(series.id)") {
                    Link(destination: url) { Label("在紅果官網開啟", systemImage: "arrow.up.right.square").font(.subheadline) }
                        .padding(.top, 8)
                }
            }.padding(20)
        }
        .clipped()
        .background(Theme.background).navigationTitle("劇集詳情").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: loadKey) {
            if detail == nil || lastLoadedKey != loadKey { await load() }
        }
        .refreshable { await load() }
        .sheet(isPresented: $showingPlaybackSetup) { NavigationStack { SettingsView(isSetupSheet: true) } }
        .fullScreenCover(item: $route) { item in
            PlayerScreen(series: item.detail.series, episodes: item.detail.episodes, initialEpisodeID: item.episode.id,
                         resumeSeconds: item.seconds, service: item.service, onProgress: item.onProgress)
        }
    }

    private var hero: some View {
        HStack(alignment: .top, spacing: 20) {
            Poster(series: current, contentMode: .fit)
                .frame(width: 115, height: 164).clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 12) {
                Text(current.title).font(.title2.weight(.bold))
                if !current.badge.isEmpty { Text(current.badge).font(.caption).foregroundStyle(Theme.accent) }
                if !current.tags.isEmpty {
                    Text(current.tags.joined(separator: " · ")).font(.caption).foregroundStyle(Theme.muted)
                }
                if let detail { Text("共 \(detail.episodes.count) 集").font(.caption).foregroundStyle(Theme.muted) }
                Button { model.toggleFavorite(current) } label: {
                    Label(model.isFavorite(current) ? "已收藏" : "加入收藏", systemImage: model.isFavorite(current) ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                }.buttonStyle(.bordered).controlSize(.large)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func sourceFacts(_ metadata: SeriesDiscoveryMetadata) -> some View {
        if ![metadata.ratingText, metadata.heatText, metadata.likeText, metadata.favoriteText, metadata.releaseText].allSatisfy({ $0.isEmpty }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("作品資訊").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 135), spacing: 12)], alignment: .leading, spacing: 10) {
                    if !metadata.ratingText.isEmpty { fact("評分 \(metadata.ratingText)", symbol: "star") }
                    if !metadata.heatText.isEmpty { fact(metadata.heatText, symbol: "flame") }
                    if !metadata.likeText.isEmpty { fact("喜歡 \(metadata.likeText)", symbol: "hand.thumbsup") }
                    if !metadata.favoriteText.isEmpty { fact("收藏數 \(metadata.favoriteText)", symbol: "bookmark") }
                    if !metadata.releaseText.isEmpty { fact("上架 \(metadata.releaseText)", symbol: "calendar") }
                }
            }
        }
    }

    private func fact(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
    }

    private func artistSection(_ artists: [Artist]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("演員與角色").font(.headline)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(artists) { artist in
                        NavigationLink {
                            ArtistProfileView(artist: artist).toolbar(.visible, for: .navigationBar)
                        } label: {
                            VStack(spacing: 7) {
                                ArtistAvatar(artist: artist, size: 64)
                                Text(artist.name).font(.system(size: 14, weight: .medium)).foregroundStyle(.white).lineLimit(1)
                                if !artist.role.isEmpty {
                                    Text(artist.role).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(2)
                                }
                            }
                            .frame(width: 100, alignment: .top)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).contentShape(Rectangle())
                        .accessibilityLabel("\(artist.name)，\(artist.role)，查看參演作品")
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 144, alignment: .top)
            .clipped().scrollIndicators(.hidden)
        }
    }

    private func episodeSection(_ detail: SeriesDetail) -> some View {
        let episodes = showingAllEpisodes ? detail.episodes : Array(detail.episodes.prefix(12))
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("選集").font(.title3.weight(.bold))
                Spacer()
                Text("\(detail.episodes.count) 集").font(.caption2).foregroundStyle(Theme.muted)
            }
            if detail.episodes.isEmpty { Text("來源尚未提供分集資料。").font(.subheadline).foregroundStyle(Theme.muted) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 10)], spacing: 10) {
                ForEach(episodes) { episode in
                    Button { play(episode) } label: {
                        VStack(spacing: 4) {
                            Text("\(episode.number)").font(.subheadline.weight(.semibold))
                            if !episode.isAvailable { Image(systemName: "lock.fill").font(.system(size: 8)) }
                        }
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .background(model.record(for: current)?.episode.id == episode.id ? Theme.accent.opacity(0.2) : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!episode.isAvailable)
                    .foregroundStyle(episode.isAvailable ? .white : Theme.muted)
                    .accessibilityLabel("第 \(episode.number) 集\(episode.isAvailable ? "" : "，服務未開放")")
                }
            }
            if detail.episodes.count > 12 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showingAllEpisodes.toggle() }
                } label: {
                    Label(showingAllEpisodes ? "收合選集" : "展開全部 \(detail.episodes.count) 集",
                          systemImage: showingAllEpisodes ? "chevron.up" : "chevron.down")
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 42)
                }.buttonStyle(.bordered)
            }
        }
    }

    private var relatedSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("相似推薦").font(.title3.weight(.bold))
            DetailSeriesGrid(items: showingAllRelated ? related : Array(related.prefix(6)))
            if related.count > 6 {
                Button(showingAllRelated ? "收合推薦" : "查看全部 \(related.count) 部相似作品") {
                    showingAllRelated.toggle()
                }
                .font(.subheadline).buttonStyle(.bordered).frame(maxWidth: .infinity)
            }
        }
    }

    private var startEpisode: Episode? {
        guard let detail else { return nil }
        return PlaybackContinuation.preferred(seriesID: detail.series.id, episodes: detail.episodes,
                                              record: model.record(for: current))?.episode
    }

    private func startLabel(for episode: Episode) -> String {
        guard let record = model.record(for: current) else { return "開始觀看" }
        if record.isEpisodeCompleted && record.episode.id == episode.id { return "重新觀看 · 第 \(episode.number) 集" }
        return "接著看 · 第 \(episode.number) 集"
    }

    private func load() async {
        let request = UUID()
        let key = loadKey
        loadID = request
        route = nil; loadedService = nil; detail = nil
        isLoading = true; error = nil
        defer { if request == loadID { isLoading = false } }
        do {
            if model.isPlaybackConfigured {
                let service = try model.playbackService()
                let result: SeriesDetail
                if let bridge = service as? BridgeService { result = try await bridge.verifiedDetail(id: series.id) }
                else { result = try await service.detail(id: series.id) }
                try Task.checkCancellation()
                guard request == loadID, key == loadKey else { return }
                loadedService = service; detail = result; lastLoadedKey = key
            } else {
                let result = try await DirectWebService().detail(id: series.id)
                try Task.checkCancellation()
                guard request == loadID, key == loadKey else { return }
                detail = result; lastLoadedKey = key
            }
        } catch {
            if request == loadID, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    private func play(_ episode: Episode) {
        guard let detail, let service = loadedService, episode.isAvailable else { return }
        let record = model.record(for: detail.series)
        guard let continuation = PlaybackContinuation.selected(seriesID: detail.series.id, episode: episode, record: record) else { return }
        route = PlaybackRoute(detail: detail, episode: continuation.episode,
                              seconds: continuation.seconds,
                              service: service, onProgress: model.playbackProgressHandler(for: detail.series, episodes: detail.episodes))
    }
}

/// Nested detail destinations stay on the current native navigation stack rather
/// than resolving a value-based route through the root tab's destination registry.
@MainActor
private struct DetailSeriesGrid: View {
    let items: [Series]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], alignment: .leading, spacing: 12) {
            ForEach(items) { work in
                NavigationLink {
                    DetailView(series: work).toolbar(.visible, for: .navigationBar)
                } label: {
                    SeriesCard(series: work).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
    }
}

@MainActor
private struct ArtistAvatar: View {
    let artist: Artist
    let size: CGFloat

    var body: some View {
        ZStack {
            Theme.surface
            Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(Theme.muted)
            if let url = URL(string: artist.avatar), url.scheme?.lowercased() == "https" {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill().frame(width: size, height: size)
                        .clipped().contentShape(Circle())
                } placeholder: { Color.clear }
            }
        }
        .frame(width: size, height: size).clipShape(Circle()).contentShape(Circle())
        .allowsHitTesting(false).accessibilityHidden(true)
    }
}

@MainActor
private struct ArtistProfileView: View {
    let artist: Artist
    @StateObject private var model = ArtistProfileModel()
    private var current: Artist { model.profile?.artist ?? artist }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    ArtistAvatar(artist: current, size: 80)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(current.name).font(.title2.weight(.bold))
                        if !current.role.isEmpty { Text(current.role).font(.subheadline).foregroundStyle(Theme.muted) }
                    }
                }
                if let profile = model.profile {
                    if !profile.biography.isEmpty {
                        Text(profile.biography).font(.subheadline).foregroundStyle(Theme.muted).lineSpacing(6)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("目前公開參演作品").font(.headline)
                            Spacer()
                            Text("\(profile.works.count) 部").font(.caption).foregroundStyle(Theme.muted)
                        }
                        Text("以下為來源目前公開的作品，未必涵蓋完整履歷。")
                            .font(.caption).foregroundStyle(Theme.muted)
                    }
                    if profile.works.isEmpty {
                        StatusCard(icon: "film", title: "目前沒有公開作品", message: "來源尚未提供這位藝人的公開參演片單。")
                    } else { DetailSeriesGrid(items: profile.works) }
                }
                if model.isLoading { ProgressView("正在載入藝人資料…").frame(maxWidth: .infinity).padding() }
                if let error = model.error {
                    StatusCard(icon: "exclamationmark.circle", title: "暫時無法載入藝人資料", message: error,
                               actionTitle: "重新載入", action: { Task { await model.load(id: artist.id) } })
                }
            }.padding(20)
        }
        .clipped().background(Theme.background).foregroundStyle(.white)
        .navigationTitle(current.name).navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: artist.id) {
            if model.profile == nil { await model.load(id: artist.id) }
        }
        .refreshable { await model.load(id: artist.id) }
        .onDisappear { model.cancel() }
    }
}

@MainActor
private final class ArtistProfileModel: ObservableObject {
    @Published private(set) var profile: ArtistProfile?
    @Published private(set) var error: String?
    @Published private(set) var isLoading = false
    private var generation = UUID()
    private var currentID: String?
    private var operation: Task<ArtistProfile, any Error>?
    private let service = ArtistDiscoveryService()

    func load(id: String) async {
        cancel()
        let request = generation
        if currentID != id { profile = nil }
        currentID = id
        isLoading = true; error = nil
        let service = self.service
        let task = Task { try await service.artist(id: id) }
        operation = task
        defer { if generation == request { isLoading = false; operation = nil } }
        do {
            let result = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard request == generation, result.artist.id == id else { return }
            profile = result
        } catch is CancellationError {
            return
        } catch {
            if generation == request, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func cancel() {
        generation = UUID()
        operation?.cancel(); operation = nil; isLoading = false
    }
}
