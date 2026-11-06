// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct AccountLibraryItem: Codable, Hashable, Identifiable, Sendable {
    public var series: Series
    public var episodeID: String
    public var episodeNumber: Int
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var updatedAtMilliseconds: Int64?
    public var collectedAtMilliseconds: Int64?
    public var id: String { series.id }
    public init(series: Series, episodeID: String = "", episodeNumber: Int = 0, positionSeconds: Double = 0,
                durationSeconds: Double = 0, updatedAtMilliseconds: Int64? = nil, collectedAtMilliseconds: Int64? = nil) {
        self.series = series; self.episodeID = episodeID; self.episodeNumber = episodeNumber
        self.positionSeconds = positionSeconds; self.durationSeconds = durationSeconds
        self.updatedAtMilliseconds = updatedAtMilliseconds; self.collectedAtMilliseconds = collectedAtMilliseconds
    }
}

public struct AccountLibrarySnapshot: Codable, Hashable, Sendable {
    public var accountID: String
    public var items: [AccountLibraryItem]
    public var isComplete: Bool
    public var pagesRead: Int
    public init(accountID: String, items: [AccountLibraryItem], isComplete: Bool, pagesRead: Int) {
        self.accountID = accountID; self.items = items; self.isComplete = isComplete; self.pagesRead = pagesRead
    }
}

public struct AccountWatchProgress: Codable, Hashable, Sendable {
    public var seriesID: String
    public var episodeID: String
    public var episodeNumber: Int
    public var positionSeconds: Double
    public var durationSeconds: Double
    public var episodeCount: Int
    public var watchedAtMilliseconds: Int64
    public var seasonIndex: Int
    public var isMultiSeason: Bool
    public init(seriesID: String, episodeID: String, episodeNumber: Int, positionSeconds: Double,
                durationSeconds: Double, episodeCount: Int, watchedAtMilliseconds: Int64,
                seasonIndex: Int = 0, isMultiSeason: Bool = false) {
        self.seriesID = seriesID; self.episodeID = episodeID; self.episodeNumber = episodeNumber
        self.positionSeconds = positionSeconds; self.durationSeconds = durationSeconds; self.episodeCount = episodeCount
        self.watchedAtMilliseconds = watchedAtMilliseconds; self.seasonIndex = seasonIndex; self.isMultiSeason = isMultiSeason
    }
}

public struct AccountMutationReceipt: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case favorite, progress }
    public let mutationID: UUID
    public let accountID: String
    public let kind: Kind
}

public struct AccountLibraryError: Error, LocalizedError, Equatable, Sendable {
    public let code: String
    public let status: Int?
    public let historyAccepted: Bool
    public init(code: String, status: Int? = nil, historyAccepted: Bool = false) {
        self.code = code; self.status = status; self.historyAccepted = historyAccepted
    }
    public var errorDescription: String? {
        if historyAccepted { return "來源已確認觀看歷史，但續播位置尚未確認；請重新整理後檢查。" }
        if status == 401 || status == 403 { return "來源拒絕這項帳號操作，請重新登入或稍後重試。" }
        switch code {
        case "ACCOUNT_CHANGED": return "帳號已退出或切換，已停止這次操作。"
        case "ETIMEDOUT": return "帳號資料請求逾時，請重試。"
        case "INVALID_INPUT", "MUTATION_CONFLICT": return "帳號操作資料無效。"
        case "BUSINESS_REJECTED": return "來源未確認這項操作，這條帳號介面可能暫不支援。"
        case "INVALID_RESPONSE", "INVALID_CURSOR": return "帳號來源資料格式已變更，請稍後重試。"
        default: return "帳號來源暫時無法使用，請稍後重試。"
        }
    }
}

/// Scoped to one validated website session. Never starts background synchronization.
/// Newly adapted favorites/writes require real-account verification on the source platform.
public actor NativeAccountLibraryService {
    private let session: AccountSession
    private let register: @Sendable () async throws -> AccountLibraryIdentity
    private let execute: @Sendable (AccountLibraryRequest) async throws -> AccountLibraryResponse
    private var identity: AccountLibraryIdentity?
    private var registration: Task<AccountLibraryIdentity, any Error>?
    private var generation: UInt64 = 0
    private var invalidated = false
    private var active: [UUID: Task<AccountLibraryResponse, any Error>] = [:]
    private var snapshots: [AccountLibraryOperation: (AccountLibrarySnapshot, Date)] = [:]
    private var readRequests: [AccountLibraryOperation: UUID] = [:]
    private struct Mutation {
        let fingerprint: String
        let task: Task<AccountLibraryResponse, any Error>?
        let result: Result<AccountMutationReceipt, AccountLibraryError>?
    }
    private var mutations: [UUID: Mutation] = [:]
    private var mutationOrder: [UUID] = []

    public init(session: AccountSession) throws {
        guard let device = session.appDevice else { throw AccountLibraryError(code: "NATIVE_LOGIN_REQUIRED") }
        _ = try session.cookieHeader(for: AccountLibraryRequest.origin)
        self.session = session
        let identity = AccountLibraryIdentity(device_id: device.deviceID, iid: device.installID, cdid: device.cdid, openudid: device.openUDID)
        // The device is the persisted Passport login device; library reads/writes never register another one.
        register = { identity }
        execute = { try await NativeJSRuntime().accountLibrary($0) }
    }

    init(session: AccountSession, register: @escaping @Sendable () async throws -> AccountLibraryIdentity,
         execute: @escaping @Sendable (AccountLibraryRequest) async throws -> AccountLibraryResponse) throws {
        _ = try session.cookieHeader(for: AccountLibraryRequest.origin)
        self.session = session; self.register = register; self.execute = execute
    }

    public func history(fresh: Bool = false) async throws -> AccountLibrarySnapshot { try await read(.history, fresh: fresh) }
    public func favorites(fresh: Bool = false) async throws -> AccountLibrarySnapshot { try await read(.favorites, fresh: fresh) }

    public func setFavorite(seriesID: String, value: Bool, mutationID: UUID) async throws -> AccountMutationReceipt {
        try validate(seriesID)
        let request = try await request(.favorite, seriesID: seriesID, favorite: value)
        return try await mutate(request, id: mutationID, kind: .favorite)
    }

    public func reportProgress(_ progress: AccountWatchProgress, mutationID: UUID) async throws -> AccountMutationReceipt {
        try validate(progress.seriesID); try validate(progress.episodeID)
        guard (1...10_000).contains(progress.episodeNumber), (0...10_000).contains(progress.episodeCount),
              (0...10_000).contains(progress.seasonIndex), progress.positionSeconds.isFinite, progress.durationSeconds.isFinite,
              (0...86_400).contains(progress.positionSeconds), (0...86_400).contains(progress.durationSeconds),
              (946_684_800_000...4_102_444_800_000).contains(progress.watchedAtMilliseconds) else { throw AccountLibraryError(code: "INVALID_INPUT") }
        let request = try await request(.progress, progress: progress)
        return try await mutate(request, id: mutationID, kind: .progress)
    }

    /// Call before logout/account replacement; stale replies cannot repopulate data or acknowledge writes.
    public func invalidate() {
        invalidated = true; generation &+= 1
        registration?.cancel(); registration = nil; identity = nil
        active.values.forEach { $0.cancel() }; active.removeAll()
        snapshots.removeAll(); readRequests.removeAll(); mutations.removeAll(); mutationOrder.removeAll()
    }

    /// Explicit retry control after a user-requested fresh pull/reconciliation.
    /// Success receipts and pending requests remain protected from duplicate writes.
    @discardableResult
    public func resetFailedMutation(_ mutationID: UUID) -> Bool {
        guard !invalidated, let mutation = mutations[mutationID], case .failure? = mutation.result else { return false }
        mutations.removeValue(forKey: mutationID); mutationOrder.removeAll { $0 == mutationID }
        return true
    }

    private func read(_ operation: AccountLibraryOperation, fresh: Bool) async throws -> AccountLibrarySnapshot {
        let request = try await request(operation)
        if !fresh, let (value, expires) = snapshots[operation], expires > Date() { return value }
        snapshots.removeValue(forKey: operation)
        let token = generation, id = UUID(), execute = self.execute
        readRequests[operation] = id
        let task = Task { try await execute(request) }; active[id] = task
        defer { active.removeValue(forKey: id) }
        let response = try await wait(task)
        try current(token)
        guard case .snapshot(let value) = response, value.accountID == session.profile.id else { throw AccountLibraryError(code: "INVALID_RESPONSE") }
        if readRequests[operation] == id {
            snapshots[operation] = (value, Date().addingTimeInterval(30)); readRequests.removeValue(forKey: operation)
        }
        return value
    }

    private func mutate(_ request: AccountLibraryRequest, id: UUID, kind: AccountMutationReceipt.Kind) async throws -> AccountMutationReceipt {
        let fingerprint = try request.fingerprint()
        let task: Task<AccountLibraryResponse, any Error>
        if let previous = mutations[id] {
            guard previous.fingerprint == fingerprint else { throw AccountLibraryError(code: "MUTATION_CONFLICT") }
            if let result = previous.result { return try result.get() }
            guard let pending = previous.task else { throw AccountLibraryError(code: "INVALID_RESPONSE") }; task = pending
        } else {
            let execute = self.execute
            task = Task { try await execute(request) }
            mutations[id] = Mutation(fingerprint: fingerprint, task: task, result: nil)
            active[id] = task
        }
        let token = generation
        do {
            let response = try await wait(task)
            try current(token)
            guard case .acknowledged = response else { throw AccountLibraryError(code: "INVALID_RESPONSE") }
            let receipt = AccountMutationReceipt(mutationID: id, accountID: session.profile.id, kind: kind)
            remember(id, fingerprint: fingerprint, result: .success(receipt))
            snapshots.removeAll(); readRequests.removeAll()
            return receipt
        } catch {
            if !invalidated, generation == token {
                // Even an ambiguous failure is not automatically resent with the same mutation ID.
                remember(id, fingerprint: fingerprint, result: .failure(Self.sanitized(error)))
            }
            throw error
        }
    }

    private func remember(_ id: UUID, fingerprint: String, result: Result<AccountMutationReceipt, AccountLibraryError>) {
        active.removeValue(forKey: id)
        mutations[id] = Mutation(fingerprint: fingerprint, task: nil, result: result)
        if !mutationOrder.contains(id) { mutationOrder.append(id) }
        while mutationOrder.count > 256 { mutations.removeValue(forKey: mutationOrder.removeFirst()) }
    }

    private func request(_ operation: AccountLibraryOperation, seriesID: String? = nil, favorite: Bool? = nil,
                         progress: AccountWatchProgress? = nil) async throws -> AccountLibraryRequest {
        try Task.checkCancellation()
        guard !invalidated else { throw AccountLibraryError(code: "ACCOUNT_CHANGED") }
        let identity = try await accountIdentity()
        guard !invalidated else { throw AccountLibraryError(code: "ACCOUNT_CHANGED") }
        return AccountLibraryRequest(operation: operation, accountID: session.profile.id,
                                     cookieHeader: try session.cookieHeader(for: AccountLibraryRequest.origin),
                                     seriesID: seriesID, favorite: favorite, progress: progress, identity: identity, token: session.token)
    }

    private func accountIdentity() async throws -> AccountLibraryIdentity {
        if let identity { return identity }
        let token = generation
        let task: Task<AccountLibraryIdentity, any Error>
        if let existing = registration { task = existing }
        else {
            let register = self.register
            task = Task { try await register() }; registration = task
        }
        do {
            let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try current(token)
            identity = value; registration = nil
            return value
        } catch {
            if generation == token { registration = nil }
            throw error
        }
    }

    private func current(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard !invalidated, generation == token else { throw AccountLibraryError(code: "ACCOUNT_CHANGED") }
    }
    private func validate(_ id: String) throws {
        guard (try? validateID(id)) != nil, id.contains(where: { $0 != "0" }) else { throw AccountLibraryError(code: "INVALID_INPUT") }
    }
    private func wait(_ task: Task<AccountLibraryResponse, any Error>) async throws -> AccountLibraryResponse {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private static func sanitized(_ error: any Error) -> AccountLibraryError {
        if let error = error as? AccountLibraryError { return error }
        if error is CancellationError { return AccountLibraryError(code: "CANCELLED") }
        return AccountLibraryError(code: "ERR_NETWORK")
    }
}

enum AccountLibraryOperation: String, Codable, Hashable, Sendable { case history, favorites, favorite, progress }

struct AccountLibraryRequest: Sendable {
    static let origin = URL(string: "https://api5-normal-lq.fqnovel.com/")!
    let operation: AccountLibraryOperation
    let accountID: String
    let cookieHeader: String
    var seriesID: String? = nil
    var favorite: Bool? = nil
    var progress: AccountWatchProgress? = nil
    var identity: AccountLibraryIdentity? = nil
    var token: String? = nil
    func json() throws -> Data {
        var value: [String: Any] = ["operation": operation.rawValue, "accountID": accountID, "cookie": cookieHeader]
        if let seriesID { value["seriesID"] = seriesID }
        if let favorite { value["favorite"] = favorite }
        if let progress { value["progress"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(progress)) }
        if let identity { value["identity"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identity)) }
        if let token { value["token"] = token }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    func fingerprint() throws -> String {
        let value = AccountLibraryRequest(operation: operation, accountID: accountID, cookieHeader: "", seriesID: seriesID, favorite: favorite, progress: progress)
        return String(decoding: try value.json(), as: UTF8.self)
    }
}

struct AccountLibraryIdentity: Codable, Equatable, Sendable {
    let device_id: String
    let iid: String
    let cdid: String
    let openudid: String?
    init(device_id: String, iid: String, cdid: String, openudid: String? = nil) {
        self.device_id = device_id; self.iid = iid; self.cdid = cdid; self.openudid = openudid
    }
}

enum AccountLibraryResponse: Sendable {
    case snapshot(AccountLibrarySnapshot)
    case acknowledged
}

enum AccountLibraryParser {
    static func identity(_ raw: String) throws -> AccountLibraryIdentity {
        let object = try object(raw)
        try sourceError(object)
        let value = try JSONDecoder().decode(AccountLibraryIdentity.self, from: JSONSerialization.data(withJSONObject: object))
        guard validID(value.device_id), validID(value.iid), UUID(uuidString: value.cdid) != nil else { throw AccountLibraryError(code: "INVALID_RESPONSE") }
        return value
    }

    static func response(_ raw: String, operation: AccountLibraryOperation, accountID: String) throws -> AccountLibraryResponse {
        let value = try object(raw)
        try sourceError(value)
        if operation == .favorite || operation == .progress {
            guard value["acknowledged"] as? Bool == true else { throw AccountLibraryError(code: "INVALID_RESPONSE") }
            return .acknowledged
        }
        guard let rows = value["items"] as? [[String: Any]], rows.count <= 5000,
              let complete = value["isComplete"] as? Bool, let pages = value["pagesRead"] as? Int,
              (1...(operation == .favorites ? 1 : 10)).contains(pages) else { throw AccountLibraryError(code: "INVALID_RESPONSE") }
        let items = try JSONDecoder().decode([AccountLibraryItem].self, from: JSONSerialization.data(withJSONObject: rows))
        var seen: Set<String> = []
        for item in items {
            guard validID(item.id), seen.insert(item.id).inserted, item.series.title.count <= 300,
                  item.series.description.count <= 2000, item.series.tags.count <= 8, item.series.tags.allSatisfy({ $0.count <= 160 }),
                  item.series.cover.isEmpty || safeImage(item.series.cover), item.episodeID.isEmpty || validID(item.episodeID),
                  (0...10000).contains(item.episodeNumber), item.positionSeconds.isFinite, item.durationSeconds.isFinite,
                  (0...86400).contains(item.positionSeconds), (0...86400).contains(item.durationSeconds),
                  [item.updatedAtMilliseconds, item.collectedAtMilliseconds].allSatisfy({ $0 == nil || (1...4_102_444_800_000).contains($0!) }) else {
                throw AccountLibraryError(code: "INVALID_RESPONSE")
            }
        }
        return .snapshot(AccountLibrarySnapshot(accountID: accountID, items: items, isComplete: complete, pagesRead: pages))
    }

    private static func object(_ raw: String) throws -> [String: Any] {
        guard raw.utf8.count <= 4 * 1024 * 1024, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountLibraryError(code: "INVALID_RESPONSE") }
        return object
    }
    private static func sourceError(_ value: [String: Any]) throws {
        guard let rawCode = value["error"] as? String else { return }
        let codes = ["ETIMEDOUT", "BUSINESS_REJECTED", "INVALID_RESPONSE", "INVALID_CURSOR", "INVALID_INPUT", "SECURITY_BLOCKED", "CANCELLED"]
        let code = codes.contains(rawCode) ? rawCode : "ERR_NETWORK"
        let status = (value["status"] as? Int).flatMap { (400...599).contains($0) ? $0 : nil }
        throw AccountLibraryError(code: code, status: status, historyAccepted: value["historyAccepted"] as? Bool == true)
    }
    private static func validID(_ value: String) -> Bool { (try? validateID(value)) != nil && value.contains(where: { $0 != "0" }) }
    private static func safeImage(_ raw: String) -> Bool {
        guard raw.utf8.count <= 8192, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.host != nil else { return false }
        return true
    }
}
