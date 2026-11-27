import SwiftUI
import HongguoCore

@MainActor
private struct PlaybackRoute: Identifiable {
    let id = UUID()
    let detail: SeriesDetail
    let episode: Episode
    let seconds: Double
    let service: any CatalogService
    let onProgress: (Episode, Double, Double) -> Void
    let session = PlaybackRouteSession()
}

private struct DownloadSelection: Identifiable {
    let detail: SeriesDetail
    var id: String { detail.series.id }
}

@MainActor
struct DetailView: View {
    let series: Series
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var downloads: OfflineDownloadModel
    @State private var detail: SeriesDetail?
    @State private var error: String?
    @State private var refreshFailed = false
    @State private var isLoading = false
    @State private var loadID = UUID()
    @State private var lastLoadedKey = ""
    @State private var route: PlaybackRoute?
    @State private var openingDownload = false
    @State private var downloadError: String?
    @State private var loadedService: (any CatalogService)?
    @State private var showingPlaybackSetup = false
    @State private var downloadSelection: DownloadSelection?
    @State private var episodeIndex: EpisodeSelection?
    @State private var selectedEpisodeGroupID: Int?
    @State private var locatedEpisodeID: String?
    @State private var episodeJumpText = ""
    @State private var episodeJumpMessage: String?
    @State private var locationTask: Task<Void, Never>?
    @FocusState private var episodeJumpFocused: Bool
    @ScaledMetric(relativeTo: .body) private var episodeMinimumWidth: CGFloat = 58
    @ScaledMetric(relativeTo: .body) private var episodeMinimumHeight: CGFloat = 46
    @State private var showingAllRelated = false
    private var hasCurrentSnapshot: Bool { detail != nil && lastLoadedKey == loadKey }
    private var current: Series { hasCurrentSnapshot ? detail?.series ?? series : series }
    private var discovery: SeriesDiscoveryMetadata? { hasCurrentSnapshot ? detail?.discovery : nil }
    private var loadKey: String { "\(series.id):\(model.revision.uuidString):\(model.downloads.scope)" }
    private var offlineStart: OfflineDownloadItem? {
        guard loadedService?.usesHongguoWebsiteCatalog ?? (model.catalogSource == .website) else { return nil }
        return OfflineDownloadItem.nextToWatch(in: downloads.items.filter {
            $0.key.scope == downloads.scope && $0.key.seriesID == series.id
        })
    }
    private var related: [Series] {
        var seen: Set<String> = [series.id]
        return (discovery?.related ?? []).filter { seen.insert($0.id).inserted }
    }

    var body: some View {
        ScrollViewReader { scroll in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                hero
                if hasCurrentSnapshot, loadedService != nil, let start = startEpisode {
                    Button { play(start) } label: {
                        Label(startLabel(for: start), systemImage: "play.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                if hasCurrentSnapshot, let detail, let entries = detail.websiteEpisodes,
                   usesOfficialCatalog {
                    websiteEpisodes(entries, detail: detail)
                }
                if let item = offlineStart {
                    Button {
                        Task { await playDownloaded(item) }
                    } label: {
                        Label(item.canResumeOffline ? "續看已下載的第 \(item.episodeNumber) 集" : "播放已下載的第 \(item.episodeNumber) 集",
                              systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.bordered).disabled(openingDownload)
                    .accessibilityIdentifier("detail.playDownloaded")
                    if let downloadError { Text(downloadError).font(.footnote).foregroundStyle(Theme.muted) }
                }
                if !model.isPlaybackConfigured, model.catalogSource == .bridge {
                    StatusCard(icon: "play.rectangle", title: "設定自訂播放服務",
                               message: "輸入你的服務網址，即可取得該服務提供的劇集。",
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
                    StatusCard(icon: "exclamationmark.circle", title: refreshFailed && hasCurrentSnapshot ? "更新未完成，顯示上次資料" : "無法取得劇集", message: error,
                               actionTitle: "重新載入", action: { Task { await load() } })
                    if model.isPlaybackConfigured {
                        Button("播放設定") { showingPlaybackSetup = true }.buttonStyle(.bordered)
                    }
                }
                if let detail, hasCurrentSnapshot, loadedService != nil, detail.episodes.contains(where: \.isAvailable) {
                    episodeSection(detail, scroll: scroll)
                }
                if !related.isEmpty { relatedSection }
                if usesOfficialCatalog, detail?.websiteEpisodes == nil,
                   let url = WebsiteEpisode.seriesURL(seriesID: series.id) {
                    Link(destination: url) { Label("在紅果官網開啟劇頁", systemImage: "arrow.up.right.square").font(.subheadline) }
                }
            }.padding(20)
        }
        .clipped()
        .background(Theme.background).navigationTitle("劇集詳情").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await load() } } label: {
                    Label("更新劇集", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)
                .accessibilityHint("更新分集資料；更新失敗時保留目前可用的資料")
                .accessibilityIdentifier("detail.refresh")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { episodeJumpFocused = false }
            }
        }
        .task(id: loadKey) {
            if detail == nil || lastLoadedKey != loadKey { await load() }
        }
        .refreshable { await load() }
        .onDisappear { locationTask?.cancel(); locationTask = nil }
        .sheet(isPresented: $showingPlaybackSetup) { NavigationStack { SettingsView(isSetupSheet: true) } }
        .sheet(item: $downloadSelection) { selection in
            OfflineEpisodeSelectionView(detail: selection.detail)
        }
        .fullScreenCover(item: Binding(get: { route }, set: { if $0 == nil { dismissPlayback() } })) { item in
            if let retained = item.session.resolve(make: {
                PlayerScreen.makeModel(series: item.detail.series, episodes: item.detail.episodes,
                    initialEpisodeID: item.episode.id, resumeSeconds: item.seconds, service: item.service,
                    onProgress: item.onProgress, isPreview: false, handoff: nil, context: nil, sceneActive: true)
            }) {
                PlayerScreen(series: item.detail.series, episodes: item.detail.episodes, initialEpisodeID: item.episode.id,
                             resumeSeconds: item.seconds, service: item.service, onProgress: item.onProgress,
                             onClose: dismissPlayback, retainedModel: retained, session: item.session)
                    .id(item.id)
            }
        }
        }
    }

    private func dismissPlayback() {
        route?.session.dispose()
        route = nil
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
                if let detail, hasCurrentSnapshot, detail.websiteEpisodes == nil, !detail.episodes.isEmpty {
                    Text("已列出 \(detail.episodes.count) 集").font(.caption).foregroundStyle(Theme.muted)
                }
                Button {
                    guard hasCurrentSnapshot else { return }
                    model.toggleFavorite(current)
                } label: {
                    Label(model.isFavorite(current) ? "已收藏" : "加入收藏", systemImage: model.isFavorite(current) ? "heart.fill" : "heart")
                        .font(.subheadline.weight(.semibold))
                }.buttonStyle(.bordered).controlSize(.large)
                    .disabled(!hasCurrentSnapshot)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var usesOfficialCatalog: Bool {
        if let loadedService { return loadedService.usesHongguoWebsiteCatalog }
        return model.catalogSource == .website && !model.isPlaybackConfigured && hasCurrentSnapshot
    }

    private func websiteEpisodes(_ entries: [WebsiteEpisode], detail: SeriesDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("官網選集", systemImage: "safari").font(.headline)
            let availability = entries.isEmpty ? "官網目前沒有公開分集連結" : "官網目前列出 \(entries.count) 集"
            Text(detail.reportedEpisodeCount.map { "全劇 \($0) 集，\(availability)" } ?? availability)
                .font(.subheadline).foregroundStyle(Theme.muted)
            if entries.isEmpty, let url = WebsiteEpisode.seriesURL(seriesID: detail.series.id) {
                Link(destination: url) { Label("在紅果官網開啟劇頁", systemImage: "arrow.up.right.square") }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 10)], alignment: .leading, spacing: 10) {
                ForEach(entries, id: \.number) { entry in
                    if let url = entry.url(seriesID: detail.series.id) {
                        Link(destination: url) {
                            Label("第 \(entry.number) 集", systemImage: "arrow.up.right")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityLabel("在紅果官網開啟第 \(entry.number) 集")
                        .accessibilityIdentifier("detail.websiteEpisode.\(entry.number)")
                    }
                }
            }
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

    private func episodeSection(_ detail: SeriesDetail, scroll: ScrollViewProxy) -> some View {
        let index = episodeIndex
        let selectedGroup = index?.groups.first { $0.id == selectedEpisodeGroupID } ?? index?.groups.first
        let episodes = selectedGroup?.episodes ?? detail.episodes
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("選集").font(.title3.weight(.bold))
                Spacer()
                Text("\(detail.episodes.count) 集").font(.caption2).foregroundStyle(Theme.muted)
            }
            if loadedService is NativeCatalogService, detail.episodes.contains(where: \.isAvailable) {
                Button { downloadSelection = DownloadSelection(detail: detail) } label: {
                    Label("選集下載", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("detail.downloadEpisodes")
            }
            if let index, !index.episodes.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                        episodeGroupPicker(index)
                        Spacer(minLength: 8)
                        locateLastButton(index, scroll: scroll)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        episodeGroupPicker(index)
                        locateLastButton(index, scroll: scroll)
                    }
                }
                HStack(spacing: 12) {
                    TextField("輸入集數", text: $episodeJumpText)
                        .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                        .focused($episodeJumpFocused)
                        .accessibilityLabel("要定位的集數")
                        .onSubmit { locateEnteredEpisode(index, scroll: scroll) }
                    Button("跳至") { locateEnteredEpisode(index, scroll: scroll) }
                        .buttonStyle(.bordered).controlSize(.large)
                        .disabled(episodeJumpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let episodeJumpMessage {
                    Text(episodeJumpMessage).font(.caption).foregroundStyle(Theme.muted)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: episodeMinimumWidth), spacing: 10)], spacing: 10) {
                ForEach(episodes) { episode in
                    Button { play(episode) } label: {
                        VStack(spacing: 4) {
                            Text("\(episode.number)").font(.subheadline.weight(.semibold))
                            if !episode.isAvailable { Image(systemName: "lock.fill").font(.system(size: 8)) }
                        }
                        .frame(maxWidth: .infinity, minHeight: episodeMinimumHeight)
                        .background(model.record(for: current)?.episode.id == episode.id ? Theme.accent.opacity(0.2) : Theme.surface,
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(locatedEpisodeID == episode.id ? Theme.accent : .clear, lineWidth: 2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(!episode.isAvailable)
                    .foregroundStyle(episode.isAvailable ? .white : Theme.muted)
                    .accessibilityLabel("第 \(episode.number) 集\(episode.isAvailable ? "" : "，服務未開放")")
                    .accessibilityValue(locatedEpisodeID == episode.id ? "已定位" : "")
                    .id("episode-\(episode.id)")
                }
            }
        }
    }

    private func episodeGroupPicker(_ index: EpisodeSelection) -> some View {
        Picker("集數範圍", selection: Binding(
            get: { selectedEpisodeGroupID ?? index.groups.first?.id ?? 1 },
            set: {
                locationTask?.cancel(); locationTask = nil
                selectedEpisodeGroupID = $0; locatedEpisodeID = nil; episodeJumpMessage = nil
            }
        )) {
            ForEach(index.groups) { group in
                Text(group.start == group.end ? "第 \(group.start) 集" : "\(group.start)–\(group.end) 集").tag(group.id)
            }
        }
        .pickerStyle(.menu).tint(Theme.accent)
        .accessibilityHint("切換顯示的分集範圍，不會開始播放")
    }

    private func locateLastButton(_ index: EpisodeSelection, scroll: ScrollViewProxy) -> some View {
        let episode = index.resumeEpisode(record: model.record(for: current))
        return Button {
            if let episode { locate(episode, in: index, scroll: scroll) }
        } label: {
            Label(episode.map { "上次第 \($0.number) 集" } ?? "定位上次", systemImage: "scope")
                .font(.subheadline)
        }
        .buttonStyle(.bordered).disabled(episode == nil)
        .accessibilityHint("定位上次觀看的分集，不會開始播放")
    }

    private func locateEnteredEpisode(_ index: EpisodeSelection, scroll: ScrollViewProxy) {
        do { locate(try index.resolve(numberText: episodeJumpText), in: index, scroll: scroll) }
        catch { episodeJumpMessage = error.localizedDescription }
    }

    private func locate(_ episode: Episode, in index: EpisodeSelection, scroll: ScrollViewProxy) {
        guard hasCurrentSnapshot, index.seriesID == detail?.series.id, let group = index.group(containing: episode.id) else { return }
        locationTask?.cancel()
        selectedEpisodeGroupID = group.id; locatedEpisodeID = episode.id
        episodeJumpText = "\(episode.number)"; episodeJumpFocused = false
        episodeJumpMessage = episode.isAvailable ? "已定位第 \(episode.number) 集，點分集即可觀看。" : "第 \(episode.number) 集尚未開放。"
        let request = loadID
        locationTask = Task { @MainActor in
            // Let the newly selected group's cells enter the scroll view first.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, hasCurrentSnapshot, request == loadID, locatedEpisodeID == episode.id,
                  detail?.series.id == index.seriesID else { return }
            withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo("episode-\(episode.id)", anchor: .center) }
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
        guard !Task.isCancelled else { return }
        let request = UUID()
        let key = loadKey
        let keepSnapshot = hasCurrentSnapshot
        loadID = request
        locationTask?.cancel(); locationTask = nil
        episodeJumpFocused = false
        if !keepSnapshot {
            downloadError = nil
            episodeIndex = nil; selectedEpisodeGroupID = nil; locatedEpisodeID = nil
            episodeJumpText = ""; episodeJumpMessage = nil
            dismissPlayback(); loadedService = nil; detail = nil
        }
        isLoading = true; error = nil; refreshFailed = false
        defer { if request == loadID { isLoading = false } }
        do {
            if model.isPlaybackConfigured {
                let service = try model.playbackService()
                let result: SeriesDetail
                if let bridge = service as? BridgeService { result = try await bridge.verifiedDetail(id: series.id) }
                else {
                    do { result = try await service.detail(id: series.id) }
                    catch {
                        try Task.checkCancellation()
                        guard !keepSnapshot, PlaybackRecovery.shouldRetry(error, attempt: 0),
                              let saved = await service.offlinePlayback?.fallbackDetail(seriesID: series.id) else { throw error }
                        result = saved
                    }
                }
                try Task.checkCancellation()
                guard request == loadID, key == loadKey else { return }
                loadedService = service; detail = result; lastLoadedKey = key
                updateEpisodeIndex(result)
            } else {
                let result = try await DirectWebService().detail(id: series.id)
                try Task.checkCancellation()
                guard request == loadID, key == loadKey else { return }
                detail = result; lastLoadedKey = key
                updateEpisodeIndex(result)
            }
        } catch {
            if request == loadID, key == loadKey, !Task.isCancelled {
                self.error = error.localizedDescription
                refreshFailed = keepSnapshot
            }
        }
    }

    private func updateEpisodeIndex(_ result: SeriesDetail) {
        episodeIndex = try? EpisodeSelection(seriesID: result.series.id, episodes: result.episodes)
        if let selectedEpisodeGroupID, episodeIndex?.groups.contains(where: { $0.id == selectedEpisodeGroupID }) != true {
            self.selectedEpisodeGroupID = nil
        }
        if let locatedEpisodeID, episodeIndex?.group(containing: locatedEpisodeID) == nil {
            self.locatedEpisodeID = nil; episodeJumpMessage = nil
        }
    }

    private func playDownloaded(_ item: OfflineDownloadItem) async {
        guard !openingDownload else { return }
        let key = loadKey
        openingDownload = true
        downloadError = nil
        defer { openingDownload = false }
        let saved = await downloads.playback(item, continuingSeries: true)
        guard key == loadKey, route == nil else { return }
        guard let saved, let episode = saved.detail.episodes.first(where: { $0.id == saved.episodeID }) else {
            downloadError = downloads.error ?? "無法開啟這一集的離線檔案。"
            return
        }
        let updateHistory = model.playbackProgressHandler(for: current)
        route = PlaybackRoute(detail: saved.detail, episode: episode, seconds: saved.resume, service: saved.service) {
            episode, seconds, duration in
            saved.onProgress(episode, seconds, duration)
            updateHistory(episode, seconds, duration)
        }
    }

    private func play(_ episode: Episode) {
        guard hasCurrentSnapshot, let detail, let service = loadedService, episode.isAvailable else { return }
        let record = model.record(for: detail.series)
        guard let continuation = PlaybackContinuation.selected(seriesID: detail.series.id, episode: episode, record: record) else { return }
        dismissPlayback()
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
