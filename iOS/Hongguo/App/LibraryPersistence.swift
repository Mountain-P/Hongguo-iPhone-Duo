import Foundation
import CryptoKit
import HongguoCore

/// Each source and account has its own protected snapshot. Authentication stays in Keychain.
struct LibraryPersistence {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UserLibraries", isDirectory: true)
    }

    func load(scope: LibraryScope, legacy: Data? = nil) throws -> LibraryState {
        let url = try fileURL(scope: scope)
        if FileManager.default.fileExists(atPath: url.path) {
            do { return try decode(Data(contentsOf: url), scope: scope) }
            catch {
                // Preserve the damaged primary file for recovery; never silently replace it with an empty library.
                let backup = url.appendingPathExtension("previous")
                if let data = try? Data(contentsOf: backup), let state = try? decode(data, scope: scope) { return state }
                throw AppError.message("片庫資料暫時無法讀取。原始資料已保留，請稍後重試。")
            }
        }
        let snapshot: LibrarySnapshot
        if let legacy {
            do { snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: legacy) }
            catch { throw AppError.message("舊版觀看紀錄無法讀取。原始資料已保留，尚未進行遷移。") }
        } else { snapshot = .init() }
        let state = try LibraryState(scope: scope, snapshot: snapshot)
        try save(state)
        return state
    }

    func save(_ state: LibraryState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        guard data.count <= 32 * 1024 * 1024 else {
            throw AppError.message("片庫已達儲存容量上限，原有資料已保留，尚未寫入這次變更。")
        }
        let url = try fileURL(scope: state.scope)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Only a valid prior snapshot may become the recovery copy.
        if let old = try? Data(contentsOf: url), (try? decode(old, scope: state.scope)) != nil {
            try writeProtected(old, to: url.appendingPathExtension("previous"))
        }
        try writeProtected(data, to: url)
    }

    private func decode(_ data: Data, scope: LibraryScope) throws -> LibraryState {
        guard data.count <= 32 * 1024 * 1024 else { throw AppError.message("片庫資料超過可讀取大小，原始資料已保留。") }
        let state = try JSONDecoder().decode(LibraryState.self, from: data)
        guard state.scope == scope else { throw AppError.message("片庫所屬帳號不一致，已停止讀取。") }
        return state
    }

    private func fileURL(scope: LibraryScope) throws -> URL {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(scope)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest).appendingPathExtension("json")
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
