// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private struct RangeScenario: Sendable {
    var status = 206
    var excess = false
    var shortBodies = 0
    var delay: Double = 0.03
    var responseOutsidePolicy = false
    var redirectHosts: [String] = []
    var redirectedResponseHost: String?

    func nextRedirectHost(after host: String?) -> String? {
        guard let index = redirectHosts.firstIndex(where: { $0 == host }) else { return redirectHosts.first }
        return redirectHosts.dropFirst(index + 1).first
    }
}
private final class RangeScenarios: @unchecked Sendable {
    static let shared = RangeScenarios()
    private let lock = NSLock()
    private var values: [String: RangeScenario] = [:]
    private var active: [String: Int] = [:]
    private var peak: [String: Int] = [:]
    private var requests: [String: Int] = [:]
    func register(_ scenario: RangeScenario, host: String) -> URL {
        lock.withLock {
            let key = UUID().uuidString; values["/" + key] = scenario
            return URL(string: "https://\(host)/" + key)!
        }
    }
    func begin(_ path: String) -> RangeScenario? {
        lock.withLock {
            guard let scenario = values[path] else { return nil }
            if scenario.shortBodies > 0 { values[path]?.shortBodies -= 1 }
            active[path, default: 0] += 1; requests[path, default: 0] += 1
            peak[path] = max(peak[path, default: 0], active[path, default: 0]); return scenario
        }
    }
    func end(_ path: String) { lock.withLock { active[path, default: 0] -= 1 } }
    func counts(_ path: String) -> (peak: Int, requests: Int) { lock.withLock { (peak[path, default: 0], requests[path, default: 0]) } }
}

private final class RangeURLProtocol: URLProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var registered = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let scenario = RangeScenarios.shared.begin(url.path) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        lock.withLock { registered = true }
        let range = (request.value(forHTTPHeaderField: "Range") ?? "bytes=0-15").dropFirst(6).split(separator: "-")
        let first = Int(range[0])!, last = Int(range[1])!
        var headers = ["Content-Type": "video/mp4", "Content-Range": "bytes \(first)-\(last)/1000", "Content-Length": String(last - first + 1), "ETag": "fixture"]
        if scenario.shortBodies > 0 { headers.removeValue(forKey: "Content-Length") }
        let redirectURL = scenario.nextRedirectHost(after: url.host).map { URL(string: "https://" + $0 + url.path)! }
        let status = redirectURL == nil && !scenario.redirectHosts.isEmpty ? 206 : scenario.status
        if status == 403 { headers["Content-Type"] = "application/json"; headers["Content-Length"] = "999999999" }
        let blockedURL = URL(string: "https://blocked.invalid" + url.path)!
        if let redirectURL { headers["Location"] = redirectURL.absoluteString }
        var responseURL = scenario.responseOutsidePolicy ? blockedURL : url
        if redirectURL == nil, let host = scenario.redirectedResponseHost { responseURL = URL(string: "https://" + host + url.path)! }
        let response = HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        DispatchQueue.global().asyncAfter(deadline: .now() + scenario.delay) { [self] in
            guard !lock.withLock({ stopped }) else { return }
            if let redirectURL {
                var redirected = request
                redirected.url = redirectURL
                client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard !lock.withLock({ stopped }) else { return }
            let byteCount = last - first + 1 + (scenario.excess ? 1 : 0) - (scenario.shortBodies > 0 ? 1 : 0)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x55, count: byteCount))
            end()
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { end() }
    private func end() {
        let finish = lock.withLock { () -> Bool in
            guard !stopped else { return false }; stopped = true
            return registered
        }
        if finish, let path = request.url?.path { RangeScenarios.shared.end(path) }
    }
}

struct NativeRangeHTTPTests {
    private let scheduledOrigin = "v5-reading-video-a.qznovelvod.com"

    private func client(_ scenario: RangeScenario, host: String = "unit.fqnovelvod.com") throws -> (NativeRangeHTTP, URL) {
        let url = RangeScenarios.shared.register(scenario, host: host)
        let source = NativeMediaSource(url: url, contentKey: nil, userAgent: "Fixture", codec: "h264", quality: "1080p")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RangeURLProtocol.self]
        return (try NativeRangeHTTP(source: source, configuration: configuration), url)
    }

    @Test func actualURLSessionLimitsConcurrencyAndCancellationIsPerRequest() async throws {
        let (client, url) = try client(.init(delay: 0.06)); defer { client.close() }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    let response = try await client.fetch(range: (index * 16)..<(index * 16 + 16))
                    #expect(response.data == Data(repeating: 0x55, count: 16))
                }
            }
            try await group.waitForAll()
        }
        #expect(RangeScenarios.shared.counts(url.path).peak <= 2)
        let cancelled = Task { try await client.fetch(range: 200..<216) }
        let retained = Task { try await client.fetch(range: 300..<316) }
        try await Task.sleep(for: .milliseconds(10)); cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await retained.value.data.count == 16)
        #expect(try await client.fetch(range: 400..<416).data.count == 16)
        #expect(RangeScenarios.shared.counts(url.path).peak <= 2)
    }

    @Test func delegateRejectsExtraBytesAndRangeIgnoringServers() async throws {
        let (excess, _) = try client(.init(excess: true)); defer { excess.close() }
        await #expect(throws: NativeProgressiveError.invalidRange) { try await excess.fetch(range: 0..<16) }
        let (ignored, _) = try client(.init(status: 200)); defer { ignored.close() }
        await #expect(throws: NativeProgressiveError.unsupportedRange) { try await ignored.fetch(range: 0..<16) }
    }

    @Test func validRangeWithAnEarlyEndIsRetriedOnce() async throws {
        let (client, url) = try client(.init(shortBodies: 1)); defer { client.close() }
        let range = 32..<48
        let response = try await client.fetch(range: range)
        #expect(response.range == range)
        #expect(response.data == Data(repeating: 0x55, count: range.count))
        #expect(RangeScenarios.shared.counts(url.path).requests == 2)
    }

    @Test func repeatedEarlyEndsReturnANetworkErrorAfterTwoAttempts() async throws {
        let (client, url) = try client(.init(shortBodies: 3)); defer { client.close() }
        await #expect(throws: NativeMediaError.network) { try await client.fetch(range: 32..<48) }
        #expect(RangeScenarios.shared.counts(url.path).requests == 2)
    }

    @Test func authorizationDenialIsTerminalDespiteHugeBinaryBody() async throws {
        let (client, url) = try client(.init(status: 403)); defer { client.close() }
        await #expect(throws: CatalogError.httpStatus(403)) { try await client.fetch(range: 0..<16) }
        let count = RangeScenarios.shared.counts(url.path).requests
        await #expect(throws: CatalogError.httpStatus(403)) { try await client.fetch(range: 32..<48) }
        #expect(RangeScenarios.shared.counts(url.path).requests == count)
    }

    @Test func rejectedFinalResponseRetiresActiveAndQueuedReads() async throws {
        let (client, url) = try client(.init(responseOutsidePolicy: true)); defer { client.close() }
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<6 {
                group.addTask {
                    await #expect(throws: NativeMediaError.unsafeURL) {
                        try await client.fetch(range: (16 * index)..<(16 * (index + 1)))
                    }
                }
            }
        }
        let requests = RangeScenarios.shared.counts(url.path).requests
        #expect((1...2).contains(requests))
        await #expect(throws: NativeMediaError.unsafeURL) { try await client.fetch(range: 200..<216) }
        #expect(RangeScenarios.shared.counts(url.path).requests == requests)
    }

    @Test func rejectedRedirectDoesNotFollowTargetOrStartMoreReads() async throws {
        let (client, url) = try client(.init(status: 302, redirectHosts: ["blocked.invalid"])); defer { client.close() }
        await #expect(throws: NativeMediaError.unsafeURL) { try await client.fetch(range: 0..<16) }
        await #expect(throws: NativeMediaError.unsafeURL) { try await client.fetch(range: 32..<48) }
        #expect(RangeScenarios.shared.counts(url.path).requests == 1)
    }

    @Test func approvedSchedulerRedirectFollowsForEachRange() async throws {
        for (origin, targets) in [(scheduledOrigin, ["relay-a9.vegslb.com"]),
                                  ("v5-reading-video-b.qznovelvod.com", ["relay-b7.bdcgslb.com"]),
                                  ("v5-ex-reading-video-a.qznovelvod.com", ["relay-b7.bdcgslb.com"]),
                                  (scheduledOrigin, ["relay-a9.vegslb.com", "relay-b7.bdcgslb.com"])] {
            let (client, url) = try client(.init(status: 302, redirectHosts: targets), host: origin)
            defer { client.close() }
            for range in [0..<16, 32..<48] {
                #expect(try await client.fetch(range: range).range == range)
            }
            #expect(RangeScenarios.shared.counts(url.path).requests == 2 * (targets.count + 1))
        }
    }

    @Test func schedulerExceptionRejectsOtherOriginsRedirectCodesAndDestinations() async throws {
        for (origin, status, targets, requests) in [
            ("unit.qznovelvod.com", 302, ["relay-a.vegslb.com"], 1),
            (scheduledOrigin, 307, ["relay-a.vegslb.com"], 1),
            (scheduledOrigin, 302, ["relay-a.vegslb.com.blocked.invalid"], 1),
            (scheduledOrigin, 302, ["one.two.vegslb.com"], 1),
            (scheduledOrigin, 302, ["another.fqnovelvod.com", "relay-a.vegslb.com"], 2),
            (scheduledOrigin, 302, ["relay-a.vegslb.com", "relay-b.vegslb.com"], 2),
            (scheduledOrigin, 302, ["relay-a.bdcgslb.com", "relay-b.vegslb.com"], 2),
            (scheduledOrigin, 302, ["relay-a.vegslb.com", "relay-b.bdcgslb.com", "relay-c.bdcgslb.com"], 3),
        ] {
            let (client, url) = try client(.init(status: status, redirectHosts: targets), host: origin)
            defer { client.close() }
            await #expect(throws: NativeMediaError.unsafeURL) { try await client.fetch(range: 0..<16) }
            #expect(RangeScenarios.shared.counts(url.path).requests == requests)
        }
    }

    @Test func schedulerDestinationCannotBeUsedAsADirectSourceOrSubstituteResponse() async throws {
        #expect(throws: NativeMediaError.unsafeURL) { try client(.init(), host: "relay-a.vegslb.com") }
        let scenario = RangeScenario(status: 302, redirectHosts: ["relay-a.vegslb.com"], redirectedResponseHost: "relay-b.vegslb.com")
        let (client, url) = try client(scenario, host: scheduledOrigin)
        defer { client.close() }
        await #expect(throws: NativeMediaError.unsafeURL) { try await client.fetch(range: 0..<16) }
        #expect(RangeScenarios.shared.counts(url.path).requests == 2)
    }

    @Test func scheduledDestinationRequiresOneLowercaseASCIIDNSLabelAndAnOrdinaryHTTPSURL() {
        let origin = URL(string: "https://\(scheduledOrigin)/v")!
        #expect(NativeMediaPolicy.allowsScheduledCDNRedirect(from: origin, to: URL(string: "https://a-9.vegslb.com:443/v")))
        for address in [
            "https://vegslb.com/v", "https://a.b.vegslb.com/v", "https://a.vegslb.com.invalid/v",
            "https://A.vegslb.com/v", "https://%61.vegslb.com/v", "https://-a.vegslb.com/v",
            "https://a-.vegslb.com/v", "https://a_.vegslb.com/v", "https://127.0.0.1/v",
            "https://a.vegslb.com:444/v", "https://user@a.vegslb.com/v", "https://a.vegslb.com/v#section",
            "http://a.vegslb.com/v", "https://" + String(repeating: "a", count: 64) + ".vegslb.com/v",
        ] {
            #expect(!NativeMediaPolicy.allowsScheduledCDNRedirect(from: origin, to: URL(string: address)))
        }
    }

    @Test func rejectionReasonsPreserveTheExistingURLAndRedirectLimits() {
        let allowed = URL(string: "https://unit.fqnovelvod.com:443/v?fixture=true")!
        #expect(NativeMediaPolicy.rejection(of: allowed) == nil)
        #expect(NativeMediaPolicy.rejection(of: nil) == .missingURL)
        for (address, reason): (String, NativeMediaPolicy.Rejection) in [
            ("http://unit.fqnovelvod.com/v", .scheme),
            ("https://user@unit.fqnovelvod.com/v", .credentials),
            ("https://unit.fqnovelvod.com/v#fixture", .fragment),
            ("https://unit.fqnovelvod.com:444/v", .port),
            ("https://fqnovelvod.com.blocked.invalid/v", .host),
            ("https://unit.fqnovelvod.com/" + String(repeating: "x", count: 32_768), .urlLength)
        ] {
            #expect(NativeMediaPolicy.rejection(of: URL(string: address)) == reason)
        }
        #expect(NativeMediaPolicy.redirectRejection(of: allowed, hops: 3) == nil)
        #expect(NativeMediaPolicy.redirectRejection(of: allowed, hops: 4) == .redirectLimit)
        for (agent, reason): (String, NativeMediaPolicy.Rejection) in [
            ("Fixture\u{0001}", .userAgentControlCharacter),
            (String(repeating: "x", count: 2049), .userAgentLength)
        ] {
            let source = NativeMediaSource(url: allowed, contentKey: nil, userAgent: agent, codec: "h264", quality: "1080p")
            #expect(NativeMediaPolicy.sourceRejection(source) == reason)
        }
    }
}
