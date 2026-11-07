import Combine
import Foundation
import HongguoCore

struct ContinuePlaybackContext: Equatable, Sendable {
    let owner: LibraryOwner
    let revision: UUID
    let sceneActive: Bool
    var parentActive = true
    var permitsStart: Bool { sceneActive && parentActive }
}

struct ContinuePlaybackRoute: Identifiable {
    let id = UUID()
    let detail: SeriesDetail
    let continuation: PlaybackContinuation
    let service: any CatalogService
    let onProgress: (Episode, Double, Double) -> Void
}

private enum ContinuePlaybackError: Error, LocalizedError {
    case recordRemoved
    var errorDescription: String? { "這筆觀看紀錄已移除，請從劇集詳情選擇播放。" }
}

/// One manual launch and one presentation per parent; no player is created while browsing.
@MainActor
final class ContinuePlaybackModel: ObservableObject {
    typealias ProgressHandler = (Episode, Double, Double) -> Void
    @Published private(set) var route: ContinuePlaybackRoute?
    @Published private(set) var preparingSeriesID: String?
    @Published private(set) var failedSeriesID: String?
    @Published private(set) var errorMessage: String?
    private let loadDetail: @Sendable (any CatalogService, String) async throws -> SeriesDetail
    private var context: ContinuePlaybackContext?
    private var generation = UUID()
    private(set) var operation: Task<Void, Never>?

    init(loadDetail: @escaping @Sendable (any CatalogService, String) async throws -> SeriesDetail = { service, id in
        if let bridge = service as? BridgeService { return try await bridge.verifiedDetail(id: id) }
        return try await service.detail(id: id)
    }) { self.loadDetail = loadDetail }

    func updateContext(_ value: ContinuePlaybackContext) {
        guard context != value else { return }
        let identityChanged = context.map { $0.owner != value.owner || $0.revision != value.revision } ?? false
        context = value
        cancelPending()
        if identityChanged || !value.parentActive { route = nil }
        // Backgrounding cancels preparation. A displayed player remains mounted
        // and uses its existing scene pause policy instead of dismissing itself.
    }

    func start(series: Series, requiresRecord: Bool = false, context value: ContinuePlaybackContext, service: any CatalogService,
               currentContext: @escaping @MainActor () -> ContinuePlaybackContext,
               latestRecord: @escaping @MainActor () -> WatchRecord?,
               progressFactory: @escaping @MainActor (SeriesDetail) -> ProgressHandler) {
        guard !Task.isCancelled, value.permitsStart, currentContext() == value else { return }
        updateContext(value)
        guard route == nil else { return }
        cancelPending()
        let request = generation
        preparingSeriesID = series.id
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.generation == request { self.preparingSeriesID = nil; self.operation = nil }
            }
            do {
                let detail = try await self.loadDetail(service, series.id)
                try Task.checkCancellation()
                guard self.generation == request, self.context == value, currentContext() == value else { return }
                guard detail.series.id == series.id else { throw CatalogError.malformedResponse }
                let record = latestRecord()
                if requiresRecord, record?.series.id != series.id { throw ContinuePlaybackError.recordRemoved }
                guard let continuation = PlaybackContinuation.preferred(seriesID: series.id, episodes: detail.episodes,
                                                                        record: record) else {
                    throw CatalogError.unavailablePlayback
                }
                // No suspension between the live context check and creating the
                // captured-scope progress handler.
                let progress = progressFactory(detail)
                self.route = .init(detail: detail, continuation: continuation, service: service, onProgress: progress)
            } catch is CancellationError { return }
            catch {
                guard self.generation == request, self.context == value, currentContext() == value, !Task.isCancelled else { return }
                self.failedSeriesID = series.id; self.errorMessage = error.localizedDescription
            }
        }
    }

    func fail(_ error: any Error, seriesID: String) {
        cancelPending(); failedSeriesID = seriesID; errorMessage = error.localizedDescription
    }

    func cancelPending() {
        generation = UUID(); operation?.cancel(); operation = nil
        preparingSeriesID = nil; failedSeriesID = nil; errorMessage = nil
    }

    func dismiss() { cancelPending(); route = nil }
}
