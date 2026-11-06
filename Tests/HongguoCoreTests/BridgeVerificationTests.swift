import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HongguoCore

private struct VerificationReply: Sendable {
    let body: String
    let status: Int
    let error: CatalogError?
    let cancelsTask: Bool

    init(_ body: String, status: Int = 200, cancelsTask: Bool = false) {
        self.body = body; self.status = status; self.error = nil; self.cancelsTask = cancelsTask
    }

    init(error: CatalogError) {
        self.body = ""; self.status = 200; self.error = error; self.cancelsTask = false
    }
}

private actor VerificationTransport: HTTPTransport {
    private var replies: [VerificationReply]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [VerificationReply]) { self.replies = replies }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else { throw CatalogError.network }
        let reply = replies.removeFirst()
        if let error = reply.error { throw error }
        if reply.cancelsTask { withUnsafeCurrentTask { $0?.cancel() } }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status,
                                       httpVersion: "HTTP/1.1", headerFields: [:])!
        return (Data(reply.body.utf8), response)
    }
}

private let validBridgeHealth = #"{"service":"hongguotv","apiVersion":1,"upstream":"unverified"}"#
private let validBridgeHome = #"{"items":[{"id":"100","title":"驗證劇集"}],"page":1}"#
private let validBridgeDetail = #"{"id":"100","title":"驗證劇集","episodes":[{"id":"200","number":1,"title":"第一集"},{"id":"201","number":2,"title":"第二集"}]}"#

private func verificationService(_ transport: VerificationTransport) throws -> BridgeService {
    BridgeService(configuration: try .init(baseURL: "https://bridge.example/mount", token: "verification-test-token"),
                  transport: transport)
}

@MainActor
struct BridgeVerificationTests {
    @Test
    func connectionChecksIdentityBeforeCatalogueAndAuthenticatesBoth() async throws {
        let transport = VerificationTransport([.init(validBridgeHealth), .init(validBridgeHome)])
        let count = try await verificationService(transport).verifyConnection()
        #expect(count == 1)
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == ["/mount/health", "/mount/api/home"])
        #expect(requests.last?.url?.query == "page=1")
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer verification-test-token" })
    }

    @Test
    func detailChecksIdentityAndBindsReturnedSeries() async throws {
        let transport = VerificationTransport([.init(validBridgeHealth), .init(validBridgeDetail)])
        let detail = try await verificationService(transport).verifiedDetail(id: "100")
        #expect(detail.series.id == "100")
        #expect(detail.episodes.map(\.id) == ["200", "201"])
        let requests = await transport.requests
        #expect(requests.map { $0.url?.path } == ["/mount/health", "/mount/api/series/100"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer verification-test-token" })
    }

    @Test
    func bridgeAvailabilityUsesOnlyExplicitBooleanAndPreservesDenial() async throws {
        let payload = #"{"id":"100","title":"驗證劇集","accessible_episode_cnt":1,"episodes":[{"id":"200","number":1,"isAvailable":true},{"id":"201","number":2},{"id":"202","number":3,"isAvailable":false}]}"#
        let directTransport = VerificationTransport([.init(payload)])
        let directDetail = try await verificationService(directTransport).detail(id: "100")
        #expect(directDetail.episodes.map(\.isAvailable) == [true, true, false])

        let verifiedTransport = VerificationTransport([.init(validBridgeHealth), .init(payload)])
        let verifiedDetail = try await verificationService(verifiedTransport).verifiedDetail(id: "100")
        #expect(verifiedDetail.episodes.map(\.isAvailable) == [true, true, false])
    }

    @Test
    func bridgeAvailabilityRejectsNumbersStringsAndNull() async throws {
        for raw in ["1", "0", #""false""#, "null"] {
            let payload = "{\"id\":\"100\",\"title\":\"驗證劇集\",\"episodes\":[{\"id\":\"200\",\"number\":1,\"isAvailable\":\(raw)}]}"
            let transport = VerificationTransport([.init(payload)])
            await #expect(throws: CatalogError.malformedResponse) {
                try await verificationService(transport).detail(id: "100")
            }
        }
    }

    @Test
    func foreignServiceOrAPIVersionStopsBeforeCatalogue() async throws {
        for payload in [#"{"service":"quest-downloader","apiVersion":1}"#,
                        #"{"service":"hongguotv","apiVersion":2}"#,
                        #"{"service":"hongguotv"}"#] {
            let transport = VerificationTransport([.init(payload), .init(validBridgeHome)])
            await #expect(throws: CatalogError.incompatibleBridge) {
                try await verificationService(transport).verifyConnection()
            }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test
    func HTMLLoginAndMalformedHealthAreNotAcceptedAsBridge() async throws {
        for payload in ["<html><title>Sign in</title></html>", "[]", "{}", "not JSON"] {
            let transport = VerificationTransport([.init(payload), .init(validBridgeHome)])
            await #expect(throws: CatalogError.incompatibleBridge) {
                try await verificationService(transport).verifyConnection()
            }
            #expect(await transport.requests.count == 1)
        }
    }

    @Test
    func correctHealthDoesNotHideWrongCatalogueSchema() async throws {
        let transport = VerificationTransport([.init(validBridgeHealth), .init(#"{"downloads":[]}"#)])
        await #expect(throws: CatalogError.incompatibleBridge) {
            try await verificationService(transport).verifyConnection()
        }
        #expect(await transport.requests.count == 2)
    }

    @Test
    func mismatchedSeriesIsRejectedAfterSuccessfulHealth() async throws {
        let wrong = validBridgeDetail.replacingOccurrences(of: #""id":"100""#, with: #""id":"999""#)
        let transport = VerificationTransport([.init(validBridgeHealth), .init(wrong)])
        await #expect(throws: CatalogError.incompatibleBridge) {
            try await verificationService(transport).verifiedDetail(id: "100")
        }
        #expect(await transport.requests.count == 2)
    }

    @Test
    func authenticationAndHTTPFailuresKeepTheirMeaning() async throws {
        for (status, expected) in [(401, CatalogError.unauthorized), (403, .httpStatus(403)),
                                   (404, .httpStatus(404)), (502, .httpStatus(502))] {
            let transport = VerificationTransport([.init("<html>upstream</html>", status: status)])
            await #expect(throws: expected) {
                try await verificationService(transport).verifyConnection()
            }
            #expect(await transport.requests.count == 1)
        }
        let transport = VerificationTransport([.init(validBridgeHealth), .init("{}", status: 401)])
        await #expect(throws: CatalogError.unauthorized) {
            try await verificationService(transport).verifiedDetail(id: "100")
        }
        #expect(CatalogError.httpStatus(403).localizedDescription.contains("拒絕存取"))
        #expect(CatalogError.unauthorized.localizedDescription.contains("口令不正確"))
    }

    @Test
    func networkFailureIsNotMisreportedAsIncompatibleBridge() async throws {
        let transport = VerificationTransport([.init(error: .network)])
        await #expect(throws: CatalogError.network) {
            try await verificationService(transport).verifyConnection()
        }
    }

    @Test
    func invalidSeriesIdentifierDoesNotSendCredentials() async throws {
        let transport = VerificationTransport([.init(validBridgeHealth)])
        await #expect(throws: CatalogError.invalidID) {
            try await verificationService(transport).verifiedDetail(id: "../private")
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test
    func cancellationStopsBeforeSendingOrBeforeCatalogueFollowUp() async throws {
        let before = VerificationTransport([.init(validBridgeHealth), .init(validBridgeHome)])
        let beforeTask = Task { try await verificationService(before).verifyConnection() }
        beforeTask.cancel()
        await #expect(throws: CancellationError.self) { try await beforeTask.value }
        #expect(await before.requests.isEmpty)

        let during = VerificationTransport([.init(validBridgeHealth, cancelsTask: true), .init(validBridgeHome)])
        let duringTask = Task { try await verificationService(during).verifyConnection() }
        await #expect(throws: CancellationError.self) { try await duringTask.value }
        #expect(await during.requests.count == 1)
    }
}
