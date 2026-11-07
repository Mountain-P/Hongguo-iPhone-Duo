import Foundation
import HongguoCore

/// Each source/account owns a protected snapshot; all encoding and IO runs off the main actor.
struct LibraryPersistence: Sendable {
    private let store: LibrarySnapshotStore

    init(store: LibrarySnapshotStore) { self.store = store }

    init(directory: URL? = nil) {
        let directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UserLibraries", isDirectory: true)
        store = LibrarySnapshotStore(directory: directory)
    }

    func load(scope: LibraryScope, legacy: Data? = nil) async throws -> LibraryState {
        try await store.load(scope: scope, legacy: legacy)
    }

    func save(_ state: LibraryState, revision: UInt64) async throws {
        try await store.save(state, revision: revision)
    }
}
