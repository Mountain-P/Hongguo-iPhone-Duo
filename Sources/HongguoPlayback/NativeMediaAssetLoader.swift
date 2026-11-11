// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation
import HongguoCore
import UniformTypeIdentifiers

/// Feeds AVFoundation clear MP4 ranges through its public resource-loader API.
/// The Core stream owns network policy, CENC processing and bounded range caching.
/// Retain this loader for as long as its asset is in use, then call invalidate().
public final class NativeMediaAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    struct ReadAheadWindow {
        static let chunkSize = 512 * 1024
        private static let diskWindowBytes = 16 * 1024 * 1024

        static func memoryWindowBytes(playbackRate: Float) -> Int {
            playbackRate >= 1.5 ? 4 * 1024 * 1024 : 2 * 1024 * 1024
        }

        private var next = 0
        private var end = 0
        var hasPendingRange: Bool { next < end }

        mutating func extend(after cursor: Int, totalLength: Int, memoryOnly: Bool = false, playbackRate: Float = 1) {
            let windowBytes = memoryOnly ? Self.memoryWindowBytes(playbackRate: playbackRate) : Self.diskWindowBytes
            let limit = cursor + min(windowBytes, totalLength - cursor)
            end = memoryOnly && limit < totalLength ? limit / Self.chunkSize * Self.chunkSize : limit
        }

        mutating func skipConsumedChunks(before cursor: Int) {
            next = max(next, cursor / Self.chunkSize * Self.chunkSize)
        }

        mutating func nextRange(after prefetched: Range<Int>?, totalLength: Int) -> Range<Int>? {
            // A temporary failure must leave the attempted chunk eligible for the
            // next demand. Advance only when the worker confirms a successful fetch.
            if let prefetched { next = max(next, prefetched.upperBound) }
            guard hasPendingRange else { return nil }
            return next..<(next + min(Self.chunkSize, totalLength - next))
        }
    }

    private final class Pending {
        let request: AVAssetResourceLoadingRequest
        let generation = UUID()
        let end: Int
        var offset: Int
        var task: Task<Void, Never>?

        init(request: AVAssetResourceLoadingRequest, range: Range<Int>) {
            self.request = request
            self.offset = range.lowerBound
            self.end = range.upperBound
        }
    }

    private let stream: NativeMediaStream
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.native-asset")
    private let chunkSize = 256 * 1024
    // All AVFoundation loading-request references are read and mutated only on queue.
    private var pending: [ObjectIdentifier: Pending] = [:]
    private var stopped = false
    private var readAheadEnabled = false
    private var readAheadMemoryOnly = false
    private var readAheadRate: Float = 1
    private var readAheadStorageFailed = false
    private var usesMemoryReadAhead: Bool { readAheadMemoryOnly || readAheadStorageFailed }
    private var readAheadTask: Task<Void, Never>?
    private var readAheadGeneration = UUID()
    private var readAheadWindow = ReadAheadWindow()
    private var latestDemandRequest: ObjectIdentifier?
    private var lastDemandEnd: Int?

    public init(stream: NativeMediaStream) {
        self.stream = stream
        super.init()
    }

    deinit {
        // Task cancellation is thread-safe; no AVFoundation request is touched here.
        pending.values.forEach { $0.task?.cancel() }
        readAheadTask?.cancel()
    }

    public func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: stream.assetURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    public func noteBufferStarvation() {
        stream.noteBufferStarvation()
    }

    /// Network/scene/power policy is owned by the active player. This can be called
    /// from any queue; speculation never starts merely because an asset was created.
    public func setReadAheadEnabled(_ enabled: Bool, memoryOnly: Bool = false, playbackRate: Float = 1) {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            let wasMemoryOnly = self.usesMemoryReadAhead
            let previousWindow = ReadAheadWindow.memoryWindowBytes(playbackRate: self.readAheadRate)
            self.readAheadEnabled = enabled
            self.readAheadMemoryOnly = memoryOnly
            self.readAheadRate = playbackRate
            let windowChanged = self.usesMemoryReadAhead && previousWindow != ReadAheadWindow.memoryWindowBytes(playbackRate: playbackRate)
            if !enabled || wasMemoryOnly != self.usesMemoryReadAhead || windowChanged { self.cancelReadAhead() }
            if enabled, let cursor = self.lastDemandEnd { self.extendReadAhead(after: cursor) }
        }
    }

    public func invalidate() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            cancelReadAhead()
            let entries = Array(pending.values)
            pending.removeAll()
            for entry in entries {
                entry.task?.cancel()
                if !entry.request.isCancelled && !entry.request.isFinished {
                    entry.request.finishLoading(with: Self.failure(code: -999, message: "影片載入已停止。"))
                }
            }
        }
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !stopped else { return false }
        guard !loadingRequest.isCancelled, !loadingRequest.isFinished else { return true }
        guard loadingRequest.request.url == stream.assetURL,
              stream.totalLength > 0, let total = Int64(exactly: stream.totalLength) else {
            loadingRequest.finishLoading(with: Self.failure(code: 1, message: "影片資料範圍無效。"))
            return true
        }

        if let information = loadingRequest.contentInformationRequest {
            information.contentType = UTType.mpeg4Movie.identifier
            information.contentLength = total
            information.isByteRangeAccessSupported = true
        }
        guard let data = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let initialOffset = data.requestedOffset
        let currentOffset = data.currentOffset
        let initialLength = data.requestedLength
        guard initialOffset >= 0, currentOffset >= 0, initialLength >= 0,
              initialOffset <= total, currentOffset <= total else {
            loadingRequest.finishLoading(with: Self.failure(code: 1, message: "影片資料範圍無效。"))
            return true
        }
        let offset = max(initialOffset, currentOffset)
        let end: Int64
        if data.requestsAllDataToEndOfResource {
            // AVFoundation may use NSIntegerMax for requestedLength here. Apple
            // requires ignoring it and incrementally serving through EOF.
            end = total
        } else {
            guard let length = Int64(exactly: initialLength) else {
                loadingRequest.finishLoading(with: Self.failure(code: 1, message: "影片資料範圍無效。"))
                return true
            }
            let (requestedEnd, overflow) = initialOffset.addingReportingOverflow(length)
            guard !overflow else {
                loadingRequest.finishLoading(with: Self.failure(code: 1, message: "影片資料範圍無效。"))
                return true
            }
            end = min(requestedEnd, total)
        }
        guard offset < end else {
            loadingRequest.finishLoading()
            return true
        }
        guard let start = Int(exactly: offset), let limit = Int(exactly: end) else {
            loadingRequest.finishLoading(with: Self.failure(code: 1, message: "影片資料範圍無效。"))
            return true
        }

        let identifier = ObjectIdentifier(loadingRequest)
        // A seek takes the foreground slot before its first bytes arrive. Cancelling
        // this loader's speculative consumer does not cancel an attached demand reader.
        if let previous = lastDemandEnd, abs(start - previous) > ReadAheadWindow.chunkSize {
            cancelReadAhead(); lastDemandEnd = nil
        }
        latestDemandRequest = identifier
        // A delegate normally receives a request once; never leave an earlier
        // task alive if AVFoundation asks again for that same request object.
        pending.removeValue(forKey: identifier)?.task?.cancel()
        let entry = Pending(request: loadingRequest, range: start..<limit)
        let generation = entry.generation
        let chunkSize = self.chunkSize
        let stream = self.stream
        pending[identifier] = entry
        entry.task = Task { [weak self] in
            do {
                var cursor = start
                while cursor < limit {
                    try Task.checkCancellation()
                    let count = min(chunkSize, limit - cursor)
                    let next = cursor + count
                    let bytes = try await stream.read(range: cursor..<next)
                    try Task.checkCancellation()
                    guard bytes.count == count else { throw NativeMediaError.invalidResponse }
                    guard let self, await self.deliver(bytes, offset: cursor, request: identifier, generation: generation) else { return }
                    cursor = next
                }
                self?.finish(request: identifier, generation: generation)
            } catch {
                self?.finish(request: identifier, generation: generation, error: error)
            }
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeValue(forKey: ObjectIdentifier(loadingRequest))?.task?.cancel()
        // AVFoundation owns cancellation completion; finishLoading is not sent again.
    }

    private func deliver(_ bytes: Data, offset: Int, request identifier: ObjectIdentifier, generation: UUID) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.stopped, let entry = self.pending[identifier], entry.generation == generation else {
                    continuation.resume(returning: false)
                    return
                }
                guard !entry.request.isCancelled, !entry.request.isFinished, entry.task?.isCancelled != true else {
                    self.pending.removeValue(forKey: identifier)
                    entry.task?.cancel()
                    continuation.resume(returning: false)
                    return
                }
                guard entry.offset == offset, bytes.count <= entry.end - entry.offset,
                      let data = entry.request.dataRequest else {
                    self.finishOnQueue(request: identifier, generation: generation,
                                       error: Self.failure(code: 1, message: "影片資料範圍無效。"))
                    continuation.resume(returning: false)
                    return
                }
                data.respond(with: bytes)
                entry.offset += bytes.count
                if self.latestDemandRequest == identifier {
                    self.lastDemandEnd = entry.offset
                    self.extendReadAhead(after: entry.offset)
                }
                continuation.resume(returning: true)
            }
        }
    }

    private func extendReadAhead(after cursor: Int) {
        guard readAheadEnabled, !stopped, cursor < stream.totalLength else { return }
        let memoryOnly = usesMemoryReadAhead
        readAheadWindow.extend(after: cursor, totalLength: stream.totalLength, memoryOnly: memoryOnly, playbackRate: readAheadRate)
        readAheadWindow.skipConsumedChunks(before: cursor)
        if readAheadTask == nil {
            guard readAheadWindow.hasPendingRange else { return }
            let generation = UUID(); readAheadGeneration = generation
            let stream = stream
            readAheadTask = Task(priority: .utility) { [weak self] in
                var completed = false
                var storageFailed = false
                do {
                    var prefetched: Range<Int>?
                    while let range = await self?.nextReadAheadRange(after: prefetched, generation: generation) {
                        try await Self.prefetchWithBackoff(range) {
                            if memoryOnly { _ = try await stream.read(range: $0) }
                            else { try await stream.prefetch(range: $0) }
                        }
                        prefetched = range
                    }
                    completed = true
                } catch PlaybackPrefetchError.unsupported where !memoryOnly { storageFailed = true }
                catch { /* Read-ahead failures never replace foreground errors. */ }
                self?.finishReadAhead(generation: generation, continueIfExtended: completed, storageFailed: storageFailed)
            }
        }
    }

    static func prefetchWithBackoff(_ range: Range<Int>,
                                    prefetch: (Range<Int>) async throws -> Void) async throws {
        var delay = Duration.milliseconds(50)
        var retriedTransport = false
        while true {
            try Task.checkCancellation()
            do {
                try await prefetch(range)
                return
            } catch NativeMediaError.busy where delay <= .milliseconds(400) {
                // A busy disk cache can finish opening or committing a chunk
                // while AVFoundation has no further successful reads to wake us.
                try await Task.sleep(for: delay)
                delay *= 2
            } catch where !retriedTransport && PlaybackRecovery.shouldRetry(error, attempt: 0) {
                retriedTransport = true
            }
        }
    }

    private func nextReadAheadRange(after prefetched: Range<Int>?, generation: UUID) async -> Range<Int>? {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, !self.stopped, self.readAheadEnabled,
                      self.readAheadGeneration == generation else {
                    continuation.resume(returning: nil); return
                }
                let range = self.readAheadWindow.nextRange(after: prefetched, totalLength: self.stream.totalLength)
                continuation.resume(returning: range)
            }
        }
    }

    private func finishReadAhead(generation: UUID, continueIfExtended: Bool, storageFailed: Bool) {
        queue.async { [weak self] in
            guard let self, self.readAheadGeneration == generation else { return }
            self.readAheadTask = nil
            if storageFailed {
                self.readAheadStorageFailed = true
                self.readAheadWindow = ReadAheadWindow()
            }
            if storageFailed || (continueIfExtended && self.readAheadWindow.hasPendingRange),
               let cursor = self.lastDemandEnd {
                self.extendReadAhead(after: cursor)
            }
        }
    }

    private func cancelReadAhead() {
        readAheadGeneration = UUID()
        readAheadTask?.cancel(); readAheadTask = nil
        readAheadWindow = ReadAheadWindow()
    }

    private func finish(request identifier: ObjectIdentifier, generation: UUID, error: (any Error)? = nil) {
        let safeError = error.map(Self.sanitized)
        queue.async { [weak self] in
            self?.finishOnQueue(request: identifier, generation: generation, error: safeError)
        }
    }

    private func finishOnQueue(request identifier: ObjectIdentifier, generation: UUID, error: NSError?) {
        guard let entry = pending[identifier], entry.generation == generation else { return }
        pending.removeValue(forKey: identifier)
        entry.task?.cancel()
        guard !entry.request.isCancelled, !entry.request.isFinished else { return }
        if let error { entry.request.finishLoading(with: error) }
        else if entry.offset == entry.end { entry.request.finishLoading() }
        else { entry.request.finishLoading(with: Self.failure(code: 2, message: "影片來源回應不完整，請重試。")) }
    }

    private static func sanitized(_ error: any Error) -> NSError {
        if error is CancellationError { return failure(code: -999, message: "影片載入已取消。") }
        if PlaybackRecovery.shouldRetryAssetRead(error) {
            return failure(code: PlaybackRecovery.transientAssetErrorCode, message: "影片連線暫時中斷，請重試。")
        }
        if let media = error as? NativeMediaError {
            if case .httpStatus(let status) = media { return failure(code: status, message: media.localizedDescription) }
            return failure(code: 2, message: media.localizedDescription)
        }
        if let catalog = error as? CatalogError {
            if case .httpStatus(let status) = catalog { return failure(code: status, message: catalog.localizedDescription) }
            if catalog == .unauthorized { return failure(code: 401, message: "來源目前未授權提供本集播放。") }
        }
        if let progressive = error as? NativeProgressiveError {
            return failure(code: 2, message: progressive.localizedDescription)
        }
        return failure(code: 2, message: "影片載入中斷，請檢查網路後重試。")
    }

    private static func failure(code: Int, message: String) -> NSError {
        NSError(domain: "HongguoNativeMediaAsset", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
