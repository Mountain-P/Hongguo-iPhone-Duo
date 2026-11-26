import AVFoundation
import Foundation
import HongguoCore
import SwiftUI

/// Simulator acceptance entry point. PlayerScreen owns start, recovery and automatic advancement.
@main @MainActor
struct HongguoApp: App {
    @StateObject private var app = AppModel()
    @State private var route: Route?
    private struct Route: Identifiable {
        let id = UUID()
        let detail: SeriesDetail
        let service: any CatalogService
        let model: PlayerModel
    }
    private struct RelayConfig: Decodable { let baseURL: String; let token: String; let seriesID: String }

    var body: some Scene {
        WindowGroup {
            if HistoryOfflineQA.offline {
                ZStack { NavigationStack { LibraryView().environmentObject(app).environmentObject(app.downloads) } }
                    .task {
                        do { try await HistoryOfflineQA.observe() }
                        catch { HistoryOfflineQA.log("FAIL " + error.localizedDescription) }
                    }
            } else if CommandLine.arguments.contains("qa-history-seed") {
                Color.black.task {
                    do { try await HistoryOfflineQA.seed(app: app) }
                    catch { HistoryOfflineQA.log("FAIL " + error.localizedDescription) }
                }
            } else {
                Color.black
                    .fullScreenCover(item: $route) { route in
                        PlayerScreen(series: route.detail.series, episodes: route.detail.episodes,
                                     initialEpisodeID: route.detail.episodes[0].id, resumeSeconds: 0, service: route.service,
                                     onProgress: { _, _, _ in }, retainedModel: route.model).environmentObject(app)
                    }
                    .task {
                        do { try await measure() }
                        catch { log("FAIL domain=\((error as NSError).domain) code=\((error as NSError).code) \(error.localizedDescription)") }
                    }
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardOutput.write(Data(("CONTINUITY " + message + "\n").utf8))
    }

    private func measure() async throws {
        let fixture = ProcessInfo.processInfo.arguments.contains("qa-direct-fixture")
        let direct = fixture || ProcessInfo.processInfo.arguments.contains("qa-direct")
        let service: any CatalogService
        let seriesID: String
        let first: Int
        if direct {
            app.useNativePlayback()
            app.setNativePlaybackQuality(.automatic)
            service = fixture ? LocalDirectFixture.service() : try app.playbackService()
            guard service is NativeCatalogService else { log("FAIL expected native service"); return }
            let config = try? String(contentsOf: URL.documentsDirectory.appendingPathComponent("direct-series"), encoding: .utf8)
            let fields = config?.split(separator: ",")
            seriesID = fixture ? "100" : (fields?.first.map(String.init) ?? "7642275752825605144")
            first = fixture ? 1 : (fields?.last.flatMap { Int($0) } ?? 20)
        } else {
            let file = URL.documentsDirectory.appendingPathComponent("relay-config.json")
            let config = try JSONDecoder().decode(RelayConfig.self, from: Data(contentsOf: file))
            service = HomeRelayService(configuration: try .init(baseURL: config.baseURL, token: config.token),
                                       usesServerLibrary: true, allowsDirectFallback: false)
            seriesID = config.seriesID; first = 1
        }
        let catalog = try await service.detail(id: seriesID)
        let episodes = catalog.episodes.filter { $0.number == first || $0.number == first + 1 }.sorted { $0.number < $1.number }
        guard episodes.count == 2, Set(episodes.map(\.id)).count == 2 else { log("FAIL missing episodes"); return }
        let selected = SeriesDetail(series: catalog.series, episodes: episodes)
        if direct && !fixture { RangeInterruption.select(episodeID: episodes[0].id) }
        var ended: Set<String> = []
        let model = PlayerModel(series: selected.series, episodes: episodes, initialEpisodeID: episodes[0].id,
                                resumeSeconds: 0, service: service, onProgress: { episode, position, duration in
            if duration > 0 && position >= duration { ended.insert(episode.id) }
        })
        model.player.isMuted = true
        model.selectSpeed(2)
        model.setAutoNext(true)
        route = Route(detail: selected, service: service, model: model)
        log("START route=\(fixture ? "direct-fixture" : (direct ? "direct" : "home-relay")) ep=\(first),\(first+1) rate=2")
        defer { model.stop() }

        let gate = URL.documentsDirectory.appendingPathComponent("outage-until")
        let receipt = URL.documentsDirectory.appendingPathComponent("outage-first-episode-read")
        let begin = ProcessInfo.processInfo.systemUptime
        var lastItem: AVPlayerItem?
        var output: AVPlayerItemVideoOutput?
        var frames: [Int: Int] = [:]
        var seen = Set<Int>()
        var faultPosition: Double?
        var initialBufferEnd = 0.0
        var witnessFrames = 0, previousWitness = -1.0
        var restored = false
        var nextStart: Double?
        var lastProgress: (Double,Double)?
        var longestGap: Double = 0
        var lastSeriesEpisode: Int?
        var initialPlaySent = false
        var nextHeartbeat = begin + 15
        let outage: TimeInterval = 6
        while ProcessInfo.processInfo.systemUptime - begin < 330 {
            try await Task.sleep(for: .milliseconds(90))
            let now = ProcessInfo.processInfo.systemUptime
            if now >= nextHeartbeat {
                nextHeartbeat = now + 15
                log(String(format: "SAMPLE ep=%d position=%.2f rate=%.1f loading=%d", model.currentEpisode?.number ?? 0,
                           model.player.currentTime().seconds, model.player.rate, model.isLoading ? 1 : 0))
            }
            // A simulator scene can enter the player while paused. Explicit start is allowed
            // once, before the first frame. After that the player must recover and advance alone.
            if !initialPlaySent, seen.isEmpty, model.isInitialSeekComplete,
               !model.isLoading, !model.canPausePlayback, now - begin > 3 {
                initialPlaySent = true
                model.togglePlayback()
                log("INITIAL_PLAY")
            }
            if let error = model.errorMessage {
                if let record = PlaybackDiagnostics.shared.records.last {
                    let attempts = (record.lookups ?? []).map { "\($0.route.rawValue)=\($0.result.rawValue)" }
                    log("DIAGNOSTIC stage=\(record.lastFailureStage?.rawValue ?? "unknown") lookups=\(attempts.joined(separator: ","))")
                }
                log("FAIL ep=\(model.currentEpisode?.number ?? 0) \(error)")
                return
            }
            guard let episode = model.currentEpisode else { continue }
            let number = episode.number
            if nextStart == nil, ended.contains(episodes[0].id) || number == first + 1 { nextStart = now }
            guard let item = model.player.currentItem else { continue }
            if let previous = lastSeriesEpisode, previous != number, number != first + 1 {
                log("FAIL unexpected episode change"); return
            }
            if lastSeriesEpisode != number { lastProgress = nil; lastSeriesEpisode = number }
            if lastItem !== item {
                let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                item.add(next); output = next; lastItem = item
            }
            let time = model.player.currentTime()
            let pos = time.seconds
            if let output, pos.isFinite, output.hasNewPixelBuffer(forItemTime: time),
               output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil,
               abs(model.player.rate - 2) < 0.01 {
                if direct && model.nativeVariant == nil { log("FAIL direct route did not use native media"); return }
                if number == first, let faultPosition, pos < faultPosition - 0.75 {
                    log(String(format:"FAIL played an earlier frame after outage: cut=%.2f position=%.2f", faultPosition, pos))
                    return
                }
                frames[number, default: 0] += 1
                if seen.insert(number).inserted {
                    log(String(format:"FRAME ep=%d position=%.2f wall=%.2f sinceSelect=%.2f actualRate=%.1f",number,pos,now-begin,now-(nextStart ?? begin),model.player.rate))
                }
                if let last = lastProgress, pos > last.0 { longestGap = max(longestGap,now-last.1-(pos-last.0)/2) }
                if lastProgress == nil || pos > lastProgress!.0 { lastProgress = (pos,now) }
                if number == first, pos >= 2, faultPosition == nil {
                    faultPosition = pos
                    // Only contiguous, already playable ranges can conceal an outage here.
                    initialBufferEnd = pos
                    for range in item.loadedTimeRanges.map(\.timeRangeValue).sorted(by: { $0.start.seconds < $1.start.seconds }) {
                        if range.start.seconds > initialBufferEnd + 0.05 { break }
                        let end = CMTimeRangeGetEnd(range).seconds
                        if end.isFinite { initialBufferEnd = max(initialBufferEnd, end) }
                    }
                    try String(Date().timeIntervalSince1970 + outage).write(to: gate, atomically: true, encoding: .utf8)
                    log(String(format:"CUT ep=%d position=%.2f contiguousBufferEnd=%.2f outage=%.0fs", number,pos,initialBufferEnd,outage))
                }
                if number == first, let faultPosition, !restored, let raw = try? String(contentsOf: gate, encoding: .utf8),
                   let until = Double(raw), let read = try? String(contentsOf: receipt, encoding: .utf8),
                   let readAt = Double(read), readAt >= until, readAt <= Date().timeIntervalSince1970,
                   pos > max(faultPosition + 1, initialBufferEnd + 0.5), pos > previousWitness + 0.02 {
                    witnessFrames += 1; previousWitness = pos
                    if witnessFrames == 3 {
                        restored = true
                        log(String(format:"RECOVERED_FRAME ep=%d position=%.2f actualRate=%.1f confirmedFrames=%d beyondBuffer=%.2fs",number,pos,model.player.rate,witnessFrames,pos-initialBufferEnd))
                    }
                }
            }
            if ended.count == 2 {
                guard restored, episodes.allSatisfy({ ended.contains($0.id) && frames[$0.number, default:0] >= 5 }) else {
                    log("FAIL insufficient completion or recovery evidence"); return
                }
                log(String(format:"RESULT completed=2 frames=%d,%d maxSampleGapSeconds=%.2f wall=%.2f",frames[first]!,frames[first+1]!,longestGap,now-begin))
                return
            }
        }
        log("FAIL timeout ended=\(ended.count) frames=\(frames)")
    }
}
