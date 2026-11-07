import Foundation
import Testing
import HongguoCore
@testable import HongguoAppSupport

@MainActor
struct ContinuePlaybackModelTests {
    @Test func nothingLoadsBeforeTheButtonAndReadyUsesTheLatestRecordWithoutFetchingVideo() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record(seconds: 10))
        launcher.updateContext(box.context)
        #expect(await service.detailCalls == 0)
        launch(launcher, service: service, box: box)
        let operation = try #require(launcher.operation)
        await service.waitForCalls(1)
        box.record = record(seconds: 45)
        await service.release("100", detail: detail())
        await operation.value
        let route = try #require(launcher.route)
        #expect(route.continuation.episode.id == "900" && route.continuation.seconds == 45)
        #expect(box.factories == 1)
        #expect(await service.videoCalls == 0)
    }

    @Test func aCompletedEpisodeAdvancesPastLockedEpisodesAndTheCompletedFinalEpisodeReplays() async throws {
        for (savedID, savedNumber, expectedID) in [("900", 1, "902"), ("902", 3, "902")] {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel()
            let box = ContinueBox(record: record(id: savedID, number: savedNumber, seconds: 90))
            launch(launcher, service: service, box: box)
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1)
            await service.release("100", detail: detail())
            await operation.value
            let route = try #require(launcher.route)
            #expect(route.continuation.episode.id == expectedID && route.continuation.seconds == 0)
        }
    }

    @Test func staleSavedEpisodeIDCannotSupplyAnUnverifiedEpisodeOrResumePosition() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel()
        let box = ContinueBox(record: record(id: "999", number: 1, seconds: 45))
        launch(launcher, service: service, box: box)
        let operation = try #require(launcher.operation)
        await service.waitForCalls(1); await service.release("100", detail: detail())
        await operation.value
        #expect(launcher.route?.continuation.episode.id == "900")
        #expect(launcher.route?.continuation.seconds == 0)
    }

    @Test func deletingTheRecordDuringPreparationDoesNotSilentlyTurnContinueIntoEpisodeOne() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
        launch(launcher, service: service, box: box)
        let operation = try #require(launcher.operation)
        await service.waitForCalls(1); box.record = nil
        await service.release("100", detail: detail()); await operation.value
        #expect(launcher.route == nil && launcher.errorMessage != nil && box.factories == 0)
        launch(launcher, service: service, box: box, requiresRecord: false)
        let gridOperation = try #require(launcher.operation)
        await service.waitForCalls(2); await service.release("100", detail: detail()); await gridOperation.value
        #expect(launcher.route?.continuation.episode.id == "900" && launcher.route?.continuation.seconds == 0)
    }

    @Test func changedOwnerSourceSceneAndExplicitCancellationAllRejectUncooperativeLateReplies() async throws {
        for change in 0..<5 {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
            launch(launcher, service: service, box: box)
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1)
            switch change {
            case 0: box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
            case 1: box.context = .init(owner: .guest, revision: UUID(), sceneActive: true)
            case 2: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: false)
            case 3: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: true, parentActive: false)
            default: launcher.cancelPending()
            }
            if change < 4 { launcher.updateContext(box.context) }
            await service.release("100", detail: detail()); await operation.value
            #expect(launcher.route == nil && launcher.preparingSeriesID == nil && box.factories == 0)
        }
    }

    @Test func liveContextGuardRejectsAccountChangeEvenBeforeSwiftUIHasUpdatedTheLauncher() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
        launch(launcher, service: service, box: box)
        let operation = try #require(launcher.operation)
        await service.waitForCalls(1)
        box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
        await service.release("100", detail: detail()); await operation.value
        #expect(launcher.route == nil && box.factories == 0)
    }

    @Test func anOldCancelledRequestCannotClearOrReplaceTheNewerPresentation() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
        launch(launcher, service: service, box: box)
        let old = try #require(launcher.operation)
        await service.waitForCalls(1)
        launch(launcher, seriesID: "200", service: service, box: box, requiresRecord: false)
        let replacement = try #require(launcher.operation)
        await service.waitForCalls(2)
        await service.release("100", detail: detail()); await old.value
        #expect(launcher.preparingSeriesID == "200" && launcher.route == nil)
        await service.release("200", detail: detail(seriesID: "200")); await replacement.value
        #expect(launcher.route?.detail.series.id == "200")
        let routeID = launcher.route?.id
        launch(launcher, service: service, box: box)
        #expect(launcher.route?.id == routeID)
        #expect(await service.detailCalls == 2)
    }

    @Test func wrongSeriesUnavailableEpisodesAndSourceErrorsNeverConstructAPlayerRoute() async throws {
        for outcome in 0..<3 {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
            launch(launcher, service: service, box: box)
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1)
            switch outcome {
            case 0: await service.release("100", detail: detail(seriesID: "200"))
            case 1: await service.release("100", detail: .init(series: .init(id: "100", title: "Fixture"), episodes: []))
            default: await service.fail("100")
            }
            await operation.value
            #expect(launcher.route == nil && launcher.failedSeriesID == "100" && launcher.errorMessage != nil)
            #expect(box.factories == 0)
        }
    }

    @Test func thePresentedProgressHandlerRemainsBoundToItsOriginalScopeAfterAccountChange() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
        launch(launcher, service: service, box: box)
        let operation = try #require(launcher.operation)
        await service.waitForCalls(1); await service.release("100", detail: detail()); await operation.value
        let route = try #require(launcher.route)
        let routeID = route.id
        box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: false)
        launcher.updateContext(box.context)
        #expect(launcher.route?.id == routeID)
        box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
        launcher.updateContext(box.context)
        #expect(launcher.route == nil)
        route.onProgress(route.continuation.episode, 50, 90)
        #expect(box.progressOwners == [.guest])
    }

    private func launch(_ launcher: ContinuePlaybackModel, seriesID: String = "100", service: ContinueServiceProbe,
                        box: ContinueBox, requiresRecord: Bool = true) {
        launcher.start(series: .init(id: seriesID, title: "Fixture"), requiresRecord: requiresRecord, context: box.context,
            service: service, currentContext: { box.context }, latestRecord: { box.record }, progressFactory: { _ in
                box.factories += 1
                let capturedOwner = box.context.owner
                return { _, _, _ in box.progressOwners.append(capturedOwner) }
            })
    }
    private func detail(seriesID: String = "100") -> SeriesDetail {
        .init(series: .init(id: seriesID, title: "Fixture"), episodes: [
            .init(id: "900", number: 1, title: "1"), .init(id: "901", number: 2, title: "2", isAvailable: false),
            .init(id: "902", number: 3, title: "3")])
    }
    private func record(id: String = "900", number: Int = 1, seconds: Double = 30) -> WatchRecord {
        .init(series: .init(id: "100", title: "Fixture"), episode: .init(id: id, number: number, title: "Saved"), seconds: seconds, duration: 90)
    }
}

@MainActor
private final class ContinueBox {
    var context = ContinuePlaybackContext(owner: .guest, revision: UUID(), sceneActive: true)
    var record: WatchRecord?
    var factories = 0
    var progressOwners: [LibraryOwner] = []
    init(record: WatchRecord?) { self.record = record }
}

private actor ContinueServiceProbe: CatalogService {
    private(set) var detailCalls = 0
    private(set) var videoCalls = 0
    private var gates: [String: CheckedContinuation<SeriesDetail, any Error>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func detail(id: String) async throws -> SeriesDetail {
        detailCalls += 1
        let ready = waiters.filter { $0.0 <= detailCalls }; waiters.removeAll { $0.0 <= detailCalls }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { gates[id] = $0 }
    }
    func waitForCalls(_ count: Int) async {
        if detailCalls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release(_ id: String, detail: SeriesDetail) { gates.removeValue(forKey: id)?.resume(returning: detail) }
    func fail(_ id: String) { gates.removeValue(forKey: id)?.resume(throwing: CatalogError.network) }
    func home(page: Int) async throws -> SeriesPage { throw CatalogError.network }
    func search(query: String, page: Int) async throws -> SeriesPage { throw CatalogError.network }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        videoCalls += 1; throw CatalogError.network
    }
}
