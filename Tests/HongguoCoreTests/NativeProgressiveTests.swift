// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private actor ProgressiveBytes: NativeRangeFetching {
    let bytes: Data
    var ranges: [Range<Int>] = []
    var changeAfter: Int?
    var delay = false
    var cancellations = 0
    var failure: (any Error)?
    init(_ bytes: Data) { self.bytes = bytes }
    func setChanged() { changeAfter = ranges.count }
    func setDelay() { delay = true }
    func setFailure(_ error: any Error) { failure = error }
    func fetch(range: Range<Int>) async throws -> NativeRangeResponse {
        ranges.append(range)
        if delay {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { cancellations += 1; throw error }
        }
        try Task.checkCancellation()
        if let failure { throw failure }
        let actual = range.lowerBound..<min(bytes.count, range.upperBound)
        return NativeRangeResponse(data: bytes.subdata(in: actual), range: actual, totalLength: bytes.count,
            validators: .init(etag: changeAfter.map { ranges.count > $0 } == true ? "changed" : "fixture"))
    }
}

struct NativeProgressiveTests {
    private func source(key: Data? = nil) -> NativeMediaSource {
        .init(url: URL(string: "https://unit.fqnovelvod.com/video.mp4")!, contentKey: key, userAgent: "Fixture", codec: "h264", quality: "1080p")
    }

    @Test func preparationFetchesOnlyPrefixAndFirstReadsUseThatPrefix() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x55, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        #expect(await bytes.ranges == [0..<(256 * 1024)])
        #expect(stream.totalLength == fixture.data.count)
        #expect(stream.assetURL.scheme == "hongguo-native")
        #expect(try await stream.read(range: 0..<1024) == fixture.data.prefix(1024))
        #expect(await bytes.ranges.count == 1)
        let offset = 700_000
        #expect(try await stream.read(range: offset..<(offset + 127)) == fixture.data.subdata(in: offset..<(offset + 127)))
        #expect(await bytes.ranges.count == 2)
        _ = try await stream.read(range: offset..<(offset + 20))
        #expect(await bytes.ranges.count == 2)
    }

    @Test func largeMoovIsSupplementedAndEOFIsClampedDuringPreparation() async throws {
        var size = UInt32(300_008).bigEndian
        let padding = withUnsafeBytes(of: &size) { Data($0) } + Data("free".utf8) + Data(count: 300_000)
        let fixture = streamFixture(payload: Data(repeating: 7, count: 400_000), samples: 1, extraTable: padding)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        #expect(await bytes.ranges.count == 2)
        #expect(await bytes.ranges[1].lowerBound == 256 * 1024)
        #expect(try await stream.read(range: 0..<300_100) == fixture.data.prefix(300_100))
        let small = streamFixture(payload: Data([1, 2, 3]), samples: 1)
        let tiny = try await NativeProgressiveMedia().prepare(source: source(), fetcher: ProgressiveBytes(small.data))
        #expect(tiny.totalLength == small.data.count)
        #expect(try await tiny.read(range: 0..<small.data.count) == small.data)
        #expect(try await tiny.read(range: small.data.count..<small.data.count).isEmpty)
    }

    @Test func requestedChunksMatchWholeCENCDecryption() async throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c"), iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let ciphertext = hex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")
        let fixture = streamFixture(payload: ciphertext, iv: iv, samples: 3, external: true)
        let stream = try await NativeProgressiveMedia().prepare(source: source(key: key), fetcher: ProgressiveBytes(fixture.data))
        let whole = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
        for range in [0..<17, 13..<fixture.data.count, fixture.media[1]] {
            #expect(try await stream.read(range: range) == whole.subdata(in: range))
        }
    }

    @Test func externalAuxiliaryBytesAreFetchedWithoutDownloadingTheMedia() async throws {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c"), iv = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let ciphertext = hex("874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff")
        var size = UInt32(300_008).bigEndian
        let padding = withUnsafeBytes(of: &size) { Data($0) } + Data("free".utf8) + Data(count: 300_000)
        let fixture = streamFixture(payload: ciphertext, iv: iv, samples: 3, external: true, extraTable: padding)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(key: key), fetcher: bytes)
        let ranges = await bytes.ranges
        let auxiliary = try #require(fixture.auxiliary)
        #expect(ranges.count >= 3)
        #expect(ranges.dropFirst(2).allSatisfy { $0.lowerBound >= auxiliary.lowerBound && $0.upperBound <= auxiliary.upperBound })
        #expect(ranges.last?.upperBound == auxiliary.upperBound)
        #expect(ranges.allSatisfy { $0.upperBound <= auxiliary.upperBound })
        let whole = try NativeMP4.decrypt(data: fixture.data, contentKey: key, codec: "h264")
        #expect(try await stream.read(range: fixture.media[1]) == whole.subdata(in: fixture.media[1]))
    }

    @Test func chunkCacheEvictsLeastRecentlyUsedDataAndRejectsChangedObject() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x55, count: 11 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        for index in 1...18 { _ = try await stream.read(range: (index * 524_288)..<(index * 524_288 + 16)) }
        #expect(await bytes.ranges.count == 19)
        _ = try await stream.read(range: 524_288..<(524_288 + 16))
        #expect(await bytes.ranges.count == 20)
        await bytes.setChanged()
        await #expect(throws: NativeProgressiveError.changedSource) { try await stream.read(range: 10_000_000..<10_000_001) }
        let count = await bytes.ranges.count
        await #expect(throws: NativeProgressiveError.changedSource) { try await stream.read(range: 600_000..<600_001) }
        #expect(await bytes.ranges.count == count)
    }

    @Test func cancellationOfOneReadDoesNotCancelAnotherRead() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x22, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        await bytes.setDelay()
        let cancelled = Task { try await stream.read(range: 600_000..<600_020) }
        let retained = Task { try await stream.read(range: 1_200_000..<1_200_020) }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await retained.value == fixture.data.subdata(in: 1_200_000..<1_200_020))
    }

    @Test func overlappingReadsShareOneChunkAndOneCancelledWaiterDoesNotCancelIt() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x31, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        await bytes.setDelay()
        let cancelled = Task { try await stream.read(range: 600_000..<600_020) }
        let retained = Task { try await stream.read(range: 600_010..<600_040) }
        try await waitForReaders(2, in: stream)
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await retained.value == fixture.data.subdata(in: 600_010..<600_040))
        #expect(await bytes.ranges == [0..<(256 * 1024), 524_288..<1_048_576])
        #expect(await bytes.cancellations == 0)
    }

    @Test func cancellingEveryWaiterCancelsTheSharedFetchAndAllowsAnotherRead() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x32, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        await bytes.setDelay()
        let first = Task { try await stream.read(range: 600_000..<600_020) }
        let second = Task { try await stream.read(range: 600_010..<600_040) }
        try await waitForReaders(2, in: stream)
        first.cancel(); second.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        for _ in 0..<100 {
            if await bytes.cancellations > 0 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await bytes.cancellations == 1)
        #expect(try await stream.read(range: 600_000..<600_020) == fixture.data.subdata(in: 600_000..<600_020))
        #expect(await bytes.ranges.count == 3)
    }

    @Test func reusablePrefixHonorsLRUTTLFreshAndClear() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x33, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let clock = ProgressiveClock()
        let media = NativeProgressiveMedia(now: { clock.now }, makeFetcher: { _ in bytes })
        let first = try await media.prepare(source: source(), episodeID: "1")
        #expect(try await media.prepare(source: source(), episodeID: "1") == first)
        #expect(await bytes.ranges.count == 1)
        _ = try await media.prepare(source: source(), episodeID: "2")
        _ = try await media.prepare(source: source(), episodeID: "3")
        #expect(await media.reusableEntryCount == 2)
        let evicted = try await media.prepare(source: source(), episodeID: "1")
        #expect(evicted != first)
        let fresh = try await media.prepare(source: source(), episodeID: "1", fresh: true)
        #expect(fresh != evicted)
        clock.advance(31)
        let expired = try await media.prepare(source: source(), episodeID: "1")
        #expect(expired != fresh)
        await media.clearReusableCache()
        #expect(await media.reusableEntryCount == 0)
        #expect(try await media.prepare(source: source(), episodeID: "1") != expired)
        #expect(await bytes.ranges.count == 7)
    }

    @Test func reusablePrefixSeparatesQualityPoliciesWhenTheirExactMediaVariantMatches() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x32, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let media = NativeProgressiveMedia(makeFetcher: { _ in bytes })
        let automatic = source()
        let saverFallback = NativeMediaSource(url: automatic.url, contentKey: automatic.contentKey,
            userAgent: automatic.userAgent, codec: automatic.codec, quality: automatic.quality,
            preference: .dataSaver, qualityFallback: true)
        let first = try await media.prepare(source: automatic, episodeID: "1")
        let second = try await media.prepare(source: saverFallback, episodeID: "1")
        #expect(first != second)
        #expect(first.variant.preference == .automatic)
        #expect(second.variant.preference == .dataSaver)
        #expect(second.variant.quality == first.variant.quality)
        #expect(second.variant.qualityFallback)
        #expect(try await media.prepare(source: automatic, episodeID: "1") == first)
        #expect(try await media.prepare(source: saverFallback, episodeID: "1") == second)
        #expect(await bytes.ranges.count == 2)
        #expect(await media.reusableEntryCount == 2)
    }

    @Test func preparationBudgetStopsBeforeFetchingAnOversizedIndex() async throws {
        var size = UInt32(1_100_008).bigEndian
        let padding = withUnsafeBytes(of: &size) { Data($0) } + Data("free".utf8) + Data(count: 1_100_000)
        let fixture = streamFixture(payload: Data(repeating: 0x34, count: 2 * 1024 * 1024), samples: 1, extraTable: padding)
        let bytes = ProgressiveBytes(fixture.data)
        await #expect(throws: PlaybackPrefetchError.budgetExceeded) {
            try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes,
                byteLimit: NativePlaybackPrefetch.maximumPreparationBytes)
        }
        #expect(await bytes.ranges == [0..<(256 * 1024)])
    }

    @Test func deniedOrChangedStreamsAreNotReused() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x35, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let media = NativeProgressiveMedia(makeFetcher: { _ in bytes })
        let original = try await media.prepare(source: source(), episodeID: "1")
        await bytes.setChanged()
        await #expect(throws: NativeProgressiveError.changedSource) { try await original.read(range: 600_000..<600_020) }
        let replacement = try await media.prepare(source: source(), episodeID: "1")
        #expect(replacement != original)
        #expect(await bytes.ranges.count == 3)
    }

    @Test func reusablePreparationIsBoundToTheExactSourceAndOversizedHeadersAreNotRetained() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x36, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let media = NativeProgressiveMedia(makeFetcher: { _ in bytes })
        let first = try await media.prepare(source: source(), episodeID: "1")
        let other = NativeMediaSource(url: URL(string: "https://unit.fqnovelvod.com/other.mp4")!, contentKey: nil,
                                      userAgent: "Fixture", codec: "h264", quality: "1080p")
        #expect(try await media.prepare(source: other, episodeID: "1") != first)
        #expect(await bytes.ranges.count == 2)
        await media.clearReusableCache()
        #expect(try await first.read(range: 0..<100) == fixture.data.prefix(100))

        var size = UInt32(2_200_008).bigEndian
        let padding = withUnsafeBytes(of: &size) { Data($0) } + Data("free".utf8) + Data(count: 2_200_000)
        let large = streamFixture(payload: Data(repeating: 0x37, count: 3 * 1024 * 1024), samples: 1, extraTable: padding)
        let largeBytes = ProgressiveBytes(large.data)
        let limited = NativeProgressiveMedia(makeFetcher: { _ in largeBytes })
        let stream = try await limited.prepare(source: source(), episodeID: "1")
        #expect(stream.preparationByteCount > NativeProgressiveMedia.maximumReusablePreparationBytes)
        #expect(await limited.reusableEntryCount == 0)
    }

    @Test func validatorFailureFailsEveryPendingChunkAndPreventsFurtherPrefixReads() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x38, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        await bytes.setChanged(); await bytes.setDelay()
        let first = Task { try await stream.read(range: 600_000..<600_020) }
        let second = Task { try await stream.read(range: 1_200_000..<1_200_020) }
        await #expect(throws: NativeProgressiveError.changedSource) { try await first.value }
        await #expect(throws: NativeProgressiveError.changedSource) { try await second.value }
        await #expect(throws: NativeProgressiveError.changedSource) { try await stream.read(range: 0..<100) }
    }

    @Test func authorizationDenialEvictsReusableStreamAndUnsupportedRangesStopCachedReads() async throws {
        let fixture = streamFixture(payload: Data(repeating: 0x39, count: 2 * 1024 * 1024), samples: 1)
        let bytes = ProgressiveBytes(fixture.data)
        let media = NativeProgressiveMedia(makeFetcher: { _ in bytes })
        let stream = try await media.prepare(source: source(), episodeID: "1")
        await bytes.setFailure(CatalogError.httpStatus(403))
        await #expect(throws: CatalogError.httpStatus(403)) { try await stream.read(range: 600_000..<600_020) }
        await #expect(throws: CatalogError.httpStatus(403)) { try await media.prepare(source: source(), episodeID: "1") }
        #expect(await media.reusableEntryCount == 0)
        #expect(await bytes.ranges.count == 3)

        let unsupported = ProgressiveBytes(fixture.data)
        let other = try await NativeProgressiveMedia().prepare(source: source(), fetcher: unsupported)
        await unsupported.setFailure(NativeProgressiveError.unsupportedRange)
        await #expect(throws: NativeProgressiveError.unsupportedRange) { try await other.read(range: 600_000..<600_020) }
        await #expect(throws: NativeProgressiveError.unsupportedRange) { try await other.read(range: 0..<100) }
    }

    @Test func rangeHeadersRejectIgnoredRangesMismatchesAndDenialBeforeBody() throws {
        func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: source().url, statusCode: status, httpVersion: nil, headerFields: headers)!
        }
        let correct = ["Content-Range": "bytes 0-15/100", "Content-Length": "16", "ETag": "one"]
        let parsed = try NativeRangeHeaders.parse(response(206, correct), requested: 0..<16, knownTotal: nil, validators: nil)
        #expect(parsed.range == 0..<16)
        #expect(throws: NativeProgressiveError.unsupportedRange) { try NativeRangeHeaders.parse(response(200, correct), requested: 0..<16, knownTotal: nil, validators: nil) }
        #expect(throws: CatalogError.httpStatus(403)) { try NativeRangeHeaders.parse(response(403, ["Content-Type": "application/json", "Content-Length": "999999999"]), requested: 0..<16, knownTotal: nil, validators: nil) }
        #expect(throws: NativeProgressiveError.changedSource) { try NativeRangeHeaders.parse(response(206, correct), requested: 0..<16, knownTotal: 101, validators: nil) }
        #expect(throws: NativeProgressiveError.changedSource) { try NativeRangeHeaders.parse(response(206, correct), requested: 0..<16, knownTotal: 100, validators: .init(etag: "other")) }
        for header in ["bytes 1-16/100", "bytes 0-14/100", "bytes 0-15/*", "bytes 0-15/0", "bytes 0-15/99999999999999999999999999999"] {
            #expect(throws: NativeProgressiveError.invalidRange) { try NativeRangeHeaders.parse(response(206, ["Content-Range": header]), requested: 0..<16, knownTotal: nil, validators: nil) }
        }
    }

    private func hex(_ value: String) -> Data {
        Data(stride(from: 0, to: value.count, by: 2).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            return UInt8(value[start..<value.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    private func waitForReaders(_ count: Int, in stream: NativeMediaStream) async throws {
        for _ in 0..<500 {
            if await stream.pendingReaderCount >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await stream.pendingReaderCount >= count)
    }
}

private final class ProgressiveClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
