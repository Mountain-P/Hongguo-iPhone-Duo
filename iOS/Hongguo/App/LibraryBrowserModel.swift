import Combine
import Foundation
import HongguoCore

enum LibraryBrowserFilter: Equatable, Sendable { case all, inProgress, completed }

struct LibraryBrowserInput: Equatable, Sendable {
    let owner: LibraryOwner
    let source: UUID
    let showingHistory: Bool
    let query: String
    let favoriteSort: LibraryFavoriteSort
    let historySort: LibraryHistorySort
    let filter: LibraryBrowserFilter
    let favorites: [Series]
    let history: [WatchRecord]

    func differsOnlyInSorting(from previous: Self) -> Bool {
        (favoriteSort != previous.favoriteSort || historySort != previous.historySort)
            && owner == previous.owner && source == previous.source && showingHistory == previous.showingHistory
            && query == previous.query && filter == previous.filter
            && favorites == previous.favorites && history == previous.history
    }
}

struct LibraryBrowserOutput: Sendable {
    var favorites: [Series] = []
    var history: [WatchRecord] = []
}

/// One non-main executor processes at most one snapshot; no per-keystroke CPU tasks.
private actor LibraryBrowserWorker {
    func process(_ input: LibraryBrowserInput) -> LibraryBrowserOutput {
        if input.showingHistory {
            let filter: LibraryHistoryFilter = switch input.filter {
            case .all: .all; case .inProgress: .inProgress; case .completed: .completed
            }
            return .init(history: LibraryBrowser.history(input.history, query: input.query, filter: filter, sort: input.historySort))
        }
        return .init(favorites: LibraryBrowser.favorites(input.favorites, query: input.query, sort: input.favoriteSort))
    }
}

@MainActor
final class LibraryBrowserModel: ObservableObject {
    @Published private(set) var favorites: [Series] = []
    @Published private(set) var history: [WatchRecord] = []
    @Published private(set) var isProcessing = false
    private let process: @Sendable (LibraryBrowserInput) async -> LibraryBrowserOutput
    private let debounceDelay: Duration
    private var completed: (LibraryBrowserInput, LibraryBrowserOutput)?
    private var input: LibraryBrowserInput?
    private var generation = UUID()
    private var pending: (LibraryBrowserInput, UUID)?
    private var debounce: Task<Void, Never>?
    private var operation: Task<Void, Never>?

    init() {
        let worker = LibraryBrowserWorker()
        process = { await worker.process($0) }
        debounceDelay = .milliseconds(180)
    }

    init(debounceDelay: Duration = .zero,
         process: @escaping @Sendable (LibraryBrowserInput) async -> LibraryBrowserOutput) {
        self.process = process; self.debounceDelay = debounceDelay
    }

    func isCurrent(_ value: LibraryBrowserInput) -> Bool { !isProcessing && input == value }
    func isSameScope(_ value: LibraryBrowserInput) -> Bool {
        input?.owner == value.owner && input?.source == value.source && input?.showingHistory == value.showingHistory
    }

    func update(_ value: LibraryBrowserInput) {
        guard input != value else { return }
        let previous = input
        let typing = previous != nil && previous?.query != value.query
        if let accepted = completed, accepted.0.owner != value.owner || accepted.0.source != value.source { completed = nil }
        input = value; generation = UUID(); pending = nil
        debounce?.cancel(); debounce = nil
        if let accepted = completed, accepted.0 == value {
            favorites = accepted.1.favorites; history = accepted.1.history
            isProcessing = false
            return
        }
        if previous?.owner != value.owner || previous?.source != value.source || previous?.showingHistory != value.showingHistory {
            favorites = []; history = []
        }
        isProcessing = true
        let token = generation
        debounce = Task { @MainActor [weak self] in
            if typing {
                do { try await Task.sleep(for: self?.debounceDelay ?? .zero) } catch { return }
            }
            guard let self, !Task.isCancelled, self.generation == token, self.input == value else { return }
            self.debounce = nil
            self.pending = (value, token)
            self.startWorker()
        }
    }

    func cancel() {
        generation = UUID(); input = nil; pending = nil
        debounce?.cancel(); debounce = nil
        // A synchronous CPU pass cannot be interrupted. Its lease is revoked;
        // keep the single worker until it returns rather than starting another.
        isProcessing = false
    }

    private func startWorker() {
        guard operation == nil else { return }
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.operation = nil }
            while let (value, token) = self.pending {
                self.pending = nil
                let result = await self.process(value)
                guard self.generation == token, self.input == value else { continue }
                self.completed = (value, result)
                self.favorites = result.favorites; self.history = result.history
                self.isProcessing = false
            }
        }
    }
}
