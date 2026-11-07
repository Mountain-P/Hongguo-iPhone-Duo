import AVFoundation
import HongguoCore
import SwiftUI
import UIKit

@MainActor
struct PlayerScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var model: PlayerModel
    @StateObject private var prefetchNetworkPolicy = PlaybackPrefetchNetworkPolicy()
    private let onClose: (() -> Void)?
    private let onSeriesSwipe: ((Int) -> Void)?
    private let isPreview: Bool
    private let onOpenSeries: (() -> Void)?
    @State private var showingEpisodes = false
    @State private var controlsVisible = true
    // A new preference version applies the fill-first default once to existing
    // installs. Subsequent manual fit/fill choices remain persistent.
    @AppStorage("playerFillsScreen.v2") private var fillsScreen = true
    @State private var isScrubbing = false
    @State private var scrubPosition: Double = 0
    @State private var hideTask: Task<Void, Never>?
    @GestureState private var holdingBoost = false
    @State private var boostStarted = false
    @State private var boostCommitted = false
    @State private var boostStartedLocked = false
    @State private var suppressBoostUntilRelease = false
    @State private var lastBoostEndAt = Date.distantPast
    @State private var lastHoverRevealAt = Date.distantPast
    @State private var lastHoverLocation: CGPoint?

    init(series: Series, episodes: [Episode], initialEpisodeID: String, resumeSeconds: Double,
         service: any CatalogService, onProgress: @escaping (Episode, Double, Double) -> Void,
         onClose: (() -> Void)? = nil, onSeriesSwipe: ((Int) -> Void)? = nil,
         isPreview: Bool = false, onOpenSeries: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onSeriesSwipe = onSeriesSwipe
        self.isPreview = isPreview
        self.onOpenSeries = onOpenSeries
        _model = StateObject(wrappedValue: PlayerModel(series: series, episodes: episodes,
            initialEpisodeID: initialEpisodeID, resumeSeconds: resumeSeconds, service: service,
            onProgress: onProgress, isPreview: isPreview))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Only the media canvas ignores native bar/container insets.
                // Its picture frame stays unchanged as the controls appear.
                GeometryReader { geometry in
                    let region = viewingRegion(geometry)
                    ZStack(alignment: .topLeading) {
                        Color.black
                        NativePlayerSurface(player: model.player, fillsScreen: fillsScreen,
                            onReadyForDisplayChange: { if $0 { model.recordFirstFrame() } })
                            .frame(width: region.width, height: region.height)
                            .clipped()
                            .position(x: region.midX, y: region.midY)
                        videoTouchSurface
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .onContinuousHover(coordinateSpace: .global, perform: updateHover)
                    .onHover { inside in
                        if !inside { scheduleAutoHide() }
                    }
                }
                .ignoresSafeArea(.container)

                // Foreground information follows the system-provided safe area,
                // independently of the full-bleed picture behind the native bars.
                GeometryReader { geometry in
                    let region = viewingRegion(geometry)
                    ZStack(alignment: .topLeading) {
                        floatingInformation(in: region)
                            .opacity(controlsVisible ? 1 : 0)
                            .allowsHitTesting(controlsVisible)
                            .accessibilityHidden(!controlsVisible)
                        statusOverlay
                            .frame(width: region.width, height: region.height)
                            .position(x: region.midX, y: region.midY)
                        centralPlaybackControl
                            .position(x: region.midX, y: region.midY)
                        VStack {
                            speedBoostHint.padding(.top, 12)
                            Spacer(minLength: 0)
                        }
                        .frame(width: region.width, height: region.height)
                        .position(x: region.midX, y: region.midY)
                        .allowsHitTesting(model.isSpeedBoostLocked)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .background { Color.black.ignoresSafeArea() }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { playerToolbar }
            // System bars overlay the picture; their axis/placement stays native.
            .toolbarBackground(.hidden, for: .navigationBar, .bottomBar)
            .toolbar(controlsVisible ? .visible : .hidden, for: .navigationBar, .bottomBar)
        }
        .background { Color.black.ignoresSafeArea() }
        .foregroundStyle(.white)
        .tint(.white)
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .task {
            if isPreview { model.setAutoNext(false) }
            model.setPrefetchNetworkAllowed(!isPreview && prefetchNetworkPolicy.allowsPrefetch)
            model.setSceneActive(scenePhase == .active)
            model.start()
        }
        .onDisappear {
            hideTask?.cancel()
            endBoostGesture()
            model.stop()
            Task { await appModel.flushLibrary() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.setSceneActive(phase == .active)
            if phase != .active { cancelBoostGesture(); showControls() }
        }
        .onChange(of: model.isPlaying) { _, _ in scheduleAutoHide() }
        .onChange(of: prefetchNetworkPolicy.allowsPrefetch) { _, allowed in
            model.setPrefetchNetworkAllowed(!isPreview && allowed)
        }
        .onChange(of: model.canPausePlayback) { _, canPause in
            if !canPause { Task { await appModel.flushLibrary() } }
        }
        .onChange(of: model.isLoading) { _, loading in
            if loading { cancelBoostGesture() }
            scheduleAutoHide()
        }
        .onChange(of: model.isBuffering) { _, _ in scheduleAutoHide() }
        .onChange(of: model.errorMessage) { _, _ in showControls() }
        .onChange(of: showingEpisodes) { _, _ in showControls() }
        .onChange(of: voiceOverEnabled) { _, _ in showControls() }
        .onChange(of: holdingBoost) { _, holding in
            if !holding {
                if boostStarted { endBoostGesture() }
                suppressBoostUntilRelease = false
            }
        }
        .sheet(isPresented: $showingEpisodes) { episodePicker }
    }

    @ToolbarContentBuilder
    private var playerToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                model.pauseAndSave()
                if let onClose { onClose() }
                else { dismiss() }
            } label: { Label("關閉", systemImage: "chevron.down") }
        }
        if isPreview, let onOpenSeries {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    cancelBoostGesture()
                    model.pauseAndSave()
                    onOpenSeries()
                } label: { Label("看整部", systemImage: "play.rectangle") }
                    .accessibilityIdentifier("player.openSeries")
            }
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { model.skip(-10); showControls() } label: { Label("後退十秒", systemImage: "gobackward.10") }
                .disabled(model.isLoading || model.duration <= 0)
            Button { model.skip(10); showControls() } label: { Label("前進十秒", systemImage: "goforward.10") }
                .disabled(model.isLoading || model.duration <= 0)
            speedMenu
            Button {
                fillsScreen.toggle()
                showControls()
            } label: {
                Label(fillsScreen ? "顯示完整畫面" : "填滿螢幕",
                      systemImage: fillsScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityValue(fillsScreen ? "等比填滿" : "完整比例")
            if !isPreview { moreMenu }
        }
    }

    private var speedMenu: some View {
        Menu {
            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                Button {
                    cancelBoostGesture()
                    model.selectSpeed(rate)
                    showControls()
                } label: {
                    if model.effectiveSpeed == rate {
                        Label(String(format: "%g×", Double(rate)), systemImage: "checkmark")
                    } else { Text(String(format: "%g×", Double(rate))) }
                }
            }
        } label: { Label("播放速度", systemImage: "speedometer") }
            .accessibilityValue(String(format: "%g 倍速", Double(model.effectiveSpeed)))
            .simultaneousGesture(TapGesture().onEnded { showControls() })
    }

    private var moreMenu: some View {
        Menu {
            Button {
                showingEpisodes = true
                showControls()
            } label: { Label("選集", systemImage: "square.grid.2x2") }
            Button {
                model.playNext()
                showControls()
            } label: { Label("下一集", systemImage: "forward.end.fill") }
                .disabled(model.nextEpisode == nil)
            Toggle("自動播放下一集", isOn: Binding(get: { model.autoNext }, set: {
                model.setAutoNext($0)
                showControls()
            }))
        } label: { Label("更多", systemImage: "ellipsis") }
            .simultaneousGesture(TapGesture().onEnded { showControls() })
    }

    private func viewingRegion(_ geometry: GeometryProxy) -> CGRect {
        let bounds = CGRect(origin: .zero, size: geometry.size)
        guard #available(iOS 27.1, *) else { return bounds }
        func expanded(_ frame: CGRect, margins: EdgeInsets) -> CGRect {
            CGRect(x: frame.minX - margins.leading, y: frame.minY - margins.top,
                   width: frame.width + margins.leading + margins.trailing,
                   height: frame.height + margins.top + margins.bottom)
        }
        let folds = geometry.reservedRegions(kind: .division).filter(\.isActive).map { expanded($0.frame, margins: $0.margins) }
        let cameras = geometry.reservedRegions(kind: .occlusion).filter(\.isActive).map { expanded($0.frame, margins: $0.margins) }
        let aspect = model.videoAspectRatio.isFinite && model.videoAspectRatio > 0 ? model.videoAspectRatio : 9 / 16
        var region = PlayerViewingRegion.best(in: bounds, avoiding: folds, aspect: aspect, anchor: CGPoint(x: bounds.midX, y: bounds.midY))
        let renderedFrame = fillsScreen ? region : PlayerViewingRegion.fit(region, aspect: aspect)
        if cameras.contains(where: { $0.intersects(renderedFrame) }) {
            region = PlayerViewingRegion.best(in: region, avoiding: cameras, aspect: aspect, anchor: CGPoint(x: region.midX, y: region.midY))
        }
        return region
    }

    private func floatingInformation(in region: CGRect) -> some View {
        let compact = region.height < 400
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            informationPanel(compact: compact)
                .frame(maxWidth: 560)
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.bottom, compact ? 8 : 12)
        }
        .frame(width: region.width, height: region.height, alignment: .bottom)
        .position(x: region.midX, y: region.midY)
    }

    @ViewBuilder
    private func informationPanel(compact: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: compact ? 16 : 20, style: .continuous)
        let content = footer(compact: compact)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.top, compact ? 8 : 10)
            .padding(.bottom, compact ? 4 : 6)
        if reduceTransparency {
            content
                .background(Color(white: 0.12), in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    private func footer(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.series.title)
                    .font((compact ? Font.caption : .subheadline).weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let episode = model.currentEpisode {
                    Text("第 \(episode.number) 集")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            HStack(spacing: 8) {
                Text(timeLabel(isScrubbing ? scrubPosition : model.elapsed))
                    .frame(minWidth: 34, alignment: .leading)
                    .accessibilityLabel("已播放 \(timeLabel(model.elapsed))")
                Slider(value: Binding(get: {
                    min(max(isScrubbing ? scrubPosition : model.elapsed, 0), max(model.duration, 1))
                }, set: { scrubPosition = $0 }), in: 0...max(model.duration, 1), onEditingChanged: { editing in
                    if editing { scrubPosition = model.elapsed }
                    isScrubbing = editing
                    if !editing { model.seek(to: scrubPosition) }
                    showControls()
                })
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .tint(Theme.accent)
                .disabled(model.isLoading || model.duration <= 0)
                .accessibilityLabel("播放進度")
                .accessibilityValue("\(timeLabel(model.elapsed))，共 \(timeLabel(model.duration))")
                Text(timeLabel(model.duration))
                    .frame(minWidth: 34, alignment: .trailing)
                    .accessibilityLabel("總長 \(timeLabel(model.duration))")
            }
            .font(.caption.monospacedDigit())
            .frame(minHeight: 44)
            if isPreview, onSeriesSwipe != nil {
                Text("上滑看下一部").font(.caption2).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity).padding(.bottom, 5)
            }
        }
    }

    @ViewBuilder
    private var videoTouchSurface: some View {
        let touch = Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                guard !boostStarted, Date().timeIntervalSince(lastBoostEndAt) > 0.25 else { return }
                toggleControlsVisibility()
            }
            .simultaneousGesture(speedBoostGesture)
            .simultaneousGesture(seriesSwipeGesture)
            .accessibilityLabel("影片")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { showControls() }
            .accessibilityAction(named: Text("顯示播放控制")) { showControls() }
            .accessibilityAction(named: Text(model.canPausePlayback ? "暫停" : "播放")) {
                togglePlaybackFromUser()
            }
            .accessibilityAction(named: Text(model.isSpeedBoostLocked ? "解除 2 倍速鎖定" : "鎖定 2 倍速")) {
                cancelBoostGesture()
                if model.isSpeedBoostLocked { model.unlockSpeedBoost() }
                else { model.lockSpeedBoost() }
                showControls()
            }
        if onSeriesSwipe != nil {
            touch
                .accessibilityAction(named: Text("下一部推薦")) { onSeriesSwipe?(1) }
                .accessibilityAction(named: Text("上一部推薦")) { onSeriesSwipe?(-1) }
        } else { touch }
    }

    private var seriesSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { value in
            guard let onSeriesSwipe, !boostStarted,
                  Date().timeIntervalSince(lastBoostEndAt) > 0.25,
                  abs(value.translation.height) > 90,
                  abs(value.translation.height) > abs(value.translation.width) * 1.2 else { return }
            onSeriesSwipe(value.translation.height < 0 ? 1 : -1)
        }
    }

    private func updateHover(_ phase: HoverPhase) {
        switch phase {
        case .active(let location):
            // Global coordinates stay stable as native bars resize the safe
            // viewport. Only actual pointer movement reveals the controls.
            if let previous = lastHoverLocation {
                let dx = location.x - previous.x, dy = location.y - previous.y
                guard dx * dx + dy * dy >= 9 else { return }
            }
            let now = Date()
            guard now.timeIntervalSince(lastHoverRevealAt) >= 0.15 else { return }
            lastHoverLocation = location
            lastHoverRevealAt = now
            showControls()
        case .ended:
            scheduleAutoHide()
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if model.isLoading || model.isBuffering {
            ProgressView(model.isLoading ? "正在準備影片…" : "影片緩衝中…")
                .padding(20)
                .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 16))
                .offset(y: model.isBuffering && !model.isLoading ? -80 : 0)
                .allowsHitTesting(false)
        }
        if let message = model.errorMessage {
            VStack(spacing: 18) {
                Image(systemName: "play.slash.fill").font(.largeTitle)
                Text(message).multilineTextAlignment(.center).font(.callout)
                Button("重新載入") {
                    model.retry()
                    showControls()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                if !isPreview {
                    Button("選擇其他集數") { showingEpisodes = true }.buttonStyle(.bordered)
                }
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 20))
            .padding()
        }
    }

    private func togglePlaybackFromUser() {
        cancelBoostGesture()
        model.togglePlayback()
        showControls()
    }

    @ViewBuilder
    private var centralPlaybackControl: some View {
        if !model.isLoading, model.errorMessage == nil, model.duration > 0,
           controlsVisible || !model.canPausePlayback {
            let button = Button(action: togglePlaybackFromUser) {
                Image(systemName: model.canPausePlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 68, height: 68)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.canPausePlayback ? "暫停" : "播放")
            .accessibilityIdentifier("player.centerPlayPause")
            if reduceTransparency {
                button.background(Color(white: 0.12), in: Circle())
            } else if #available(iOS 26.0, *) {
                button.glassEffect(.regular.interactive(), in: Circle())
            } else {
                button.background(.ultraThinMaterial, in: Circle())
            }
        }
    }

    private func showControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        scheduleAutoHide()
    }

    private func toggleControlsVisibility() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard controlsVisible, model.isPlaying, !model.isLoading, !model.isBuffering, model.errorMessage == nil,
              !showingEpisodes, !isScrubbing, !voiceOverEnabled, !boostStarted, scenePhase == .active else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        }
    }

    private var speedBoostGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.35, maximumDistance: 28)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holdingBoost) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag) = value,
                      !suppressBoostUntilRelease,
                      !model.isLoading, model.errorMessage == nil, model.duration > 0 else { return }
                if !boostStarted {
                    boostStarted = true
                    boostCommitted = false
                    boostStartedLocked = model.isSpeedBoostLocked
                    showControls()
                    model.beginSpeedBoost()
                }
                guard !boostCommitted, let drag else { return }
                if !boostStartedLocked, drag.translation.height <= -60 {
                    model.lockSpeedBoost()
                    boostCommitted = true
                } else if boostStartedLocked, drag.translation.height >= 60 {
                    model.unlockSpeedBoost()
                    model.endSpeedBoost()
                    boostCommitted = true
                }
            }
            .onEnded { _ in endBoostGesture(); suppressBoostUntilRelease = false }
    }

    private func cancelBoostGesture() {
        if holdingBoost || boostStarted { suppressBoostUntilRelease = true }
        endBoostGesture()
    }

    private func endBoostGesture() {
        if boostStarted { lastBoostEndAt = Date() }
        model.endSpeedBoost()
        boostStarted = false
        boostCommitted = false
        if controlsVisible { scheduleAutoHide() }
    }

    @ViewBuilder
    private var speedBoostHint: some View {
        if model.isSpeedBoostLocked {
            Button {
                cancelBoostGesture()
                model.unlockSpeedBoost()
                showControls()
            } label: {
                Label("2 倍速已鎖定 · 長按下滑解除", systemImage: "lock.fill")
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("解除 2 倍速鎖定")
            .padding(.horizontal, 16)
        } else if model.isSpeedBoosting {
            Text("2 倍速 · 上滑鎖定")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.updatesFrequently)
        }
    }

    private func timeLabel(_ value: Double) -> String {
        let seconds = value.isFinite ? max(0, Int(value)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private var episodePicker: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 12)], spacing: 12) {
                    ForEach(model.episodes) { episode in
                        Button {
                            model.select(episode)
                            showingEpisodes = false
                        } label: {
                            VStack(spacing: 5) {
                                Text("\(episode.number)").font(.headline)
                                if !episode.isAvailable { Image(systemName: "lock.fill").font(.caption2) }
                            }
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .foregroundStyle(episode.isAvailable ? Color.white : Theme.muted)
                            .background(model.currentEpisode?.id == episode.id ? Theme.accent : Color.white.opacity(0.08),
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .disabled(!episode.isAvailable)
                        .accessibilityLabel("第 \(episode.number) 集\(episode.isAvailable ? "" : "，來源未提供")")
                    }
                }
                .padding(20)
                Text("播放依來源當次提供的影片為準。")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
            }
            .navigationTitle(model.series.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingEpisodes = false } label: { Label("完成", systemImage: "checkmark") }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

@MainActor
struct NativePlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let fillsScreen: Bool
    var onReadyForDisplayChange: ((Bool) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerSurface {
        let view = PlayerLayerSurface()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        view.clipsToBounds = true
        view.playerLayer.player = player
        view.playerLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        context.coordinator.observe(view.playerLayer, player: player, callback: onReadyForDisplayChange)
        return view
    }

    func updateUIView(_ view: PlayerLayerSurface, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
            context.coordinator.observe(view.playerLayer, player: player, callback: onReadyForDisplayChange)
        } else { context.coordinator.update(callback: onReadyForDisplayChange) }
        view.playerLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
    }

    static func dismantleUIView(_ view: PlayerLayerSurface, coordinator: Coordinator) {
        coordinator.invalidate()
        view.playerLayer.player = nil
    }

    @MainActor
    final class Coordinator {
        private var readyObservation: NSKeyValueObservation?
        private var itemObservation: NSKeyValueObservation?
        private var callback: ((Bool) -> Void)?
        private weak var layer: AVPlayerLayer?
        private weak var observedItem: AVPlayerItem?
        private var generation = UUID()
        private var itemGeneration = UUID()
        private var lastReady: Bool?

        func observe(_ layer: AVPlayerLayer, player: AVPlayer, callback: ((Bool) -> Void)?) {
            invalidate()
            self.layer = layer
            self.callback = callback
            let token = generation
            bindReadiness(to: player.currentItem, layer: layer, token: token)
            itemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
                let item = player.currentItem
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token,
                          let layer = self.layer, layer.player?.currentItem === item else { return }
                    self.bindReadiness(to: item, layer: layer, token: token)
                }
            }
        }

        private func bindReadiness(to item: AVPlayerItem?, layer: AVPlayerLayer, token: UUID) {
            readyObservation?.invalidate()
            itemGeneration = UUID()
            let itemToken = itemGeneration
            observedItem = item
            // Deliver state outside UIViewRepresentable's update transaction.
            readyObservation = layer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == token, self.itemGeneration == itemToken,
                          self.observedItem === item, let layer = self.layer,
                          layer.player?.currentItem === item else { return }
                    // Query the current layer instead of delivering an older captured ready bit.
                    self.report(item != nil && layer.isReadyForDisplay)
                }
            }
        }

        func update(callback: ((Bool) -> Void)?) { self.callback = callback }

        func invalidate() {
            generation = UUID(); itemGeneration = UUID()
            readyObservation?.invalidate(); readyObservation = nil
            itemObservation?.invalidate(); itemObservation = nil
            callback = nil; layer = nil; observedItem = nil; lastReady = nil
        }

        private func report(_ ready: Bool) {
            guard lastReady != ready else { return }
            lastReady = ready
            callback?(ready)
        }
    }
}

@MainActor
final class PlayerLayerSurface: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}





/// Only the picture avoids active fold/camera regions. Native containers place all bars.
enum PlayerViewingRegion {
    static func fit(_ rect: CGRect, aspect: CGFloat) -> CGRect {
        let width = max(0, min(rect.width, rect.height * aspect))
        let height = width / aspect
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    static func best(in bounds: CGRect, avoiding obstacles: [CGRect], aspect: CGFloat, anchor: CGPoint) -> CGRect {
        let regions = obstacles.reduce([bounds]) { regions, obstacle in
            regions.flatMap { region -> [CGRect] in
                let blocked = region.intersection(obstacle)
                guard !blocked.isNull, blocked.width > 0, blocked.height > 0 else { return [region] }
                return [
                    CGRect(x: region.minX, y: region.minY, width: blocked.minX - region.minX, height: region.height),
                    CGRect(x: blocked.maxX, y: region.minY, width: region.maxX - blocked.maxX, height: region.height),
                    CGRect(x: region.minX, y: region.minY, width: region.width, height: blocked.minY - region.minY),
                    CGRect(x: region.minX, y: blocked.maxY, width: region.width, height: region.maxY - blocked.maxY)
                ].filter { $0.width > 1 && $0.height > 1 }
            }
        }
        func score(_ candidate: CGRect) -> CGFloat {
            let image = fit(candidate, aspect: aspect)
            let dx = image.midX - anchor.x, dy = image.midY - anchor.y
            return image.width * image.height - (dx * dx + dy * dy) * 0.15
        }
        return regions.max { score($0) < score($1) } ?? bounds
    }
}
