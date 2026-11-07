import Foundation
import Testing
@testable import HongguoCore
@testable import HongguoAppSupport

@MainActor
struct LibraryBrowserModelTests {
    @Test func sameCompletedContextReturnsImmediatelyWithoutAnotherCPURequest() async throws {
        let gate = BrowserProcessorGate(), model = LibraryBrowserModel { await gate.process($0) }
        let value = input("A")
        model.update(value); try await waitForCalls(gate, 1)
        await gate.release(1); try await ready(model, value)
        model.cancel()
        #expect(!model.isCurrent(value))
        model.update(value)
        #expect(model.isCurrent(value))
        #expect(model.favorites.map(\.id) == ["100"])
        #expect(await gate.count == 1)
    }

    @Test func cancelledPendingWorkIsNeverACacheHit() async throws {
        let gate = BrowserProcessorGate(), model = LibraryBrowserModel { await gate.process($0) }
        let value = input("A")
        model.update(value); try await waitForCalls(gate, 1)
        model.cancel(); await gate.release(1)
        for _ in 0..<100 { await Task.yield() }
        #expect(model.favorites.isEmpty)
        model.update(value)
        #expect(model.isProcessing)
        try await waitForCalls(gate, 2)
        await gate.release(2); try await ready(model, value)
    }

    @Test func changingOwnerOrSourceClearsCompletedCacheAndOldRowsSynchronously() async throws {
        let gate = BrowserProcessorGate(), model = LibraryBrowserModel { await gate.process($0) }
        let a = input("A"), b = input("A", owner: .account(id: "42")), c = input("A", owner: .account(id: "42"), source: UUID())
        model.update(a); try await waitForCalls(gate, 1); await gate.release(1); try await ready(model, a)
        model.cancel(); model.update(b)
        #expect(model.isProcessing && model.favorites.isEmpty)
        try await waitForCalls(gate, 2); await gate.release(2); try await ready(model, b)
        model.update(c)
        #expect(model.isProcessing && model.favorites.isEmpty)
        try await waitForCalls(gate, 3); await gate.release(3); try await ready(model, c)
        model.cancel(); model.update(a)
        #expect(model.isProcessing)
        try await waitForCalls(gate, 4); await gate.release(4); try await ready(model, a)
    }

    @Test func dataSortAndFilterChangesMissAndOnlyOneCompletedEntryIsRetained() async throws {
        let gate = BrowserProcessorGate(), model = LibraryBrowserModel { await gate.process($0) }
        let variants = [input("A"), input("B"), input("B", sort: .titleAscending), input("B", sort: .titleAscending, filter: .completed),
                        input("B", sort: .titleAscending, filter: .completed, title: "更新資料"), input("A")]
        for (index, value) in variants.enumerated() {
            model.cancel(); model.update(value)
            #expect(model.isProcessing)
            try await waitForCalls(gate, index + 1)
            await gate.release(index + 1); try await ready(model, value)
        }
        #expect(await gate.count == variants.count)
    }

    @Test func completedCacheCanResumeWhileUnrelatedOldWorkFinishesWithoutPublishingIt() async throws {
        let gate = BrowserProcessorGate(), model = LibraryBrowserModel { await gate.process($0) }
        let a = input("A"), b = input("B"), c = input("C")
        model.update(a); try await waitForCalls(gate, 1); await gate.release(1); try await ready(model, a)
        model.update(b); try await waitForCalls(gate, 2)
        model.cancel(); model.update(a)
        #expect(model.isCurrent(a))
        await gate.release(2)
        for _ in 0..<100 { await Task.yield() }
        #expect(model.isCurrent(a))
        model.update(c); try await waitForCalls(gate, 3)
        await gate.release(3); try await ready(model, c)
    }

    @Test func aRunningPassAndRapidUpdatesKeepOnlyOneLatestPendingPass() async throws {
        let gate = BrowserProcessorGate(), model = LibraryBrowserModel { await gate.process($0) }
        let a = input("A"), b = input("B"), c = input("C")
        model.update(a); try await waitForCalls(gate, 1)
        model.update(b); model.update(c)
        for _ in 0..<100 { await Task.yield() }
        #expect(await gate.count == 1)
        await gate.release(1); try await waitForCalls(gate, 2)
        #expect(await gate.query(at: 2) == "C")
        await gate.release(2); try await ready(model, c)
        #expect(!model.isCurrent(a) && !model.isCurrent(b))
    }

    private let source = UUID()
    private func input(_ query: String, owner: LibraryOwner = .guest, source: UUID? = nil,
                       sort: LibraryFavoriteSort = .storedOrder, filter: LibraryBrowserFilter = .all,
                       title: String = "測試劇") -> LibraryBrowserInput {
        .init(owner: owner, source: source ?? self.source, showingHistory: false, query: query,
              favoriteSort: sort, historySort: .recent, filter: filter,
              favorites: [.init(id: "100", title: title)], history: [])
    }
    private func waitForCalls(_ gate: BrowserProcessorGate, _ count: Int) async throws {
        for _ in 0..<20_000 { if await gate.count >= count { return }; await Task.yield() }
        Issue.record("The serial browser worker did not start its expected pass")
        throw BrowserTestError.timeout
    }
    private func ready(_ model: LibraryBrowserModel, _ value: LibraryBrowserInput) async throws {
        for _ in 0..<20_000 { if model.isCurrent(value) { return }; await Task.yield() }
        Issue.record("The current browser pass did not publish")
        throw BrowserTestError.timeout
    }
}

private enum BrowserTestError: Error { case timeout }
private actor BrowserProcessorGate {
    private(set) var count = 0
    private var requests: [Int: LibraryBrowserInput] = [:]
    private var gates: [Int: CheckedContinuation<LibraryBrowserOutput, Never>] = [:]
    func process(_ input: LibraryBrowserInput) async -> LibraryBrowserOutput {
        count += 1; let index = count; requests[index] = input
        return await withCheckedContinuation { gates[index] = $0 }
    }
    func release(_ index: Int) {
        guard let input = requests[index], let gate = gates.removeValue(forKey: index) else { return }
        gate.resume(returning: .init(favorites: input.favorites, history: input.history))
    }
    func query(at index: Int) -> String? { requests[index]?.query }
}
