// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import HongguoCore
import SwiftUI
import UIKit

/// An inline first-episode preview. The pager owns which settled card is active.
@MainActor
struct RecommendationPreviewMediaCard: View {
    let series: Series
    let episode: Episode
    let service: any CatalogService
    let isActive: Bool
    var resumeSeconds: Double = 0
    var handoffContext: PlaybackHandoffEligibility.Context? = nil
    var topicPreferences = RecommendationTopicPreferences()
    var topicPreferencesLoading = false
    var onTopicPreference: ((String, RecommendationTopicPreferences.Preference) -> Void)? = nil
    var retainsFrame: Bool = false
    var allowsInteraction: Bool = true
    var isFavorite: Bool = false
    var onToggleFavorite: (() -> Void)? = nil
    var onPlaybackStarted: (() -> Void)? = nil
    var onPreviewQualified: (() -> Void)? = nil
    var onPositionSnapshot: (PreviewPlaybackSnapshot) -> Void = { _ in }
    var recommendationTitle: String? = nil
    var recommendationReason: String? = nil
    var discoverySourceLabel: String? = nil
    var bottomControlInset: CGFloat = 0
    var onShowPreferences: (() -> Void)? = nil
    var onNotInterested: (() -> Void)? = nil
    var onViewDetails: (() -> Void)? = nil
    let onOpenSeries: (PreviewPlaybackSnapshot, PlaybackTransitionFrame?, PreviewPlaybackHandoff?) -> Void

    var body: some View {
        PreviewVideoContent(series: series, episode: episode, service: service,
                            isActive: isActive, resumeSeconds: resumeSeconds, handoffContext: handoffContext,
                            topicPreferences: topicPreferences, topicPreferencesLoading: topicPreferencesLoading,
                            onTopicPreference: onTopicPreference, retainsFrame: retainsFrame,
                            allowsInteraction: allowsInteraction, isFavorite: isFavorite,
                            onToggleFavorite: onToggleFavorite, onPlaybackStarted: onPlaybackStarted,
                            onPreviewQualified: onPreviewQualified,
                            onPositionSnapshot: onPositionSnapshot,
                            recommendationTitle: recommendationTitle, recommendationReason: recommendationReason,
                            discoverySourceLabel: discoverySourceLabel,
                            bottomControlInset: bottomControlInset,
                            onShowPreferences: onShowPreferences,
                            onNotInterested: onNotInterested, onViewDetails: onViewDetails, onOpenSeries: onOpenSeries)
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
    private let episodeID: String
    let isActive: Bool
    let topicPreferences: RecommendationTopicPreferences
    let topicPreferencesLoading: Bool
    let onTopicPreference: ((String, RecommendationTopicPreferences.Preference) -> Void)?
    @State private var originContext: PlaybackHandoffEligibility.Context?
    let retainsFrame: Bool
    let allowsInteraction: Bool
    let isFavorite: Bool
    let onToggleFavorite: (() -> Void)?
    let onPlaybackStarted: (() -> Void)?
    let onPreviewQualified: (() -> Void)?
    let onPositionSnapshot: (PreviewPlaybackSnapshot) -> Void
    let recommendationTitle: String?
    let recommendationReason: String?
    let discoverySourceLabel: String?
    let bottomControlInset: CGFloat
    let onShowPreferences: (() -> Void)?
    let onNotInterested: (() -> Void)?
    let onViewDetails: (() -> Void)?
    let onOpenSeries: (PreviewPlaybackSnapshot, PlaybackTransitionFrame?, PreviewPlaybackHandoff?) -> Void
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var boostStarted = false
    @State private var ownerID = UUID()
    @State private var suspendedForPaging = false
    @State private var resumeAfterPaging = false
    @State private var lastBoostEndAt = Date.distantPast
    @State private var firstFrameReady = false
    @State private var reportedPlaybackStarted = false
    @State private var reportedPreviewQualified = false
    @State private var watchQualification = PreviewWatchQualification()
    @State private var qualificationTask: Task<Void, Never>?
    @State private var handoffFrame: PlaybackTransitionFrame?

    init(series: Series, episode: Episode, service: any CatalogService,
         isActive: Bool, resumeSeconds: Double, handoffContext: PlaybackHandoffEligibility.Context?,
         topicPreferences: RecommendationTopicPreferences, topicPreferencesLoading: Bool,
         onTopicPreference: ((String, RecommendationTopicPreferences.Preference) -> Void)?,
         retainsFrame: Bool, allowsInteraction: Bool, isFavorite: Bool,
         onToggleFavorite: (() -> Void)?, onPlaybackStarted: (() -> Void)?, onPreviewQualified: (() -> Void)?,
         onPositionSnapshot: @escaping (PreviewPlaybackSnapshot) -> Void,
         recommendationTitle: String?, recommendationReason: String?, discoverySourceLabel: String?,
         bottomControlInset: CGFloat,
         onShowPreferences: (() -> Void)?, onNotInterested: (() -> Void)?, onViewDetails: (() -> Void)?,
         onOpenSeries: @escaping (PreviewPlaybackSnapshot, PlaybackTransitionFrame?, PreviewPlaybackHandoff?) -> Void) {
        self.isActive = isActive
        _originContext = State(initialValue: handoffContext)
        self.topicPreferences = topicPreferences
        self.topicPreferencesLoading = topicPreferencesLoading
        self.onTopicPreference = onTopicPreference
        self.episodeID = episode.id
        self.retainsFrame = retainsFrame
        self.allowsInteraction = allowsInteraction
        self.isFavorite = isFavorite
        self.onToggleFavorite = onToggleFavorite
        self.onPlaybackStarted = onPlaybackStarted
        self.onPreviewQualified = onPreviewQualified
        self.onPositionSnapshot = onPositionSnapshot
        self.recommendationTitle = recommendationTitle
        self.recommendationReason = recommendationReason
        self.discoverySourceLabel = discoverySourceLabel
        self.bottomControlInset = bottomControlInset
        self.onShowPreferences = onShowPreferences
        self.onNotInterested = onNotInterested
        self.onViewDetails = onViewDetails
        self.onOpenSeries = onOpenSeries
        _model = StateObject(wrappedValue: PlayerModel(series: series, episodes: [episode],
            initialEpisodeID: episode.id, resumeSeconds: resumeSeconds, service: service,
            onProgress: { _, _, _ in }, isPreview: true))
    }

    var body: some View {
        GeometryReader { geometry in
            let region = viewingRegion(geometry)
            ZStack(alignment: .topLeading) {
                Color.black
                ZStack {
                    Poster(series: model.series, contentMode: .fill)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    NativePlayerSurface(player: model.player, fillsScreen: true, onReadyForDisplayChange: { ready in
                        if ready { model.recordFirstFrame() }
                        firstFrameReady = ready
                        if ready { reportPositionSnapshot() }
                        updatePreviewQualification()
                    })
                        .opacity(firstFrameReady && model.player.currentItem != nil && !model.isLoading && model.errorMessage == nil ? 1 : 0)
                    if let handoffFrame {
                        Image(uiImage: handoffFrame.image).resizable().scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    touchSurface
                    if isActive, controlsVisible || !model.canPausePlayback {
                        centerControl
                    }
                    status.accessibilityHidden(!isActive)
                    VStack {
                        HStack {
                            preferenceMenu
                            Spacer(minLength: 0)
                            speedMenu.accessibilityHidden(!isActive)
                        }
                        Spacer(minLength: 12)
                        footer
                    }
                    .padding(region.height < 400 ? 12 : 20)
                    .padding(.bottom, max(bottomControlInset, 0))
                    .opacity(controlsVisible || !isActive ? 1 : 0)
                    .allowsHitTesting(controlsVisible || !isActive)
                    .accessibilityHidden(!controlsVisible && isActive)
                }
                .frame(width: region.width, height: region.height)
                .overlay(alignment: .top) {
                    if isActive, model.isSpeedBoosting {
                        glass(Text("2 倍速").font(.caption.weight(.semibold))
                            .padding(.horizontal, 14).frame(minHeight: 44), in: Capsule())
                            .padding(.top, region.height < 400 ? 12 : 20)
                            .allowsHitTesting(false)
                    }
                }
                .clipped()
                .position(x: region.midX, y: region.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear { traceLayout(geometry, region: region) }
            .onChange(of: region) { _, value in traceLayout(geometry, region: value) }
        }
        .background(.black)
        .foregroundStyle(.white)
        .accessibilityHidden(!allowsInteraction)
        .task { synchronizeActivation(); updatePreviewQualification() }
        .onChange(of: isActive) { wasActive, active in
            if wasActive, !active { reportPositionSnapshot(allowLeaving: true) }
            if active { clearHandoffFrame(reason: "active") }
            else if allowsInteraction { clearHandoffFrame(reason: "not_preparing") }
            if !active { reportedPlaybackStarted = false }
            synchronizeActivation(); updatePreviewQualification()
        }
        .onChange(of: retainsFrame) { _, _ in synchronizeActivation(); updatePreviewQualification() }
        .onChange(of: allowsInteraction) { _, allowed in
            if allowed { clearHandoffFrame(reason: "interaction") }
            else if let handoffFrame { traceTransition("retained_preparing", frame: handoffFrame) }
            updatePreviewQualification()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { clearHandoffFrame(reason: "scene") }
            synchronizeActivation(); updatePreviewQualification()
        }
        .onChange(of: model.isPlaying) { _, _ in scheduleAutoHide(); updatePreviewQualification() }
        .onChange(of: model.isLoading) { _, loading in
            if loading { firstFrameReady = false }
            else { reportPositionSnapshot() }
            scheduleAutoHide(); updatePreviewQualification()
        }
        .onChange(of: model.isBuffering) { _, _ in scheduleAutoHide(); updatePreviewQualification() }
        .onChange(of: model.duration) { _, _ in updatePreviewQualification() }
        .onChange(of: model.elapsed) { _, _ in reportPositionSnapshot() }
        .onChange(of: model.errorMessage) { _, _ in revealControls(); updatePreviewQualification() }
        .onChange(of: voiceOverEnabled) { _, _ in revealControls() }
        .onDisappear { clearHandoffFrame(reason: "disappear"); deactivate() }
    }

    private var touchSurface: some View {
        PreviewGestureSurface(isEnabled: allowsInteraction && isActive && scenePhase == .active,
            onTap: {
                guard allowsInteraction, isActive, !boostStarted,
                      Date().timeIntervalSince(lastBoostEndAt) > 0.25 else { return }
                toggleControlsVisibility()
            }, onHoldBegan: {
                guard allowsInteraction, isActive, !boostStarted,
                      scenePhase == .active, !model.isLoading,
                      model.errorMessage == nil, model.duration > 0 else { return }
                boostStarted = true
                hideTask?.cancel()
                model.beginSpeedBoost()
            }, onHoldEnded: { cancelled in
                let wasBoosting = boostStarted
                endBoost(reveal: false)
                if wasBoosting, !cancelled, controlsVisible, isActive, scenePhase == .active {
                    scheduleAutoHide()
                }
            })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("第 1 集試看影片")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { revealControls() }
            .accessibilityAction(named: Text("顯示播放控制"), revealControls)
            .accessibilityAction(named: Text(model.canPausePlayback ? "暫停" : "播放"), togglePlayback)
            .accessibilityAction(named: Text("追這部"), openSeries)
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
        .simultaneousGesture(TapGesture().onEnded { revealControls() })
        .disabled(!isActive), in: Capsule())
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    if let discoverySourceLabel {
                        Text(discoverySourceLabel).font(.caption2.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(Theme.accent)
                            .accessibilityLabel("推薦來源：\(discoverySourceLabel)")
                    }
                    if let recommendationReason {
                        Text(recommendationReason).font(.caption2).lineLimit(2)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    if let onViewDetails {
                        Button {
                            guard allowsInteraction, scenePhase == .active else { return }
                            deactivate()
                            onViewDetails()
                        } label: {
                            Text(model.series.title).font(.headline).lineLimit(2)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("查看\(model.series.title)劇集詳情")
                    } else {
                        Text(model.series.title).font(.headline).lineLimit(2)
                    }
                    Text("第 1 集試看 · 上滑看下一部").font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                .shadow(color: .black.opacity(0.8), radius: 3, y: 1)
                .frame(maxWidth: .infinity, alignment: .leading)
                if let onToggleFavorite {
                    glass(Button {
                        guard allowsInteraction, scenePhase == .active else { return }
                        onToggleFavorite()
                    } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.body.weight(.semibold)).frame(width: 46, height: 46)
                    }.buttonStyle(.plain)
                        .accessibilityLabel(isFavorite ? "取消收藏" : "收藏這部劇")
                        .accessibilityValue(isFavorite ? "已收藏" : "未收藏")
                        .accessibilityIdentifier("preview.favorite"), in: Circle())
                }
                glass(Button(action: openSeries) {
                    Label("追這部", systemImage: "play.rectangle")
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
    private var preferenceMenu: some View {
        if onShowPreferences != nil || onNotInterested != nil {
            glass(Menu {
                if let onShowPreferences {
                    Button { guard allowsInteraction else { return }; onShowPreferences() }
                        label: { Label("推薦偏好", systemImage: "slider.horizontal.3") }
                }
                topicPreferenceMenu
                if let onNotInterested {
                    Button { guard allowsInteraction else { return }; onNotInterested() }
                        label: { Label("不感興趣", systemImage: "hand.thumbsdown") }
                }
            } label: {
                Label(recommendationTitle ?? "推薦選項", systemImage: "ellipsis")
                    .font(.caption.weight(.semibold)).lineLimit(1)
                    .padding(.horizontal, 12).frame(minHeight: 44)
            }
            .simultaneousGesture(TapGesture().onEnded { revealControls() })
            .disabled(!allowsInteraction), in: Capsule())
        }
    }

    private func updatePreviewQualification() {
        let validContext = isActive && allowsInteraction && scenePhase == .active && firstFrameReady
        let eligible = validContext && model.isPlaying && !model.isBuffering
            && !model.isLoading && model.errorMessage == nil
        if eligible, !reportedPlaybackStarted {
            reportedPlaybackStarted = true
            onPlaybackStarted?()
        }
        watchQualification.update(isEligible: eligible, duration: model.duration)
        // The closing eligible interval can qualify at natural EOF or pause.
        if validContext, watchQualification.isQualified, !reportedPreviewQualified {
            reportedPreviewQualified = true
            onPreviewQualified?()
        }
        guard eligible, !reportedPreviewQualified else {
            qualificationTask?.cancel(); qualificationTask = nil
            return
        }
        guard qualificationTask == nil else { return }
        qualificationTask = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard !Task.isCancelled else { return }
                updatePreviewQualification()
            }
        }
    }

    private func stopPreviewQualification() {
        watchQualification.update(isEligible: false, duration: model.duration)
        qualificationTask?.cancel(); qualificationTask = nil
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

    private var availableTopicTags: [String] {
        var seen: Set<String> = []
        return Array(model.series.tags.compactMap { tag in
            guard let value = RecommendationTopicTag.normalized(tag), seen.insert(value.key).inserted else { return nil }
            return value.title
        }.prefix(8))
    }

    @ViewBuilder
    private var topicPreferenceMenu: some View {
        if let onTopicPreference, !availableTopicTags.isEmpty {
            Menu("多推薦這類", systemImage: "hand.thumbsup") {
                ForEach(availableTopicTags, id: \.self) { tag in
                    Button { onTopicPreference(tag, .more) } label: {
                        if topicPreferences.preference(for: tag) == .more { Label(tag, systemImage: "checkmark") }
                        else { Text(tag) }
                    }
                }
            }.disabled(topicPreferencesLoading)
            Menu("少推薦這類", systemImage: "line.3.horizontal.decrease") {
                ForEach(availableTopicTags, id: \.self) { tag in
                    Button { onTopicPreference(tag, .less) } label: {
                        if topicPreferences.preference(for: tag) == .less { Label(tag, systemImage: "checkmark") }
                        else { Text(tag) }
                    }
                }
            }.disabled(topicPreferencesLoading)
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
        model.setAutoNext(false)
        model.setSceneActive(true)
        model.start()
        if shouldResume, !model.canPausePlayback { model.togglePlayback() }
        revealControls()
    }

    private func pauseRetainingFrame() {
        guard PreviewPlaybackOwner.isOwner(ownerID) else { return }
        reportPositionSnapshot(allowLeaving: true)
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
        if PreviewPlaybackOwner.isOwner(ownerID) { reportPositionSnapshot(allowLeaving: true) }
        reportedPlaybackStarted = false
        stopPreviewQualification()
        hideTask?.cancel()
        cancelBoost(reveal: false)
        suspendedForPaging = false
        resumeAfterPaging = false
        PreviewPlaybackOwner.release(ownerID)
    }

    private func togglePlayback() {
        guard allowsInteraction, isActive, scenePhase == .active else { return }
        cancelBoost()
        if !model.canPausePlayback, model.duration > 0, model.elapsed >= model.duration - 0.25 {
            model.seek(to: 0)
        }
        model.togglePlayback()
        revealControls()
    }

    private func openSeries() {
        guard allowsInteraction, scenePhase == .active, let episode = model.currentEpisode else { return }
        cancelBoost(reveal: false)
        if PreviewPlaybackOwner.isOwner(ownerID) { reportPositionSnapshot(); model.pauseAndSave() }
        let frame = firstFrameReady ? model.captureTransitionFrame() : nil
        handoffFrame = frame
        traceTransition(frame == nil ? "capture_fallback" : "capture_success", frame: frame)
        let position = model.player.currentTime().seconds
        let snapshot = PreviewPlaybackSnapshot(seriesID: model.series.id, episodeID: episode.id,
            position: position.isFinite && position >= 0 ? position : model.elapsed, duration: model.duration)
        var handoff: PreviewPlaybackHandoff?
        if PreviewPlaybackOwner.isOwner(ownerID), let originContext {
            handoff = PreviewPlaybackHandoff(model: model, snapshot: snapshot, context: originContext)
            if handoff != nil, !PreviewPlaybackOwner.detach(ownerID, model: model) {
                handoff?.dispose(); handoff = nil
            }
        }
        deactivate()
        onOpenSeries(snapshot, frame, handoff)
    }

    private func reportPositionSnapshot(allowLeaving: Bool = false) {
        guard isActive || allowLeaving, firstFrameReady, model.isInitialSeekComplete,
              let episode = model.currentEpisode, episode.id == episodeID,
              model.duration.isFinite, model.duration > 0 else { return }
        let position = model.player.currentTime().seconds
        guard position.isFinite, position >= 0 else { return }
        onPositionSnapshot(.init(seriesID: model.series.id, episodeID: episode.id,
            position: min(position, model.duration), duration: model.duration))
    }

    private func clearHandoffFrame(reason: String) {
        guard let frame = handoffFrame else { return }
        traceTransition("cleared_\(reason)", frame: frame)
        handoffFrame = nil
    }

    private func traceTransition(_ event: String, frame: PlaybackTransitionFrame?) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-playback-transition-diagnostics") else { return }
        let bitmap = frame?.image.cgImage
        NSLog("PreviewTransition %@ size=%dx%d", event, bitmap?.width ?? 0, bitmap?.height ?? 0)
        #endif
    }

    private func cancelBoost(reveal: Bool = true) {
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
        scheduleAutoHide()
    }

    private func toggleControlsVisibility() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleAutoHide() }
    }

    private func scheduleAutoHide() {
        hideTask?.cancel()
        guard controlsVisible, isActive, scenePhase == .active, model.isPlaying,
              !model.isBuffering, model.errorMessage == nil,
              !boostStarted, !voiceOverEnabled else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard !Task.isCancelled else { return }
            controlsVisible = false
        }
    }

    private func traceLayout(_ geometry: GeometryProxy, region: CGRect) {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-preview-layout-diagnostics") else { return }
        NSLog("PreviewCanvas bounds=%.1fx%.1f region=%.1f,%.1f,%.1f,%.1f safe=%.1f,%.1f,%.1f,%.1f controlsBottom=%.1f",
              Double(geometry.size.width), Double(geometry.size.height), Double(region.minX), Double(region.minY),
              Double(region.width), Double(region.height), Double(geometry.safeAreaInsets.top), Double(geometry.safeAreaInsets.bottom),
              Double(geometry.safeAreaInsets.leading), Double(geometry.safeAreaInsets.trailing), Double(bottomControlInset))
        #endif
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

/// Stable UIKit recognizers share touches with the ancestor ScrollView pan.
/// Updating playback eligibility never replaces or disables the recognizers.
@MainActor
private struct PreviewGestureSurface: UIViewRepresentable {
    let isEnabled: Bool
    let onTap: () -> Void
    let onHoldBegan: () -> Void
    let onHoldEnded: (_ cancelled: Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isAccessibilityElement = false
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.held(_:)))
        hold.minimumPressDuration = 0.35
        hold.allowableMovement = 18
        for recognizer in [tap, hold] {
            recognizer.delegate = context.coordinator
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            view.addGestureRecognizer(recognizer)
        }
        tap.require(toFail: hold)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.finishHold()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: PreviewGestureSurface
        private var isHolding = false

        init(_ parent: PreviewGestureSurface) { self.parent = parent }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            parent.isEnabled
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, parent.isEnabled, !isHolding else { return }
            parent.onTap()
        }

        @objc func held(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                guard parent.isEnabled else { return }
                isHolding = true
                parent.onHoldBegan()
            case .ended:
                finishHold(cancelled: false)
            case .cancelled, .failed:
                finishHold(cancelled: true)
            default: break
            }
        }

        func finishHold(cancelled: Bool = true) {
            guard isHolding else { return }
            isHolding = false
            parent.onHoldEnded(cancelled)
        }
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

    static func detach(_ id: UUID, model expected: PlayerModel) -> Bool {
        guard ownerID == id, model === expected else { return false }
        ownerID = nil; model = nil
        return true
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
