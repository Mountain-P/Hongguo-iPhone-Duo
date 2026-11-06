// SPDX-License-Identifier: GPL-3.0-only
// Official web-login contract checked against jackotom/hongguo-drama
// 2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0, src/native/account-session.js.
import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AccountProfile: Codable, Sendable, Equatable {
    public let id: String
    public let nickname: String
    public let avatar: URL?
    public let maskedPhone: String
    public init(id: String, nickname: String, avatar: URL? = nil, maskedPhone: String = "") {
        self.id = id; self.nickname = nickname; self.avatar = avatar; self.maskedPhone = maskedPhone
    }
}

/// Only these official-site cookies may leave the isolated login web view.
/// Values are intentionally module-private; Codable is for the app's Keychain.
public struct AccountCookie: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let allowedNames: Set<String> = [
        "sessionid", "sessionid_ss", "sid_tt", "sid_guard", "uid_tt", "uid_tt_ss",
        "passport_csrf_token", "passport_csrf_token_default", "passport_auth_status", "passport_auth_status_ss",
        "ttwid", "s_v_web_id", "tt_scid", "store-region", "store-region-src", "store-region-sign",
        "install_id", "odin_tt", "ttreq", "sid_ucp_v1", "ssid_ucp_v1", "passport_status"
    ]
    public let name: String
    let value: String
    public let domain: String
    public let path: String
    public let isSecure: Bool
    public let expiresAt: Date?
    public var description: String { "AccountCookie(\(name), value: [redacted])" }
    public var debugDescription: String { description }

    public init(name: String, value: String, domain: String, path: String = "/", isSecure: Bool = true, expiresAt: Date? = nil) throws {
        let domain = domain.lowercased()
        guard Self.allowedNames.contains(name), ["hongguoduanju.com", ".hongguoduanju.com", "fqnovel.com", ".fqnovel.com", "api5-normal-lq.fqnovel.com"].contains(domain),
              path == "/", isSecure, !value.isEmpty, value.utf8.count <= 4096,
              value.utf8.allSatisfy({ $0 >= 0x21 && $0 <= 0x7e && ![0x22, 0x2c, 0x3b, 0x5c].contains($0) }),
              expiresAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw AccountError.invalidCookies }
        self.name = name; self.value = value; self.domain = domain; self.path = path
        self.isSecure = isSecure; self.expiresAt = expiresAt
    }

    private enum CodingKeys: String, CodingKey { case name, value, domain, path, isSecure, expiresAt }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(name: c.decode(String.self, forKey: .name), value: c.decode(String.self, forKey: .value),
                      domain: c.decode(String.self, forKey: .domain), path: c.decode(String.self, forKey: .path),
                      isSecure: c.decode(Bool.self, forKey: .isSecure), expiresAt: c.decodeIfPresent(Date.self, forKey: .expiresAt))
    }
}

public struct AccountSession: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let profile: AccountProfile
    public let cookies: [AccountCookie]
    public let expiresAt: Date?
    public let appDevice: AccountAppDevice?
    let token: String?
    public var isNativeAppSession: Bool { appDevice != nil }
    public var description: String { "AccountSession(profile: [redacted], cookies: [redacted])" }
    public var debugDescription: String { description }

    public init(profile: AccountProfile, cookies: [AccountCookie], expiresAt: Date? = nil, token: String? = nil, appDevice: AccountAppDevice? = nil) throws {
        guard AccountValidation.validID(profile.id), expiresAt.map({ $0.timeIntervalSince1970.isFinite }) ?? true else {
            throw AccountError.malformedResponse
        }
        let token = token.flatMap { $0.isEmpty ? nil : $0 }
        if let token {
            guard appDevice != nil, token.utf8.count <= 8192, token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw AccountError.invalidCookies }
        }
        let domains = appDevice == nil ? ["hongguoduanju.com", ".hongguoduanju.com"] : ["fqnovel.com", ".fqnovel.com", "api5-normal-lq.fqnovel.com"]
        guard cookies.allSatisfy({ domains.contains($0.domain) }) else { throw AccountError.invalidCookies }
        _ = try AccountValidation.cookieHeader(cookies, now: Date(), requireSession: token == nil)
        let authExpiry = token == nil ? cookies.filter { ["sessionid", "sessionid_ss"].contains($0.name) }.compactMap(\.expiresAt).max() : nil
        let expiry = [expiresAt, authExpiry].compactMap { $0 }.min()
        if let expiry, expiry <= Date() { throw AccountError.expired }
        self.profile = profile; self.cookies = cookies; self.expiresAt = expiry; self.token = token; self.appDevice = appDevice
    }

    /// Explicitly scoped credential transfer for the official account API only.
    /// Playback/CDN URLs never receive the user's login cookies.
    public func cookieHeader(for url: URL) throws -> String {
        guard AccountValidation.allowedCredentialURL(url, native: isNativeAppSession) else { throw AccountError.invalidCookies }
        if let expiresAt, expiresAt <= Date() { throw AccountError.expired }
        return try AccountValidation.cookieHeader(cookies, now: Date(), requireSession: token == nil)
    }

    private enum CodingKeys: String, CodingKey { case profile, cookies, expiresAt, token, appDevice }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(profile: c.decode(AccountProfile.self, forKey: .profile), cookies: c.decode([AccountCookie].self, forKey: .cookies),
                      expiresAt: c.decodeIfPresent(Date.self, forKey: .expiresAt), token: c.decodeIfPresent(String.self, forKey: .token),
                      appDevice: c.decodeIfPresent(AccountAppDevice.self, forKey: .appDevice))
    }
}

public enum AccountError: Error, LocalizedError, Sendable, Equatable {
    case invalidCookies, expired, authenticationFailed, malformedResponse, responseTooLarge, network
    case denied(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidCookies: "登入資料無效，請重新開啟官方登入頁。"
        case .expired: "登入已失效，請重新登入。"
        case .authenticationFailed: "官方未確認登入成功，請在登入頁完成驗證。"
        case .malformedResponse: "官方帳號回應格式有變，請稍後重試。"
        case .responseTooLarge: "官方帳號回應超過允許大小。"
        case .network: "無法連線至官方帳號服務，請稍後重試。"
        case .denied(let status): "官方帳號服務拒絕請求（HTTP \(status)）。"
        }
    }
}

/// Validates a user-completed official website login. It never sends an SMS.
public struct WebAccountService: Sendable {
    public static let siteURL = URL(string: "https://hongguoduanju.com/")!
    private let transport: any HTTPTransport
    public init(transport: (any HTTPTransport)? = nil) { self.transport = transport ?? WebAccountTransport() }

    public func validate(cookies: [AccountCookie]) async throws -> AccountProfile {
        try Task.checkCancellation()
        guard cookies.allSatisfy({ ["hongguoduanju.com", ".hongguoduanju.com"].contains($0.domain) }) else { throw AccountError.invalidCookies }
        let cookie = try AccountValidation.cookieHeader(cookies, now: Date())
        var components = URLComponents(url: Self.siteURL.appendingPathComponent("passport/account/info/v2/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "aid", value: "513755"), .init(name: "passport_jssdk_version", value: "3.4.10"),
            .init(name: "passport_jssdk_type", value: "normal"), .init(name: "account_sdk_source", value: "web"),
            .init(name: "is_from_ttaccountsdk", value: "1"), .init(name: "language", value: "zh")
        ]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.httpMethod = "GET"
        request.setValue(DirectWebService.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.siteURL.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("https://hongguoduanju.com", forHTTPHeaderField: "Origin")
        request.setValue("application/json, text/javascript", forHTTPHeaderField: "Accept")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        let data: Data, response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as AccountError { throw e }
        catch { try Task.checkCancellation(); throw AccountError.network }
        try Task.checkCancellation()
        guard response.url == request.url else { throw AccountError.denied(response.statusCode) }
        if response.statusCode == 401 { throw AccountError.expired }
        guard response.statusCode == 200 else { throw AccountError.denied(response.statusCode) }
        guard data.count <= AccountValidation.maximumBodyBytes else { throw AccountError.responseTooLarge }
        let profile = try AccountValidation.profile(data)
        try Task.checkCancellation()
        return profile
    }

    /// A restored session cannot silently become a different user's account.
    public func validate(session: AccountSession) async throws -> AccountProfile {
        if let expiry = session.expiresAt, expiry <= Date() { throw AccountError.expired }
        let profile = try await validate(cookies: session.cookies)
        guard profile.id == session.profile.id else { throw AccountError.expired }
        return profile
    }
}

private enum AccountValidation {
    static let maximumBodyBytes = 2 * 1024 * 1024
    static func validID(_ raw: String) -> Bool {
        !raw.isEmpty && raw.utf8.count <= 30 && raw.utf8.allSatisfy { (48...57).contains($0) } && raw.utf8.contains { $0 != 48 }
    }
    static func allowedCredentialURL(_ url: URL, native: Bool) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
            && (native ? ["api5-normal-lq.fqnovel.com"] : ["hongguoduanju.com", "api5-normal-sinfonlinea.fqnovel.com"]).contains(url.host?.lowercased() ?? "")
    }
    static func cookieHeader(_ cookies: [AccountCookie], now: Date, requireSession: Bool = true) throws -> String {
        guard (!cookies.isEmpty || !requireSession), cookies.count <= 32, Set(cookies.map(\.name)).count == cookies.count else { throw AccountError.invalidCookies }
        let live = cookies.filter { $0.expiresAt.map { $0 > now } ?? true }
        guard !requireSession || live.contains(where: { ["sessionid", "sessionid_ss"].contains($0.name) }) else { throw AccountError.expired }
        let header = live.sorted { $0.name < $1.name }.map { $0.name + "=" + $0.value }.joined(separator: "; ")
        guard header.utf8.count <= 16 * 1024 else { throw AccountError.invalidCookies }
        return header
    }
    private static func exactID(_ value: Any?) -> String? {
        if let value = value as? String { return validID(value) ? value : nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)), validID(n.stringValue) else { return nil }
        return n.stringValue
    }
    static func profile(_ data: Data) throws -> AccountProfile {
        guard !data.isEmpty, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw AccountError.malformedResponse }
        let detail = object["data"] as? [String: Any]
        for code in [object["code"], object["error_code"], detail?["error_code"]].compactMap({ $0 }) {
            guard let raw = code as? String ?? (code as? NSNumber).flatMap({ CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.stringValue }),
                  let number = Int(raw) else { throw AccountError.malformedResponse }
            // The official info/v2 endpoint returns data.error_code=13 with
            // HTTP 200 when called without credentials (read-only 2026-11-07).
            if number == 13 || number == 401 { throw AccountError.expired }
            guard number == 0 else { throw AccountError.authenticationFailed }
        }
        guard let message = object["message"] as? String, message.lowercased() == "success" else { throw AccountError.authenticationFailed }
        guard let detail else { throw AccountError.malformedResponse }
        let stringID = detail["user_id_str"].flatMap(exactID), numericID = detail["user_id"].flatMap(exactID)
        guard let id = stringID ?? numericID,
              detail["user_id_str"] == nil || stringID != nil,
              detail["user_id"] == nil || numericID != nil,
              stringID == nil || numericID == nil || stringID == numericID else { throw AccountError.malformedResponse }
        func text(_ value: Any?, maximum: Int) -> String {
            guard let value = value as? String else { return "" }
            return String(value.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
                .filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(maximum))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let nickname = text(detail["name"] ?? detail["screen_name"] ?? detail["username"], maximum: 80)
        var avatar: URL?
        if let raw = detail["avatar_url"] as? String, raw.utf8.count <= 2048, let url = URL(string: raw),
           url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.host != nil { avatar = url }
        let phone = text(detail["mobile"] ?? detail["phone"], maximum: 32)
        // Never turn a full number returned by the service into public profile data.
        let maskedPhone = phone.contains("*") && phone.filter(\.isNumber).count <= 7 ? phone : ""
        return AccountProfile(id: id, nickname: nickname.isEmpty ? "紅果使用者" : nickname, avatar: avatar, maskedPhone: maskedPhone)
    }
}

/// Bounded, credential-isolated transport. No automatic redirects, shared jar,
/// URL credentials, cache, error-body parsing, or automatic SMS/login retries.
private struct WebAccountTransport: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { try await WebAccountTransfer().run(request) }
}

final class WebAccountTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var completion: CheckedContinuation<(Data, HTTPURLResponse), any Error>?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var cancelled = false
    private var finished = false
    init(configuration: URLSessionConfiguration = .ephemeral) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        super.init()
    }
    func run(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                if finished { lock.unlock(); continuation.resume(throwing: AccountError.network); return }
                completion = continuation
                let config = configuration.copy() as! URLSessionConfiguration
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil; config.urlCache = nil
                config.timeoutIntervalForRequest = 12; config.timeoutIntervalForResource = 15
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
                self.session = session
                let task = session.dataTask(with: request)
                lock.unlock(); task.resume()
            }
        } onCancel: { self.finish(.failure(CancellationError()), cancelled: true) }
    }
    private func finish(_ result: Result<(Data, HTTPURLResponse), any Error>, cancelled: Bool = false) {
        lock.lock()
        if cancelled { self.cancelled = true }
        guard !finished else { lock.unlock(); return }
        finished = true
        let completion = completion; self.completion = nil
        let session = session; self.session = nil
        lock.unlock()
        completion?.resume(with: result); session?.invalidateAndCancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); finish(.failure(AccountError.malformedResponse)); return }
        self.response = http
        if http.statusCode != 200 { completionHandler(.cancel); finish(.success((Data(), http))); return }
        guard http.expectedContentLength <= AccountValidation.maximumBodyBytes else { completionHandler(.cancel); finish(.failure(AccountError.responseTooLarge)); return }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count + data.count <= AccountValidation.maximumBodyBytes else { finish(.failure(AccountError.responseTooLarge)); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finish(.failure(error)) }
        else if let response { finish(.success((body, response))) }
        else { finish(.failure(AccountError.malformedResponse)) }
    }
}
