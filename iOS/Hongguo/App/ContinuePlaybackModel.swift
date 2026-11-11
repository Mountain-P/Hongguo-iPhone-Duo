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

@MainActor
protocol PlaybackRouteResource: AnyObject, Sendable {
    func stop()
}

/// Route value copies share one resource even if SwiftUI rebuilds a cover.
@MainActor
final class PlaybackRouteSession {
    private var resource: (any PlaybackRouteResource)?
    private var isResolving = false
    private(set) var isDisposed = false

    func resolve<Resource: PlaybackRouteResource>(make: () -> Resource) -> Resource? {
        guard !isDisposed else { return nil }
        if let resource { return resource as? Resource }
        guard !isResolving else { return nil }
        isResolving = true
        defer { isResolving = false }
        let created = make()
        guard !isDisposed else { created.stop(); return nil }
        resource = created
        return created
    }

    func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        let previous = resource
        resource = nil
        previous?.stop()
    }

    deinit {
        let abandoned = resource
        Task { @MainActor in abandoned?.stop() }
    }
}

struct ContinuePlaybackRoute: Identifiable {
    let id = UUID()
    let detail: SeriesDetail
    let continuation: PlaybackContinuation
    let service: any CatalogService
    let onProgress: (Episode, Double, Double) -> Void
    let session: PlaybackRouteSession

    @MainActor
    init(detail: SeriesDetail, continuation: PlaybackContinuation, service: any CatalogService,
         onProgress: @escaping (Episode, Double, Double) -> Void) {
        self.detail = detail
        self.continuation = continuation
        self.service = service
        self.onProgress = onProgress
        self.session = PlaybackRouteSession()
    }
}

private enum ContinuePlaybackError: Error, LocalizedError, Equatable {
    case recordRemoved, recordChanged, preparationTimedOut
    var errorDescription: String? {
        switch self {
        case .recordRemoved: "這筆觀看紀錄已移除，請從劇集詳情選擇播放。"
        case .recordChanged: "觀看紀錄已變更，請重新選擇播放位置。"
        case .preparationTimedOut: "劇集準備逾時，請重試。"
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
    @Published private(set) var canRetry = false
    private let loadDetail: @Sendable (any CatalogService, String) async throws -> SeriesDetail
    private let preparationTimeout: Duration
    private var context: ContinuePlaybackContext?
    private var generation = UUID()
    private(set) var operation: Task<Void, Never>?
    private var preparationDeadline: Task<Void, Never>?
    private struct LaunchIntent {
        let series: Series
        let requiresRecord: Bool
        let selection: ContinuePlaybackSelection
        let context: ContinuePlaybackContext
        let service: any CatalogService
        let currentContext: @MainActor () -> ContinuePlaybackContext
        let latestRecord: @MainActor () -> WatchRecord?
        let progressFactory: @MainActor (SeriesDetail) -> ProgressHandler
    }
    private struct PendingPreview {
        let request: UUID
        let intent: LaunchIntent
        let detail: SeriesDetail
        let record: WatchRecord?
    }
    private var launchIntent: LaunchIntent?
    private var pendingPreview: PendingPreview?

    init(preparationTimeout: Duration = .seconds(30),
         loadDetail: @escaping @Sendable (any CatalogService, String) async throws -> SeriesDetail = { service, id in
        if let bridge = service as? BridgeService { return try await bridge.verifiedDetail(id: id) }
        return try await service.detail(id: id)
    }) {
        self.preparationTimeout = preparationTimeout
        self.loadDetail = loadDetail
    }

    deinit {
        operation?.cancel()
        preparationDeadline?.cancel()
    }

    func updateContext(_ value: ContinuePlaybackContext) {
        guard context != value else { return }
        let identityChanged = context.map { $0.owner != value.owner || $0.revision != value.revision } ?? false
        context = value
        cancelPending()
        if identityChanged || !value.parentActive { clearRoute() }
        // Backgrounding cancels preparation. A displayed player remains mounted
        // and uses its existing scene pause policy instead of dismissing itself.
    }

    func start(series: Series, requiresRecord: Bool = false, selection: ContinuePlaybackSelection = .preferred,
               context value: ContinuePlaybackContext, service: any CatalogService,
               currentContext: @escaping @MainActor () -> ContinuePlaybackContext,
               latestRecord: @escaping @MainActor () -> WatchRecord?,
               progressFactory: @escaping @MainActor (SeriesDetail) -> ProgressHandler) {
        guard !Task.isCancelled, route == nil else { return }
        cancelPending()
        guard value.permitsStart, currentContext() == value else { return }
        updateContext(value)
        begin(.init(series: series, requiresRecord: requiresRecord, selection: selection, context: value,
                    service: service, currentContext: currentContext, latestRecord: latestRecord, progressFactory: progressFactory))
    }

    /// Explicit, read-only re-preparation. The original preview snapshot is never recaptured.
    func retry() {
        guard canRetry, operation == nil, preparingSeriesID == nil, pendingChoice == nil, route == nil,
              let intent = launchIntent else { return }
        guard !Task.isCancelled, context == intent.context, intent.context.permitsStart,
              intent.currentContext() == intent.context else { cancelPending(); return }
        begin(intent)
    }

    private func begin(_ intent: LaunchIntent) {
        cancelPending()
        launchIntent = intent
        let request = generation
        let loader = loadDetail
        let deadline = ContinuousClock.now.advanced(by: preparationTimeout)
        preparingSeriesID = intent.series.id
        operation = Task { @MainActor [weak self] in
            // Do not retain the model across an uncooperative transport suspension.
            defer { self?.finish(request: request) }
            do {
                let detail = try await loader(intent.service, intent.series.id)
                try Task.checkCancellation()
                try self?.accept(detail: detail, intent: intent, request: request)
            } catch is CancellationError { self?.discardCancelled(request: request) }
            catch {
                self?.recordFailure(error, intent: intent, request: request)
            }
        }
        preparationDeadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled else { return }
            self?.expirePreparation(request: request)
        }
    }

    private func accepts(_ intent: LaunchIntent, request: UUID) -> Bool {
        generation == request && context == intent.context && intent.context.permitsStart
            && intent.currentContext() == intent.context
    }

    private func accept(detail: SeriesDetail, intent: LaunchIntent, request: UUID) throws {
        guard accepts(intent, request: request) else { discardCancelled(request: request); return }
        guard detail.series.id == intent.series.id else { throw CatalogError.malformedResponse }
        let record = intent.latestRecord()
        if intent.requiresRecord, record?.series.id != intent.series.id { throw ContinuePlaybackError.recordRemoved }
        if case .preview(let snapshot) = intent.selection {
            guard snapshot.seriesID == intent.series.id, let preview = snapshot.continuation(in: detail) else {
                throw CatalogError.unavailablePlayback
            }
            if let record, record.series.id == intent.series.id,
               detail.episodes.contains(where: { $0.id == record.episode.id && $0.isAvailable }),
               let saved = PlaybackContinuation.preferred(seriesID: intent.series.id, episodes: detail.episodes, record: record),
               !PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: record, detail: detail) {
                pendingPreview = .init(request: request, intent: intent, detail: detail, record: record)
                pendingChoice = .init(seriesID: intent.series.id, saved: saved, preview: preview)
            } else {
                present(detail: detail, continuation: preview, service: intent.service, progressFactory: intent.progressFactory)
            }
            return
        }
        guard let continuation = PlaybackContinuation.preferred(seriesID: intent.series.id, episodes: detail.episodes, record: record) else {
            throw CatalogError.unavailablePlayback
        }
        // No suspension between the live context check and capturing the original-scope handler.
        present(detail: detail, continuation: continuation, service: intent.service, progressFactory: intent.progressFactory)
    }

    private func finish(request: UUID) {
        guard generation == request else { return }
        clearPreparation()
    }

    private func clearPreparation() {
        preparationDeadline?.cancel()
        preparationDeadline = nil
        preparingSeriesID = nil; operation = nil
    }

    private func expirePreparation(request: UUID) {
        guard generation == request, operation != nil, let intent = launchIntent else { return }
        guard accepts(intent, request: request) else { discardCancelled(request: request); return }
        // A transport may ignore cancellation. Invalidate its generation before
        // exposing Retry so the old completion cannot affect the new request.
        generation = UUID()
        operation?.cancel()
        clearPreparation()
        failedSeriesID = intent.series.id
        errorMessage = ContinuePlaybackError.preparationTimedOut.errorDescription
        canRetry = true
    }

    private func discardCancelled(request: UUID) {
        guard generation == request else { return }
        cancelPending()
    }

    private func recordFailure(_ error: any Error, intent: LaunchIntent, request: UUID) {
        guard !Task.isCancelled, accepts(intent, request: request) else { discardCancelled(request: request); return }
        let retryable = (error as? ContinuePlaybackError) == .recordChanged
            || PlaybackRecovery.shouldRetry(error, attempt: 0)
        finish(request: request)
        pendingChoice = nil; pendingPreview = nil
        launchIntent = retryable ? intent : nil
        failedSeriesID = intent.series.id; errorMessage = error.localizedDescription
        canRetry = retryable
    }

    /// A dialog is only an offer. Recheck the live scope and saved record when it is accepted.
    func choose(_ selection: ContinuePlaybackChoiceSelection, choiceID: UUID) {
        guard let choice = pendingChoice, choice.id == choiceID, let pending = pendingPreview else { return }
        guard !Task.isCancelled, accepts(pending.intent, request: pending.request) else {
            cancelPending(); return
        }
        guard pending.intent.latestRecord() == pending.record else {
            recordFailure(ContinuePlaybackError.recordChanged, intent: pending.intent, request: pending.request)
            return
        }
        let continuation = selection == .saved ? choice.saved : choice.preview
        pendingChoice = nil; pendingPreview = nil
        present(detail: pending.detail, continuation: continuation, service: pending.intent.service, progressFactory: pending.intent.progressFactory)
    }

    private func present(detail: SeriesDetail, continuation: PlaybackContinuation, service: any CatalogService,
                         progressFactory: @MainActor (SeriesDetail) -> ProgressHandler) {
        let progress = progressFactory(detail)
        launchIntent = nil; canRetry = false
        clearRoute()
        route = .init(detail: detail, continuation: continuation, service: service, onProgress: progress)
    }

    func fail(_ error: any Error, seriesID: String) {
        cancelPending(); failedSeriesID = seriesID; errorMessage = error.localizedDescription
    }

    func cancelPending() {
        canRetry = false; launchIntent = nil
        generation = UUID(); operation?.cancel()
        clearPreparation()
        failedSeriesID = nil; errorMessage = nil
        pendingChoice = nil; pendingPreview = nil
    }

    private func clearRoute() {
        route?.session.dispose()
        route = nil
    }

    func dismiss() { cancelPending(); clearRoute() }
}
