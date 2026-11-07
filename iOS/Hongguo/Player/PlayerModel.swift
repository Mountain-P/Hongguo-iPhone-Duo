import AVFoundation
import Combine
import CoreVideo
import Foundation
import HongguoCore
import HongguoPlayback
import os

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var series: Series
    @Published private(set) var episodes: [Episode]

    @Published private(set) var currentEpisode: Episode?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
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

    func selectSpeed(_ rate: Float) {
        guard rate.isFinite, (0.25...4).contains(rate) else { return }
        playbackSpeed.selectRate(rate)
        preferences.setNormalRate(playbackSpeed.normalRate)
        applyPlaybackRate()
        updateNextEpisodePrefetch()
    }

    func setAutoNext(_ enabled: Bool) {
        guard !isPreview else { autoNext = false; return }
        autoNext = enabled
        preferences.setAutoNext(enabled)
    }

    func setPrefetchNetworkAllowed(_ allowed: Bool) {
        prefetchNetworkAllowed = allowed
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
        guard let episode = currentEpisode else { return nil }
        return .init(seriesID: series.id, episodeID: episode.id, position: player.currentTime().seconds,
                     duration: duration, itemID: generation, isReady: isInitialSeekComplete, isSeeking: isSeeking)
    }

    /// The caller has just claimed this preview for a freshly validated formal route.
    /// Neither the player, item, resource loader nor decoder is replaced here.
    func promoteToFormalPlayback(detail: SeriesDetail, service: any CatalogService,
                                 onProgress: @escaping (Episode, Double, Double) -> Void) -> Bool {
        guard isPreview, isInitialSeekComplete, !isSeeking, detail.series.id == series.id,
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
        autoNext = preferences.load().resolved(isPreview: false).autoNext
        pendingFormalActivation = true
        diagnosticsID = PlaybackDiagnostics.shared.begin(context: .episode)
        if let diagnosticsID { PlaybackDiagnostics.shared.recordReady(id: diagnosticsID) }
        return true
    }

    func finishVisualTransition() { episodeTransitionFrame = nil }

    func beginSpeedBoost() {
        guard hasStarted, audioPolicy.permitsPlayback(sceneActive: sceneActive), !isLoading, errorMessage == nil else { return }
        playbackSpeed.beginHold()
        applyPlaybackRate()
    }

    func endSpeedBoost() {
        playbackSpeed.endHold()
        applyPlaybackRate()
    }

    func lockSpeedBoost() {
        guard hasStarted, audioPolicy.permitsPlayback(sceneActive: sceneActive), !isLoading, errorMessage == nil else { return }
        playbackSpeed.lock()
        applyPlaybackRate()
    }

    func unlockSpeedBoost() {
        playbackSpeed.unlock()
        applyPlaybackRate()
    }

    private func applyPlaybackRate() {
        let rate = effectiveSpeed
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

    private var service: any CatalogService
    private var isPreview: Bool
    private let preferences = PlaybackPreferencesStore.shared
    private let initialEpisodeID: String
    private let resumeSeconds: Double
    private var onProgress: (Episode, Double, Double) -> Void
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var loader: AuthenticatedMediaLoader?
    private var progressiveLoader: NativeMediaAssetLoader?
    private var statusObservation: NSKeyValueObservation?
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
    private var lastSavedAt = Date.distantPast
    private var loadStartedAt = Date()
    private var loggedPlaybackStart = false
    private var reachedEnd = false
    private var seekGeneration = UUID()
    private var diagnosticsID: UUID?
    private var transitionVideoOutput: AVPlayerItemVideoOutput?
    @Published private(set) var episodeTransitionFrame: PlaybackTransitionFrame?
    private var isSeeking = false
    private var pendingFormalActivation = false
    private let nextPrefetcher = NativePlaybackPrefetch()
    private var nextPrefetchState = EpisodePrefetchState()
    private var nextPrefetchTask: Task<Void, Never>?
    private var prefetchNetworkAllowed = false

    init(series: Series, episodes: [Episode], initialEpisodeID: String, resumeSeconds: Double,
         service: any CatalogService, onProgress: @escaping (Episode, Double, Double) -> Void,
         isPreview: Bool = false) {
        self.series = series
        self.episodes = episodes.sorted { $0.number < $1.number }
        self.initialEpisodeID = initialEpisodeID
        self.resumeSeconds = resumeSeconds.isFinite ? max(0, resumeSeconds) : 0
        self.service = service
        self.onProgress = onProgress
        self.isPreview = isPreview
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
        beginLoad(episode, position: position, fresh: false, autoplay: true)
    }

    func retry() {
        guard let episode = currentEpisode else { return }
        retryCount = 0
        beginLoad(episode, position: resumePosition, fresh: true, autoplay: true)
    }

    func skip(_ seconds: Double) {
        guard hasStarted else { return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        seek(to: current + seconds)
    }

    func seek(to seconds: Double) {
        guard hasStarted, seconds.isFinite else { return }
        let target = min(max(0, seconds), duration > 0 ? duration : .greatestFiniteMagnitude)
        let requestGeneration = generation
        let seekRequest = UUID(); seekGeneration = seekRequest
        isSeeking = true
        elapsed = target
        reachedEnd = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration, self.seekGeneration == seekRequest else { return }
                self.isSeeking = false
                guard finished, self.playbackSpeed.wantsPlayback, self.sceneActive,
                      self.player.timeControlStatus == .paused else { return }
                self.resumePlayback()
            }
        }
        updateNextEpisodePrefetch()
    }

    func togglePlayback() {
        guard hasStarted, !isLoading, errorMessage == nil else { return }
        if canPausePlayback { pauseAndSave() }
        else if !audioPolicy.permitsPlayback(sceneActive: sceneActive) { return }
        else if PlaybackReplay.shouldRestart(position: elapsed, duration: duration, reachedEnd: reachedEnd) {
            restartFromBeginning()
        } else { resumePlayback() }
    }

    private func restartFromBeginning() {
        let requestGeneration = generation
        let seekRequest = UUID(); seekGeneration = seekRequest
        if diagnosticsID == nil {
            diagnosticsID = PlaybackDiagnostics.shared.begin(context: .replay)
        }
        playbackSpeed.requestPlayback()
        isSeeking = true
        reachedEnd = false
        elapsed = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration, self.seekGeneration == seekRequest else { return }
                self.isSeeking = false
                guard finished else {
                    if let id = self.diagnosticsID { PlaybackDiagnostics.shared.recordFailure(id: id, recovered: false) }
                    self.finishDiagnostics(outcome: .failed)
                    self.pauseAndSave()
                    self.errorMessage = "無法從頭重播，請重新載入。"
                    return
                }
                if let id = self.diagnosticsID { PlaybackDiagnostics.shared.recordReady(id: id) }
                guard self.playbackSpeed.wantsPlayback, self.sceneActive else { return }
                self.resumePlayback()
            }
        }
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
        if let id = diagnosticsID { PlaybackDiagnostics.shared.recordPause(id: id) }
        cancelNextEpisodePrefetch()
        playbackSpeed.pause()
        player.pause()
        isPlaying = false
        isBuffering = false
        applyPlaybackRate()
        saveProgress()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if !active { episodeTransitionFrame = nil; endSpeedBoost(); pauseAndSave() }
    }

    func stop() {
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
                           continuingDiagnostics: Bool = false) {
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
        pendingResume = position.isFinite ? max(0, position) : 0
        elapsed = pendingResume
        duration = 0
        errorMessage = nil
        isLoading = true
        isBuffering = false
        loadStartedAt = Date()
        loggedPlaybackStart = false
        reachedEnd = false
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await service.playback(seriesID: series.id, episodeID: episode.id, fresh: fresh)
                try Task.checkCancellation()
                guard generation == requestGeneration else { return }
                configure(source: source, generation: requestGeneration)
            } catch is CancellationError {
                return
            } catch {
                guard generation == requestGeneration, !Task.isCancelled else { return }
                handleFailure(generation: requestGeneration, error: error)
            }
        }
    }

    private func configure(source: PlaybackSource, generation requestGeneration: UUID) {
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
        item.preferredForwardBufferDuration = 5
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
                self.elapsed = time.seconds.isFinite ? max(0, time.seconds) : 0
                self.updateDuration()
                self.updateNextEpisodePrefetch()
                if Date().timeIntervalSince(self.lastSavedAt) >= 5 { self.saveProgress() }
            }
        }
    }

    private func ready(generation requestGeneration: UUID) {
        guard generation == requestGeneration, !hasStarted, preparingGeneration != requestGeneration else { return }
        preparingGeneration = requestGeneration
        updateDuration()
        let completed = duration > 0 && pendingResume >= duration - 1 && pendingResume / duration >= 0.98
        let target = completed ? 0 : (duration > 0 ? min(pendingResume, max(0, duration - 0.5)) : pendingResume)
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
                if let id = self.diagnosticsID { PlaybackDiagnostics.shared.recordReady(id: id) }
                if self.sceneActive, self.playbackSpeed.wantsPlayback { self.resumePlayback() }
            }
        }
    }

    private func handleFailure(generation requestGeneration: UUID, error: (any Error)? = nil) {
        guard generation == requestGeneration, let episode = currentEpisode else { return }
        if error is CancellationError { return }
        let willRetry = PlaybackRecovery.shouldRetry(error, attempt: retryCount)
        if let id = diagnosticsID { PlaybackDiagnostics.shared.recordFailure(id: id, recovered: willRetry) }
        if willRetry {
            let resumeAfterRecovery = playbackSpeed.wantsPlayback
            retryCount = 1
            beginLoad(episode, position: resumePosition, fresh: true, autoplay: resumeAfterRecovery,
                      continuingDiagnostics: true)
        } else {
            finishDiagnostics(outcome: .failed)
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

    private func updateNextEpisodePrefetch() {
        guard let currentEpisode else { cancelNextEpisodePrefetch(); return }
        let bufferAhead = player.currentItem?.loadedTimeRanges.reduce(0.0) { best, value in
            let range = value.timeRangeValue
            let start = range.start.seconds, end = CMTimeRangeGetEnd(range).seconds
            guard start.isFinite, end.isFinite, start <= elapsed + 0.25, end > elapsed else { return best }
            return max(best, end - elapsed)
        } ?? 0
        let context = EpisodePrefetchState.Context(elapsed: elapsed, duration: duration, rate: effectiveSpeed,
            bufferedAhead: bufferAhead,
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
        hasStarted = false
        isSeeking = false
        preparingGeneration = nil
        isPlaying = false
        isBuffering = false
        playbackSpeed.prepareForItem(autoplay: autoplay)
        if let progressObserver { player.removeTimeObserver(progressObserver) }
        progressObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
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
