import Foundation
import Testing
@testable import HongguoCore

struct PlaybackMeasurementTests {
    @Test func startupWaitIsSeparateFromRebufferingAndPauseClosesWait() throws {
        var value = PlaybackMeasurement(context: .episode, startedAt: 10)
        value.recordTransport(waiting: true, playing: false, at: 10)
        value.recordReady(at: 11)
        value.recordFirstFrame(at: 12)
        value.recordTransport(waiting: false, playing: true, at: 12)
        value.recordTransport(waiting: true, playing: false, at: 15)
        value.recordTransport(waiting: true, playing: false, at: 16)
        value.recordTransport(waiting: false, playing: false, at: 18)
        let optional = value.finish(outcome: .completed, at: 25)
        let result = try #require(optional)
        #expect(result.readySeconds == 1)
        #expect(result.firstFrameSeconds == 2)
        #expect(result.rebufferCount == 1)
        #expect(result.rebufferSeconds == 3)
        #expect(result.durationSeconds == 15)
    }

    @Test func diagnosticsPreserveFailureStageThroughRecoveryAndReadLegacyHistory() throws {
        var measure = PlaybackMeasurement(context: .episode, startedAt: 0, route: .relay)
        measure.recordFailure(recovered: true, at: 1)
        measure.beginLookup(route: .relay)
        measure.receivedSource(route: .direct)
        measure.recordReady(at: 2)
        measure.recordFirstFrame(at: 3)
        measure.recordFailure(recovered: true, at: 4)
        measure.beginLookup(route: .relay)
        measure.receivedSource(route: .relay)
        measure.recordReady(at: 5)
        measure.recordFailure(recovered: false, at: 6)
        measure.beginLookup(route: .direct)
        let finished = measure.finish(outcome: .failed, at: 7)
        let result = try #require(finished)
        #expect(result.lastFailureStage == .firstFrame)
        #expect(result.route == .direct && result.lastFailureRoute == .relay)
        #expect(result.failureCount == 3 && result.firstFrameSeconds == 3)
        let encoded = try JSONEncoder().encode(result)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "route")
        legacy.removeValue(forKey: "lastFailureStage")
        legacy.removeValue(forKey: "lastFailureRoute")
        legacy.removeValue(forKey: "lookups")
        let old = try JSONDecoder().decode(PlaybackMeasurement.Summary.self,
                                           from: JSONSerialization.data(withJSONObject: legacy))
        #expect(old.route == nil && old.lastFailureStage == nil && old.lastFailureRoute == nil && old.lookups == nil && old.failureCount == 3)
    }

    @Test func automaticRecoveryKeepsTheOriginalFirstFrameClock() throws {
        var value = PlaybackMeasurement(context: .preview, startedAt: 1)
        value.recordFailure(recovered: true, at: 2)
        value.recordReady(at: 4)
        value.recordFirstFrame(at: 5)
        value.recordFirstFrame(at: 7)
        let optional = value.finish(outcome: .cancelled, at: 8)
        let result = try #require(optional)
        #expect(result.firstFrameSeconds == 4)
        #expect(result.recoveryCount == 1 && result.failureCount == 1)
        let data = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(PlaybackMeasurement.Summary.self, from: data) == result)
        #expect(!String(decoding: data, as: UTF8.self).contains("series"))
        #expect(value.finish(outcome: .failed, at: 9) == nil)
    }

    @Test func invalidAndOutOfOrderEventsCannotCorruptDurations() throws {
        var value = PlaybackMeasurement(context: .episode, startedAt: 10)
        value.recordReady(at: .nan)
        value.recordReady(at: 9)
        value.recordFirstFrame(at: 12)
        value.recordTransport(waiting: true, playing: true, at: 13)
        value.recordTransport(waiting: true, playing: false, at: 14)
        value.recordTransport(waiting: false, playing: true, at: 13)
        let optional = value.finish(outcome: .failed, at: 16)
        let result = try #require(optional)
        #expect(result.readySeconds == nil)
        #expect(result.firstFrameSeconds == 2)
        #expect(result.rebufferCount == 1 && result.rebufferSeconds == 2)
    }

    @Test func recoveryRebuildPauseDoesNotHideTheInterruptedPlaybackTime() throws {
        var value = PlaybackMeasurement(context: .episode, startedAt: 0)
        value.recordFirstFrame(at: 1)
        value.recordTransport(waiting: true, playing: false, at: 10)
        value.recordFailure(recovered: true, at: 11)
        value.recordTransport(waiting: false, playing: false, at: 12)
        value.recordReady(at: 29)
        value.recordTransport(waiting: false, playing: true, at: 30)
        let optional = value.finish(outcome: .completed, at: 35)
        let result = try #require(optional)
        #expect(result.rebufferSeconds == 20)
        #expect(result.rebufferCount == 1)
    }

    @Test func explicitUserPauseEndsRecoveryWithoutCountingTimeAway() throws {
        var value = PlaybackMeasurement(context: .replay, startedAt: 0)
        value.recordFirstFrame(at: 1)
        value.recordTransport(waiting: false, playing: true, at: 1)
        value.recordFailure(recovered: true, at: 10)
        value.recordPause(at: 12)
        value.recordTransport(waiting: false, playing: false, at: 30)
        let optional = value.finish(outcome: .cancelled, at: 40)
        let result = try #require(optional)
        #expect(result.context == .replay)
        #expect(result.firstFrameSeconds == nil)
        #expect(result.rebufferSeconds == 2)
    }
}
