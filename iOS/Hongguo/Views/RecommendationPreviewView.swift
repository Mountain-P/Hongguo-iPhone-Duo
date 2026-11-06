import SwiftUI
import HongguoCore

private struct RecommendationPreviewSelection: Identifiable {
    let id = UUID()
    let series: Series
    let episode: Episode
    let service: any CatalogService
}

private struct RecommendationPreviewPresentation: Identifiable { let id = UUID() }

@MainActor
struct RecommendationPreviewView: View {
    var isActive = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preview = RecommendationPreviewModel()
    @State private var presentation: RecommendationPreviewPresentation?
    @State private var pendingSeries: Series?
    @State private var detailSeries: Series?
    @State private var hasStarted = false

    private struct Activation: Hashable {
        let revision: UUID
        let active: Bool
    }

    var body: some View {
        let activation = Activation(revision: model.revision, active: isActive)
        return ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("先看第一集，再決定追哪部").font(.title2.weight(.bold))
                Text("從目前目錄逐部試看。上滑換下一部，喜歡時點「看整部」，進入詳情與選集。")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                if let series = preview.current {
                    HStack(alignment: .top, spacing: 18) {
                        Poster(series: series, contentMode: .fit)
                            .frame(width: 112, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 10)).allowsHitTesting(false)
                        VStack(alignment: .leading, spacing: 10) {
                            Text(series.title).font(.headline)
                            if !series.badge.isEmpty { Text(series.badge).font(.caption).foregroundStyle(Theme.muted) }
                            Text("第 1 集試看").font(.subheadline).foregroundStyle(Theme.accent)
                        }
                    }
                }
                Button(hasStarted ? "繼續試看" : "開始試看") { openPreview() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .frame(maxWidth: .infinity)
                if let error = preview.error {
                    Text(error).font(.footnote).foregroundStyle(Theme.muted)
                }
                Text("試看不寫入觀看紀錄，也不改變原有續播位置。每部只播放第 1 集，播完會暫停。")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            .padding(20)
        }
        .background(Theme.background).foregroundStyle(.white)
        .navigationTitle("推薦試看").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: activation) { activate(activation) }
        .onChange(of: isActive) { _, active in
            if !active { closePreview(); pendingSeries = nil }
        }
        .onChange(of: model.revision) { _, _ in
            closePreview(); pendingSeries = nil
            preview.invalidateSource()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, isActive, !hasStarted { openPreview() }
        }
        .onDisappear {
            guard presentation == nil else { return }
            preview.cancel()
            model.isImmersivePlayback = false
        }
        .navigationDestination(item: $detailSeries) { series in
            DetailView(series: series).toolbar(.visible, for: .navigationBar)
        }
        .fullScreenCover(item: $presentation, onDismiss: finishDismissal) { _ in
            RecommendationPreviewPlayer(preview: preview, onClose: closePreview, onOpenSeries: openEntireSeries)
        }
    }

    private func activate(_ activation: Activation) {
        guard !Task.isCancelled, activation.revision == model.revision, activation.active == isActive, isActive else { return }
        configureSource()
        if !hasStarted, scenePhase == .active { openPreview() }
    }

    private func configureSource() {
        guard preview.revision != model.revision else { return }
        do {
            preview.configure(revision: model.revision, catalogue: try model.catalogService(), playback: try model.playbackService())
        } catch { preview.configureFailure(error, revision: model.revision) }
    }

    private func openPreview() {
        guard isActive, scenePhase == .active, presentation == nil else { return }
        configureSource()
        hasStarted = true
        presentation = RecommendationPreviewPresentation()
        model.isImmersivePlayback = true
        preview.start()
    }

    private func closePreview() {
        preview.cancel()
        presentation = nil
        model.isImmersivePlayback = false
    }

    private func openEntireSeries(_ series: Series) {
        pendingSeries = series
        closePreview()
    }

    private func finishDismissal() {
        preview.cancel()
        model.isImmersivePlayback = false
        if let pendingSeries, isActive {
            self.pendingSeries = nil
            detailSeries = pendingSeries
        }
    }
}

@MainActor
private struct RecommendationPreviewPlayer: View {
    @ObservedObject var preview: RecommendationPreviewModel
    let onClose: () -> Void
    let onOpenSeries: (Series) -> Void

    var body: some View {
        Group {
            if let selection = preview.selection {
                PlayerScreen(series: selection.series, episodes: [selection.episode],
                             initialEpisodeID: selection.episode.id, resumeSeconds: 0,
                             service: selection.service, onProgress: { _, _, _ in },
                             onClose: onClose, onSeriesSwipe: { preview.move(by: $0) },
                             isPreview: true, onOpenSeries: { onOpenSeries(selection.series) })
                    .id(selection.id)
            } else {
                previewStatus
            }
        }
        .preferredColorScheme(.dark)
    }

    private var previewStatus: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                if let series = preview.current {
                    Poster(series: series, contentMode: .fit)
                        .frame(width: 140, height: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).allowsHitTesting(false)
                    Text(series.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                }
                if preview.isLoading {
                    ProgressView(preview.status).tint(.white)
                } else {
                    Text(preview.error ?? "目前沒有可試看的劇集。")
                        .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                    Button("再試一次") { preview.start() }.buttonStyle(.bordered)
                }
                HStack(spacing: 22) {
                    Button("上一部") { preview.move(by: -1) }.disabled(!preview.hasPrevious)
                    Button("下一部") { preview.move(by: 1) }.disabled(!preview.canAdvance)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Text("上滑看下一部 · 第 1 集試看").font(.footnote).foregroundStyle(Theme.muted)
                Spacer()
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.height) > 80,
                      abs(value.translation.height) > abs(value.translation.width) * 1.4 else { return }
                preview.move(by: value.translation.height < 0 ? 1 : -1)
            })
            .background(Theme.background).foregroundStyle(.white)
            .navigationTitle("推薦試看").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("關閉", action: onClose) }
                if let series = preview.current {
                    ToolbarItem(placement: .primaryAction) { Button("看整部") { onOpenSeries(series) } }
                }
            }
        }
    }

}

@MainActor
private final class RecommendationPreviewModel: ObservableObject {
    @Published private(set) var queue = RecommendationPreviewQueue()
    @Published private(set) var selection: RecommendationPreviewSelection?
    @Published private(set) var isLoading = false
    @Published private(set) var status = "正在載入試看片單…"
    @Published private(set) var error: String?
    private(set) var revision: UUID?
    private var catalogue: (any CatalogService)?
    private var playback: (any CatalogService)?
    private var operation: Task<Void, Never>?
    private var operationID = UUID()

    var current: Series? { queue.current }
    var hasPrevious: Bool { queue.hasPrevious }
    var canAdvance: Bool { queue.hasNext || queue.hasMore }

    func configure(revision: UUID, catalogue: any CatalogService, playback: any CatalogService) {
        cancel(); queue.reset()
        error = nil
        self.revision = revision; self.catalogue = catalogue; self.playback = playback
    }

    func configureFailure(_ error: any Error, revision: UUID) {
        invalidateSource()
        self.revision = revision
        self.error = error.localizedDescription
    }

    func invalidateSource() {
        cancel(); queue.reset()
        revision = nil; catalogue = nil; playback = nil; error = nil
    }

    func start() {
        if queue.current == nil, !queue.hasMore { queue.reset() }
        prepare(move: 0)
    }

    func move(by offset: Int) {
        guard offset == 1 || offset == -1 else { return }
        if offset < 0, !queue.hasPrevious { return }
        prepare(move: offset)
    }

    func cancel() {
        operationID = UUID(); operation?.cancel(); operation = nil
        queue.cancelPageRequest()
        selection = nil; isLoading = false
    }

    private func prepare(move offset: Int) {
        guard let catalogue, let playback else {
            error = error ?? CatalogError.invalidConfiguration.localizedDescription
            return
        }
        let hadCurrent = queue.current != nil
        cancel()
        let request = operationID
        error = nil; isLoading = true; status = "正在載入試看片單…"
        operation = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.operationID == request { self.isLoading = false; self.operation = nil }
            }
            do {
                if self.queue.current == nil || (offset > 0 && !self.queue.hasNext) {
                    try await self.loadPages(needsNext: hadCurrent && offset > 0, catalogue: catalogue, request: request)
                }
                try self.check(request)
                if hadCurrent, offset != 0, self.queue.move(by: offset) == nil {
                    self.error = self.queue.hasMore ? "這一頁沒有新的劇集，請再滑一次或點下一部繼續找。" : "目前已到片單最後一部，可重新試看或稍後再來。"
                    return
                }
                guard let series = self.queue.current else {
                    self.error = "目前沒有可試看的劇集，請稍後再試。"
                    return
                }
                self.status = "正在準備第 1 集…"
                let detail: SeriesDetail
                if let bridge = playback as? BridgeService { detail = try await bridge.verifiedDetail(id: series.id) }
                else { detail = try await playback.detail(id: series.id) }
                try self.check(request)
                let episode = try RecommendationPreviewQueue.firstEpisode(in: detail, expectedSeriesID: series.id)
                self.selection = RecommendationPreviewSelection(series: detail.series, episode: episode, service: playback)
            } catch is CancellationError {
                return
            } catch {
                if self.operationID == request, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func loadPages(needsNext: Bool, catalogue: any CatalogService, request: UUID) async throws {
        // At most three overlapping/empty pages per user swipe; no unbounded background scan.
        for _ in 0..<3 {
            if needsNext ? queue.hasNext : queue.current != nil { return }
            guard let pageRequest = queue.beginPageRequest() else { return }
            do {
                let result = try await catalogue.home(page: pageRequest.page)
                try check(request)
                guard try queue.receive(result, for: pageRequest) else { throw CancellationError() }
            } catch {
                if operationID == request { queue.cancelPageRequest() }
                throw error
            }
        }
    }

    private func check(_ request: UUID) throws {
        try Task.checkCancellation()
        guard operationID == request else { throw CancellationError() }
    }
}
