import Testing
@testable import HongguoCore

struct RecommendationPreviewQueueTests {
    @Test func catalogueOrderAndCursorUseOnlyReceivedSeries() throws {
        var queue = RecommendationPreviewQueue()
        let request = queue.beginPageRequest()!
        #expect(request.page == 1)
        #expect(queue.beginPageRequest() == nil)
        try queue.receive(page(1, ["31", "11", "21"], more: true), for: request)
        #expect(queue.current?.id == "31")
        #expect(queue.move(by: 1)?.id == "11")
        #expect(queue.move(by: 1)?.id == "21")
        #expect(queue.move(by: 1) == nil)
        #expect(queue.move(by: -1)?.id == "11")
        #expect(queue.move(by: 50) == nil)
        #expect(queue.current?.id == "11")
    }

    @Test func repeatedIDsAreDeduplicatedWithoutStoppingValidPagination() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10", "10", "20"], more: true), for: queue.beginPageRequest()!)
        try queue.receive(page(2, ["20", "10"], more: true), for: queue.beginPageRequest()!)
        #expect(queue.items.map(\.id) == ["10", "20"])
        #expect(queue.hasMore)
        try queue.receive(page(3, ["20", "30"], more: false), for: queue.beginPageRequest()!)
        #expect(queue.items.map(\.id) == ["10", "20", "30"])
        #expect(!queue.hasMore)
        #expect(queue.beginPageRequest() == nil)
    }

    @Test func sourceResetAndCancellationRejectLateResponses() throws {
        var queue = RecommendationPreviewQueue()
        let stale = queue.beginPageRequest()!
        queue.reset()
        let replacement = queue.beginPageRequest()!
        #expect(try !queue.receive(page(1, ["10"], more: true), for: stale))
        #expect(queue.items.isEmpty)
        try queue.receive(page(1, ["20"], more: true), for: replacement)
        let cancelled = queue.beginPageRequest()!
        queue.cancelPageRequest()
        let retry = queue.beginPageRequest()!
        #expect(retry.page == cancelled.page)
        #expect(retry != cancelled)
        #expect(try !queue.receive(page(2, ["30"], more: false), for: cancelled))
        try queue.receive(page(2, ["40"], more: false), for: retry)
        #expect(queue.items.map(\.id) == ["20", "40"])
    }

    @Test func cancelledTaskCannotClaimAResetQueueOrBlockItsReplacement() async throws {
        var initial = RecommendationPreviewQueue()
        let oldPending = initial.beginPageRequest()
        let oldRequest = try #require(oldPending)
        initial.reset()
        let cancelled = Task { [initial] in
            var queue = initial
            withUnsafeCurrentTask { $0?.cancel() }
            #expect(Task.isCancelled)
            #expect(queue.beginPageRequest() == nil)
            return queue
        }
        let returnedQueue = await cancelled.value
        #expect(!Task.isCancelled)
        let replacement = Task { [returnedQueue] in
            var queue = returnedQueue
            let pending = queue.beginPageRequest()
            let request = try #require(pending)
            #expect(request.page == 1)
            #expect(try !queue.receive(page(1, ["20"], more: false), for: oldRequest))
            try queue.receive(page(1, ["30"], more: false), for: request)
            return queue
        }
        let result = try await replacement.value
        #expect(result.items.map(\.id) == ["30"])
        #expect(result.page == 1)
        #expect(!result.hasMore)
    }

    @Test func malformedPagesCannotPartiallyReplaceCurrentQueue() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10"], more: true), for: queue.beginPageRequest()!)
        let request = queue.beginPageRequest()!
        #expect(throws: CatalogError.malformedResponse) {
            try queue.receive(page(3, ["20"], more: false), for: request)
        }
        #expect(throws: CatalogError.invalidID) {
            try queue.receive(page(2, ["20", "invalid"], more: false), for: request)
        }
        #expect(queue.items.map(\.id) == ["10"])
        #expect(queue.page == 1)
        #expect(queue.current?.id == "10")
        queue.cancelPageRequest()
        #expect(queue.beginPageRequest()?.page == 2)
    }

    @Test func continuousBrowsingKeepsMemoryBoundedAndStopsAtPageLimit() throws {
        var queue = RecommendationPreviewQueue(capacity: 120)
        for pageNumber in 1...100 {
            let ids = (0..<100).map { String(pageNumber * 100 + $0) }
            let request = queue.beginPageRequest()!
            try queue.receive(page(pageNumber, ids, more: true), for: request)
            #expect(queue.items.count <= queue.capacity)
            if pageNumber > 1 { #expect(queue.move(by: 1)?.id == ids.first) }
            for expected in ids.dropFirst() { #expect(queue.move(by: 1)?.id == expected) }
            #expect(queue.current?.id == ids.last)
        }
        #expect(queue.items.count == 120)
        #expect(!queue.hasMore)
        #expect(queue.beginPageRequest() == nil)
        #expect(queue.hasPrevious)
    }

    @Test func prefetchCannotEvictCurrentOrUnvisitedCards() throws {
        var queue = RecommendationPreviewQueue(capacity: 101)
        try queue.receive(page(1, (100...199).map(String.init), more: true), for: queue.beginPageRequest()!)
        let next = queue.beginPageRequest()!
        #expect(throws: CatalogError.responseTooLarge) {
            try queue.receive(page(2, (200...299).map(String.init), more: true), for: next)
        }
        #expect(queue.current?.id == "100")
        #expect(queue.items.count == 100)
        #expect(queue.page == 1)
    }

    @Test func previewRequiresAvailableEpisodeOneAndMatchingSeries() throws {
        let series = Series(id: "10", title: "第一集試看")
        let one = Episode(id: "100", number: 1, title: "第一集")
        let two = Episode(id: "101", number: 2, title: "第二集")
        #expect(try RecommendationPreviewQueue.firstEpisode(in: .init(series: series, episodes: [two, one]), expectedSeriesID: "10") == one)
        #expect(throws: CatalogError.unavailablePlayback) {
            try RecommendationPreviewQueue.firstEpisode(in: .init(series: series, episodes: [two]), expectedSeriesID: "10")
        }
        var locked = one
        locked.isAvailable = false
        #expect(throws: CatalogError.unavailablePlayback) {
            try RecommendationPreviewQueue.firstEpisode(in: .init(series: series, episodes: [locked, two]), expectedSeriesID: "10")
        }
        #expect(throws: CatalogError.malformedResponse) {
            try RecommendationPreviewQueue.firstEpisode(in: .init(series: series, episodes: [one]), expectedSeriesID: "99")
        }
    }

    @Test func stableIDSelectionAllowsScrollJumpsWithoutUnknownIDsMovingTheCursor() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10", "20", "30", "40"], more: true), for: queue.beginPageRequest()!)
        #expect(queue.select(seriesID: "40")?.id == "40")
        #expect(queue.select(seriesID: "10")?.id == "10")
        #expect(queue.select(seriesID: "999") == nil)
        #expect(queue.current?.id == "10")
        #expect(queue.select(seriesID: "30")?.id == "30")
        #expect(queue.move(by: 1)?.id == "40")
    }

    @Test func trimmingHistoryPreservesCurrentIDAndCannotRetargetAnEvictedPosition() throws {
        var queue = RecommendationPreviewQueue(capacity: 120)
        try queue.receive(page(1, (100...199).map(String.init), more: true), for: queue.beginPageRequest()!)
        #expect(queue.select(seriesID: "199")?.id == "199")
        try queue.receive(page(2, (200...299).map(String.init), more: false), for: queue.beginPageRequest()!)
        #expect(queue.items.count == 120)
        #expect(queue.current?.id == "199")
        #expect(queue.currentIndex == 19)
        #expect(queue.select(seriesID: "100") == nil)
        #expect(queue.current?.id == "199")
        #expect(queue.select(seriesID: "201")?.id == "201")
        #expect(queue.select(seriesID: "199")?.id == "199")
    }

    @Test func rankingNewCandidatesKeepsCurrentAndVisitedCardsAnchored() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10", "20"], more: true), for: queue.beginPageRequest()!,
                          ranking: { Array($0.reversed()) })
        #expect(queue.items.map(\.id) == ["20", "10"])
        queue.select(seriesID: "10")
        var preferences = RecommendationPreferences()
        try preferences.setNotInterested(seriesID: "30", value: true)
        try queue.receive(page(2, ["10", "30", "40", "50"], more: false),
                          for: queue.beginPageRequest()!, preferences: preferences,
                          ranking: { Array($0.reversed()) })
        #expect(queue.items.map(\.id) == ["20", "10", "50", "40"])
        #expect(queue.current?.id == "10")
        #expect(queue.move(by: 1)?.id == "50")
        #expect(queue.page == 2)
        #expect(!queue.hasMore)
    }

    @Test func excludingCurrentChoosesTheNextSurvivorWithoutResettingAPendingPage() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10", "20", "30", "40"], more: true), for: queue.beginPageRequest()!)
        queue.select(seriesID: "20")
        let nextPage = queue.beginPageRequest()!
        var preferences = RecommendationPreferences()
        try preferences.setNotInterested(seriesID: "20", value: true)
        try preferences.setNotInterested(seriesID: "30", value: true)
        let change = queue.excludeNotInterested(using: preferences)
        #expect(change.removedIDs == ["20", "30"])
        #expect(change.previousCurrentID == "20" && change.currentID == "40")
        #expect(queue.page == 1 && queue.hasMore)
        #expect(queue.beginPageRequest() == nil)
        // Simulate an in-flight caller holding an old preferences snapshot.
        try queue.receive(page(2, ["20", "30", "50"], more: false), for: nextPage)
        #expect(queue.items.map(\.id) == ["10", "40", "50"])
        #expect(queue.current?.id == "40")
        #expect(queue.page == 2 && !queue.hasMore)
    }

    @Test func excludingBeforeCurrentRetainsItsIDAndExcludingLastFallsBackToPrevious() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10", "20", "30"], more: false), for: queue.beginPageRequest()!)
        queue.select(seriesID: "30")
        var preferences = RecommendationPreferences()
        try preferences.setNotInterested(seriesID: "10", value: true)
        let first = queue.excludeNotInterested(using: preferences)
        #expect(!first.currentChanged)
        #expect(queue.current?.id == "30" && queue.currentIndex == 1)
        try preferences.setNotInterested(seriesID: "30", value: true)
        let last = queue.excludeNotInterested(using: preferences)
        #expect(last.currentID == "20")
        #expect(queue.currentIndex == 0 && queue.page == 1 && !queue.hasMore)
    }

    @Test func anEmptyExcludedPageContinuesAtTheNextPageAndBlocksUnseenHiddenIDs() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10"], more: true), for: queue.beginPageRequest()!)
        var preferences = RecommendationPreferences()
        try preferences.setNotInterested(seriesID: "10", value: true)
        try preferences.setNotInterested(seriesID: "20", value: true)
        let change = queue.excludeNotInterested(using: preferences)
        #expect(change.currentID == nil && queue.items.isEmpty)
        #expect(queue.page == 1 && queue.hasMore)
        let pending = queue.beginPageRequest()
        let request = try #require(pending)
        #expect(request.page == 2)
        try queue.receive(page(2, ["10", "20", "30"], more: false), for: request)
        #expect(queue.items.map(\.id) == ["30"])
        #expect(queue.current?.id == "30")
    }

    @Test func excludingOnlyDislikesNeverRemovesAnAlreadyPreviewedCurrentCard() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10", "20"], more: true), for: queue.beginPageRequest()!)
        var preferences = RecommendationPreferences(skipsPreviewed: true)
        try preferences.markPreviewed(seriesID: "10")
        let change = queue.excludeNotInterested(using: preferences)
        #expect(change.removedIDs.isEmpty && !change.currentChanged)
        #expect(queue.current?.id == "10" && queue.items.count == 2)
        try preferences.setNotInterested(seriesID: "20", value: true)
        queue.excludeNotInterested(using: preferences)
        #expect(queue.items.map(\.id) == ["10"])
    }

    @Test func restoringPreferencesAndResettingCanRevisitAnExcludedWork() throws {
        var queue = RecommendationPreviewQueue()
        try queue.receive(page(1, ["10"], more: true), for: queue.beginPageRequest()!)
        let stale = queue.beginPageRequest()!
        var preferences = RecommendationPreferences()
        try preferences.setNotInterested(seriesID: "10", value: true)
        queue.excludeNotInterested(using: preferences)
        preferences.clearNotInterested()
        queue.reset()
        #expect(try !queue.receive(page(2, ["20"], more: false), for: stale))
        try queue.receive(page(1, ["10"], more: false), for: queue.beginPageRequest()!, preferences: preferences)
        #expect(queue.current?.id == "10")
    }

    @Test func rankingCannotReintroduceHiddenOrForeignOrRepeatedCandidates() throws {
        var queue = RecommendationPreviewQueue()
        var preferences = RecommendationPreferences()
        try preferences.setNotInterested(seriesID: "10", value: true)
        queue.excludeNotInterested(using: preferences)
        try queue.receive(page(1, ["10", "20"], more: false), for: queue.beginPageRequest()!, ranking: {
            [.init(id: "10", title: "已隱藏"), .init(id: "999", title: "非來源")] + $0 + $0
        })
        #expect(queue.items.map(\.id) == ["20"])
    }

    private func page(_ number: Int, _ ids: [String], more: Bool) -> SeriesPage {
        .init(items: ids.map { .init(id: $0, title: "劇集\($0)") }, page: number, hasMore: more)
    }
}
