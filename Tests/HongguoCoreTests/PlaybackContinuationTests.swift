import Foundation
import Testing
@testable import HongguoCore

struct PlaybackContinuationTests {
    private let series = Series(id: "100", title: "續播測試")
    private let first = Episode(id: "200", number: 1, title: "第一集")
    private let last = Episode(id: "202", number: 3, title: "第三集")

    @Test func unfinishedEpisodeContinuesAtItsSavedPosition() {
        let record = saved(first, seconds: 42)
        let result = PlaybackContinuation.preferred(seriesID: series.id, episodes: [first, last], record: record)
        #expect(result?.episode == first)
        #expect(result?.seconds == 42)
    }

    @Test func completedEpisodeAdvancesPastUnavailableEpisodesFromZero() {
        let locked = Episode(id: "201", number: 2, title: "第二集", isAvailable: false)
        let result = PlaybackContinuation.preferred(seriesID: series.id, episodes: [first, locked, last], record: saved(first, seconds: 98))
        #expect(result?.episode == last)
        #expect(result?.seconds == 0)
    }

    @Test func completedFinalEpisodeReplaysFromZeroInsteadOfItsTail() {
        let result = PlaybackContinuation.preferred(seriesID: series.id, episodes: [first, last], record: saved(last, seconds: 99))
        #expect(result?.episode == last)
        #expect(result?.seconds == 0)
    }

    @Test func unsortedBridgeEpisodesContinueByNumberWithoutJumpingBackwards() {
        let middle = Episode(id: "201", number: 2, title: "第二集")
        let unsorted = [last, first, middle]
        for (completed, expected) in [(first, middle), (middle, last), (last, last)] {
            let result = PlaybackContinuation.preferred(seriesID: series.id, episodes: unsorted,
                                                        record: saved(completed, seconds: 99))
            #expect(result?.episode == expected)
            #expect(result?.seconds == 0)
        }
        #expect(PlaybackContinuation.preferred(seriesID: series.id, episodes: unsorted, record: nil)?.episode == first)
    }

    @Test func explicitReplayStartsCompletedEpisodeAtZeroAndKeepsIncompleteResume() {
        #expect(PlaybackContinuation.selected(seriesID: series.id, episode: first, record: saved(first, seconds: 98))?.seconds == 0)
        #expect(PlaybackContinuation.selected(seriesID: series.id, episode: first, record: saved(first, seconds: 41))?.seconds == 41)
        #expect(PlaybackContinuation.selected(seriesID: series.id, episode: last, record: saved(first, seconds: 41))?.seconds == 0)
    }

    @Test func foreignSeriesOrMissingEpisodeCannotSupplyAnotherResumePosition() {
        var foreign = saved(last, seconds: 50)
        foreign.series = Series(id: "999", title: "另一部劇")
        let result = PlaybackContinuation.preferred(seriesID: series.id, episodes: [first, last], record: foreign)
        #expect(result?.episode == first)
        #expect(result?.seconds == 0)
        #expect(PlaybackContinuation.selected(seriesID: series.id, episode: last, record: foreign)?.seconds == 0)
        let missing = saved(Episode(id: "299", number: 3, title: "舊分集"), seconds: 70)
        #expect(PlaybackContinuation.preferred(seriesID: series.id, episodes: [first, last], record: missing)?.episode == first)
    }

    @Test func unavailableEntriesAndInvalidPositionsNeverStartInvalidPlayback() {
        let locked = Episode(id: "201", number: 2, title: "未開放", isAvailable: false)
        #expect(PlaybackContinuation.preferred(seriesID: series.id, episodes: [], record: nil) == nil)
        #expect(PlaybackContinuation.preferred(seriesID: series.id, episodes: [locked], record: nil) == nil)
        #expect(PlaybackContinuation.selected(seriesID: series.id, episode: locked, record: nil) == nil)
        for invalid in [Double.nan, .infinity, -1] {
            #expect(PlaybackContinuation.selected(seriesID: series.id, episode: first, record: saved(first, seconds: invalid))?.seconds == 0)
        }
        var durationUnknown = saved(first, seconds: 30)
        durationUnknown.duration = 0
        #expect(PlaybackContinuation.selected(seriesID: series.id, episode: first, record: durationUnknown)?.seconds == 30)
    }

    private func saved(_ episode: Episode, seconds: Double) -> WatchRecord {
        WatchRecord(series: series, episode: episode, seconds: seconds, duration: 100)
    }
}
