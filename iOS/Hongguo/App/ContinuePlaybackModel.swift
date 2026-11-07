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
    case recordRemoved, recordChanged
    var errorDescription: String? {
        switch self {
        case .recordRemoved: "這筆觀看紀錄已移除，請從劇集詳情選擇播放。"
        case .recordChanged: "觀看紀錄已變更，請重新選擇播放位置。"
        }
    }
}

enum ContinuePlaybackSelection: Equatable, Sendable {
    case preferred
    case preview(PreviewPlaybackSnapshot)
}

enum ContinuePlaybackChoiceSelection { case saved, preview }

struct ContinuePlaybackChoice: Identifiable {
    let id = UUID()
    let seriesID: String
    let saved: PlaybackContinuation
    let preview: PlaybackContinuation
}

/// One manual launch and one presentation per parent; no player is created while browsing.
@MainActor
final class ContinuePlaybackModel: ObservableObject {
    typealias ProgressHandler = (Episode, Double, Double) -> Void
    @Published private(set) var route: ContinuePlaybackRoute?
    @Published private(set) var preparingSeriesID: String?
    @Published private(set) var failedSeriesID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingChoice: ContinuePlaybackChoice?
    private let loadDetail: @Sendable (any CatalogService, String) async throws -> SeriesDetail
    private var context: ContinuePlaybackContext?
    private var generation = UUID()
    private(set) var operation: Task<Void, Never>?
    private struct PendingPreview {
        let request: UUID
        let context: ContinuePlaybackContext
        let detail: SeriesDetail
        let service: any CatalogService
        let snapshot: PreviewPlaybackSnapshot
        let record: WatchRecord?
        let currentContext: @MainActor () -> ContinuePlaybackContext
        let latestRecord: @MainActor () -> WatchRecord?
        let progressFactory: @MainActor (SeriesDetail) -> ProgressHandler
    }
    private var pendingPreview: PendingPreview?

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

    func start(series: Series, requiresRecord: Bool = false, selection: ContinuePlaybackSelection = .preferred,
               context value: ContinuePlaybackContext, service: any CatalogService,
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
                if case .preview(let snapshot) = selection {
                    guard snapshot.seriesID == series.id, let preview = snapshot.continuation(in: detail) else {
                        throw CatalogError.unavailablePlayback
                    }
                    if let record, record.series.id == series.id,
                       detail.episodes.contains(where: { $0.id == record.episode.id && $0.isAvailable }),
                       let saved = PlaybackContinuation.preferred(seriesID: series.id, episodes: detail.episodes, record: record),
                       !PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: record, detail: detail) {
                        self.pendingPreview = .init(request: request, context: value, detail: detail, service: service,
                            snapshot: snapshot, record: record, currentContext: currentContext,
                            latestRecord: latestRecord, progressFactory: progressFactory)
                        self.pendingChoice = .init(seriesID: series.id, saved: saved, preview: preview)
                    } else {
                        self.present(detail: detail, continuation: preview, service: service, progressFactory: progressFactory)
                    }
                    return
                }
                guard let continuation = PlaybackContinuation.preferred(seriesID: series.id, episodes: detail.episodes,
                                                                        record: record) else {
                    throw CatalogError.unavailablePlayback
                }
                // No suspension between the live context check and creating the
                // captured-scope progress handler.
                self.present(detail: detail, continuation: continuation, service: service, progressFactory: progressFactory)
            } catch is CancellationError { return }
            catch {
                guard self.generation == request, self.context == value, currentContext() == value, !Task.isCancelled else { return }
                self.failedSeriesID = series.id; self.errorMessage = error.localizedDescription
            }
        }
    }

    /// A dialog is only an offer. Recheck the live scope and saved record when it is accepted.
    func choose(_ selection: ContinuePlaybackChoiceSelection, choiceID: UUID) {
        guard let choice = pendingChoice, choice.id == choiceID, let pending = pendingPreview else { return }
        guard !Task.isCancelled, generation == pending.request, context == pending.context,
              pending.context.permitsStart, pending.currentContext() == pending.context else {
            cancelPending(); return
        }
        guard pending.latestRecord() == pending.record else {
            fail(ContinuePlaybackError.recordChanged, seriesID: pending.detail.series.id)
            return
        }
        let continuation = selection == .saved ? choice.saved : choice.preview
        pendingChoice = nil; pendingPreview = nil
        present(detail: pending.detail, continuation: continuation, service: pending.service, progressFactory: pending.progressFactory)
    }

    private func present(detail: SeriesDetail, continuation: PlaybackContinuation, service: any CatalogService,
                         progressFactory: @MainActor (SeriesDetail) -> ProgressHandler) {
        let progress = progressFactory(detail)
        route = .init(detail: detail, continuation: continuation, service: service, onProgress: progress)
    }

    func fail(_ error: any Error, seriesID: String) {
        cancelPending(); failedSeriesID = seriesID; errorMessage = error.localizedDescription
    }

    func cancelPending() {
        generation = UUID(); operation?.cancel(); operation = nil
        preparingSeriesID = nil; failedSeriesID = nil; errorMessage = nil
        pendingChoice = nil; pendingPreview = nil
    }

    func dismiss() { cancelPending(); route = nil }
}
