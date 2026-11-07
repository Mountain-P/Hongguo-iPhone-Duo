// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation
import Foundation
import HongguoCore
import UniformTypeIdentifiers

/// Feeds AVFoundation clear MP4 ranges through its public resource-loader API.
/// The Core stream owns network policy, CENC processing and bounded range caching.
/// Retain this loader for as long as its asset is in use, then call invalidate().
public final class NativeMediaAssetLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
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

    public init(stream: NativeMediaStream) {
        self.stream = stream
        super.init()
    }

    deinit {
        // Task cancellation is thread-safe; no AVFoundation request is touched here.
        pending.values.forEach { $0.task?.cancel() }
    }

    public func makeAsset() -> AVURLAsset {
        let asset = AVURLAsset(url: stream.assetURL)
        asset.resourceLoader.setDelegate(self, queue: queue)
        return asset
    }

    public func invalidate() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
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
                continuation.resume(returning: true)
            }
        }
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
        if PlaybackRecovery.shouldRetry(error, attempt: 0) {
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
