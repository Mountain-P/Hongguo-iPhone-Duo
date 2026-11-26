// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum PlaybackPrefetchError: Error, Sendable, Equatable {
    case unsupported, budgetExceeded
}

enum NativePrefetchContext {
    @TaskLocal static var maximumBytes: Int?
}

/// One adjacent episode. Formal playback can also stage a bounded opening segment.
/// The caller supplies its low-power/network policy and cancels on scrolling.
public actor NativePlaybackPrefetch {
    public enum Outcome: Sendable, Equatable { case prepared, skipped }
    public static let maximumPreparationBytes = 1024 * 1024
    private var operation: Task<Void, any Error>?
    private var generation = UUID()
    public struct Opening: Sendable {
        public let source: PlaybackSource
        public let relayPrefix: RelayPlaybackOpening?
    }
    private var prepared: (series: String, episode: String, opening: Opening, expires: Double)?

    public func takePrepared(seriesID: String, episodeID: String, preference: NativePlaybackQuality? = nil) async -> PlaybackSource? {
        await takeOpening(seriesID: seriesID, episodeID: episodeID, preference: preference)?.source
    }

    public func takeOpening(seriesID: String, episodeID: String, preference: NativePlaybackQuality? = nil) async -> Opening? {
        guard let value = prepared, value.series == seriesID, value.episode == episodeID,
              value.expires > ProcessInfo.processInfo.systemUptime else { return nil }
        if let stream = value.opening.source.nativeStream {
            guard preference.map({ $0 == stream.variant.preference }) ?? true, await stream.isReusable,
                  prepared?.opening.source.nativeStream?.id == stream.id else { return nil }
        } else if value.opening.relayPrefix == nil { return nil }
        prepared = nil
        return value.opening
    }

    public init() {}
    deinit { operation?.cancel() }

    @discardableResult
    public func prepare(seriesID: String, episodeID: String, service: any CatalogService,
                        allowed: Bool = true, warmOpening: Bool = false, playbackRate: Float = 1) async throws -> Outcome {
        // A stale caller must not cancel the operation owned by a newer caller.
        try Task.checkCancellation()
        cancel()
        guard allowed else { return .skipped }
        try validateID(seriesID); try validateID(episodeID)
        try Task.checkCancellation()
        let request = generation
        let task = Task(priority: .utility) {
            try await NativePrefetchContext.$maximumBytes.withValue(Self.maximumPreparationBytes) {
                let source = try await service.playback(seriesID: seriesID, episodeID: episodeID, fresh: false)
                try Task.checkCancellation()
                guard let stream = source.nativeStream else {
                    guard warmOpening, let relay = service as? HomeRelayService, relay.servesMedia(at: source.url) else {
                        throw PlaybackPrefetchError.unsupported
                    }
                    let prefix = try await RelayPlaybackOpening.fetch(source, rate: playbackRate)
                    try Task.checkCancellation()
                    self.remember(source, relayPrefix: prefix, seriesID: seriesID, episodeID: episodeID, generation: request)
                    return
                }
                if warmOpening {
                    let count = PlaybackReadAheadBudget.bytes(totalLength: stream.totalLength, duration: stream.mediaDuration,
                        rate: playbackRate, wallSeconds: 12, minimum: 2 * 1024 * 1024, maximum: 8 * 1024 * 1024)
                    try await PlaybackTransferContext.$isBackground.withValue(true) {
                        var offset = 0
                        while offset < count {
                            try Task.checkCancellation()
                            try await PlaybackNetworkPriority.shared.waitForForeground()
                            let end = min(count, offset + 512 * 1024)
                            // The bounded opening stays in the stream's 8 MiB hot cache,
                            // so it is useful even if disk storage is unavailable.
                            _ = try await stream.read(range: offset..<end)
                            offset = end
                        }
                    }
                    try Task.checkCancellation()
                    self.remember(source, seriesID: seriesID, episodeID: episodeID, generation: request)
                }
            }
        }
        operation = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard generation == request else { throw CancellationError() }
            operation = nil
            return .prepared
        } catch {
            if generation == request { operation = nil }
            throw error
        }
    }

    private func remember(_ source: PlaybackSource, relayPrefix: RelayPlaybackOpening? = nil, seriesID: String, episodeID: String, generation request: UUID) {
        guard request == generation else { return }
        prepared = (seriesID, episodeID, Opening(source: source, relayPrefix: relayPrefix), ProcessInfo.processInfo.systemUptime + 45)
    }

    public func cancel() {
        prepared = nil
        generation = UUID()
        operation?.cancel(); operation = nil
    }

    /// Memory-pressure/source-change hook. Active playback remains valid.
    public func clear() async {
        cancel()
        await NativeProgressiveMedia.shared.clearReusableCache()
    }
}
