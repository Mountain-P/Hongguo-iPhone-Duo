// SPDX-License-Identifier: GPL-3.0-only
// Explicit, opt-in live validation. No URLs, content keys or anonymous identities are logged.
import Foundation
import HongguoCore
import HongguoPlayback
#if os(macOS)
@preconcurrency import AVFoundation
import CoreVideo

@main
enum NativePlaybackCheck {
    static func main() async {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var quality = NativePlaybackQuality.automatic
        if let index = arguments.firstIndex(of: "--quality") {
            guard index + 1 < arguments.count,
                  let selected = NativePlaybackQuality(rawValue: arguments[index + 1]) else {
                print("--quality must be automatic or dataSaver")
                exit(2)
            }
            quality = selected
            arguments.removeSubrange(index...(index + 1))
        }
        if arguments.count == 3, arguments[0] == "--resolve-only" {
            do {
                let started = Date()
                let source = try await NativeSourceResolver.shared.resolve(episodeID: arguments[1], contentType: arguments[2], fresh: true, quality: quality)
                print("nativeSource=PASS preference=\(quality.rawValue) codec=\(safeLabel(source.codec)) quality=\(safeLabel(source.quality)) width=\(source.width ?? 0) height=\(source.height ?? 0) fallback=\(source.qualityFallback) encrypted=\(source.contentKey != nil) elapsed=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
                return
            } catch {
                print("FAIL: \(error.localizedDescription)")
                exit(1)
            }
        }
        let seekOnly = arguments.first == "--seek"
        let startupOnly = arguments.first == "--startup" || seekOnly
        if startupOnly { arguments.removeFirst() }
        guard arguments.count == 2, let number = Int(arguments[1]), number > 0 else {
            print("Usage: swift run NativePlaybackCheck SERIES_ID EPISODE_NUMBER")
            print("       swift run NativePlaybackCheck --resolve-only EPISODE_ID CONTENT_TYPE")
            print("       swift run NativePlaybackCheck --startup SERIES_ID EPISODE_NUMBER")
            print("       swift run NativePlaybackCheck --seek SERIES_ID EPISODE_NUMBER")
            print("       All commands accept --quality automatic|dataSaver (default: automatic)")
            exit(2)
        }
        do {
            let service = NativeCatalogService(quality: quality)
            let detail = try await service.detail(id: arguments[0])
            guard let episode = detail.episodes.first(where: { $0.number == number }) else { throw CatalogError.invalidID }
            print("catalogueEpisodes=\(detail.episodes.count) selected=\(episode.number)")
            let started = Date()
            let source = try await service.playback(seriesID: detail.series.id, episodeID: episode.id, fresh: true)
            let preparedSeconds = Date().timeIntervalSince(started)
            if let stream = source.nativeStream {
                let variant = stream.variant
                print("selectedSource preference=\(variant.preference.rawValue) codec=\(safeLabel(variant.codec)) quality=\(safeLabel(variant.quality)) width=\(variant.width ?? 0) height=\(variant.height ?? 0) fallback=\(variant.qualityFallback) totalBytes=\(stream.totalLength)")
            }
            let nativeLoader = source.nativeStream.map { NativeMediaAssetLoader(stream: $0) }
            guard nativeLoader != nil || source.url.isFileURL else { throw CatalogError.unsafePlaybackURL }
            defer {
                nativeLoader?.invalidate()
                if source.url.isFileURL { try? FileManager.default.removeItem(at: source.url) }
            }
            let asset = nativeLoader?.makeAsset() ?? AVURLAsset(url: source.url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw CatalogError.malformedResponse }
            let video = try await asset.loadTracks(withMediaType: .video)
            guard let track = video.first else { throw CatalogError.malformedResponse }
            let reader = try AVAssetReader(asset: asset)
            if seekOnly {
                reader.timeRange = CMTimeRange(start: CMTime(seconds: duration * 0.7, preferredTimescale: 600),
                    duration: CMTime(seconds: min(5, duration * 0.3), preferredTimescale: 600))
            }
            let output = AVAssetReaderTrackOutput(track: track,
                outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw CatalogError.unavailablePlayback }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CatalogError.unavailablePlayback }
            var count = 0
            var firstFrameSeconds: Double?
            while autoreleasepool(invoking: { () -> Bool in
                guard output.copyNextSampleBuffer() != nil else { return false }
                count += 1
                if firstFrameSeconds == nil { firstFrameSeconds = Date().timeIntervalSince(started) }
                if startupOnly { reader.cancelReading(); return false }
                return true
            }) {}
            if startupOnly {
                guard count > 0, let firstFrameSeconds else { throw reader.error ?? CatalogError.unavailablePlayback }
                print("\(seekOnly ? "progressiveSeek70Percent" : "progressiveStartup")=PASS prepared=\(String(format: "%.2f", preparedSeconds))s firstDecodedFrame=\(String(format: "%.2f", firstFrameSeconds))s")
                return
            }
            guard reader.status == .completed, count > 0 else { throw reader.error ?? CatalogError.unavailablePlayback }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            var audioBuffers = 0
            for audioTrack in audio {
                let audioReader = try AVAssetReader(asset: asset)
                let audioOutput = AVAssetReaderTrackOutput(track: audioTrack,
                    outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                audioOutput.alwaysCopiesSampleData = false
                guard audioReader.canAdd(audioOutput) else { throw CatalogError.unavailablePlayback }
                audioReader.add(audioOutput)
                guard audioReader.startReading() else { throw audioReader.error ?? CatalogError.unavailablePlayback }
                let before = audioBuffers
                while autoreleasepool(invoking: { () -> Bool in
                    guard audioOutput.copyNextSampleBuffer() != nil else { return false }
                    audioBuffers += 1
                    return true
                }) {}
                guard audioReader.status == .completed, audioBuffers > before else {
                    throw audioReader.error ?? CatalogError.unavailablePlayback
                }
            }
            print("nativeProgressiveDecode=PASS frames=\(count) audioBuffers=\(audioBuffers) duration=\(String(format: "%.2f", duration))s firstFrame=\(String(format: "%.2f", firstFrameSeconds ?? 0))s elapsed=\(String(format: "%.1f", Date().timeIntervalSince(started)))s")
            print("This verifies the standalone source pipeline and macOS audio/video decoder; physical iPhone output is separate.")
        } catch {
            print("FAIL: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func safeLabel(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 32,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || " ._-×".unicodeScalars.contains($0) }) else {
            return "unspecified"
        }
        return value
    }
}
#else
@main enum NativePlaybackCheck {
    static func main() { print("NativePlaybackCheck requires macOS.") }
}
#endif
