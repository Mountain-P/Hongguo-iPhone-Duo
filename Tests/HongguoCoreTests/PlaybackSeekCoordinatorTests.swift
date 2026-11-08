// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct PlaybackSeekCoordinatorTests {
    @Test func aBurstStartsOnlyTheActiveAndFinalDestinations() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .relative))
        let command1 = state.submit(target: 50, kind: .relative)
        #expect(command1 == nil)
        let command2 = state.submit(target: 60, kind: .relative)
        #expect(command2 == nil)
        let command3 = state.submit(target: 50, kind: .relative)
        #expect(command3 == nil)
        #expect(state.activeRequest == first)
        #expect(state.pendingTarget == 50)
        let last = try requireRequest(state.complete(token: first.token, finished: true))
        #expect(last.target == 50)
        #expect(last.token != first.token)
        let command4 = state.complete(token: last.token, finished: true)
        #expect(command4 == nil)
        #expect(!state.isSeeking && state.pendingTarget == nil)
    }

    @Test func reversingBackToTheActiveDestinationDropsTheOldQueue() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .relative))
        _ = state.submit(target: 80, kind: .relative)
        _ = state.submit(target: 40, kind: .relative)
        #expect(state.pendingTarget == 40)
        let command5 = state.complete(token: first.token, finished: true)
        #expect(command5 == nil)
        #expect(!state.isSeeking)
    }

    @Test func reversingPastTheActiveDestinationKeepsOnlyTheFinalReverseTarget() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .relative))
        _ = state.submit(target: 60, kind: .relative)
        _ = state.submit(target: 30, kind: .relative)
        #expect(state.pendingTarget == 30)
        let command6 = state.complete(token: first.token, finished: true)
        #expect(command6?.target == 30)
    }

    @Test func aFailedActiveSeekStillStartsTheLatestQueuedTarget() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .relative))
        _ = state.submit(target: 80, kind: .precise)
        let next = try requireRequest(state.complete(token: first.token, finished: false))
        #expect(next.target == 80 && next.kind == .precise)
        let command7 = state.complete(token: next.token, finished: false)
        #expect(command7 == nil)
        #expect(!state.isSeeking && state.pendingTarget == nil)
    }

    @Test func anUnrelatedCompletionCannotReleaseOrReplaceTheActiveSeek() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .relative))
        _ = state.submit(target: 50, kind: .relative)
        let command8 = state.complete(token: UUID(), finished: true)
        #expect(command8 == nil)
        #expect(state.activeRequest == first && state.pendingTarget == 50)
        let command9 = state.complete(token: first.token, finished: true)
        #expect(command9?.target == 50)
    }

    @Test func aDuplicateOldCompletionCannotFinishThePromotedSeek() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .relative))
        _ = state.submit(target: 50, kind: .relative)
        let second = try requireRequest(state.complete(token: first.token, finished: true))
        let command10 = state.complete(token: first.token, finished: true)
        #expect(command10 == nil)
        #expect(state.activeRequest == second && state.pendingTarget == 50)
    }

    @Test func resetInvalidatesBothActiveAndQueuedWorkIncludingTheSameLaterTarget() throws {
        var state = PlaybackSeekCoordinator()
        let old = try requireRequest(state.submit(target: 40, kind: .relative))
        _ = state.submit(target: 50, kind: .relative)
        state.reset()
        #expect(!state.isSeeking && state.pendingTarget == nil)
        let replacement = try requireRequest(state.submit(target: 40, kind: .precise))
        #expect(replacement.token != old.token)
        let command11 = state.complete(token: old.token, finished: true)
        #expect(command11 == nil)
        #expect(state.activeRequest == replacement)
        let command12 = state.complete(token: replacement.token, finished: true)
        #expect(command12 == nil)
        #expect(!state.isSeeking)
    }

    @Test func invalidTargetsDoNotConsumeTheSlotOrEraseTheLatestValidTarget() throws {
        var state = PlaybackSeekCoordinator()
        for value: Double in [.nan, .infinity, -.infinity, -1] {
            let command13 = state.submit(target: value, kind: .relative)
            #expect(command13 == nil)
            #expect(!state.isSeeking && state.pendingTarget == nil)
        }
        let first = try requireRequest(state.submit(target: 0, kind: .precise))
        _ = state.submit(target: 20, kind: .relative)
        for value: Double in [.nan, .infinity, -.infinity, -1] {
            let command14 = state.submit(target: value, kind: .precise)
            #expect(command14 == nil)
            #expect(state.activeRequest == first && state.pendingTarget == 20)
        }
    }

    @Test func duplicateActiveTargetDoesNotCreateAnExtraCommand() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .precise))
        let command15 = state.submit(target: 40, kind: .precise)
        #expect(command15 == nil)
        let command16 = state.submit(target: 40, kind: .relative)
        #expect(command16 == nil)
        let command17 = state.complete(token: first.token, finished: true)
        #expect(command17 == nil)
        #expect(!state.isSeeking)
    }

    @Test func anExactScrubCanTightenAnActiveRelativeSeekAtTheSameTarget() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .relative))
        _ = state.submit(target: 80, kind: .relative)
        _ = state.submit(target: 40, kind: .precise)
        let exact = try requireRequest(state.complete(token: first.token, finished: true))
        #expect(exact.target == 40 && exact.toleranceSeconds == 0)
        let command18 = state.complete(token: exact.token, finished: true)
        #expect(command18 == nil)
    }

    @Test func latestSubmissionAlsoReplacesTheQueuedPrecisionPolicy() throws {
        var state = PlaybackSeekCoordinator()
        let first = try requireRequest(state.submit(target: 40, kind: .precise))
        _ = state.submit(target: 50, kind: .precise)
        _ = state.submit(target: 50, kind: .relative)
        let last = try requireRequest(state.complete(token: first.token, finished: true))
        #expect(last.target == 50 && last.toleranceSeconds == 0.15)
        #expect(first.toleranceSeconds == 0)
    }
}

private func requireRequest(_ request: PlaybackSeekCoordinator.Request?) throws -> PlaybackSeekCoordinator.Request {
    try #require(request)
}

struct PlaybackResumeTargetTests {
    @Test func aLiveReloadNearTheEndKeepsItsPositionWhileSavedHistoryRestarts() {
        #expect(PlaybackResumeTarget.target(position: 119.5, duration: 120, isLiveReload: true) == 119.5)
        #expect(PlaybackResumeTarget.target(position: 119.5, duration: 120, isLiveReload: false) == 0)
    }

    @Test func aLiveReloadAtOrBeyondTheEndStaysAtTheLastFrame() {
        #expect(PlaybackResumeTarget.target(position: 120, duration: 120, isLiveReload: true) == 120)
        #expect(PlaybackResumeTarget.target(position: 121, duration: 120, isLiveReload: true) == 120)
        #expect(PlaybackResumeTarget.target(position: 120, duration: 120, isLiveReload: false) == 0)
    }

    @Test func aShorterReloadedRenditionClampsWithoutTurningIntoAReplay() {
        #expect(PlaybackResumeTarget.target(position: 119.5, duration: 100, isLiveReload: true) == 100)
        #expect(PlaybackResumeTarget.target(position: 90, duration: 100, isLiveReload: true) == 90)
    }

    @Test func savedHistoryRetainsItsExistingMiddlePositionAndCompletionThresholds() {
        #expect(PlaybackResumeTarget.target(position: 30, duration: 120, isLiveReload: false) == 30)
        #expect(PlaybackResumeTarget.target(position: 118.99, duration: 120, isLiveReload: false) == 118.99)
        #expect(PlaybackResumeTarget.target(position: 119, duration: 120, isLiveReload: false) == 0)
        // Being in the last second must also meet the completion ratio threshold.
        #expect(PlaybackResumeTarget.target(position: 29, duration: 30, isLiveReload: false) == 29)
        #expect(PlaybackResumeTarget.target(position: 29.5, duration: 30, isLiveReload: false) == 0)
    }

    @Test func anUnknownDurationDoesNotInventAnEndOrDiscardAValidPosition() {
        for live in [false, true] {
            #expect(PlaybackResumeTarget.target(position: 119.5, duration: 0, isLiveReload: live) == 119.5)
            #expect(PlaybackResumeTarget.target(position: 0, duration: 0, isLiveReload: live) == 0)
        }
    }

    @Test func invalidPositionsAndDurationsCannotBecomeResumeCommands() {
        for live in [false, true] {
            for invalid: Double in [.nan, .infinity, -.infinity, -1] {
                #expect(PlaybackResumeTarget.target(position: invalid, duration: 120, isLiveReload: live) == nil)
                #expect(PlaybackResumeTarget.target(position: 30, duration: invalid, isLiveReload: live) == nil)
            }
        }
    }
}
