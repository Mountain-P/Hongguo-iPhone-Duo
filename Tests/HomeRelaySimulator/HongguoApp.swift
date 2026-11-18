import AVFoundation
import Foundation
import HongguoCore
import SwiftUI

@main
@MainActor
struct HongguoApp: App {
    @StateObject private var app = AppModel()
    @State private var route: Route?

    var body: some Scene {
        WindowGroup {
            Color.black
                .fullScreenCover(item: $route) { screen in
                    PlayerScreen(series: screen.detail.series, episodes: screen.detail.episodes,
                                 initialEpisodeID: screen.initial.id, resumeSeconds: 0, service: screen.service,
                                 onProgress: { _, _, _ in }, retainedModel: screen.model)
                        .environmentObject(app)
                }
                .task {
                    do { try await run() }
                    catch { emit("FAIL domain=\((error as NSError).domain) code=\((error as NSError).code) message=\(error.localizedDescription)") }
                }
        }
    }

    private struct Route: Identifiable {
        let id = UUID()
        let detail: SeriesDetail
        let initial: Episode
        let service: any CatalogService
        let model: PlayerModel
    }

    private struct Run {
        var episode: Int
        var entered: Double
        var identity: UUID
        var started = false
        var advancedAt: Double = 0
        var position: Double = 0
        var stalls = 0
        var waitingSeconds: Double = 0
        var maxWait: Double = 0
        var reloads = 0
        var beganWaiting = false
        var reloading = false
        var nextSample: Double = 0
    }

    private func run() async throws {
        let args = ProcessInfo.processInfo.arguments
        let spec = args.first(where: { $0.hasPrefix("qa=") })?.dropFirst(3).split(separator: ",") ?? []
        let start = spec.first.flatMap { Int($0) } ?? 1
        let end = spec.dropFirst().first.flatMap { Int($0) } ?? 3
        let rate = spec.dropFirst(2).first.flatMap { Float($0) } ?? 2
        let config = try JSONDecoder().decode(RelayConfig.self, from: Data(contentsOf: URL.documentsDirectory.appendingPathComponent("relay-config.json")))
        if args.contains("qa-offline-reopen") { try await offlineReopen(); return }
        let relay = HomeRelayService(configuration: try .init(baseURL: config.baseURL, token: config.token),
                                     usesServerLibrary: true, allowsDirectFallback: false)
        let service: any CatalogService = relay
        let detail = try await service.detail(id: config.seriesID)
        guard let initial = detail.episodes.first(where: { $0.number == start }),
              detail.episodes.contains(where: { $0.number == end }) else { throw CatalogError.invalidID }
        app.useNativePlayback()
        if !app.isFavorite(detail.series) { app.toggleFavorite(detail.series) }
        _ = try await app.connect(address: config.baseURL, token: config.token, catalogSource: .bridge, mode: .relay)
        app.setRelayDirectFallback(false)
        guard app.isFavorite(detail.series), app.supportsAccountPlayback else { throw CatalogError.malformedResponse }
        emit("LIBRARY_SCOPE_PASS favorite preserved and account capability remains enabled; fallback disabled")
        if args.contains("qa-offline") { try await offlineDownload(detail: detail, start: start, end: end); return }
        if args.contains("qa-controls") { try await controls(detail: detail, initial: initial, service: service); return }
        var completed: [Int: Double] = [:]
        let selected = SeriesDetail(series: detail.series,
            episodes: detail.episodes.filter { (start...end).contains($0.number) })
        let model = PlayerModel(series: detail.series, episodes: selected.episodes, initialEpisodeID: initial.id,
                                resumeSeconds: 0, service: service, onProgress: { episode, position, duration in
            if duration > 0 && position >= duration {
                completed[episode.number] = duration
            }
        })
        model.setAutoNext(end > start)
        model.player.isMuted = true
        model.selectSpeed(rate)
        route = Route(detail: selected, initial: initial, service: service, model: model)
        emit("START version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") title=\(detail.series.title) catalogue=\(detail.episodes.count) range=\(start)-\(end) rate=\(rate)")
        let began = ProcessInfo.processInfo.systemUptime
        var run = Run(episode: start, entered: began, identity: model.playbackItemIdentity)
        var outcomes: [Run] = []
        var nextHeartbeat = began + 20
        var frameItem: AVPlayerItem?
        var frameOutput: AVPlayerItemVideoOutput?
        var frameCounts: [Int: Int] = [:]
        defer { model.stop() }
        while true {
            try await Task.sleep(for: .milliseconds(100))
            let now = ProcessInfo.processInfo.systemUptime
            let current = model.currentEpisode?.number ?? run.episode
            if let item = model.player.currentItem, frameItem !== item {
                frameItem = item
                let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                item.add(output); frameOutput = output
            }
            if let output = frameOutput {
                let time = model.player.currentTime()
                if output.hasNewPixelBuffer(forItemTime: time), output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil {
                    frameCounts[current, default: 0] += 1
                }
            }
            if let duration = completed[run.episode] {
                emit(String(format: "END ep=%d duration=%.2f wall=%.2f stalls=%d stallSeconds=%.2f worst=%.2f reloads=%d",
                            run.episode, duration, now-run.entered, run.stalls, run.waitingSeconds, run.maxWait, run.reloads))
                guard frameCounts[run.episode, default: 0] > 3 else { emit("FAIL no decoded video frames"); return }
                emit("FRAMES ep=\(run.episode) count=\(frameCounts[run.episode, default: 0])")
                outcomes.append(run)
                if run.episode == end {
                    emit(String(format: "RESULT completed=%d expected=%d stalls=%d stallSeconds=%.2f worst=%.2f reloads=%d wall=%.2f",
                                outcomes.count, end-start+1, outcomes.reduce(0) { $0 + $1.stalls },
                                outcomes.reduce(0) { $0 + $1.waitingSeconds }, outcomes.map(\.maxWait).max() ?? 0,
                                outcomes.reduce(0) { $0 + $1.reloads }, now-began))
                    return
                }
                run = Run(episode: run.episode + 1, entered: now, identity: model.playbackItemIdentity)
            }
            if let error = model.errorMessage {
                emit("FAIL ep=\(run.episode) completed=\(outcomes.count) position=\(run.position) reloads=\(run.reloads) message=\(error)")
                return
            }
            let position = model.player.currentTime().seconds
            if current == run.episode {
                if !run.started, model.isInitialSeekComplete, model.player.timeControlStatus == .playing,
                   position.isFinite, abs(model.player.rate - rate) < 0.01 {
                    run.started = true
                    run.position = position
                    run.advancedAt = now
                    run.nextSample = now + 10
                    let variant = model.nativeVariant
                    emit(String(format: "FIRST ep=%d startup=%.2f pos=%.2f actualRate=%.2f height=%d duration=%.2f",
                                run.episode, now-run.entered, position, model.player.rate, variant?.height ?? 0, model.duration))
                } else if run.started {
                    if run.identity != model.playbackItemIdentity {
                        run.reloads += 1
                        run.reloading = true
                        emit(String(format: "RELOAD ep=%d pos=%.2f", run.episode, run.position))
                    }
                    if position.isFinite, !model.isLoading, position > run.position + 0.025 {
                        let gap = now - run.advancedAt
                        let stalled = max(0, gap - (position - run.position) / Double(rate))
                        if stalled >= 0.55 {
                            run.stalls += 1
                            run.waitingSeconds += stalled
                            run.maxWait = max(run.maxWait, stalled)
                            emit(String(format: "STALL ep=%d pos=%.2f wait=%.2f buffering=%d reloaded=%d resume=%.2f",
                                        run.episode, run.position, stalled, run.beganWaiting ? 1 : 0,
                                        run.reloading ? 1 : 0, position))
                        }
                        run.position = position
                        run.advancedAt = now
                        run.beganWaiting = false
                        run.reloading = false
                    } else {
                        run.beganWaiting = run.beganWaiting || model.isBuffering || model.isLoading
                    }
                    if now >= run.nextSample {
                        run.nextSample = now + 10
                        let ahead = model.bufferedRanges.first(where: { $0.start <= run.position + 0.25 && $0.end >= run.position })
                            .map { $0.end - run.position } ?? 0
                        emit(String(format: "SAMPLE ep=%d pos=%.2f ahead=%.2f stalled=%.2f loading=%d",
                                    run.episode, run.position, ahead, now-run.advancedAt, model.isLoading ? 1 : 0))
                    }
                }
                run.identity = model.playbackItemIdentity
            }
            if now >= nextHeartbeat {
                nextHeartbeat = now + 20
                emit("HEARTBEAT completed=\(outcomes.count) ep=\(run.episode) current=\(current)")
            }
            let lastMotion = run.started ? run.advancedAt : run.entered
            if now - lastMotion > 100 {
                emit("FAIL timed-out ep=\(run.episode) completed=\(outcomes.count) position=\(run.position)")
                return
            }
        }
    }


    private struct RelayConfig: Decodable { let baseURL: String; let token: String; let seriesID: String }
    private enum QAError: Error { case timeout, invalidState, networkMustNotBeUsed }
    private var offlineDirectory: URL { URL.documentsDirectory.appendingPathComponent("RelayOfflineQA") }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw QAError.timeout
    }
    private func controls(detail: SeriesDetail, initial: Episode, service: any CatalogService) async throws {
        let model = PlayerModel(series: detail.series, episodes: detail.episodes, initialEpisodeID: initial.id,
                                resumeSeconds: 0, service: service, onProgress: { _, _, _ in })
        model.setAutoNext(false); model.player.isMuted = true
        route = Route(detail: detail, initial: initial, service: service, model: model)
        defer { model.stop() }
        try await waitUntil { model.player.currentTime().seconds > 2 }
        model.pauseAndSave(); model.setSceneActive(false)
        let position = model.player.currentTime().seconds
        try await Task.sleep(for: .seconds(1))
        model.setSceneActive(true)
        try await Task.sleep(for: .milliseconds(400))
        guard model.player.rate == 0, abs(model.player.currentTime().seconds-position) < 0.5 else { throw QAError.invalidState }
        model.togglePlayback()
        try await waitUntil { model.player.currentTime().seconds > position+0.5 }
        model.selectSpeed(2)
        try await waitUntil { model.player.rate == 2 }
        model.selectSpeed(1); model.beginSpeedBoost()
        try await waitUntil { model.player.rate == 2 }
        model.endSpeedBoost()
        try await waitUntil { model.player.rate == 1 }
        model.seek(to: 20)
        try await waitUntil { model.player.currentTime().seconds >= 19 }
        guard model.skip(-10) else { throw QAError.invalidState }
        try await waitUntil { model.player.currentTime().seconds < 15 }
        guard model.skip(10) else { throw QAError.invalidState }
        try await waitUntil { model.player.currentTime().seconds > 18 }
        model.pauseAndSave()
        emit("RESULT controls=PASS background-pause/resume speed1/2 hold/release seek skip-10/+10")
    }
    private func offlineDownload(detail: SeriesDetail, start: Int, end: Int) async throws {
        let storage = try OfflineDownloads(directory: offlineDirectory) { item, destination, limit, progress in
            try await AppModel.downloadForCurrentRoute(item: item, destination: destination, maximumBytes: limit, progress: progress)
        }
        let items = detail.episodes.filter { (start...end).contains($0.number) }.map {
            OfflineDownloadItem(key: .init(scope: "native.public.v1", seriesID: detail.series.id, episodeID: $0.id),
                                seriesTitle: detail.series.title, episodeNumber: $0.number, episodeTitle: $0.title)
        }
        let requested = Set(items.map(\.key))
        if ProcessInfo.processInfo.arguments.contains("qa-reset-unsupported") {
            let failed = await storage.snapshot().filter { requested.contains($0.key) && $0.isOfflineUnsupported }.map(\.key)
            try await storage.delete(failed)
            emit("RESET_UNSUPPORTED_QA_ONLY count=\(failed.count)")
        }
        try await storage.enqueue(items)
        let retried = try await storage.retryFailed(items.map(\.key))
        emit("RETRY_ALL count=\(retried)")
        await storage.start()
        var previous = -1
        for _ in 0..<3600 {
            let snapshot = await storage.snapshot().filter { requested.contains($0.key) }
            if let failed = snapshot.first(where: { $0.state == .failed || $0.state == .paused }) {
                emit("FAIL offline ep=\(failed.episodeNumber) error=\(failed.failure ?? "unknown")"); return
            }
            let done = snapshot.filter { $0.state == .completed }
            if done.count != previous { emit("DOWNLOAD completed=\(done.count)/\(items.count)"); previous = done.count }
            if done.count == items.count {
                for item in done { try await storage.recordProgress(for: item.key, position: 2, duration: 60) }
                emit("RESULT offline-download completed=\(done.count) bytes=\(done.reduce(Int64(0)) { $0+$1.receivedBytes })")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw QAError.timeout
    }
    private func offlineReopen() async throws {
        let storage = try OfflineDownloads(directory: offlineDirectory) { _, _, _, _ in throw QAError.networkMustNotBeUsed }
        let items = await storage.snapshot().sorted { $0.episodeNumber < $1.episodeNumber }
        guard !items.isEmpty, items.allSatisfy({ $0.state == .completed }) else { throw QAError.invalidState }
        var frames = 0
        for item in items {
            guard let url = try await storage.localURL(for: item.key), url.isFileURL, item.position == 2 else { throw QAError.invalidState }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            for seconds in [1, duration/2, max(1,duration-1)] {
                _ = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)); frames += 1
            }
        }
        let first = items[0]
        let detail = SeriesDetail(series: .init(id: first.key.seriesID, title: first.seriesTitle),
            episodes: items.prefix(3).map { .init(id: $0.key.episodeID, number: $0.episodeNumber, title: $0.episodeTitle) })
        let service = OfflinePlaybackService(detail: detail, scope: first.key.scope, storage: storage)
        let model = PlayerModel(series: detail.series, episodes: detail.episodes, initialEpisodeID: detail.episodes[0].id,
            resumeSeconds: first.position, service: service, onProgress: { _, _, _ in })
        model.player.isMuted = true; model.setAutoNext(false); model.selectSpeed(2)
        route = Route(detail: detail, initial: detail.episodes[0], service: service, model: model)
        model.start()
        defer { model.stop() }
        for (index, episode) in detail.episodes.enumerated() {
            if index > 0 { model.select(episode, position: 2) }
            try await waitUntil { model.currentEpisode?.id == episode.id && model.player.currentTime().seconds > 6 && model.player.rate == 2 }
            guard model.errorMessage == nil else { throw QAError.invalidState }
            emit("OFFLINE_PLAY ep=\(episode.number) resume=2 progressed=\(model.player.currentTime().seconds) productionPlayer=1")
        }
        emit("RESULT offline-reopen episodes=\(items.count) decodedFrames=\(frames) playbackSwitches=2 networkProvider=forbidden")
    }

    private func emit(_ line: String) {
        FileHandle.standardOutput.write(Data(("RELAY_QA " + line + "\n").utf8))
    }
}
