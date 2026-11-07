import Foundation
import Testing
@testable import HongguoCore

struct LibrarySnapshotStoreTests {
    private let scope = LibraryScope(owner: .account(id: "42"), sourceID: "native")

    @Test func blockedDiskCoalescesProgressAndOlderRevisionsCannotOverwriteNewerData() async throws {
        let io = SnapshotIOProbe(blockFirstSave: true), store = LibrarySnapshotStore(io: io)
        let first = Task { try await store.save(state(seconds: 1), revision: 1) }
        await io.waitForCalls(1)
        let tasks = (2...20).map { revision in
            Task { try await store.save(state(seconds: Double(revision)), revision: UInt64(revision)) }
        }
        while await store.latestRequestedRevision(for: scope) < 20 { await Task.yield() }
        await io.release()
        try await first.value
        for task in tasks { try await task.value }
        try await store.save(state(seconds: 2), revision: 2)
        let saved = await io.values()
        #expect(saved.count == 2)
        #expect(saved.first?.history.first?.seconds == 1)
        #expect(saved.last?.history.first?.seconds == 20)
        #expect(await io.ranOnMainThread() == false)
    }

    @Test func durabilityBarrierCannotReleaseACloudWriteBeforeRetryGateReachedStorage() async throws {
        let io = SnapshotIOProbe(blockFirstSave: true), store = LibrarySnapshotStore(io: io), sent = SnapshotCounter()
        var marked = try state(seconds: 10)
        let mutation = marked.pendingProgress[0]
        let didMark = marked.markProgressAttempt(operationID: mutation.operationID)
        #expect(didMark)
        let snapshot = marked
        let write = Task {
            try await store.save(snapshot, revision: 1)
            await sent.increment()
        }
        await io.waitForCalls(1)
        #expect(await sent.value == 0)
        await io.release()
        try await write.value
        #expect(await sent.value == 1)
        #expect(await io.values().last?.retryRequiredCount == 1)
    }

    @Test func failedDurabilityBarrierDoesNotSendAndCanBeExplicitlyFlushedAgain() async throws {
        let io = SnapshotIOProbe(blockFirstSave: false, failures: 1), store = LibrarySnapshotStore(io: io), sent = SnapshotCounter()
        let snapshot = try state(seconds: 10)
        let write = Task {
            try await store.save(snapshot, revision: 1)
            await sent.increment()
        }
        if case .success = await write.result { Issue.record("The injected disk failure must fail the write barrier") }
        #expect(await sent.value == 0)
        #expect(await io.values().isEmpty)
        try await store.save(snapshot, revision: 1)
        #expect(await io.values().last == snapshot)
    }

    @Test func scopeIsolationAndConflictingSameRevisionAreEnforced() async throws {
        let io = SnapshotIOProbe(blockFirstSave: false), store = LibrarySnapshotStore(io: io)
        let first = try state(seconds: 10)
        try await store.save(first, revision: 1)
        await #expect(throws: LibraryStorageError.revisionConflict) { try await store.save(state(seconds: 20), revision: 1) }
        let otherScope = LibraryScope(owner: .account(id: "43"), sourceID: "native")
        let other = try LibraryState(scope: otherScope, snapshot: first.snapshot)
        try await store.save(other, revision: 1)
        #expect(try await store.load(scope: scope) == first)
        #expect(try await store.load(scope: otherScope) == other)
        #expect(await io.values().count == 2)
    }

    @Test func corruptPrimaryRecoversOnlyValidSameScopeBackupAndPreservesBrokenBytes() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LibrarySnapshotDisk(directory: directory)
        let old = try state(seconds: 10), newer = try state(seconds: 20)
        try await disk.save(old); try await disk.save(newer)
        let url = try LibrarySnapshotDisk.fileURL(scope: scope, directory: directory)
        let broken = Data("broken primary".utf8)
        try broken.write(to: url)
        #expect(try await disk.load(scope: scope, legacy: nil) == old)
        #expect(try Data(contentsOf: url) == broken)
        let foreign = try LibraryState(scope: .init(owner: .account(id: "43"), sourceID: "native"))
        try JSONEncoder().encode(foreign).write(to: url.appendingPathExtension("previous"))
        await #expect(throws: LibraryStorageError.unreadable) { try await disk.load(scope: scope, legacy: nil) }
        #expect(try Data(contentsOf: url) == broken)
    }

    @Test func backupWriteFailureCannotDamageTheExistingPrimary() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LibrarySnapshotDisk(directory: directory)
        try await disk.save(state(seconds: 10))
        let url = try LibrarySnapshotDisk.fileURL(scope: scope, directory: directory)
        let before = try Data(contentsOf: url)
        try FileManager.default.createDirectory(at: url.appendingPathExtension("previous"), withIntermediateDirectories: true)
        await #expect(throws: LibraryStorageError.writeFailed) { try await disk.save(state(seconds: 20)) }
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func oversizedWriteAndBrokenLegacyNeverReplaceOriginalFilesWithEmptyState() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let disk = LibrarySnapshotDisk(directory: directory, maximumBytes: 4096)
        try await disk.save(state(seconds: 10))
        let url = try LibrarySnapshotDisk.fileURL(scope: scope, directory: directory)
        let before = try Data(contentsOf: url)
        let large = try LibraryState(scope: scope, snapshot: .init(favorites: [.init(id: "200", title: String(repeating: "x", count: 5000))]))
        await #expect(throws: LibraryStorageError.tooLarge) { try await disk.save(large) }
        #expect(try Data(contentsOf: url) == before)
        let newScope = LibraryScope(owner: .guest, sourceID: "other")
        await #expect(throws: LibraryStorageError.unreadable) { try await disk.load(scope: newScope, legacy: Data("broken legacy".utf8)) }
        #expect(!FileManager.default.fileExists(atPath: try LibrarySnapshotDisk.fileURL(scope: newScope, directory: directory).path))
    }

    @Test func largeLibraryAndLegacyMigrationRoundTripWithoutTruncation() async throws {
        let directory = temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let records = (1...1500).map { index in
            WatchRecord(series: .init(id: String(10000 + index), title: "大量片庫測試\(index)"),
                        episode: .init(id: String(20000 + index), number: 1, title: "第1集"), seconds: 12, duration: 90)
        }
        let snapshot = LibrarySnapshot(favorites: records.map(\.series), history: records)
        let store = LibrarySnapshotStore(directory: directory)
        let migrated = try await store.load(scope: scope, legacy: JSONEncoder().encode(snapshot))
        #expect(migrated.history.count == 1500 && migrated.favorites.count == 1500)
        var changed = migrated
        try changed.record(.init(series: records[0].series, episode: records[0].episode, seconds: 50, duration: 90,
                                 updatedAt: Date().addingTimeInterval(1)))
        try await store.save(changed, revision: 1)
        let reopened = LibrarySnapshotStore(directory: directory)
        let restored = try await reopened.load(scope: scope)
        #expect(restored == changed)
        #expect(restored.history.count == 1500 && restored.record(for: records[0].series.id)?.seconds == 50)
    }

    private func state(seconds: Double) throws -> LibraryState {
        var state = try LibraryState(scope: scope)
        try state.record(.init(series: .init(id: "100", title: "測試劇"), episode: .init(id: "200", number: 1, title: "第1集"),
                               seconds: seconds, duration: 90, updatedAt: Date(timeIntervalSince1970: 1_700_000_000 + seconds)))
        return state
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-library-test-\(UUID())") }
}

private actor SnapshotCounter { private(set) var value = 0; func increment() { value += 1 } }

private actor SnapshotIOProbe: LibrarySnapshotIO {
    private var snapshots: [LibraryState] = []
    private var calls = 0
    private var failures: Int
    private var blockFirstSave: Bool
    private var gate: CheckedContinuation<Void, Never>?
    private var starts: [(Int, CheckedContinuation<Void, Never>)] = []
    private var onMainThread = false
    init(blockFirstSave: Bool, failures: Int = 0) { self.blockFirstSave = blockFirstSave; self.failures = failures }
    func load(scope: LibraryScope, legacy: Data?) throws -> LibraryState {
        try snapshots.last(where: { $0.scope == scope }) ?? LibraryState(scope: scope)
    }
    func save(_ state: LibraryState) async throws {
        calls += 1; onMainThread = onMainThread || Thread.isMainThread
        let ready = starts.filter { $0.0 <= calls }; starts.removeAll { $0.0 <= calls }
        ready.forEach { $0.1.resume() }
        if blockFirstSave, calls == 1 { await withCheckedContinuation { gate = $0 } }
        if failures > 0 { failures -= 1; throw LibraryStorageError.writeFailed }
        snapshots.append(state)
    }
    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { starts.append((count, $0)) }
    }
    func release() { gate?.resume(); gate = nil }
    func values() -> [LibraryState] { snapshots }
    func ranOnMainThread() -> Bool { onMainThread }
}
