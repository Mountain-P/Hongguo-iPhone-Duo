// SPDX-License-Identifier: GPL-3.0-only
import Darwin
import Foundation
import Testing
@testable import HongguoCore

struct OfflineDownloadsTests {
    @Test func unsupportedSourceIsNotRetriedAndDoesNotBlockOtherEpisodes() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let unsupported = episode(1)
        let available = episode(2)
        let queue = try OfflineDownloads(directory: directory) { item, destination, maximum, progress in
            if item.key == unsupported.key { throw NativeMediaError.unsupportedEncryption }
            try await writeFixture(item, destination, maximum, progress)
        }
        try await queue.enqueue([unsupported, available])
        try await wait { await queue.snapshot().map(\.state) == [.failed, .completed] }
        #expect(await queue.snapshot().first?.isOfflineUnsupported == true)
        #expect(try await queue.localURL(for: unsupported.key) == nil)
        try await queue.retry(unsupported.key)
        #expect(await queue.snapshot().map(\.key) == [unsupported.key, available.key])
        let reopened = try OfflineDownloads(directory: directory, provider: writeFixture)
        #expect(await reopened.snapshot().first?.isOfflineUnsupported == true)
    }

    @Test(arguments: [true, false])
    func persistedClearOnlyFailureAllowsManualRetry(_ hasUnsupportedFlag: Bool) async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = episode(1)
        let previous = try OfflineDownloads(directory: directory) { _, _, _, _ in
            throw NativeSourceError(code: "OFFLINE_CLEAR_UNAVAILABLE")
        }
        try await previous.enqueue(item)
        try await wait { await previous.snapshot().first?.state == .failed }

        let manifest = directory.appendingPathComponent("index.json")
        var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        var records = try #require(index["records"] as? [[String: Any]])
        var persisted = try #require(records.first?["item"] as? [String: Any])
        persisted["failure"] = "來源未提供可離線儲存的未加密 MP4。"
        persisted["offlineUnsupported"] = hasUnsupportedFlag ? true : nil
        records[0]["item"] = persisted
        index["records"] = records
        let previousManifest = try JSONSerialization.data(withJSONObject: index)
        try previousManifest.write(to: manifest)

        let reopened = try OfflineDownloads(directory: directory, provider: writeFixture)
        await reopened.start()
        #expect(await reopened.snapshot().first?.state == .failed)
        #expect(await reopened.snapshot().first?.isOfflineUnsupported == false)
        #expect(try Data(contentsOf: manifest) == previousManifest)
        try await reopened.retry(item.key)
        try await wait { await reopened.snapshot().first?.state == .completed }
        #expect(try await reopened.localURL(for: item.key) != nil)
    }

    @Test func serialQueueRejectsCancelledWorkAndRetriesAtTheTail() async throws {
        let directory = temporaryLibrary()
        let transfer = ControlledOfflineTransfer()
        defer {
            Task { await transfer.releaseAll() }
            try? FileManager.default.removeItem(at: directory)
        }
        let queue = try OfflineDownloads(directory: directory) { item, destination, maximum, progress in
            try await transfer.download(item, destination, maximum, progress)
        }
        let first = episode(1)
        let second = episode(2)
        var updates = await queue.updates().makeAsyncIterator()
        #expect(await updates.next() == [])
        try await queue.enqueue(first)
        try await wait { await transfer.count == 1 }
        try await queue.enqueue(first)
        try await queue.enqueue(second)
        #expect(await queue.snapshot().map(\.state) == [.downloading, .queued])
        #expect(await updates.next()?.map(\.state) == [.downloading, .queued])
        #expect(try await queue.localURL(for: first.key) == nil)

        try await queue.cancel(first.key)
        try await queue.retry(first.key)
        #expect(await queue.snapshot().map(\.key) == [second.key, first.key])
        #expect(await transfer.count == 1)
        await transfer.release(0)
        try await wait { await transfer.count == 2 }
        #expect(await transfer.key(at: 1) == second.key)
        #expect(try await queue.localURL(for: first.key) == nil)
        await transfer.release(1)
        try await wait { await transfer.count == 3 }
        #expect(await transfer.key(at: 2) == first.key)
        #expect(await transfer.distinctStagingDirectories == 3)
        await transfer.release(2)
        try await wait { await queue.snapshot().map(\.state) == [.completed, .completed] }
        let url = try #require(try await queue.localURL(for: first.key))
        #expect(try Data(contentsOf: url) == ControlledOfflineTransfer.complete)
        #expect(url.deletingLastPathComponent().lastPathComponent == "completed")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("staging").path).isEmpty)
    }

    @Test func completedFileAndWatchPositionSurviveReopeningAndDetectSameSizeDamage() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = episode(1)
        var queue: OfflineDownloads? = try OfflineDownloads(directory: directory, provider: writeFixture)
        try await queue?.enqueue(item)
        try await wait { await queue?.snapshot().first?.state == .completed }
        try await queue?.recordProgress(for: item.key, position: 13.5, duration: 30)
        let url = try #require(try await queue?.localURL(for: item.key))
        queue = nil

        let restored = try OfflineDownloads(directory: directory, provider: writeFixture)
        #expect(await restored.snapshot().first?.position == 13.5)
        #expect(await restored.snapshot().first?.duration == 30)
        #expect(try await restored.localURL(for: item.key) == url)
        try Data(repeating: 0, count: fixture.count).write(to: url)
        #expect(try await restored.localURL(for: item.key) == nil)
        #expect(await restored.snapshot().first?.state == .failed)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await restored.retry(item.key)
        try await wait { await restored.snapshot().first?.state == .completed }
        #expect(await restored.snapshot().first?.position == 13.5)
    }

    @Test func interruptedIndexKeepsWaitingJobsAndRequiresManualRetryForActiveJob() async throws {
        let originalDirectory = temporaryLibrary()
        let restartDirectory = temporaryLibrary()
        let transfer = ControlledOfflineTransfer()
        defer {
            Task { await transfer.releaseAll() }
            try? FileManager.default.removeItem(at: originalDirectory)
            try? FileManager.default.removeItem(at: restartDirectory)
        }
        let item = episode(1)
        let original = try OfflineDownloads(directory: originalDirectory) { item, destination, maximum, progress in
            try await transfer.download(item, destination, maximum, progress)
        }
        try await original.enqueue(item)
        try await original.enqueue(episode(2))
        try await wait { await transfer.count == 1 }
        #expect(await original.snapshot().first?.receivedBytes == 3)
        let diskImage = try Data(contentsOf: originalDirectory.appendingPathComponent("index.json"))
        let index = try #require(JSONSerialization.jsonObject(with: diskImage) as? [String: Any])
        let persisted = try #require((index["records"] as? [[String: Any]])?.first?["item"] as? [String: Any])
        #expect(persisted["receivedBytes"] as? Int == 3)

        // Copy the stable checkpoint while the provider is still writing its private staging job.
        try FileManager.default.copyItem(at: originalDirectory, to: restartDirectory)
        let orphan = restartDirectory.appendingPathComponent("completed/\(UUID().uuidString).mp4")
        try fixture.write(to: orphan)
        let restored = try OfflineDownloads(directory: restartDirectory, provider: writeFixture)
        #expect(await restored.snapshot().map(\.state) == [.failed, .queued])
        #expect(await restored.snapshot().first?.receivedBytes == 0)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: restartDirectory.appendingPathComponent("staging").path).isEmpty)
        await restored.start()
        try await wait { await restored.snapshot().map(\.state) == [.failed, .completed] }
        try await restored.retry(item.key)
        try await wait { await restored.snapshot().map(\.state) == [.completed, .completed] }
        #expect(try await restored.localURL(for: item.key) != nil)
        await transfer.release(0)
        try await wait { await transfer.count == 2 }
        await transfer.release(1)
        try await wait { await original.snapshot().map(\.state) == [.completed, .completed] }
    }

    @Test func batchEnqueueValidatesTheWholeSelectionBeforeStartingDownloads() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let caps = OfflineTransferCaps()
        let queue = try OfflineDownloads(directory: directory, limits: .init(maximumItems: 2)) { _, destination, maximum, _ in
            await caps.record(maximum)
            try fixture.write(to: destination)
        }
        let invalid = OfflineDownloadItem(key: episode(3).key, seriesTitle: "", episodeNumber: 3)
        await #expect(throws: OfflineDownloadError.invalidItem) { try await queue.enqueue([episode(1), invalid]) }
        await #expect(throws: OfflineDownloadError.tooManyItems) { try await queue.enqueue([episode(1), episode(2), episode(3)]) }
        #expect(await queue.snapshot().isEmpty)
        #expect(await caps.values.isEmpty)
        try await queue.enqueue([episode(1), episode(2), episode(1)])
        try await wait { await queue.snapshot().map(\.state) == [.completed, .completed] }
        #expect(await caps.values.count == 2)
    }

    @Test func quotaPassesActualRemainingCapAndDeleteReleasesIt() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let caps = OfflineTransferCaps()
        let limits = OfflineDownloads.Limits(maximumItems: 2, maximumBytesPerItem: 12,
                                             maximumTotalBytes: 10, reserveBytes: 0)
        let queue = try OfflineDownloads(directory: directory, limits: limits) { item, destination, maximum, progress in
            await caps.record(maximum)
            // Deliberately write beyond the second job's limit to exercise final validation.
            try fixture.write(to: destination)
        }
        let first = episode(1)
        let second = episode(2)
        try await queue.enqueue(first)
        try await queue.enqueue(second)
        try await wait { await queue.snapshot().map(\.state) == [.completed, .failed] }
        #expect(await caps.values == [10, 4])
        await #expect(throws: OfflineDownloadError.tooManyItems) { try await queue.enqueue(episode(3)) }
        let url = try #require(try await queue.localURL(for: first.key))
        try await queue.delete(first.key)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await queue.retry(second.key)
        try await wait { await queue.snapshot().map(\.state) == [.completed] }
        #expect(await caps.values == [10, 4, 10])
    }

    @Test func deleteDuringTransferKeepsLateProviderFromPublishingUnderNewRecord() async throws {
        let directory = temporaryLibrary()
        let transfer = ControlledOfflineTransfer()
        defer {
            Task { await transfer.releaseAll() }
            try? FileManager.default.removeItem(at: directory)
        }
        let item = episode(1)
        let queue = try OfflineDownloads(directory: directory) { item, destination, maximum, progress in
            try await transfer.download(item, destination, maximum, progress)
        }
        try await queue.enqueue(item)
        try await wait { await transfer.count == 1 }
        try await queue.delete(item.key)
        try await queue.enqueue(item)
        await transfer.release(0)
        try await wait { await transfer.count == 2 }
        #expect(try await queue.localURL(for: item.key) == nil)
        #expect(await queue.snapshot().first?.state == .downloading)
        await transfer.release(1)
        try await wait { await queue.snapshot().first?.state == .completed }
        #expect(try await queue.localURL(for: item.key) != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("completed").path).count == 1)
    }

    @Test func unsafeProviderFileNeverMovesIntoCompletedLibrary() async throws {
        let directory = temporaryLibrary()
        let external = temporaryLibrary()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: external)
        }
        try fixture.write(to: external)
        let queue = try OfflineDownloads(directory: directory) { _, destination, _, _ in
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: external)
        }
        let item = episode(1)
        try await queue.enqueue(item)
        try await wait { await queue.snapshot().first?.state == .failed }
        #expect(try await queue.localURL(for: item.key) == nil)
        #expect(try Data(contentsOf: external) == fixture)
    }

    @Test func missingOrUnreadableIndexPreservesCompletedFiles() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = episode(1)
        var queue: OfflineDownloads? = try OfflineDownloads(directory: directory, provider: writeFixture)
        try await queue?.enqueue(item)
        try await wait { await queue?.snapshot().first?.state == .completed }
        let movie = try #require(try await queue?.localURL(for: item.key))
        queue = nil
        let index = directory.appendingPathComponent("index.json")
        let data = try Data(contentsOf: index)
        try FileManager.default.removeItem(at: index)
        #expect(throws: OfflineDownloadError.invalidIndex) { try OfflineDownloads(directory: directory, provider: writeFixture) }
        #expect(try Data(contentsOf: movie) == fixture)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: false)
        #expect(throws: OfflineDownloadError.invalidIndex) { try OfflineDownloads(directory: directory, provider: writeFixture) }
        #expect(try Data(contentsOf: movie) == fixture)
        try FileManager.default.removeItem(at: index)
        try data.write(to: index)
        let reopened = try OfflineDownloads(directory: directory, provider: writeFixture)
        #expect(try await reopened.localURL(for: item.key) == movie)
    }

    @Test(.enabled(if: geteuid() != 0))
    func temporaryReadDenialPreservesTheCompletedItem() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = episode(1)
        var queue: OfflineDownloads? = try OfflineDownloads(directory: directory, provider: writeFixture)
        try await queue?.enqueue(item)
        try await wait { await queue?.snapshot().first?.state == .completed }
        let movie = try #require(try await queue?.localURL(for: item.key))
        queue = nil
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: movie.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: movie.path) }
        let restored = try OfflineDownloads(directory: directory, provider: writeFixture)
        await #expect(throws: OfflineDownloadError.storageUnavailable) { try await restored.localURL(for: item.key) }
        #expect(await restored.snapshot().first?.state == .completed)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: movie.path)
        #expect(try await restored.localURL(for: item.key) == movie)
    }

    @Test(.enabled(if: geteuid() != 0))
    func deleteRefusalRestoresTheDurableRowAndCanBeRetried() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = episode(1)
        var queue: OfflineDownloads? = try OfflineDownloads(directory: directory, provider: writeFixture)
        try await queue?.enqueue(item)
        try await wait { await queue?.snapshot().first?.state == .completed }
        let movie = try #require(try await queue?.localURL(for: item.key))
        let movies = movie.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: movies.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: movies.path) }
        await #expect(throws: OfflineDownloadError.storageUnavailable) { try await queue?.delete(item.key) }
        #expect(await queue?.snapshot().first?.state == .completed)
        #expect(FileManager.default.fileExists(atPath: movie.path))
        queue = nil
        let reopened = try OfflineDownloads(directory: directory, provider: writeFixture)
        #expect(try await reopened.localURL(for: item.key) == movie)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: movies.path)
        try await reopened.delete(item.key)
        #expect(await reopened.snapshot().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: movie.path))
    }

    @Test func batchDeleteRemovesOnlySelectedEpisodesFromDiskAndIndex() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = episode(1)
        let second = episode(2)
        let third = episode(3)
        let otherSeries = OfflineDownloadItem(key: .init(scope: "public", seriesID: "41", episodeID: "1"),
                                              seriesTitle: "另一部劇", episodeNumber: 1)
        let queue = try OfflineDownloads(directory: directory, provider: writeFixture)
        try await queue.enqueue([first, second, third, otherSeries])
        try await wait { await queue.snapshot().map(\.state) == Array(repeating: .completed, count: 4) }
        let firstMovie = try #require(try await queue.localURL(for: first.key))
        let thirdMovie = try #require(try await queue.localURL(for: third.key))

        try await queue.delete([third.key, episode(5).key, first.key, third.key])

        #expect(await queue.snapshot().map(\.key) == [second.key, otherSeries.key])
        #expect(!FileManager.default.fileExists(atPath: firstMovie.path))
        #expect(!FileManager.default.fileExists(atPath: thirdMovie.path))
        let reopened = try OfflineDownloads(directory: directory, provider: writeFixture)
        #expect(await reopened.snapshot().map(\.key) == [second.key, otherSeries.key])
        #expect(try await reopened.localURL(for: second.key) != nil)
        #expect(try await reopened.localURL(for: otherSeries.key) != nil)
    }

    @Test func deleteSeriesRemovesSavedAndOutstandingDownloadsAndContinuesTheQueue() async throws {
        let directory = temporaryLibrary()
        let transfer = ControlledOfflineTransfer()
        defer {
            Task { await transfer.releaseAll() }
            try? FileManager.default.removeItem(at: directory)
        }
        let saved = episode(1)
        let active = episode(2)
        let waiting = episode(3)
        let otherSeries = OfflineDownloadItem(key: .init(scope: saved.key.scope, seriesID: "41", episodeID: "1"),
                                              seriesTitle: "另一部劇", episodeNumber: 1)
        let otherScope = OfflineDownloadItem(key: .init(scope: "private", seriesID: saved.key.seriesID, episodeID: "1"),
                                             seriesTitle: "另一個來源", episodeNumber: 1)
        let queue = try OfflineDownloads(directory: directory) { item, destination, maximum, progress in
            try await transfer.download(item, destination, maximum, progress)
        }
        try await queue.enqueue([saved, active, waiting, otherSeries, otherScope])
        try await wait { await transfer.count == 1 }
        await transfer.release(0)
        try await wait { await transfer.count == 2 }
        let movie = try #require(try await queue.localURL(for: saved.key))
        #expect(await queue.snapshot().map(\.state) == [.completed, .downloading, .queued, .queued, .queued])

        try await queue.deleteSeries(scope: saved.key.scope, seriesID: saved.key.seriesID)

        #expect(await queue.snapshot().map(\.key) == [otherSeries.key, otherScope.key])
        #expect(!FileManager.default.fileExists(atPath: movie.path))
        await transfer.release(1)
        try await wait { await transfer.count == 3 }
        #expect(await transfer.key(at: 2) == otherSeries.key)
        await transfer.release(2)
        try await wait { await transfer.count == 4 }
        #expect(await transfer.key(at: 3) == otherScope.key)
        await transfer.release(3)
        try await wait { await queue.snapshot().map(\.state) == [.completed, .completed] }

        let reopened = try OfflineDownloads(directory: directory, provider: writeFixture)
        #expect(await reopened.snapshot().map(\.key) == [otherSeries.key, otherScope.key])
        #expect(try await reopened.localURL(for: otherSeries.key) != nil)
        #expect(try await reopened.localURL(for: otherScope.key) != nil)
    }

    @Test(.enabled(if: geteuid() != 0))
    func batchDeletePreservesOnlyRefusedRowsWhenSomeDeletionsFail() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let available = episode(1)
        let unavailable = episode(2)
        let queue = try OfflineDownloads(directory: directory) { item, destination, maximum, progress in
            if item.key == unavailable.key { throw NativeMediaError.unsupportedEncryption }
            try await writeFixture(item, destination, maximum, progress)
        }
        try await queue.enqueue([available, unavailable])
        try await wait { await queue.snapshot().map(\.state) == [.completed, .failed] }
        let movie = try #require(try await queue.localURL(for: available.key))
        let movies = movie.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: movies.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: movies.path) }

        await #expect(throws: OfflineDownloadError.storageUnavailable) {
            try await queue.delete([available.key, unavailable.key])
        }

        #expect(await queue.snapshot().map(\.key) == [available.key])
        let reopened = try OfflineDownloads(directory: directory, provider: writeFixture)
        #expect(await reopened.snapshot().map(\.key) == [available.key])
        #expect(try await reopened.localURL(for: available.key) == movie)
    }

    @Test(.enabled(if: geteuid() != 0))
    func retryReplacesTheStaleCorruptFileOnceStorageAllowsRemoval() async throws {
        let directory = temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: directory) }
        let item = episode(1)
        let queue = try OfflineDownloads(directory: directory, provider: writeFixture)
        try await queue.enqueue(item)
        try await wait { await queue.snapshot().first?.state == .completed }
        let movie = try #require(try await queue.localURL(for: item.key))
        try Data(repeating: 0, count: fixture.count).write(to: movie)
        let movies = movie.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: movies.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: movies.path) }
        #expect(try await queue.localURL(for: item.key) == nil)
        #expect(await queue.snapshot().first?.state == .failed)
        #expect(FileManager.default.fileExists(atPath: movie.path))
        await #expect(throws: OfflineDownloadError.storageUnavailable) { try await queue.retry(item.key) }

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: movies.path)
        try await queue.retry(item.key)
        try await wait { await queue.snapshot().first?.state == .completed }
        #expect(try await queue.localURL(for: item.key) == movie)
        #expect(try Data(contentsOf: movie) == fixture)
    }
}

private let fixture = Data([1, 2, 3, 4, 5, 6])

private func writeFixture(_ item: OfflineDownloadItem, _ destination: URL, _ maximum: Int64,
                          _ progress: OfflineDownloads.Progress) async throws {
    try fixture.write(to: destination)
}

private func temporaryLibrary() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

private func episode(_ number: Int) -> OfflineDownloadItem {
    .init(key: .init(scope: "public", seriesID: "40", episodeID: String(number)),
          seriesTitle: "測試劇集", episodeNumber: number)
}

private func wait(_ condition: () async -> Bool) async throws {
    for _ in 0..<300 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw OfflineTransferTestError.timedOut
}

private enum OfflineTransferTestError: Error { case timedOut }

private actor ControlledOfflineTransfer {
    static let complete = fixture
    private struct Call {
        let key: OfflineDownloadKey
        let staging: URL
    }
    private var calls: [Call] = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var autoRelease = false
    var count: Int { calls.count }
    var distinctStagingDirectories: Int { Set(calls.map(\.staging)).count }
    func key(at index: Int) -> OfflineDownloadKey { calls[index].key }

    func download(_ item: OfflineDownloadItem, _ destination: URL, _ maximum: Int64,
                  _ progress: OfflineDownloads.Progress) async throws {
        try Data(fixture.prefix(3)).write(to: destination)
        await progress(3, 6)
        if !autoRelease {
            await withCheckedContinuation { completion in
                let index = calls.count
                calls.append(.init(key: item.key, staging: destination.deletingLastPathComponent()))
                waiting[index] = completion
            }
        }
        // Even cancelled work finishes writing and reports progress, exercising the job token.
        try Self.complete.write(to: destination)
        await progress(6, 6)
    }

    func release(_ index: Int) { waiting.removeValue(forKey: index)?.resume() }
    func releaseAll() {
        autoRelease = true
        let pending = waiting.values
        waiting.removeAll()
        for completion in pending { completion.resume() }
    }
}

private actor OfflineTransferCaps {
    private(set) var values: [Int64] = []
    func record(_ cap: Int64) { values.append(cap) }
}
