// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private actor AccountFixtureTransport: HTTPTransport {
    let body: Data
    let status: Int
    let responseURL: URL?
    let cancelOnRead: Bool
    var requests: [URLRequest] = []
    init(_ body: String, status: Int = 200, responseURL: URL? = nil, cancelOnRead: Bool = false) {
        self.body = Data(body.utf8); self.status = status; self.responseURL = responseURL; self.cancelOnRead = cancelOnRead
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if cancelOnRead { withUnsafeCurrentTask { $0?.cancel() } }
        return (body, HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private final class AccountFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let scenario = url.lastPathComponent
        DispatchQueue.global().asyncAfter(deadline: .now() + (scenario == "slow" ? 0.2 : 0.01)) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            let denied = scenario == "denied"
            let response = HTTPURLResponse(url: url, statusCode: denied ? 403 : 200, httpVersion: nil,
                headerFields: ["Content-Length": scenario == "huge-header" || denied ? "999999999" : "1"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard !lock.withLock({ stopped }) else { return }
            client?.urlProtocol(self, didLoad: Data(repeating: 0xff, count: scenario == "excess" ? 2_097_153 : 1))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { lock.withLock { stopped = true } }
}

struct AccountSessionTests {
    private let success = #"{"message":"SUCCESS","data":{"user_id_str":"7701935931787316286","user_id":7701935931787316286,"name":"<b>合成帳號</b>","avatar_url":"https://example.test/avatar.jpg","mobile":"09*****123"}}"#
    private func cookie(name: String = "sessionid", value: String = "synthetic-private-value", expiresAt: Date? = nil) throws -> AccountCookie {
        try AccountCookie(name: name, value: value, domain: ".hongguoduanju.com", expiresAt: expiresAt)
    }

    @Test func officialWebContractKeepsCredentialsOutOfTheURL() async throws {
        let transport = AccountFixtureTransport(success)
        let profile = try await WebAccountService(transport: transport).validate(cookies: [cookie()])
        #expect(profile == AccountProfile(id: "7701935931787316286", nickname: "合成帳號", avatar: URL(string: "https://example.test/avatar.jpg"), maskedPhone: "09*****123"))
        let request = try #require(await transport.requests.first)
        let url = try #require(request.url), components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(request.httpMethod == "GET" && request.httpBody == nil)
        #expect(url.scheme == "https" && url.host == "hongguoduanju.com" && components.path == "/passport/account/info/v2/")
        #expect(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }) == [
            "aid": "513755", "passport_jssdk_version": "3.4.10", "passport_jssdk_type": "normal",
            "account_sdk_source": "web", "is_from_ttaccountsdk": "1", "language": "zh"])
        #expect(!url.absoluteString.contains("synthetic-private-value"))
        #expect(request.value(forHTTPHeaderField: "Cookie") == "sessionid=synthetic-private-value")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://hongguoduanju.com")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://hongguoduanju.com/")
    }

    @Test func cookieScopeAndHeaderInjectionAreRejected() throws {
        for (name, value, domain, path, secure) in [
            ("unrecognized", "value", "hongguoduanju.com", "/", true),
            ("sessionid", "secret\r\nInjected:yes", "hongguoduanju.com", "/", true),
            ("sessionid", "one; another=two", "hongguoduanju.com", "/", true),
            ("sessionid", "value", "hongguoduanju.com.attacker.test", "/", true),
            ("sessionid", "value", "attacker.hongguoduanju.com", "/", true),
            ("sessionid", "value", "hongguoduanju.com", "/passport", true),
            ("sessionid", "value", "hongguoduanju.com", "/", false),
            ("sessionid", String(repeating: "a", count: 4097), "hongguoduanju.com", "/", true)
        ] {
            #expect(throws: AccountError.invalidCookies) { try AccountCookie(name: name, value: value, domain: domain, path: path, isSecure: secure) }
        }
        let secret = try cookie()
        #expect(!String(describing: secret).contains("synthetic-private-value"))
        #expect(!String(reflecting: secret).contains("synthetic-private-value"))
    }

    @Test func expiredMissingDuplicateAndOversizedCookieSetsStopBeforeNetwork() async throws {
        let transport = AccountFixtureTransport(success), service = WebAccountService(transport: transport)
        await #expect(throws: AccountError.expired) { try await service.validate(cookies: [cookie(expiresAt: .distantPast)]) }
        await #expect(throws: AccountError.expired) { try await service.validate(cookies: [cookie(name: "sid_tt")]) }
        await #expect(throws: AccountError.invalidCookies) { try await service.validate(cookies: []) }
        await #expect(throws: AccountError.invalidCookies) { try await service.validate(cookies: [cookie(), cookie(value: "different")]) }
        let oversized = try ["sessionid", "sid_tt", "uid_tt", "ttwid", "passport_csrf_token"].map { try cookie(name: $0, value: String(repeating: "a", count: 4096)) }
        await #expect(throws: AccountError.invalidCookies) { try await service.validate(cookies: oversized) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func sessionEncodingIsValidatedAndCredentialUseIsExplicitlyScoped() throws {
        let profile = AccountProfile(id: "7701935931787316286", nickname: "合成帳號")
        let session = try AccountSession(profile: profile, cookies: [cookie()], expiresAt: Date().addingTimeInterval(3600))
        let decoded = try JSONDecoder().decode(AccountSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session)
        #expect(try decoded.cookieHeader(for: URL(string: "https://hongguoduanju.com/passport/account/info/v2/")!) == "sessionid=synthetic-private-value")
        #expect(try decoded.cookieHeader(for: URL(string: "https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/read_history/list/v1/")!) == "sessionid=synthetic-private-value")
        for raw in ["https://attacker.test/", "http://hongguoduanju.com/", "https://user:password@hongguoduanju.com/", "https://hongguoduanju.com:444/", "https://v1-default.ixigua.com/video.mp4"] {
            #expect(throws: AccountError.invalidCookies) { try decoded.cookieHeader(for: URL(string: raw)!) }
        }
        #expect(!String(reflecting: decoded).contains("synthetic-private-value"))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any])
        var cookies = try #require(object["cookies"] as? [[String: Any]])
        cookies[0]["domain"] = "attacker.test"; object["cookies"] = cookies
        #expect(throws: AccountError.invalidCookies) { try JSONDecoder().decode(AccountSession.self, from: JSONSerialization.data(withJSONObject: object)) }
        #expect(throws: AccountError.expired) { try AccountSession(profile: profile, cookies: [cookie()], expiresAt: .distantPast) }
    }

    @Test func profileRequiresUnambiguousExactNonzeroIDs() async throws {
        for raw in [
            #"{"message":"success","data":{"user_id_str":"0"}}"#,
            #"{"message":"success","data":{"user_id_str":"7701935931787316286","user_id":7701935931787316287}}"#,
            #"{"message":"success","data":{"user_id_str":"42","user_id":true}}"#,
            #"{"message":"success","data":{"user_id_str":"42","user_id":42.5}}"#,
            #"{"message":"success","data":{"user_id_str":"+42"}}"#,
            #"{"message":"success","data":{"user_id_str":"42\n"}}"#,
            #"{"message":"success","data":{"name":"anonymous"}}"#,
            #"{"message":"success","data":{"user_id_str":"1111111111111111111111111111111"}}"#
        ] {
            await #expect(throws: AccountError.malformedResponse) { try await WebAccountService(transport: AccountFixtureTransport(raw)).validate(cookies: [cookie()]) }
        }
        let numeric = #"{"message":"success","data":{"user_id":7701935931787316286}}"#
        #expect(try await WebAccountService(transport: AccountFixtureTransport(numeric)).validate(cookies: [cookie()]).id == "7701935931787316286")
    }

    @Test func businessFailureAndExpiredHTTPNeverBecomeSuccess() async throws {
        for raw in [
            #"{"message":"success","code":1,"data":{"user_id_str":"42"}}"#,
            #"{"message":"success","data":{"user_id_str":"42","error_code":8}}"#,
            #"{"message":"error","data":{"user_id_str":"42"},"description":"sessionid=do-not-echo https://secret.test/"}"#
        ] {
            do { _ = try await WebAccountService(transport: AccountFixtureTransport(raw)).validate(cookies: [cookie()]); Issue.record("accepted rejected login") }
            catch let e as AccountError { #expect(e == .authenticationFailed); #expect(!e.localizedDescription.contains("do-not-echo")); #expect(!e.localizedDescription.contains("https://")) }
        }
        await #expect(throws: AccountError.expired) { try await WebAccountService(transport: AccountFixtureTransport("not-json", status: 401)).validate(cookies: [cookie()]) }
        await #expect(throws: AccountError.denied(403)) { try await WebAccountService(transport: AccountFixtureTransport(String(repeating: "x", count: 2_097_153), status: 403)).validate(cookies: [cookie()]) }
        await #expect(throws: AccountError.expired) { try await WebAccountService(transport: AccountFixtureTransport(#"{"message":"error","data":{"error_code":401}}"#)).validate(cookies: [cookie()]) }
        await #expect(throws: AccountError.expired) { try await WebAccountService(transport: AccountFixtureTransport(#"{"message":"error","data":{"error_code":13}}"#)).validate(cookies: [cookie()]) }
    }

    @Test func malformedOversizedAndRedirectResponsesAreRejected() async throws {
        for body in ["", "<html>login</html>", "{}", #"{"message":"success","data":[]}"#] {
            do { _ = try await WebAccountService(transport: AccountFixtureTransport(body)).validate(cookies: [cookie()]); Issue.record("accepted malformed response") }
            catch let e as AccountError { #expect(e == .malformedResponse || e == .authenticationFailed) }
        }
        await #expect(throws: AccountError.responseTooLarge) { try await WebAccountService(transport: AccountFixtureTransport(String(repeating: "x", count: 2_097_153))).validate(cookies: [cookie()]) }
        await #expect(throws: AccountError.denied(302)) { try await WebAccountService(transport: AccountFixtureTransport("", status: 302)).validate(cookies: [cookie()]) }
        await #expect(throws: AccountError.denied(200)) { try await WebAccountService(transport: AccountFixtureTransport(success, responseURL: URL(string: "https://attacker.test/"))).validate(cookies: [cookie()]) }
    }

    @Test func restoredSessionCannotChangeAccountIdentity() async throws {
        let session = try AccountSession(profile: .init(id: "42", nickname: "合成帳號"), cookies: [cookie()])
        await #expect(throws: AccountError.expired) { try await WebAccountService(transport: AccountFixtureTransport(success)).validate(session: session) }
    }

    @Test func privateProfileFieldsAreNotPublishedAndCancellationWins() async throws {
        let body = #"{"message":"success","data":{"user_id_str":"42","name":"ok\nname","mobile":"0912345678","avatar_url":"http://attacker.test/image"}}"#
        let profile = try await WebAccountService(transport: AccountFixtureTransport(body)).validate(cookies: [cookie()])
        #expect(profile.maskedPhone.isEmpty && profile.avatar == nil && profile.nickname == "okname")
        let transport = AccountFixtureTransport(success, cancelOnRead: true)
        let task = Task { try await WebAccountService(transport: transport).validate(cookies: [cookie()]) }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func actualHTTPDelegateBoundsBodyAndPreservesDenialBeforeReadingIt() async throws {
        func transfer(_ scenario: String) async throws -> (Data, HTTPURLResponse) {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AccountFixtureURLProtocol.self]
            return try await WebAccountTransfer(configuration: config).run(URLRequest(url: URL(string: "https://hongguoduanju.com/" + scenario)!))
        }
        await #expect(throws: AccountError.responseTooLarge) { try await transfer("huge-header") }
        await #expect(throws: AccountError.responseTooLarge) { try await transfer("excess") }
        let (body, response) = try await transfer("denied")
        #expect(response.statusCode == 403 && body.isEmpty)
    }

    @Test func actualHTTPDelegateCancellationDoesNotAffectAnotherTransaction() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AccountFixtureURLProtocol.self]
        let one = WebAccountTransfer(configuration: config), two = WebAccountTransfer(configuration: config)
        let request = URLRequest(url: URL(string: "https://hongguoduanju.com/slow")!)
        let cancelled = Task { try await one.run(request) }, retained = Task { try await two.run(request) }
        try await Task.sleep(for: .milliseconds(20)); cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await retained.value.0.count == 1)
    }
}
