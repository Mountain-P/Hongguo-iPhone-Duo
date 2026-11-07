import Foundation
import Testing
@testable import HongguoCore

@Suite(.serialized)
struct NativeProgressiveDiskTests {
    private let chunk = 512 * 1024
    private func source(encrypted: Bool = false) -> NativeMediaSource {
        .init(url: URL(string: "https://unit.fqnovelvod.com/disk-fixture.mp4")!,
              contentKey: encrypted ? Data(repeating: 0x11, count: 16) : nil,
              userAgent: "Synthetic fixture", codec: "h264", quality: "1080p")
    }
    private func fixture(mebibytes: Int = 4, encrypted: Bool = false) -> StreamFixture {
        streamFixture(payload: Data(repeating: 0x55, count: mebibytes * 1024 * 1024),
                      iv: encrypted ? Data(repeating: 0x22, count: 16) : nil, samples: 1)
    }
    private func disk(limit: Int = 32 * 1024 * 1024) throws -> (URL, NativeChunkDiskCache) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hongguo.ProgressiveDisk.\(UUID())")
        return (directory, NativeChunkDiskCache(directory: directory, byteLimit: limit, freeSpaceProvider: { _ in Int64.max }))
    }

    @Test func rawReadAheadUsesDiskWithoutDecryptingAndDemandUsesThePrefetchedBytes() async throws {
        let fixture = fixture(encrypted: true), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(encrypted: true), fetcher: bytes, diskCache: disk)
        try await stream.prefetch(range: chunk..<(2 * chunk))
        #expect(await stream.decryptedChunkCount == 0)
        #expect(await disk.byteCount == chunk)
        let stored = await disk.lookup(streamID: stream.id, index: 1, expectedBytes: chunk)
        #expect(stored.data == fixture.data.subdata(in: chunk..<(2 * chunk)))
        let expected = try NativeMP4.decrypt(data: fixture.data, contentKey: Data(repeating: 0x11, count: 16), codec: "h264")
        let range = 600_000..<600_128
        #expect(try await stream.read(range: range) == expected.subdata(in: range))
        #expect(await stream.decryptedChunkCount == 1)
        #expect(await bytes.ranges == [0..<(256 * 1024), chunk..<(2 * chunk)])
    }

    @Test func dataEvictedBeyondEightMiBComesFromDiskWithoutAnotherRangeRequest() async throws {
        let fixture = fixture(mebibytes: 11), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        _ = try await stream.read(range: chunk..<(chunk + 16))
        try await wait { await stream.pendingDiskWriteCount == 0 }
        for index in 2...18 { _ = try await stream.read(range: (index * chunk)..<(index * chunk + 16)) }
        #expect(await bytes.ranges.count == 19)
        #expect(try await stream.read(range: chunk..<(chunk + 16)) == fixture.data.subdata(in: chunk..<(chunk + 16)))
        #expect(await bytes.ranges.count == 19)
        #expect(await stream.decryptedChunkCount == 19)
    }

    @Test func aDemandJoinsReadAheadAndCancellingOnlySpeculationKeepsOneTransferAndOneDecryption() async throws {
        let fixture = fixture(encrypted: true), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(encrypted: true), fetcher: bytes, diskCache: disk)
        await bytes.holdPayload()
        let ahead = Task { try await stream.prefetch(range: chunk..<(2 * chunk)) }
        try await wait { await bytes.pendingCount == 1 }
        let demand = Task { try await stream.read(range: 600_000..<600_128) }
        try await wait { await stream.pendingReaderCount == 2 }
        ahead.cancel()
        await #expect(throws: CancellationError.self) { try await ahead.value }
        #expect(await bytes.cancellations == 0)
        await bytes.release(start: chunk)
        let expected = try NativeMP4.decrypt(data: fixture.data, contentKey: Data(repeating: 0x11, count: 16), codec: "h264")
        #expect(try await demand.value == expected.subdata(in: 600_000..<600_128))
        #expect(await stream.decryptedChunkCount == 1)
        #expect(await bytes.ranges.count == 2)
    }

    @Test func anUncooperativeLateWorkerCannotStoreAfterEveryConsumerCancelled() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        await bytes.holdPayload(ignoringCancellation: true)
        let ahead = Task { try await stream.prefetch(range: chunk..<(2 * chunk)) }
        try await wait { await bytes.pendingCount == 1 }
        let demand = Task { try await stream.read(range: 600_000..<600_128) }
        try await wait { await stream.pendingReaderCount == 2 }
        ahead.cancel(); demand.cancel()
        await #expect(throws: CancellationError.self) { try await ahead.value }
        await #expect(throws: CancellationError.self) { try await demand.value }
        await bytes.release(start: chunk)
        try await wait { await stream.completedChunkFetchCount == 1 }
        #expect(await disk.byteCount == 0)
        #expect(await stream.decryptedChunkCount == 0)
        let stored = await disk.lookup(streamID: stream.id, index: 1, expectedBytes: chunk)
        #expect(stored.data == nil)
    }

    @Test func cancellingTheOldAheadLetsAnUnrelatedSeekCompleteWithoutWaitingForIt() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        await bytes.holdPayload()
        let ahead = Task { try await stream.prefetch(range: chunk..<(2 * chunk)) }
        try await wait { await bytes.pendingCount == 1 }
        let seek = Task { try await stream.read(range: (3 * chunk)..<(3 * chunk + 128)) }
        try await wait { await bytes.pendingCount == 2 }
        #expect(await bytes.maximumActive == 2)
        ahead.cancel()
        await #expect(throws: CancellationError.self) { try await ahead.value }
        try await wait { await bytes.cancellations == 1 }
        await bytes.release(start: 3 * chunk)
        #expect(try await seek.value == fixture.data.subdata(in: (3 * chunk)..<(3 * chunk + 128)))
        #expect(await stream.decryptedChunkCount == 1)
    }

    @Test func denialOrChangedSourceRemovesDiskAndStopsEvenPreviouslyCachedReads() async throws {
        for failure in [CatalogError.httpStatus(403), .unauthorized] {
            let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
            let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
            let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
            try await stream.prefetch(range: chunk..<(2 * chunk))
            await bytes.fail(with: failure)
            await #expect(throws: failure) { try await stream.read(range: (3 * chunk)..<(3 * chunk + 1)) }
            #expect(await disk.byteCount == 0)
            let requests = await bytes.ranges.count
            await #expect(throws: failure) { try await stream.read(range: 0..<16) }
            #expect(await bytes.ranges.count == requests)
        }
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        try await stream.prefetch(range: chunk..<(2 * chunk))
        await bytes.changeValidator()
        await #expect(throws: NativeProgressiveError.changedSource) { try await stream.read(range: (3 * chunk)..<(3 * chunk + 1)) }
        #expect(await disk.byteCount == 0)
    }

    @Test func aFailedStoreStopsTheSpeculativeRangeLoopButForegroundStillPlays() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(limit: 1); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        await #expect(throws: PlaybackPrefetchError.unsupported) { try await stream.prefetch(range: chunk..<(4 * chunk)) }
        #expect(await bytes.ranges.count == 2)
        #expect(await stream.decryptedChunkCount == 0)
        #expect(await disk.byteCount == 0)
        #expect(try await stream.read(range: (2 * chunk)..<(2 * chunk + 16)) == fixture.data.subdata(in: (2 * chunk)..<(2 * chunk + 16)))
        #expect(await bytes.ranges.count == 3)
    }

    @Test func noDiskStreamsDoNotSpeculativelyFetchOrDecrypt() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes)
        try await stream.prefetch(range: chunk..<(4 * chunk))
        #expect(await bytes.ranges.count == 1)
        #expect(await stream.decryptedChunkCount == 0)
    }

    @Test func diskChunksAreIsolatedBetweenExactStreamIdentities() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let one = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        let two = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        try await one.prefetch(range: chunk..<(2 * chunk))
        _ = try await two.read(range: chunk..<(chunk + 16))
        try await wait { await two.pendingDiskWriteCount == 0 }
        #expect(await bytes.ranges.filter { $0 == chunk..<(2 * chunk) }.count == 2)
        #expect(one.id != two.id)
        #expect(await disk.byteCount == 2 * chunk)
    }

    @Test func demandAndASecondUncachedRangeReturnWhileTheOptionalDiskWriteIsBlocked() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data), gate = ProgressiveDiskWriteGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hongguo.ProgressiveWriteGate.\(UUID())")
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let disk = NativeChunkDiskCache(directory: directory, freeSpaceProvider: { _ in gate.capacity() })
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        gate.arm()
        let returned = ProgressiveCompletionFlag()
        let demand = Task {
            let data = try await stream.read(range: 600_000..<600_128)
            returned.mark(); return data
        }
        try await wait { gate.entered }
        try await wait { returned.completed }
        #expect(try await demand.value == fixture.data.subdata(in: 600_000..<600_128))
        #expect(await stream.pendingDiskWriteCount == 1)
        #expect(try await stream.read(range: 600_001..<600_017) == fixture.data.subdata(in: 600_001..<600_017))
        let newReturned = ProgressiveCompletionFlag()
        let newDemand = Task {
            let range = (2 * chunk)..<(2 * chunk + 128)
            let data = try await stream.read(range: range)
            newReturned.mark(); return data
        }
        // This request begins only after the cache actor is actually blocked in
        // the first optional write, not while all lookups can still pass through.
        try await wait { newReturned.completed }
        #expect(try await newDemand.value == fixture.data.subdata(in: (2 * chunk)..<(2 * chunk + 128)))
        #expect(await bytes.ranges.count == 3)
        #expect(await stream.pendingDiskWriteCount == 1)
        gate.release()
        try await wait { await stream.pendingDiskWriteCount == 0 }
        #expect(await disk.byteCount == chunk)
    }

    @Test func terminalFailureCancelsAnOptionalWriteBeforeItCanCommitLate() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data), gate = ProgressiveDiskWriteGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hongguo.ProgressiveTerminalGate.\(UUID())")
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let disk = NativeChunkDiskCache(directory: directory, freeSpaceProvider: { _ in gate.capacity() })
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        await bytes.holdPayload(); gate.arm()
        let success = Task { try await stream.read(range: 600_000..<600_128) }
        let denied = Task { try await stream.read(range: (3 * chunk)..<(3 * chunk + 16)) }
        try await wait { await bytes.pendingCount == 2 }
        await bytes.release(start: chunk)
        _ = try await success.value
        try await wait { gate.entered }
        await bytes.release(start: 3 * chunk, error: CatalogError.httpStatus(403))
        // The terminal handler has synchronously revoked every flight before disk cleanup.
        try await wait { await stream.pendingReaderCount == 0 }
        gate.release()
        await #expect(throws: CatalogError.httpStatus(403)) { try await denied.value }
        try await wait { await stream.pendingDiskWriteCount == 0 }
        #expect(await disk.byteCount == 0)
        #expect(await disk.lookup(streamID: stream.id, index: 1, expectedBytes: chunk).data == nil)
    }

    @Test func demandJoiningAValidatedPrefetchDoesNotWaitForItsBlockedDiskCommit() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data), gate = ProgressiveDiskWriteGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hongguo.ProgressiveJoinGate.\(UUID())")
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let disk = NativeChunkDiskCache(directory: directory, freeSpaceProvider: { _ in gate.capacity() })
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        await bytes.holdPayload()
        let ahead = Task { try await stream.prefetch(range: chunk..<(2 * chunk)) }
        try await wait { await bytes.pendingCount == 1 }
        gate.arm(); await bytes.release(start: chunk)
        try await wait { gate.entered }
        let returned = ProgressiveCompletionFlag()
        let demand = Task {
            let data = try await stream.read(range: 600_000..<600_128)
            returned.mark(); return data
        }
        try await wait { returned.completed }
        #expect(try await demand.value == fixture.data.subdata(in: 600_000..<600_128))
        #expect(await stream.decryptedChunkCount == 1)
        #expect(await bytes.ranges.count == 2)
        gate.release(); try await ahead.value
    }

    @Test func optionalDiskWritesHaveAHardTwoChunkBoundAndNeverHoldBackMoreDemands() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data), gate = ProgressiveDiskWriteGate()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Hongguo.ProgressiveBoundGate.\(UUID())")
        defer { gate.release(); try? FileManager.default.removeItem(at: directory) }
        let disk = NativeChunkDiskCache(directory: directory, freeSpaceProvider: { _ in gate.capacity() })
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        await bytes.holdPayload(); gate.arm()
        let demands = (1...3).map { index in Task { try await stream.read(range: (index * chunk)..<(index * chunk + 16)) } }
        try await wait { await bytes.pendingCount == 3 }
        await bytes.release(start: chunk); _ = try await demands[0].value
        try await wait { gate.entered }
        await bytes.release(start: 2 * chunk); _ = try await demands[1].value
        await bytes.release(start: 3 * chunk); _ = try await demands[2].value
        #expect(await stream.pendingDiskWriteCount == 2)
        await #expect(throws: NativeMediaError.busy) { try await stream.prefetch(range: (4 * chunk)..<(5 * chunk)) }
        #expect(await bytes.ranges.count == 4)
        gate.release()
        try await wait { await stream.pendingDiskWriteCount == 0 }
        #expect(await disk.byteCount == 2 * chunk)
        // Temporary backpressure must not become the permanent storage-failure latch.
        let retry = Task { try await stream.prefetch(range: (4 * chunk)..<(5 * chunk)) }
        try await wait { await bytes.pendingCount == 1 }
        await bytes.release(start: 4 * chunk); try await retry.value
        #expect(await disk.byteCount == 3 * chunk)
    }

    @Test func actualWriteFailureLatchesAcrossRepeatedReadAheadCallsDespiteReportedFreeSpace() async throws {
        let fixture = fixture(), bytes = ControlledProgressiveBytes(fixture.data)
        let (directory, disk) = try disk(); defer { try? FileManager.default.removeItem(at: directory) }
        let stream = try await NativeProgressiveMedia().prepare(source: source(), fetcher: bytes, diskCache: disk)
        // The directory descriptor remains open, but no new file can be created in
        // the removed directory. This fails real I/O even with ample reported capacity.
        try FileManager.default.removeItem(at: directory)
        #expect(await disk.allowsPrefetch)
        for _ in 0..<3 {
            await #expect(throws: PlaybackPrefetchError.unsupported) { try await stream.prefetch(range: chunk..<(4 * chunk)) }
        }
        #expect(await bytes.ranges.count == 2)
        #expect(await stream.decryptedChunkCount == 0)
        #expect(try await stream.read(range: (2 * chunk)..<(2 * chunk + 16)) == fixture.data.subdata(in: (2 * chunk)..<(2 * chunk + 16)))
    }

    private func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("The controlled range worker did not enter its barrier")
        throw CancellationError()
    }
}

private actor ControlledProgressiveBytes: NativeRangeFetching {
    let bytes: Data
    private(set) var ranges: [Range<Int>] = []
    private(set) var cancellations = 0
    private(set) var maximumActive = 0
    private var pending: [UUID: (range: Range<Int>, continuation: CheckedContinuation<NativeRangeResponse, any Error>)] = [:]
    private var hold = false, ignoresCancellation = false
    private var failure: (any Error)?
    private var changed = false
    var pendingCount: Int { pending.count }
    init(_ bytes: Data) { self.bytes = bytes }
    func holdPayload(ignoringCancellation: Bool = false) { hold = true; ignoresCancellation = ignoringCancellation }
    func fail(with error: any Error) { failure = error }
    func changeValidator() { changed = true }
    func fetch(range: Range<Int>) async throws -> NativeRangeResponse {
        ranges.append(range)
        if let failure { throw failure }
        guard hold, range.lowerBound >= 512 * 1024 else { return response(range) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NativeRangeResponse, any Error>) in
                pending[id] = (range, continuation)
                maximumActive = max(maximumActive, pending.count)
                if Task.isCancelled, !ignoresCancellation { cancel(id) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) {
        guard !ignoresCancellation, let operation = pending.removeValue(forKey: id) else { return }
        cancellations += 1; operation.continuation.resume(throwing: CancellationError())
    }
    func release(start: Int, error: (any Error)? = nil) {
        guard let id = pending.first(where: { $0.value.range.lowerBound == start })?.key,
              let operation = pending.removeValue(forKey: id) else { return }
        if let error { operation.continuation.resume(throwing: error) }
        else { operation.continuation.resume(returning: response(operation.range)) }
    }
    private func response(_ range: Range<Int>) -> NativeRangeResponse {
        let actual = range.lowerBound..<min(range.upperBound, bytes.count)
        return .init(data: bytes.subdata(in: actual), range: actual, totalLength: bytes.count,
                     validators: .init(etag: changed ? "changed" : "synthetic"))
    }
}

private final class ProgressiveCompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var completed: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

private final class ProgressiveDiskWriteGate: @unchecked Sendable {
    private let lock = NSLock(), semaphore = DispatchSemaphore(value: 0)
    private var armed = false, blocked = false
    var entered: Bool { lock.withLock { blocked } }
    func arm() { lock.withLock { armed = true; blocked = false } }
    func release() { semaphore.signal() }
    func capacity() -> Int64 {
        let block = lock.withLock { () -> Bool in
            guard armed else { return false }
            armed = false; blocked = true; return true
        }
        if block { semaphore.wait() }
        return Int64.max
    }
}
