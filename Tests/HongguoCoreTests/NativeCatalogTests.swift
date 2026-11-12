import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HongguoCore

private actor NativeCatalogueTransport: HTTPTransport {
    let body: Data
    let status: Int
    let firstStatus: Int?
    private(set) var requests: [URLRequest] = []
    init(body: String, status: Int = 200, firstStatus: Int? = nil) {
        self.body = Data(body.utf8); self.status = status; self.firstStatus = firstStatus
    }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let status = requests.count == 1 ? (firstStatus ?? status) : status
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

private actor NativePreparationRecorder {
    struct Call: Equatable, Sendable { let episodeID: String; let contentType: String; let fresh: Bool }
    private(set) var calls: [Call] = []
    func prepare(episodeID: String, contentType: String, fresh: Bool) -> URL {
        calls.append(.init(episodeID: episodeID, contentType: contentType, fresh: fresh))
        return URL(fileURLWithPath: "/private/tmp/native-catalog-fixture.mp4")
    }
}

private actor CancellingCatalogueTransport: HTTPTransport {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(for: .seconds(30))
        throw CatalogError.network
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor NativeQualityPreparationRecorder {
    struct Call: Equatable, Sendable {
        let episodeID: String
        let contentType: String
        let fresh: Bool
        let quality: NativePlaybackQuality
    }
    private(set) var calls: [Call] = []
    func prepare(_ episodeID: String, _ contentType: String, _ fresh: Bool,
                 _ quality: NativePlaybackQuality) -> PlaybackSource {
        calls.append(.init(episodeID: episodeID, contentType: contentType, fresh: fresh, quality: quality))
        return PlaybackSource(url: URL(fileURLWithPath: "/private/tmp/native-quality-fixture.mp4"))
    }
}

private actor CancellingNativePreparation {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var calls = 0
    func prepare() async throws -> URL {
        calls += 1
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        try await Task.sleep(for: .seconds(30))
        throw CatalogError.network
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
}

private actor OfflineSourceProbe: NativeOfflineMediaDownloading {
    struct Resolution: Equatable, Sendable {
        let episodeID: String
        let contentType: String
        let quality: NativePlaybackQuality
        let playable: Bool
    }

    private let transferError: NativeMediaError
    private(set) var calls: [Resolution] = []
    private(set) var transfers: [URL] = []

    init(transferError: NativeMediaError = .network) { self.transferError = transferError }

    func resolve(_ episodeID: String, _ contentType: String, _ quality: NativePlaybackQuality,
                 playable: Bool, errorCode: String? = nil) throws -> NativeMediaSource {
        calls.append(.init(episodeID: episodeID, contentType: contentType, quality: quality, playable: playable))
        if let errorCode { throw NativeSourceError(code: errorCode) }
        return NativeMediaSource(url: URL(string: "https://fixture.qznovelvod.com/episode-\(calls.count).mp4")!,
                                 contentKey: nil, userAgent: "Fixture", codec: "h264", quality: "720p", preference: quality)
    }

    func downloadOffline(source: NativeMediaSource, destination: URL, maximumBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        transfers.append(source.url)
        try Data([0]).write(to: destination, options: .withoutOverwriting)
        throw transferError
    }
}

struct NativeCatalogTests {
    @Test(arguments: ["OFFLINE_CLEAR_UNAVAILABLE", "HTTP_401", "HTTP_403", "HTTP_429", "BUSINESS_REJECTED", "SECURITY_BLOCKED", "ERR_NETWORK"])
    func offlineUsesTheExactPlayableEpisodeOnlyWhenNoClearSourceExists(_ code: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML(episodes: ["200"], accessible: 1))
        let service = NativeCatalogService(transport: transport, quality: .dataSaver)
        let probe = OfflineSourceProbe()
        do {
            try await service.downloadOffline(seriesID: "100", episodeID: "200", to: directory.appendingPathComponent("episode.mp4"),
                maximumBytes: 2048, resolve: { try await probe.resolve($0, $1, $2, playable: false, errorCode: code) },
                resolvePlayable: { try await probe.resolve($0, $1, $2, playable: true) }, downloader: probe, progress: { _, _ in })
            Issue.record("The fixture always stops before publishing")
        } catch {
            if code == "OFFLINE_CLEAR_UNAVAILABLE" {
                #expect(error as? NativeMediaError == .network)
            } else {
                #expect((error as? NativeSourceError)?.code == code)
            }
        }
        let clear = OfflineSourceProbe.Resolution(episodeID: "200", contentType: "1004", quality: .dataSaver, playable: false)
        let playable = OfflineSourceProbe.Resolution(episodeID: "200", contentType: "1004", quality: .dataSaver, playable: true)
        let usesPlayable = code == "OFFLINE_CLEAR_UNAVAILABLE"
        #expect(await probe.calls == (usesPlayable ? [clear, playable, clear, playable] : [clear]))
        #expect(await probe.transfers.count == (usesPlayable ? 2 : 0))
    }

    @Test(arguments: [NativeMediaError.network, .unsafeURL, .httpStatus(503), .httpStatus(429), .storage])
    func offlineRefreshesTheExactSourceOnceForRetryableTransferFailures(_ error: NativeMediaError) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML(episodes: ["199", "200"], accessible: 2,
                                                                               contentType: "1005"))
        let service = NativeCatalogService(transport: transport, quality: .dataSaver)
        let probe = OfflineSourceProbe(transferError: error)
        await #expect(throws: error) {
            try await service.downloadOffline(seriesID: "100", episodeID: "200", to: directory.appendingPathComponent("episode.mp4"),
                maximumBytes: 2048, resolve: { try await probe.resolve($0, $1, $2, playable: false) },
                resolvePlayable: { try await probe.resolve($0, $1, $2, playable: true) }, downloader: probe, progress: { _, _ in })
        }
        let count = [.network, .unsafeURL, .httpStatus(503)].contains(error) ? 2 : 1
        let clear = OfflineSourceProbe.Resolution(episodeID: "200", contentType: "1005", quality: .dataSaver, playable: false)
        #expect(await probe.calls == Array(repeating: clear, count: count))
        #expect(await probe.transfers.map(\.lastPathComponent) == (1...count).map { "episode-\($0).mp4" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test(arguments: [[502, 200], [502, 502], [401, 200], [403, 200], [429, 200]])
    func offlineRetriesOnlyTransientCatalogueResponses(_ statuses: [Int]) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML(episodes: ["199", "200"], accessible: 2,
                                                                               contentType: "1005"),
                                                 status: statuses[1], firstStatus: statuses[0])
        let service = NativeCatalogService(transport: transport, quality: .dataSaver)
        let probe = OfflineSourceProbe(transferError: .storage)
        let retries = statuses[0] == 502
        let reachedTransfer = retries && statuses[1] == 200
        do {
            try await service.downloadOffline(seriesID: "100", episodeID: "200", to: directory.appendingPathComponent("episode.mp4"),
                maximumBytes: 2048, resolve: { try await probe.resolve($0, $1, $2, playable: false) }, downloader: probe, progress: { _, _ in })
            Issue.record("The fixture stops at the catalogue or first transfer")
        } catch {
            if reachedTransfer {
                #expect(error as? NativeMediaError == .storage)
            } else {
                #expect(error as? CatalogError == (statuses[0] == 401 ? .unauthorized : .httpStatus(statuses[0])))
            }
        }
        let requests = await transport.requests
        #expect(requests.count == (retries ? 2 : 1))
        #expect(requests.allSatisfy { $0.url?.query == "series_id=100" })
        let clear = OfflineSourceProbe.Resolution(episodeID: "200", contentType: "1005", quality: .dataSaver, playable: false)
        #expect(await probe.calls == (reachedTransfer ? [clear] : []))
        #expect(await probe.transfers.count == (reachedTransfer ? 1 : 0))
    }

    @Test
    func completeNativeListDoesNotUseWebsitePreviewCount() throws {
        let html = try nativeCatalogueHTML(episodes: ["200", "201", "202", "203"], accessible: 1)
        let native = try NativeCatalogParser.detail(html: html, seriesID: "100")
        let website = try WebsiteParser.detail(html: html, seriesID: "100")
        #expect(native.detail.episodes.map(\.id) == ["200", "201", "202", "203"])
        #expect(native.detail.episodes.allSatisfy { $0.isAvailable })
        #expect(website.episodes.map(\.isAvailable) == [true, false, false, false])
        #expect(native.detail.series.title == "原生完整目錄")
        #expect(native.detail.episodes.map(\.number) == [1, 2, 3, 4])
        #expect(native.contentType == "1004")
    }

    @Test
    func nativeParserRejectsWrongSeriesDuplicateIDsAndInvalidContentType() throws {
        for html in [
            try nativeCatalogueHTML(seriesID: "999"),
            try nativeCatalogueHTML(episodes: ["200", "200"]),
            try nativeCatalogueHTML(contentType: "1004&extra=1"),
            try nativeCatalogueHTML(contentType: ""),
            try nativeCatalogueHTML(episodes: ["200", "../../secret"])
        ] {
            #expect(throws: (any Error).self) { try NativeCatalogParser.detail(html: html, seriesID: "100") }
        }
    }

    @Test
    func nativePlaybackBindsVidAndContentTypeBeforeResolution() async throws {
        let recorder = NativePreparationRecorder()
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML(contentType: "1005"))
        let service = NativeCatalogService(transport: transport) { episodeID, contentType, fresh in
            await recorder.prepare(episodeID: episodeID, contentType: contentType, fresh: fresh)
        }
        _ = try await service.detail(id: "100")
        let source = try await service.playback(seriesID: "100", episodeID: "203", fresh: true)
        #expect(source.url.isFileURL)
        #expect(source.headers.isEmpty)
        #expect(await recorder.calls == [.init(episodeID: "203", contentType: "1005", fresh: true)])
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.host == "hongguoduanju.com")
        #expect(requests[0].url?.path == "/detail")
        #expect(requests[0].url?.query == "series_id=100")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        do {
            _ = try await service.playback(seriesID: "100", episodeID: "888", fresh: false)
            Issue.record("An unrelated episode reached the playback pipeline")
        } catch { #expect(error as? CatalogError == .invalidID) }
        #expect(await recorder.calls.count == 1)
    }

    @Test
    func playbackWithoutPriorDetailLoadsBindingAndPreservesSourceDenial() async throws {
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML())
        let recorder = NativePreparationRecorder()
        let service = NativeCatalogService(transport: transport) { episode, type, fresh in
            _ = await recorder.prepare(episodeID: episode, contentType: type, fresh: fresh)
            throw CatalogError.httpStatus(403)
        }
        do {
            _ = try await service.playback(seriesID: "100", episodeID: "203", fresh: false)
            Issue.record("An explicit denial was lost")
        } catch { #expect(error as? CatalogError == .httpStatus(403)) }
        #expect(await transport.requests.count == 1)
        #expect(await recorder.calls == [.init(episodeID: "203", contentType: "1004", fresh: false)])
    }

    @Test(arguments: [false, true])
    func rejectedInitialPreparationRequeriesTheSameEpisodeAndQualityOnce(changedSource: Bool) async throws {
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML(contentType: "1005"))
        let recorder = NativeQualityPreparationRecorder()
        let service = NativeCatalogService(transport: transport, quality: .dataSaver, prepareSource: { episode, type, fresh, quality in
            let source = await recorder.prepare(episode, type, fresh, quality)
            if !fresh {
                if changedSource { throw NativeProgressiveError.changedSource }
                throw NativeMediaError.unsafeURL
            }
            return source
        })
        let source = try await service.playback(seriesID: "100", episodeID: "203", fresh: false)
        #expect(source.url.isFileURL)
        #expect(await transport.requests.count == 1)
        #expect(await recorder.calls == [
            .init(episodeID: "203", contentType: "1005", fresh: false, quality: .dataSaver),
            .init(episodeID: "203", contentType: "1005", fresh: true, quality: .dataSaver)
        ])
    }

    @Test
    func unsafePreparationCannotRetryAnExplicitRefreshOrPrefetchOrLoop() async throws {
        let cases: [(fresh: Bool, prefetchBudget: Int?, expected: [Bool])] = [
            (false, nil, [false, true]), (true, nil, [true]),
            (false, NativePlaybackPrefetch.maximumPreparationBytes, [false])
        ]
        for entry in cases {
            let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML())
            let recorder = NativePreparationRecorder()
            let service = NativeCatalogService(transport: transport) { episode, type, refresh in
                _ = await recorder.prepare(episodeID: episode, contentType: type, fresh: refresh)
                throw NativeMediaError.unsafeURL
            }
            await #expect(throws: NativeMediaError.unsafeURL) {
                try await NativePrefetchContext.$maximumBytes.withValue(entry.prefetchBudget) {
                    try await service.playback(seriesID: "100", episodeID: "203", fresh: entry.fresh)
                }
            }
            #expect(await recorder.calls.map(\.fresh) == entry.expected)
        }
    }

    @Test
    func cancellationAtAnUnsafePreparationStopsBeforeRefresh() async throws {
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML())
        let recorder = NativePreparationRecorder()
        let service = NativeCatalogService(transport: transport) { episode, type, fresh in
            _ = await recorder.prepare(episodeID: episode, contentType: type, fresh: fresh)
            withUnsafeCurrentTask { $0?.cancel() }
            throw NativeMediaError.unsafeURL
        }
        let task = Task { try await service.playback(seriesID: "100", episodeID: "203", fresh: false) }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await recorder.calls.map(\.fresh) == [false])
    }

    @Test
    func malformedIDsAndCrossSeriesDataDoNotReachResolution() async throws {
        let recorder = NativePreparationRecorder()
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML(seriesID: "999"))
        let service = NativeCatalogService(transport: transport) { episodeID, contentType, fresh in
            await recorder.prepare(episodeID: episodeID, contentType: contentType, fresh: fresh)
        }
        do { _ = try await service.playback(seriesID: "../100", episodeID: "200", fresh: false); Issue.record("Invalid ID accepted") }
        catch { #expect(error as? CatalogError == .invalidID) }
        #expect(await transport.requests.isEmpty)
        do { _ = try await service.playback(seriesID: "100", episodeID: "200", fresh: false); Issue.record("Wrong series accepted") }
        catch { #expect(error as? CatalogError == .malformedResponse) }
        #expect(await recorder.calls.isEmpty)
    }

    @Test
    func cancellationStopsBeforeNativeSourceResolution() async throws {
        let recorder = NativePreparationRecorder()
        let transport = CancellingCatalogueTransport()
        let service = NativeCatalogService(transport: transport) { episodeID, contentType, fresh in
            await recorder.prepare(episodeID: episodeID, contentType: contentType, fresh: fresh)
        }
        let task = Task { try await service.playback(seriesID: "100", episodeID: "200", fresh: false) }
        await transport.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled playback succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(await recorder.calls.isEmpty)
    }

    @Test
    func nativePipelineCannotReturnRemoteMedia() async throws {
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML())
        let service = NativeCatalogService(transport: transport) { _, _, _ in URL(string: "https://example.com/video.mp4")! }
        do { _ = try await service.playback(seriesID: "100", episodeID: "200", fresh: false); Issue.record("Remote result accepted") }
        catch { #expect(error as? CatalogError == .unsafePlaybackURL) }
    }

    @Test
    func qualityCopiesPreserveTheOriginalAndShareValidatedDetailWhileForwardingTheChosenQuality() async throws {
        let recorder = NativeQualityPreparationRecorder()
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML(contentType: "1005"))
        let original = NativeCatalogService(transport: transport, prepareSource: { episodeID, contentType, fresh, quality in
            await recorder.prepare(episodeID, contentType, fresh, quality)
        })
        _ = try await original.detail(id: "100")
        let saver = original.selectingPlaybackQuality(.dataSaver)
        let restored = saver.selectingPlaybackQuality(.automatic)
        #expect(original.playbackQuality == .automatic)
        #expect(saver.playbackQuality == .dataSaver)
        #expect(restored.playbackQuality == .automatic)

        _ = try await saver.playback(seriesID: "100", episodeID: "203", fresh: true)
        _ = try await original.playback(seriesID: "100", episodeID: "200", fresh: false)
        _ = try await restored.playback(seriesID: "100", episodeID: "201", fresh: false)
        #expect(await transport.requests.count == 1)
        #expect(await recorder.calls == [
            .init(episodeID: "203", contentType: "1005", fresh: true, quality: .dataSaver),
            .init(episodeID: "200", contentType: "1005", fresh: false, quality: .automatic),
            .init(episodeID: "201", contentType: "1005", fresh: false, quality: .automatic)
        ])
    }

    @Test
    func changingQualityDoesNotWeakenCachedEpisodeOrCrossSeriesBindings() async throws {
        let recorder = NativePreparationRecorder()
        let transport = NativeCatalogueTransport(body: try nativeCatalogueHTML())
        let original = NativeCatalogService(transport: transport) { episodeID, contentType, fresh in
            await recorder.prepare(episodeID: episodeID, contentType: contentType, fresh: fresh)
        }
        _ = try await original.detail(id: "100")
        let saver = original.selectingPlaybackQuality(.dataSaver)
        do {
            _ = try await saver.playback(seriesID: "100", episodeID: "888", fresh: true)
            Issue.record("A quality copy prepared an episode outside the validated detail")
        } catch { #expect(error as? CatalogError == .invalidID) }
        #expect(await transport.requests.count == 1)
        do {
            _ = try await saver.playback(seriesID: "999", episodeID: "200", fresh: true)
            Issue.record("A quality copy accepted a different series' response")
        } catch { #expect(error as? CatalogError == .malformedResponse) }
        #expect(await transport.requests.count == 2)
        #expect(await recorder.calls.isEmpty)
        // The failed copy requests do not remove or alter the original binding.
        _ = try await original.playback(seriesID: "100", episodeID: "200", fresh: false)
        #expect(await transport.requests.count == 2)
        #expect(await recorder.calls == [.init(episodeID: "200", contentType: "1004", fresh: false)])
    }

    @Test
    func qualityCopiesPreserveSourceDenialAndInFlightPreparationCancellation() async throws {
        let denialTransport = NativeCatalogueTransport(body: try nativeCatalogueHTML())
        let denied = NativeCatalogService(transport: denialTransport) { _, _, _ in throw CatalogError.httpStatus(403) }
        _ = try await denied.detail(id: "100")
        do {
            _ = try await denied.selectingPlaybackQuality(.dataSaver)
                .playback(seriesID: "100", episodeID: "200", fresh: true)
            Issue.record("Changing quality bypassed an explicit source denial")
        } catch { #expect(error as? CatalogError == .httpStatus(403)) }
        #expect(await denialTransport.requests.count == 1)

        let gate = CancellingNativePreparation()
        let cancellationTransport = NativeCatalogueTransport(body: try nativeCatalogueHTML())
        let original = NativeCatalogService(transport: cancellationTransport) { _, _, _ in try await gate.prepare() }
        _ = try await original.detail(id: "100")
        let copy = original.selectingPlaybackQuality(.dataSaver)
        let task = Task { try await copy.playback(seriesID: "100", episodeID: "200", fresh: true) }
        await gate.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; Issue.record("A cancelled quality preparation succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(await gate.calls == 1)
        #expect(await cancellationTransport.requests.count == 1)
        #expect(original.playbackQuality == .automatic && copy.playbackQuality == .dataSaver)
    }
}

private func nativeCatalogueHTML(seriesID: String = "100", episodes: [String] = ["200", "201", "202", "203"], accessible: Int = 1,
                                 contentType: String? = nil) throws -> String {
    var detail: [String: Any] = ["series_id": seriesID, "series_name": "原生完整目錄", "episode_cnt": episodes.count,
                                 "vid_list": episodes, "accessible_episode_cnt": accessible]
    if let contentType { detail["content_type"] = contentType }
    let payload: [String: Any] = ["loaderData": ["detail_page": ["isSuccess": true, "seriesDetail": detail]]]
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    return "<script>window._ROUTER_DATA = \(String(decoding: data, as: UTF8.self));</script>"
}
