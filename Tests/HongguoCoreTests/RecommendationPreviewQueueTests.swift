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

    private func page(_ number: Int, _ ids: [String], more: Bool) -> SeriesPage {
        .init(items: ids.map { .init(id: $0, title: "劇集\($0)") }, page: number, hasMore: more)
    }
}
