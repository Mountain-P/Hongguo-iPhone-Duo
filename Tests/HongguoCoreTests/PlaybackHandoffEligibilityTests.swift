// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct PlaybackHandoffEligibilityTests {
    private let request = UUID()
    private let revision = UUID()
    private let item = UUID()
    private var scope: LibraryScope { .init(owner: .guest, sourceID: "fixture-source") }
    private var context: PlaybackHandoffEligibility.Context { .init(scope: scope, revision: revision, quality: .automatic) }
    private var snapshot: PreviewPlaybackSnapshot { .init(seriesID: "series-a", episodeID: "episode-a", position: 20, duration: 120) }

    @Test func latestMatchingRouteCanClaimTheExistingReadyItemWithinTwoSeconds() {
        for position in [18.0, 20, 22] {
            var policy = make()
            #expect(claim(&policy, position: position, playback: playback(position: position)))
            #expect(policy.status == .claimed && policy.rejectionReason == nil)
        }
    }

    @Test func originalGuestAccountAndSourceMustAllMatch() {
        for changedScope in [LibraryScope(owner: .account(id: "fixture-account"), sourceID: scope.sourceID),
                             LibraryScope(owner: .guest, sourceID: "other-source")] {
            var policy = make()
            let changed = PlaybackHandoffEligibility.Context(scope: changedScope, revision: revision, quality: .automatic)
            #expect(!claim(&policy, context: changed))
            #expect(policy.rejectionReason == .scopeChanged)
        }
        let accountScope = LibraryScope(owner: .account(id: "account-a"), sourceID: scope.sourceID)
        let initial = PlaybackHandoffEligibility.Context(scope: accountScope, revision: revision, quality: .automatic)
        let other = PlaybackHandoffEligibility.Context(scope: .init(owner: .account(id: "account-b"), sourceID: scope.sourceID),
                                                       revision: revision, quality: .automatic)
        var accountPolicy = make(context: initial)
        #expect(!claim(&accountPolicy, context: other))
    }

    @Test func sourceRevisionOrQualityChangesRequireANewPlayer() {
        for (changed, reason) in [
            (PlaybackHandoffEligibility.Context(scope: scope, revision: UUID(), quality: .automatic), PlaybackHandoffEligibility.RejectionReason.revisionChanged),
            (.init(scope: scope, revision: revision, quality: .dataSaver), .qualityChanged)
        ] {
            var policy = make()
            #expect(!claim(&policy, context: changed))
            #expect(policy.rejectionReason == reason)
        }
    }

    @Test func ANewLaunchOrReplacedItemCannotConsumeAnOldToken() {
        var otherRequest = make()
        #expect(!claim(&otherRequest, requestID: UUID()))
        #expect(otherRequest.rejectionReason == .requestChanged)
        var replaced = make()
        #expect(!claim(&replaced, playback: playback(itemID: UUID())))
        #expect(replaced.rejectionReason == .itemChanged)
    }

    @Test func latestRouteAndLivePlayerMustBothRemainOnTheCapturedEpisode() {
        for (seriesID, episodeID) in [("series-b", "episode-a"), ("series-a", "episode-b")] {
            var route = make()
            #expect(!claim(&route, seriesID: seriesID, episodeID: episodeID))
            #expect(route.rejectionReason == .episodeChanged)
            var live = make()
            #expect(!claim(&live, playback: playback(seriesID: seriesID, episodeID: episodeID)))
            #expect(live.rejectionReason == .episodeChanged)
        }
    }

    @Test func aDifferentSavedPositionOrMovedPlayheadCannotReuseThePreview() {
        var saved = make()
        #expect(!claim(&saved, position: 22.000_001))
        #expect(saved.rejectionReason == .positionChanged)
        var moved = make()
        #expect(!claim(&moved, playback: playback(position: 10)))
        #expect(moved.rejectionReason == .positionChanged)
        var oppositeSides = make()
        #expect(!claim(&oppositeSides, position: 18, playback: playback(position: 22)))
        #expect(oppositeSides.rejectionReason == .positionChanged)
    }

    @Test func readinessAndPendingSeekAreCheckedAtTheMomentOfClaim() {
        var unready = make()
        #expect(!claim(&unready, playback: playback(isReady: false)))
        #expect(unready.rejectionReason == .notReady)
        var seeking = make()
        #expect(!claim(&seeking, playback: playback(isSeeking: true)))
        #expect(seeking.rejectionReason == .seeking)
    }

    @Test func backgroundClaimIsTerminalAndForegroundingCannotReviveIt() {
        var policy = make()
        #expect(!claim(&policy, sceneActive: false))
        #expect(policy.status == .disposed && policy.rejectionReason == .inactiveScene)
        #expect(!claim(&policy))
    }

    @Test func expiryUsesAnInjectedMonotonicClockAndHasABoundedLifetime() {
        var before = make()
        #expect(claim(&before, now: 159.999))
        for now in [160.0, 161, Double.greatestFiniteMagnitude] {
            var expired = make()
            #expect(!claim(&expired, now: now))
            #expect(expired.rejectionReason == .expired)
        }
        var bounded = make(timeToLive: 3_600)
        #expect(!claim(&bounded, now: 160))
        #expect(bounded.rejectionReason == .expired)
        var backwards = make()
        #expect(!claim(&backwards, now: 99.999))
        #expect(backwards.rejectionReason == .invalidInput)
    }

    @Test func aClaimCanSucceedOnlyOnceAndCancellationCannotUndoTransfer() {
        var policy = make()
        #expect(claim(&policy))
        #expect(!claim(&policy))
        policy.cancel()
        #expect(policy.status == .claimed)
        #expect(!claim(&policy))
    }

    @Test func failedAttemptAndExplicitCancellationCanNeverBeReused() {
        var failed = make()
        #expect(!claim(&failed, context: .init(scope: scope, revision: UUID(), quality: .automatic)))
        #expect(!claim(&failed))
        #expect(failed.status == .disposed && failed.rejectionReason == .revisionChanged)
        var cancelled = make()
        cancelled.cancel(); cancelled.cancel()
        #expect(!claim(&cancelled))
        #expect(cancelled.status == .disposed && cancelled.rejectionReason == .cancelled)
        // A distinct later launch owns an independent claim, not a global UUID registry.
        var next = make()
        #expect(claim(&next))
    }

    @Test func malformedSnapshotsScopesAndLifetimesAreUnclaimableFromCreation() {
        let badSnapshots: [PreviewPlaybackSnapshot] = [
            .init(seriesID: "", episodeID: "episode-a", position: 20, duration: 120),
            .init(seriesID: "series-a", episodeID: "", position: 20, duration: 120),
            .init(seriesID: "series-a", episodeID: "episode-a", position: .nan, duration: 120),
            .init(seriesID: "series-a", episodeID: "episode-a", position: -1, duration: 120),
            .init(seriesID: "series-a", episodeID: "episode-a", position: 121, duration: 120),
            .init(seriesID: "series-a", episodeID: "episode-a", position: 0, duration: 0)
        ]
        for snapshot in badSnapshots {
            var policy = make(snapshot: snapshot)
            #expect(policy.status == .disposed && policy.rejectionReason == .invalidInput)
            #expect(!claim(&policy))
        }
        for ttl: Double in [0, -1, .nan, .infinity] {
            var policy = make(timeToLive: ttl)
            #expect(!claim(&policy))
            #expect(policy.rejectionReason == .invalidInput)
        }
        for badScope in [LibraryScope(owner: .guest, sourceID: ""), LibraryScope(owner: .account(id: ""), sourceID: "source")] {
            let badContext = PlaybackHandoffEligibility.Context(scope: badScope, revision: revision, quality: .automatic)
            var policy = make(context: badContext)
            #expect(!claim(&policy, context: badContext))
            #expect(policy.rejectionReason == .invalidInput)
        }
    }

    @Test func invalidClaimTimesAndLiveDurationsCannotReachPromotion() {
        for bad: Double in [.nan, .infinity, -.infinity, -1] {
            var target = make()
            #expect(!claim(&target, position: bad))
            var live = make()
            #expect(!claim(&live, playback: playback(position: bad)))
            var clock = make()
            #expect(!claim(&clock, now: bad))
            var duration = make()
            #expect(!claim(&duration, playback: playback(duration: bad)))
        }
        var unknownDuration = make()
        #expect(!claim(&unknownDuration, playback: playback(duration: 0)))
        var outOfBounds = make()
        #expect(!claim(&outOfBounds, playback: playback(position: 121)))
    }

    private func make(context: PlaybackHandoffEligibility.Context? = nil, snapshot: PreviewPlaybackSnapshot? = nil,
                      timeToLive: Double = 60) -> PlaybackHandoffEligibility {
        .init(requestID: request, context: context ?? self.context, snapshot: snapshot ?? self.snapshot,
              itemID: item, createdAt: 100, timeToLive: timeToLive)
    }

    private func playback(seriesID: String = "series-a", episodeID: String = "episode-a", position: Double = 20,
                          duration: Double = 120, itemID: UUID? = nil, isReady: Bool = true,
                          isSeeking: Bool = false) -> PlaybackHandoffEligibility.Playback {
        .init(seriesID: seriesID, episodeID: episodeID, position: position, duration: duration,
              itemID: itemID ?? item, isReady: isReady, isSeeking: isSeeking)
    }

    private func claim(_ policy: inout PlaybackHandoffEligibility, requestID: UUID? = nil,
                       context: PlaybackHandoffEligibility.Context? = nil, seriesID: String = "series-a",
                       episodeID: String = "episode-a", position: Double = 20,
                       playback: PlaybackHandoffEligibility.Playback? = nil, sceneActive: Bool = true,
                       now: Double = 101) -> Bool {
        policy.claim(requestID: requestID ?? request, context: context ?? self.context,
                     seriesID: seriesID, episodeID: episodeID, position: position, playback: playback ?? self.playback(),
                     isSceneActive: sceneActive, now: now)
    }
}
