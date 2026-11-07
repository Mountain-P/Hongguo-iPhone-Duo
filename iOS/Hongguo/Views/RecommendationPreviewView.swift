import SwiftUI
import HongguoCore
import Network

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
    var bottomControlInset: CGFloat = 0
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var preview = RecommendationPreviewModel()
    @StateObject private var networkPolicy = PreviewNetworkPolicy()
    @StateObject private var playback = ContinuePlaybackModel()
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
    @State private var showingPreferences = false

    private struct Activation: Hashable {
        let revision: UUID
        let preferences: UUID
        let scope: LibraryScope
        let active: Bool
    }

    private var playbackContext: ContinuePlaybackContext {
        .init(owner: model.selectedLibraryOwner, revision: model.revision,
              sceneActive: scenePhase == .active && UIApplication.shared.applicationState == .active,
              parentActive: isActive && tabIsActive && isVisible && detailSeries == nil && !showingPreferences)
    }

    var body: some View {
        let activation = Activation(revision: model.revision, preferences: model.recommendationFilterRevision,
                                    scope: model.recommendationScope, active: isActive)
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
        .allowsHitTesting(playback.pendingChoice == nil && playback.route == nil && playback.preparingSeriesID == nil)
        .accessibilityHidden(playback.preparingSeriesID != nil || playback.pendingChoice != nil || playback.route != nil)
        .clipped().background(Color.black).foregroundStyle(.white)
        .navigationTitle("推薦試看").navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .toolbarBackground(isActive && detailSeries == nil ? .hidden : .automatic, for: .tabBar)
        .task(id: activation) {
            guard !Task.isCancelled, activation.revision == model.revision,
                  activation.preferences == model.recommendationFilterRevision,
                  activation.scope == model.recommendationScope,
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
            // Our own player cover hides the feed too; keep that presentation alive.
            if playback.route == nil { isVisible = false; playback.cancelPending() }
            fallbackSettle?.cancel(); fallbackSettle = nil
            preview.suspend()
        }
        .onChange(of: isActive) { _, active in
            tabIsActive = active
            if active { activateSource() }
            else { preview.suspend(); playback.dismiss() }
            refreshEligibility()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { preview.suspend() }
            else if tabIsActive, isVisible { preview.loadInitial() }
            refreshEligibility()
        }
        .onChange(of: model.revision) { _, _ in
            resetFeed()
        }
        .onChange(of: model.recommendationFilterRevision) { _, _ in resetFeed() }
        .onChange(of: model.recommendationScope) { _, _ in resetFeed() }
        .onChange(of: model.recommendationProfile) { _, profile in
            preview.updateRankingProfile(profile, scope: model.recommendationScope)
        }
        .onChange(of: model.recommendationPreferences.previewedIDs) { _, _ in
            preview.updatePreferences(model.recommendationPreferences)
        }
        .onChange(of: networkPolicy.allowsPrefetch) { _, allowed in
            preview.setPrefetchAllowed(model.playbackMode == .native && allowed)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            preview.discardPrefetchCache()
        }
        .onChange(of: preview.items.map(\.id)) { _, ids in
            if scrollID == nil || !ids.contains(scrollID ?? "") { scrollID = preview.current?.id ?? ids.first }
            refreshEligibility()
        }
        .onChange(of: scrollID) { _, _ in refreshEligibility() }
        .onChange(of: detailSeries) { _, detail in
            if detail != nil { requiresManualResume = true; preview.suspend(); playback.cancelPending() }
            refreshEligibility()
        }
        .onChange(of: showingPreferences) { _, presented in
            if presented { requiresManualResume = true; preview.suspend(); playback.cancelPending() }
            refreshEligibility()
        }
        .sheet(isPresented: $showingPreferences) {
            NavigationStack { RecommendationPreferencesView() }
        }
        .navigationDestination(item: $detailSeries) { series in
            DetailView(series: series).toolbar(.visible, for: .navigationBar)
        }
        .onChange(of: playback.route?.id) { _, routeID in
            if routeID != nil { requiresManualResume = true; preview.suspend() }
            refreshEligibility()
        }
        .overlay { if let choice = playback.pendingChoice { continuationChoice(choice) } }
        .overlay(alignment: .bottom) {
            if let message = playback.errorMessage {
                HStack(alignment: .top, spacing: 12) {
                    Text(message).font(.footnote)
                    Button("關閉") { playback.cancelPending() }
                }
                .padding(16).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .padding(18).padding(.bottom, max(bottomControlInset, 0))
            }
        }
        .continuePlaybackPresentation(playback, context: playbackContext, bottomOverlayInset: bottomControlInset)
    }

    private var emptyFeed: some View {
        VStack(spacing: 18) {
            if preview.isLoadingPage {
                ProgressView("正在載入試看片單…").tint(.white)
            } else {
                Text("推薦試看").font(.title2.weight(.semibold))
                Text(preview.pageError ?? "目前沒有符合偏好的劇集，可調整推薦偏好再找找。")
                    .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button(preview.queue.page > 0 && preview.queue.hasMore ? "繼續找劇" : "重新載入") { activateSource(); preview.loadInitial() }
                    .buttonStyle(.borderedProminent)
            }
            Button("推薦偏好", systemImage: "slider.horizontal.3") { showingPreferences = true }
                .buttonStyle(.bordered)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feedCard(_ series: Series) -> some View {
        let canRetainFrame = isVisible && tabIsActive && scenePhase == .active && detailSeries == nil && !showingPreferences && playback.route == nil && intersectsViewport(series.id)
        let allowsInteraction = alignedID == series.id && isVisible && tabIsActive
            && scenePhase == .active && detailSeries == nil && !showingPreferences && phaseIsIdle
            && playback.preparingSeriesID == nil && playback.pendingChoice == nil && playback.route == nil
        return ZStack {
            Poster(series: series, contentMode: .fill).allowsHitTesting(false)
            if let media = preview.media[series.id] {
                RecommendationPreviewMediaCard(series: media.series, episode: media.episode, service: media.service,
                    isActive: preview.lease?.seriesID == series.id && effectivePlaybackAllowed,
                    retainsFrame: canRetainFrame, allowsInteraction: allowsInteraction,
                    isFavorite: model.isFavorite(series),
                    onToggleFavorite: { model.toggleFavorite(media.series) },
                    onPreviewStarted: {
                        model.markPreviewed(series)
                        preview.didStartPreview(seriesID: series.id)
                    },
                    recommendationTitle: model.catalogSource == .website ? model.recommendationPreferences.category.previewTitle : "試看",
                    recommendationReason: recommendationReason(for: series.id),
                    bottomControlInset: bottomControlInset,
                    onShowPreferences: { showingPreferences = true },
                    onNotInterested: { model.setNotInterested(series, value: true) },
                    onViewDetails: { openEntireSeries(media.series) },
                    onOpenSeries: { snapshot in startFollowing(media.series, snapshot: snapshot) })
                    .id(media.id)
            } else {
                posterInformation(series)
            }
            if requiresManualResume, alignedID == series.id, !showingPreferences {
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
            if let reason = recommendationReason(for: series.id) {
                Text(reason).font(.caption).foregroundStyle(.white.opacity(0.8)).lineLimit(2)
            }
            Text("第 1 集試看 · 上滑看下一部").font(.subheadline).foregroundStyle(.white.opacity(0.8))
            HStack {
                Button("劇集詳情") { openEntireSeries(series) }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button {
                    model.toggleFavorite(series)
                } label: {
                    Image(systemName: model.isFavorite(series) ? "heart.fill" : "heart")
                }.buttonStyle(.bordered)
                    .accessibilityLabel(model.isFavorite(series) ? "取消收藏" : "收藏這部劇")
                Menu {
                    Button("推薦偏好", systemImage: "slider.horizontal.3") { showingPreferences = true }
                    Button("不感興趣", systemImage: "eye.slash") { model.setNotInterested(series, value: true) }
                } label: { Image(systemName: "ellipsis") }
                    .buttonStyle(.bordered).accessibilityLabel("試看選項")
            }.disabled(alignedID != series.id || !phaseIsIdle)
        }
        .padding(24).padding(.bottom, max(bottomControlInset, 0))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false)
        }
    }

    private var effectivePlaybackAllowed: Bool {
        isVisible && tabIsActive && scenePhase == .active && detailSeries == nil && !showingPreferences && !requiresManualResume && phaseIsIdle
            && playback.route == nil && playback.pendingChoice == nil && playback.preparingSeriesID == nil
    }

    private func recommendationReason(for seriesID: String) -> String? {
        guard preview.rankingScope == model.recommendationScope else { return nil }
        return preview.reasonByID[seriesID]
    }

    private var alignedID: String? {
        // The system's available scroll viewport can change with Duo bars and
        // rotation independently of the outer GeometryReader. Measured card
        // origins share the actual viewport coordinates used by viewAligned.
        let known = Set(preview.items.map(\.id))
        guard let closest = frames.filter({ known.contains($0.key) }).min(by: { abs($0.value) < abs($1.value) }),
              abs(closest.value) <= 2 else { return nil }
        return closest.key
    }

    private func intersectsViewport(_ id: String) -> Bool {
        guard let top = frames[id] else { return false }
        return top > -viewportHeight && top < viewportHeight
    }

    private func activateSource() {
        guard tabIsActive else { return }
        if preview.revision != model.revision || preview.filterRevision != model.recommendationFilterRevision
            || preview.rankingScope != model.recommendationScope {
            do {
                preview.configure(revision: model.revision, filterRevision: model.recommendationFilterRevision,
                    preferences: model.recommendationPreferences, profile: model.recommendationProfile, scope: model.recommendationScope,
                    catalogue: try model.previewCatalogService(), playback: try model.playbackService())
            } catch { preview.configureFailure(error, revision: model.revision) }
        }
        preview.updateRankingProfile(model.recommendationProfile, scope: model.recommendationScope)
        preview.loadInitial()
        preview.setPrefetchAllowed(model.playbackMode == .native && networkPolicy.allowsPrefetch)
    }

    private func resetFeed() {
        playback.dismiss()
        fallbackSettle?.cancel(); fallbackSettle = nil
        scrollID = nil; frames = [:]; contentOffset = nil; pendingScrollTarget = nil
        requiresManualResume = showingPreferences
        preview.invalidateSource()
        if tabIsActive { activateSource() }
    }

    private func refreshEligibility() {
        let sourceMatches = preview.revision == model.revision && preview.filterRevision == model.recommendationFilterRevision
            && preview.rankingScope == model.recommendationScope
        let aligned = alignedID
        let commandHasArrived = pendingScrollTarget == nil || pendingScrollTarget == aligned
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-preview-layout-diagnostics") {
            let nearest = frames.values.min(by: { abs($0) < abs($1) }) ?? -9999
            NSLog("PreviewLayout height=%.2f offset=%.2f nearest=%.2f idle=%d pending=%d aligned=%d",
                  Double(viewportHeight), Double(contentOffset ?? -9999), Double(nearest),
                  phaseIsIdle ? 1 : 0, pendingScrollTarget == nil ? 0 : 1,
                  aligned.flatMap { id in preview.items.firstIndex(where: { $0.id == id }) } ?? -1)
        }
        #endif
        if commandHasArrived { pendingScrollTarget = nil }
        preview.update(selectedID: commandHasArrived ? aligned : nil, isIdle: phaseIsIdle,
            isActive: isVisible && tabIsActive && sourceMatches && !showingPreferences && !requiresManualResume
                && playback.route == nil && playback.pendingChoice == nil && playback.preparingSeriesID == nil,
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
            refreshEligibility()
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

    private func startFollowing(_ series: Series, snapshot: PreviewPlaybackSnapshot) {
        guard playbackContext.permitsStart, alignedID == series.id, phaseIsIdle,
              snapshot.seriesID == series.id, playback.route == nil,
              playback.preparingSeriesID == nil, playback.pendingChoice == nil else { return }
        requiresManualResume = true; preview.suspend()
        do {
            playback.start(series: series, selection: .preview(snapshot), context: playbackContext,
                service: try model.playbackService(), currentContext: { playbackContext },
                latestRecord: { model.record(for: series) },
                progressFactory: { detail in model.playbackProgressHandler(for: detail.series, episodes: detail.episodes) })
        } catch { playback.fail(error, seriesID: series.id) }
    }

    private func continuationChoice(_ choice: ContinuePlaybackChoice) -> some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("選擇播放位置").font(.headline)
                Text("這部劇已有正式觀看進度，請選擇這次要從哪裡開始。")
                    .font(.subheadline).multilineTextAlignment(.center)
                Button {
                    playback.choose(.saved, choiceID: choice.id)
                } label: {
                    VStack(spacing: 4) {
                        Text("接續原進度").fontWeight(.semibold)
                        Text(positionLabel(choice.saved)).font(.caption)
                    }.frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button {
                    playback.choose(.preview, choiceID: choice.id)
                } label: {
                    VStack(spacing: 4) {
                        Text("從試看位置看").fontWeight(.semibold)
                        Text(positionLabel(choice.preview)).font(.caption)
                    }.frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.bordered)
                Button("取消") { playback.cancelPending() }.frame(minHeight: 44)
            }
            .padding(24).frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))
            .padding(24)
        }
    }

    private func positionLabel(_ continuation: PlaybackContinuation) -> String {
        let seconds = continuation.seconds.isFinite ? Int(min(max(continuation.seconds, 0), 86_400)) : 0
        return "第 \(continuation.episode.number) 集 · \(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }
}

@MainActor
private final class RecommendationPreviewModel: ObservableObject {
    @Published private(set) var queue = RecommendationPreviewQueue()
    @Published private(set) var media: [String: RecommendationFeedMedia] = [:]
    @Published private(set) var reasonByID: [String: String] = [:]
    private(set) var rankingScope: LibraryScope?
    private var rankingProfile: PersonalizedRecommendationProfile?
    @Published private(set) var lease: RecommendationFeedActivation.Lease?
    @Published private(set) var loadingID: String?
    @Published private(set) var detailErrors: [String: String] = [:]
    @Published private(set) var isLoadingPage = false
    @Published private(set) var pageError: String?
    private(set) var revision: UUID?
    private(set) var filterRevision: UUID?
    private var preferences = RecommendationPreferences()
    private var catalogue: (any CatalogService)?
    private var playback: (any CatalogService)?
    private var activation = RecommendationFeedActivation()
    private var catalogueGeneration = UUID()
    private var catalogueTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var detailGeneration = UUID()
    private var recentMediaIDs: [String] = []
    private let prefetcher = NativePlaybackPrefetch()
    private var prefetchTask: Task<Void, Never>?
    private var prefetchGeneration = UUID()
    private var prefetchAllowed = false
    private var startedPreviewIDs: Set<String> = []

    var items: [Series] { queue.items }
    var current: Series? { queue.current }

    func configure(revision: UUID, filterRevision: UUID, preferences: RecommendationPreferences,
                   profile: PersonalizedRecommendationProfile, scope: LibraryScope,
                   catalogue: any CatalogService, playback: any CatalogService) {
        invalidateSource()
        self.revision = revision; self.filterRevision = filterRevision; self.preferences = preferences
        rankingScope = scope; rankingProfile = profile
        self.catalogue = catalogue; self.playback = playback
    }

    func updatePreferences(_ preferences: RecommendationPreferences) { self.preferences = preferences }

    func updateRankingProfile(_ profile: PersonalizedRecommendationProfile, scope: LibraryScope) {
        guard rankingScope == scope, rankingProfile != profile else { return }
        rankingProfile = profile
        refreshReasons()
    }

    private func refreshReasons() {
        guard let rankingScope, let rankingProfile else { reasonByID = [:]; return }
        var reasons: [String: String] = [:]
        for item in PersonalizedRecommendation.rank(queue.items, using: rankingProfile, scope: rankingScope) {
            if let reason = item.reason { reasons[item.series.id] = reason.displayText }
        }
        // Updating explanations never changes the queue's current card or source pagination.
        reasonByID = reasons
    }

    func configureFailure(_ error: any Error, revision: UUID) {
        invalidateSource(); self.revision = revision; pageError = error.localizedDescription
    }

    func invalidateSource() {
        suspend(); queue.reset(); media = [:]; recentMediaIDs = []; detailErrors = [:]; startedPreviewIDs = []
        revision = nil; filterRevision = nil; catalogue = nil; playback = nil; pageError = nil
        rankingScope = nil; rankingProfile = nil; reasonByID = [:]
    }

    func suspend() {
        cancelAdjacentPrefetch()
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
        cancelAdjacentPrefetch()
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
        guard let catalogue, let profile = rankingProfile, let scope = rankingScope,
              catalogueTask == nil, queue.hasMore else { return }
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
                    // A cancelled task can start after a replacement configured the queue.
                    // Reject it before it can claim that replacement's pending page.
                    try Task.checkCancellation()
                    guard self.catalogueGeneration == request else { return }
                    guard let pageRequest = self.queue.beginPageRequest() else { return }
                    let result = try await catalogue.home(page: pageRequest.page)
                    try Task.checkCancellation()
                    guard self.catalogueGeneration == request else { return }
                    guard try self.queue.receive(result, for: pageRequest, preferences: self.preferences, ranking: {
                        PersonalizedRecommendation.rank($0, using: profile, scope: scope).map(\.series)
                    }) else { throw CancellationError() }
                    self.refreshReasons()
                    self.pruneMedia()
                    if self.queue.items.last?.id != previousTail || !self.queue.hasMore { return }
                }
                self.pageError = "這幾頁沒有符合偏好的新劇，可載入更多或調整推薦偏好。"
            } catch is CancellationError {
                if self.catalogueGeneration == request { self.queue.cancelPageRequest() }
            } catch {
                guard self.catalogueGeneration == request, !Task.isCancelled else { return }
                self.queue.cancelPageRequest(); self.pageError = error.localizedDescription
            }
        }
    }

    private func prepare(_ lease: RecommendationFeedActivation.Lease) {
        guard let playback else { return }
        if media[lease.seriesID] != nil {
            touch(lease.seriesID)
            if startedPreviewIDs.contains(lease.seriesID) { prepareAdjacent(to: lease) }
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
        startedPreviewIDs.formIntersection(retained)
    }

    func setPrefetchAllowed(_ allowed: Bool) {
        guard allowed != prefetchAllowed else { return }
        prefetchAllowed = allowed
        if !allowed { cancelAdjacentPrefetch() }
        else if let lease, startedPreviewIDs.contains(lease.seriesID) { prepareAdjacent(to: lease) }
    }

    func didStartPreview(seriesID: String) {
        startedPreviewIDs.insert(seriesID)
        guard let lease, lease.seriesID == seriesID else { return }
        prepareAdjacent(to: lease)
    }

    func discardPrefetchCache() {
        cancelAdjacentPrefetch()
        let prefetcher = prefetcher
        Task { await prefetcher.clear() }
    }

    private func cancelAdjacentPrefetch() {
        prefetchGeneration = UUID()
        prefetchTask?.cancel(); prefetchTask = nil
    }

    private func prepareAdjacent(to lease: RecommendationFeedActivation.Lease) {
        guard prefetchAllowed, prefetchTask == nil, let playback,
              let current = items.firstIndex(where: { $0.id == lease.seriesID }), items.indices.contains(current + 1) else { return }
        let next = items[current + 1]
        guard preferences.allows(seriesID: next.id) else { return }
        let request = UUID(); prefetchGeneration = request
        prefetchTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer { if self.prefetchGeneration == request { self.prefetchTask = nil } }
            do {
                // Give active playback first use of the connection and ignore quick flicks.
                try await Task.sleep(for: .milliseconds(400))
                guard self.prefetchAllowed, self.prefetchGeneration == request, self.activation.accepts(lease) else { return }
                let media: RecommendationFeedMedia
                if let cached = self.media[next.id] { media = cached }
                else {
                    let detail = try await playback.detail(id: next.id)
                    try Task.checkCancellation()
                    guard self.prefetchGeneration == request, self.activation.accepts(lease) else { return }
                    let episode = try RecommendationPreviewQueue.firstEpisode(in: detail, expectedSeriesID: next.id)
                    media = RecommendationFeedMedia(series: detail.series, episode: episode, service: playback)
                    self.media[next.id] = media; self.touch(next.id)
                }
                try Task.checkCancellation()
                guard self.prefetchAllowed, self.prefetchGeneration == request, self.activation.accepts(lease) else { return }
                _ = try await self.prefetcher.prepare(seriesID: next.id, episodeID: media.episode.id, service: playback)
            } catch { /* Speculative work never becomes a visible playback error. */ }
        }
    }
}

/// Speculative bytes are allowed only on an unconstrained, non-metered path.
@MainActor
private final class PreviewNetworkPolicy: ObservableObject {
    @Published private var networkAllowed = false
    @Published private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private let monitor = NWPathMonitor()
    private var powerObserver: NSObjectProtocol?

    var allowsPrefetch: Bool { networkAllowed && !lowPower }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let allowed = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            Task { @MainActor [weak self] in self?.networkAllowed = allowed }
        }
        monitor.start(queue: DispatchQueue(label: "tw.mountainp.hongguo.preview-network"))
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    deinit {
        monitor.cancel()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }
}

extension DirectWebService.Category {
    var previewTitle: String {
        switch self {
        case .realDrama: "真人"
        case .comicDrama: "漫劇"
        case .aiDrama: "AI 短劇"
        }
    }
}

@MainActor
struct RecommendationPreferencesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("想看的類型") {
                Picker("內容類型", selection: Binding(get: { model.recommendationPreferences.category },
                    set: { model.setRecommendationCategory($0) })) {
                    ForEach(DirectWebService.Category.allCases, id: \.self) { category in
                        Text(category.previewTitle).tag(category)
                    }
                }
                .pickerStyle(.segmented).disabled(model.catalogSource != .website)
                if model.catalogSource != .website {
                    Text("目前片單由自訂服務提供，類型由該服務決定。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle("略過已試看的劇", isOn: Binding(get: { model.recommendationPreferences.skipsPreviewed },
                    set: { model.setSkipsPreviewed($0) }))
                Text("已記住 \(model.recommendationPreferences.previewedIDs.count) 部試看。正在看的這一部會保留，下次找劇才套用略過。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("重新顯示試看過的劇") { model.resetPreviewed() }
                    .disabled(model.recommendationPreferences.previewedIDs.isEmpty)
            } header: { Text("減少重複推薦") }
              footer: { Text("試看標記只存在這部 iPhone，不會加入或清除正式觀看紀錄。") }
            Section("不感興趣") {
                Text("已隱藏 \(model.recommendationPreferences.notInterestedIDs.count) 部劇")
                Button("恢復這些推薦") { model.resetNotInterested() }
                    .disabled(model.recommendationPreferences.notInterestedIDs.isEmpty)
            }
            Section {
                Text("片單來自公開目錄，這些偏好只調整本機試看片單，不會提交到官方帳號。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("推薦偏好").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
}
