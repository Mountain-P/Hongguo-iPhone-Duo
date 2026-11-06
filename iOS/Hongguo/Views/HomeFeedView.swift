import SwiftUI
import HongguoCore
import Darwin

private struct FeedPlaybackRoute: Identifiable {
    let id = UUID()
    let detail: SeriesDetail
    let episode: Episode
    let seconds: Double
    let service: any CatalogService
    let onProgress: (Episode, Double, Double) -> Void
}

@MainActor
struct HomeFeedView: View {
    var isActive = true
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var catalogue = CatalogModel()
    @State private var category: DirectWebService.Category = .realDrama
    @State private var scrollTargetID: String?
    @State private var route: FeedPlaybackRoute?
    @State private var preparation: Task<Void, Never>?
    @State private var requestID = UUID()
    @State private var requestedSeriesID: String?
    @State private var preparingID: String?
    @State private var failure: String?
    @State private var failureSeriesID: String?
    @State private var lastLoadKey = ""
    @State private var activeTab = true

    private var loadKey: String { "\(model.revision):\(category.rawValue)" }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if catalogue.items.isEmpty {
                        emptyCatalogue
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], alignment: .leading, spacing: 12) {
                            ForEach(catalogue.items) { series in
                                gridCard(series).id(series.id)
                                    .onAppear { loadMoreIfNeeded(lastID: series.id) }
                            }
                        }
                        if let error = catalogue.error {
                            StatusCard(icon: "wifi.exclamationmark", title: "暫時無法載入", message: error,
                                       actionTitle: "再試一次", action: { Task { await load() } })
                        }
                        if catalogue.isLoading {
                            ProgressView("正在載入更多…").font(.caption).foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                        } else if catalogue.hasMore {
                            Button { Task { await load() } } label: {
                                Label("載入更多", systemImage: "arrow.down").font(.system(size: 13, weight: .medium))
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 9))
                            }.buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                        }
                    }
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 22)
            }
            .clipped()
            .scrollIndicators(.hidden)
            .allowsHitTesting(route == nil)
            .accessibilityHidden(route != nil)
            .refreshable { cancelPreparation(); await load(reset: true) }
            .onChange(of: scrollTargetID) { _, target in
                if let target { scroll.scrollTo(target, anchor: .top) }
            }
            .onAppear {
                if let target = scrollTargetID { scroll.scrollTo(target, anchor: .top) }
            }
        }
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.headerTint, Theme.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 270).frame(maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(edges: .top).allowsHitTesting(false)
        }
        .background(Theme.background)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { activeTab = isActive }
        .task(id: loadKey) {
            if isActive, lastLoadKey != loadKey || catalogue.items.isEmpty { await load(reset: true) }
        }
        .onChange(of: isActive) { _, active in
            activeTab = active
            if active {
                if lastLoadKey != loadKey || catalogue.items.isEmpty { Task { await load(reset: true) } }
            } else {
                cancelPreparation(); route = nil; model.isImmersivePlayback = false
            }
        }
        .onChange(of: model.revision) { _, _ in cancelPreparation(); route = nil }
        .onChange(of: route?.id) { _, _ in model.isImmersivePlayback = activeTab && route != nil }
        .onDisappear {
            // Presenting the player also hides this view. It must not cancel its own presentation.
            guard route == nil else { return }
            cancelPreparation(); model.isImmersivePlayback = false
        }
        .fullScreenCover(item: $route, onDismiss: {
            model.isImmersivePlayback = false
            trace("dismissed")
        }) { selection in
            PlayerScreen(series: selection.detail.series, episodes: selection.detail.episodes,
                         initialEpisodeID: selection.episode.id, resumeSeconds: selection.seconds,
                         service: selection.service, onProgress: selection.onProgress,
                         onClose: { route = nil }, onSeriesSwipe: browse)
                .id(selection.id)
                .onAppear { trace("presented") }
        }
    }

    private var emptyCatalogue: some View {
        Group {
            if catalogue.isLoading {
                ProgressView("正在發現好故事…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                StatusCard(icon: "film", title: "故事正在路上", message: catalogue.error ?? "稍後再試，或到劇場找找想看的片名。",
                           actionTitle: "重新整理", action: { Task { await load(reset: true) } })
                    .padding(20).frame(maxHeight: .infinity)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 20) {
            if model.catalogSource == .website {
                categoryButton("推薦", value: .realDrama)
                categoryButton("漫劇", value: .comicDrama)
                categoryButton("AI 短劇", value: .aiDrama)
            } else { Text("推薦").font(.headline) }
            Spacer(minLength: 0)
            NavigationLink { SearchView().toolbar(.visible, for: .navigationBar) } label: {
                Image(systemName: "magnifyingglass").font(.title3).frame(width: 44, height: 44)
            }.accessibilityLabel("搜尋劇集")
        }
        .foregroundStyle(.white)
        .padding(.vertical, 4)
    }

    private func categoryButton(_ title: String, value: DirectWebService.Category) -> some View {
        Button { cancelPreparation(); category = value } label: {
            VStack(spacing: 7) {
                Text(title).font(.subheadline.weight(category == value ? .bold : .regular))
                Capsule().fill(category == value ? Color.white : .clear).frame(width: 18, height: 3)
            }.padding(.top, 8).frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(category == value ? .white : .white.opacity(0.65))
    }

    private func gridCard(_ series: Series) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topTrailing) {
                NavigationLink(value: series) {
                    SeriesCard(series: series).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                favoriteButton(series).padding(6)
            }
            .clipped()
            .contentShape(Rectangle())
            if failureSeriesID == series.id, let failure, preparingID == nil {
                Text(failure).font(.system(size: 10)).foregroundStyle(Theme.muted)
                    .padding(.horizontal, 8).padding(.top, 3)
            }
            playbackButton(series).padding(8)
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
        .contentShape(Rectangle())
    }

    private func favoriteButton(_ series: Series) -> some View {
        Button { model.toggleFavorite(series) } label: {
            Image(systemName: model.isFavorite(series) ? "heart.fill" : "heart")
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
                .foregroundStyle(model.isFavorite(series) ? Theme.accent : .white)
                .shadow(color: .black.opacity(0.7), radius: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.isFavorite(series) ? "取消收藏" : "收藏劇集")
    }

    private func playbackButton(_ series: Series) -> some View {
        Button { start(series) } label: {
            HStack(spacing: 7) {
                if preparingID == series.id { ProgressView().tint(.white) }
                else { Image(systemName: "play.rectangle.fill") }
                Text(preparingID == series.id ? "正在準備…" : "開始觀看")
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.bold))
            }
            .padding(.horizontal, 10).padding(.vertical, 10)
            .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(preparingID != nil)
        .accessibilityLabel("開始觀看\(series.title)")
    }

    private func loadMoreIfNeeded(lastID: String?) {
        if lastID == catalogue.items.last?.id, catalogue.hasMore { Task { await load() } }
    }

    private func load(reset: Bool = false) async {
        let key = loadKey
        do {
            let service: any CatalogService = model.catalogSource == .website
                ? NativeCatalogService(category: category) : try model.catalogService()
            await catalogue.load(service: service, reset: reset)
            if !Task.isCancelled, key == loadKey {
                lastLoadKey = key
                if reset { scrollTargetID = nil }
            }
        } catch { catalogue.fail(error) }
    }

    private func cancelPreparation() {
        if preparation != nil || preparingID != nil { trace("cancelled") }
        requestID = UUID()
        preparation?.cancel(); preparation = nil
        requestedSeriesID = nil; preparingID = nil
        failure = nil; failureSeriesID = nil
    }

    private func browse(_ offset: Int) {
        let selected = route?.detail.series.id ?? requestedSeriesID
        cancelPreparation(); route = nil; model.isImmersivePlayback = false
        guard let selected, let index = catalogue.items.firstIndex(where: { $0.id == selected }) else { return }
        let target = index + offset
        guard catalogue.items.indices.contains(target) else { return }
        scrollTargetID = catalogue.items[target].id
    }

    private func start(_ series: Series) {
        guard isActive, activeTab, scenePhase == .active, preparingID == nil, route == nil else { return }
        cancelPreparation()
        let request = UUID(), revision = model.revision
        requestID = request; requestedSeriesID = series.id; preparingID = series.id
        trace("prepare_started")
        preparation = Task {
            defer {
                if requestID == request { preparingID = nil; requestedSeriesID = nil; preparation = nil }
            }
            do {
                let service = try model.playbackService()
                let detail: SeriesDetail
                if let bridge = service as? BridgeService { detail = try await bridge.verifiedDetail(id: series.id) }
                else { detail = try await service.detail(id: series.id) }
                try Task.checkCancellation()
                guard requestID == request, requestedSeriesID == series.id, model.revision == revision, activeTab else { return }
                trace("detail_ready")
                let record = model.record(for: series)
                guard let continuation = PlaybackContinuation.preferred(seriesID: detail.series.id, episodes: detail.episodes, record: record) else {
                    throw CatalogError.unavailablePlayback
                }
                route = FeedPlaybackRoute(detail: detail, episode: continuation.episode,
                    seconds: continuation.seconds, service: service,
                    onProgress: model.playbackProgressHandler(for: detail.series, episodes: detail.episodes))
            } catch is CancellationError {
                if requestID == request {
                    failure = "影片準備已取消，請再試一次。"; failureSeriesID = series.id
                    trace("cancelled")
                }
            } catch {
                if requestID == request, !Task.isCancelled {
                    failure = error.localizedDescription; failureSeriesID = series.id
                    trace("failed", error: error)
                }
            }
        }
    }

    private func trace(_ event: String, error: (any Error)? = nil) {
        #if DEBUG
        if let error {
            let value = error as NSError
            print("[Hongguo] home_playback=\(event) error_domain=\(value.domain) error_code=\(value.code)")
        } else { print("[Hongguo] home_playback=\(event)") }
        fflush(stdout)
        #endif
    }
}
