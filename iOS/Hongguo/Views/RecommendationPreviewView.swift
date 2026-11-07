import SwiftUI
import HongguoCore
import Network

private struct RecommendationFeedFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
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
    @StateObject private var preview = RecommendationPreviewModel(sessionStore: .shared)
    @StateObject private var networkPolicy = PreviewNetworkPolicy()
    @StateObject private var playback = ContinuePlaybackModel()
    @State private var scrollID: String?
    @State private var frames: [String: CGRect] = [:]
    @State private var viewportSize: CGSize = .zero
    @State private var lastSettledID: String?
    @State private var resizeTargetID: String?
    @State private var resizeGeneration = UUID()
    @State private var resizeTask: Task<Void, Never>?
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
    @State private var transitionFrame: PlaybackTransitionFrame?

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
        return feedViewport
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
            cancelResize()
            // Our own player cover hides the feed too; keep that presentation alive.
            if playback.route == nil { isVisible = false; playback.cancelPending() }
            fallbackSettle?.cancel(); fallbackSettle = nil
            preview.suspend()
            Task { await preview.saveSession() }
        }
        .onChange(of: isActive) { _, active in
            tabIsActive = active
            if active { activateSource() }
            else { cancelResize(); preview.suspend(); playback.dismiss(); transitionFrame = nil; Task { await preview.saveSession() } }
            refreshEligibility()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { cancelResize(); preview.suspend(); transitionFrame = nil; Task { await preview.saveSession() } }
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
        .onChange(of: model.recommendationPreferences.notInterestedIDs) { _, _ in
            applyNotInterested()
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
        .onChange(of: scrollID) { _, id in
            if let failed = playback.failedSeriesID, id != failed { playback.cancelPending(); transitionFrame = nil }
            refreshEligibility()
        }
        .onChange(of: detailSeries) { _, detail in
            if detail != nil { cancelResize(); requiresManualResume = true; preview.suspend(); playback.cancelPending(); transitionFrame = nil }
            refreshEligibility()
        }
        .onChange(of: showingPreferences) { _, presented in
            if presented { cancelResize(); requiresManualResume = true; preview.suspend(); playback.cancelPending(); transitionFrame = nil }
            refreshEligibility()
        }
        .sheet(isPresented: $showingPreferences) {
            NavigationStack { RecommendationPreferencesView() }
        }
        .navigationDestination(item: $detailSeries) { series in
            DetailView(series: series).toolbar(.visible, for: .navigationBar)
        }
        .onChange(of: playback.route?.id) { _, routeID in
            if routeID != nil { cancelResize(); requiresManualResume = true; preview.suspend() }
            else if playback.preparingSeriesID == nil && playback.pendingChoice == nil { transitionFrame = nil }
            refreshEligibility()
        }
        .overlay { if let choice = playback.pendingChoice { continuationChoice(choice) } }
        .overlay(alignment: .bottom) { followingError }
        .continuePlaybackPresentation(playback, context: playbackContext, bottomOverlayInset: bottomControlInset, transitionFrame: transitionFrame)
    }

    private var feedViewport: some View {
        GeometryReader { geometry in
            resizeAwareFeed(size: geometry.size)
        }
    }

    private func resizeAwareFeed(size: CGSize) -> some View {
        ScrollViewReader { proxy in
            feedContents(size: size)
                .onAppear { viewportSize = size; viewportHeight = max(size.height, 1) }
                .onChange(of: size) { _, newSize in
                    reanchorAfterResize(size: newSize, proxy: proxy)
                }
        }
    }

    @ViewBuilder
    private func feedContents(size: CGSize) -> some View {
        Group {
            if preview.items.isEmpty { emptyFeed }
            else { pagingFeed(size: size) }
        }
    }

    private var feedScrollPosition: Binding<String?> {
        Binding(get: { resizeTargetID ?? scrollID }, set: {
            if resizeTargetID == nil { scrollID = $0 }
        })
    }

    private func pagingFeed(size: CGSize) -> some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(preview.items) { series in
                    feedPage(series, size: size)
                }
            }
            .scrollTargetLayout()
        }
        .coordinateSpace(name: "recommendationFeed")
        .contentMargins(.vertical, 0, for: .scrollContent)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
        .scrollPosition(id: feedScrollPosition, anchor: .top)
        .scrollIndicators(.hidden)
        .modifier(RecommendationFeedScrollPhase(changed: phaseChanged, fallbackDrag: fallbackDragChanged,
            offsetChanged: offsetChanged))
        .onPreferenceChange(RecommendationFeedFrames.self, perform: framesChanged)
    }

    private func feedPage(_ series: Series, size: CGSize) -> some View {
        feedCard(series, resizing: abs(size.height - viewportSize.height) > 2)
            .frame(width: max(size.width, 1), height: max(size.height, 1))
            .clipped()
            .background {
                GeometryReader { card in
                    let frame: CGRect = card.frame(in: .named("recommendationFeed"))
                    let preference: [String: CGRect] = [series.id: frame]
                    Color.clear.preference(key: RecommendationFeedFrames.self, value: preference)
                }
            }
            .id(series.id)
    }

    @ViewBuilder
    private var followingError: some View {
        if let message = playback.errorMessage {
            VStack(alignment: .leading, spacing: 12) {
                Text(message).font(.footnote)
                HStack(spacing: 20) {
                    Spacer(minLength: 0)
                    if playback.canRetry {
                        Button("重試") {
                            guard alignedID == playback.failedSeriesID, phaseIsIdle else { playback.cancelPending(); return }
                            playback.retry()
                        }
                            .disabled(!playbackContext.permitsStart || alignedID != playback.failedSeriesID || !phaseIsIdle)
                            .accessibilityIdentifier("preview.retryFollowing")
                    }
                    Button("關閉") { playback.cancelPending() }
                }.font(.subheadline.weight(.semibold))
            }
            .padding(12).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
            .padding(14).padding(.bottom, max(bottomControlInset, 0))
        }
    }

    private var emptyFeed: some View {
        VStack(spacing: 18) {
            if preview.isLoadingPage {
                ProgressView("正在載入試看片單…").tint(.white)
            } else {
                Text("推薦試看").font(.title2.weight(.semibold))
                Text(preview.pageError ?? "目前沒有符合偏好的劇集，可調整推薦偏好再找找。")
                    .font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
                Button(preview.queue.page > 0 && preview.queue.hasMore ? "繼續找劇" : "重新載入") {
                    activateSource()
                    if preview.queue.hasMore { preview.loadInitial() }
                    else { preview.reloadEmptyCatalogue() }
                }
                    .buttonStyle(.borderedProminent)
            }
            Button("推薦偏好", systemImage: "slider.horizontal.3") { showingPreferences = true }
                .buttonStyle(.bordered)
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func feedCard(_ series: Series, resizing: Bool) -> some View {
        let preservedID = resizeTargetID ?? (resizing ? lastSettledID : nil)
        let canRetainFrame = isVisible && tabIsActive && scenePhase == .active && detailSeries == nil && !showingPreferences && playback.route == nil
            && (intersectsViewport(series.id) || preservedID == series.id)
        let allowsInteraction = !resizing && resizeTargetID == nil && alignedID == series.id && isVisible && tabIsActive
            && scenePhase == .active && detailSeries == nil && !showingPreferences && phaseIsIdle
            && playback.preparingSeriesID == nil && playback.pendingChoice == nil && playback.route == nil
        let sessionContextID = preview.sessionContextID
        return ZStack {
            Poster(series: series, contentMode: .fill).allowsHitTesting(false)
            if let media = preview.media[series.id] {
                RecommendationPreviewMediaCard(series: media.series, episode: media.episode, service: media.service,
                    isActive: !resizing && preview.lease?.seriesID == series.id && effectivePlaybackAllowed,
                    resumeSeconds: media.resumeSeconds,
                    retainsFrame: canRetainFrame, allowsInteraction: allowsInteraction,
                    isFavorite: model.isFavorite(series),
                    onToggleFavorite: { model.toggleFavorite(media.series) },
                    onPlaybackStarted: {
                        guard preview.items.contains(where: { $0.id == series.id }),
                              !model.recommendationPreferences.isNotInterested(seriesID: series.id) else { return }
                        preview.didStartPreview(seriesID: series.id)
                    },
                    onPreviewQualified: {
                        guard preview.items.contains(where: { $0.id == series.id }),
                              !model.recommendationPreferences.isNotInterested(seriesID: series.id) else { return }
                        model.markPreviewed(series)
                    },
                    onPositionSnapshot: { snapshot in
                        preview.rememberPreviewPosition(snapshot, contextID: sessionContextID)
                    },
                    recommendationTitle: model.catalogSource == .website ? model.recommendationPreferences.category.previewTitle : "試看",
                    recommendationReason: recommendationReason(for: series.id),
                    discoverySourceLabel: preview.sourceLabelByID[series.id],
                    bottomControlInset: bottomControlInset,
                    onShowPreferences: { showingPreferences = true },
                    onNotInterested: { hide(series) },
                    onViewDetails: { openEntireSeries(media.series) },
                    onOpenSeries: { snapshot, frame in startFollowing(media.series, snapshot: snapshot, frame: frame) })
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
                    } else if preview.queue.hasMore {
                        Button("載入更多劇集") { preview.loadMoreIfNeeded(force: true) }
                            .font(.caption.weight(.semibold)).padding(10).background(.ultraThinMaterial, in: Capsule())
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
            if let source = preview.sourceLabelByID[series.id] {
                Text(source).font(.caption.weight(.medium)).foregroundStyle(Theme.accent)
                    .accessibilityLabel("推薦來源：\(source)")
            }
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
                    Button("不感興趣", systemImage: "eye.slash") { hide(series) }
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
        resizeTargetID == nil && isVisible && tabIsActive && scenePhase == .active && detailSeries == nil && !showingPreferences && !requiresManualResume && phaseIsIdle
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
        guard let closest = frames.filter({ known.contains($0.key) }).min(by: { abs($0.value.minY) < abs($1.value.minY) }),
              abs(closest.value.minY) <= 2 else { return nil }
        return closest.key
    }

    private func intersectsViewport(_ id: String) -> Bool {
        guard let frame = frames[id] else { return false }
        return frame.maxY > 0 && frame.minY < viewportHeight
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
        cancelResize(); lastSettledID = nil
        playback.dismiss()
        transitionFrame = nil
        fallbackSettle?.cancel(); fallbackSettle = nil
        scrollID = nil; frames = [:]; contentOffset = nil; pendingScrollTarget = nil
        requiresManualResume = showingPreferences
        preview.invalidateSource()
        if tabIsActive { activateSource() }
    }

    private func hide(_ series: Series) {
        model.setNotInterested(series, value: true)
        applyNotInterested(preferredCurrentID: series.id)
    }

    private func applyNotInterested(preferredCurrentID: String? = nil) {
        let change = preview.excludeNotInterested(model.recommendationPreferences,
            preferredCurrentID: preferredCurrentID ?? alignedID ?? scrollID)
        guard !change.removedIDs.isEmpty else { return }
        if let target = resizeTargetID, change.removedIDs.contains(target) { cancelResize() }
        if let settled = lastSettledID, change.removedIDs.contains(settled) { lastSettledID = change.currentID }
        frames = frames.filter { !change.removedIDs.contains($0.key) }
        if change.currentChanged {
            fallbackSettle?.cancel(); fallbackSettle = nil
            pendingScrollTarget = change.currentID
            scrollID = change.currentID
        } else if pendingScrollTarget.map(change.removedIDs.contains) == true {
            pendingScrollTarget = change.currentID
            scrollID = change.currentID
        }
        refreshEligibility()
    }

    private func refreshEligibility() {
        let sourceMatches = preview.revision == model.revision && preview.filterRevision == model.recommendationFilterRevision
            && preview.rankingScope == model.recommendationScope
        let aligned = alignedID
        let commandHasArrived = pendingScrollTarget == nil || pendingScrollTarget == aligned
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-preview-layout-diagnostics") {
            let nearest = frames.values.map(\.minY).min(by: { abs($0) < abs($1) }) ?? -9999
            NSLog("PreviewLayout height=%.2f offset=%.2f nearest=%.2f idle=%d pending=%d aligned=%d",
                  Double(viewportHeight), Double(contentOffset ?? -9999), Double(nearest),
                  phaseIsIdle ? 1 : 0, pendingScrollTarget == nil ? 0 : 1,
                  aligned.flatMap { id in preview.items.firstIndex(where: { $0.id == id }) } ?? -1)
            if let target = resizeTargetID {
                let frame = frames[target] ?? .zero
                NSLog("PreviewResize viewport=%.2fx%.2f page=%.2fx%.2f top=%.2f",
                      Double(viewportSize.width), Double(viewportSize.height), Double(frame.width), Double(frame.height), Double(frame.minY))
            }
        }
        #endif
        if commandHasArrived, resizeTargetID == nil { pendingScrollTarget = nil }
        if resizeTargetID == nil, commandHasArrived, phaseIsIdle, tabIsActive, isVisible, let aligned,
           resizeFrameAligned(aligned) {
            lastSettledID = aligned
        }
        preview.update(selectedID: commandHasArrived && resizeTargetID == nil ? aligned : nil, isIdle: phaseIsIdle,
            isActive: isVisible && tabIsActive && sourceMatches && !showingPreferences && !requiresManualResume
                && playback.route == nil && playback.pendingChoice == nil && playback.preparingSeriesID == nil,
            isSceneActive: scenePhase == .active, isDetailPresented: detailSeries != nil)
    }

    private func phaseChanged(_ idle: Bool, _ userInitiated: Bool) {
        if userInitiated { cancelResize() }
        phaseIsIdle = idle
        fallbackDragging = userInitiated
        if userInitiated { pendingScrollTarget = nil }
        if userInitiated, detailSeries == nil { requiresManualResume = false }
        if idle || userInitiated { fallbackSettle?.cancel(); fallbackSettle = nil }
        refreshEligibility()
        if !idle, !userInitiated, resizeTargetID == nil { scheduleFallbackSettle() }
    }

    private func framesChanged(_ next: [String: CGRect]) {
        frames = next
        if let target = resizeTargetID {
            if phaseIsIdle, !fallbackDragging, resizeFrameAligned(target) { finishResize(target) }
            else { refreshEligibility() }
            return
        }
        if #available(iOS 18.0, *) {
            refreshEligibility()
        }
        else { scheduleFallbackSettle() }
    }

    private func offsetChanged(_ offset: CGFloat) {
        contentOffset = offset
        refreshEligibility()
        if !phaseIsIdle, !fallbackDragging, resizeTargetID == nil { scheduleFallbackSettle() }
    }

    private func fallbackDragChanged(_ dragging: Bool) {
        fallbackDragging = dragging
        if dragging {
            cancelResize()
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

    private func reanchorAfterResize(size: CGSize, proxy: ScrollViewProxy) {
        viewportSize = size; viewportHeight = max(size.height, 1)
        let ids = Set(preview.items.map(\.id))
        guard tabIsActive, isVisible, scenePhase == .active, detailSeries == nil, !showingPreferences,
              playback.route == nil,
              let target = [resizeTargetID, lastSettledID, preview.current?.id, scrollID].compactMap({ $0 }).first(where: ids.contains) else {
            refreshEligibility(); return
        }
        resizeTask?.cancel(); fallbackSettle?.cancel(); fallbackSettle = nil
        let request = UUID(); resizeGeneration = request; resizeTargetID = target
        pendingScrollTarget = target; phaseIsIdle = false; fallbackDragging = false
        preview.beginPaging(); refreshEligibility()
        resizeTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(100))
                for _ in 0..<3 {
                    guard !Task.isCancelled, resizeGeneration == request, resizeTargetID == target else { return }
                    var transaction = Transaction(); transaction.disablesAnimations = true
                    withTransaction(transaction) { scrollID = target; proxy.scrollTo(target, anchor: .top) }
                    var alignedSamples = 0
                    for _ in 0..<8 {
                        try await Task.sleep(for: .milliseconds(50))
                        guard !Task.isCancelled, resizeGeneration == request, resizeTargetID == target else { return }
                        alignedSamples = resizeFrameAligned(target) && !fallbackDragging ? alignedSamples + 1 : 0
                        if alignedSamples >= 2 { finishResize(target); return }
                    }
                }
                // Stop issuing scroll commands. A late aligned frame can still finish,
                // and an explicit drag cancels this recovery without changing pause intent.
                if resizeGeneration == request { resizeTask = nil; phaseIsIdle = true; refreshEligibility() }
            } catch { }
        }
    }

    private func resizeFrameAligned(_ id: String) -> Bool {
        guard let frame = frames[id] else { return false }
        // Native Duo bars can leave a small width difference between the outer
        // geometry and scroll content. Vertical paging depends on top and height.
        return abs(frame.minY) <= 2 && abs(frame.height - viewportSize.height) <= 2
    }

    private func finishResize(_ target: String) {
        guard resizeTargetID == target else { return }
        resizeTask?.cancel(); resizeTask = nil; resizeTargetID = nil
        if pendingScrollTarget == target { pendingScrollTarget = nil }
        phaseIsIdle = true; fallbackDragging = false; scrollID = target; lastSettledID = target
        refreshEligibility()
    }

    private func cancelResize() {
        resizeGeneration = UUID(); resizeTask?.cancel(); resizeTask = nil
        if let target = resizeTargetID {
            if pendingScrollTarget == target { pendingScrollTarget = nil }
            phaseIsIdle = true; fallbackDragging = false
        }
        resizeTargetID = nil
    }

    private func scroll(by offset: Int, from id: String) {
        cancelResize()
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
        preview.beginPaging(toward: preview.items[index + offset].id)
        withAnimation { scrollID = preview.items[index + offset].id }
    }

    private func openEntireSeries(_ series: Series) {
        requiresManualResume = true
        preview.suspend()
        detailSeries = series
    }

    private func startFollowing(_ series: Series, snapshot: PreviewPlaybackSnapshot, frame: PlaybackTransitionFrame?) {
        guard playbackContext.permitsStart, alignedID == series.id, phaseIsIdle,
              snapshot.seriesID == series.id, playback.route == nil,
              playback.preparingSeriesID == nil, playback.pendingChoice == nil else { return }
        transitionFrame = frame
        requiresManualResume = true; preview.suspend()
        Task { await preview.saveSession() }
        do {
            playback.start(series: series, selection: .preview(snapshot), context: playbackContext,
                service: try model.playbackService(), currentContext: { playbackContext },
                latestRecord: { model.record(for: series) },
                progressFactory: { detail in model.playbackProgressHandler(for: detail.series, episodes: detail.episodes) })
        } catch { transitionFrame = nil; playback.fail(error, seriesID: series.id) }
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
              footer: { Text("實際播放累計 10 秒才記住；短片依片長調整，暫停或滑動不計。試看標記只存在這部 iPhone，不會加入或清除正式觀看紀錄。") }
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
