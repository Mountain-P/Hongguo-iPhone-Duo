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
        let service: NativeCatalogService
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
        let start = spec.first.flatMap { Int($0) } ?? 20
        let end = spec.dropFirst().first.flatMap { Int($0) } ?? 29
        let rate = spec.dropFirst(2).first.flatMap { Float($0) } ?? 2
        let quality: NativePlaybackQuality = args.contains("qa-data-saver") ? .dataSaver : (args.contains("qa-smooth") ? .smooth : .automatic)
        let fixtureMode = args.first(where: { $0.hasPrefix("qa-fixture=") }).map { String($0.dropFirst(11)) }
        let fixture = try fixtureMode.map { try ContinuitySimulatorFixture(file: URL.documentsDirectory.appendingPathComponent("fixture.mp4"),
            lowFile: URL.documentsDirectory.appendingPathComponent("fixture-low.mp4"), mode: $0) }
        let service: NativeCatalogService
        if let fixture { service = await fixture.service(quality: quality) }
        else { service = NativeCatalogService(quality: quality) }
        let detail = try await service.detail(id: "7642275752825605144")
        guard detail.series.title == "幸得重生不负青梅",
              let initial = detail.episodes.first(where: { $0.number == start }),
              detail.episodes.contains(where: { $0.number == end }) else {
            emit("FAIL catalogue title=\(detail.series.title) episodes=\(detail.episodes.count)")
            return
        }
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
        emit("START version=\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") ?? "?") title=\(detail.series.title) catalogue=\(detail.episodes.count) range=\(start)-\(end) rate=\(rate) quality=\(quality.rawValue)")
        let began = ProcessInfo.processInfo.systemUptime
        var run = Run(episode: start, entered: began, identity: model.playbackItemIdentity)
        var outcomes: [Run] = []
        var nextHeartbeat = began + 20
        var checkedCancellation = false
        defer { model.stop() }
        while true {
            try await Task.sleep(for: .milliseconds(100))
            var now = ProcessInfo.processInfo.systemUptime
            if fixtureMode == "cancel", !checkedCancellation, let fixture, await fixture.routeCount >= 2 {
                checkedCancellation = true
                model.pauseAndSave(); model.setSceneActive(false)
                let held = model.player.currentTime().seconds
                try await Task.sleep(for: .seconds(6))
                model.setSceneActive(true)
                try await Task.sleep(for: .milliseconds(400))
                guard !model.isPlaying, !model.canPausePlayback,
                      abs(model.player.currentTime().seconds - held) < 0.5 else {
                    emit("FAIL cancelled replacement resumed playback"); return
                }
                emit("CANCEL_PASS background and pause preserved position and playback intent")
                model.togglePlayback()
                now = ProcessInfo.processInfo.systemUptime
                run.advancedAt = now
                run.position = model.player.currentTime().seconds
            }
            let current = model.currentEpisode?.number ?? run.episode
            if let duration = completed[run.episode] {
                emit(String(format: "END ep=%d duration=%.2f wall=%.2f stalls=%d stallSeconds=%.2f worst=%.2f reloads=%d",
                            run.episode, duration, now-run.entered, run.stalls, run.waitingSeconds, run.maxWait, run.reloads))
                outcomes.append(run)
                if run.episode == end {
                    if let fixture {
                        emit("FIXTURE mode=\(fixtureMode ?? "") routes=\(await fixture.routeCount) qualities=\(await fixture.requestedQualities) finalRate=\(model.effectiveSpeed) height=\(model.nativeVariant?.height ?? 0)")
                        if fixtureMode == "smooth", model.nativeVariant?.preference != .dataSaver {
                            emit("FAIL no automatic quality fallback"); return
                        }
                        if fixtureMode == "cancel", !checkedCancellation { emit("FAIL cancellation not exercised"); return }
                    }
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

    private func emit(_ line: String) {
        FileHandle.standardOutput.write(Data(("SIMULATOR_QA " + line + "\n").utf8))
    }
}
