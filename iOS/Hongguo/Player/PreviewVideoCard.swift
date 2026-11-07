// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import HongguoCore
import SwiftUI

/// An inline first-episode preview. The pager owns which settled card is active.
@MainActor
struct RecommendationPreviewMediaCard: View {
    let series: Series
    let episode: Episode
    let service: any CatalogService
    let isActive: Bool
    var retainsFrame: Bool = false
    var allowsInteraction: Bool = true
    let onOpenSeries: () -> Void

    var body: some View {
        PreviewVideoContent(series: series, episode: episode, service: service,
                            isActive: isActive, retainsFrame: retainsFrame,
                            allowsInteraction: allowsInteraction, onOpenSeries: onOpenSeries)
            .id(Identity(seriesID: series.id, episodeID: episode.id))
    }

    private struct Identity: Hashable {
        let seriesID: String
        let episodeID: String
    }
}

@MainActor
private struct PreviewVideoContent: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @StateObject private var model: PlayerModel
    let isActive: Bool
    let retainsFrame: Bool
    let allowsInteraction: Bool
    let onOpenSeries: () -> Void
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var holdingBoost = false
    @State private var boostStarted = false
    @State private var suppressBoostUntilRelease = false
    @State private var ownerID = UUID()
    @State private var suspendedForPaging = false
    @State private var resumeAfterPaging = false
    @State private var lastBoostEndAt = Date.distantPast

    init(series: Series, episode: Episode, service: any CatalogService,
         isActive: Bool, retainsFrame: Bool, allowsInteraction: Bool, onOpenSeries: @escaping () -> Void) {
        self.isActive = isActive
        self.retainsFrame = retainsFrame
        self.allowsInteraction = allowsInteraction
        self.onOpenSeries = onOpenSeries
        _model = StateObject(wrappedValue: PlayerModel(series: series, episodes: [episode],
            initialEpisodeID: episode.id, resumeSeconds: 0, service: service,
            onProgress: { _, _, _ in }))
    }

    var body: some View {
        GeometryReader { geometry in
            let region = viewingRegion(geometry)
            ZStack(alignment: .topLeading) {
                Color.black
                ZStack {
                    Poster(series: model.series, contentMode: .fill)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    NativePlayerSurface(player: model.player, fillsScreen: true)
                        .opacity(model.player.currentItem != nil && !model.isLoading && model.errorMessage == nil ? 1 : 0)
                    touchSurface
                    if isActive, controlsVisible || !model.canPausePlayback {
                        centerControl
                    }
                    status.accessibilityHidden(!isActive)
                    VStack {
                        HStack {
                            if model.isSpeedBoosting {
                                glass(Text("2 倍速").font(.caption.weight(.semibold))
                                    .padding(.horizontal, 14).frame(minHeight: 44), in: Capsule())
                                .allowsHitTesting(false)
                            }
                            Spacer(minLength: 0)
                            speedMenu.accessibilityHidden(!isActive)
                        }
                        Spacer(minLength: 12)
                        footer
                    }
                    .padding(region.height < 400 ? 12 : 20)
                }
                .frame(width: region.width, height: region.height)
                .clipped()
                .position(x: region.midX, y: region.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(.black)
        .foregroundStyle(.white)
        .accessibilityHidden(!allowsInteraction)
        .task { synchronizeActivation() }
        .onChange(of: isActive) { _, _ in synchronizeActivation() }
        .onChange(of: retainsFrame) { _, _ in synchronizeActivation() }
        .onChange(of: scenePhase) { _, _ in synchronizeActivation() }
        .onChange(of: model.isPlaying) { _, _ in revealControls() }
        .onChange(of: model.isBuffering) { _, _ in revealControls() }
        .onChange(of: model.errorMessage) { _, _ in revealControls() }
        .onChange(of: voiceOverEnabled) { _, _ in revealControls() }
        .onDisappear { deactivate() }
    }

    private var touchSurface: some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture {
                guard allowsInteraction, isActive, !boostStarted,
                      Date().timeIntervalSince(lastBoostEndAt) > 0.25 else { return }
                togglePlayback()
            }
            // Keep the recognizer tree stable throughout a scroll. This hold
            // has no DragGesture that could compete with the parent's paging.
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 18, pressing: { pressing in
                holdingBoost = pressing
                if !pressing { endBoost(); suppressBoostUntilRelease = false }
            }, perform: {
                guard allowsInteraction, isActive, holdingBoost, !boostStarted,
                      !suppressBoostUntilRelease, scenePhase == .active, !model.isLoading,
                      model.errorMessage == nil, model.duration > 0 else { return }
                boostStarted = true
                hideTask?.cancel()
                model.beginSpeedBoost()
            })
            .accessibilityLabel("第 1 集試看影片")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text(model.canPausePlayback ? "暫停" : "播放"), togglePlayback)
            .accessibilityAction(named: Text("看整部"), openSeries)
            .accessibilityHidden(!isActive)
    }

    @ViewBuilder
    private var centerControl: some View {
        if !model.isLoading, model.errorMessage == nil, model.duration > 0 {
            glass(Button(action: togglePlayback) {
                Image(systemName: model.canPausePlayback ? "pause.fill" : "play.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 68, height: 68).contentShape(Circle())
            }.buttonStyle(.plain)
                .accessibilityLabel(model.canPausePlayback ? "暫停" : "播放")
                .accessibilityIdentifier("preview.playPause"), in: Circle())
        }
    }

    private var speedMenu: some View {
        glass(Menu {
            ForEach([Float(0.75), 1, 1.25, 1.5, 2], id: \.self) { rate in
                Button {
                    guard allowsInteraction, isActive else { return }
                    cancelBoost()
                    model.selectSpeed(rate)
                    revealControls()
                } label: {
                    if model.effectiveSpeed == rate {
                        Label(String(format: "%g×", Double(rate)), systemImage: "checkmark")
                    } else { Text(String(format: "%g×", Double(rate))) }
                }
            }
        } label: {
            Label(String(format: "%g×", Double(model.effectiveSpeed)), systemImage: "speedometer")
                .font(.caption.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
        }
        .accessibilityLabel("播放速度")
        .accessibilityValue(String(format: "%g 倍速", Double(model.effectiveSpeed)))
        .disabled(!isActive), in: Capsule())
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.series.title).font(.headline).lineLimit(2)
                    Text("第 1 集試看 · 上滑看下一部").font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                glass(Button(action: openSeries) {
                    Label("看整部", systemImage: "play.rectangle")
                        .font(.subheadline.weight(.semibold)).fixedSize()
                        .padding(.horizontal, 16).frame(minHeight: 46)
                }.buttonStyle(.plain).accessibilityIdentifier("preview.openSeries"), in: Capsule())
            }
            if model.duration > 0 {
                ProgressView(value: min(max(model.elapsed, 0), model.duration), total: model.duration)
                    .tint(.white.opacity(0.8)).allowsHitTesting(false)
                    .accessibilityLabel("第一集播放進度")
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        if model.isLoading || model.isBuffering {
            glass(ProgressView(model.isLoading ? "正在準備試看…" : "影片緩衝中…")
                .font(.caption).tint(.white).padding(16), in: RoundedRectangle(cornerRadius: 16))
                .offset(y: model.isBuffering && !model.isLoading ? -80 : 0)
                .allowsHitTesting(false)
        } else if let error = model.errorMessage {
            glass(VStack(spacing: 14) {
                Text(error).font(.callout).multilineTextAlignment(.center).lineLimit(4)
                Button("重新試看") {
                    guard allowsInteraction, isActive else { return }
                    model.retry(); revealControls()
                }
                    .buttonStyle(.bordered).disabled(!isActive)
                Text("也可以上滑看下一部").font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 300), in: RoundedRectangle(cornerRadius: 20))
            .padding(20)
        }
    }

    @ViewBuilder
    private func glass<Content: View, S: Shape>(_ content: Content, in shape: S) -> some View {
        if reduceTransparency {
            content.background(Color(white: 0.12), in: shape)
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: shape)
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }

    private func synchronizeActivation() {
        guard !Task.isCancelled else { return }
        guard scenePhase == .active else { deactivate(); return }
        guard isActive else {
            if retainsFrame { pauseRetainingFrame() }
            else { deactivate() }
            return
        }
        let shouldResume = suspendedForPaging && resumeAfterPaging
        suspendedForPaging = false
        resumeAfterPaging = false
        PreviewPlaybackOwner.acquire(ownerID, model: model)
        model.autoNext = false
        model.setSceneActive(true)
        model.start()
        if shouldResume, !model.canPausePlayback { model.togglePlayback() }
        revealControls()
    }

    private func pauseRetainingFrame() {
        guard PreviewPlaybackOwner.isOwner(ownerID) else { return }
        // With no decoded frame yet, cancellation is preferable to continuing
        // the initial network request while the user scrolls elsewhere.
        guard !model.isLoading else { deactivate(); return }
        if !suspendedForPaging {
            resumeAfterPaging = model.canPausePlayback
            suspendedForPaging = true
        }
        hideTask?.cancel()
        cancelBoost(reveal: false)
        model.pauseAndSave()
    }

    private func deactivate() {
        hideTask?.cancel()
        cancelBoost(reveal: false)
        suspendedForPaging = false
        resumeAfterPaging = false
        PreviewPlaybackOwner.release(ownerID)
    }

    private func togglePlayback() {
        guard allowsInteraction, isActive, scenePhase == .active else { return }
        cancelBoost()
        model.togglePlayback()
        revealControls()
    }

    private func openSeries() {
        guard allowsInteraction, scenePhase == .active else { return }
        deactivate()
        onOpenSeries()
    }

    private func cancelBoost(reveal: Bool = true) {
        if holdingBoost || boostStarted { suppressBoostUntilRelease = true }
        endBoost(reveal: reveal)
    }

    private func endBoost(reveal: Bool = true) {
        if boostStarted { lastBoostEndAt = Date() }
        boostStarted = false
        model.endSpeedBoost()
        if reveal { revealControls() }
    }

    private func revealControls() {
        hideTask?.cancel()
        controlsVisible = true
        guard isActive, scenePhase == .active, model.isPlaying,
              !model.isBuffering, model.errorMessage == nil,
              !boostStarted, !voiceOverEnabled else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func viewingRegion(_ geometry: GeometryProxy) -> CGRect {
        let bounds = CGRect(origin: .zero, size: geometry.size)
        guard #available(iOS 27.1, *) else { return bounds }
        let obstacles = geometry.reservedRegions(kind: .division).filter(\.isActive)
            + geometry.reservedRegions(kind: .occlusion).filter(\.isActive)
        let frames = obstacles.map { region in
            CGRect(x: region.frame.minX - region.margins.leading,
                   y: region.frame.minY - region.margins.top,
                   width: region.frame.width + region.margins.leading + region.margins.trailing,
                   height: region.frame.height + region.margins.top + region.margins.bottom)
        }
        return PlayerViewingRegion.best(in: bounds, avoiding: frames, aspect: model.videoAspectRatio,
                                        anchor: CGPoint(x: bounds.midX, y: bounds.midY))
    }
}

/// Serialises the complete stop/start handoff, including AVAudioSession changes.
/// A delayed disappearance from an old page cannot deactivate the new owner.
@MainActor
private enum PreviewPlaybackOwner {
    private static var ownerID: UUID?
    private static weak var model: PlayerModel?

    static func acquire(_ id: UUID, model newModel: PlayerModel) {
        guard ownerID != id else { return }
        model?.setSceneActive(false)
        model?.stop()
        model = newModel
        ownerID = id
    }

    static func release(_ id: UUID) {
        guard ownerID == id else { return }
        let previous = model
        ownerID = nil
        model = nil
        previous?.setSceneActive(false)
        previous?.stop()
    }

    static func isOwner(_ id: UUID) -> Bool { ownerID == id }
}
