// SPDX-License-Identifier: GPL-3.0-only
import Testing
@testable import HongguoCore

struct PlaybackGesturePolicyTests {
    @Test func episodeSwipeRequiresStrictDistanceAndVerticalDominance() {
        var state = EpisodeSwipeState(currentIndex: 1, episodeAvailability: [true, true, true])
        #expect(state.update(horizontal: 0, vertical: -45).progress == 0.5)
        #expect(!state.update(horizontal: 0, vertical: -90).isArmed)
        #expect(!state.update(horizontal: 100, vertical: -120).isArmed)
        let next = state.update(horizontal: 100, vertical: -121)
        #expect(next.direction == .next && next.targetIndex == 2 && next.isArmed)
        #expect(next.progress == 1)
        #expect(state.end(horizontal: 0, vertical: 100) == 0)
    }

    @Test func firstLastAndUnavailableEpisodesProduceFeedbackWithoutCommit() {
        var first = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
        #expect(first.update(horizontal: 0, vertical: 120).blockedReason == .firstEpisode)
        #expect(first.end(horizontal: 0, vertical: 120) == nil)
        var last = EpisodeSwipeState(currentIndex: 1, episodeAvailability: [true, true])
        #expect(last.update(horizontal: 0, vertical: -120).blockedReason == .lastEpisode)
        #expect(last.end(horizontal: 0, vertical: -120) == nil)
        var locked = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, false])
        let feedback = locked.update(horizontal: 0, vertical: -120)
        #expect(feedback.targetIndex == 1 && feedback.blockedReason == .unavailableEpisode)
        #expect(!feedback.isArmed)
        #expect(locked.end(horizontal: 0, vertical: -120) == nil)
    }

    @Test func holdOrScrubDisqualifiesTheWholeSwipeEvenAfterRelease() {
        for holding in [true, false] {
            var state = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
            _ = state.update(horizontal: 0, vertical: -100, isHolding: holding, isScrubbing: !holding)
            #expect(state.update(horizontal: 0, vertical: -150).blockedReason == .conflictingGesture)
            #expect(state.end(horizontal: 0, vertical: -150) == nil)
        }
    }

    @Test func returningBelowThresholdOrTowardHorizontalDoesNotCommit() {
        var returned = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
        #expect(returned.update(horizontal: 0, vertical: -150).isArmed)
        #expect(returned.end(horizontal: 0, vertical: -40) == nil)
        var diagonal = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
        #expect(diagonal.update(horizontal: 0, vertical: -150).isArmed)
        #expect(diagonal.end(horizontal: 160, vertical: -150) == nil)
    }

    @Test func swipeCanCommitOnlyOnceAndCancellationPermanentlyRevokesIt() {
        var ended = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
        #expect(ended.end(horizontal: 0, vertical: -100) == 1)
        #expect(ended.end(horizontal: 0, vertical: -200) == nil)
        #expect(!ended.isActive)
        var cancelled = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
        _ = cancelled.update(horizontal: 0, vertical: -200)
        cancelled.cancel()
        #expect(cancelled.end(horizontal: 0, vertical: -200) == nil)
        #expect(cancelled.feedback.direction == nil && cancelled.feedback.progress == 0)
    }

    @Test func invalidSwipeInputAndConfigurationCannotProduceAnIndex() {
        for index in [-1, 2, Int.max] {
            var state = EpisodeSwipeState(currentIndex: index, episodeAvailability: [true, true])
            #expect(state.end(horizontal: 0, vertical: -100) == nil)
            #expect(state.feedback.blockedReason == .invalidInput)
        }
        var empty = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [])
        #expect(empty.end(horizontal: 0, vertical: 100) == nil)
        for invalid: Double in [.nan, .infinity, -.infinity] {
            var state = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
            _ = state.update(horizontal: invalid, vertical: -100)
            #expect(state.end(horizontal: 0, vertical: -100) == nil)
        }
    }

    @Test func scrubbingStartsFromPlayheadAndMapsOneTrackWidthToDuration() {
        var state = FineScrubbingState(position: 30, duration: 120, trackWidth: 240)
        #expect(state.update(horizontalTranslation: 60, upwardDistance: 0) == 60)
        #expect(state.update(horizontalTranslation: -30, upwardDistance: 0) == 15)
        #expect(state.end() == 15)
    }

    @Test func exactHeightThresholdsChooseTheFourSensitivities() {
        var state = FineScrubbingState(position: 0, duration: 1_000, trackWidth: 1_000)
        #expect(state.update(horizontalTranslation: 100, upwardDistance: 49) == 100)
        #expect(state.sensitivity == .full)
        #expect(state.update(horizontalTranslation: 200, upwardDistance: 50) == 150)
        #expect(state.sensitivity == .half)
        #expect(state.update(horizontalTranslation: 300, upwardDistance: 100) == 175)
        #expect(state.sensitivity == .quarter)
        #expect(state.update(horizontalTranslation: 400, upwardDistance: 150) == 185)
        #expect(state.sensitivity == .tenth)
    }

    @Test func changingSensitivityWithoutHorizontalMovementNeverJumps() {
        var state = FineScrubbingState(position: 50, duration: 200, trackWidth: 200)
        _ = state.update(horizontalTranslation: 40, upwardDistance: 0)
        for height: Double in [50, 100, 150, 100, 50, 0, -80] {
            #expect(state.update(horizontalTranslation: 40, upwardDistance: height) == 90)
        }
        #expect(state.end() == 90)
    }

    @Test func movementBackAndForthUsesTheSensitivityOfEachNewDelta() {
        var state = FineScrubbingState(position: 100, duration: 400, trackWidth: 400)
        #expect(state.update(horizontalTranslation: 100, upwardDistance: 0) == 200)
        #expect(state.update(horizontalTranslation: 140, upwardDistance: 100) == 210)
        #expect(state.update(horizontalTranslation: 100, upwardDistance: 100) == 200)
        #expect(state.update(horizontalTranslation: 0, upwardDistance: 0) == 100)
        #expect(state.end() == 100)
    }

    @Test func clampingLetsTheNextReversedDeltaLeaveEitherBoundaryImmediately() {
        var state = FineScrubbingState(position: 90, duration: 100, trackWidth: 100)
        #expect(state.update(horizontalTranslation: 100, upwardDistance: 0) == 100)
        #expect(state.update(horizontalTranslation: 90, upwardDistance: 0) == 90)
        #expect(state.update(horizontalTranslation: -100, upwardDistance: 0) == 0)
        #expect(state.update(horizontalTranslation: -90, upwardDistance: 0) == 10)
        var outside = FineScrubbingState(position: -10, duration: 100, trackWidth: 100)
        #expect(outside.initialPosition == 0)
        #expect(outside.end() == 0)
    }

    @Test func cancelRestoresPreviewAndCannotSeekWhileEndCanSeekOnlyOnce() {
        var cancelled = FineScrubbingState(position: 30, duration: 100, trackWidth: 100)
        _ = cancelled.update(horizontalTranslation: 20, upwardDistance: 0)
        cancelled.cancel()
        #expect(cancelled.position == 30)
        #expect(cancelled.update(horizontalTranslation: 50, upwardDistance: 0) == nil)
        #expect(cancelled.end() == nil)
        var ended = FineScrubbingState(position: 30, duration: 100, trackWidth: 100)
        _ = ended.update(horizontalTranslation: 20, upwardDistance: 0)
        #expect(ended.end() == 50)
        #expect(ended.end() == nil)
        ended.cancel()
        #expect(ended.position == 50)
    }

    @Test func invalidScrubConfigurationRejectsSeekAndInvalidSamplesPreserveTheAnchor() {
        let configurations: [(Double, Double, Double)] = [
            (0, 0, 100), (0, -1, 100), (0, .infinity, 100), (0, .nan, 100),
            (0, 100, 0), (0, 100, -1), (0, 100, .infinity), (0, 100, .nan),
            (.nan, 100, 100), (.infinity, 100, 100)
        ]
        for (position, duration, width) in configurations {
            var state = FineScrubbingState(position: position, duration: duration, trackWidth: width)
            #expect(!state.isActive)
            #expect(state.end() == nil)
        }
        var valid = FineScrubbingState(position: 20, duration: 100, trackWidth: 100)
        _ = valid.update(horizontalTranslation: 10, upwardDistance: 0)
        #expect(valid.update(horizontalTranslation: .nan, upwardDistance: 100) == nil)
        #expect(valid.update(horizontalTranslation: 99, upwardDistance: .infinity) == nil)
        #expect(valid.sensitivity == .full && valid.position == 30)
        #expect(valid.update(horizontalTranslation: 20, upwardDistance: 0) == 40)
    }

    @Test func finiteExtremeCoordinatesRemainClampedAndNeverBecomeNaN() {
        var scrub = FineScrubbingState(position: 50, duration: 100, trackWidth: 1)
        #expect(scrub.update(horizontalTranslation: .greatestFiniteMagnitude, upwardDistance: 0) == 100)
        #expect(scrub.update(horizontalTranslation: -.greatestFiniteMagnitude, upwardDistance: 0) == 0)
        #expect(scrub.end() == 0)
        var swipe = EpisodeSwipeState(currentIndex: 0, episodeAvailability: [true, true])
        #expect(swipe.end(horizontal: .greatestFiniteMagnitude, vertical: -.greatestFiniteMagnitude) == nil)
    }
}
