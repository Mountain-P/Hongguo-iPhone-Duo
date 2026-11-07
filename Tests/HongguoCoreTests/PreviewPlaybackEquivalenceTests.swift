import Foundation
import Testing
@testable import HongguoCore

struct PreviewPlaybackEquivalenceTests {
    private let series = Series(id: "100", title: "Fixture")
    private var episodes: [Episode] { [
        .init(id: "900", number: 1, title: "1"),
        .init(id: "901", number: 2, title: "2", isAvailable: false),
        .init(id: "902", number: 3, title: "3")
    ] }
    private var detail: SeriesDetail { .init(series: series, episodes: episodes) }

    @Test func smallDifferencesAreEquivalentThroughTheInclusiveTwoSecondBoundary() {
        for (saved, preview) in [(20.1, 20.2), (20.0, 22.0), (22.0, 20.0), (0.0, 2.0), (20.0, 20.0)] {
            #expect(equivalent(saved: saved, preview: preview))
        }
        #expect(PreviewPlaybackEquivalence.positionTolerance == 2)
    }

    @Test func anythingBeyondTwoSecondsStillRequiresAChoice() {
        #expect(!equivalent(saved: 20, preview: 22.000_001))
        #expect(!equivalent(saved: 22.000_001, preview: 20))
        #expect(!equivalent(saved: 20, preview: 40))
    }

    @Test func crossingCompletionRequiresAChoiceEvenForASubsecondDifference() {
        #expect(!equivalent(saved: 88.1, preview: 88.3))
        #expect(!equivalent(saved: 88.3, preview: 88.1))
    }

    @Test func matchingCompletionCanAdvanceOrReplayButCannotMergeDifferentOriginalEpisodes() {
        #expect(equivalent(saved: 89, preview: 90))
        #expect(equivalent(episodeID: "902", saved: 89, preview: 90))
        let completedFirst = record(id: "900", seconds: 90)
        let atNextStart = PreviewPlaybackSnapshot(seriesID: "100", episodeID: "902", position: 0, duration: 90)
        #expect(PlaybackContinuation.preferred(seriesID: "100", episodes: episodes, record: completedFirst)?.episode.id == "902")
        #expect(atNextStart.continuation(in: detail)?.episode.id == "902")
        #expect(!PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: atNextStart, record: completedFirst, detail: detail))
    }

    @Test func aCompletedFinalEpisodeReplayIsDifferentFromAnEarlyPositionInThatEpisode() {
        let completedFinal = record(id: "902", seconds: 90)
        for position in [0.0, 0.1, 1.0, 2.0] {
            let snapshot = PreviewPlaybackSnapshot(seriesID: "100", episodeID: "902", position: position, duration: 90)
            #expect(!PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: completedFinal, detail: detail))
        }
        #expect(!equivalent(episodeID: "902", saved: 1, preview: 90))
    }

    @Test func foreignMissingAndLockedInputsCannotBecomeEquivalent() {
        for (seriesID, episodeID) in [("200", "900"), ("100", "999"), ("100", "901")] {
            let snapshot = PreviewPlaybackSnapshot(seriesID: seriesID, episodeID: episodeID, position: 20, duration: 90)
            #expect(!PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: record(id: episodeID, seconds: 20), detail: detail))
        }
        let snapshot = PreviewPlaybackSnapshot(seriesID: "100", episodeID: "900", position: 20, duration: 90)
        let foreign = WatchRecord(series: .init(id: "200", title: "Foreign"), episode: episodes[0], seconds: 20, duration: 90)
        #expect(!PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: foreign, detail: detail))
        #expect(!PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: record(id: "902", seconds: 20), detail: detail))
    }

    @Test func invalidTimesNeverUseTheToleranceToSuppressAChoice() {
        for (position, duration) in [(Double.nan, 90.0), (.infinity, 90), (-1, 90), (0, 0), (0, -.infinity), (0, .nan)] {
            let snapshot = PreviewPlaybackSnapshot(seriesID: "100", episodeID: "900", position: position, duration: duration)
            #expect(!PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: record(id: "900", seconds: 0), detail: detail))
        }
        for (seconds, duration) in [(Double.nan, 90.0), (.infinity, 90), (-1, 90), (0, -1), (0, .infinity)] {
            let snapshot = PreviewPlaybackSnapshot(seriesID: "100", episodeID: "900", position: 0, duration: 90)
            let saved = WatchRecord(series: series, episode: episodes[0], seconds: seconds, duration: duration)
            #expect(!PreviewPlaybackEquivalence.canContinueWithoutChoice(snapshot: snapshot, record: saved, detail: detail))
        }
    }

    private func equivalent(episodeID: String = "900", saved: Double, preview: Double) -> Bool {
        PreviewPlaybackEquivalence.canContinueWithoutChoice(
            snapshot: .init(seriesID: "100", episodeID: episodeID, position: preview, duration: 90),
            record: record(id: episodeID, seconds: saved), detail: detail)
    }

    private func record(id: String, seconds: Double) -> WatchRecord {
        .init(series: series, episode: .init(id: id, number: id == "900" ? 1 : 3, title: "Saved"), seconds: seconds, duration: 90)
    }
}
