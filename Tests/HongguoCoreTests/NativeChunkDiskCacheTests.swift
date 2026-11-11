// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

@Suite("Raw chunk disk cache")
struct NativeChunkDiskCacheTests {
    private struct Fixture: Sendable {
        let root: URL
        let directory: URL
        let cache: NativeChunkDiskCache

        init(byteLimit: Int = NativeChunkDiskCache.maximumBytes,
             freeSpaceProvider: @escaping @Sendable (URL) -> Int64? = { _ in Int64.max }) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-cache-tests-\(UUID())", isDirectory: true)
            directory = root.appendingPathComponent("chunks", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            cache = NativeChunkDiskCache(directory: directory, byteLimit: byteLimit, freeSpaceProvider: freeSpaceProvider)
        }

        func file(_ streamID: UUID, index: Int = 0) -> URL {
            directory.appendingPathComponent("\(streamID.uuidString.lowercased())-\(index)")
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func diskBytes() throws -> Int {
            try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
                .reduce(0) { try $0 + $1.resourceValues(forKeys: [.fileSizeKey]).fileSize! }
        }
    }

    private final class Capacity: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64?
        init(_ value: Int64?) { self.value = value }
        func get() -> Int64? { lock.withLock { value } }
        func set(_ next: Int64?) { lock.withLock { value = next } }
    }

    @Test func rawBytesRoundTripWithOnlyOpaqueChunkNamesAndNoSidecars() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID(), raw = Data([0, 255, 28, 0, 117, 93])
        let first = await fixture.cache.lookup(streamID: id, index: 7, expectedBytes: raw.count)
        #expect(first.data == nil)
        await fixture.cache.store(raw, streamID: id, index: 7, generation: first.generation)
        let hit = await fixture.cache.lookup(streamID: id, index: 7, expectedBytes: raw.count)
        #expect(hit.data == raw)
        #expect(hit.generation == first.generation)
        #expect(await fixture.cache.byteCount == raw.count)
        #expect(try Data(contentsOf: fixture.file(id, index: 7)) == raw)
        let names = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        #expect(names == ["\(id.uuidString.lowercased())-7"])
        #expect(try fixture.diskBytes() == raw.count)
    }

    @Test func evictionUsesReadRecencyAndEnforcesPhysicalByteLimit() async throws {
        let fixture = try Fixture(byteLimit: 12); defer { fixture.cleanup() }
        let id = UUID(), raw = Data(repeating: 9, count: 4)
        let generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 4).generation
        for index in 0..<3 { await fixture.cache.store(raw, streamID: id, index: index, generation: generation) }
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 4).data == raw)
        await fixture.cache.store(raw, streamID: id, index: 3, generation: generation)
        #expect(await fixture.cache.lookup(streamID: id, index: 1, expectedBytes: 4).data == nil)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 4).data == raw)
        #expect(await fixture.cache.lookup(streamID: id, index: 2, expectedBytes: 4).data == raw)
        for index in 4..<40 {
            await fixture.cache.store(raw, streamID: id, index: index, generation: generation)
            #expect(await fixture.cache.byteCount <= 12)
            #expect(try fixture.diskBytes() <= 12)
        }
        #expect(await fixture.cache.byteCount == 12)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 3)
    }

    @Test func replacingAChunkReconcilesByteAccountingWithoutTemporaryFiles() async throws {
        let fixture = try Fixture(byteLimit: 8); defer { fixture.cleanup() }
        let id = UUID()
        let generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 8).generation
        await fixture.cache.store(Data(repeating: 1, count: 8), streamID: id, index: 0, generation: generation)
        let replacement = Data([8, 7, 6])
        await fixture.cache.store(replacement, streamID: id, index: 0, generation: generation)
        #expect(await fixture.cache.byteCount == 3)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 3).data == replacement)
        #expect(try fixture.diskBytes() == 3)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).count == 1)
    }

    @Test func maximumChunkBoundaryAndInvalidInputsNeverCreateFiles() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID(), limit = NativeChunkDiskCache.maximumChunkBytes
        #expect(NativeChunkDiskCache.maximumBytes == 512 * 1024 * 1024)
        #expect(limit == 512 * 1024)
        let generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: limit).generation
        await fixture.cache.store(Data(), streamID: id, index: 0, generation: generation)
        await fixture.cache.store(Data([1]), streamID: id, index: -1, generation: generation)
        await fixture.cache.store(Data(repeating: 4, count: limit + 1), streamID: id, index: 0, generation: generation)
        #expect(await fixture.cache.byteCount == 0)
        #expect(try fixture.diskBytes() == 0)
        let raw = Data(repeating: 0xAA, count: limit)
        await fixture.cache.store(raw, streamID: id, index: 0, generation: generation)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: limit).data == raw)
        #expect(await fixture.cache.lookup(streamID: id, index: -1, expectedBytes: limit).data == nil)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 0).data == nil)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: limit + 1).data == nil)
        #expect(await fixture.cache.byteCount == limit)
    }

    @Test func streamUUIDAndExpectedLengthArePartOfTheLookupBoundary() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = UUID(), b = UUID(), dataA = Data([1, 2]), dataB = Data([8, 9])
        let generation = await fixture.cache.lookup(streamID: a, index: 0, expectedBytes: 2).generation
        await fixture.cache.store(dataA, streamID: a, index: 0, generation: generation)
        await fixture.cache.store(dataB, streamID: b, index: 0, generation: generation)
        #expect(await fixture.cache.lookup(streamID: a, index: 0, expectedBytes: 2).data == dataA)
        #expect(await fixture.cache.lookup(streamID: b, index: 0, expectedBytes: 2).data == dataB)
        #expect(await fixture.cache.lookup(streamID: a, index: 0, expectedBytes: 1).data == nil)
        #expect(await fixture.cache.lookup(streamID: b, index: 0, expectedBytes: 2).data == dataB)
        #expect(await fixture.cache.byteCount == 2)
    }

    @Test func corruptionTruncationGrowthAndMissingFilesBecomeMisses() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID(), raw = Data([1, 2, 3, 4])
        let generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 4).generation
        for index in 0..<4 {
            await fixture.cache.store(raw, streamID: id, index: index, generation: generation)
            let file = fixture.file(id, index: index)
            switch index {
            case 0: try Data([4, 3, 2, 1]).write(to: file)
            case 1: try Data([1, 2]).write(to: file)
            case 2: try Data([1, 2, 3, 4, 5]).write(to: file)
            default: try FileManager.default.removeItem(at: file)
            }
            #expect(await fixture.cache.lookup(streamID: id, index: index, expectedBytes: 4).data == nil)
            #expect(await fixture.cache.byteCount == 0)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func symlinksAndHardLinksAreNotReadOrFollowed() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID(), raw = Data([1, 2, 3, 4])
        let outside = fixture.root.appendingPathComponent("outside")
        try raw.write(to: outside)
        let generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 4).generation
        for index in 0..<2 {
            await fixture.cache.store(raw, streamID: id, index: index, generation: generation)
            let file = fixture.file(id, index: index)
            try FileManager.default.removeItem(at: file)
            if index == 0 { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside) }
            else { try FileManager.default.linkItem(at: outside, to: file) }
            #expect(await fixture.cache.lookup(streamID: id, index: index, expectedBytes: 4).data == nil)
            #expect(try Data(contentsOf: outside) == raw)
            #expect(await fixture.cache.byteCount == 0)
        }
    }

    @Test func aNewCacheRemovesOnlyLegalOldChunksWithoutFollowingLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-init-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("chunks"), id = UUID()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let old = directory.appendingPathComponent("\(id.uuidString.lowercased())-0")
        let link = directory.appendingPathComponent("\(UUID().uuidString.lowercased())-2")
        let unrelated = directory.appendingPathComponent("unrelated.txt"), outside = root.appendingPathComponent("outside")
        let unicodeName = String(repeating: "影", count: 14)
        try Data([8]).write(to: old)
        try Data([4]).write(to: unrelated)
        try Data([5]).write(to: directory.appendingPathComponent(unicodeName))
        try Data([7]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let cache = NativeChunkDiskCache(directory: directory, freeSpaceProvider: { _ in Int64.max })
        #expect(await cache.lookup(streamID: id, index: 0, expectedBytes: 1).data == nil)
        #expect(await cache.byteCount == 0)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["unrelated.txt", unicodeName])
        #expect(try Data(contentsOf: outside) == Data([7]))
    }

    @Test func symlinkOrFileAsCacheDirectoryFailsClosed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chunk-directory-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside"), link = root.appendingPathComponent("linked")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let file = root.appendingPathComponent("file")
        try Data([7]).write(to: file)
        for directory in [link, file] {
            let cache = NativeChunkDiskCache(directory: directory, freeSpaceProvider: { _ in Int64.max })
            let id = UUID(), generation = await cache.lookup(streamID: id, index: 0, expectedBytes: 1).generation
            await cache.store(Data([1]), streamID: id, index: 0, generation: generation)
            #expect(await cache.lookup(streamID: id, index: 0, expectedBytes: 1).data == nil)
            #expect(await cache.byteCount == 0)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try Data(contentsOf: file) == Data([7]))
    }

    @Test func lowOrUnknownFreeSpaceDisablesWritesButPreservesExistingReads() async throws {
        let capacity = Capacity(NativeChunkDiskCache.minimumFreeBytes - 1)
        let fixture = try Fixture(freeSpaceProvider: { _ in capacity.get() }); defer { fixture.cleanup() }
        let id = UUID(), raw = Data([2, 4, 6])
        let generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 3).generation
        #expect(await fixture.cache.store(raw, streamID: id, index: 0, generation: generation) == false)
        #expect(await fixture.cache.allowsPrefetch == false)
        #expect(await fixture.cache.byteCount == 0)
        capacity.set(NativeChunkDiskCache.minimumFreeBytes)
        #expect(await fixture.cache.allowsPrefetch)
        #expect(await fixture.cache.store(raw, streamID: id, index: 0, generation: generation))
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 3).data == raw)
        capacity.set(NativeChunkDiskCache.minimumFreeBytes - 1)
        #expect(await fixture.cache.allowsPrefetch == false)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 3).data == raw)
        capacity.set(nil)
        #expect(await fixture.cache.allowsPrefetch == false)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 3).data == raw)
        #expect(await fixture.cache.store(raw, streamID: id, index: 1, generation: generation) == false)
        #expect(await fixture.cache.byteCount == 3)
        capacity.set(Int64.max)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 3).data == raw)
        #expect(await fixture.cache.lookup(streamID: id, index: 1, expectedBytes: 3).data == nil)
    }

    @Test func IOFailureAfterInitializationRemainsAMiss() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID(), generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 2).generation
        try FileManager.default.removeItem(at: fixture.directory)
        #expect(await fixture.cache.store(Data([1, 2]), streamID: id, index: 0, generation: generation) == false)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 2).data == nil)
        #expect(await fixture.cache.byteCount == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func removeAndClearRejectLateWritersWhilePreservingOtherStreams() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let a = UUID(), b = UUID(), raw = Data([5, 6])
        let old = await fixture.cache.lookup(streamID: a, index: 0, expectedBytes: 2).generation
        await fixture.cache.store(raw, streamID: a, index: 0, generation: old)
        await fixture.cache.store(raw, streamID: b, index: 0, generation: old)
        await fixture.cache.remove(streamID: a)
        let next = await fixture.cache.lookup(streamID: a, index: 0, expectedBytes: 2)
        #expect(next.data == nil)
        #expect(next.generation != old)
        #expect(await fixture.cache.lookup(streamID: b, index: 0, expectedBytes: 2).data == raw)
        await fixture.cache.store(raw, streamID: a, index: 0, generation: old)
        await fixture.cache.store(raw, streamID: b, index: 1, generation: old)
        #expect(await fixture.cache.byteCount == 2)
        await fixture.cache.store(raw, streamID: a, index: 0, generation: next.generation)
        #expect(await fixture.cache.byteCount == 4)
        await fixture.cache.clear()
        let cleared = await fixture.cache.lookup(streamID: a, index: 0, expectedBytes: 2)
        #expect(cleared.generation != next.generation)
        await fixture.cache.store(raw, streamID: a, index: 0, generation: next.generation)
        #expect(await fixture.cache.byteCount == 0)
        #expect(try fixture.diskBytes() == 0)
        await fixture.cache.store(raw, streamID: a, index: 0, generation: cleared.generation)
        #expect(await fixture.cache.lookup(streamID: a, index: 0, expectedBytes: 2).data == raw)
    }

    @Test func alreadyCancelledTasksCannotReadOrCommitChunks() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let id = UUID(), raw = Data([3, 5])
        let generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 2).generation
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await fixture.cache.store(raw, streamID: id, index: 0, generation: generation)
        }.value
        #expect(await fixture.cache.byteCount == 0)
        await fixture.cache.store(raw, streamID: id, index: 0, generation: generation)
        let cancelledRead = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 2)
        }.value
        #expect(cancelledRead.data == nil)
        #expect(await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 2).data == raw)
    }

    @Test func zeroBudgetCannotCreateAnyChunk() async throws {
        let fixture = try Fixture(byteLimit: 0); defer { fixture.cleanup() }
        let id = UUID(), generation = await fixture.cache.lookup(streamID: id, index: 0, expectedBytes: 1).generation
        await fixture.cache.store(Data([1]), streamID: id, index: 0, generation: generation)
        #expect(await fixture.cache.byteCount == 0)
        #expect(try fixture.diskBytes() == 0)
    }
}
