// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private final class IdentityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

struct NativePlaybackIdentityCacheTests {
    private let identity = #"{"device_id":"700000000000000001","iid":"700000000000000002","cdid":"96641666-28a2-4fbd-a83e-ef77e1df15d7"}"#

    @Test func cacheIsScopedExpiresAndRejectsAccountsOrInvalidIDs() throws {
        let clock = IdentityClock(), cache = NativePlaybackIdentityCache(now: clock.now)
        #expect(cache.write(scope: "tab", json: identity))
        #expect(cache.read(scope: "tab") == identity)
        #expect(cache.read(scope: "legacy") == "null")
        #expect(!cache.write(scope: "account", json: identity))
        #expect(!cache.write(scope: "tab", json: identity.replacingOccurrences(of: "700000000000000001", with: "0")))
        var account = try #require(JSONSerialization.jsonObject(with: Data(identity.utf8)) as? [String: String])
        account["cookie"] = "sessionid=fixture"
        #expect(!cache.write(scope: "tab", json: String(decoding: try JSONSerialization.data(withJSONObject: account), as: UTF8.self)))
        #expect(cache.read(scope: "tab") == identity)
        clock.advance(299)
        #expect(cache.read(scope: "tab") == identity)
        clock.advance(1)
        #expect(cache.read(scope: "tab") == "null")
    }

    @Test func separateRuntimesReuseAnonymousIdentityAndFreshLegacyStillRegisters() async throws {
        let cache = NativePlaybackIdentityCache()
        func register(scope: String, fresh: Bool = false, zero: Bool = false) async throws -> [String: Any] {
            let script = #"""
            (async () => {
              let requests = 0;
              globalThis._nativeHTTP = (id, json) => {
                requests++;
                const body = {device_id_str: 'DEVICE', install_id_str: 'INSTALL'};
                __httpDone(id, JSON.stringify({status:200, headers:{}, data:JSON.stringify(body)}));
              };
              try {
                const value = await require('app-source').audit.playbackDevice({scope:'SCOPE', fresh:FRESH, deadline:Date.now()+1000});
                return {requests, id:value.device_id};
              } catch(e) { return {requests, error:e.code}; }
            })()
            """#.replacingOccurrences(of: "DEVICE", with: zero ? "0" : "700000000000000001")
                .replacingOccurrences(of: "INSTALL", with: zero ? "0" : "700000000000000002")
                .replacingOccurrences(of: "SCOPE", with: scope)
                .replacingOccurrences(of: "FRESH", with: fresh ? "true" : "false")
            let raw = try await NativeJSRuntime(identityCache: cache).evaluateForTesting(script)
            return try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        }
        #expect(try await register(scope: "tab")["requests"] as? Int == 1)
        #expect(try await register(scope: "tab")["requests"] as? Int == 0)
        #expect(try await register(scope: "legacy")["requests"] as? Int == 1)
        #expect(try await register(scope: "legacy")["requests"] as? Int == 0)
        #expect(try await register(scope: "legacy", fresh: true)["requests"] as? Int == 1)
        // A failed renewal must not replace the last valid anonymous identity.
        #expect(try await register(scope: "legacy", fresh: true, zero: true)["error"] as? String == "DEVICE_REGISTRATION_FAILED")
        #expect(try await register(scope: "legacy")["requests"] as? Int == 0)
        #expect(try await register(scope: "tab")["requests"] as? Int == 0)
    }
}
