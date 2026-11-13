import AVFoundation
import Foundation
import HongguoCore
import SwiftUI

/// Opt-in simulator entry point. The runner copies this into an isolated app.
@main @MainActor
struct HongguoApp: App {
    private let seriesID = "7642275752825605144"
    private let scope = "offline-source-qa"
    private var library: URL { URL.applicationSupportDirectory.appendingPathComponent("OfflineBatchQA") }

    var body: some Scene {
        WindowGroup {
            Color.black.task {
                do {
                    if CommandLine.arguments.contains("qa-reopen") { try await reopen() }
                    else { try await download() }
                } catch {
                    emit("FAIL \(type(of: error)): \(error.localizedDescription)")
                }
            }
        }
    }

    private func download() async throws {
        let range = CommandLine.arguments.first(where: { $0.hasPrefix("qa-episodes=") })?
            .dropFirst("qa-episodes=".count).split(separator: ",").compactMap { Int($0) } ?? [1, 91]
        guard range.count == 2 else { throw CatalogError.invalidID }
        let service = NativeCatalogService()
        let detail = try await service.detail(id: seriesID)
        let episodes = detail.episodes.filter { (range[0]...range[1]).contains($0.number) }
        guard episodes.count == range[1] - range[0] + 1 else { throw CatalogError.invalidID }
        let storage = try OfflineDownloads(directory: library) { item, destination, limit, progress in
            let started = Date()
            do {
                try await service.downloadOffline(seriesID: item.key.seriesID, episodeID: item.key.episodeID,
                    to: destination, maximumBytes: limit, progress: progress)
                emit("TRANSFER episode=\(item.episodeNumber) seconds=\(Int(Date().timeIntervalSince(started)))")
            } catch {
                emit("SOURCE_FAILURE episode=\(item.episodeNumber) code=\((error as? NativeSourceError)?.code ?? String(describing: type(of: error)))")
                throw error
            }
        }
        emit("START episodes=\(episodes.count) title=\(detail.series.title)")
        for episode in episodes {
            try await storage.enqueue(.init(key: .init(scope: scope, seriesID: seriesID, episodeID: episode.id),
                seriesTitle: detail.series.title, episodeNumber: episode.number, episodeTitle: episode.title))
        }
        var reported = Set<OfflineDownloadKey>()
        let deadline = ContinuousClock.now + .seconds(7200)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            let rows = await storage.snapshot()
            for item in rows where [.completed, .failed].contains(item.state) && reported.insert(item.key).inserted {
                emit("ITEM episode=\(item.episodeNumber) state=\(item.state.rawValue) bytes=\(item.receivedBytes) error=\(item.failure ?? "none")")
            }
            if CommandLine.arguments.contains("qa-stop-on-failure"), rows.contains(where: { $0.state == .failed }) {
                emit("RESULT baseline_failed completed=\(rows.filter { $0.state == .completed }.count)")
                return
            }
            if rows.count == episodes.count, rows.allSatisfy({ [.completed, .failed].contains($0.state) }) {
                let complete = rows.filter { $0.state == .completed }
                for item in complete {
                    guard try await storage.localURL(for: item.key)?.isFileURL == true else { throw OfflineDownloadError.invalidFile }
                    try await storage.recordProgress(for: item.key, position: 2, duration: 10)
                }
                emit("RESULT downloaded=\(complete.count) failed=\(rows.count-complete.count) bytes=\(complete.reduce(Int64(0)) { $0 + $1.receivedBytes })")
                return
            }
        }
        throw QAError.timeout
    }

    private func reopen() async throws {
        let storage = try OfflineDownloads(directory: library) { _, _, _, _ in
            throw QAError.unexpectedNetworkProvider
        }
        let rows = await storage.snapshot().filter { $0.state == .completed }
        guard !rows.isEmpty else { throw OfflineDownloadError.invalidFile }
        var frames = 0
        for item in rows.sorted(by: { $0.episodeNumber < $1.episodeNumber }) {
            guard item.position == 2, let url = try await storage.localURL(for: item.key), url.isFileURL else {
                throw OfflineDownloadError.invalidFile
            }
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 2 else { throw OfflineDownloadError.invalidFile }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.maximumSize = CGSize(width: 320, height: 320)
            for seconds in [0.0, duration / 2, max(0, duration - 1)] {
                let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
                guard image.image.width > 0 else { throw OfflineDownloadError.invalidFile }
                frames += 1
            }
            emit("LOCAL episode=\(item.episodeNumber) duration=\(Int(duration)) frames=3 resume=2")
        }
        emit("RESULT reopened=\(rows.count) localFrames=\(frames) providerCalls=0")
    }

    nonisolated private func emit(_ message: String) {
        FileHandle.standardOutput.write(Data(("OFFLINE_BATCH_QA " + message + "\n").utf8))
    }

    private enum QAError: Error { case timeout, unexpectedNetworkProvider }
}
