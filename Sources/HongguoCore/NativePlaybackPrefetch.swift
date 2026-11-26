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
    private var prepared: (series: String, episode: String, scope: UUID?, opening: Opening, expires: Double)?

    public func takePrepared(seriesID: String, episodeID: String, preference: NativePlaybackQuality? = nil) async -> PlaybackSource? {
        await takeOpening(seriesID: seriesID, episodeID: episodeID, preference: preference)?.source
    }

    public func takeOpening(seriesID: String, episodeID: String, preference: NativePlaybackQuality? = nil,
                            service: (any CatalogService)? = nil) async -> Opening? {
        guard let opening = await matchingOpening(seriesID: seriesID, episodeID: episodeID, preference: preference,
                                                   scope: service.flatMap(Self.scope), consume: true) else { return nil }
        if let local = await service?.offlinePlayback?.source(seriesID: seriesID, episodeID: episodeID) {
            return Opening(source: local, relayPrefix: nil)
        }
        return opening
    }

    private static func scope(_ service: any CatalogService) -> UUID? {
        (service as? NativeCatalogService)?.openingScope ?? (service as? HomeRelayService)?.openingScope
    }

    private func matchingOpening(seriesID: String, episodeID: String, preference: NativePlaybackQuality?,
                                 scope: UUID?, consume: Bool) async -> Opening? {
        guard let value = prepared, value.series == seriesID, value.episode == episodeID,
              scope == nil || scope == value.scope, value.expires > ProcessInfo.processInfo.systemUptime else { return nil }
        if let stream = value.opening.source.nativeStream {
            let owner = generation
            guard preference.map({ $0 == stream.variant.preference }) ?? true, await stream.isReusable,
                  owner == generation, prepared != nil else { return nil }
        } else if value.opening.relayPrefix == nil { return nil }
        if consume { prepared = nil }
        return value.opening
    }

    public init() {}
    deinit { operation?.cancel() }

    @discardableResult
    public func prepare(seriesID: String, episodeID: String, service: any CatalogService,
                        allowed: Bool = true, warmOpening: Bool = false, playbackRate: Float = 1) async throws -> Outcome {
        // A stale caller must not cancel the operation owned by a newer caller.
        try Task.checkCancellation()
        guard allowed else { cancel(); return .skipped }
        try validateID(seriesID); try validateID(episodeID)
        let scope = Self.scope(service)
        if warmOpening, let scope, prepared?.scope == scope {
            let owner = generation
            let existing = await matchingOpening(seriesID: seriesID, episodeID: episodeID,
                preference: (service as? NativeCatalogService)?.playbackQuality, scope: scope, consume: false)
            try Task.checkCancellation()
            guard owner == generation else { throw CancellationError() }
            if existing != nil { return .prepared }
        }
        cancel()
        let request = generation
        let task = Task(priority: .utility) {
            try await NativePrefetchContext.$maximumBytes.withValue(Self.maximumPreparationBytes) {
                let source = try await service.playback(seriesID: seriesID, episodeID: episodeID, fresh: false)
                try Task.checkCancellation()
                if source.url.isFileURL, service.offlinePlayback != nil { return }
                guard let stream = source.nativeStream else {
                    guard warmOpening, let relay = service as? HomeRelayService, relay.servesMedia(at: source.url) else {
                        throw PlaybackPrefetchError.unsupported
                    }
                    let prefix = try await RelayPlaybackOpening.fetch(source, rate: playbackRate)
                    try Task.checkCancellation()
                    self.remember(source, relayPrefix: prefix, seriesID: seriesID, episodeID: episodeID, scope: scope, generation: request)
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
                    self.remember(source, seriesID: seriesID, episodeID: episodeID, scope: scope, generation: request)
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

    private func remember(_ source: PlaybackSource, relayPrefix: RelayPlaybackOpening? = nil, seriesID: String, episodeID: String, scope: UUID?, generation request: UUID) {
        guard request == generation else { return }
        prepared = (seriesID, episodeID, scope, Opening(source: source, relayPrefix: relayPrefix), ProcessInfo.processInfo.systemUptime + 45)
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
