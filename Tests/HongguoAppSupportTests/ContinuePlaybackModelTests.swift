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

    @Test func followingAPreviewWithoutARecordOnlyCreatesTheFormalRouteAfterLatestDetail() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
        launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
        let operation = try #require(launcher.operation)
        await service.waitForCalls(1)
        #expect(launcher.route == nil && launcher.pendingChoice == nil && box.factories == 0)
        await service.release("100", detail: detail()); await operation.value
        #expect(launcher.route?.continuation.episode.id == "900" && launcher.route?.continuation.seconds == 20)
        #expect(box.record == nil && box.factories == 1 && box.progressOwners.isEmpty)
        #expect(await service.videoCalls == 0)
    }

    @Test func aDifferentFormalPositionRequiresAnExplicitChoiceUsingTheLatestRecord() async throws {
        for selectSaved in [false, true] {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record(seconds: 10))
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); box.record = record(id: "902", number: 3, seconds: 50)
            await service.release("100", detail: detail()); await operation.value
            let choice = try #require(launcher.pendingChoice)
            #expect(launcher.route == nil && box.factories == 0 && launcher.preparingSeriesID == nil)
            #expect(choice.saved.episode.id == "902" && choice.saved.seconds == 50)
            #expect(choice.preview.episode.id == "900" && choice.preview.seconds == 20)
            launcher.choose(selectSaved ? .saved : .preview, choiceID: choice.id)
            #expect(launcher.pendingChoice == nil && box.factories == 1)
            #expect(launcher.route?.continuation.seconds == (selectSaved ? 50 : 20))
            #expect(launcher.route?.continuation.episode.id == (selectSaved ? "902" : "900"))
        }
    }

    @Test func equalContinuationsNeedNoChoiceAndACompletedPreviewAdvances() async throws {
        for completed in [false, true] {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel()
            let box = ContinueBox(record: completed ? nil : record(seconds: 20))
            launch(launcher, service: service, box: box, requiresRecord: false,
                   selection: .preview(preview(position: completed ? 90 : 20)))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.release("100", detail: detail()); await operation.value
            #expect(launcher.pendingChoice == nil)
            #expect(launcher.route?.continuation.episode.id == (completed ? "902" : "900"))
            #expect(launcher.route?.continuation.seconds == (completed ? 0 : 20))
        }
    }

    @Test func aChangedOrDeletedRecordWhileChoosingCannotApplyAnOldDecision() async throws {
        for removed in [false, true] {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.release("100", detail: detail()); await operation.value
            let choice = try #require(launcher.pendingChoice)
            box.record = removed ? nil : record(seconds: 55)
            launcher.choose(.saved, choiceID: choice.id)
            #expect(launcher.route == nil && launcher.pendingChoice == nil && box.factories == 0)
            #expect(launcher.errorMessage != nil)
        }
    }

    @Test func choiceAcceptanceRechecksOwnerSourceSceneParentAndCancellationEvenBeforeViewUpdates() async throws {
        for change in 0..<5 {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.release("100", detail: detail()); await operation.value
            let choice = try #require(launcher.pendingChoice)
            switch change {
            case 0: box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
            case 1: box.context = .init(owner: .guest, revision: UUID(), sceneActive: true)
            case 2: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: false)
            case 3: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: true, parentActive: false)
            default: launcher.cancelPending()
            }
            launcher.choose(.preview, choiceID: choice.id)
            #expect(launcher.route == nil && launcher.pendingChoice == nil && box.factories == 0)
        }
    }

    @Test func oldChoicesCannotSelectANewerRequestAndTheChosenProgressHandlerKeepsItsOriginalScope() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
        launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
        let first = try #require(launcher.operation)
        await service.waitForCalls(1); await service.release("100", detail: detail()); await first.value
        let oldChoice = try #require(launcher.pendingChoice)
        launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview(position: 40)))
        let second = try #require(launcher.operation)
        await service.waitForCalls(2); await service.release("100", detail: detail()); await second.value
        let newChoice = try #require(launcher.pendingChoice)
        launcher.choose(.preview, choiceID: oldChoice.id)
        #expect(launcher.route == nil && launcher.pendingChoice?.id == newChoice.id)
        launcher.choose(.preview, choiceID: newChoice.id)
        let route = try #require(launcher.route)
        #expect(route.continuation.seconds == 40)
        box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
        launcher.updateContext(box.context)
        route.onProgress(route.continuation.episode, 45, 90)
        #expect(box.progressOwners == [.guest] && launcher.route == nil)
    }

    @Test func anUnavailableOrForeignPreviewCannotCreateAChoiceOrAFormalPlayer() async throws {
        for snapshot in [preview(episodeID: "999"), preview(episodeID: "901"),
                         PreviewPlaybackSnapshot(seriesID: "200", episodeID: "900", position: 20, duration: 90)] {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(snapshot))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.release("100", detail: detail()); await operation.value
            #expect(launcher.route == nil && launcher.pendingChoice == nil && box.factories == 0)
            #expect(launcher.errorMessage != nil)
        }
    }

    @Test func sameEpisodePositionsWithinTwoSecondsLaunchThePreviewPositionWithoutAnIdenticalChoice() async throws {
        for (saved, position, needsChoice) in [(20.1, 20.2, false), (20.0, 22.0, false),
                                               (22.0, 20.0, false), (20.0, 22.000_001, true)] {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record(seconds: saved))
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview(position: position)))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.release("100", detail: detail()); await operation.value
            if needsChoice {
                #expect(launcher.pendingChoice != nil && launcher.route == nil && box.factories == 0)
            } else {
                #expect(launcher.pendingChoice == nil && launcher.route?.continuation.seconds == position)
                #expect(launcher.route?.continuation.episode.id == "900" && box.factories == 1)
            }
        }
    }

    @Test func tinyResolvedDifferencesDoNotHideCompletionAdvancementOrFinalReplayIntent() async throws {
        let cases: [(WatchRecord, PreviewPlaybackSnapshot)] = [
            (record(seconds: 88.1), preview(position: 88.3)),
            (record(seconds: 90), preview(episodeID: "902", position: 0)),
            (record(id: "902", number: 3, seconds: 90), preview(episodeID: "902", position: 1)),
            (record(id: "902", number: 3, seconds: 1), preview(episodeID: "902", position: 90))
        ]
        for (saved, snapshot) in cases {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: saved)
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(snapshot))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.release("100", detail: detail()); await operation.value
            #expect(launcher.pendingChoice != nil && launcher.route == nil && box.factories == 0)
        }
    }

    @Test func nearPositionComparisonUsesTheLatestRecordAfterDetailRatherThanTheButtonTime() async throws {
        for latestIsNear in [false, true] {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel()
            let box = ContinueBox(record: record(seconds: latestIsNear ? 50 : 20))
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview(position: 21)))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); box.record = record(seconds: latestIsNear ? 20 : 50)
            await service.release("100", detail: detail()); await operation.value
            if latestIsNear {
                #expect(launcher.pendingChoice == nil && launcher.route?.continuation.seconds == 21)
            } else {
                #expect(launcher.route == nil && launcher.pendingChoice?.saved.seconds == 50)
            }
        }
    }

    @Test func nearPositionFastPathStillRejectsCancelledOrChangedContextsBeforePresenting() async throws {
        for change in 0..<5 {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record(seconds: 20))
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview(position: 20.1)))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1)
            switch change {
            case 0: box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
            case 1: box.context = .init(owner: .guest, revision: UUID(), sceneActive: true)
            case 2: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: false)
            case 3: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: true, parentActive: false)
            default: launcher.cancelPending()
            }
            await service.release("100", detail: detail()); await operation.value
            #expect(launcher.route == nil && launcher.pendingChoice == nil && box.factories == 0)
        }
    }

    @Test func explicitRetryPreservesTheOriginalSnapshotReadsTheLatestRecordAndCoalescesDoubleTaps() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
        var snapshot = preview(position: 20)
        launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(snapshot))
        let first = try #require(launcher.operation)
        await service.waitForCalls(1); await service.fail("100"); await first.value
        #expect(launcher.canRetry && launcher.operation == nil && launcher.preparingSeriesID == nil)
        #expect(launcher.pendingChoice == nil && launcher.route == nil && box.factories == 0)
        #expect(await service.detailCalls == 1)
        snapshot = preview(position: 80)
        launcher.retry(); launcher.retry()
        let retry = try #require(launcher.operation)
        #expect(!launcher.canRetry && launcher.errorMessage == nil && launcher.preparingSeriesID == "100")
        await service.waitForCalls(2); box.record = record(seconds: 55)
        await service.release("100", detail: detail()); await retry.value
        let choice = try #require(launcher.pendingChoice)
        #expect(choice.saved.seconds == 55 && choice.preview.seconds == 20 && snapshot.position == 80)
        #expect(await service.detailCalls == 2)
        launcher.choose(.preview, choiceID: choice.id)
        #expect(launcher.route?.continuation.seconds == 20 && !launcher.canRetry)
        #expect(box.progressOwners.isEmpty && box.factories == 1)
    }

    @Test func aChangedChoiceCanRetryWithFreshDetailAndRecordWithoutReusingItsOldDecision() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
        launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview(position: 20)))
        let first = try #require(launcher.operation)
        await service.waitForCalls(1); await service.release("100", detail: detail()); await first.value
        let oldChoice = try #require(launcher.pendingChoice)
        box.record = record(seconds: 55)
        launcher.choose(.saved, choiceID: oldChoice.id)
        #expect(launcher.canRetry && launcher.pendingChoice == nil && launcher.route == nil && box.factories == 0)
        launcher.retry()
        let retry = try #require(launcher.operation)
        launcher.choose(.preview, choiceID: oldChoice.id)
        #expect(launcher.route == nil && launcher.preparingSeriesID == "100")
        await service.waitForCalls(2); box.record = record(seconds: 70)
        let freshDetail = SeriesDetail(series: .init(id: "100", title: "Fresh fixture"), episodes: [
            .init(id: "900", number: 1, title: "Updated episode"), .init(id: "903", number: 4, title: "New episode")])
        await service.release("100", detail: freshDetail); await retry.value
        let updated = try #require(launcher.pendingChoice)
        #expect(updated.id != oldChoice.id && updated.saved.seconds == 70 && updated.preview.seconds == 20)
        #expect(updated.preview.episode.title == "Updated episode" && !launcher.canRetry)
        launcher.choose(.saved, choiceID: oldChoice.id)
        #expect(launcher.route == nil && launcher.pendingChoice?.id == updated.id)
        launcher.choose(.preview, choiceID: updated.id)
        let route = try #require(launcher.route)
        #expect(route.detail.series.title == "Fresh fixture" && route.continuation.seconds == 20)
        box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
        launcher.updateContext(box.context)
        route.onProgress(route.continuation.episode, 25, 90)
        #expect(box.progressOwners == [.guest] && launcher.route == nil)
    }

    @Test func retryIsOffForDenialMalformedUnsupportedUnknownAndCancellationButOnForKnownTransientFailures() async throws {
        let failures: [(any Error, Bool)] = [
            (CatalogError.network, true), (CatalogError.httpStatus(500), true), (CatalogError.httpStatus(503), true),
            (URLError(.timedOut), true), (URLError(.notConnectedToInternet), true),
            (CatalogError.unauthorized, false), (CatalogError.httpStatus(401), false), (CatalogError.httpStatus(403), false),
            (CatalogError.invalidConfiguration, false), (CatalogError.malformedResponse, false),
            (CatalogError.incompatibleBridge, false), (CatalogError.unavailablePlayback, false),
            (CatalogError.unsafePlaybackURL, false), (NSError(domain: "UnknownFixtureError", code: 1), false),
            (CancellationError(), false), (URLError(.cancelled), false)
        ]
        for (error, retryable) in failures {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.fail("100", error: error); await operation.value
            #expect(launcher.canRetry == retryable)
            #expect(launcher.operation == nil && launcher.preparingSeriesID == nil && launcher.pendingChoice == nil && launcher.route == nil)
            #expect(await service.detailCalls == 1)
            #expect(box.factories == 0)
        }
    }

    @Test func cancelDismissNewStartAndContextChangesDiscardFailedRetryIntents() async throws {
        for change in 0..<8 {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.fail("100"); await operation.value
            #expect(launcher.canRetry)
            switch change {
            case 0: launcher.cancelPending()
            case 1: launcher.dismiss()
            case 2: box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
            case 3: box.context = .init(owner: .guest, revision: UUID(), sceneActive: true)
            case 4: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: false)
            case 5: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: true, parentActive: false)
            case 6: launcher.fail(CatalogError.invalidConfiguration, seriesID: "200")
            default:
                box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: false)
                launch(launcher, seriesID: "200", service: service, box: box, requiresRecord: false)
            }
            if (2...5).contains(change) { launcher.updateContext(box.context) }
            launcher.retry()
            #expect(!launcher.canRetry && launcher.operation == nil && launcher.route == nil)
            #expect(await service.detailCalls == 1)
        }
    }

    @Test func retryRechecksTheLiveContextEvenIfTheViewHasNotReportedItsChangeYet() async throws {
        for change in 0..<4 {
            let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
            launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview()))
            let operation = try #require(launcher.operation)
            await service.waitForCalls(1); await service.fail("100"); await operation.value
            switch change {
            case 0: box.context = .init(owner: .account(id: "42"), revision: box.context.revision, sceneActive: true)
            case 1: box.context = .init(owner: .guest, revision: UUID(), sceneActive: true)
            case 2: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: false)
            default: box.context = .init(owner: .guest, revision: box.context.revision, sceneActive: true, parentActive: false)
            }
            launcher.retry()
            #expect(!launcher.canRetry && launcher.errorMessage == nil && launcher.operation == nil)
            #expect(await service.detailCalls == 1)
        }
    }

    @Test func repeatedTransientFailuresWaitForEachExplicitRetryAndEventuallyUseTheOriginalSnapshot() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
        launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview(position: 25)))
        let first = try #require(launcher.operation)
        await service.waitForCalls(1); await service.fail("100"); await first.value
        launcher.retry()
        let second = try #require(launcher.operation)
        await service.waitForCalls(2); await service.fail("100", error: CatalogError.httpStatus(503)); await second.value
        #expect(launcher.canRetry && launcher.operation == nil && launcher.route == nil)
        #expect(await service.detailCalls == 2)
        launcher.retry()
        let third = try #require(launcher.operation)
        await service.waitForCalls(3); await service.release("100", detail: detail()); await third.value
        #expect(launcher.route?.continuation.seconds == 25 && !launcher.canRetry && launcher.errorMessage == nil)
        #expect(await service.detailCalls == 3)
    }

    @Test func anOldCancelledReplyCannotClearANewerRetryOrMakeItsErrorRetryable() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
        launch(launcher, service: service, box: box, requiresRecord: false)
        let old = try #require(launcher.operation)
        await service.waitForCalls(1)
        launch(launcher, seriesID: "200", service: service, box: box, requiresRecord: false)
        let replacement = try #require(launcher.operation)
        await service.waitForCalls(2); await service.fail("200"); await replacement.value
        #expect(launcher.canRetry && launcher.failedSeriesID == "200")
        launcher.retry()
        let retry = try #require(launcher.operation)
        await service.waitForCalls(3)
        await service.release("100", detail: detail()); await old.value
        #expect(!launcher.canRetry && launcher.preparingSeriesID == "200" && launcher.operation != nil && launcher.errorMessage == nil)
        await service.release("200", detail: detail(seriesID: "200")); await retry.value
        #expect(launcher.route?.detail.series.id == "200" && !launcher.canRetry)
    }

    @Test func hangingDetailExposesManualRetryAndRejectsItsLateCompletion() async throws {
        let latestDetail = detail()
        let service = ContinueServiceProbe(immediateDetails: [2: latestDetail])
        let launcher = ContinuePlaybackModel(preparationTimeout: .milliseconds(150))
        let box = ContinueBox(record: record(seconds: 10))
        defer { Task { await service.release("100", detail: latestDetail) } }

        launch(launcher, service: service, box: box)
        let expired = try #require(launcher.operation)
        await service.waitForCalls(1)
        for _ in 0..<200 where !launcher.canRetry { try await Task.sleep(for: .milliseconds(10)) }
        try #require(launcher.canRetry)
        #expect(expired.isCancelled && launcher.operation == nil && launcher.preparingSeriesID == nil)
        #expect(launcher.errorMessage == "劇集準備逾時，請重試。")
        #expect(launcher.route == nil && box.factories == 0)
        #expect(await service.detailCalls == 1)

        box.record = record(seconds: 45)
        launcher.retry()
        let retry = try #require(launcher.operation)
        await retry.value
        let route = try #require(launcher.route)
        #expect(route.continuation.seconds == 45)
        #expect(await service.detailCalls == 2)

        // The first request returned after the replacement despite being cancelled.
        await service.release("100", detail: detail(seriesID: "200"))
        await expired.value
        #expect(launcher.route?.id == route.id && box.factories == 1)
        #expect(launcher.operation == nil && launcher.errorMessage == nil && !launcher.canRetry)
    }

    @Test func aCancelledStaleStartCannotCancelAFreshPendingLaunch() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: nil)
        launch(launcher, service: service, box: box, requiresRecord: false, selection: .preview(preview(position: 25)))
        let fresh = try #require(launcher.operation)
        await service.waitForCalls(1)
        let stale = Task { @MainActor in
            #expect(Task.isCancelled)
            launch(launcher, seriesID: "200", service: service, box: box, requiresRecord: false)
        }
        stale.cancel()
        await stale.value
        #expect(launcher.preparingSeriesID == "100" && launcher.operation != nil && !launcher.canRetry)
        #expect(await service.detailCalls == 1)
        await service.release("100", detail: detail()); await fresh.value
        #expect(launcher.route?.detail.series.id == "100" && launcher.route?.continuation.seconds == 25)
        #expect(box.factories == 1)
    }

    @Test func retryStillRequiresTheHistoryRecordWhenTheOriginalEntryPointRequiredIt() async throws {
        let service = ContinueServiceProbe(), launcher = ContinuePlaybackModel(), box = ContinueBox(record: record())
        launch(launcher, service: service, box: box, selection: .preview(preview()))
        let first = try #require(launcher.operation)
        await service.waitForCalls(1); await service.fail("100"); await first.value
        launcher.retry()
        let retry = try #require(launcher.operation)
        await service.waitForCalls(2); box.record = nil
        await service.release("100", detail: detail()); await retry.value
        #expect(launcher.route == nil && launcher.pendingChoice == nil && !launcher.canRetry && launcher.errorMessage != nil)
        #expect(box.factories == 0)
    }

    @Test func aSuspendedTransportAndAnIdleRetryIntentDoNotRetainTheLauncher() async throws {
        for failFirst in [false, true] {
            let service = ContinueServiceProbe(), box = ContinueBox(record: nil)
            var launcher: ContinuePlaybackModel? = ContinuePlaybackModel()
            let weakLauncher = WeakContinueLauncher(launcher)
            launch(try #require(launcher), service: service, box: box, requiresRecord: false, selection: .preview(preview()))
            let operation = try #require(launcher?.operation)
            await service.waitForCalls(1)
            if failFirst {
                await service.fail("100"); await operation.value
                #expect(launcher?.canRetry == true)
            }
            launcher = nil
            #expect(weakLauncher.value == nil)
            if !failFirst { await service.release("100", detail: detail()); await operation.value }
            #expect(box.factories == 0)
        }
    }

    private func preview(episodeID: String = "900", position: Double = 20) -> PreviewPlaybackSnapshot {
        .init(seriesID: "100", episodeID: episodeID, position: position, duration: 90)
    }

    private func launch(_ launcher: ContinuePlaybackModel, seriesID: String = "100", service: ContinueServiceProbe,
                        box: ContinueBox, requiresRecord: Bool = true, selection: ContinuePlaybackSelection = .preferred) {
        launcher.start(series: .init(id: seriesID, title: "Fixture"), requiresRecord: requiresRecord, selection: selection, context: box.context,
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
private final class WeakContinueLauncher {
    weak var value: ContinuePlaybackModel?
    init(_ value: ContinuePlaybackModel?) { self.value = value }
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
    private let immediateDetails: [Int: SeriesDetail]
    init(immediateDetails: [Int: SeriesDetail] = [:]) { self.immediateDetails = immediateDetails }

    func detail(id: String) async throws -> SeriesDetail {
        detailCalls += 1
        let ready = waiters.filter { $0.0 <= detailCalls }; waiters.removeAll { $0.0 <= detailCalls }
        ready.forEach { $0.1.resume() }
        if let detail = immediateDetails[detailCalls] { return detail }
        return try await withCheckedThrowingContinuation { gates[id] = $0 }
    }
    func waitForCalls(_ count: Int) async {
        if detailCalls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release(_ id: String, detail: SeriesDetail) { gates.removeValue(forKey: id)?.resume(returning: detail) }
    func fail(_ id: String, error: any Error = CatalogError.network) { gates.removeValue(forKey: id)?.resume(throwing: error) }
    func home(page: Int) async throws -> SeriesPage { throw CatalogError.network }
    func search(query: String, page: Int) async throws -> SeriesPage { throw CatalogError.network }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        videoCalls += 1; throw CatalogError.network
    }
}
