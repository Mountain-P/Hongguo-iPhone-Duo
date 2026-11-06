import Foundation
import Testing
@testable import HongguoCore

struct UserLibraryTests {
    private let guest = LibraryScope(owner: .guest, sourceID: "native")
    private let account = LibraryScope(owner: .account(id: "42"), sourceID: "native")

    @Test func legacySnapshotDecodesWithoutEpisodeHistoryOrCount() throws {
        let json = #"{"favorites":[],"history":[{"series":{"id":"100","title":"測試劇","cover":"","description":"","badge":"全100集","tags":[]},"episode":{"id":"200","number":1,"title":"第1集","isAvailable":true},"seconds":20,"duration":100,"updatedAt":0}]}"#
        let old = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(json.utf8))
        #expect(old.episodeHistory.isEmpty)
        #expect(old.history[0].episodeCount == nil)
        let state = try LibraryState(scope: guest, snapshot: old)
        #expect(state.history.count == 1)
        #expect(state.episodeHistory.count == 1)
        #expect(state.record(for: "100")?.seconds == 20)
    }

    @Test func normalizationUsesNewestRecordAndKeepsEveryEpisode() throws {
        let old = libraryRecord(seconds: 80, time: 1)
        let newest = libraryRecord(episodeID: "201", number: 2, seconds: 10, time: 2)
        let state = try LibraryState(scope: account, snapshot: .init(favorites: [librarySeries(), librarySeries()], history: [old, newest, old]))
        #expect(state.favorites.count == 1)
        #expect(state.history.count == 1)
        #expect(state.record(for: "100")?.episode.id == "201")
        #expect(state.episodeHistory.count == 2)
    }

    @Test func equalTimestampDoesNotRollbackOrGuessAnotherEpisode() throws {
        var state = try LibraryState(scope: guest, snapshot: .init(history: [libraryRecord(seconds: 80, time: 1)]))
        try state.merge(remote: .init(history: [libraryRecord(seconds: 20, time: 1)]), scope: guest)
        #expect(state.record(for: "100")?.seconds == 80)
        try state.merge(remote: .init(history: [libraryRecord(seconds: 90, time: 1)]), scope: guest)
        #expect(state.record(for: "100")?.seconds == 90)
        try state.merge(remote: .init(history: [libraryRecord(episodeID: "299", number: 99, seconds: 99, time: 1)]), scope: guest)
        #expect(state.record(for: "100")?.episode.id == "200")
    }

    @Test func newerTimestampCanRepresentIntentionalRewind() throws {
        var state = try LibraryState(scope: guest)
        try state.record(libraryRecord(seconds: 80, time: 1))
        try state.record(libraryRecord(seconds: 10, time: 2))
        #expect(state.record(for: "100")?.seconds == 10)
        #expect(state.pendingProgress.count == 1)
        #expect(state.pendingProgress[0].record?.seconds == 10)
    }

    @Test func episodeCompletionIsNotWholeSeriesCompletionAndSurvivesRewatch() throws {
        let episodes = [Episode(id: "200", number: 1, title: "1"), Episode(id: "201", number: 2, title: "2")]
        var state = try LibraryState(scope: guest)
        try state.record(libraryRecord(seconds: 99, time: 1))
        #expect(state.history[0].isEpisodeCompleted)
        #expect(!state.isSeriesCompleted(seriesID: "100", episodes: episodes))
        try state.record(libraryRecord(episodeID: "201", number: 2, seconds: 99, time: 2))
        #expect(state.isSeriesCompleted(seriesID: "100", episodes: episodes))
        try state.record(libraryRecord(seconds: 1, time: 3))
        #expect(!state.record(for: "100")!.isEpisodeCompleted)
        #expect(state.isSeriesCompleted(seriesID: "100", episodes: episodes))
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        #expect(decoded.isSeriesCompleted(seriesID: "100", episodes: episodes))
        #expect(!decoded.isSeriesCompleted(seriesID: "100", episodes: []))
    }

    @Test func mergeCannotCrossGuestAccountOrSource() throws {
        var state = try LibraryState(scope: account, snapshot: .init(favorites: [librarySeries()]))
        let before = state
        #expect(throws: UserLibraryError.scopeMismatch) { try state.merge(remote: .init(), scope: guest) }
        #expect(throws: UserLibraryError.scopeMismatch) {
            try state.merge(remote: .init(), scope: .init(owner: .account(id: "43"), sourceID: "native"))
        }
        #expect(throws: UserLibraryError.scopeMismatch) {
            try state.merge(remote: .init(), scope: .init(owner: .account(id: "42"), sourceID: "other"))
        }
        #expect(state == before)
    }

    @Test func partialFavoritePullUnionsAndCompletePullCanRemove() throws {
        var state = try LibraryState(scope: account, snapshot: .init(favorites: [librarySeries(), librarySeries("101")]))
        try state.merge(remote: .init(favorites: [librarySeries("102")]), scope: account)
        #expect(Set(state.favorites.map(\.id)) == ["100", "101", "102"])
        try state.merge(remote: .init(favorites: [librarySeries("102")]), scope: account, favoritesAreComplete: true)
        #expect(state.favorites.map(\.id) == ["102"])
    }

    @Test func pendingFavoriteAndTombstoneWinOverStalePullAndAckIsSpecific() throws {
        var state = try LibraryState(scope: account)
        try state.setFavorite(librarySeries(), isFavorite: true, at: libraryDate(1))
        let oldID = state.pendingFavorites[0].operationID
        try state.setFavorite(librarySeries(), isFavorite: false, at: libraryDate(2))
        let deleteID = state.pendingFavorites[0].operationID
        state.acknowledgeFavorites(operationIDs: [oldID])
        #expect(state.pendingFavorites.count == 1)
        try state.merge(remote: .init(favorites: [librarySeries()]), scope: account)
        #expect(!state.isFavorite("100"))
        state.acknowledgeFavorites(operationIDs: [deleteID])
        try state.merge(remote: .init(favorites: [librarySeries()]), scope: account)
        #expect(!state.isFavorite("100"))
        try state.merge(remote: .init(), scope: account, favoritesAreComplete: true)
        try state.merge(remote: .init(favorites: [librarySeries()]), scope: account)
        #expect(state.isFavorite("100"))
    }

    @Test func unacknowledgedFavoriteAddSurvivesCompleteRemoteAbsence() throws {
        var state = try LibraryState(scope: account)
        try state.setFavorite(librarySeries(), isFavorite: true)
        try state.merge(remote: .init(), scope: account, favoritesAreComplete: true)
        #expect(state.isFavorite("100"))
        #expect(state.pendingFavorites.count == 1)
    }

    @Test func pendingProgressIsCoalescedAndOldReceiptCannotClearNewPosition() throws {
        var state = try LibraryState(scope: account)
        try state.record(libraryRecord(seconds: 20, time: 1))
        let oldID = state.pendingProgress[0].operationID
        try state.record(libraryRecord(seconds: 40, time: 2))
        state.acknowledgeProgress(operationIDs: [oldID])
        #expect(state.pendingProgress.count == 1)
        #expect(state.pendingProgress[0].record?.seconds == 40)
        let localID = state.pendingProgress[0].operationID
        try state.merge(remote: .init(history: [libraryRecord(seconds: 50, time: 3)]), scope: account)
        #expect(state.record(for: "100")?.seconds == 50)
        #expect(state.pendingProgress[0].record?.seconds == 50)
        state.acknowledgeProgress(operationIDs: [localID])
        #expect(state.pendingProgress.count == 1)
    }

    @Test func clearAndSingleRemovePreventOldHistoryResurrection() throws {
        let first = libraryRecord(seconds: 99, time: 1)
        let second = libraryRecord(seriesID: "101", episodeID: "300", seconds: 10, time: 2)
        var state = try LibraryState(scope: account, snapshot: .init(history: [first, second]))
        state.removeHistory(seriesID: "100", at: libraryDate(3))
        #expect(state.history.map(\.series.id) == ["101"])
        try state.merge(remote: .init(history: [first]), scope: account)
        #expect(state.history.map(\.series.id) == ["101"])
        state.clearHistory(at: libraryDate(4))
        #expect(state.history.isEmpty)
        #expect(state.episodeHistory.isEmpty)
        let decoded = try JSONDecoder().decode(LibraryState.self, from: JSONEncoder().encode(state))
        var restored = decoded
        restored.acknowledgeProgress(operationIDs: Set(restored.pendingProgress.map(\.operationID)))
        try restored.merge(remote: .init(history: [first, second]), scope: account)
        #expect(restored.history.isEmpty)
    }

    @Test func explicitGuestImportCopiesWithoutConsumingOrMixingScopes() throws {
        var localGuest = try LibraryState(scope: guest)
        try localGuest.setFavorite(librarySeries(), isFavorite: true)
        try localGuest.record(libraryRecord(seconds: 25, time: 2))
        let guestBefore = localGuest
        var user = try LibraryState(scope: account)
        try user.importGuest(localGuest)
        #expect(user.isFavorite("100"))
        #expect(user.record(for: "100")?.seconds == 25)
        #expect(user.pendingFavorites.count == 1)
        #expect(user.pendingProgress.count == 1)
        #expect(localGuest == guestBefore)
        var otherSource = try LibraryState(scope: .init(owner: .account(id: "42"), sourceID: "bridge"))
        #expect(throws: UserLibraryError.scopeMismatch) { try otherSource.importGuest(localGuest) }
        #expect(throws: UserLibraryError.scopeMismatch) { try localGuest.importGuest(user) }
    }

    @Test func stateRoundTripRetainsScopePendingAndFavoriteDeletion() throws {
        var state = try LibraryState(scope: account)
        try state.setFavorite(librarySeries(), isFavorite: false)
        try state.record(libraryRecord(seconds: 10, time: 2))
        let raw = try JSONEncoder().encode(state)
        var restored = try JSONDecoder().decode(LibraryState.self, from: raw)
        #expect(restored == state)
        try restored.merge(remote: .init(favorites: [librarySeries()]), scope: account)
        #expect(!restored.isFavorite("100"))
    }

    @Test func historyDoesNotDropOlderEntriesAtTwoHundred() throws {
        let records = (0..<240).map { index in
            libraryRecord(seriesID: String(1000 + index), episodeID: String(5000 + index), seconds: 5, time: index)
        }
        let state = try LibraryState(scope: guest, snapshot: .init(history: records))
        #expect(state.history.count == 240)
        #expect(state.episodeHistory.count == 240)
        #expect(state.record(for: "1000") != nil)
    }

    @Test func invalidInputIsRejectedWithoutMutatingExistingState() throws {
        var state = try LibraryState(scope: guest, snapshot: .init(favorites: [librarySeries()]))
        let before = state
        for invalid in [libraryRecord(seconds: -1), libraryRecord(seconds: .nan), libraryRecord(duration: .infinity),
                        libraryRecord(seriesID: "../bad"), libraryRecord(episodeCount: 0)] {
            #expect(throws: UserLibraryError.invalidRecord) { try state.record(invalid) }
        }
        #expect(state == before)
        #expect(throws: UserLibraryError.invalidScope) { try LibraryState(scope: .init(owner: .account(id: ""), sourceID: "native")) }
        #expect(throws: UserLibraryError.invalidMutation) {
            try LibraryState(scope: guest, pendingProgress: [.init(seriesID: "999", record: libraryRecord())])
        }
    }

    @Test func invalidRemoteDataCannotPartiallyMergeFavorites() throws {
        var state = try LibraryState(scope: account, snapshot: .init(favorites: [librarySeries()]))
        let before = state
        #expect(throws: UserLibraryError.invalidRecord) {
            try state.merge(remote: .init(favorites: [librarySeries("101")], history: [libraryRecord(seconds: .nan)]), scope: account)
        }
        #expect(state == before)
    }

    @Test func metadataEnrichmentPreservesProgressAndMutationIdentity() throws {
        let finished = libraryRecord(seconds: 99, time: 1, episodeCount: 2)
        let anotherEpisode = libraryRecord(episodeID: "201", number: 2, seconds: 20, time: 2, episodeCount: 2)
        var state = try LibraryState(scope: account, snapshot: .init(
            favorites: [librarySeries(), librarySeries("101")], history: [finished, anotherEpisode]))
        try state.record(libraryRecord(seconds: 5, time: 3, episodeCount: 2))
        try state.setFavorite(librarySeries(), isFavorite: true, at: libraryDate(4))
        try state.setFavorite(librarySeries("101"), isFavorite: false, at: libraryDate(5))
        state.removeHistory(seriesID: "101", at: libraryDate(6))
        let before = state
        let rich = Series(id: "100", title: "完整劇名", cover: "https://example.com/cover.jpg",
                          description: "正式劇情", badge: "全2集", tags: ["劇情"])

        try state.enrichSeries(rich)

        #expect(state.scope == before.scope)
        #expect(state.favorites == [rich])
        var expectedResume = before.record(for: "100")!
        expectedResume.series = rich
        #expect(state.record(for: "100") == expectedResume)
        #expect(state.episodeHistory.count == before.episodeHistory.count)
        for original in before.episodeHistory {
            var expected = original
            if expected.series.id == "100" { expected.series = rich }
            #expect(state.episodeHistory.first { $0.episode.id == original.episode.id } == expected)
        }
        let previousFavorite = before.pendingFavorites.first { $0.seriesID == "100" }!
        #expect(state.pendingFavorites.first { $0.seriesID == "100" } == FavoriteMutation(
            operationID: previousFavorite.operationID, series: rich,
            isFavorite: previousFavorite.isFavorite, updatedAt: previousFavorite.updatedAt))
        let previousProgress = before.pendingProgress.first { $0.seriesID == "100" }!
        #expect(state.pendingProgress.first { $0.seriesID == "100" } == ProgressMutation(
            operationID: previousProgress.operationID, seriesID: "100", record: expectedResume,
            updatedAt: previousProgress.updatedAt))
        #expect(state.pendingFavorites.count == before.pendingFavorites.count)
        #expect(state.pendingProgress.count == before.pendingProgress.count)
        #expect(state.pendingFavorites.first { $0.seriesID == "101" } == before.pendingFavorites.first { $0.seriesID == "101" })
        #expect(state.pendingProgress.first { $0.seriesID == "101" } == before.pendingProgress.first { $0.seriesID == "101" })

        struct Proofs: Decodable { let completedRecords: [WatchRecord] }
        let encoded = try JSONEncoder().encode(state)
        let proof = try JSONDecoder().decode(Proofs.self, from: encoded).completedRecords.first { $0.series.id == "100" }
        var expectedProof = finished
        expectedProof.series = rich
        #expect(proof == expectedProof)
        #expect(state.isSeriesCompleted(seriesID: "100", episodes: [finished.episode]))
        #expect(try JSONDecoder().decode(LibraryState.self, from: encoded) == state)
    }

    @Test func metadataEnrichmentDoesNotRestoreRemovedFavoriteOrCreatePendingOperation() throws {
        var state = try LibraryState(scope: account, snapshot: .init(favorites: [librarySeries()]))
        let rich = Series(id: "100", title: "真實劇名", tags: ["喜劇"])
        try state.enrichSeries(rich)
        #expect(state.favorites == [rich])
        #expect(state.history.isEmpty)
        #expect(state.pendingFavorites.isEmpty)
        #expect(state.pendingProgress.isEmpty)

        try state.setFavorite(librarySeries(), isFavorite: false, at: libraryDate(10))
        let mutation = state.pendingFavorites[0]
        try state.enrichSeries(rich)
        #expect(!state.isFavorite("100"))
        #expect(state.pendingFavorites == [.init(operationID: mutation.operationID, series: rich,
                                                isFavorite: false, updatedAt: mutation.updatedAt)])
        try state.merge(remote: .init(favorites: [rich]), scope: account)
        #expect(!state.isFavorite("100"))
    }

    @Test func metadataEnrichmentRejectsUnknownOrInvalidSeriesWithoutChangingLibrary() throws {
        var state = try LibraryState(scope: account, snapshot: .init(favorites: [librarySeries()]))
        let before = state
        for invalid in [Series(id: "999", title: "不在片庫"), Series(id: "100", title: " \n"), Series(id: "bad", title: "無效ID")] {
            #expect(throws: UserLibraryError.invalidRecord) { try state.enrichSeries(invalid) }
            #expect(state == before)
        }
    }
}

private func librarySeries(_ id: String = "100") -> Series { Series(id: id, title: "測試劇\(id)") }
private func libraryDate(_ seconds: Int) -> Date { Date(timeIntervalSince1970: Double(seconds)) }
private func libraryRecord(seriesID: String = "100", episodeID: String = "200", number: Int = 1,
                           seconds: Double = 10, duration: Double = 100, time: Int = 1, episodeCount: Int? = nil) -> WatchRecord {
    WatchRecord(series: librarySeries(seriesID), episode: Episode(id: episodeID, number: number, title: "第\(number)集"),
                seconds: seconds, duration: duration, updatedAt: libraryDate(time), episodeCount: episodeCount)
}
