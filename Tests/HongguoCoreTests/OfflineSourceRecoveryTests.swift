// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct OfflineSourceRecoveryTests {
    @Test(arguments: ["REGISTRATION_UNAVAILABLE", "REGISTRATION_TIMEOUT", "REGISTRATION_NETWORK_ERROR",
                      "REGISTRATION_HTTP_500", "REGISTRATION_HTTP_502", "REGISTRATION_HTTP_503", "REGISTRATION_HTTP_504"])
    func onlyClassifiedRegistrationFailuresWait(_ code: String) {
        #expect(OfflineSourceRecovery.shouldWait(NativeSourceError(code: code)))
    }

    @Test(arguments: ["HTTP_401", "HTTP_403", "HTTP_429", "BUSINESS_REJECTED", "SECURITY_BLOCKED",
                      "ABORT_ERR", "ERR_CANCELED", "DEVICE_REGISTRATION_FAILED", "REGISTRATION_HTTP_501",
                      "NO_COMPATIBLE_SOURCE", "QUALITY_UNAVAILABLE", "EMPTY_RESPONSE", "HTTP_503"])
    func terminalAndUnclassifiedErrorsDoNotEnterSharedWait(_ code: String) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RecoveryGate(), source = RecoveryProvider(failures: [code])
        let queue = try library(directory, gate, source)
        try await queue.enqueue([episode(1), episode(2)])
        try await wait { await queue.snapshot().map(\.state) == [.failed, .completed] }
        #expect(await source.calls == [1, 2])
        #expect(await gate.delays.isEmpty)
    }

    @Test func wrappedCancellationOrDenialWinsOverTemporaryCause() {
        let transient = NativeSourceError(code: "REGISTRATION_TIMEOUT")
        #expect(!OfflineSourceRecovery.shouldWait(CancellationError()))
        #expect(!OfflineSourceRecovery.shouldWait(URLError(.cancelled)))
        #expect(!OfflineSourceRecovery.shouldWait(URLError(.timedOut)))
        #expect(OfflineSourceRecovery.shouldWait(NSError(domain: "wrapper", code: 1,
            userInfo: [NSUnderlyingErrorKey: transient])))
        #expect(!OfflineSourceRecovery.shouldWait(NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue,
            userInfo: [NSUnderlyingErrorKey: transient])))
    }

    @Test func waitsAreSharedBoundedAndBulkRetryRecoversWithoutTryingEveryEpisode() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RecoveryGate(), source = RecoveryProvider(failures: Array(repeating: "REGISTRATION_TIMEOUT", count: 4))
        let queue = try library(directory, gate, source)
        try await queue.enqueue([episode(1), episode(2)])
        try await wait { await gate.delays.count == 1 }
        try await queue.enqueue(episode(3))
        #expect(await queue.snapshot().map(\.state) == [.waiting, .waiting, .waiting])
        #expect(await queue.snapshot().allSatisfy { !$0.canRetryFailedDownload && $0.sourceRetryAttempt == 1 })
        #expect(await source.calls == [1])
        for count in 2...3 {
            await gate.release()
            try await wait { await gate.delays.count == count }
            #expect(await source.calls == Array(repeating: 1, count: count))
        }
        await gate.release()
        try await wait { await queue.snapshot().allSatisfy { $0.state == .paused } }
        #expect(await gate.delays == [.seconds(10), .seconds(20), .seconds(40)])
        #expect(await source.calls == [1, 1, 1, 1])
        #expect(await queue.snapshot().allSatisfy { $0.canRetryFailedDownload && $0.retryAfter == nil })
        #expect(try await queue.retryFailed([episode(1).key, episode(2).key, episode(3).key]) == 3)
        try await wait { await queue.snapshot().allSatisfy { $0.state == .completed } }
        #expect(await source.calls == [1, 1, 1, 1, 1, 2, 3])
        #expect(try await queue.retryFailed([episode(1).key, episode(2).key]) == 0)
        #expect(try await queue.localURL(for: episode(1).key) != nil)
    }

    @Test func otherScopesContinueAndCancellingFirstWaiterPreservesRemainingBudget() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RecoveryGate(), source = RecoveryProvider(failures: ["REGISTRATION_NETWORK_ERROR"])
        let queue = try library(directory, gate, source)
        try await queue.enqueue([episode(1), episode(2), episode(3, scope: "other")])
        try await wait { await queue.snapshot().last?.state == .completed }
        #expect(await source.calls == [1, 3])
        #expect(await queue.snapshot().prefix(2).map(\.state) == [.waiting, .waiting])
        try await queue.cancel(episode(1).key)
        #expect(await queue.snapshot()[1].sourceRetryAttempt == 1)
        await gate.release()
        try await wait { await queue.snapshot().map(\.state) == [.cancelled, .completed, .completed] }
        #expect(await source.calls == [1, 3, 2])
    }

    @Test func manualRetryDuringCooldownCannotBypassTheSharedWait() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RecoveryGate(), source = RecoveryProvider(failures: ["HTTP_403", "REGISTRATION_TIMEOUT"])
        let queue = try library(directory, gate, source)
        try await queue.enqueue([episode(1), episode(2)])
        try await wait { await gate.delays.count == 1 }
        #expect(try await queue.retryFailed([episode(1).key]) == 1)
        #expect(await queue.snapshot().map(\.state) == [.waiting, .waiting])
        #expect(await source.calls == [1, 2])
        await gate.release()
        try await wait { await queue.snapshot().allSatisfy { $0.state == .completed } }
        #expect(await source.calls == [1, 2, 2, 1])
    }

    @Test func exhaustedPauseSurvivesReopenAndNeedsExplicitRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RecoveryGate(), source = RecoveryProvider(failures: Array(repeating: "REGISTRATION_TIMEOUT", count: 4))
        let queue = try library(directory, gate, source)
        try await queue.enqueue([episode(1), episode(2)])
        for count in 1...3 {
            try await wait { await gate.delays.count == count }
            await gate.release()
        }
        try await wait { await queue.snapshot().allSatisfy { $0.state == .paused } }
        let nextGate = RecoveryGate(), nextSource = RecoveryProvider(failures: [])
        let reopened = try library(directory, nextGate, nextSource)
        await reopened.start()
        #expect(await reopened.snapshot().allSatisfy { $0.state == .paused && $0.canRetryFailedDownload })
        #expect(await nextSource.calls.isEmpty)
        #expect(await nextGate.delays.isEmpty)
        try await reopened.retry(episode(1).key)
        try await wait { await reopened.snapshot().first { $0.key == episode(1).key }?.state == .completed }
        #expect(await reopened.snapshot().first { $0.key == episode(2).key }?.state == .paused)
        #expect(await nextSource.calls == [1])
    }

    @Test(arguments: [false, true])
    func cancellingOrDeletingAllWaitersCancelsTimerAndCannotResurrectWork(delete: Bool) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = RecoveryGate(), source = RecoveryProvider(failures: ["REGISTRATION_HTTP_503"])
        let queue = try library(directory, gate, source)
        try await queue.enqueue([episode(1), episode(2)])
        try await wait { await gate.delays.count == 1 }
        if delete { try await queue.deleteSeries(scope: "public", seriesID: "40") }
        else {
            try await queue.cancel(episode(1).key)
            try await queue.cancel(episode(2).key)
        }
        try await wait { await gate.cancellations == 1 }
        await gate.release() // A late timer completion cannot restore deleted/cancelled rows.
        await queue.start()
        #expect(await source.calls == [1])
        #expect(await queue.snapshot().allSatisfy { $0.state == .cancelled })
        try await queue.enqueue(episode(3))
        try await wait { await queue.snapshot().last?.state == .completed }
    }

    @Test func reopenRetainsWaitAndBudgetThenSuccessResetsBudgetForNextEpisode() async throws {
        let directory = temporaryDirectory(), reopenedDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: reopenedDirectory)
        }
        let gate = RecoveryGate(), source = RecoveryProvider(failures: ["REGISTRATION_UNAVAILABLE"])
        let queue = try library(directory, gate, source)
        try await queue.enqueue([episode(1), episode(2)])
        try await wait { await gate.delays.count == 1 }
        try FileManager.default.copyItem(at: directory, to: reopenedDirectory)
        try await queue.cancel(episode(1).key)
        try await queue.cancel(episode(2).key)

        let nextGate = RecoveryGate(), nextSource = RecoveryProvider(failures: [nil, "REGISTRATION_TIMEOUT"])
        let reopened = try library(reopenedDirectory, nextGate, nextSource)
        #expect(await reopened.snapshot().map(\.state) == [.waiting, .waiting])
        #expect(await reopened.snapshot().map(\.sourceRetryAttempt) == [1, 1])
        await reopened.start()
        try await wait { await nextGate.delays.count == 1 }
        #expect(await nextSource.calls.isEmpty)
        await nextGate.release()
        try await wait { await nextGate.delays.count == 2 }
        #expect(await reopened.snapshot().map(\.state) == [.completed, .waiting])
        #expect(await reopened.snapshot().last?.sourceRetryAttempt == 1)
        #expect(await nextGate.delays == [.seconds(10), .seconds(10)])
        try await reopened.recordProgress(for: episode(1).key, position: 12, duration: 30)
        #expect(try await reopened.localURL(for: episode(1).key) != nil)
        #expect(await reopened.snapshot().last?.state == .waiting)
        await nextGate.release()
        try await wait { await reopened.snapshot().allSatisfy { $0.state == .completed } }
        #expect(await reopened.snapshot().first?.position == 12)
        #expect(await nextSource.calls == [1, 2, 2])
    }

    private func library(_ directory: URL, _ gate: RecoveryGate, _ source: RecoveryProvider) throws -> OfflineDownloads {
        try OfflineDownloads(directory: directory, now: { Date(timeIntervalSince1970: 2_000_000_000) },
            sleep: { try await gate.sleep($0) }, provider: { item, destination, _, _ in
                try await source.download(item, to: destination)
            })
    }

    private func episode(_ number: Int, scope: String = "public") -> OfflineDownloadItem {
        .init(key: .init(scope: scope, seriesID: "40", episodeID: String(number)),
              seriesTitle: "測試劇集", episodeNumber: number)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw RecoveryTestError.timeout
    }
}

private enum RecoveryTestError: Error { case timeout }

private actor RecoveryProvider {
    private var failures: [String?]
    private(set) var calls: [Int] = []
    init(failures: [String?]) { self.failures = failures }
    func download(_ item: OfflineDownloadItem, to destination: URL) throws {
        calls.append(item.episodeNumber)
        if !failures.isEmpty, let code = failures.removeFirst() { throw NativeSourceError(code: code) }
        try Data([1, 2, 3, 4, 5, 6]).write(to: destination)
    }
}

private actor RecoveryGate {
    private(set) var delays: [Duration] = []
    private(set) var cancellations = 0
    private var pending: [Int: CheckedContinuation<Void, any Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        let id = delays.count
        delays.append(duration)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pending[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() { if let id = pending.keys.min() { pending.removeValue(forKey: id)?.resume() } }
    private func cancel(_ id: Int) {
        cancellations += 1
        pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }
}
