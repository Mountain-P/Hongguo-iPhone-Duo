import Foundation
import HongguoCore

/// One paused, already decoded preview. Its ownership can move to one formal route.
@MainActor
final class PreviewPlaybackHandoff: Identifiable {
    let id: UUID
    private var model: PlayerModel?
    private var eligibility: PlaybackHandoffEligibility
    private var expiryTask: Task<Void, Never>?
    private var currentContext: (() -> PlaybackHandoffEligibility.Context?)?

    init?(model: PlayerModel, snapshot: PreviewPlaybackSnapshot,
          context: PlaybackHandoffEligibility.Context) {
        guard let live = model.handoffPlayback, live.isReady, !live.isSeeking else { return nil }
        let id = UUID()
        self.id = id; self.model = model
        eligibility = .init(requestID: id, context: context, snapshot: snapshot,
            itemID: live.itemID, createdAt: ProcessInfo.processInfo.systemUptime)
        guard eligibility.status == .available else { return nil }
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            self?.dispose()
        }
    }

    deinit {
        expiryTask?.cancel()
        // A discarded, unclaimed token owns only the old paused preview.
        let abandoned = model
        Task { @MainActor in abandoned?.stop() }
    }

    func bindCurrentContext(_ provider: @escaping () -> PlaybackHandoffEligibility.Context?) {
        if currentContext == nil { currentContext = provider }
    }

    func claim(detail: SeriesDetail, episodeID: String, seconds: Double, service: any CatalogService,
               context: PlaybackHandoffEligibility.Context, sceneActive: Bool,
               onProgress: @escaping (Episode, Double, Double) -> Void) -> PlayerModel? {
        guard let model, let live = model.handoffPlayback,
              let latestContext = currentContext?(), latestContext == context else { dispose(); return nil }
        guard eligibility.claim(requestID: id, context: context, seriesID: detail.series.id,
            episodeID: episodeID, position: seconds, playback: live,
            isSceneActive: sceneActive, now: ProcessInfo.processInfo.systemUptime),
              model.promoteToFormalPlayback(detail: detail, service: service, onProgress: onProgress) else {
            trace("rejected")
            dispose()
            return nil
        }
        expiryTask?.cancel(); expiryTask = nil
        self.model = nil; currentContext = nil
        trace("claimed samePlayer=1 sameItem=1")
        return model
    }

    func dispose() {
        expiryTask?.cancel(); expiryTask = nil
        eligibility.cancel()
        let previous = model; model = nil; currentContext = nil
        previous?.stop()
    }

    private func trace(_ event: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-playback-transition-diagnostics") {
            NSLog("PlaybackHandoff %@", event)
        }
        #endif
    }
}
