import Foundation
import Testing
@testable import HongguoCore
@testable import HongguoAppSupport

@MainActor
struct AccountLibraryControllerTests {
    private let a = LibraryScope(owner: .guest, sourceID: "test-source-a")
    private let b = LibraryScope(owner: .guest, sourceID: "test-source-b")

    @Test func delayedLoadQueuesFavoriteAndProgressWithoutReplacingExistingDataWithEmptyState() async throws {
        let original = try state(a, ids: ["100"])
        let io = ControllerStorageProbe(initial: [a: original], blockedLoads: [a])
        let controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        controller.toggleFavorite(series("101"))
        controller.progressHandler(for: series("100"), episodes: [episode])(episode, 30, 90)
        let flush = Task { await controller.flush() }
        await io.waitForLoad(a)
        #expect(controller.favorites.isEmpty)
        #expect(await io.writeCount == 0)
        await io.releaseLoad(a)
        await flush.value
        #expect(Set(controller.favorites.map(\.id)) == ["100", "101"])
        #expect(controller.record(for: series("100"))?.seconds == 30)
        let stored = try #require(await io.value(a))
        #expect(Set(stored.favorites.map(\.id)) == ["100", "101"])
        #expect(stored.record(for: "100")?.seconds == 30)
    }

    @Test func queuedMutationsPreserveOrderSoEarlyProgressCannotReviveALaterClear() async throws {
        let io = ControllerStorageProbe(initial: [a: try state(a, ids: ["100"])], blockedLoads: [a])
        let controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        controller.progressHandler(for: series("100"), episodes: [episode])(episode, 30, 90)
        controller.clearHistory()
        await io.waitForLoad(a)
        await io.releaseLoad(a)
        await controller.flush()
        #expect(controller.history.isEmpty)
        #expect(await io.value(a)?.history.isEmpty == true)
        #expect(await io.value(a)?.favorites.map(\.id) == ["100"])
    }

    @Test func changingSourceDuringLoadNeverPublishesOrWritesProgressIntoTheNewScope() async throws {
        let io = ControllerStorageProbe(initial: [a: try state(a, ids: ["100"]), b: try state(b, ids: ["200"])], blockedLoads: [a])
        let controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        let oldProgress = controller.progressHandler(for: series("100"), episodes: [episode])
        controller.toggleFavorite(series("101"))
        controller.selectSource(b.sourceID, legacy: nil, allowsAccount: false)
        oldProgress(episode, 40, 90)
        await io.waitForLoad(a)
        await io.releaseLoad(a)
        await controller.flush()
        #expect(controller.favorites.map(\.id) == ["200"])
        #expect(controller.record(for: series("100")) == nil)
        #expect(await io.value(a)?.record(for: "100")?.seconds == 40)
        #expect(await io.value(b)?.record(for: "100") == nil)
        #expect(Set(await io.value(a)?.favorites.map(\.id) ?? []) == ["100", "101"])
    }

    @Test func failedLoadBlocksQueuedMutationAndFlushWithoutWritingAnEmptyReplacement() async throws {
        let original = try state(a, ids: ["100"])
        let io = ControllerStorageProbe(initial: [a: original], failingLoads: [a])
        let controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        controller.toggleFavorite(series("101"))
        controller.clearHistory()
        await controller.flush()
        #expect(controller.persistenceError != nil)
        #expect(await io.writeCount == 0)
        #expect(await io.value(a) == original)
    }

    @Test func lifecycleFlushWaitsForTheFinalProgressEvenWhenAnOlderWriteIsStillBlocked() async throws {
        let io = ControllerStorageProbe(initial: [a: try state(a, ids: ["100"])], blockFirstWrite: true)
        let controller = makeController(io), completion = ControllerCounter()
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        await controller.flush()
        let progress = controller.progressHandler(for: series("100"), episodes: [episode])
        progress(episode, 30, 90)
        let flush = Task { await controller.flush(); await completion.increment() }
        await io.waitForWrite()
        #expect(await completion.value == 0)
        progress(episode, 40, 90)
        await io.releaseWrite()
        await flush.value
        #expect(await completion.value == 1)
        #expect(await io.value(a)?.record(for: "100")?.seconds == 40)
    }

    @Test func oldMetadataDeferCannotClearReplacementTaskAndOldResultCannotEnrichTheLibrary() async throws {
        let io = ControllerStorageProbe(initial: [a: try state(a, ids: ["100"])])
        let loader = ControllerMetadataProbe()
        let controller = makeController(io, loader: { try await loader.load($0) })
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        await controller.flush()
        controller.refreshMetadata(history: nil, favorites: snapshot(["100"]))
        let old = try #require(controller.metadataTask)
        await loader.waitForCalls(1)
        controller.refreshMetadata(history: nil, favorites: snapshot(["100"]))
        let replacement = try #require(controller.metadataTask)
        await loader.waitForCalls(2)
        await loader.release(1, title: "舊資料")
        await old.value
        #expect(controller.loadingMetadata)
        #expect(controller.metadataTask != nil)
        #expect(controller.favorites[0].title != "舊資料")
        await loader.release(2, title: "新資料")
        await replacement.value
        await controller.flush()
        #expect(!controller.loadingMetadata)
        #expect(controller.favorites[0].title == "新資料")
    }

    @Test func sourceCancellationRejectsAnOldMetadataResultBeforeCacheOrDiskCommit() async throws {
        let io = ControllerStorageProbe(initial: [a: try state(a, ids: ["100"]), b: try state(b, ids: ["200"])])
        let loader = ControllerMetadataProbe()
        let controller = makeController(io, loader: { try await loader.load($0) })
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        await controller.flush()
        controller.refreshMetadata(history: nil, favorites: snapshot(["100"]))
        let old = try #require(controller.metadataTask)
        await loader.waitForCalls(1)
        controller.selectSource(b.sourceID, legacy: nil, allowsAccount: false)
        await loader.release(1, title: "不得回填")
        await old.value
        await controller.flush()
        #expect(controller.favorites.map(\.id) == ["200"])
        #expect(await io.value(a)?.favorites[0].title != "不得回填")
        #expect(!controller.loadingMetadata)
    }

    @Test func controllerSecondMetadataRoundReachesTheValidItemsBehindFiftyFailures() async throws {
        let ids = (100..<160).map(String.init)
        let io = ControllerStorageProbe(initial: [a: try state(a, ids: ids)])
        let requests = ControllerRequestRecorder()
        let controller = makeController(io, loader: { id in
            await requests.append(id)
            if Int(id)! < 150 { throw CatalogError.httpStatus(404) }
            return .init(series: .init(id: id, title: "成功\(id)", cover: "https://example.com/poster.jpg"), episodes: [])
        })
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        await controller.flush()
        controller.refreshMetadata(history: nil, favorites: snapshot(ids))
        await controller.metadataTask?.value
        #expect(await requests.ids.count == 50)
        controller.refreshMetadata(history: nil, favorites: snapshot(ids))
        await controller.metadataTask?.value
        await controller.flush()
        #expect(await requests.ids.count == 60)
        #expect(controller.favorites.filter { $0.title.hasPrefix("成功") }.count == 10)
    }

    @Test func batchUnfavoriteWaitsForItsCapturedScopeAndCommitsOnceWithoutUnlockingOtherFailures() async throws {
        var original = try state(a, ids: ["100", "101", "102"])
        try original.setFavorite(series("100"), isFavorite: true)
        let old = original.pendingFavorites[0]
        original.markFavoriteAttempt(operationID: old.operationID)
        let io = ControllerStorageProbe(initial: [a: original, b: try state(b, ids: ["100", "101", "102"])], blockedLoads: [a])
        let controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        controller.removeFavorites(seriesIDs: ["101", "102"])
        controller.selectSource(b.sourceID, legacy: nil, allowsAccount: false)
        await io.waitForLoad(a); await io.releaseLoad(a)
        await controller.flush()
        #expect(Set(controller.favorites.map(\.id)) == ["100", "101", "102"])
        let saved = try #require(await io.value(a))
        #expect(saved.favorites.map(\.id) == ["100"])
        #expect(saved.pendingFavorites.first { $0.seriesID == "100" }?.operationID == old.operationID)
        #expect(saved.pendingFavorites.first { $0.seriesID == "100" }?.retryRequired == true)
        #expect(Set(saved.eligibleFavorites().map(\.seriesID)) == ["101", "102"])
        #expect(await io.writeCount == 1)
    }

    @Test func batchHistoryRemovalMakesOneLocalCommitAndKeepsFavorites() async throws {
        var original = try state(a, ids: ["100", "101", "102"])
        for id in ["100", "101", "102"] {
            try original.record(.init(series: series(id), episode: episode, seconds: 20, duration: 90))
        }
        let io = ControllerStorageProbe(initial: [a: original]), controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        await controller.flush()
        controller.removeHistory(seriesIDs: ["100", "101"])
        await controller.flush()
        let saved = try #require(await io.value(a))
        #expect(saved.history.map(\.id) == ["102"])
        #expect(Set(saved.favorites.map(\.id)) == ["100", "101", "102"])
        #expect(saved.pendingProgress.filter(\.isDeletion).count == 2)
        #expect(!saved.eligibleProgress().contains { ["100", "101"].contains($0.seriesID) })
        #expect(await io.writeCount == 1)
    }

    @Test func invalidAndStaleSelectionsCannotPartiallyChangeOrRewriteTheLibrary() async throws {
        let original = try state(a, ids: ["100", "101"])
        let io = ControllerStorageProbe(initial: [a: original]), controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        await controller.flush()
        controller.removeFavorites(seriesIDs: ["100", "invalid"])
        controller.removeHistory(seriesIDs: ["100", "invalid"])
        controller.removeFavorites(seriesIDs: ["999"])
        await controller.flush()
        #expect(controller.persistenceError != nil)
        #expect(await io.value(a) == original)
        #expect(await io.writeCount == 0)
    }

    @Test func aNewUserToggleAfterQueuedBulkRemovalRetainsTheLaterDesiredState() async throws {
        let io = ControllerStorageProbe(initial: [a: try state(a, ids: ["100", "101", "102"])], blockedLoads: [a])
        let controller = makeController(io)
        controller.selectSource(a.sourceID, legacy: nil, allowsAccount: false)
        controller.removeFavorites(seriesIDs: ["100", "101"])
        controller.toggleFavorite(series("100"))
        await io.waitForLoad(a); await io.releaseLoad(a)
        await controller.flush()
        let saved = try #require(await io.value(a))
        #expect(Set(saved.favorites.map(\.id)) == ["100", "102"])
        #expect(saved.pendingFavorites.first { $0.seriesID == "100" }?.isFavorite == true)
        #expect(saved.pendingFavorites.first { $0.seriesID == "101" }?.isFavorite == false)
    }

    private var episode: Episode { .init(id: "900", number: 1, title: "第1集") }
    private func series(_ id: String) -> Series { .init(id: id, title: "待補劇\(id)") }
    private func state(_ scope: LibraryScope, ids: [String]) throws -> LibraryState {
        try .init(scope: scope, snapshot: .init(favorites: ids.map(series)))
    }
    private func snapshot(_ ids: [String]) -> AccountLibrarySnapshot {
        .init(accountID: "42", items: ids.map { .init(series: series($0)) }, isComplete: true, pagesRead: 1)
    }
    private func makeController(_ io: ControllerStorageProbe,
                                loader: @escaping @Sendable (String) async throws -> SeriesDetail = { _ in throw CatalogError.network }) -> AccountLibraryController {
        AccountLibraryController(persistence: .init(store: .init(io: io)),
                                 defaults: UserDefaults(suiteName: "HongguoAppSupportTests.\(UUID())")!,
                                 metadataLoader: loader, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
    }
}

private actor ControllerCounter { private(set) var value = 0; func increment() { value += 1 } }
private actor ControllerRequestRecorder { private(set) var ids: [String] = []; func append(_ id: String) { ids.append(id) } }

private actor ControllerStorageProbe: LibrarySnapshotIO {
    private var states: [LibraryScope: LibraryState]
    private var blockedLoads: Set<LibraryScope>
    private let failingLoads: Set<LibraryScope>
    private var loadStarted: Set<LibraryScope> = []
    private var loadStartWaiters: [LibraryScope: [CheckedContinuation<Void, Never>]] = [:]
    private var loadGates: [LibraryScope: [CheckedContinuation<Void, Never>]] = [:]
    private let blockFirstWrite: Bool
    private var writeGate: CheckedContinuation<Void, Never>?
    private var writeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var writeCount = 0
    init(initial: [LibraryScope: LibraryState], blockedLoads: Set<LibraryScope> = [],
         failingLoads: Set<LibraryScope> = [], blockFirstWrite: Bool = false) {
        states = initial; self.blockedLoads = blockedLoads; self.failingLoads = failingLoads; self.blockFirstWrite = blockFirstWrite
    }
    func load(scope: LibraryScope, legacy: Data?) async throws -> LibraryState {
        loadStarted.insert(scope); loadStartWaiters.removeValue(forKey: scope)?.forEach { $0.resume() }
        if blockedLoads.contains(scope) { await withCheckedContinuation { loadGates[scope, default: []].append($0) } }
        if failingLoads.contains(scope) { throw LibraryStorageError.unreadable }
        return try states[scope] ?? LibraryState(scope: scope)
    }
    func save(_ state: LibraryState) async throws {
        writeCount += 1; writeStartWaiters.forEach { $0.resume() }; writeStartWaiters = []
        if blockFirstWrite, writeCount == 1 { await withCheckedContinuation { writeGate = $0 } }
        states[state.scope] = state
    }
    func waitForLoad(_ scope: LibraryScope) async {
        if loadStarted.contains(scope) { return }
        await withCheckedContinuation { loadStartWaiters[scope, default: []].append($0) }
    }
    func releaseLoad(_ scope: LibraryScope) { blockedLoads.remove(scope); loadGates.removeValue(forKey: scope)?.forEach { $0.resume() } }
    func waitForWrite() async {
        if writeCount > 0 { return }
        await withCheckedContinuation { writeStartWaiters.append($0) }
    }
    func releaseWrite() { writeGate?.resume(); writeGate = nil }
    func value(_ scope: LibraryScope) -> LibraryState? { states[scope] }
}

private actor ControllerMetadataProbe {
    private var calls = 0
    private var gates: [Int: (String, CheckedContinuation<SeriesDetail, any Error>)] = [:]
    private var starts: [(Int, CheckedContinuation<Void, Never>)] = []
    func load(_ id: String) async throws -> SeriesDetail {
        calls += 1
        let number = calls
        let ready = starts.filter { $0.0 <= calls }; starts.removeAll { $0.0 <= calls }
        ready.forEach { $0.1.resume() }
        return try await withCheckedThrowingContinuation { gates[number] = (id, $0) }
    }
    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { starts.append((count, $0)) }
    }
    func release(_ number: Int, title: String) {
        guard let (id, gate) = gates.removeValue(forKey: number) else { return }
        gate.resume(returning: .init(series: .init(id: id, title: title, cover: "https://example.com/poster.jpg"), episodes: []))
    }
}
