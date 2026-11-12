// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct PlaybackContinuityTests {
    @Test func strongIdentityToleratesCDNDateDriftButRejectsChangedOrMissingBytesIdentity() throws {
        let old = NativeRangeValidators(etag: "\"same\"", lastModified: "old")
        #expect(old.accepts(.init(etag: "\"same\"", lastModified: "new")))
        #expect(old.accepts(.init(etag: "\"same\"")))
        for tag in [nil, "\"other\"", "W/\"same\"", "same"] as [String?] {
            #expect(!old.accepts(.init(etag: tag, lastModified: "old")))
        }
        let url = URL(string: "https://unit.fqnovelvod.com/movie.mp4")!
        func response(total: Int) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: [
                "Content-Type": "video/mp4", "Content-Range": "bytes 16-31/\(total)",
                "Content-Length": "16", "ETag": "\"same\"", "Last-Modified": "new"
            ])!
        }
        _ = try NativeRangeHeaders.parse(response(total: 100), requested: 16..<32, knownTotal: 100, validators: old)
        #expect(throws: NativeProgressiveError.changedSource) {
            try NativeRangeHeaders.parse(response(total: 101), requested: 16..<32, knownTotal: 100, validators: old)
        }
        try NativeProgressiveMedia.validate(.init(data: Data(count: 16), range: 16..<32, totalLength: 100,
            validators: .init(etag: "\"same\"", lastModified: "new")), requested: 16..<32, total: 100, validators: old)
    }

    @Test func weakMalformedAndDateOnlyValidatorsRemainConservative() {
        for tag in [nil, "W/\"same\"", "unquoted", "\"bad space\"", "\"bad\nvalue\"", "\"a\"b\""] as [String?] {
            let old = NativeRangeValidators(etag: tag, lastModified: "old")
            #expect(old.strongETag == nil)
            #expect(!old.accepts(.init(etag: tag, lastModified: "new")))
            #expect(old.accepts(.init(etag: tag, lastModified: "old")))
        }
    }

    @Test func terminalFailurePreparesWhileBufferStillPlaysAndRespectsCooldown() {
        var policy = PlaybackContinuityPolicy()
        func evaluate(_ time: Double, eligible: Bool = true) -> PlaybackContinuityPolicy.Reason? {
            policy.update(now: time, eligible: eligible, terminal: true, waiting: false,
                bufferedWallSeconds: 15, requiredBytesPerSecond: 300_000, transfer: .init())
        }
        #expect(evaluate(0, eligible: false) == nil)
        #expect(evaluate(1) == .terminal)
        #expect(evaluate(10) == nil)
        #expect(evaluate(21) == .terminal)
    }

    @Test func stalledPlaybackPreparesAfterThreeSecondsButBriefWaitsAndCacheHitsDoNotSwitch() {
        var policy = PlaybackContinuityPolicy()
        func evaluate(_ time: Double, waiting: Bool, active: Int = 0) -> PlaybackContinuityPolicy.Reason? {
            policy.update(now: time, eligible: true, terminal: false, waiting: waiting, bufferedWallSeconds: 1,
                requiredBytesPerSecond: 500_000, transfer: .init(bytesPerSecond: 10_000, completedRanges: 6, activeRanges: active))
        }
        #expect(evaluate(0, waiting: true) == nil)
        #expect(evaluate(1, waiting: false) == nil)
        #expect(evaluate(10, waiting: false) == nil)
        #expect(evaluate(11, waiting: true) == nil)
        #expect(evaluate(13.9, waiting: true) == nil)
        #expect(evaluate(14, waiting: true) == .stalled)
    }

    @Test func slowRouteNeedsSustainedMeasuredDeficitAndLowActualBuffer() {
        var policy = PlaybackContinuityPolicy()
        let slow = PlaybackTransferSnapshot(bytesPerSecond: 100_000, completedRanges: 4, activeRanges: 1)
        #expect(policy.update(now: 0, eligible: true, terminal: false, waiting: false,
            bufferedWallSeconds: 30, requiredBytesPerSecond: 300_000, transfer: slow) == nil)
        #expect(policy.update(now: 4, eligible: true, terminal: false, waiting: false,
            bufferedWallSeconds: 10, requiredBytesPerSecond: 300_000, transfer: slow) == nil)
        #expect(policy.update(now: 8, eligible: true, terminal: false, waiting: false,
            bufferedWallSeconds: 6, requiredBytesPerSecond: 300_000, transfer: slow) == .slow)
    }

    @Test func foregroundPressureExpiresAndCancellationReleasesBackgroundWaiter() async throws {
        let priority = PlaybackNetworkPriority(), owner = UUID()
        priority.update(owner: owner, constrained: true, now: 10)
        #expect(priority.isConstrained(now: 14))
        #expect(!priority.isConstrained(now: 15))
        priority.update(owner: owner, constrained: true)
        let task = Task { try await priority.waitForForeground() }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        priority.update(owner: owner, constrained: false)
        try await priority.waitForForeground()
    }

    @Test func readAheadScalesByRateAndTimeWithinMemoryAndDiskBudgets() {
        let mib = 1024 * 1024
        #expect(PlaybackReadAheadBudget.bytes(totalLength: 60 * mib, duration: 120, rate: 1,
            wallSeconds: 45, minimum: 16 * mib, maximum: 64 * mib) == Int(22.5 * Double(mib)))
        #expect(PlaybackReadAheadBudget.bytes(totalLength: 60 * mib, duration: 120, rate: 2,
            wallSeconds: 45, minimum: 16 * mib, maximum: 64 * mib) == 45 * mib)
        #expect(PlaybackReadAheadBudget.bytes(totalLength: 100 * mib, duration: 60, rate: 2,
            wallSeconds: 45, minimum: 16 * mib, maximum: 64 * mib) == 64 * mib)
        #expect(PlaybackReadAheadBudget.bytes(totalLength: mib, duration: nil, rate: 2,
            wallSeconds: 12, minimum: 2 * mib, maximum: 8 * mib) == mib)
    }

    @Test func cdnRankingUsesCompletedBytesAndExpiresFailurePenalties() {
        let ranking = NativeCDNPerformance()
        func source(_ host: String) -> NativeMediaSource {
            .init(url: URL(string: "https://\(host).fqnovelvod.com/movie.mp4")!, contentKey: nil, userAgent: "Test", codec: "h264", quality: "1080p")
        }
        let a = source("a"), b = source("b")
        ranking.record(host: a.url.host!, bytes: 524_288, seconds: 4, failed: false, now: 0)
        ranking.record(host: b.url.host!, bytes: 524_288, seconds: 0.5, failed: false, now: 0)
        #expect(ranking.ranked([a,b], now: 1).first?.url == b.url)
        ranking.record(host: b.url.host!, bytes: 0, seconds: 3, failed: true, now: 2)
        #expect(ranking.ranked([a,b], now: 3).first?.url == a.url)
        #expect(ranking.ranked([a,b], now: 130).first?.url == a.url)
    }
    @Test func durationHintReadsBothMovieHeaderVersionsAndRejectsTruncation() {
        func uint(_ value: UInt64, count: Int) -> Data {
            Data((0..<count).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        func box(_ type: String, _ payload: Data) -> Data {
            uint(UInt64(payload.count + 8), count: 4) + Data(type.utf8) + payload
        }
        for version in [0, 1] {
            let payload = Data([UInt8(version),0,0,0]) + Data(count: version == 0 ? 8 : 16)
                + uint(600, count: 4) + uint(36_000, count: version == 0 ? 4 : 8)
            let prefix = box("ftyp", Data(count: 8)) + box("moov", box("mvhd", payload))
            #expect(NativeMovieDuration.seconds(in: prefix) == 60)
            #expect(NativeMovieDuration.seconds(in: prefix.dropLast()) == nil)
        }
        #expect(NativeMovieDuration.seconds(in: Data()) == nil)
    }

}
