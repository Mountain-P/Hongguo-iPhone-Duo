import Foundation
import Testing
@testable import HongguoCore

struct PreviewPlaybackSnapshotTests {
    private func detail() -> SeriesDetail {
        .init(series: .init(id: "100", title: "Fixture"), episodes: [
            .init(id: "900", number: 1, title: "1"),
            .init(id: "901", number: 2, title: "2", isAvailable: false),
            .init(id: "902", number: 3, title: "3")])
    }

    @Test func theLatestAvailableEpisodeAndCapturedTimeAreUsedWithoutChangingHistory() throws {
        let snapshot = PreviewPlaybackSnapshot(seriesID: "100", episodeID: "900", position: 32, duration: 90)
        let original = detail()
        let continuation = try #require(snapshot.continuation(in: original))
        #expect(continuation.episode.id == "900" && continuation.seconds == 32)
        #expect(original.episodes.count == 3)
    }

    @Test func completionAdvancesToTheNextAvailableEpisodeAndTheFinalEpisodeReplays() throws {
        for (id, expected) in [("900", "902"), ("902", "902")] {
            let snapshot = PreviewPlaybackSnapshot(seriesID: "100", episodeID: id, position: 89, duration: 90)
            let continuation = try #require(snapshot.continuation(in: detail()))
            #expect(continuation.episode.id == expected && continuation.seconds == 0)
        }
    }

    @Test func invalidTimesRestartTheVerifiedEpisodeAndNeverAdvance() throws {
        for (position, duration) in [(Double.nan, 90.0), (.infinity, 90), (-1, 90), (30, 0), (30, .nan), (30, .infinity), (30, -90)] {
            let snapshot = PreviewPlaybackSnapshot(seriesID: "100", episodeID: "900", position: position, duration: duration)
            let continuation = try #require(snapshot.continuation(in: detail()))
            #expect(continuation.episode.id == "900" && continuation.seconds == 0)
        }
    }

    @Test func aPositionBeyondTheDurationIsTreatedAsCompletedInsteadOfSeekingBeyondEOF() throws {
        let continuation = try #require(PreviewPlaybackSnapshot(seriesID: "100", episodeID: "900", position: 1000, duration: 90).continuation(in: detail()))
        #expect(continuation.episode.id == "902" && continuation.seconds == 0)
    }

    @Test func wrongSeriesMissingAndLockedEpisodesAreRejectedRatherThanSubstituted() {
        for (seriesID, episodeID) in [("200", "900"), ("100", "999"), ("100", "901")] {
            #expect(PreviewPlaybackSnapshot(seriesID: seriesID, episodeID: episodeID, position: 20, duration: 90).continuation(in: detail()) == nil)
        }
    }

    @Test func timeBelowTheCompletionThresholdStaysAtThePreviewPosition() throws {
        let continuation = try #require(PreviewPlaybackSnapshot(seriesID: "100", episodeID: "900", position: 87, duration: 90).continuation(in: detail()))
        #expect(continuation.episode.id == "900" && continuation.seconds == 87)
    }
}
