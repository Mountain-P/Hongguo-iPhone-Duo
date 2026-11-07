import Foundation
import Testing
import HongguoCore
@testable import HongguoAppSupport

@MainActor
struct RecommendationPreviewModelTests {
    private let scope = LibraryScope(owner: .guest, sourceID: "test-source")

    @Test func sourceLabelsRemainSeparateFromRankingAndArePrunedWithExcludedCards() async throws {
        let source = PreviewCatalogueGate()
        await source.setOrigins([
            "10": .init(source: .category, category: .realDrama),
            "20": .init(source: .ranking, category: .realDrama),
            "30": .init(source: .newRelease, category: .realDrama),
            "99": .init(source: .ranking, category: .aiDrama)
        ])
        let model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        #expect(model.items.map(\.id) == ["10", "20", "30"])
        #expect(model.sourceLabelByID == ["20": "真人熱播榜", "30": "真人近 7 天上新"])
        #expect(model.reasonByID.isEmpty)
        model.excludeNotInterested(try hidden(["20"]))
        #expect(model.sourceLabelByID == ["30": "真人近 7 天上新"])
        #expect(model.current?.id == "10")
        model.invalidateSource()
        #expect(model.sourceLabelByID.isEmpty)
    }

    @Test func lateSourceLabelsCannotPopulateAReplacementSource() async throws {
        let oldSource = PreviewCatalogueGate(), replacement = PreviewCatalogueGate()
        await oldSource.setOrigins(["10": .init(source: .ranking, category: .realDrama)], hold: true)
        await replacement.setOrigins(["20": .init(source: .newRelease, category: .aiDrama)])
        let model = configured(oldSource)
        defer { cleanUp(model, oldSource); Task { await replacement.finishAll() } }
        model.loadInitial()
        try await wait { await oldSource.hasHome(1) }
        let stale = try #require(model.catalogueTask)
        await oldSource.releaseHome(1, ids: ["10"])
        try await wait { await oldSource.hasProvenance() }
        let other = LibraryScope(owner: .guest, sourceID: "replacement")
        model.configure(revision: UUID(), filterRevision: UUID(), preferences: .init(category: .aiDrama),
                        profile: .init(scope: other, favorites: [], history: []), scope: other,
                        catalogue: replacement, playback: replacement)
        try await loadFirst(model, replacement, ids: ["20"])
        await oldSource.releaseProvenance()
        await stale.value
        #expect(model.items.map(\.id) == ["20"])
        #expect(model.sourceLabelByID == ["20": "AI近 7 天上新"])
        #expect(model.rankingScope == other)
    }

    @Test func hidingCurrentRejectsItsLateDetailAndPreservesOtherCachedCards() async throws {
        let source = PreviewCatalogueGate()
        let model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("10", model, source)
        try await prepare("20", model, source)
        let first = try #require(model.media["10"]?.id)
        let second = try #require(model.media["20"]?.id)
        activate("30", model)
        try await wait { await source.hasDetail("30") }
        let stale = try #require(model.detailTask)
        let change = model.excludeNotInterested(try hidden(["30"]))
        #expect(change.currentID == "20")
        #expect(model.lease == nil && model.loadingID == nil)
        await source.releaseDetail("30")
        await stale.value
        #expect(model.media["30"] == nil)
        #expect(model.media["10"]?.id == first && model.media["20"]?.id == second)
        #expect(model.queue.page == 1 && !model.queue.hasMore)
        #expect(await source.homeRequests == [1])
    }

    @Test func aPageAlreadyInFlightUsesLatestExclusionsWithoutLosingItsCursor() async throws {
        let source = PreviewCatalogueGate()
        let model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20"], more: true)
        model.loadMoreIfNeeded(force: true)
        try await wait { await source.hasHome(2) }
        let pageTask = try #require(model.catalogueTask)
        model.excludeNotInterested(try hidden(["10", "30"]))
        #expect(model.catalogueTask != nil && model.queue.page == 1)
        await source.releaseHome(2, ids: ["10", "30", "40"])
        await pageTask.value
        #expect(model.items.map(\.id) == ["20", "40"])
        #expect(model.current?.id == "20" && model.queue.page == 2)
        #expect(await source.homeRequests == [1, 2])
    }

    @Test func anEmptyFeedContinuesAtPageTwoAndOnlyExplicitReloadRestartsIt() async throws {
        let source = PreviewCatalogueGate()
        let model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10"], more: true)
        model.excludeNotInterested(try hidden(["10"]))
        #expect(model.items.isEmpty && model.queue.page == 1 && model.queue.hasMore)
        model.loadInitial()
        try await wait { await source.hasHome(2) }
        let continuation = try #require(model.catalogueTask)
        await source.releaseHome(2, ids: ["10", "20"])
        await continuation.value
        #expect(model.items.map(\.id) == ["20"] && model.queue.page == 2)
        model.excludeNotInterested(try hidden(["10", "20"]))
        model.loadInitial()
        #expect(model.items.isEmpty && model.catalogueTask == nil && !model.queue.hasMore)
        #expect(await source.homeRequests == [1, 2])
        model.reloadEmptyCatalogue()
        try await wait { await source.hasHome(1) }
        let reload = try #require(model.catalogueTask)
        await source.releaseHome(1, ids: ["30"])
        await reload.value
        #expect(model.items.map(\.id) == ["30"] && model.queue.page == 1)
        #expect(await source.homeRequests == [1, 2, 1])
    }

    @Test func removingAnOffscreenCardKeepsTheCurrentLeaseAndMediaIdentity() async throws {
        let source = PreviewCatalogueGate()
        let model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("20", model, source)
        let lease = try #require(model.lease)
        let media = try #require(model.media["20"]?.id)
        var preferences = try hidden(["10"])
        preferences.skipsPreviewed = true
        try preferences.markPreviewed(seriesID: "20")
        let change = model.excludeNotInterested(preferences)
        #expect(!change.currentChanged)
        #expect(model.current?.id == "20" && model.lease == lease)
        #expect(model.media["20"]?.id == media)
        #expect(model.items.map(\.id) == ["20", "30"])
    }

    @Test func excludingACachedNeighborPrefetchesTheNextLegalCardAndRejectsLateOldWork() async throws {
        let source = PreviewCatalogueGate()
        let model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("20", model, source)
        try await prepare("10", model, source)
        let currentMedia = try #require(model.media["10"]?.id)
        let currentLease = try #require(model.lease)
        model.setPrefetchAllowed(true)
        model.didStartPreview(seriesID: "10")
        try await wait { await source.hasPlayback("20") }
        let oldPrefetch = try #require(model.prefetchTask)
        model.excludeNotInterested(try hidden(["20"]))
        #expect(model.lease == currentLease && model.media["10"]?.id == currentMedia)
        #expect(model.media["20"] == nil)
        try await wait { await source.hasDetail("30") }
        await source.releaseDetail("30")
        try await wait { await source.hasPlayback("30") }
        let newPrefetch = try #require(model.prefetchTask)
        await source.releasePlayback("20")
        await oldPrefetch.value
        #expect(model.prefetchTask != nil)
        #expect(model.media["20"] == nil && model.media["30"] != nil)
        await source.releasePlayback("30")
        await newPrefetch.value
        #expect(model.media["10"]?.id == currentMedia)
        #expect(await source.playbackRequests == ["20", "30"])
        #expect(await source.homeRequests == [1])
    }

    @Test func sourceAndOwnerReplacementStillRejectAnOldCatalogueResponse() async throws {
        let oldSource = PreviewCatalogueGate(), newSource = PreviewCatalogueGate()
        let model = configured(oldSource)
        defer { cleanUp(model, oldSource); Task { await newSource.finishAll() } }
        model.loadInitial()
        try await wait { await oldSource.hasHome(1) }
        let stale = try #require(model.catalogueTask)
        let account = LibraryScope(owner: .account(id: "test-account"), sourceID: "other-source")
        model.configure(revision: UUID(), filterRevision: UUID(), preferences: .init(category: .comicDrama),
                        profile: .init(scope: account, favorites: [], history: []), scope: account,
                        catalogue: newSource, playback: newSource)
        model.loadInitial()
        try await wait { await newSource.hasHome(1) }
        let current = try #require(model.catalogueTask)
        await oldSource.releaseHome(1, ids: ["10"])
        await stale.value
        #expect(model.items.isEmpty && model.rankingScope == account)
        await newSource.releaseHome(1, ids: ["20"])
        await current.value
        #expect(model.items.map(\.id) == ["20"])
    }

    @Test func pagingPromotesPendingNeighborMetadataAndPreservesAnInFlightCataloguePage() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"], more: true)
        try await prepare("10", model, source)
        try await wait { await source.hasHome(2) }
        let page = try #require(model.catalogueTask)
        model.setPrefetchAllowed(true); model.didStartPreview(seriesID: "10")
        try await wait { await source.hasDetail("20") }
        let adjacent = try #require(model.prefetchTask)
        model.beginPaging(toward: "20")
        model.update(selectedID: nil, isIdle: false, isActive: true, isSceneActive: true, isDetailPresented: false)
        #expect(model.lease == nil && model.catalogueTask != nil)
        activate("20", model)
        try await wait { model.metadataConsumerCount(seriesID: "20") == 2 }
        let foreground = try #require(model.detailTask)
        #expect(await source.detailRequests.filter { $0 == "20" }.count == 1)
        // Revoking speculative permission releases that owner, never the foreground owner.
        model.setPrefetchAllowed(false)
        #expect(model.metadataConsumerCount(seriesID: "20") == 1)
        #expect(source.detailCancellations.count(for: "20") == 0)
        await source.releaseDetail("20")
        await foreground.value; await adjacent.value
        await source.releaseHome(2, ids: ["40"])
        await page.value
        #expect(model.media["20"] != nil && model.detailErrors["20"] == nil)
        #expect(model.current?.id == "20" && model.queue.page == 2)
        #expect(await source.homeRequests == [1, 2])
        #expect(model.metadataFlightCount == 0)
    }

    @Test func releasingForegroundDuringPagingKeepsTheAdjacentMetadataOwnerAlive() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("10", model, source)
        model.setPrefetchAllowed(true); model.didStartPreview(seriesID: "10")
        try await wait { await source.hasDetail("20") }
        activate("20", model)
        try await wait { model.metadataConsumerCount(seriesID: "20") == 2 }
        let oldForeground = try #require(model.detailTask)
        model.beginPaging()
        #expect(model.metadataConsumerCount(seriesID: "20") == 1)
        #expect(source.detailCancellations.count(for: "20") == 0)
        await source.releaseDetail("20")
        await oldForeground.value
        try await wait { await source.hasPlayback("20") }
        #expect(model.media["20"] != nil && model.lease == nil)
        activate("20", model)
        #expect(model.loadingID == nil && model.detailTask == nil)
        #expect(await source.detailRequests.filter { $0 == "20" }.count == 1)
    }

    @Test func theLastSettledCardWinsAndOldSharedMetadataCannotPopulateItsUI() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("10", model, source)
        model.setPrefetchAllowed(true); model.didStartPreview(seriesID: "10")
        try await wait { await source.hasDetail("20") }
        let oldAdjacent = try #require(model.prefetchTask)
        activate("20", model)
        try await wait { model.metadataConsumerCount(seriesID: "20") == 2 }
        let oldForeground = try #require(model.detailTask)
        model.beginPaging(toward: "30")
        #expect(model.metadataFlightCount == 0)
        activate("30", model)
        try await wait { await source.hasDetail("30") }
        #expect(model.metadataFlightCount == 1)
        let final = try #require(model.detailTask)
        await source.releaseDetail("30")
        await final.value
        let identity = try #require(model.media["30"]?.id)
        await source.releaseDetail("20")
        await oldForeground.value; await oldAdjacent.value
        #expect(model.lease?.seriesID == "30" && model.media["30"]?.id == identity)
        #expect(model.media["20"] == nil && model.detailErrors["20"] == nil)
        #expect(source.detailCancellations.count(for: "20") == 1)
        #expect(await source.detailRequests == ["10", "20", "30"])
    }

    @Test func matchingHeaderPrefetchSurvivesPromotionUntilForegroundPlaybackActuallyStarts() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("10", model, source)
        model.setPrefetchAllowed(true); model.didStartPreview(seriesID: "10")
        try await wait { await source.hasDetail("20") }
        await source.releaseDetail("20")
        try await wait { await source.hasPlayback("20") }
        let header = try #require(model.prefetchTask)
        let identity = try #require(model.media["20"]?.id)
        model.beginPaging(toward: "20")
        activate("20", model)
        #expect(model.prefetchTask != nil && model.media["20"]?.id == identity)
        #expect(await source.playbackRequests == ["20"])
        model.didStartPreview(seriesID: "20")
        try await wait { await source.hasDetail("30") }
        await source.releasePlayback("20")
        await header.value
        #expect(model.prefetchTask != nil)
        #expect(await source.detailRequests == ["10", "20", "30"])
    }

    @Test func fullSuspensionCancelsBothSharedOwnersAndRejectsTheLateMetadata() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("10", model, source)
        model.setPrefetchAllowed(true); model.didStartPreview(seriesID: "10")
        try await wait { await source.hasDetail("20") }
        let oldAdjacent = try #require(model.prefetchTask)
        activate("20", model)
        try await wait { model.metadataConsumerCount(seriesID: "20") == 2 }
        let oldForeground = try #require(model.detailTask)
        model.suspend()
        #expect(model.lease == nil && model.metadataFlightCount == 0)
        await source.releaseDetail("20")
        await oldForeground.value; await oldAdjacent.value
        #expect(model.media["20"] == nil && model.loadingID == nil)
        #expect(source.detailCancellations.count(for: "20") == 1)
    }

    @Test func disallowedSpeculationDoesNotStartAdjacentMetadataOrMedia() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20"])
        try await prepare("10", model, source)
        model.setPrefetchAllowed(false); model.didStartPreview(seriesID: "10")
        #expect(model.prefetchTask == nil && model.metadataFlightCount == 0)
        #expect(await source.detailRequests == ["10"])
        #expect(await source.playbackRequests.isEmpty)
    }

    @Test func aCachedCardWaitsForThisActivationsPlaybackCallbackBeforePrefetchingAnotherCard() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("20", model, source)
        model.didStartPreview(seriesID: "20")
        try await prepare("10", model, source)
        model.didStartPreview(seriesID: "10"); model.setPrefetchAllowed(true)
        try await wait { await source.hasPlayback("20") }
        let header = try #require(model.prefetchTask)
        await source.releasePlayback("20")
        await header.value
        model.beginPaging(toward: "20"); activate("20", model)
        #expect(model.media["20"] != nil && model.prefetchTask == nil)
        model.setPrefetchAllowed(false); model.setPrefetchAllowed(true)
        #expect(model.prefetchTask == nil)
        #expect(await source.detailRequests == ["20", "10"])
        model.didStartPreview(seriesID: "20")
        #expect(model.prefetchTask != nil)
        try await wait { await source.hasDetail("30") }
    }

    @Test func anImmediatePolicyChangeCannotCancelThePromotedForegroundBeforeItsTaskStarts() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        try await loadFirst(model, source, ids: ["10", "20"])
        try await prepare("10", model, source)
        model.setPrefetchAllowed(true); model.didStartPreview(seriesID: "10")
        try await wait { await source.hasDetail("20") }
        let adjacent = try #require(model.prefetchTask)
        model.beginPaging(toward: "20")
        activate("20", model)
        // Do not yield between promotion and policy revocation.
        model.setPrefetchAllowed(false)
        #expect(model.metadataConsumerCount(seriesID: "20") == 1)
        #expect(source.detailCancellations.count(for: "20") == 0)
        let foreground = try #require(model.detailTask)
        await source.releaseDetail("20")
        await foreground.value; await adjacent.value
        #expect(model.media["20"] != nil)
        #expect(await source.detailRequests == ["10", "20"])
    }

    @Test func restoredNonFirstCardSurvivesBothSuccessfulAndFailedRealPageOneWithoutDuplicateLoads() async throws {
        for shouldFail in [false, true] {
            let fixture = try PreviewSessionFixture(); defer { fixture.clear() }
            try await seedSession(fixture.store, scope: scope, ids: ["10", "20", "30"], current: "20", seconds: 35)
            let source = PreviewCatalogueGate(), model = configured(source, sessionStore: fixture.store)
            defer { model.invalidateSource(); cleanUp(model, source) }
            model.loadInitial(); model.loadInitial()
            let restore = try #require(model.sessionRestoreTask)
            await restore.value
            #expect(model.current?.id == "20" && model.queue.page == 0 && model.media.isEmpty && model.lease == nil)
            try await wait { await source.hasHome(1) }
            let page = try #require(model.catalogueTask)
            if shouldFail { await source.failHome(1) }
            else { await source.releaseHome(1, ids: ["20", "30", "40"]) }
            await page.value
            #expect(model.current?.id == "20")
            #expect(model.queue.page == (shouldFail ? 0 : 1))
            #expect(model.items.map(\.id) == (shouldFail ? ["10", "20", "30"] : ["10", "20", "30", "40"]))
            #expect((model.pageError != nil) == shouldFail)
            #expect(await source.homeRequests == [1])
            #expect(await source.playbackRequests.isEmpty)
        }
    }

    @Test func savingAndReopeningPreviewPreservesPositionOnlyAfterFreshFirstEpisodeVerification() async throws {
        let fixture = try PreviewSessionFixture(); defer { fixture.clear() }
        let formal = Data("formal library untouched".utf8)
        fixture.defaults.set(formal, forKey: "library.v1.synthetic")
        let source = PreviewCatalogueGate(), model = configured(source, sessionStore: fixture.store)
        defer { model.invalidateSource(); cleanUp(model, source) }
        await model.sessionRestoreTask?.value
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("20", model, source)
        model.rememberPreviewPosition(.init(seriesID: "20", episodeID: "201", position: 35, duration: 90), contextID: model.sessionContextID)
        await model.saveSession()
        model.invalidateSource()
        let reopenedSource = PreviewCatalogueGate(), reopened = configured(reopenedSource, sessionStore: fixture.store)
        defer { reopened.invalidateSource(); cleanUp(reopened, reopenedSource) }
        await reopened.sessionRestoreTask?.value
        #expect(reopened.current?.id == "20" && reopened.media.isEmpty)
        try await loadFirst(reopened, reopenedSource, ids: ["10", "20", "30"])
        try await prepare("20", reopened, reopenedSource)
        let media = try #require(reopened.media["20"])
        #expect(media.episode.id == "201" && media.resumeSeconds == 35)
        reopened.beginPaging(); activate("20", reopened)
        #expect(reopened.media["20"]?.id == media.id && reopened.media["20"]?.resumeSeconds == 35)
        #expect(await reopenedSource.detailRequests == ["20"])
        #expect(fixture.defaults.data(forKey: "library.v1.synthetic") == formal)
    }

    @Test func aChangedFirstEpisodeCannotInheritTheSavedEpisodePosition() async throws {
        let fixture = try PreviewSessionFixture(); defer { fixture.clear() }
        try await seedSession(fixture.store, scope: scope, ids: ["20"], current: "20", seconds: 35)
        let source = PreviewCatalogueGate(), model = configured(source, sessionStore: fixture.store)
        defer { model.invalidateSource(); cleanUp(model, source) }
        await model.sessionRestoreTask?.value
        try await loadFirst(model, source, ids: ["20"])
        activate("20", model)
        try await wait { await source.hasDetail("20") }
        let task = try #require(model.detailTask)
        await source.releaseDetail("20", episodeID: "299")
        await task.value
        #expect(model.media["20"]?.episode.id == "299" && model.media["20"]?.resumeSeconds == 0)
        model.rememberPreviewPosition(.init(seriesID: "20", episodeID: "201", position: 40, duration: 90), contextID: model.sessionContextID)
        await model.saveSession()
        #expect(try await fixture.store.load(scope: scope, category: .realDrama, preferences: .init())?.snapshot == nil)
    }

    @Test func aLateExclusionWhileRestoringNeverRestoresItsOldCurrentCardOrPosition() async throws {
        let clock = PreviewSessionClockGate(), fixture = try PreviewSessionFixture(clock: clock)
        defer { clock.release(); fixture.clear() }
        try await seedSession(fixture.store, scope: scope, ids: ["10", "20", "30"], current: "20", seconds: 35)
        clock.arm()
        let source = PreviewCatalogueGate(), model = configured(source, sessionStore: fixture.store)
        defer { model.invalidateSource(); cleanUp(model, source) }
        let restore = try #require(model.sessionRestoreTask)
        try await wait { clock.entered }
        model.excludeNotInterested(try hidden(["20"]))
        clock.release(); await restore.value
        #expect(model.current?.id == "30" && model.items.map(\.id) == ["10", "30"])
        try await loadFirst(model, source, ids: ["10", "20", "30"])
        try await prepare("30", model, source)
        #expect(model.media["30"]?.resumeSeconds == 0 && model.media["20"] == nil)
    }

    @Test func lateSourceRestoreAndOldPositionCallbacksCannotOverwriteANewAccountsSession() async throws {
        let clock = PreviewSessionClockGate(), fixture = try PreviewSessionFixture(clock: clock)
        defer { clock.release(); fixture.clear() }
        let account = LibraryScope(owner: .account(id: "42"), sourceID: "replacement-source")
        try await seedSession(fixture.store, scope: scope, ids: ["10", "20"], current: "20", seconds: 30)
        try await seedSession(fixture.store, scope: account, ids: ["20", "30"], current: "20", seconds: 70)
        clock.arm()
        let oldSource = PreviewCatalogueGate(), source = PreviewCatalogueGate()
        let model = configured(oldSource, sessionStore: fixture.store)
        defer { model.invalidateSource(); cleanUp(model, oldSource); Task { await source.finishAll() } }
        model.loadInitial()
        let old = try #require(model.sessionRestoreTask), oldContext = model.sessionContextID
        try await wait { clock.entered }
        model.configure(revision: UUID(), filterRevision: UUID(), preferences: .init(),
                        profile: .init(scope: account, favorites: [], history: []), scope: account, catalogue: source, playback: source)
        model.loadInitial()
        let replacement = try #require(model.sessionRestoreTask)
        clock.release(); await old.value; await replacement.value
        #expect(model.items.map(\.id) == ["20", "30"] && model.current?.id == "20")
        #expect(model.rankingScope == account && model.sessionContextID != oldContext)
        #expect(await oldSource.homeRequests.isEmpty)
        try await wait { await source.hasHome(1) }
        let page = try #require(model.catalogueTask)
        await source.releaseHome(1, ids: ["20", "30"]); await page.value
        try await prepare("20", model, source)
        #expect(model.media["20"]?.resumeSeconds == 70)
        model.rememberPreviewPosition(.init(seriesID: "20", episodeID: "201", position: 5, duration: 90), contextID: oldContext)
        await model.saveSession()
        #expect(try await fixture.store.load(scope: account, category: .realDrama, preferences: .init())?.snapshot?.position == 70)
        #expect(try await fixture.store.load(scope: scope, category: .realDrama, preferences: .init())?.snapshot?.position == 30)
    }

    @Test func leavingDuringLocalRestoreDoesNotStartBackgroundCatalogueWorkAndReentryStillLoadsPageOne() async throws {
        let clock = PreviewSessionClockGate(), fixture = try PreviewSessionFixture(clock: clock)
        defer { clock.release(); fixture.clear() }
        try await seedSession(fixture.store, scope: scope, ids: ["10", "20"], current: "20", seconds: 35)
        clock.arm()
        let source = PreviewCatalogueGate(), model = configured(source, sessionStore: fixture.store)
        defer { model.invalidateSource(); cleanUp(model, source) }
        model.loadInitial()
        let restore = try #require(model.sessionRestoreTask)
        try await wait { clock.entered }
        model.suspend(); clock.release(); await restore.value
        #expect(model.current?.id == "20" && model.lease == nil && model.catalogueTask == nil)
        #expect(await source.homeRequests.isEmpty)
        try await loadFirst(model, source, ids: ["10", "20"])
        #expect(model.current?.id == "20" && model.queue.page == 1)
    }

    @Test func aNewPageContinuesTopicDiversityWithoutMovingThePlayingCard() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        model.updateRankingProfile(topicProfile(), scope: scope)
        try await loadTopicPage(1, [topic("5", "甜寵"), topic("10", "懸疑"), topic("20", "懸疑")], model, source, more: true)
        try await prepare("10", model, source)
        let lease = try #require(model.lease), mediaID = try #require(model.media["10"]?.id)
        let originalPrefix = model.items
        try await loadTopicPage(2, [topic("30", "懸疑"), topic("40", "甜寵")], model, source)
        #expect(model.items.map(\.id) == ["5", "10", "20", "40", "30"])
        #expect(Array(model.items.prefix(3)) == originalPrefix)
        #expect(model.current?.id == "10" && model.lease == lease && model.media["10"]?.id == mediaID)
    }

    @Test func failedPageRetryDoesNotAdvanceOrChangeTheCommittedDiversityTail() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        model.updateRankingProfile(topicProfile(), scope: scope)
        try await loadTopicPage(1, [topic("10", "懸疑"), topic("20", "懸疑")], model, source, more: true)
        model.loadMoreIfNeeded(force: true)
        try await wait { await source.hasHome(2) }
        let failed = try #require(model.catalogueTask)
        await source.failHome(2); await failed.value
        #expect(model.items.map(\.id) == ["10", "20"] && model.queue.page == 1 && model.pageError != nil)
        try await loadTopicPage(2, [topic("30", "懸疑"), topic("40", "甜寵")], model, source)
        #expect(model.items.map(\.id) == ["10", "20", "40", "30"])
        #expect(await source.homeRequests == [1, 2, 2])
    }

    @Test func anInFlightPageReadsTheTailAfterExclusionRatherThanTheRequestStart() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        model.updateRankingProfile(topicProfile(), scope: scope)
        try await loadTopicPage(1, [topic("10", "懸疑"), topic("20", "懸疑")], model, source, more: true)
        model.loadMoreIfNeeded(force: true)
        try await wait { await source.hasHome(2) }
        let pending = try #require(model.catalogueTask)
        model.excludeNotInterested(try hidden(["20"]))
        await source.releaseHome(2, items: [topic("30", "懸疑"), topic("40", "甜寵")])
        await pending.value
        // Only one suspense card survives. The removed card cannot force romance first.
        #expect(model.items.map(\.id) == ["10", "30", "40"] && model.current?.id == "10")
    }

    @Test func replacementScopeRejectsALatePageAndStartsWithoutThePreviousTail() async throws {
        let source = PreviewCatalogueGate(), replacement = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source); Task { await replacement.finishAll() } }
        model.updateRankingProfile(topicProfile(), scope: scope)
        try await loadTopicPage(1, [topic("10", "懸疑"), topic("20", "懸疑")], model, source, more: true)
        model.loadMoreIfNeeded(force: true)
        try await wait { await source.hasHome(2) }
        let stale = try #require(model.catalogueTask)
        let nextScope = LibraryScope(owner: .account(id: "next-owner"), sourceID: "next-source")
        model.configure(revision: UUID(), filterRevision: UUID(), preferences: .init(),
                        profile: topicProfile(scope: nextScope), scope: nextScope, catalogue: replacement, playback: replacement)
        await source.releaseHome(2, items: [topic("50", "甜寵")]); await stale.value
        #expect(model.items.isEmpty)
        try await loadTopicPage(1, [topic("30", "懸疑"), topic("40", "甜寵")], model, replacement)
        #expect(model.items.map(\.id) == ["30", "40"] && model.current?.id == "30")
    }

    @Test func restoredQueueProvidesTheRealTailWithoutReorderingItsCurrentCard() async throws {
        let fixture = try PreviewSessionFixture(); defer { fixture.clear() }
        let saved = [topic("10", "懸疑"), topic("20", "懸疑")]
        try await fixture.store.save(scope: scope, category: .realDrama, items: saved, currentStableID: "20", snapshot: nil)
        let source = PreviewCatalogueGate(), model = configured(source, sessionStore: fixture.store)
        defer { model.invalidateSource(); cleanUp(model, source) }
        model.updateRankingProfile(topicProfile(), scope: scope)
        let restore = try #require(model.sessionRestoreTask)
        await restore.value
        #expect(model.current?.id == "20" && model.queue.page == 0)
        try await loadTopicPage(1, [topic("30", "懸疑"), topic("40", "甜寵")], model, source)
        #expect(model.items.map(\.id) == ["10", "20", "40", "30"] && model.current?.id == "20")
    }

    @Test func aPendingNewBatchUsesTheLatestExplicitTopicChoiceWithoutReorderingExistingCards() async throws {
        let source = PreviewCatalogueGate(), model = configured(source)
        defer { cleanUp(model, source) }
        model.updateRankingProfile(topicProfile(), scope: scope)
        try await loadTopicPage(1, [topic("10", "懸疑"), topic("20", "懸疑")], model, source, more: true)
        model.loadMoreIfNeeded(force: true)
        try await wait { await source.hasHome(2) }
        let pending = try #require(model.catalogueTask)
        var topics = RecommendationTopicPreferences()
        try topics.set(tag: "甜寵", preference: .less)
        model.updateRankingProfile(topicProfile(topics: topics), scope: scope)
        #expect(model.items.map(\.id) == ["10", "20"])
        await source.releaseHome(2, items: [topic("30", "懸疑"), topic("40", "甜寵")]); await pending.value
        #expect(model.items.map(\.id) == ["10", "20", "30", "40"] && model.current?.id == "10")
        #expect(model.reasonByID["40"] == nil)
    }

    private func topic(_ id: String, _ tag: String) -> Series { .init(id: id, title: "劇\(id)", tags: [tag]) }
    private func topicProfile(scope: LibraryScope? = nil, topics: RecommendationTopicPreferences = .init()) -> PersonalizedRecommendationProfile {
        .init(scope: scope ?? self.scope, favorites: [topic("1", "懸疑"), topic("2", "甜寵")], history: [], topicPreferences: topics)
    }
    private func loadTopicPage(_ page: Int, _ items: [Series], _ model: RecommendationPreviewModel,
                               _ source: PreviewCatalogueGate, more: Bool = false) async throws {
        if page == 1 { model.loadInitial() } else { model.loadMoreIfNeeded(force: true) }
        try await wait { await source.hasHome(page) }
        let task = try #require(model.catalogueTask)
        await source.releaseHome(page, items: items, more: more); await task.value
    }

    private func seedSession(_ store: PreviewSessionStore, scope: LibraryScope, ids: [String], current: String, seconds: Double) async throws {
        try await store.save(scope: scope, category: .realDrama, items: ids.map { .init(id: $0, title: "劇\($0)") },
                             currentStableID: current, snapshot: .init(seriesID: current, episodeID: current + "1", position: seconds, duration: 90))
    }

    private func configured(_ source: PreviewCatalogueGate, sessionStore: PreviewSessionStore? = nil) -> RecommendationPreviewModel {
        let model = RecommendationPreviewModel(sessionStore: sessionStore)
        model.configure(revision: UUID(), filterRevision: UUID(), preferences: .init(),
                        profile: .init(scope: scope, favorites: [], history: []), scope: scope,
                        catalogue: source, playback: source)
        return model
    }
    private func hidden(_ ids: [String]) throws -> RecommendationPreferences {
        var preferences = RecommendationPreferences()
        for id in ids { try preferences.setNotInterested(seriesID: id, value: true) }
        return preferences
    }
    private func activate(_ id: String, _ model: RecommendationPreviewModel) {
        model.update(selectedID: id, isIdle: true, isActive: true, isSceneActive: true, isDetailPresented: false)
    }
    private func loadFirst(_ model: RecommendationPreviewModel, _ source: PreviewCatalogueGate,
                           ids: [String], more: Bool = false) async throws {
        model.loadInitial()
        try await wait { await source.hasHome(1) }
        let task = try #require(model.catalogueTask)
        await source.releaseHome(1, ids: ids, more: more)
        await task.value
    }
    private func prepare(_ id: String, _ model: RecommendationPreviewModel, _ source: PreviewCatalogueGate) async throws {
        activate(id, model)
        try await wait { await source.hasDetail(id) }
        let task = try #require(model.detailTask)
        await source.releaseDetail(id)
        await task.value
        #expect(model.media[id] != nil)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("A controlled catalogue operation never entered its barrier")
        throw CancellationError()
    }
    private func cleanUp(_ model: RecommendationPreviewModel, _ source: PreviewCatalogueGate) {
        model.suspend()
        Task { await source.finishAll() }
    }
}

/// Deliberately ignores task cancellation until release, exercising stale-response guards.
private actor PreviewCatalogueGate: CatalogService, RecommendationProvenanceProviding {
    nonisolated let detailCancellations = PreviewDetailCancellations()
    private(set) var homeRequests: [Int] = []
    private(set) var detailRequests: [String] = []
    private(set) var playbackRequests: [String] = []
    private var homes: [Int: CheckedContinuation<SeriesPage, any Error>] = [:]
    private var details: [String: CheckedContinuation<SeriesDetail, any Error>] = [:]
    private var playbacks: [String: CheckedContinuation<PlaybackSource, any Error>] = [:]
    private var origins: [String: RecommendationProvenance] = [:]
    private var holdProvenance = false
    private var provenanceWaiter: CheckedContinuation<Void, Never>?

    func setOrigins(_ origins: [String: RecommendationProvenance], hold: Bool = false) {
        self.origins = origins; holdProvenance = hold
    }
    func provenance(for seriesIDs: [String]) async -> [String: RecommendationProvenance] {
        if holdProvenance { await withCheckedContinuation { provenanceWaiter = $0 } }
        return origins.filter { seriesIDs.contains($0.key) }
    }
    func hasProvenance() -> Bool { provenanceWaiter != nil }
    func releaseProvenance() { holdProvenance = false; provenanceWaiter?.resume(); provenanceWaiter = nil }

    func home(page: Int) async throws -> SeriesPage {
        homeRequests.append(page)
        return try await withCheckedThrowingContinuation { homes[page] = $0 }
    }
    func detail(id: String) async throws -> SeriesDetail {
        detailRequests.append(id)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { details[id] = $0 }
        } onCancel: { self.detailCancellations.record(id) }
    }
    func search(query: String, page: Int) async throws -> SeriesPage { throw CatalogError.network }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        playbackRequests.append(seriesID)
        return try await withCheckedThrowingContinuation { playbacks[seriesID] = $0 }
    }
    func hasHome(_ page: Int) -> Bool { homes[page] != nil }
    func hasDetail(_ id: String) -> Bool { details[id] != nil }
    func hasPlayback(_ id: String) -> Bool { playbacks[id] != nil }
    func releaseHome(_ page: Int, ids: [String], more: Bool = false) {
        homes.removeValue(forKey: page)?.resume(returning: .init(items: ids.map { .init(id: $0, title: "劇\($0)") }, page: page, hasMore: more))
    }
    func releaseHome(_ page: Int, items: [Series], more: Bool = false) {
        homes.removeValue(forKey: page)?.resume(returning: .init(items: items, page: page, hasMore: more))
    }
    func releaseDetail(_ id: String, episodeID: String? = nil) {
        details.removeValue(forKey: id)?.resume(returning: .init(series: .init(id: id, title: "劇\(id)"),
            episodes: [.init(id: episodeID ?? "\(id)1", number: 1, title: "第1集")]))
    }
    func failHome(_ page: Int) { homes.removeValue(forKey: page)?.resume(throwing: CatalogError.network) }
    func releasePlayback(_ id: String) {
        playbacks.removeValue(forKey: id)?.resume(returning: .init(url: URL(string: "https://example.invalid/test.mp4")!))
    }
    func finishAll() {
        releaseProvenance()
        let home = Array(homes.values), detail = Array(details.values), playback = Array(playbacks.values)
        homes = [:]; details = [:]; playbacks = [:]
        for continuation in home { continuation.resume(throwing: CancellationError()) }
        for continuation in detail { continuation.resume(throwing: CancellationError()) }
        for continuation in playback { continuation.resume(throwing: CancellationError()) }
    }
}

private final class PreviewSessionClockGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var armed = false, blocked = false
    var entered: Bool { lock.withLock { blocked } }
    func arm() { lock.withLock { armed = true; blocked = false } }
    func release() { semaphore.signal() }
    func now() -> Date {
        let shouldBlock = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false; blocked = true; return true
        }
        if shouldBlock { semaphore.wait() }
        return Date(timeIntervalSince1970: 10_000)
    }
}

@MainActor
private final class PreviewSessionFixture {
    let name: String
    let defaults: UserDefaults
    let store: PreviewSessionStore
    init(clock: PreviewSessionClockGate? = nil) throws {
        name = "Hongguo.PreviewModelSessionTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: name))
        store = PreviewSessionStore(defaults: defaults, storageKey: "synthetic.preview-session", now: { clock?.now() ?? Date() })
    }
    func clear() { defaults.removePersistentDomain(forName: name) }
}

private final class PreviewDetailCancellations: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func record(_ id: String) { lock.lock(); counts[id, default: 0] += 1; lock.unlock() }
    func count(for id: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[id, default: 0] }
}
