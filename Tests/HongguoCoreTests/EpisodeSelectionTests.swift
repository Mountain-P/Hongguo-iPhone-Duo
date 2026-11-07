import Testing
@testable import HongguoCore

struct EpisodeSelectionTests {
    @Test func finalGroupUsesTheActualLastEpisodeWithoutPhantomEntries() throws {
        let index = try EpisodeSelection(seriesID: "10", episodes: episodes(102))
        #expect(index.groups.map(\.start) == [1, 31, 61, 91])
        #expect(index.groups.map(\.end) == [30, 60, 90, 102])
        #expect(index.groups.last?.episodes.map(\.number) == Array(91...102))
        #expect(index.group(containing: "1102")?.id == 91)
        for count in [1, 5, 30, 60] {
            let value = try EpisodeSelection(seriesID: "10", episodes: episodes(count))
            #expect(value.groups.last?.end == count)
            #expect(value.groups.flatMap(\.episodes).count == count)
        }
    }

    @Test func numericJumpAcceptsTrimmedDigitsAndRejectsInvalidOrMissingNumbers() throws {
        let index = try EpisodeSelection(seriesID: "10", episodes: episodes(102))
        #expect(try index.resolve(numberText: " 00031 \n").number == 31)
        for invalid in ["", "0", "-1", "+1", "1.5", "第一集", "１２", String(repeating: "9", count: 100)] {
            #expect(throws: EpisodeSelectionError.invalidNumber) { try index.resolve(numberText: invalid) }
        }
        #expect(throws: EpisodeSelectionError.episodeNotFound) { try index.resolve(numberText: "103") }
    }

    @Test func locatingBlockedEpisodePreservesItsUnavailableState() throws {
        var source = episodes(32)
        source[30].isAvailable = false
        let index = try EpisodeSelection(seriesID: "10", episodes: source)
        let selected = try index.resolve(numberText: "31")
        #expect(selected.id == source[30].id)
        #expect(!selected.isAvailable)
        #expect(index.group(containing: selected.id)?.start == 31)
        #expect(PlaybackContinuation.selected(seriesID: "10", episode: selected, record: nil) == nil)
    }

    @Test func resumeLocationRequiresMatchingSeriesAndTheRealEpisodeID() throws {
        let source = episodes(35)
        let index = try EpisodeSelection(seriesID: "10", episodes: source)
        var record = WatchRecord(series: .init(id: "10", title: "測試劇"), episode: source[31], seconds: 10, duration: 100)
        #expect(index.resumeEpisode(record: record) == source[31])
        record.episode.number = 1
        #expect(index.resumeEpisode(record: record)?.number == 32)
        record.series.id = "99"
        #expect(index.resumeEpisode(record: record) == nil)
        record.series.id = "10"; record.episode.id = "9999"
        #expect(index.resumeEpisode(record: record) == nil)
        #expect(index.resumeEpisode(record: nil) == nil)
    }

    @Test func sparseAndUnsortedSourcesNeverInventMissingEpisodes() throws {
        let source = [Episode(id: "102", number: 102, title: "102"),
                      Episode(id: "1", number: 1, title: "1"), Episode(id: "31", number: 31, title: "31")]
        let index = try EpisodeSelection(seriesID: "10", episodes: source)
        #expect(index.episodes.map(\.number) == [1, 31, 102])
        #expect(index.groups.map(\.start) == [1, 31, 91])
        #expect(index.groups.flatMap(\.episodes).count == 3)
        #expect(throws: EpisodeSelectionError.episodeNotFound) { try index.resolve(numberText: "32") }
        #expect(index.group(containing: "unknown") == nil)
    }

    @Test func malformedSourceAndGroupBoundsAreRejected() throws {
        #expect(throws: EpisodeSelectionError.invalidSeries) { try EpisodeSelection(seriesID: "bad", episodes: []) }
        for size in [0, -1, 101, Int.max] {
            #expect(throws: EpisodeSelectionError.invalidGroupSize) { try EpisodeSelection(seriesID: "10", episodes: [], groupSize: size) }
        }
        let valid = episodes(2)
        #expect(throws: EpisodeSelectionError.invalidEpisodes) { try EpisodeSelection(seriesID: "10", episodes: [valid[0], valid[0]]) }
        #expect(throws: EpisodeSelectionError.invalidEpisodes) {
            try EpisodeSelection(seriesID: "10", episodes: [valid[0], .init(id: "999", number: 1, title: "重複集數")])
        }
        #expect(throws: EpisodeSelectionError.invalidEpisodes) {
            try EpisodeSelection(seriesID: "10", episodes: [.init(id: "1", number: 0, title: "無效")])
        }
    }

    @Test func emptyEpisodeListHasNoGroupOrJumpTarget() throws {
        let index = try EpisodeSelection(seriesID: "10", episodes: [])
        #expect(index.groups.isEmpty)
        #expect(index.group(containing: "1") == nil)
        #expect(throws: EpisodeSelectionError.episodeNotFound) { try index.resolve(numberText: "1") }
    }

    @Test func adjacentNavigationSortsUnorderedEpisodesBeforeMovingBothDirections() {
        let source = episodes(3)
        let unordered = [source[2], source[0], source[1]]
        #expect(EpisodeNavigation.adjacent(to: source[1].id, in: unordered, direction: .next) == .episode(source[2]))
        #expect(EpisodeNavigation.adjacent(to: source[1].id, in: unordered, direction: .previous) == .episode(source[0]))
        #expect(unordered.map(\.number) == [3, 1, 2])
    }

    @Test func adjacentNavigationReportsFirstAndLastWithoutProducingAPlaybackTarget() {
        let source = episodes(3)
        #expect(EpisodeNavigation.adjacent(to: source[0].id, in: source, direction: .previous) == .first)
        #expect(EpisodeNavigation.adjacent(to: source[2].id, in: source, direction: .next) == .last)
        #expect(EpisodeNavigation.adjacent(to: source[0].id, in: source, direction: .next) == .episode(source[1]))
        #expect(EpisodeNavigation.adjacent(to: source[2].id, in: source, direction: .previous) == .episode(source[1]))
    }

    @Test func aSingleEpisodeHasBothBoundaries() {
        let source = episodes(1)
        #expect(EpisodeNavigation.adjacent(to: source[0].id, in: source, direction: .previous) == .first)
        #expect(EpisodeNavigation.adjacent(to: source[0].id, in: source, direction: .next) == .last)
    }

    @Test func anUnavailableNextEpisodeIsNotSkippedForALaterAvailableEpisode() {
        var source = episodes(3)
        source[1].isAvailable = false
        #expect(EpisodeNavigation.adjacent(to: source[0].id, in: source, direction: .next) == .unavailable(source[1]))
        #expect(source[2].isAvailable)
    }

    @Test func anUnavailablePreviousEpisodeIsNotSkippedForAnEarlierAvailableEpisode() {
        var source = episodes(3)
        source[1].isAvailable = false
        #expect(EpisodeNavigation.adjacent(to: source[2].id, in: source, direction: .previous) == .unavailable(source[1]))
        #expect(source[0].isAvailable)
    }

    @Test func missingCurrentAndEmptyCataloguesNeverPretendToBeABoundary() {
        let source = episodes(2)
        for direction in [EpisodeNavigation.Direction.previous, .next] {
            for missing: String? in [nil, "", "unknown"] {
                #expect(EpisodeNavigation.adjacent(to: missing, in: source, direction: direction) == .missingCurrent)
            }
            #expect(EpisodeNavigation.adjacent(to: source[0].id, in: [], direction: direction) == .missingCurrent)
        }
    }

    @Test func adjacencyUsesTheActualListInsteadOfAssumingConsecutiveNumbers() {
        let first = Episode(id: "11", number: 1, title: "第一集")
        let middle = Episode(id: "88", number: 8, title: "第八集")
        let last = Episode(id: "4242", number: 42, title: "第四十二集")
        let source = [last, first, middle]
        #expect(EpisodeNavigation.adjacent(to: middle.id, in: source, direction: .previous) == .episode(first))
        #expect(EpisodeNavigation.adjacent(to: middle.id, in: source, direction: .next) == .episode(last))
    }

    @Test func duplicateNumbersHaveStableTiesAndAmbiguousCurrentIDsAreRejected() {
        let first = Episode(id: "11", number: 1, title: "第一集")
        let a = Episode(id: "21", number: 2, title: "第二集甲")
        let b = Episode(id: "22", number: 2, title: "第二集乙")
        #expect(EpisodeNavigation.adjacent(to: a.id, in: [a, b, first], direction: .next) == .episode(b))
        #expect(EpisodeNavigation.adjacent(to: b.id, in: [a, b, first], direction: .previous) == .episode(a))
        #expect(EpisodeNavigation.adjacent(to: a.id, in: [first, a, a], direction: .next) == .missingCurrent)
    }

    private func episodes(_ count: Int) -> [Episode] {
        (1...count).map { .init(id: String(1_000 + $0), number: $0, title: "第\($0)集") }
    }
}
