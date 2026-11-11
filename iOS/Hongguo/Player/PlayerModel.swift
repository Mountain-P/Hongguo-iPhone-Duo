import AVFoundation
import Combine
import CoreVideo
import Foundation
import HongguoCore
import HongguoPlayback
import os

@MainActor
final class PlayerModel: ObservableObject, PlaybackRouteResource {
    let player = AVPlayer()
    @Published private(set) var series: Series
    @Published private(set) var episodes: [Episode]

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    @Published private(set) var showsBufferingIndicator = false
    @Published private(set) var bufferedRanges: [PlaybackBufferedRange] = []
    @Published private(set) var nativeVariant: NativeMediaVariant?
    @Published private(set) var playbackQuality: NativePlaybackQuality = .automatic
    @Published private(set) var isSwitchingQuality = false
    @Published private(set) var qualityNotice: String?
    @Published private(set) var audioPlaybackNotice: String?
    var supportsPlaybackQuality: Bool { service is NativeCatalogService }
    // The requested transport remains pausable while AVPlayer changes between
    // waiting and playing; clock observations alone can briefly report neither.
    var canPausePlayback: Bool { playbackSpeed.wantsPlayback || isPlaying || isBuffering }
    @Published private(set) var errorMessage: String?
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var videoAspectRatio: CGFloat = 9.0 / 16.0
    @Published private var playbackSpeed = PlaybackSpeedState()
    var isSpeedBoosting: Bool { playbackSpeed.isPressing }
    var isSpeedBoostLocked: Bool { playbackSpeed.isLocked }
    @Published private(set) var autoNext = true {
        didSet {
            if !autoNext { cancelNextEpisodePrefetch() }
            else { updateNextEpisodePrefetch() }
        }
    }
    var speed: Float {
        get { playbackSpeed.normalRate }
        set { selectSpeed(newValue) }
    }

    var effectiveSpeed: Float { playbackSpeed.effectiveRate }

    func selectSpeed(_ rate: Float, feedback: Bool = false) {
        guard rate.isFinite, (0.25...4).contains(rate) else { return }
        let changed = playbackSpeed.normalRate != rate || playbackSpeed.isPressing || playbackSpeed.isLocked
        playbackSpeed.selectRate(rate)
        preferences.setNormalRate(playbackSpeed.normalRate)
        applyPlaybackRate()
        updateNextEpisodePrefetch()
        if feedback, changed { PlaybackHaptics.emit(.speedSelected) }
    }

    func setAutoNext(_ enabled: Bool) {
        guard !isPreview else { autoNext = false; return }
        autoNext = enabled
        preferences.setAutoNext(enabled)
    }

    func setPrefetchNetworkAllowed(_ allowed: Bool) {
        prefetchNetworkAllowed = allowed
        updateLoaderReadAheadEligibility()
        updateNextEpisodePrefetch()
    }

    func recordFirstFrame() {
        if let diagnosticsID { PlaybackDiagnostics.shared.recordFirstFrame(id: diagnosticsID) }
    }

    /// readyToPlay alone is insufficient: the initial resume seek must also finish.
    var isInitialSeekComplete: Bool {
        hasStarted && !isLoading && errorMessage == nil && player.currentItem?.status == .readyToPlay
    }

    func captureTransitionFrame() -> PlaybackTransitionFrame? {
        guard isInitialSeekComplete, !isSeeking, let episode = currentEpisode,
              let item = player.currentItem, let output = transitionVideoOutput,
              item.outputs.contains(where: { $0 === output }) else { return nil }
        let time = player.currentTime(), position = time.seconds
        guard position.isFinite, position >= 0 else { return nil }
        var displayTime = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) else { return nil }
        let displayed = displayTime.seconds
        let seconds = displayed.isFinite && displayed >= 0 ? displayed : position
        guard abs(seconds - position) <= PlaybackTransitionFrame.maximumPositionDifference else { return nil }
        return PlaybackTransitionFrame.make(pixelBuffer: buffer, seriesID: series.id, episodeID: episode.id,
                                            seconds: seconds, presentationSize: item.presentationSize)
    }

    var playbackItemIdentity: UUID { generation }

    var handoffPlayback: PlaybackHandoffEligibility.Playback? {
        guard !isSwitchingQuality, let episode = currentEpisode else { return nil }
        return .init(seriesID: series.id, episodeID: episode.id, position: player.currentTime().seconds,
                     duration: duration, itemID: generation, isReady: isInitialSeekComplete, isSeeking: isSeeking)
    }

    /// The caller has just claimed this preview for a freshly validated formal route.
    /// Neither the player, item, resource loader nor decoder is replaced here.
    func promoteToFormalPlayback(detail: SeriesDetail, service: any CatalogService,
                                 onProgress: @escaping (Episode, Double, Double) -> Void) -> Bool {
        guard isPreview, isInitialSeekComplete, !isSeeking, detail.series.id == series.id,
              (service as? NativeCatalogService)?.playbackQuality == (self.service as? NativeCatalogService)?.playbackQuality,
              let current = currentEpisode,
              let resolved = detail.episodes.first(where: { $0.id == current.id && $0.isAvailable }) else { return false }
        endSpeedBoost(); unlockSpeedBoost()
        finishDiagnostics(outcome: .cancelled)
        self.series = detail.series
        self.episodes = detail.episodes.sorted { $0.number < $1.number }
        self.service = service
        self.onProgress = onProgress
        self.currentEpisode = resolved
        isPreview = false
        updateBufferPolicy()
        updateLoaderReadAheadEligibility()
        autoNext = preferences.load().resolved(isPreview: false).autoNext
        pendingFormalActivation = true
        diagnosticsID = PlaybackDiagnostics.shared.begin(context: .episode)
        if let diagnosticsID { PlaybackDiagnostics.shared.recordReady(id: diagnosticsID) }
        return true
    }

    func finishVisualTransition() { episodeTransitionFrame = nil }

    func beginSpeedBoost(feedback: Bool = false) {
        guard hasStarted, audioPolicy.permitsPlayback(sceneActive: sceneActive), !isLoading, errorMessage == nil else { return }
        let changed = !playbackSpeed.isPressing
        playbackSpeed.beginHold()
        applyPlaybackRate()
        if feedback, changed { PlaybackHaptics.emit(.boostBegan) }
    }

    func endSpeedBoost(feedback: Bool = false) {
        let releasedTemporaryBoost = playbackSpeed.isPressing && !playbackSpeed.isLocked
        playbackSpeed.endHold()
        applyPlaybackRate()
        if feedback, releasedTemporaryBoost { PlaybackHaptics.emit(.boostEnded) }
    }

    func lockSpeedBoost(feedback: Bool = false) {
        guard hasStarted, audioPolicy.permitsPlayback(sceneActive: sceneActive), !isLoading, errorMessage == nil else { return }
        let changed = !playbackSpeed.isLocked
        playbackSpeed.lock()
        applyPlaybackRate()
        if feedback, changed { PlaybackHaptics.emit(.boostLocked) }
    }

    func unlockSpeedBoost(feedback: Bool = false) {
        let changed = playbackSpeed.isLocked
        playbackSpeed.unlock()
        applyPlaybackRate()
        if feedback, changed { PlaybackHaptics.emit(.boostUnlocked) }
    }

    private func applyPlaybackRate() {
        let rate = effectiveSpeed
        updateBufferPolicy()
        updateLoaderReadAheadEligibility()
        if abs(player.defaultRate - rate) > 0.0001 { player.defaultRate = rate }
        let transport: PlaybackSpeedState.Transport
        switch player.timeControlStatus {
        case .playing: transport = .playing
        case .waitingToPlayAtSpecifiedRate: transport = .waiting
        default: transport = .paused
        }
        if let adjustment = playbackSpeed.rateAdjustment(transport: transport, currentRate: player.rate,
                                                        isReady: hasStarted, sceneActive: sceneActive) {
            player.rate = adjustment
        }
    }

    private func resumePlayback() {
        guard hasStarted, audioPolicy.permitsPlayback(sceneActive: sceneActive), !isLoading, errorMessage == nil else { return }
        playbackSpeed.requestPlayback()
        applyPlaybackRate()
        player.playImmediately(atRate: effectiveSpeed)
    }

    /// This is an AVFoundation preference only. It never delays startup or commands playback.
    private func updateBufferPolicy(for item: AVPlayerItem? = nil, waiting: Bool = false) {
        guard let item = item ?? player.currentItem else { return }
        let previous = bufferPolicy.targetMediaSeconds
        let target = bufferPolicy.update(isPreview: isPreview, rate: effectiveSpeed, waiting: waiting)
        if target > 0, item.preferredForwardBufferDuration != target {
            item.preferredForwardBufferDuration = target
        }
        if target != previous { traceBufferPolicy() }
    }

    private func updateLoaderReadAheadEligibility() {
        let canReadAhead = (prefetchNetworkAllowed || !isPreview) && sceneActive && hasStarted
            && playbackSpeed.wantsPlayback && !isLoading && errorMessage == nil
        setLoaderReadAheadEnabled(canReadAhead, memoryOnly: !prefetchNetworkAllowed)
    }

    private func setLoaderReadAheadEnabled(_ requested: Bool, memoryOnly: Bool = false) {
        let enabled = requested && progressiveLoader != nil
        let memoryOnly = enabled && memoryOnly
        let rate = enabled ? effectiveSpeed : 1
        guard loaderReadAheadEnabled != enabled || loaderReadAheadMemoryOnly != memoryOnly
            || loaderReadAheadRate != rate else { return }
        progressiveLoader?.setReadAheadEnabled(enabled, memoryOnly: memoryOnly, playbackRate: rate)
        loaderReadAheadEnabled = enabled
        loaderReadAheadMemoryOnly = memoryOnly
        loaderReadAheadRate = rate
        traceBufferPolicy()
    }

    private func traceBufferPolicy() {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-playback-buffer-diagnostics") else { return }
        NSLog("PlaybackBuffer rate=%.2f targetMediaSeconds=%.2f preview=%d aheadEnabled=%d memoryOnly=%d",
              Double(effectiveSpeed), bufferPolicy.targetMediaSeconds, isPreview ? 1 : 0,
              loaderReadAheadEnabled ? 1 : 0, loaderReadAheadMemoryOnly ? 1 : 0)
        #endif
    }

    private func updateBufferedRanges() {
        let ranges: [PlaybackBufferedRange] = player.currentItem?.loadedTimeRanges.prefix(128).map {
            let value = $0.timeRangeValue
            return PlaybackBufferedRange(start: value.start.seconds, end: CMTimeRangeGetEnd(value).seconds)
        } ?? []
        let normalized = PlaybackBufferedRanges.normalized(ranges, duration: duration)
        if normalized != bufferedRanges { bufferedRanges = normalized }
    }

    private func updatePlaybackHealth() {
        let now = ProcessInfo.processInfo.systemUptime
        let eligible = didStart && hasStarted && sceneActive && playbackSpeed.wantsPlayback
            && !isLoading && !reachedEnd && errorMessage == nil
        let waiting = eligible && isBuffering
        showsBufferingIndicator = bufferingIndicator.update(waiting: waiting, eligible: eligible, at: now)
        let action = stallRecovery.update(.init(time: now, position: resumePosition, waiting: waiting,
            wantsPlayback: playbackSpeed.wantsPlayback, sceneActive: sceneActive,
            isReady: hasStarted && !isLoading, isSeeking: isSeeking,
            networkAvailable: PlaybackNetworkAvailability.shared.isAvailable))
        switch action {
        case .reload:
            guard let episode = currentEpisode, eligible else { return }
            let position = resumePosition
            if bufferedSeconds(at: position) <= 0.5 * Double(effectiveSpeed) {
                progressiveLoader?.noteBufferStarvation()
            }
            traceHealth("reload")
            if let id = diagnosticsID { PlaybackDiagnostics.shared.recordFailure(id: id, recovered: true) }
            beginLoad(episode, position: position, fresh: true, autoplay: playbackSpeed.wantsPlayback,
                      continuingDiagnostics: true, preservingPosition: true)
            return
        case .stopWaiting:
            traceHealth("exhausted")
            errorMessage = "影片持續緩衝，請檢查網路後重新載入。"
            if let id = diagnosticsID { PlaybackDiagnostics.shared.recordFailure(id: id, recovered: false) }
            finishDiagnostics(outcome: .failed)
            pauseAndSave()
            return
        case .none: break
        }
        guard waiting else {
            healthTask?.cancel(); healthTask = nil
            return
        }
        guard healthTask == nil else { return }
        let requestGeneration = generation
        healthTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, self.generation == requestGeneration else { return }
                self.updateBufferedRanges()
                if await self.recoverTerminalStreamFailure(generation: requestGeneration) { return }
                self.updatePlaybackHealth()
            }
        }
    }

    private func recoverTerminalStreamFailure(generation requestGeneration: UUID) async -> Bool {
        guard isBuffering, !isSeeking, bufferedSeconds(at: resumePosition) <= 0.5 * Double(effectiveSpeed),
              let error = await progressiveLoader?.recoverableTerminalError(),
              generation == requestGeneration, !Task.isCancelled, sceneActive, playbackSpeed.wantsPlayback,
              PlaybackNetworkAvailability.shared.isAvailable, errorMessage == nil,
              isBuffering, !isSeeking, bufferedSeconds(at: resumePosition) <= 0.5 * Double(effectiveSpeed) else { return false }
        traceHealth("terminal source")
        handleFailure(generation: requestGeneration, error: error)
        return true
    }

    private func traceHealth(_ action: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-playback-health-diagnostics") {
            NSLog("PlaybackHealth %@", action)
        }
        #endif
    }

    func switchPlaybackQuality(_ preference: NativePlaybackQuality) {
        guard let native = service as? NativeCatalogService, let episode = currentEpisode,
              hasStarted, sceneActive, !isLoading, !isSwitchingQuality,
              playbackQuality != preference else { return }
        clearQualityNotice()
        cancelNextEpisodePrefetch()
        let token = UUID(); qualityGeneration = token
        let requestGeneration = generation
        let seriesID = series.id
        let candidateService = native.selectingPlaybackQuality(preference)
        isSwitchingQuality = true
        qualityTask = Task { @MainActor [weak self] in
            do {
                let source = try await candidateService.playback(seriesID: seriesID, episodeID: episode.id, fresh: false)
                try Task.checkCancellation()
                guard let self, self.qualityGeneration == token, self.generation == requestGeneration,
                      self.currentEpisode?.id == episode.id, self.sceneActive else { return }
                self.qualityTask = nil
                self.isSwitchingQuality = false
                guard let variant = source.nativeStream?.variant else {
                    self.showQualityNotice("目前來源不支援切換畫質。")
                    return
                }
                guard preference != .dataSaver || !variant.qualityFallback else {
                    self.showQualityNotice("目前來源沒有較低畫質，保留現有影片。")
                    return
                }
                let same = self.nativeVariant.map {
                    $0.codec == variant.codec && $0.quality == variant.quality
                        && $0.width == variant.width && $0.height == variant.height
                } ?? false
                self.service = candidateService
                self.playbackQuality = preference
                if same {
                    self.showQualityNotice("目前已是所選模式的可用畫質。")
                    self.updateNextEpisodePrefetch()
                    return
                }
                let position = self.resumePosition
                let autoplay = self.playbackSpeed.wantsPlayback
                self.retryCount = 0
                if self.stallRecovery.isExhausted { self.stallRecovery.reset() }
                self.beginLoad(episode, position: position, fresh: false, autoplay: autoplay,
                               preparedSource: source, preservingPosition: true)
                self.showQualityNotice(preference == .dataSaver ? "已切換為流暢優先" : "已切換為畫質優先")
                self.traceHealth("qualityChanged")
            } catch {
                guard let self, self.qualityGeneration == token, self.generation == requestGeneration else { return }
                self.qualityTask = nil
                self.isSwitchingQuality = false
                guard !(error is CancellationError) else { return }
                self.showQualityNotice("畫質切換未完成，繼續播放原影片。")
            }
        }
    }

    /// Paging/route suspension cancels optional work without treating a pause as cancellation.
    func cancelQualityPreparation() {
        cancelQualitySwitch()
        clearQualityNotice()
    }

    private func cancelQualitySwitch() {
        qualityGeneration = UUID()
        qualityTask?.cancel(); qualityTask = nil
        isSwitchingQuality = false
    }

    private func showQualityNotice(_ text: String) {
        qualityNoticeTask?.cancel()
        qualityNotice = text
        qualityNoticeTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.qualityNotice = nil
        }
    }

    private func clearQualityNotice() {
        qualityNoticeTask?.cancel(); qualityNoticeTask = nil
        qualityNotice = nil
    }

    private var service: any CatalogService
    private var isPreview: Bool
    private let preferences = PlaybackPreferencesStore.shared
    private let initialEpisodeID: String
    private let resumeSeconds: Double
    private let startupTimeout: Duration
    private var onProgress: (Episode, Double, Double) -> Void
    private var loadTask: Task<Void, Never>?
    private var startupWatchdog: Task<Void, Never>?
    private var generation = UUID()
    private var loader: AuthenticatedMediaLoader?
    private var progressiveLoader: NativeMediaAssetLoader?
    private var statusObservation: NSKeyValueObservation?
    private var rangesObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var progressObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var audioInterruptionObserver: NSObjectProtocol?
    private var audioRouteObserver: NSObjectProtocol?
    private var audioObserverGeneration = UUID()
    private var audioPolicy = PlaybackInterruptionPolicy()
    private var hasStarted = false
    private var preparingGeneration: UUID?
    private var didStart = false
    private var sceneActive = true
    private var retryCount = 0
    private var pendingResume: Double = 0
    private var preservesResumePosition = false
    private var lastSavedAt = Date.distantPast
    private var loadStartedAt = Date()
    private var loggedPlaybackStart = false
    private var reachedEnd = false
    private var diagnosticsID: UUID?
    private var transitionVideoOutput: AVPlayerItemVideoOutput?
    @Published private(set) var episodeTransitionFrame: PlaybackTransitionFrame?
    private var isSeeking = false
    // AVPlayer's clock/periodic callbacks can lag behind an in-flight seek.
    private var pendingSeekTarget: Double?
    private var seekCoordinator = PlaybackSeekCoordinator()
    private var replaySeekToken: UUID?
    private var healthTask: Task<Void, Never>?
    private var stallRecovery = PlaybackStallRecoveryState()
    private var bufferingIndicator = BufferingIndicatorPolicy()
    private var qualityTask: Task<Void, Never>?
    private var qualityNoticeTask: Task<Void, Never>?
    private var audioNoticeTask: Task<Void, Never>?
    private var qualityGeneration = UUID()
    private var pendingFormalActivation = false
    private let nextPrefetcher = NativePlaybackPrefetch()
    private var nextPrefetchState = EpisodePrefetchState()
    private var nextPrefetchTask: Task<Void, Never>?
    private var prefetchNetworkAllowed = false
    private var bufferPolicy = PlaybackBufferPolicy()
    private var loaderReadAheadEnabled = false
    private var loaderReadAheadMemoryOnly = false
    private var loaderReadAheadRate: Float = 1

    init(series: Series, episodes: [Episode], initialEpisodeID: String, resumeSeconds: Double,
         service: any CatalogService, onProgress: @escaping (Episode, Double, Double) -> Void,
         isPreview: Bool = false, startupTimeout: Duration = .seconds(30)) {
        self.series = series
        self.episodes = episodes.sorted { $0.number < $1.number }
        self.initialEpisodeID = initialEpisodeID
        self.resumeSeconds = resumeSeconds.isFinite ? max(0, resumeSeconds) : 0
        self.startupTimeout = startupTimeout
        self.service = service
        self.onProgress = onProgress
        self.isPreview = isPreview
        self.playbackQuality = (service as? NativeCatalogService)?.playbackQuality ?? .automatic
        let saved = preferences.load().resolved(isPreview: isPreview)
        playbackSpeed.selectRate(saved.normalRate)
        autoNext = saved.autoNext
        applyPlaybackRate()
    }

    func start() {
        if didStart {
            if pendingFormalActivation {
                pendingFormalActivation = false
                if sceneActive { resumePlayback() }
            }
            return
        }
        didStart = true
        observeAudioEvents()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // AVPlayer still has a usable system default if the audio session is busy.
        }
        playbackObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaying = self.player.timeControlStatus == .playing
                self.isBuffering = self.hasStarted && self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                self.updateBufferPolicy(waiting: self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
                self.updateLoaderReadAheadEligibility()
                self.updatePlaybackHealth()
                if let id = self.diagnosticsID {
                    PlaybackDiagnostics.shared.recordTransport(id: id,
                        waiting: self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                        playing: self.player.timeControlStatus == .playing)
                }
                self.updateNextEpisodePrefetch()
                if self.isPlaying {
                    if self.hasStarted, !self.loggedPlaybackStart {
                        self.loggedPlaybackStart = true
                        #if DEBUG
                        Logger(subsystem: "tw.mountainp.hongguo", category: "startup")
                            .info("first_playback_seconds=\(Date().timeIntervalSince(self.loadStartedAt), privacy: .public)")
                        #endif
                    }
                }
                if self.player.timeControlStatus == .paused { self.saveProgress() }
            }
        }
        let previous = currentEpisode
        guard let episode = previous
                ?? episodes.first(where: { $0.id == initialEpisodeID && $0.isAvailable })
                ?? episodes.first(where: \.isAvailable) else {
            errorMessage = "目前沒有可選集數。"
            return
        }
        let position = previous == nil ? (episode.id == initialEpisodeID ? resumeSeconds : 0) : pendingResume
        select(episode, position: position)
    }

    func select(_ episode: Episode, position: Double = 0) {
        guard episode.isAvailable else { return }
        retryCount = 0
        stallRecovery.reset()
        beginLoad(episode, position: position, fresh: false, autoplay: true)
    }

    func retry() {
        guard let episode = currentEpisode else { return }
        retryCount = 0
        stallRecovery.reset()
        beginLoad(episode, position: resumePosition, fresh: true, autoplay: true,
                  preservingPosition: hasStarted || preservesResumePosition)
    }

    @discardableResult
    func skip(_ seconds: Double, feedback: Bool = false) -> Bool {
        guard hasStarted, sceneActive, !isLoading, errorMessage == nil,
              let target = PlaybackRelativeSeek.target(current: player.currentTime().seconds,
                  pendingTarget: pendingSeekTarget, offset: seconds, duration: duration) else { return false }
        enqueueSeek(to: target, kind: .relative)
        if feedback { PlaybackHaptics.emit(.skip) }
        return true
    }

    func seek(to seconds: Double) {
        enqueueSeek(to: seconds, kind: .precise)
    }

    private func enqueueSeek(to seconds: Double, kind: PlaybackSeekCoordinator.Kind) {
        guard hasStarted, sceneActive, !isLoading, errorMessage == nil, seconds.isFinite else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        let request = seekCoordinator.submit(target: target, kind: kind)
        isSeeking = seekCoordinator.isSeeking
        pendingSeekTarget = seekCoordinator.pendingTarget
        elapsed = target
        reachedEnd = false
        updatePlaybackHealth()
        if let request { performSeek(request) }
        updateNextEpisodePrefetch()
    }

    private func performSeek(_ request: PlaybackSeekCoordinator.Request) {
        let requestGeneration = generation
        let tolerance = CMTime(seconds: request.toleranceSeconds, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: request.target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration,
                      self.seekCoordinator.activeRequest?.token == request.token else { return }
                let next = self.seekCoordinator.complete(token: request.token, finished: finished)
                let wasReplay = self.replaySeekToken == request.token
                if wasReplay { self.replaySeekToken = nil }
                self.isSeeking = self.seekCoordinator.isSeeking
                self.pendingSeekTarget = self.seekCoordinator.pendingTarget
                if let next { self.performSeek(next); return }
                let actual = self.player.currentTime().seconds
                if actual.isFinite { self.elapsed = max(0, actual) }
                self.updatePlaybackHealth()
                if !finished, wasReplay {
                    if let id = self.diagnosticsID { PlaybackDiagnostics.shared.recordFailure(id: id, recovered: false) }
                    self.finishDiagnostics(outcome: .failed)
                    self.pauseAndSave()
                    self.errorMessage = "無法從頭重播，請重新載入。"
                    return
                }
                guard self.player.currentItem?.status == .readyToPlay,
                      self.playbackSpeed.wantsPlayback, self.sceneActive,
                      self.player.timeControlStatus == .paused else { return }
                self.resumePlayback()
            }
        }
    }

    func togglePlayback() {
        guard hasStarted, !isLoading, errorMessage == nil else { return }
        if canPausePlayback { pauseAndSave(); return }
        // iOS may suspend the audio session without delivering a matching end
        // notification. Only a fresh user Play may reactivate it and clear the
        // stale interruption; returning to the foreground never starts playback.
        guard activateAudioForUserPlayback() else { return }
        if PlaybackReplay.shouldRestart(position: elapsed, duration: duration, reachedEnd: reachedEnd) {
            restartFromBeginning()
        } else { resumePlayback() }
    }

    private func activateAudioForUserPlayback() -> Bool {
        clearAudioPlaybackNotice()
        do {
            return try audioPolicy.activateForUserPlayback(sceneActive: sceneActive) {
                try AVAudioSession.sharedInstance().setActive(true)
            }
        } catch {
            audioPlaybackNotice = "暫時無法恢復音訊，請稍後再按播放。"
            audioNoticeTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                self?.audioPlaybackNotice = nil
            }
            return false
        }
    }

    private func clearAudioPlaybackNotice() {
        audioNoticeTask?.cancel(); audioNoticeTask = nil
        audioPlaybackNotice = nil
    }

    private func restartFromBeginning() {
        seekCoordinator.reset()
        player.currentItem?.cancelPendingSeeks()
        if diagnosticsID == nil {
            diagnosticsID = PlaybackDiagnostics.shared.begin(context: .replay)
        }
        playbackSpeed.requestPlayback()
        reachedEnd = false
        if let id = diagnosticsID { PlaybackDiagnostics.shared.recordReady(id: id) }
        enqueueSeek(to: 0, kind: .precise)
        replaySeekToken = seekCoordinator.activeRequest?.token
    }

    var nextEpisode: Episode? {
        guard let currentEpisode, let index = episodes.firstIndex(where: { $0.id == currentEpisode.id }) else { return nil }
        return episodes.dropFirst(index + 1).first(where: \.isAvailable)
    }

    func playNext() {
        guard let nextEpisode else { return }
        select(nextEpisode)
    }

    func navigateEpisode(_ direction: EpisodeNavigation.Direction) -> EpisodeNavigation.Result {
        guard !isPreview, sceneActive else { return .missingCurrent }
        let result = EpisodeNavigation.adjacent(to: currentEpisode?.id, in: episodes, direction: direction)
        if case .episode(let episode) = result { select(episode) }
        return result
    }

    func pauseAndSave() {
        clearAudioPlaybackNotice()
        if let id = diagnosticsID { PlaybackDiagnostics.shared.recordPause(id: id) }
        cancelNextEpisodePrefetch()
        playbackSpeed.pause()
        player.pause()
        isPlaying = false
        isBuffering = false
        updatePlaybackHealth()
        applyPlaybackRate()
        saveProgress()
    }

    func setSceneActive(_ active: Bool) {
        let wasActive = sceneActive
        sceneActive = active
        updateLoaderReadAheadEligibility()
        if !active {
            cancelStartupWatchdog()
            cancelQualitySwitch(); episodeTransitionFrame = nil; endSpeedBoost(); pauseAndSave()
        } else if !wasActive && isLoading {
            monitorStartup(generation)
        }
    }

    func stop() {
        clearAudioPlaybackNotice()
        cancelQualitySwitch()
        clearQualityNotice()
        setLoaderReadAheadEnabled(false)
        pendingFormalActivation = false
        episodeTransitionFrame = nil
        removeAudioObservers()
        audioPolicy = PlaybackInterruptionPolicy()
        cancelNextEpisodePrefetch()
        finishDiagnostics(outcome: .cancelled)
        saveProgress()
        pendingResume = resumePosition
        didStart = false
        generation = UUID()
        loadTask?.cancel()
        loadTask = nil
        player.pause()
        playbackObservation?.invalidate()
        playbackObservation = nil
        clearItem()
        isLoading = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func beginLoad(_ episode: Episode, position: Double, fresh: Bool, autoplay: Bool,
                           continuingDiagnostics: Bool = false, preparedSource: PlaybackSource? = nil,
                           preservingPosition: Bool = false) {
        clearAudioPlaybackNotice()
        cancelQualitySwitch()
        cancelNextEpisodePrefetch()
        if !continuingDiagnostics || diagnosticsID == nil {
            finishDiagnostics(outcome: .cancelled)
            diagnosticsID = PlaybackDiagnostics.shared.begin(context: isPreview ? .preview : .episode)
        }
        // Capture before clearing the old item, including rapid B -> C while B is loading.
        if let frame = captureTransitionFrame() {
            episodeTransitionFrame = frame
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-playback-transition-diagnostics") {
                NSLog("EpisodeTransition captured=1")
            }
            #endif
        }
        saveProgress()
        loadTask?.cancel()
        let requestGeneration = UUID()
        generation = requestGeneration
        player.pause()
        clearItem(autoplay: autoplay && audioPolicy.permitsPlayback(sceneActive: sceneActive))
        currentEpisode = episode
        preservesResumePosition = preservingPosition
        pendingResume = position.isFinite ? max(0, position) : 0
        elapsed = pendingResume
        duration = 0
        errorMessage = nil
        isLoading = true
        isBuffering = false
        loadStartedAt = Date()
        loggedPlaybackStart = false
        reachedEnd = false
        monitorStartup(requestGeneration)
        let service = self.service
        let seriesID = series.id
        loadTask = Task { [weak self] in
            do {
                let source: PlaybackSource
                if let preparedSource { source = preparedSource }
                else { source = try await service.playback(seriesID: seriesID, episodeID: episode.id, fresh: fresh) }
                try Task.checkCancellation()
                guard let self, self.generation == requestGeneration else { return }
                self.configure(source: source, generation: requestGeneration)
            } catch is CancellationError {
                // Superseded requests have already changed generation or been
                // cancelled. A source may also interrupt the current request.
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.handleFailure(generation: requestGeneration, error: NSError(
                    domain: NSURLErrorDomain, code: URLError.cancelled.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "影片載入中斷，請重新取源。"]))
            } catch {
                guard let self, self.generation == requestGeneration, !Task.isCancelled else { return }
                self.handleFailure(generation: requestGeneration, error: error)
            }
        }
    }

    private func monitorStartup(_ requestGeneration: UUID) {
        cancelStartupWatchdog()
        guard sceneActive, isLoading else { return }
        let timeout = startupTimeout
        startupWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard let self, !Task.isCancelled, self.sceneActive, self.isLoading,
                  self.generation == requestGeneration else { return }
            self.handleFailure(generation: requestGeneration, error: NSError(
                domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "影片載入逾時，請重新取源。"]))
        }
    }

    private func cancelStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    private func configure(source: PlaybackSource, generation requestGeneration: UUID) {
        nativeVariant = source.nativeStream?.variant
        let asset: AVURLAsset
        if let stream = source.nativeStream {
            let resourceLoader = NativeMediaAssetLoader(stream: stream)
            progressiveLoader = resourceLoader
            asset = resourceLoader.makeAsset()
        } else if source.headers.isEmpty {
            asset = AVURLAsset(url: source.url)
        } else {
            let resourceLoader = AuthenticatedMediaLoader(url: source.url, headers: source.headers)
            loader = resourceLoader
            asset = resourceLoader.makeAsset()
        }
        let item = AVPlayerItem(asset: asset)
        rangesObservation = item.observe(\.loadedTimeRanges, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == requestGeneration,
                      self.player.currentItem === item else { return }
                self.updateBufferedRanges()
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-playback-transition-diagnostics") {
            NSLog("PlayerPipeline configured preview=%d", isPreview ? 1 : 0)
        }
        #endif
        do {
            let output = AVPlayerItemVideoOutput(outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                AVVideoAllowWideColorKey: false
            ])
            item.add(output); transitionVideoOutput = output
        }
        updateBufferPolicy(for: item)
        updateLoaderReadAheadEligibility()
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration, self.player.currentItem === item else { return }
                switch item.status {
                case .readyToPlay: self.ready(generation: requestGeneration)
                case .failed: self.handleFailure(generation: requestGeneration, error: self.mediaFailure(item.error))
                default: break
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self, weak item] _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item, self.generation == requestGeneration, self.player.currentItem === item else { return }
                let shouldAdvance = self.audioPolicy.shouldAdvanceAfterEnd(sceneActive: self.sceneActive,
                    wantsPlayback: self.playbackSpeed.wantsPlayback, autoNext: self.autoNext)
                self.updateDuration()
                self.elapsed = self.duration
                self.saveProgress(completed: true)
                self.reachedEnd = true
                self.finishDiagnostics(outcome: .completed)
                self.playbackSpeed.pause()
                self.isPlaying = false
                self.isBuffering = false
                self.updatePlaybackHealth()
                self.updateLoaderReadAheadEligibility()
                if shouldAdvance { self.playNext() }
            }
        }
        stalledObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] notification in
            let failure = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleFailure(generation: requestGeneration, error: self.mediaFailure(failure))
            }
        }
        player.replaceCurrentItem(with: item)
        progressObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration, self.hasStarted else { return }
                if !self.isSeeking { self.elapsed = time.seconds.isFinite ? max(0, time.seconds) : 0 }
                if !self.isSeeking, self.sceneActive, self.playbackSpeed.wantsPlayback, !self.isLoading,
                   self.player.timeControlStatus == .playing, self.player.currentItem?.status == .readyToPlay,
                   self.errorMessage == nil {
                    self.stallRecovery.recordPlaybackProgress(at: time.seconds)
                }
                self.updateDuration()
                self.updateBufferedRanges()
                self.updateNextEpisodePrefetch()
                if Date().timeIntervalSince(self.lastSavedAt) >= 5 { self.saveProgress() }
            }
        }
    }

    private func ready(generation requestGeneration: UUID) {
        guard generation == requestGeneration, !hasStarted, preparingGeneration != requestGeneration else { return }
        preparingGeneration = requestGeneration
        updateDuration()
        let target = PlaybackResumeTarget.target(position: pendingResume, duration: duration,
                                                isLiveReload: preservesResumePosition) ?? 0
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                guard finished else {
                    self.preparingGeneration = nil
                    self.handleFailure(generation: requestGeneration)
                    return
                }
                self.elapsed = target
                self.hasStarted = true
                self.isLoading = false
                self.cancelStartupWatchdog()
                self.updateLoaderReadAheadEligibility()
                self.updateBufferedRanges()
                self.updatePlaybackHealth()
                if let id = self.diagnosticsID { PlaybackDiagnostics.shared.recordReady(id: id) }
                if self.sceneActive, self.playbackSpeed.wantsPlayback { self.resumePlayback() }
            }
        }
    }

    private func handleFailure(generation requestGeneration: UUID, error: (any Error)? = nil) {
        guard generation == requestGeneration, let episode = currentEpisode else { return }
        if error is CancellationError { return }
        cancelStartupWatchdog()
        let willRetry: Bool
        if hasStarted && !isLoading {
            willRetry = PlaybackRecovery.shouldRetry(error, attempt: 0) && stallRecovery.requestReload()
        } else {
            willRetry = PlaybackRecovery.shouldRetry(error, attempt: retryCount)
        }
        if let id = diagnosticsID { PlaybackDiagnostics.shared.recordFailure(id: id, recovered: willRetry) }
        if willRetry {
            let resumeAfterRecovery = playbackSpeed.wantsPlayback
            retryCount = 1
            beginLoad(episode, position: resumePosition, fresh: true, autoplay: resumeAfterRecovery,
                      continuingDiagnostics: true, preservingPosition: hasStarted || preservesResumePosition)
        } else {
            finishDiagnostics(outcome: .failed)
            if isLoading {
                generation = UUID()
                loadTask?.cancel()
                loadTask = nil
                clearItem()
            }
            isLoading = false
            errorMessage = error?.localizedDescription ?? "目前無法播放這一集。請重新取源，或選擇其他集數。"
            pauseAndSave()
        }
    }

    private func finishDiagnostics(outcome: PlaybackDiagnostics.Outcome) {
        guard let id = diagnosticsID else { return }
        PlaybackDiagnostics.shared.finish(id: id, outcome: outcome)
        diagnosticsID = nil
    }

    private func observeAudioEvents() {
        removeAudioObservers()
        let token = audioObserverGeneration
        audioInterruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
                guard let raw = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue,
                      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
                let event: PlaybackInterruptionPolicy.Event
                switch type {
                case .began: event = .began
                case .ended: event = .ended
                @unknown default: return
                }
                Task { @MainActor [weak self] in
                    guard let self, self.audioObserverGeneration == token, self.didStart else { return }
                    self.handleAudioEvent(event)
                }
            }
        audioRouteObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
                guard let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue,
                      let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
                let event: PlaybackInterruptionPolicy.Event = reason == .oldDeviceUnavailable ? .oldDeviceUnavailable : .otherRouteChange
                Task { @MainActor [weak self] in
                    guard let self, self.audioObserverGeneration == token, self.didStart else { return }
                    self.handleAudioEvent(event)
                }
            }
    }

    private func removeAudioObservers() {
        audioObserverGeneration = UUID()
        if let observer = audioInterruptionObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = audioRouteObserver { NotificationCenter.default.removeObserver(observer) }
        audioInterruptionObserver = nil; audioRouteObserver = nil
    }

    private func handleAudioEvent(_ event: PlaybackInterruptionPolicy.Event) {
        if audioPolicy.receive(event) == .pause { pauseAndSave() }
    }

    private func bufferedSeconds(at position: Double) -> Double {
        player.currentItem?.loadedTimeRanges.reduce(0.0) { best, value in
            let range = value.timeRangeValue
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, start <= position + 0.25, end > position else { return best }
            return max(best, end - position)
        } ?? 0
    }

    private func updateNextEpisodePrefetch() {
        guard let currentEpisode else { cancelNextEpisodePrefetch(); return }
        let context = EpisodePrefetchState.Context(elapsed: elapsed, duration: duration, rate: effectiveSpeed,
            bufferedAhead: bufferedSeconds(at: elapsed),
            allowed: !isPreview && service is NativeCatalogService && autoNext && sceneActive && hasStarted
                && playbackSpeed.wantsPlayback && isPlaying && !isLoading && !isBuffering
                && errorMessage == nil && prefetchNetworkAllowed)
        switch nextPrefetchState.update(episodeID: currentEpisode.id, nextEpisodeID: nextEpisode?.id, context: context) {
        case .none: break
        case .cancel: cancelNextEpisodePrefetch()
        case .prepare(let episodeID):
            nextPrefetchTask?.cancel()
            let service = service, seriesID = series.id, prefetcher = nextPrefetcher
            nextPrefetchTask = Task(priority: .utility) {
                do {
                    try Task.checkCancellation()
                    _ = try await prefetcher.prepare(seriesID: seriesID, episodeID: episodeID, service: service)
                } catch { /* Optional work cannot become a visible playback error. */ }
            }
        }
    }

    private func cancelNextEpisodePrefetch() {
        nextPrefetchState.reset()
        nextPrefetchTask?.cancel()
        nextPrefetchTask = nil
    }

    private func mediaFailure(_ error: (any Error)?) -> (any Error)? {
        var current = error as NSError?
        for _ in 0..<8 {
            guard let value = current else { break }
            if value.domain == "HongguoNativeMediaAsset", (400...499).contains(value.code) {
                return value.code == 401 ? CatalogError.unauthorized : CatalogError.httpStatus(value.code)
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        if PlaybackRecovery.shouldRetry(error, attempt: 0) { return NativeMediaError.network }
        return CatalogError.unavailablePlayback
    }

    private func updateDuration() {
        let seconds = player.currentItem?.duration.seconds ?? 0
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        if let size = player.currentItem?.presentationSize, size.width.isFinite, size.height.isFinite,
           size.width > 0, size.height > 0 {
            let ratio = size.width / size.height
            if (0.1...10).contains(ratio), abs(ratio - videoAspectRatio) > 0.001 { videoAspectRatio = ratio }
        }
    }

    private var resumePosition: Double {
        if let pendingSeekTarget { return pendingSeekTarget }
        guard hasStarted else { return pendingResume }
        let current = player.currentTime().seconds
        return current.isFinite ? max(0, current) : elapsed
    }

    private func saveProgress(completed: Bool = false) {
        guard hasStarted, let episode = currentEpisode else { return }
        updateDuration()
        let seconds = player.currentTime().seconds
        let position = completed && duration > 0 ? duration : (seconds.isFinite ? max(0, seconds) : elapsed)
        elapsed = position
        onProgress(episode, position, duration)
        lastSavedAt = Date()
    }

    private func clearItem(autoplay: Bool = false) {
        cancelStartupWatchdog()
        healthTask?.cancel(); healthTask = nil
        bufferingIndicator.reset()
        showsBufferingIndicator = false
        _ = stallRecovery.update(.init(time: ProcessInfo.processInfo.systemUptime, position: 0, waiting: false,
            wantsPlayback: false, sceneActive: sceneActive, isReady: false, isSeeking: false, networkAvailable: false))
        bufferedRanges = []
        seekCoordinator.reset()
        replaySeekToken = nil
        setLoaderReadAheadEnabled(false)
        bufferPolicy.reset()
        hasStarted = false
        isSeeking = false
        pendingSeekTarget = nil
        preparingGeneration = nil
        isPlaying = false
        isBuffering = false
        playbackSpeed.prepareForItem(autoplay: autoplay)
        if let progressObserver { player.removeTimeObserver(progressObserver) }
        progressObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        rangesObservation?.invalidate(); rangesObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let stalledObserver { NotificationCenter.default.removeObserver(stalledObserver) }
        endObserver = nil
        stalledObserver = nil
        if let output = transitionVideoOutput { player.currentItem?.remove(output) }
        transitionVideoOutput = nil
        player.replaceCurrentItem(with: nil)
        loader?.invalidate()
        loader = nil
        progressiveLoader?.invalidate()
        progressiveLoader = nil
    }
}
