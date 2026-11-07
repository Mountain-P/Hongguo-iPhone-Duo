import SwiftUI
import HongguoCore

private struct RecommendationFeedMedia: Identifiable {
    let id = UUID()
    let series: Series
    let episode: Episode
    let service: any CatalogService
}

private struct RecommendationFeedFrames: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

@MainActor
private struct RecommendationFeedScrollPhase: ViewModifier {
    let changed: (Bool, Bool) -> Void
    let fallbackDrag: (Bool) -> Void
    let offsetChanged: (CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                // Tracking includes a stationary tap or long press on the card's controls.
                // Revoke playback only once an actual scroll begins.
                guard phase != .tracking else { return }
                changed(phase == .idle, phase == .interacting)
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                // Keep offsets in the same content coordinates as page origins.
                max(geometry.contentOffset.y, 0)
            } action: { _, offset in offsetChanged(offset) }
        } else {
            content.simultaneousGesture(DragGesture(minimumDistance: 4)
                .onChanged { _ in fallbackDrag(true) }
                .onEnded { _ in fallbackDrag(false) })
        }
    }
}

@MainActor
struct RecommendationPreviewView: View {
    var isActive = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preview = RecommendationPreviewModel()
    @State private var scrollID: String?
    @State private var frames: [String: CGFloat] = [:]
    @State private var viewportHeight: CGFloat = 1
    @State private var contentOffset: CGFloat?
    @State private var pendingScrollTarget: String?
    @State private var phaseIsIdle = true
    @State private var fallbackDragging = false
    @State private var fallbackSettle: Task<Void, Never>?
    @State private var tabIsActive = false
    @State private var isVisible = false
    @State private var requiresManualResume = false
    @State private var detailSeries: Series?

    private struct Activation: Hashable {
        let revision: UUID
        let active: Bool
    }

    var body: some View {
        let activation = Activation(revision: model.revision, active: isActive)
        return GeometryReader { geometry in
            Group {
                if preview.items.isEmpty {
                    emptyFeed
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(preview.items) { series in
                                feedCard(series)
                                    .frame(width: max(geometry.size.width, 1), height: max(geometry.size.height, 1))
                                    .clipped()
                                    .background {
                                        GeometryReader { card in
                                            Color.clear.preference(key: RecommendationFeedFrames.self,
                                                value: [series.id: card.frame(in: .named("recommendationFeed")).minY])
                                        }
                                    }
                                    .id(series.id)
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .coordinateSpace(name: "recommendationFeed")
                    .contentMargins(.vertical, 0, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                    .scrollPosition(id: $scrollID, anchor: .top)
                    .scrollIndicators(.hidden)
                    .modifier(RecommendationFeedScrollPhase(changed: phaseChanged, fallbackDrag: fallbackDragChanged,
                        offsetChanged: offsetChanged))
                    .onPreferenceChange(RecommendationFeedFrames.self, perform: framesChanged)
                }
            }
            .onAppear { viewportHeight = max(geometry.size.height, 1) }
            .onChange(of: geometry.size.height) { _, height in
                viewportHeight = max(height, 1)
                refreshEligibility()
            }
        }
        .clipped().background(Color.black).foregroundStyle(.white)
        .navigationTitle("推薦試看").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .task(id: activation) {
            guard !Task.isCancelled, activation.revision == model.revision,
                  activation.active == isActive, activation.active else { return }
            tabIsActive = true
            activateSource()
        }
        .onAppear {
            isVisible = true; tabIsActive = isActive; phaseIsIdle = true
            if tabIsActive { activateSource() }
            refreshEligibility()
        }
        .onDisappear {
            isVisible = false
            fallbackSettle?.cancel(); fallbackSettle = nil
            preview.suspend()
        }
        .onChange(of: isActive) { _, active in
            tabIsActive = active
            if active { activateSource() }
            else { preview.suspend() }
            refreshEligibility()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { preview.suspend() }
            else if tabIsActive, isVisible { preview.loadInitial() }
            refreshEligibility()
        }
        .onChange(of: model.revision) { _, _ in
            fallbackSettle?.cancel(); fallbackSettle = nil
            scrollID = nil; frames = [:]; contentOffset = nil; pendingScrollTarget = nil; requiresManualResume = false
            preview.invalidateSource()
            if tabIsActive { activateSource() }
        }
        .onChange(of: preview.items.map(\.id)) { _, ids in
            if scrollID == nil || !ids.contains(scrollID ?? "") { scrollID = preview.current?.id ?? ids.first }
            refreshEligibility()
        }
        .onChange(of: scrollID) { _, _ in refreshEligibility() }
        .onChange(of: detailSeries) { _, detail in
            if detail != nil { preview.suspend() }
            refreshEligibility()
        }
        .navigationDestination(item: $detailSeries) { series in
            DetailView(series: series).toolbar(.visible, for: .navigationBar)
        }
    }

    private var emptyFeed: some View {
        VStack(spacing: 18) {
            if preview.isLoadingPage {
                ProgressView("正在載入試看片單…").tint(.white)
            } else {
                Text("推薦試看").font(.title2.weight(.semibold))
                Text(preview.pageError ?? "目前沒有可試看的劇集。")
                    .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button("重新載入") { activateSource(); preview.loadInitial() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feedCard(_ series: Series) -> some View {
        let canRetainFrame = isVisible && tabIsActive && scenePhase == .active && detailSeries == nil && intersectsViewport(series.id)
        let allowsInteraction = alignedID == series.id && isVisible && tabIsActive
            && scenePhase == .active && detailSeries == nil && phaseIsIdle
        return ZStack {
            Poster(series: series, contentMode: .fit).allowsHitTesting(false)
            if let media = preview.media[series.id] {
                RecommendationPreviewMediaCard(series: media.series, episode: media.episode, service: media.service,
                    isActive: preview.lease?.seriesID == series.id && effectivePlaybackAllowed,
                    retainsFrame: canRetainFrame, allowsInteraction: allowsInteraction,
                    onOpenSeries: { openEntireSeries(media.series) })
                    .id(media.id)
            } else {
                posterInformation(series)
            }
            if requiresManualResume, alignedID == series.id {
                Button {
                    requiresManualResume = false
                    refreshEligibility()
                } label: {
                    Label("繼續試看", systemImage: "play.fill")
                        .font(.headline).padding(.horizontal, 22).padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
            if series.id == preview.items.last?.id {
                VStack {
                    if preview.isLoadingPage {
                        ProgressView("正在載入更多劇集…").font(.caption).padding(10).background(.ultraThinMaterial, in: Capsule())
                    } else if let error = preview.pageError {
                        VStack(spacing: 8) {
                            Text(error).font(.caption).multilineTextAlignment(.center)
                            Button("重試載入更多") { preview.loadMoreIfNeeded(force: true) }.font(.caption.weight(.semibold))
                        }.padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    Spacer()
                }.padding(.top, 18).padding(.horizontal, 24)
            }
        }
        .background(Color.black).contentShape(Rectangle())
        .accessibilityAction(named: Text("下一部試看")) { scroll(by: 1, from: series.id) }
        .accessibilityAction(named: Text("上一部試看")) { scroll(by: -1, from: series.id) }
    }

    private func posterInformation(_ series: Series) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            if preview.loadingID == series.id { ProgressView("正在準備第 1 集…").tint(.white) }
            if let error = preview.detailErrors[series.id] {
                Text(error).font(.footnote)
                Button("重試第一集") { preview.retry(seriesID: series.id) }.buttonStyle(.bordered)
            }
            Text(series.title).font(.title3.weight(.semibold)).lineLimit(3)
            Text("第 1 集試看 · 上滑看下一部").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            Button("看整部") { openEntireSeries(series) }.buttonStyle(.borderedProminent).tint(Theme.accent)
        }
        .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
        }
    }

    private var effectivePlaybackAllowed: Bool {
        isVisible && tabIsActive && scenePhase == .active && detailSeries == nil && !requiresManualResume && phaseIsIdle
    }

    private var alignedID: String? {
        if let contentOffset {
            let index = Int((contentOffset / viewportHeight).rounded())
            guard preview.items.indices.contains(index),
                  abs(contentOffset - CGFloat(index) * viewportHeight) <= 2 else { return nil }
            return preview.items[index].id
        }
        let known = Set(preview.items.map(\.id))
        guard let closest = frames.filter({ known.contains($0.key) }).min(by: { abs($0.value) < abs($1.value) }),
              abs(closest.value) <= 2 else { return nil }
        return closest.key
    }

    private func intersectsViewport(_ id: String) -> Bool {
        if let contentOffset, let index = preview.items.firstIndex(where: { $0.id == id }) {
            let top = CGFloat(index) * viewportHeight - contentOffset
            return top > -viewportHeight && top < viewportHeight
        }
        guard let top = frames[id] else { return false }
        return top > -viewportHeight && top < viewportHeight
    }

    private func activateSource() {
        guard tabIsActive else { return }
        if preview.revision != model.revision {
            do {
                preview.configure(revision: model.revision, catalogue: try model.catalogService(), playback: try model.playbackService())
            } catch { preview.configureFailure(error, revision: model.revision) }
        }
        preview.loadInitial()
    }

    private func refreshEligibility() {
        let sourceMatches = preview.revision == model.revision
        let aligned = alignedID
        let commandHasArrived = pendingScrollTarget == nil || pendingScrollTarget == aligned
        if commandHasArrived { pendingScrollTarget = nil }
        preview.update(selectedID: commandHasArrived ? aligned : nil, isIdle: phaseIsIdle,
            isActive: isVisible && tabIsActive && sourceMatches && !requiresManualResume,
            isSceneActive: scenePhase == .active, isDetailPresented: detailSeries != nil)
    }

    private func phaseChanged(_ idle: Bool, _ userInitiated: Bool) {
        phaseIsIdle = idle
        fallbackDragging = userInitiated
        if userInitiated { pendingScrollTarget = nil }
        if userInitiated, detailSeries == nil { requiresManualResume = false }
        if idle || userInitiated { fallbackSettle?.cancel(); fallbackSettle = nil }
        refreshEligibility()
        if !idle, !userInitiated { scheduleFallbackSettle() }
    }

    private func framesChanged(_ next: [String: CGFloat]) {
        frames = next
        if #available(iOS 18.0, *) {
            if contentOffset == nil { refreshEligibility() }
        }
        else { scheduleFallbackSettle() }
    }

    private func offsetChanged(_ offset: CGFloat) {
        contentOffset = offset
        refreshEligibility()
        if !phaseIsIdle, !fallbackDragging { scheduleFallbackSettle() }
    }

    private func fallbackDragChanged(_ dragging: Bool) {
        fallbackDragging = dragging
        if dragging {
            fallbackSettle?.cancel(); phaseIsIdle = false
            if detailSeries == nil { requiresManualResume = false }
            refreshEligibility()
        } else { scheduleFallbackSettle() }
    }

    private func scheduleFallbackSettle() {
        fallbackSettle?.cancel()
        phaseIsIdle = false
        refreshEligibility()
        guard !fallbackDragging else { return }
        fallbackSettle = Task {
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard !Task.isCancelled, !fallbackDragging, alignedID != nil else { return }
            phaseIsIdle = true
            refreshEligibility()
        }
    }

    private func scroll(by offset: Int, from id: String) {
        guard let index = preview.items.firstIndex(where: { $0.id == id }),
              preview.items.indices.contains(index + offset) else {
            preview.loadMoreIfNeeded(force: true)
            return
        }
        requiresManualResume = false
        pendingScrollTarget = preview.items[index + offset].id
        // Geometry alignment and the system's scroll phase gate activation.
        // A binding-driven accessibility scroll does not always emit a phase
        // transition, so do not leave it waiting for an idle callback forever.
        preview.suspend()
        withAnimation { scrollID = preview.items[index + offset].id }
    }

    private func openEntireSeries(_ series: Series) {
        requiresManualResume = true
        preview.suspend()
        detailSeries = series
    }
}

@MainActor
private final class RecommendationPreviewModel: ObservableObject {
    @Published private(set) var queue = RecommendationPreviewQueue()
    @Published private(set) var media: [String: RecommendationFeedMedia] = [:]
    @Published private(set) var lease: RecommendationFeedActivation.Lease?
    @Published private(set) var loadingID: String?
    @Published private(set) var detailErrors: [String: String] = [:]
    @Published private(set) var isLoadingPage = false
    @Published private(set) var pageError: String?
    private(set) var revision: UUID?
    private var catalogue: (any CatalogService)?
    private var playback: (any CatalogService)?
    private var activation = RecommendationFeedActivation()
    private var catalogueGeneration = UUID()
    private var catalogueTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = UUID()
    private var recentMediaIDs: [String] = []

    var items: [Series] { queue.items }
    var current: Series? { queue.current }

    func configure(revision: UUID, catalogue: any CatalogService, playback: any CatalogService) {
        invalidateSource()
        self.revision = revision; self.catalogue = catalogue; self.playback = playback
    }

    func configureFailure(_ error: any Error, revision: UUID) {
        invalidateSource(); self.revision = revision; pageError = error.localizedDescription
    }

    func invalidateSource() {
        suspend(); queue.reset(); media = [:]; recentMediaIDs = []; detailErrors = [:]
        revision = nil; catalogue = nil; playback = nil; pageError = nil
    }

    func suspend() {
        activation.invalidate(); lease = nil
        detailGeneration = UUID()
        detailTask?.cancel(); detailTask = nil; loadingID = nil
        catalogueGeneration = UUID(); catalogueTask?.cancel(); catalogueTask = nil
        queue.cancelPageRequest(); isLoadingPage = false
    }

    func update(selectedID: String?, isIdle: Bool, isActive: Bool, isSceneActive: Bool, isDetailPresented: Bool) {
        let validID = selectedID.flatMap { id in queue.items.contains(where: { $0.id == id }) ? id : nil }
        let next = activation.update(selectedID: validID, isIdle: isIdle, isActive: isActive,
                                     isSceneActive: isSceneActive, isDetailPresented: isDetailPresented)
        guard next != lease else { return }
        detailGeneration = UUID()
        detailTask?.cancel(); detailTask = nil; loadingID = nil
        lease = next
        guard let next else { return }
        queue.select(seriesID: next.seriesID)
        prepare(next)
        loadMoreIfNeeded()
    }

    func retry(seriesID: String) {
        guard let lease, lease.seriesID == seriesID else { return }
        detailTask?.cancel(); detailTask = nil
        media.removeValue(forKey: seriesID); detailErrors.removeValue(forKey: seriesID)
        prepare(lease)
    }

    func loadInitial() {
        guard items.isEmpty else { return }
        if !queue.hasMore { queue.reset() }
        loadPage()
    }

    func loadMoreIfNeeded(force: Bool = false) {
        guard queue.hasMore, let index = queue.currentIndex,
              force || index >= max(queue.items.count - 3, 0) else { return }
        loadPage()
    }

    private func loadPage() {
        guard let catalogue, catalogueTask == nil, queue.hasMore else { return }
        let request = catalogueGeneration
        let previousTail = queue.items.last?.id
        isLoadingPage = true; pageError = nil
        catalogueTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.catalogueGeneration == request { self.isLoadingPage = false; self.catalogueTask = nil }
            }
            do {
                for _ in 0..<3 {
                    guard let pageRequest = self.queue.beginPageRequest() else { return }
                    let result = try await catalogue.home(page: pageRequest.page)
                    try Task.checkCancellation()
                    guard self.catalogueGeneration == request else { return }
                    guard try self.queue.receive(result, for: pageRequest) else { throw CancellationError() }
                    self.pruneMedia()
                    if self.queue.items.last?.id != previousTail || !self.queue.hasMore { return }
                }
                self.pageError = "這幾頁沒有新的劇集，可重試載入更多。"
            } catch is CancellationError { return }
            catch {
                guard self.catalogueGeneration == request, !Task.isCancelled else { return }
                self.queue.cancelPageRequest(); self.pageError = error.localizedDescription
            }
        }
    }

    private func prepare(_ lease: RecommendationFeedActivation.Lease) {
        guard let playback else { return }
        if media[lease.seriesID] != nil {
            touch(lease.seriesID)
            return
        }
        detailGeneration = UUID()
        let request = detailGeneration
        loadingID = lease.seriesID; detailErrors.removeValue(forKey: lease.seriesID)
        detailTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.activation.accepts(lease), self.detailGeneration == request {
                    self.loadingID = nil; self.detailTask = nil
                }
            }
            do {
                let detail: SeriesDetail
                if let bridge = playback as? BridgeService { detail = try await bridge.verifiedDetail(id: lease.seriesID) }
                else { detail = try await playback.detail(id: lease.seriesID) }
                try Task.checkCancellation()
                guard self.activation.accepts(lease), self.detailGeneration == request else { return }
                let episode = try RecommendationPreviewQueue.firstEpisode(in: detail, expectedSeriesID: lease.seriesID)
                self.media[lease.seriesID] = RecommendationFeedMedia(series: detail.series, episode: episode, service: playback)
                self.touch(lease.seriesID)
            } catch is CancellationError { return }
            catch {
                if self.activation.accepts(lease), self.detailGeneration == request, !Task.isCancelled {
                    self.detailErrors[lease.seriesID] = error.localizedDescription
                }
            }
        }
    }

    private func touch(_ id: String) {
        recentMediaIDs.removeAll { $0 == id }; recentMediaIDs.append(id)
        while recentMediaIDs.count > 3 { media.removeValue(forKey: recentMediaIDs.removeFirst()) }
        pruneMedia()
    }

    private func pruneMedia() {
        let retained = Set(queue.items.map(\.id))
        media = media.filter { retained.contains($0.key) }
        recentMediaIDs.removeAll { !retained.contains($0) }
        detailErrors = detailErrors.filter { retained.contains($0.key) }
    }
}
