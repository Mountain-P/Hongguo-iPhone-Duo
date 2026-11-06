// SPDX-License-Identifier: GPL-3.0-only
// Phone/form/MFA contract facts independently implemented from the authorized
// Quest reference and aston314/hongguo-tv 36508246eeca2cf5ef1f29f7f17f8e985d50ae2e.
// No Go signing implementation is copied. Signing runs in the bundled GPL JS.
import Foundation
import CoreFoundation

public struct PhoneCountry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let minDigits: Int
    public let maxDigits: Int
}

/// Dedicated registered App identity; never the anonymous playback identity.
public struct AccountAppDevice: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deviceID: String
    public let installID: String
    public let cdid: String
    public let clientUDID: String
    public let openUDID: String
    public let createdAtMilliseconds: Int64
    let registrationCookies: [String: String]
    public var description: String { "AccountAppDevice([redacted])" }
    public var debugDescription: String { description }

    public init(deviceID: String, installID: String, cdid: String, clientUDID: String, openUDID: String,
                createdAtMilliseconds: Int64, registrationCookies: [String: String] = [:]) throws {
        guard PhoneAuthRules.validID(deviceID), PhoneAuthRules.validID(installID), UUID(uuidString: cdid) != nil,
              UUID(uuidString: clientUDID) != nil, openUDID.range(of: #"^[a-fA-F0-9]{16}$"#, options: .regularExpression) != nil,
              (946_684_800_000...4_102_444_800_000).contains(createdAtMilliseconds), registrationCookies.count <= 8 else { throw PhoneAuthError.invalidResponse }
        for (name, value) in registrationCookies {
            guard ["store-region", "store-region-src", "ttreq", "odin_tt", "install_id"].contains(name) else { throw PhoneAuthError.invalidResponse }
            _ = try AccountCookie(name: name, value: value, domain: ".fqnovel.com")
        }
        self.deviceID = deviceID; self.installID = installID; self.cdid = cdid; self.clientUDID = clientUDID
        self.openUDID = openUDID; self.createdAtMilliseconds = createdAtMilliseconds; self.registrationCookies = registrationCookies
    }
    private enum CodingKeys: String, CodingKey { case deviceID, installID, cdid, clientUDID, openUDID, createdAtMilliseconds, registrationCookies }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(deviceID: c.decode(String.self, forKey: .deviceID), installID: c.decode(String.self, forKey: .installID),
                      cdid: c.decode(String.self, forKey: .cdid), clientUDID: c.decode(String.self, forKey: .clientUDID),
                      openUDID: c.decode(String.self, forKey: .openUDID), createdAtMilliseconds: c.decode(Int64.self, forKey: .createdAtMilliseconds),
                      registrationCookies: c.decodeIfPresent([String: String].self, forKey: .registrationCookies) ?? [:])
    }
}

public enum PhoneCodeDelivery: Sendable, Equatable { case sent, uncertain }
public struct PhoneCodeChallenge: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let maskedPhone: String
    public let retryAfter: Int
    public let expiresAt: Date
    public let delivery: PhoneCodeDelivery
}
public struct PhoneMFAChallenge: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let destination: String
    public let message: String
    public let expiresAt: Date
}
public enum PhoneLoginResult: Sendable, Equatable {
    case authenticated(AccountSession)
    case verificationRequired(PhoneMFAChallenge)
}
public enum PhoneAuthError: Error, LocalizedError, Sendable, Equatable {
    case invalidPhone, invalidCode, unsupportedCountry, busy, expired, rejected, unsupportedChallenge, invalidResponse, network
    case cooldown(Int), denied(Int), rateLimited(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidPhone: "請輸入符合所選國家或地區的手機號碼。"
        case .invalidCode: "請輸入 4 至 8 位數字驗證碼。"
        case .unsupportedCountry: "暫不支援這個國家或地區的手機號碼。"
        case .busy: "正在處理登入，請稍候。"
        case .expired: "這次登入已取消或到期，請重新取得驗證碼。"
        case .rejected: "官方未接受這次登入操作，請檢查資料後再試。"
        case .unsupportedChallenge: "官方要求額外驗證，目前無法在這個介面完成，請稍後重試。"
        case .invalidResponse: "官方登入回應格式已改變，請稍後重試。"
        case .network: "無法連線至官方登入服務，請稍後重試。"
        case .cooldown(let seconds), .rateLimited(let seconds): "請等待 \(seconds) 秒後再取得驗證碼。"
        case .denied(let status): "官方登入服務拒絕了請求（HTTP \(status)）。"
        }
    }
}

struct NativePhoneMFA: Codable, Sendable {
    let encryptUID: String
    let codeKey: String
    let logID: String
    let scene: String
    let destination: String
    let message: String
}
struct NativePhoneAuthRequest: Codable, Sendable {
    let operation: String
    var device: AccountAppDevice?
    var phone: String?
    var wirePhone: String?
    var code: String?
    var ticket: String?
    var mfa: NativePhoneMFA?
    var cookies: [String: String]?
    var token: String?
}

public actor NativePhoneAuthService {
    public static let shared = NativePhoneAuthService()
    public static let countries: [PhoneCountry] = [
        .init(id: "+86", name: "中國大陸", minDigits: 11, maxDigits: 11),
        .init(id: "+852", name: "香港", minDigits: 8, maxDigits: 8), .init(id: "+853", name: "澳門", minDigits: 8, maxDigits: 8),
        .init(id: "+886", name: "台灣", minDigits: 9, maxDigits: 10), .init(id: "+60", name: "馬來西亞", minDigits: 9, maxDigits: 10),
        .init(id: "+65", name: "新加坡", minDigits: 8, maxDigits: 8), .init(id: "+62", name: "印尼", minDigits: 10, maxDigits: 13),
        .init(id: "+95", name: "緬甸", minDigits: 9, maxDigits: 10), .init(id: "+63", name: "菲律賓", minDigits: 7, maxDigits: 10),
        .init(id: "+84", name: "越南", minDigits: 9, maxDigits: 10), .init(id: "+855", name: "柬埔寨", minDigits: 8, maxDigits: 9),
        .init(id: "+81", name: "日本", minDigits: 9, maxDigits: 11), .init(id: "+82", name: "韓國", minDigits: 8, maxDigits: 11),
        .init(id: "+971", name: "阿拉伯聯合大公國", minDigits: 9, maxDigits: 9)
    ]
    private let execute: @Sendable (NativePhoneAuthRequest) async throws -> String
    private var device: AccountAppDevice?
    private var cookies: [String: String] = [:]
    private var token: String?
    private var generation: UInt64 = 0
    private var busy = false
    private var current: (challenge: PhoneCodeChallenge, phone: String, wire: String)?
    private var pendingMFA: (challenge: PhoneMFAChallenge, value: NativePhoneMFA, code: String)?
    private var nextSendAt = Date.distantPast
    private var active: Task<String, any Error>?

    public init(device: AccountAppDevice? = nil) {
        self.device = device
        execute = { try await NativeJSRuntime().phoneAuth($0) }
    }
    init(device: AccountAppDevice? = nil, execute: @escaping @Sendable (NativePhoneAuthRequest) async throws -> String) {
        self.device = device; self.execute = execute
    }

    /// Input normalization only; this list does not promise SMS delivery abroad.
    public static func normalize(countryCode: String, localNumber: String) throws -> String {
        try PhoneAuthRules.phone(countryCode: countryCode, local: localNumber).canonical
    }

    /// Anonymous registration only. No phone, code, account cookies or token are sent.
    public func prepareRegistration() async throws {
        guard !busy else { throw PhoneAuthError.busy }
        if device != nil { return }
        generation &+= 1; let g = generation; busy = true
        defer { if generation == g { busy = false } }
        _ = try await perform(.init(operation: "register"), generation: g)
        guard device != nil else { throw PhoneAuthError.invalidResponse }
    }

    public func sendCode(countryCode: String, localNumber: String) async throws -> PhoneCodeChallenge {
        let phone = try PhoneAuthRules.phone(countryCode: countryCode, local: localNumber)
        guard !busy else { throw PhoneAuthError.busy }
        let remaining = Int(ceil(nextSendAt.timeIntervalSinceNow))
        guard remaining <= 0 else { throw PhoneAuthError.cooldown(remaining) }
        generation &+= 1; let g = generation; busy = true
        current = nil; pendingMFA = nil; cookies = [:]; token = nil
        defer { if generation == g { busy = false } }
        if device == nil { _ = try await perform(.init(operation: "register"), generation: g) }
        guard device != nil else { throw PhoneAuthError.invalidResponse }
        let id = UUID(), expires = Date().addingTimeInterval(600)
        nextSendAt = Date().addingTimeInterval(60)
        do {
            let result = try await perform(.init(operation: "sendCode", device: device, phone: phone.canonical, wirePhone: phone.wire), generation: g)
            try PhoneAuthRules.requireSuccess(result)
            let retry = PhoneAuthRules.retry(result) ?? 60
            nextSendAt = Date().addingTimeInterval(Double(retry))
            let challenge = PhoneCodeChallenge(id: id, maskedPhone: PhoneAuthRules.mask(phone.canonical), retryAfter: retry, expiresAt: expires, delivery: .sent)
            current = (challenge, phone.canonical, phone.wire)
            return challenge
        } catch is CancellationError { throw CancellationError() }
        catch let error as PhoneAuthError where PhoneAuthRules.uncertainDelivery(error) {
            try check(g)
            let challenge = PhoneCodeChallenge(id: id, maskedPhone: PhoneAuthRules.mask(phone.canonical), retryAfter: 60, expiresAt: expires, delivery: .uncertain)
            current = (challenge, phone.canonical, phone.wire)
            return challenge
        } catch {
            if let e = error as? PhoneAuthError, case .rateLimited(let retry) = e { nextSendAt = Date().addingTimeInterval(Double(retry)) }
            else { nextSendAt = .distantPast }
            throw error
        }
    }

    public func loginSMS(challengeID: UUID, code: String) async throws -> PhoneLoginResult {
        guard PhoneAuthRules.asciiDigits(code), (4...8).contains(code.utf8.count) else { throw PhoneAuthError.invalidCode }
        guard !busy else { throw PhoneAuthError.busy }
        guard let current, current.challenge.id == challengeID, current.challenge.expiresAt > Date() else { throw PhoneAuthError.expired }
        let g = generation; busy = true
        defer { if generation == g { busy = false } }
        let result = try await perform(.init(operation: "loginSMS", device: device, phone: current.phone, wirePhone: current.wire,
                                             code: code, cookies: cookies, token: token), generation: g)
        return try finish(result, code: code)
    }

    public func verifyMFA(challengeID: UUID) async throws -> PhoneLoginResult {
        guard !busy else { throw PhoneAuthError.busy }
        guard let current, let pendingMFA, pendingMFA.challenge.id == challengeID,
              current.challenge.expiresAt > Date(), pendingMFA.challenge.expiresAt > Date() else { throw PhoneAuthError.expired }
        let g = generation; busy = true
        defer { if generation == g { busy = false } }
        let verified = try await perform(.init(operation: "verifyMFA", device: device, phone: current.phone, wirePhone: current.wire,
                                               mfa: pendingMFA.value, cookies: cookies, token: token), generation: g)
        if PhoneAuthRules.errorCode(verified) == 1045 { return .verificationRequired(pendingMFA.challenge) }
        try PhoneAuthRules.requireSuccess(verified)
        let data = verified["data"] as? [String: Any] ?? [:]
        guard let ticket = (data["ticket"] ?? data["verify_ticket"]) as? String, !ticket.isEmpty, ticket.utf8.count <= 8192 else { throw PhoneAuthError.invalidResponse }
        let result = try await perform(.init(operation: "loginSMS", device: device, phone: current.phone, wirePhone: current.wire,
                                             code: pendingMFA.code, ticket: ticket, cookies: cookies, token: token), generation: g)
        return try finish(result, code: pendingMFA.code)
    }

    public func cancel() { generation &+= 1; active?.cancel(); active = nil; busy = false; current = nil; pendingMFA = nil; cookies = [:]; token = nil }
    /// Local logout only. The inspected source does not establish a remote logout endpoint.
    public func logout() { cancel() }
    public func registeredDevice() -> AccountAppDevice? { device }

    /// Local validation of the previously authenticated session, not an online
    /// identity check. The actual library API decides whether it is still accepted.
    public static func validateForLibrary(session: AccountSession) throws -> AccountProfile {
        guard session.isNativeAppSession, PhoneAuthRules.validID(session.profile.id) else { throw AccountError.expired }
        _ = try session.cookieHeader(for: URL(string: "https://api5-normal-lq.fqnovel.com/")!)
        return session.profile
    }

    private func perform(_ request: NativePhoneAuthRequest, generation g: UInt64) async throws -> [String: Any] {
        try check(g)
        let execute = execute, task = Task { try await execute(request) }
        active = task
        defer { if generation == g { active = nil } }
        let raw: String
        do { raw = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() } }
        catch is CancellationError { throw CancellationError() }
        catch { try check(g); throw PhoneAuthError.network }
        try check(g)
        guard raw.utf8.count <= 4 * 1024 * 1024, let bytes = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw PhoneAuthError.invalidResponse }
        if let error = value["error"] as? String {
            let status = value["status"] as? Int
            if status == 429 { throw PhoneAuthError.rateLimited((value["retryAfter"] as? Int).flatMap { (1...3600).contains($0) ? $0 : nil } ?? 60) }
            if let status, (400...599).contains(status) { throw PhoneAuthError.denied(status) }
            if ["ETIMEDOUT", "ERR_NETWORK", "ECONNRESET", "ENOTFOUND"].contains(error) { throw PhoneAuthError.network }
            if ["CANCELLED", "ERR_CANCELED"].contains(error) { throw CancellationError() }
            throw PhoneAuthError.invalidResponse
        }
        if let rawDevice = value["device"] as? [String: Any] {
            guard let next = try? JSONDecoder().decode(AccountAppDevice.self, from: JSONSerialization.data(withJSONObject: rawDevice)) else { throw PhoneAuthError.invalidResponse }
            if let existing = device, next != existing { throw PhoneAuthError.invalidResponse }
            device = next
        }
        if let next = value["cookies"] as? [String: String] {
            guard next.count <= 32 else { throw PhoneAuthError.invalidResponse }
            for (name, val) in next {
                guard AccountCookie.allowedNames.contains(name) else { continue }
                if val.isEmpty { cookies.removeValue(forKey: name); continue }
                _ = try AccountCookie(name: name, value: val, domain: ".fqnovel.com")
                cookies[name] = val
            }
        }
        if let next = value["token"] as? String, !next.isEmpty {
            guard next.utf8.count <= 8192, next.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw PhoneAuthError.invalidResponse }
            token = next
        }
        guard let payload = value["payload"] as? [String: Any] else { throw PhoneAuthError.invalidResponse }
        return payload
    }
    private func check(_ g: UInt64) throws { try Task.checkCancellation(); guard generation == g else { throw CancellationError() } }
    private func finish(_ payload: [String: Any], code: String) throws -> PhoneLoginResult {
        if let mfa = PhoneAuthRules.mfa(payload) {
            let challenge = PhoneMFAChallenge(id: UUID(), destination: mfa.destination, message: mfa.message, expiresAt: Date().addingTimeInterval(600))
            pendingMFA = (challenge, mfa, code)
            return .verificationRequired(challenge)
        }
        try PhoneAuthRules.requireSuccess(payload)
        guard let data = payload["data"] as? [String: Any], let device else { throw PhoneAuthError.invalidResponse }
        let id = try PhoneAuthRules.uid(data)
        let accountCookies = try cookies.map { try AccountCookie(name: $0.key, value: $0.value, domain: ".fqnovel.com") }
        let nickname = PhoneAuthRules.safeText(data["screen_name"] ?? data["name"], limit: 80)
        let avatar = (data["avatar_url"] as? String).flatMap(URL.init(string:)).flatMap { $0.scheme == "https" && $0.user == nil && $0.password == nil ? $0 : nil }
        let profile = AccountProfile(id: id, nickname: nickname.isEmpty ? "紅果使用者" : nickname, avatar: avatar,
                                     maskedPhone: current?.challenge.maskedPhone ?? "")
        let session = try AccountSession(profile: profile, cookies: accountCookies, token: token, appDevice: device)
        current = nil; pendingMFA = nil; cookies = [:]; token = nil
        return .authenticated(session)
    }
}

enum PhoneAuthRules {
    static func uncertainDelivery(_ error: PhoneAuthError) -> Bool {
        if error == .network || error == .invalidResponse { return true }
        if case .denied(let status) = error { return status == 408 || status >= 500 }
        return false
    }
    static func asciiDigits(_ raw: String) -> Bool { !raw.isEmpty && raw.utf8.allSatisfy { (48...57).contains($0) } }
    static func validID(_ raw: String) -> Bool { asciiDigits(raw) && raw.utf8.count <= 30 && raw.contains { $0 != "0" } }
    static func phone(countryCode: String, local: String) throws -> (canonical: String, wire: String) {
        let input = countryCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = input.hasPrefix("+") ? input : "+" + input
        guard let region = NativePhoneAuthService.countries.first(where: { $0.id == code }) else { throw PhoneAuthError.unsupportedCountry }
        let local = local.trimmingCharacters(in: .whitespacesAndNewlines)
        guard asciiDigits(local), (region.minDigits...region.maxDigits).contains(local.utf8.count), code.utf8.count - 1 + local.utf8.count <= 15,
              code != "+86" || local.range(of: #"^1[3-9][0-9]{9}$"#, options: .regularExpression) != nil else { throw PhoneAuthError.invalidPhone }
        let canonical = code + local
        if code == "+86" { return (canonical, canonical) }
        let widths = region.maxDigits == 10 ? [3, 4, 3] : region.maxDigits == 11 ? [3, 4, 4] : Array(repeating: region.maxDigits % 4 == 0 ? 4 : 3, count: 5)
        var rest = local[...], groups: [String] = []
        for width in widths where !rest.isEmpty { let end = rest.index(rest.startIndex, offsetBy: min(width, rest.count)); groups.append(String(rest[..<end])); rest = rest[end...] }
        return (canonical, code + groups.joined(separator: " "))
    }
    static func mask(_ raw: String) -> String { String(raw.prefix(4)) + String(repeating: "*", count: max(0, raw.count - 7)) + raw.suffix(3) }
    static func errorCode(_ p: [String: Any]) -> Int? {
        let data = p["data"] as? [String: Any]
        let value = data?["error_code"] ?? p["error_code"]
        if let s = value as? String { return Int(s) }
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return Int(n.stringValue) }
        return nil
    }
    static func requireSuccess(_ p: [String: Any]) throws {
        let data = p["data"] as? [String: Any]
        for value in [p["code"], p["error_code"], data?["error_code"]].compactMap({ $0 }) {
            let raw: String?
            if let s = value as? String { raw = s }
            else if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { raw = n.stringValue }
            else { raw = nil }
            guard let raw, let code = Int(raw) else { throw PhoneAuthError.invalidResponse }
            guard code == 0 else { throw PhoneAuthError.rejected }
        }
        guard (p["message"] as? String)?.lowercased() == "success", data != nil else { throw PhoneAuthError.rejected }
    }
    static func retry(_ p: [String: Any]) -> Int? { let data = p["data"] as? [String: Any]; return (data?["retry_time"] as? Int).flatMap { (1...3600).contains($0) ? $0 : nil } }
    static func uid(_ d: [String: Any]) throws -> String {
        func exact(_ value: Any?) -> String? {
            if let s = value as? String { return validID(s) ? s : nil }
            if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), !["d", "f"].contains(String(cString: n.objCType)), validID(n.stringValue) { return n.stringValue }
            return nil
        }
        let a = exact(d["user_id_str"]), b = exact(d["user_id"])
        guard let id = a ?? b, d["user_id_str"] == nil || a != nil, d["user_id"] == nil || b != nil,
              a == nil || b == nil || a == b else { throw PhoneAuthError.invalidResponse }
        return id
    }
    static func safeText(_ raw: Any?, limit: Int) -> String {
        guard let s = raw as? String else { return "" }
        return String(s.filter { !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(limit))
    }
    static func mfa(_ p: [String: Any]) -> NativePhoneMFA? {
        guard let d = p["data"] as? [String: Any], let uid = d["encrypt_uid"] as? String, !uid.isEmpty, uid.utf8.count <= 8192,
              let key = d["sms_code_key"] as? String, !key.isEmpty, key.utf8.count <= 8192,
              let ways = d["verify_ways"] as? [[String: Any]], ways.count <= 20,
              let way = ways.first(where: { $0["verify_way"] as? String == "upsms" || $0["sms_content"] as? String != nil }),
              let destination = way["channel_mobile"] as? String, destination.utf8.count <= 32,
              asciiDigits(destination.hasPrefix("+") ? String(destination.dropFirst()) : destination),
              let message = way["sms_content"] as? String, !message.isEmpty, message.utf8.count <= 1024,
              !message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return .init(encryptUID: uid, codeKey: key, logID: safeText((d["event_params"] as? [String: Any])?["log_id"], limit: 256),
                     scene: safeText(d["passport_scene"], limit: 80), destination: destination, message: message)
    }
}
