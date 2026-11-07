import Foundation
import CryptoKit

public enum LibraryStorageError: Error, LocalizedError, Equatable, Sendable {
    case unreadable, tooLarge, writeFailed, revisionConflict
    public var errorDescription: String? {
        switch self {
        case .unreadable: "片庫資料暫時無法讀取。原始資料已保留，請稍後重試。"
        case .tooLarge: "片庫超過儲存容量上限，原有資料已保留。"
        case .writeFailed: "片庫暫時無法儲存，原有檔案已保留，請稍後重試。"
        case .revisionConflict: "片庫變更順序不符，已停止覆寫原有資料。"
        }
    }
}

protocol LibrarySnapshotIO: Sendable {
    func load(scope: LibraryScope, legacy: Data?) async throws -> LibraryState
    func save(_ state: LibraryState) async throws
}

/// Encoding and protected atomic disk operations are isolated from the main actor.
actor LibrarySnapshotDisk: LibrarySnapshotIO {
    let directory: URL
    let maximumBytes: Int
    init(directory: URL, maximumBytes: Int = 32 * 1024 * 1024) {
        self.directory = directory; self.maximumBytes = maximumBytes
    }
    static func fileURL(scope: LibraryScope, directory: URL) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }
    func load(scope: LibraryScope, legacy: Data?) throws -> LibraryState {
        let url = try Self.fileURL(scope: scope, directory: directory)
        let backup = url.appendingPathExtension("previous")
        if FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: backup.path) {
            if let state = try? decode(read(url), scope: scope) { return state }
            if let state = try? decode(read(backup), scope: scope) { return state }
            throw LibraryStorageError.unreadable
        }
        let snapshot: LibrarySnapshot
        if let legacy {
            guard legacy.count <= maximumBytes else { throw LibraryStorageError.tooLarge }
            do { snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: legacy) }
            catch { throw LibraryStorageError.unreadable }
        } else { snapshot = .init() }
        let state = try LibraryState(scope: scope, snapshot: snapshot)
        try save(state)
        return state
    }
    func save(_ state: LibraryState) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= maximumBytes else { throw LibraryStorageError.tooLarge }
        do {
            let url = try Self.fileURL(scope: state.scope, directory: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // A failed backup write cannot replace the primary. An invalid primary never replaces a valid backup.
            if let old = try? read(url), (try? decode(old, scope: state.scope)) != nil {
                try write(old, to: url.appendingPathExtension("previous"))
            }
            try write(data, to: url)
        } catch let error as LibraryStorageError { throw error }
        catch { throw LibraryStorageError.writeFailed }
    }
    private func read(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.int64Value <= maximumBytes else { throw LibraryStorageError.tooLarge }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw LibraryStorageError.tooLarge }
        return data
    }
    private func decode(_ data: Data, scope: LibraryScope) throws -> LibraryState {
        let state = try JSONDecoder().decode(LibraryState.self, from: data)
        guard state.scope == scope else { throw UserLibraryError.scopeMismatch }
        return state
    }
    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Serial background durability with per-scope revisions and coalescing of queued snapshots.
/// A successful save means this revision, or a newer snapshot containing it, reached disk.
public actor LibrarySnapshotStore {
    private struct Snapshot: Sendable { let state: LibraryState; let revision: UInt64 }
    private struct Waiter { let revision: UInt64; let completion: CheckedContinuation<Void, any Error> }
    private let io: any LibrarySnapshotIO
    private var latest: [LibraryScope: Snapshot] = [:]
    private var durable: [LibraryScope: UInt64] = [:]
    private var pending: [LibraryScope: Snapshot] = [:]
    private var inFlight: [LibraryScope: UInt64] = [:]
    private var order: [LibraryScope] = []
    private var waiters: [LibraryScope: [Waiter]] = [:]
    private var worker: Task<Void, Never>?

    public init(directory: URL) { io = LibrarySnapshotDisk(directory: directory) }
    init(io: any LibrarySnapshotIO) { self.io = io }

    func latestRequestedRevision(for scope: LibraryScope) -> UInt64 { latest[scope]?.revision ?? 0 }

    public func load(scope: LibraryScope, legacy: Data? = nil) async throws -> LibraryState {
        if let latest = latest[scope] { return latest.state }
        let state = try await io.load(scope: scope, legacy: legacy)
        return latest[scope]?.state ?? state
    }

    public func save(_ state: LibraryState, revision: UInt64) async throws {
        guard revision > 0 else { throw LibraryStorageError.revisionConflict }
        let scope = state.scope
        if let previous = latest[scope], previous.revision == revision, previous.state != state {
            throw LibraryStorageError.revisionConflict
        }
        if latest[scope].map({ $0.revision < revision }) ?? true {
            latest[scope] = Snapshot(state: state, revision: revision)
        }
        if durable[scope, default: 0] >= revision { return }
        try await withCheckedThrowingContinuation { completion in
            waiters[scope, default: []].append(Waiter(revision: revision, completion: completion))
            if let newest = latest[scope], inFlight[scope] != newest.revision {
                pending[scope] = newest
                if !order.contains(scope) { order.append(scope) }
            }
            if worker == nil { worker = Task { await self.drain() } }
        }
    }

    private func drain() async {
        while !order.isEmpty {
            let scope = order.removeFirst()
            guard let snapshot = pending.removeValue(forKey: scope) else { continue }
            inFlight[scope] = snapshot.revision
            do {
                try await io.save(snapshot.state)
                durable[scope] = max(durable[scope, default: 0], snapshot.revision)
                let completed = waiters[scope, default: []].filter { $0.revision <= snapshot.revision }
                waiters[scope] = waiters[scope, default: []].filter { $0.revision > snapshot.revision }
                completed.forEach { $0.completion.resume() }
            } catch {
                // Newer pending data can still satisfy older durability barriers.
                if pending[scope] == nil {
                    let failed = waiters.removeValue(forKey: scope) ?? []
                    failed.forEach { $0.completion.resume(throwing: error) }
                }
            }
            inFlight.removeValue(forKey: scope)
        }
        worker = nil
    }
}
