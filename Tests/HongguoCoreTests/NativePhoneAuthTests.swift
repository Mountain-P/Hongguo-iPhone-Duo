// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private func phoneDevice() throws -> AccountAppDevice {
    try .init(deviceID: "7391234567890123456", installID: "7391234567890123457", cdid: "00000000-0000-4000-8000-000000000001",
              clientUDID: "00000000-0000-4000-8000-000000000002", openUDID: "0011223344556677", createdAtMilliseconds: 1_728_000_000_000,
              registrationCookies: ["install_id": "7391234567890123457"])
}
private func phoneWrapper(_ payload: [String: Any], device: AccountAppDevice? = nil, cookies: [String: String] = [:], token: String? = nil) throws -> String {
    var value: [String: Any] = ["payload": payload, "cookies": cookies]
    if let device { value["device"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) }
    if let token { value["token"] = token }
    return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
}
private actor PhoneFixture {
    var requests: [NativePhoneAuthRequest] = []
    let sendError: String?
    let credentials: Bool
    let mismatch: Bool
    let mfa: Bool
    var verificationCount = 0
    init(sendError: String? = nil, credentials: Bool = true, mismatch: Bool = false, mfa: Bool = false) {
        self.sendError = sendError; self.credentials = credentials; self.mismatch = mismatch; self.mfa = mfa
    }
    func run(_ request: NativePhoneAuthRequest) throws -> String {
        requests.append(request)
        switch request.operation {
        case "register": return try phoneWrapper([:], device: phoneDevice())
        case "sendCode":
            if let sendError { return sendError }
            return try phoneWrapper(["message": "success", "data": ["retry_time": 73]], device: phoneDevice())
        case "loginSMS":
            if mfa, request.ticket == nil {
                return try phoneWrapper(["message": "error", "data": ["error_code": 1005, "encrypt_uid": "synthetic-encrypted-uid",
                    "sms_code_key": "synthetic-code-key", "event_params": ["log_id": "synthetic-log"], "passport_scene": "sms_login",
                    "verify_ways": [["verify_way": "upsms", "channel_mobile": "1069000000", "sms_content": "SYNTHETIC-VERIFY"]]]])
            }
            return try phoneWrapper(["message": "success", "data": ["user_id_str": "7701935931787316286",
                "user_id": mismatch ? "42" : "7701935931787316286", "screen_name": "合成帳號"]], device: phoneDevice(),
                cookies: credentials ? ["sessionid": "synthetic-session"] : [:])
        case "verifyMFA":
            verificationCount += 1
            return try phoneWrapper(verificationCount == 1 ? ["message": "error", "data": ["error_code": 1045]]
                : ["message": "success", "data": ["ticket": "synthetic-verified-ticket"]])
        default: throw PhoneAuthError.invalidResponse
        }
    }
}
private actor SuspendedPhoneFixture {
    var pending: CheckedContinuation<Void, Never>?
    var started = false
    var waiters: [CheckedContinuation<Void, Never>] = []
    var operations: [String] = []
    func run(_ request: NativePhoneAuthRequest) async throws -> String {
        operations.append(request.operation); started = true
        waiters.forEach { $0.resume() }; waiters = []
        await withCheckedContinuation { pending = $0 }
        return try phoneWrapper([:], device: phoneDevice())
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { waiters.append($0) } } }
    func release() { pending?.resume(); pending = nil }
}

struct NativePhoneAuthTests {
    @Test func normalizationKeepsFourteenSourceRegionsAndExactInternationalWireGrouping() throws {
        #expect(NativePhoneAuthService.countries.count == 14)
        for (code, local, expected) in [
            ("+86", "13800000000", "+8613800000000"), ("+852", "61234567", "+8526123 4567"),
            ("+853", "01234567", "+8530123 4567"), ("+886", "0912345678", "+886091 2345 678"),
            ("+60", "0123456789", "+60012 3456 789"), ("+65", "01234567", "+650123 4567"),
            ("+62", "0812345678901", "+62081 234 567 890 1"), ("+95", "0123456789", "+95012 3456 789"),
            ("+63", "0123456789", "+63012 3456 789"), ("+84", "0123456789", "+84012 3456 789"),
            ("+855", "012345678", "+855012 345 678"), ("+81", "01234567890", "+81012 3456 7890"),
            ("+82", "01234567890", "+82012 3456 7890"), ("+971", "012345678", "+971012 345 678")
        ] {
            let value = try PhoneAuthRules.phone(countryCode: code, local: local)
            #expect(value.canonical == code + local && value.wire == expected)
            #expect(try NativePhoneAuthService.normalize(countryCode: code, localNumber: local) == code + local)
        }
        #expect(try NativePhoneAuthService.normalize(countryCode: "886", localNumber: " 0912345678 ") == "+8860912345678")
    }

    @Test func invalidInputsNeverTriggerDeviceRegistrationOrSMS() async throws {
        let fixture = PhoneFixture(), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
        for local in ["１２３４５６７８", "123 45678", "123\n45678", "", "+85261234567"] {
            await #expect(throws: PhoneAuthError.invalidPhone) { try await service.sendCode(countryCode: "+852", localNumber: local) }
        }
        await #expect(throws: PhoneAuthError.unsupportedCountry) { try await service.sendCode(countryCode: "+1", localNumber: "1234567890") }
        await #expect(throws: PhoneAuthError.invalidPhone) { try await service.sendCode(countryCode: "+86", localNumber: "12000000000") }
        #expect(await fixture.requests.isEmpty)
    }

    @Test func SMSLoginKeepsTheRegisteredDevicePhoneAndServerCooldown() async throws {
        let fixture = PhoneFixture(), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
        let challenge = try await service.sendCode(countryCode: "+852", localNumber: "61234567")
        #expect(challenge.retryAfter == 73 && challenge.delivery == .sent && !challenge.maskedPhone.contains("61234567"))
        let result = try await service.loginSMS(challengeID: challenge.id, code: "001234")
        guard case .authenticated(let session) = result else { Issue.record("missing session"); return }
        let expectedDevice = try phoneDevice()
        #expect(session.profile.id == "7701935931787316286" && session.appDevice == expectedDevice)
        #expect(try NativePhoneAuthService.validateForLibrary(session: session) == session.profile)
        let requests = await fixture.requests
        #expect(requests.map(\.operation) == ["register", "sendCode", "loginSMS"])
        #expect(requests[1].device == requests[2].device && requests[2].phone == "+85261234567" && requests[2].wirePhone == "+8526123 4567")
        #expect(requests[2].code == "001234")
        await #expect(throws: PhoneAuthError.cooldown(73)) { try await service.sendCode(countryCode: "+852", localNumber: "61234567") }
    }

    @Test func wrongChallengeAndInvalidCodesDoNotLogin() async throws {
        let fixture = PhoneFixture(), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
        let challenge = try await service.sendCode(countryCode: "+852", localNumber: "61234567")
        await #expect(throws: PhoneAuthError.expired) { try await service.loginSMS(challengeID: UUID(), code: "123456") }
        for code in ["１２３４５６", "123", "123456789", "123 45", "123\n456"] {
            await #expect(throws: PhoneAuthError.invalidCode) { try await service.loginSMS(challengeID: challenge.id, code: code) }
        }
        #expect(await fixture.requests.count == 2)
    }

    @Test func uncertainDeliveryRemainsSubmitCapableAndDoesNotAutomaticallyResend() async throws {
        let fixture = PhoneFixture(sendError: #"{"error":"ETIMEDOUT"}"#), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
        let challenge = try await service.sendCode(countryCode: "+86", localNumber: "13800000000")
        #expect(challenge.delivery == .uncertain && challenge.retryAfter == 60)
        _ = try await service.loginSMS(challengeID: challenge.id, code: "123456")
        #expect(await fixture.requests.map(\.operation) == ["register", "sendCode", "loginSMS"])
    }

    @Test func explicitRefusalAndRateLimitDoNotBecomeUncertainDelivery() async throws {
        for (body, expected) in [(#"{"error":"HTTP_ERROR","status":403}"#, PhoneAuthError.denied(403)),
                                 (#"{"error":"HTTP_ERROR","status":429,"retryAfter":125}"#, .rateLimited(125))] {
            let fixture = PhoneFixture(sendError: body), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
            await #expect(throws: expected) { try await service.sendCode(countryCode: "+86", localNumber: "13800000000") }
            #expect(await fixture.requests.count == 2)
        }
    }

    @Test func loginRejectsMissingCredentialsAndMismatchedUIDs() async throws {
        #expect(throws: PhoneAuthError.invalidResponse) { try PhoneAuthRules.requireSuccess(["message": "success", "data": ["error_code": true]]) }
        #expect(throws: PhoneAuthError.invalidResponse) { try PhoneAuthRules.requireSuccess(["message": "success", "data": ["error_code": "invalid"]]) }
        #expect(throws: PhoneAuthError.rejected) { try PhoneAuthRules.requireSuccess(["message": "success", "error_code": 8, "data": ["error_code": 0]]) }
        for fixture in [PhoneFixture(credentials: false), PhoneFixture(mismatch: true)] {
            let service = NativePhoneAuthService(execute: { try await fixture.run($0) })
            let challenge = try await service.sendCode(countryCode: "+86", localNumber: "13800000000")
            do { _ = try await service.loginSMS(challengeID: challenge.id, code: "123456"); Issue.record("invalid login accepted") }
            catch { #expect(error is AccountError || error as? PhoneAuthError == .invalidResponse) }
            #expect(await fixture.requests.allSatisfy { !["validate", "userinfo"].contains($0.operation) })
        }
    }

    @Test func upSMSRequiresManualVerificationBeforeResumingTheOriginalLogin() async throws {
        let fixture = PhoneFixture(mfa: true), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
        let challenge = try await service.sendCode(countryCode: "+86", localNumber: "13800000000")
        guard case .verificationRequired(let mfa) = try await service.loginSMS(challengeID: challenge.id, code: "001234") else { Issue.record("missing MFA"); return }
        #expect(mfa.destination == "1069000000" && mfa.message == "SYNTHETIC-VERIFY")
        #expect(await fixture.requests.count == 3)
        #expect(try await service.verifyMFA(challengeID: mfa.id) == .verificationRequired(mfa))
        guard case .authenticated = try await service.verifyMFA(challengeID: mfa.id) else { Issue.record("verified login did not resume"); return }
        let requests = await fixture.requests
        #expect(requests.map(\.operation) == ["register", "sendCode", "loginSMS", "verifyMFA", "verifyMFA", "loginSMS"])
        #expect(requests.last?.code == "001234" && requests.last?.ticket == "synthetic-verified-ticket")
        #expect(requests.last?.device == requests[1].device && requests.last?.phone == requests[1].phone)
    }

    @Test func cancelledRegistrationCannotSendSMSOrRestoreAChallenge() async throws {
        let fixture = SuspendedPhoneFixture(), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
        let task = Task { try await service.sendCode(countryCode: "+86", localNumber: "13800000000") }
        await fixture.waitUntilStarted(); await service.cancel(); await fixture.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await fixture.operations == ["register"])
        await #expect(throws: PhoneAuthError.expired) { try await service.loginSMS(challengeID: UUID(), code: "123456") }
    }

    @Test func appTokenOnlySessionPersistsAndCannotLeakToWebsiteOrPlayback() throws {
        let session = try AccountSession(profile: .init(id: "42", nickname: "合成帳號"), cookies: [], token: "synthetic-app-token", appDevice: phoneDevice())
        let decoded = try JSONDecoder().decode(AccountSession.self, from: JSONEncoder().encode(session))
        #expect(decoded == session && decoded.token == "synthetic-app-token")
        #expect(try decoded.cookieHeader(for: URL(string: "https://api5-normal-lq.fqnovel.com/")!) == "")
        for raw in ["https://hongguoduanju.com/", "https://api5-normal-sinfonlinea.fqnovel.com/", "https://v1-default.ixigua.com/video.mp4"] {
            #expect(throws: AccountError.invalidCookies) { try decoded.cookieHeader(for: URL(string: raw)!) }
        }
        #expect(!String(reflecting: decoded).contains("synthetic-app-token"))
        #expect(!String(reflecting: try phoneDevice()).contains("7391234567890123456"))
        #expect(throws: AccountError.invalidCookies) { try AccountSession(profile: .init(id: "42", nickname: "x"), cookies: [], token: "injected\r\nHeader", appDevice: phoneDevice()) }
    }

    @Test func localValidationRejectsLegacyWebSessionsAndMalformedDeviceState() throws {
        let cookie = try AccountCookie(name: "sessionid", value: "synthetic", domain: ".hongguoduanju.com")
        let old = try AccountSession(profile: .init(id: "42", nickname: "合成"), cookies: [cookie])
        #expect(throws: AccountError.expired) { try NativePhoneAuthService.validateForLibrary(session: old) }
        let original = try JSONEncoder().encode(phoneDevice())
        var object = try #require(JSONSerialization.jsonObject(with: original) as? [String: Any]); object["deviceID"] = "0"
        #expect(throws: PhoneAuthError.invalidResponse) { try JSONDecoder().decode(AccountAppDevice.self, from: JSONSerialization.data(withJSONObject: object)) }
    }

    @Test func registrationProbeIsAnonymousAndReusedBySendCode() async throws {
        let fixture = PhoneFixture(), service = NativePhoneAuthService(execute: { try await fixture.run($0) })
        try await service.prepareRegistration(); try await service.prepareRegistration()
        #expect(await service.registeredDevice() != nil)
        let requests = await fixture.requests
        #expect(requests.count == 1 && requests[0].operation == "register" && requests[0].phone == nil && requests[0].cookies == nil && requests[0].token == nil)
        _ = try await service.sendCode(countryCode: "+86", localNumber: "13800000000")
        #expect(await fixture.requests.map(\.operation) == ["register", "sendCode"])
    }
}
