import Foundation
import Testing
@testable import HongguoCore

struct LibraryBrowserTests {
    private let scope = LibraryScope(owner: .account(id: "42"), sourceID: "native")
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func localSearchMatchesSimplifiedTraditionalWidthCaseAndAllTokensAcrossMetadata() {
        let target = Series(id: "100", title: "霸道总裁 ＣＡＦÉ", description: "異世界故事", tags: ["重生"])
        let other = Series(id: "101", title: "重生故事")
        #expect(LibraryBrowser.favorites([target, other], query: "總裁 cafe 重生").map(\.id) == ["100"])
        #expect(LibraryBrowser.favorites([target, other], query: "异世界").map(\.id) == ["100"])
        #expect(LibraryBrowser.favorites([target, other], query: "總裁 不存在").isEmpty)
        #expect(target.title == "霸道总裁 ＣＡＦÉ")
    }

    @Test func historySearchIncludesEpisodeTitleAndCombinesWithCompletionFilter() {
        let record = record("100", seconds: 99, episodeTitle: "FINALE 大結局")
        #expect(LibraryBrowser.history([record], query: "finale 结局", filter: .completed).count == 1)
        #expect(LibraryBrowser.history([record], query: "finale", filter: .inProgress).isEmpty)
        #expect(LibraryBrowser.history([record], query: " \n ").count == 1)
    }

    @Test func favoriteStoredOrderIsPreservedAndTitleSortingUsesNumbersWithStableIDs() {
        let items = [Series(id: "10", title: "第10部"), Series(id: "3", title: "第2部"), Series(id: "2", title: "第2部")]
        #expect(LibraryBrowser.favorites(items).map(\.id) == ["10", "3", "2"])
        #expect(LibraryBrowser.favorites(items, sort: .titleAscending).map(\.id) == ["2", "3", "10"])
        #expect(LibraryBrowser.favorites(items, sort: .titleDescending).map(\.id) == ["10", "3", "2"])
        #expect(items.map(\.id) == ["10", "3", "2"])
    }

    @Test func historySortsByActualTimeAndProgressWithoutGuessingWholeSeriesCompletion() {
        let old = record("100", seconds: 99, time: -10)
        let recent = record("200", seconds: 20, time: 10)
        let unknownDuration = WatchRecord(series: .init(id: "300", title: "未知時長"), episode: episode,
                                          seconds: 100, duration: 0, updatedAt: date)
        #expect(LibraryBrowser.history([old, recent, unknownDuration], sort: .recent).map(\.id) == ["200", "300", "100"])
        #expect(LibraryBrowser.history([old, recent, unknownDuration], sort: .oldest).map(\.id) == ["100", "300", "200"])
        #expect(LibraryBrowser.history([old, recent, unknownDuration], sort: .progressDescending).map(\.id) == ["100", "200", "300"])
        #expect(LibraryBrowser.history([old, recent, unknownDuration], filter: .completed).map(\.id) == ["100"])
        #expect(LibraryBrowser.history([unknownDuration], filter: .inProgress).count == 1)
    }

    @Test func equalTimeOrderingDoesNotLosePrecisionForNineteenDigitIDs() {
        let smaller = record("7687140962539162648"), larger = record("7687140962539162649")
        #expect(LibraryBrowser.history([larger, smaller]).map(\.id) == [smaller.id, larger.id])
    }

    @Test func batchHistoryRemovalKeepsFavoritesAndUnselectedFailedProgressAndRejectsStalePullResurrection() throws {
        let records = [record("100"), record("101"), record("102")]
        var state = try LibraryState(scope: scope, snapshot: .init(favorites: records.map(\.series), history: records))
        try state.record(record("100", seconds: 30, time: 1))
        let pending = state.pendingProgress[0]
        state.markProgressAttempt(operationID: pending.operationID)
        var result = try LibraryManagement.removingHistory(seriesIDs: ["101", "102"], from: state, at: date.addingTimeInterval(20))
        #expect(result.history.map(\.id) == ["100"])
        #expect(Set(result.favorites.map(\.id)) == ["100", "101", "102"])
        #expect(result.pendingProgress.first { $0.seriesID == "100" }?.operationID == pending.operationID)
        #expect(result.pendingProgress.first { $0.seriesID == "100" }?.retryRequired == true)
        #expect(result.pendingProgress.filter(\.isDeletion).count == 2)
        #expect(result.eligibleProgress().isEmpty)
        try result.merge(remote: .init(history: records), scope: scope)
        #expect(result.history.map(\.id) == ["100"])
    }

    @Test func batchUnfavoriteCreatesExplicitNewIntentWithoutUnlockingUnselectedFailuresOrAcceptingOldACK() throws {
        var state = try LibraryState(scope: scope, snapshot: .init(favorites: [series("100"), series("101"), series("102")]))
        try state.setFavorite(series("100"), isFavorite: true, at: date)
        try state.setFavorite(series("101"), isFavorite: true, at: date)
        let unselected = state.pendingFavorites.first { $0.seriesID == "100" }!
        let oldSelected = state.pendingFavorites.first { $0.seriesID == "101" }!
        state.markFavoriteAttempt(operationID: unselected.operationID); state.markFavoriteAttempt(operationID: oldSelected.operationID)
        var result = try LibraryManagement.removingFavorites(seriesIDs: ["101", "102"], from: state, at: date.addingTimeInterval(1))
        #expect(result.favorites.map(\.id) == ["100"])
        #expect(result.pendingFavorites.first { $0.seriesID == "100" }?.operationID == unselected.operationID)
        #expect(result.pendingFavorites.first { $0.seriesID == "100" }?.retryRequired == true)
        let newSelected = result.pendingFavorites.first { $0.seriesID == "101" }!
        #expect(newSelected.operationID != oldSelected.operationID && !newSelected.retryRequired && !newSelected.isFavorite)
        #expect(Set(result.eligibleFavorites().map(\.seriesID)) == ["101", "102"])
        result.acknowledgeFavorites(operationIDs: [oldSelected.operationID])
        #expect(result.pendingFavorites.contains { $0.operationID == newSelected.operationID })
    }

    @Test func invalidBatchIsRejectedBeforeAnyMutationAndUnknownIDsDoNotCreateTombstones() throws {
        let state = try LibraryState(scope: scope, snapshot: .init(favorites: [series("100")], history: [record("100")]))
        #expect(throws: CatalogError.invalidID) { try LibraryManagement.removingFavorites(seriesIDs: ["100", "invalid"], from: state) }
        #expect(throws: CatalogError.invalidID) { try LibraryManagement.removingHistory(seriesIDs: ["100", "invalid"], from: state) }
        #expect(throws: UserLibraryError.invalidMutation) {
            try LibraryManagement.removingHistory(seriesIDs: ["100"], from: state, at: Date(timeIntervalSince1970: .nan))
        }
        #expect(try LibraryManagement.removingHistory(seriesIDs: ["999"], from: state) == state)
        #expect(try LibraryManagement.removingFavorites(seriesIDs: [], from: state) == state)
        #expect(state.favorites.count == 1 && state.history.count == 1)
    }

    private var episode: Episode { .init(id: "900", number: 1, title: "第1集") }
    private func series(_ id: String) -> Series { .init(id: id, title: "劇集\(id)") }
    private func record(_ id: String, seconds: Double = 20, time: TimeInterval = 0, episodeTitle: String = "第1集") -> WatchRecord {
        .init(series: series(id), episode: .init(id: "900", number: 1, title: episodeTitle), seconds: seconds, duration: 100,
              updatedAt: date.addingTimeInterval(time))
    }
}
