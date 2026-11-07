// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private final class SourceCacheClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}
private actor SourceCounter {
    var calls = 0
    func next() -> Int { calls += 1; return calls }
}

private actor SourceFlightGate {
    struct Call: Sendable { let id: Int; let episode: String; let contentType: String; let quality: NativePlaybackQuality }
    private(set) var calls: [Call] = []
    private(set) var cancelled: Set<Int> = []
    private var continuations: [Int: CheckedContinuation<NativeMediaSource, any Error>] = [:]
    func resolve(_ episode: String, _ contentType: String, _ quality: NativePlaybackQuality) async throws -> NativeMediaSource {
        let id = calls.count + 1
        calls.append(.init(id: id, episode: episode, contentType: contentType, quality: quality))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuations[id] = $0 }
        } onCancel: { Task { await self.noteCancellation(id) } }
    }
    private func noteCancellation(_ id: Int) { cancelled.insert(id) }
    func succeed(_ id: Int, source: NativeMediaSource) { continuations.removeValue(forKey: id)?.resume(returning: source) }
    func fail(_ id: Int, code: String) { continuations.removeValue(forKey: id)?.resume(throwing: NativeSourceError(code: code)) }
}

private final class WeakSourceResolver: @unchecked Sendable {
    weak var value: NativeSourceResolver?
    init(_ value: NativeSourceResolver?) { self.value = value }
}

private enum SourceFlightTestError: Error { case conditionTimedOut }

struct NativeSourceCacheTests {
    private func source(_ count: Int, preference: NativePlaybackQuality = .automatic) -> NativeMediaSource {
        .init(url: URL(string: "https://unit.fqnovelvod.com/video.mp4")!, contentKey: nil, userAgent: "Fixture", codec: "h264", quality: String(count), preference: preference)
    }
    @Test func successCacheHasTTLAndFreshBypassAndContentTypeIsolation() async throws {
        let clock = SourceCacheClock(), counter = SourceCounter()
        let resolver = NativeSourceResolver(now: { clock.now() }, resolve: { _, _ in source(await counter.next()) })
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(try await resolver.resolve(episodeID: "100", fresh: true).quality == "2")
        #expect(try await resolver.resolve(episodeID: "100", contentType: "1006").quality == "3")
        clock.advance(121)
        #expect(try await resolver.resolve(episodeID: "100").quality == "4")
    }
    @Test func sixteenEntryLimitUsesLRUAndCancellationCannotPopulateCache() async throws {
        let counter = SourceCounter()
        let resolver = NativeSourceResolver(resolve: { _, _ in source(await counter.next()) })
        for id in 100..<116 { _ = try await resolver.resolve(episodeID: String(id)) }
        _ = try await resolver.resolve(episodeID: "100")
        _ = try await resolver.resolve(episodeID: "116")
        #expect(await counter.calls == 17)
        _ = try await resolver.resolve(episodeID: "101")
        #expect(await counter.calls == 18)
        let cancelledCounter = SourceCounter()
        let cancelledResolver = NativeSourceResolver(resolve: { _, _ in
            let count = await cancelledCounter.next()
            if count == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            return source(count)
        })
        let task = Task { try await cancelledResolver.resolve(episodeID: "100") }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try await cancelledResolver.resolve(episodeID: "100").quality == "2")
    }

    @Test func overlappingNonFreshConsumersShareOneResolutionAndItsCompletedCache() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let first = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 1 }
        let second = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await resolver.pendingWaiterCount == 2 }
        #expect(await gate.calls.count == 1)
        #expect(await resolver.pendingFlightCount == 1)
        await gate.succeed(1, source: source(1))
        #expect(try await first.value.quality == "1")
        #expect(try await second.value.quality == "1")
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(await gate.calls.count == 1)
        #expect(await resolver.pendingWaiterCount == 0)
        #expect(await resolver.pendingFlightCount == 0)
    }

    @Test func cancellingOneConsumerDoesNotCancelTheOtherConsumerOrTheSharedWorker() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let prefetch = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 1 }
        let foreground = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await resolver.pendingWaiterCount == 2 }
        prefetch.cancel()
        await #expect(throws: CancellationError.self) { try await prefetch.value }
        #expect(await gate.cancelled.isEmpty)
        #expect(await resolver.pendingWaiterCount == 1)
        await gate.succeed(1, source: source(1))
        #expect(try await foreground.value.quality == "1")
        #expect(try await resolver.resolve(episodeID: "100").quality == "1")
        #expect(await gate.calls.count == 1)
    }

    @Test func allCancelledConsumersCancelTheWorkerAndLateCompletionCannotClearANewerFlight() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let first = Task { try await resolver.resolve(episodeID: "100") }
        let second = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await resolver.pendingWaiterCount == 2 }
        first.cancel(); second.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        try await wait { await gate.cancelled.contains(1) }
        let newer = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 2 }
        await gate.succeed(1, source: source(1))
        try await wait { await resolver.pendingFlightCount == 1 }
        #expect(await resolver.pendingWaiterCount == 1)
        let joined = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await resolver.pendingWaiterCount == 2 }
        #expect(await gate.calls.count == 2)
        await gate.succeed(2, source: source(2))
        #expect(try await newer.value.quality == "2")
        #expect(try await joined.value.quality == "2")
        #expect(try await resolver.resolve(episodeID: "100").quality == "2")
        #expect(await gate.calls.count == 2)
    }

    @Test func freshRunsIndependentlyAndAnOlderSuccessfulFlightCannotReplaceItsCache() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let old = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 1 }
        let fresh = Task { try await resolver.resolve(episodeID: "100", fresh: true) }
        try await wait { await gate.calls.count == 2 }
        let newerFresh = Task { try await resolver.resolve(episodeID: "100", fresh: true) }
        try await wait { await gate.calls.count == 3 }
        await gate.succeed(3, source: source(3))
        #expect(try await newerFresh.value.quality == "3")
        await gate.succeed(2, source: source(2))
        #expect(try await fresh.value.quality == "2")
        await gate.succeed(1, source: source(1))
        #expect(try await old.value.quality == "1")
        #expect(try await resolver.resolve(episodeID: "100").quality == "3")
        #expect(await gate.calls.count == 3)
        #expect(await gate.cancelled.isEmpty)
    }

    @Test func lastConsumerCancellationRacingWithCompletionCannotPopulateTheCache() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let first = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 1 }
        first.cancel()
        // Do not wait for actor-side cancellation cleanup before the producer completes.
        await gate.succeed(1, source: source(1))
        await #expect(throws: CancellationError.self) { try await first.value }
        try await wait { await resolver.pendingFlightCount == 0 }
        let next = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 2 }
        await gate.succeed(2, source: source(2))
        #expect(try await next.value.quality == "2")
        #expect(try await resolver.resolve(episodeID: "100").quality == "2")
    }

    @Test func failedOrCancelledFreshDoesNotRestoreAnOlderSourceToCache() async throws {
        for failure in ["HTTP_401", "HTTP_403", "CANCELLED"] {
            let gate = SourceFlightGate(), resolver = resolver(gate)
            let old = Task { try await resolver.resolve(episodeID: "100") }
            try await wait { await gate.calls.count == 1 }
            let fresh = Task { try await resolver.resolve(episodeID: "100", fresh: true) }
            try await wait { await gate.calls.count == 2 }
            if failure == "CANCELLED" {
                fresh.cancel()
                await #expect(throws: CancellationError.self) { try await fresh.value }
                await gate.succeed(2, source: source(2))
            } else {
                await gate.fail(2, code: failure)
                await #expect(throws: NativeSourceError.self) { try await fresh.value }
            }
            await gate.succeed(1, source: source(1))
            #expect(try await old.value.quality == "1")
            let subsequent = Task { try await resolver.resolve(episodeID: "100") }
            try await wait { await gate.calls.count == 3 }
            await gate.succeed(3, source: source(3))
            #expect(try await subsequent.value.quality == "3")
        }
    }

    @Test func aFreshBoundaryPreventsNewConsumersFromJoiningAnOlderGeneration() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let old = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 1 }
        let fresh = Task { try await resolver.resolve(episodeID: "100", fresh: true) }
        try await wait { await gate.calls.count == 2 }
        let newer = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await gate.calls.count == 3 }
        await gate.succeed(1, source: source(1))
        #expect(try await old.value.quality == "1")
        let joined = Task { try await resolver.resolve(episodeID: "100") }
        try await wait { await resolver.pendingWaiterCount == 3 }
        #expect(await gate.calls.count == 3)
        await gate.succeed(2, source: source(2))
        #expect(try await fresh.value.quality == "2")
        await gate.succeed(3, source: source(3))
        #expect(try await newer.value.quality == "3")
        #expect(try await joined.value.quality == "3")
        #expect(try await resolver.resolve(episodeID: "100").quality == "3")
    }

    @Test func episodeContentTypeAndRequestedQualityRemainSeparateKeys() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let inputs: [(String, String, NativePlaybackQuality)] = [
            ("100", "1004", .automatic), ("100", "1005", .automatic),
            ("100", "1004", .dataSaver), ("101", "1004", .automatic)
        ]
        var tasks: [Task<NativeMediaSource, any Error>] = []
        for (index, input) in inputs.enumerated() {
            tasks.append(Task { try await resolver.resolve(episodeID: input.0, contentType: input.1, quality: input.2) })
            try await wait { await gate.calls.count == index + 1 }
        }
        for (index, input) in inputs.enumerated() { await gate.succeed(index + 1, source: source(index + 1, preference: input.2)) }
        for (index, task) in tasks.enumerated() { #expect(try await task.value.quality == String(index + 1)) }
        for (index, input) in inputs.enumerated() {
            #expect(try await resolver.resolve(episodeID: input.0, contentType: input.1, quality: input.2).quality == String(index + 1))
        }
        #expect(await gate.calls.count == 4)
    }

    @Test func authorizationAndNetworkFailuresAreSharedOnceWithoutRetryOrFailureCaching() async throws {
        for code in ["HTTP_401", "HTTP_403", "ERR_NETWORK", "INVALID_RESPONSE"] {
            let gate = SourceFlightGate(), resolver = resolver(gate)
            let first = Task { try await resolver.resolve(episodeID: "100") }
            let second = Task { try await resolver.resolve(episodeID: "100") }
            try await wait { await resolver.pendingWaiterCount == 2 }
            try await wait { await gate.calls.count == 1 }
            await gate.fail(1, code: code)
            for task in [first, second] {
                do { _ = try await task.value; Issue.record("Source failure was ignored") }
                catch let error as NativeSourceError { #expect(error.code == code) }
            }
            #expect(await gate.calls.count == 1)
            #expect(await resolver.pendingFlightCount == 0)
            let explicitNext = Task { try await resolver.resolve(episodeID: "100") }
            try await wait { await gate.calls.count == 2 }
            await gate.succeed(2, source: source(2))
            #expect(try await explicitNext.value.quality == "2")
        }
    }

    @Test func aMismatchedReturnedQualityIsRejectedAndCannotPoisonTheCache() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        let wrong = Task { try await resolver.resolve(episodeID: "100", quality: .dataSaver) }
        try await wait { await gate.calls.count == 1 }
        await gate.succeed(1, source: source(1))
        do { _ = try await wrong.value; Issue.record("Mismatched quality accepted") }
        catch let error as NativeSourceError { #expect(error.code == "INVALID_RESPONSE") }
        let correct = Task { try await resolver.resolve(episodeID: "100", quality: .dataSaver) }
        try await wait { await gate.calls.count == 2 }
        await gate.succeed(2, source: source(2, preference: .dataSaver))
        #expect(try await correct.value.quality == "2")
    }

    @Test func pendingWorkersAndWaitersStayBoundedEvenWhileCancelledWorkersIgnoreCancellation() async throws {
        let gate = SourceFlightGate(), resolver = resolver(gate)
        var tasks: [Task<NativeMediaSource, any Error>] = []
        for index in 0..<NativeSourceResolver.maximumPendingFlights {
            tasks.append(Task { try await resolver.resolve(episodeID: String(100 + index)) })
        }
        try await wait { await gate.calls.count == NativeSourceResolver.maximumPendingFlights }
        do { _ = try await resolver.resolve(episodeID: "999"); Issue.record("Pending worker cap ignored") }
        catch let error as NativeSourceError { #expect(error.code == "SOURCE_BUSY") }
        for _ in 1..<NativeSourceResolver.maximumWaitersPerFlight {
            tasks.append(Task { try await resolver.resolve(episodeID: "100") })
        }
        let total = NativeSourceResolver.maximumPendingFlights + NativeSourceResolver.maximumWaitersPerFlight - 1
        try await wait { await resolver.pendingWaiterCount == total }
        do { _ = try await resolver.resolve(episodeID: "100"); Issue.record("Waiter cap ignored") }
        catch let error as NativeSourceError { #expect(error.code == "SOURCE_BUSY") }
        tasks.forEach { $0.cancel() }
        for task in tasks { await #expect(throws: CancellationError.self) { try await task.value } }
        do { _ = try await resolver.resolve(episodeID: "999"); Issue.record("Cancelled worker still consumes resources") }
        catch let error as NativeSourceError { #expect(error.code == "SOURCE_BUSY") }
        #expect(await gate.calls.count == NativeSourceResolver.maximumPendingFlights)
        for id in 1...NativeSourceResolver.maximumPendingFlights { await gate.succeed(id, source: source(id)) }
        try await wait { await resolver.pendingFlightCount == 0 }
        let recovered = Task { try await resolver.resolve(episodeID: "999") }
        try await wait { await gate.calls.count == NativeSourceResolver.maximumPendingFlights + 1 }
        await gate.succeed(NativeSourceResolver.maximumPendingFlights + 1, source: source(99))
        #expect(try await recovered.value.quality == "99")
    }

    @Test func cancelledConsumersDoNotKeepTheResolverAliveThroughAnUncooperativeWorker() async throws {
        let gate = SourceFlightGate()
        var value: NativeSourceResolver? = resolver(gate)
        let weak = WeakSourceResolver(value)
        let task = resolveWithOwner(try #require(value))
        try await wait { await gate.calls.count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        value = nil
        try await wait { weak.value == nil }
        await gate.succeed(1, source: source(1))
    }

    private func resolver(_ gate: SourceFlightGate) -> NativeSourceResolver {
        NativeSourceResolver(resolveQuality: { try await gate.resolve($0, $1, $2) })
    }
    private func resolveWithOwner(_ resolver: NativeSourceResolver) -> Task<NativeMediaSource, any Error> {
        Task { try await resolver.resolve(episodeID: "100") }
    }
    private func wait(_ condition: @Sendable () async -> Bool) async throws {
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard clock.now < deadline else { throw SourceFlightTestError.conditionTimedOut }
            await Task.yield()
        }
    }
}
