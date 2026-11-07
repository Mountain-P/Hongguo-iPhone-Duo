import AVFoundation
import Combine
import Foundation
import HongguoCore
import HongguoPlayback
import os

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    let series: Series
    let episodes: [Episode]

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
    @Published var autoNext = true
    var speed: Float {
        get { playbackSpeed.normalRate }
        set { selectSpeed(newValue) }
    }

    var effectiveSpeed: Float { playbackSpeed.effectiveRate }

    func selectSpeed(_ rate: Float) {
        playbackSpeed.selectRate(rate)
        applyPlaybackRate()
    }

    func beginSpeedBoost() {
        guard hasStarted, !isLoading, errorMessage == nil else { return }
        playbackSpeed.beginHold()
        applyPlaybackRate()
    }

    func endSpeedBoost() {
        playbackSpeed.endHold()
        applyPlaybackRate()
    }

    func lockSpeedBoost() {
        guard hasStarted, !isLoading, errorMessage == nil else { return }
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
        guard hasStarted, sceneActive, !isLoading, errorMessage == nil else { return }
        playbackSpeed.requestPlayback()
        applyPlaybackRate()
        player.playImmediately(atRate: effectiveSpeed)
    }

    private let service: any CatalogService
    private let initialEpisodeID: String
    private let resumeSeconds: Double
    private let onProgress: (Episode, Double, Double) -> Void
    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var loader: AuthenticatedMediaLoader?
    private var progressiveLoader: NativeMediaAssetLoader?
    private var statusObservation: NSKeyValueObservation?
    private var playbackObservation: NSKeyValueObservation?
    private var progressObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var stalledObserver: NSObjectProtocol?
    private var hasStarted = false
    private var preparingGeneration: UUID?
    private var didStart = false
    private var sceneActive = true
    private var retryCount = 0
    private var pendingResume: Double = 0
    private var lastSavedAt = Date.distantPast
    private var loadStartedAt = Date()
    private var loggedPlaybackStart = false

    init(series: Series, episodes: [Episode], initialEpisodeID: String, resumeSeconds: Double,
         service: any CatalogService, onProgress: @escaping (Episode, Double, Double) -> Void) {
        self.series = series
        self.episodes = episodes.sorted { $0.number < $1.number }
        self.initialEpisodeID = initialEpisodeID
        self.resumeSeconds = resumeSeconds.isFinite ? max(0, resumeSeconds) : 0
        self.service = service
        self.onProgress = onProgress
    }

    func start() {
        guard !didStart else { return }
        didStart = true
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
        elapsed = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayback() {
        guard hasStarted, !isLoading, errorMessage == nil else { return }
        if canPausePlayback { pauseAndSave() }
        else { resumePlayback() }
    }

    var nextEpisode: Episode? {
        guard let currentEpisode, let index = episodes.firstIndex(where: { $0.id == currentEpisode.id }) else { return nil }
        return episodes.dropFirst(index + 1).first(where: \.isAvailable)
    }

    func playNext() {
        guard let nextEpisode else { return }
        select(nextEpisode)
    }

    func pauseAndSave() {
        playbackSpeed.pause()
        player.pause()
        isPlaying = false
        isBuffering = false
        applyPlaybackRate()
        saveProgress()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        if !active { endSpeedBoost(); pauseAndSave() }
    }

    func stop() {
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

    private func beginLoad(_ episode: Episode, position: Double, fresh: Bool, autoplay: Bool) {
        saveProgress()
        loadTask?.cancel()
        let requestGeneration = UUID()
        generation = requestGeneration
        player.pause()
        clearItem(autoplay: autoplay && sceneActive)
        currentEpisode = episode
        pendingResume = position.isFinite ? max(0, position) : 0
        elapsed = pendingResume
        duration = 0
        errorMessage = nil
        isLoading = true
        isBuffering = false
        loadStartedAt = Date()
        loggedPlaybackStart = false
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
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestGeneration else { return }
                self.updateDuration()
                self.elapsed = self.duration
                self.saveProgress(completed: true)
                self.playbackSpeed.pause()
                self.isPlaying = false
                self.isBuffering = false
                if self.autoNext { self.playNext() }
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
                if self.sceneActive, self.playbackSpeed.wantsPlayback { self.resumePlayback() }
            }
        }
    }

    private func handleFailure(generation requestGeneration: UUID, error: (any Error)? = nil) {
        guard generation == requestGeneration, let episode = currentEpisode else { return }
        if error is CancellationError { return }
        if PlaybackRecovery.shouldRetry(error, attempt: retryCount) {
            let resumeAfterRecovery = playbackSpeed.wantsPlayback
            retryCount = 1
            beginLoad(episode, position: resumePosition, fresh: true, autoplay: resumeAfterRecovery)
        } else {
            isLoading = false
            errorMessage = error?.localizedDescription ?? "目前無法播放這一集。請重新取源，或選擇其他集數。"
            pauseAndSave()
        }
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
        player.replaceCurrentItem(with: nil)
        loader?.invalidate()
        loader = nil
        progressiveLoader?.invalidate()
        progressiveLoader = nil
    }
}
