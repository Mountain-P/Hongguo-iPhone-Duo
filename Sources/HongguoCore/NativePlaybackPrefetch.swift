// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public enum PlaybackPrefetchError: Error, Sendable, Equatable {
    case unsupported, budgetExceeded
}

enum NativePrefetchContext {
    @TaskLocal static var maximumBytes: Int?
}

/// One adjacent native episode's header only. Creates no AVPlayer or audio session.
/// The caller supplies its low-power/network policy and cancels on scrolling.
public actor NativePlaybackPrefetch {
    public enum Outcome: Sendable, Equatable { case prepared, skipped }
    public static let maximumPreparationBytes = 1024 * 1024
    private var operation: Task<Void, any Error>?
    private var generation = UUID()

    public init() {}
    deinit { operation?.cancel() }

    @discardableResult
    public func prepare(seriesID: String, episodeID: String, service: any CatalogService,
                        allowed: Bool = true) async throws -> Outcome {
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
                guard source.nativeStream != nil else { throw PlaybackPrefetchError.unsupported }
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

    public func cancel() {
        generation = UUID()
        operation?.cancel(); operation = nil
    }

    /// Memory-pressure/source-change hook. Active playback remains valid.
    public func clear() async {
        cancel()
        await NativeProgressiveMedia.shared.clearReusableCache()
    }
}
