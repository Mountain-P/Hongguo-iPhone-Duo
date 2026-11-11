// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

private struct OfflineCatalogueFixture: HTTPTransport {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let html = #"<script>window._ROUTER_DATA={"loaderData":{"detail_page":{"isSuccess":true,"seriesDetail":{"series_id":"100","series_name":"Offline fixture","vid_list":["200"],"episode_cnt":1,"content_type":"1005"}}}};</script>"#
        return (Data(html.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor OfflineEvents {
    struct Resolution: Equatable, Sendable {
        let episode: String
        let contentType: String
        let quality: NativePlaybackQuality
    }
    private(set) var resolutions: [Resolution] = []
    private(set) var progress: [(Int64, Int64?)] = []
    func resolved(_ episode: String, _ type: String, _ quality: NativePlaybackQuality) {
        resolutions.append(.init(episode: episode, contentType: type, quality: quality))
    }
    func advanced(_ received: Int64, _ expected: Int64?) { progress.append((received, expected)) }
}

private final class OfflineHTTPSFixtures: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var headers: [String: String]
        var body: Data
    }
    static let shared = OfflineHTTPSFixtures()
    private let lock = NSLock()
    private var responses: [URL: Response] = [:]
    private var requests: [URL: [URLRequest]] = [:]

    func register(_ response: Response) -> URL {
        let url = URL(string: "https://offline-fixture.fqnovelvod.com/\(UUID()).mp4")!
        lock.withLock { responses[url] = response }
        return url
    }
    func start(_ request: URLRequest, url: URL) -> Response? {
        lock.withLock { requests[url, default: []].append(request); return responses[url] }
    }
    func requests(to url: URL) -> [URLRequest] { lock.withLock { requests[url] ?? [] } }
    func remove(_ url: URL) {
        lock.withLock { responses.removeValue(forKey: url); requests.removeValue(forKey: url) }
    }
}

private final class OfflineHTTPSProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = OfflineHTTPSFixtures.shared.start(request, url: url),
              let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: fixture.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let middle = fixture.body.count / 2
        client?.urlProtocol(self, didLoad: Data(fixture.body.prefix(middle)))
        client?.urlProtocol(self, didLoad: Data(fixture.body.dropFirst(middle)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor OfflineHeldTransfer: NativeOfflineMediaDownloading {
    private var started = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func downloadOffline(source: NativeMediaSource, destination: URL, maximumBytes: Int64,
                         progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws {
        try Data([0, 0, 0, 16]).write(to: destination)
        progress(4, nil)
        started = true
        waiters.forEach { $0.resume() }; waiters.removeAll()
        try await Task.sleep(for: .seconds(30))
    }
    func waitForPartialFile() async {
        if !started { await withCheckedContinuation { waiters.append($0) } }
    }
}

struct NativeOfflineDownloadTests {
    @Test func importedVideoSurvivesSourceRemovalAndReopening() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("episode.mp4")
        let library = directory.appendingPathComponent("library", isDirectory: true)
        let bytes = clearMP4()
        try bytes.write(to: source)
        let queue = try OfflineDownloads(directory: library) { _, _, _, _ in
            Issue.record("Local import must not use the network provider")
            throw CatalogError.network
        }
        try await queue.importVideo(from: source, title: "匯入測試")
        let item = try #require(await queue.snapshot().first)
        #expect(item.state == .completed)
        #expect(item.key.scope == OfflineDownloads.importedScope)
        #expect(try Data(contentsOf: source) == bytes)
        try FileManager.default.removeItem(at: source)
        try await queue.recordProgress(for: item.key, position: 3, duration: 10)

        let reopened = try OfflineDownloads(directory: library) { _, _, _, _ in throw CatalogError.network }
        let saved = try #require(try await reopened.localURL(for: item.key))
        #expect(try Data(contentsOf: saved) == bytes)
        #expect(await reopened.snapshot().first?.position == 3)
        try await reopened.delete(item.key)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
    }

    @Test func protectedOrOversizeImportsNeverEnterTheLibrary() async throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("episode.mp4")
        let library = directory.appendingPathComponent("library", isDirectory: true)
        let protected = clearMP4(sampleEntry: "encv")
        let queue = try OfflineDownloads(directory: library,
            limits: .init(maximumBytesPerItem: Int64(protected.count))) { _, _, _, _ in throw CatalogError.network }
        try protected.write(to: source)
        await #expect(throws: OfflineDownloadError.invalidFile) {
            try await queue.importVideo(from: source, title: "加密測試")
        }
        try (protected + Data([0])).write(to: source)
        await #expect(throws: OfflineDownloadError.fileTooLarge) {
            try await queue.importVideo(from: source, title: "超過上限")
        }
        #expect(await queue.snapshot().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.appendingPathComponent("staging").path).isEmpty)
    }

    @Test func exactEpisodeTransfersWithoutCredentialsAndStagesUnmodifiedMP4() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("episode.stage")
        let media = clearMP4(), events = OfflineEvents()
        let url = OfflineHTTPSFixtures.shared.register(.init(headers: ["Content-Type": "video/mp4", "Content-Length": String(media.count)], body: media))
        defer { OfflineHTTPSFixtures.shared.remove(url) }
        let service = NativeCatalogService(transport: OfflineCatalogueFixture(), quality: .dataSaver)
        try await service.downloadOffline(seriesID: "100", episodeID: "200", to: destination, maximumBytes: 2048,
            resolve: { episode, type, quality in
                await events.resolved(episode, type, quality)
                return self.source(url)
            }, downloader: httpDownloader(), progress: { await events.advanced($0, $1) })
        #expect(await events.resolutions == [.init(episode: "200", contentType: "1005", quality: .dataSaver)])
        #expect(try Data(contentsOf: destination) == media)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["episode.stage"])
        #expect(try (FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let progress = await events.progress
        #expect(progress.last?.0 == Int64(media.count))
        #expect(progress.last?.1 == Int64(media.count))
        #expect(progress.map(\.0) == progress.map(\.0).sorted())
        let requests = OfflineHTTPSFixtures.shared.requests(to: url)
        #expect(requests.count == 1)
        #expect(requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func wrongEpisodeAndExistingDestinationStopBeforeResolution() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("episode.stage")
        let service = NativeCatalogService(transport: OfflineCatalogueFixture()), events = OfflineEvents()
        let resolver: @Sendable (String, String, NativePlaybackQuality) async throws -> NativeMediaSource = { episode, type, quality in
            await events.resolved(episode, type, quality)
            throw NativeMediaError.invalidResponse
        }
        await #expect(throws: CatalogError.invalidID) {
            try await service.downloadOffline(seriesID: "100", episodeID: "201", to: destination, maximumBytes: 2048,
                                               resolve: resolver, downloader: httpDownloader(), progress: { _, _ in })
        }
        let existing = Data([7]); try existing.write(to: destination)
        await #expect(throws: NativeMediaError.storage) {
            try await service.downloadOffline(seriesID: "100", episodeID: "200", to: destination, maximumBytes: 2048,
                                               resolve: resolver, downloader: httpDownloader(), progress: { _, _ in })
        }
        #expect(await events.resolutions.isEmpty)
        #expect(try Data(contentsOf: destination) == existing)
    }

    @Test func protectedSourceFailsBeforeOpeningTheMediaConnection() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = OfflineHTTPSFixtures.shared.register(.init(headers: [:], body: Data()))
        defer { OfflineHTTPSFixtures.shared.remove(url) }
        let file = try NativeOfflineFile(destination: directory.appendingPathComponent("episode.stage"), maximumBytes: 2048)
        do {
            try await file.write(source: source(url, key: Data(repeating: 0x11, count: 16)), downloader: httpDownloader(), progress: { _, _ in })
            Issue.record("A keyed source reached offline staging")
        } catch let error as NativeSourceError { #expect(error.code == "OFFLINE_CLEAR_UNAVAILABLE") }
        #expect(OfflineHTTPSFixtures.shared.requests(to: url).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func deniedAndOversizeBodiesNeverPublishOrRetry() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let payload = Data(repeating: 0xff, count: 1024)
        for status in [401, 403, 429, 200] {
            let url = OfflineHTTPSFixtures.shared.register(.init(status: status, headers: ["Content-Type": "video/mp4", "Content-Length": "1024"], body: payload))
            defer { OfflineHTTPSFixtures.shared.remove(url) }
            let file = try NativeOfflineFile(destination: directory.appendingPathComponent("episode.stage"), maximumBytes: 64)
            do {
                try await file.write(source: source(url), downloader: httpDownloader(), progress: { _, _ in })
                Issue.record("Denied or oversized media was published")
            } catch {
                switch status {
                case 401: #expect(error as? CatalogError == .unauthorized)
                case 403: #expect(error as? CatalogError == .httpStatus(403))
                case 429: #expect(error as? NativeMediaError == .httpStatus(429))
                default: #expect(error as? NativeMediaError == .tooLarge)
                }
            }
            #expect(OfflineHTTPSFixtures.shared.requests(to: url).count == 1)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    @Test func cancellingAStartedTransferDiscardsItsPartialFile() async throws {
        let directory = try makeDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let file = try NativeOfflineFile(destination: directory.appendingPathComponent("episode.stage"), maximumBytes: 2048)
        let downloader = OfflineHeldTransfer()
        let task = Task {
            try await file.write(source: source(URL(string: "https://offline-fixture.fqnovelvod.com/cancel.mp4")!),
                                 downloader: downloader, progress: { _, _ in })
        }
        await downloader.waitForPartialFile()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func clearValidationRejectsTruncatedSamplesExternalReferencesAndProtectedTracks() throws {
        try NativeMP4.validateOfflineClear(data: clearMP4(), codec: "h264")
        #expect(throws: NativeMediaError.malformedMP4) {
            try NativeMP4.validateOfflineClear(data: clearMP4(truncatedToEOF: true), codec: "h264")
        }
        #expect(throws: NativeMediaError.malformedMP4) {
            try NativeMP4.validateOfflineClear(data: clearMP4(selfContained: false), codec: "h264")
        }
        #expect(throws: NativeMediaError.unsupportedEncryption) {
            try NativeMP4.validateOfflineClear(data: clearMP4(sampleEntry: "encv"), codec: "h264")
        }
    }

    @Test func offlineSelectionUsesOnlyExplicitClearDirectRowsFromThePrimaryResponse() async throws {
        let raw = try await NativeJSRuntime().evaluateForTesting(#"""
        (async () => {
          const consume = require('app-source').audit.consumeAppPlayResponse;
          const plain = {main_url:'https://unit.fqnovelvod.com/clear.mp4', codec_type:'h264', width:720, height:1280, encrypt:false};
          const encrypted = {...plain, main_url:'https://unit.fqnovelvod.com/protected.mp4', width:1080, height:1920, encrypt:true, spade_a:'not-a-key'};
          const parse = model => consume({data:{'200':{video_model:model}}}, '200', {quality:'auto', offlineDirect:true}, {deadline:Date.now()+500, route:'video_tab'});
          const result = await parse({video_list:{encrypted,plain}});
          const outcome = async model => {try {await parse(model); return 'accepted'} catch(error){return error.code}};
          const denied = await Promise.all([
            outcome({video_list:{encrypted}}),
            outcome({video_list:{unmarked:{...plain,encrypt:undefined}}}),
            outcome({video_list:{conflicting:{...plain,encrypt_info:{encrypt:true}}}}),
            outcome({video_list:{plain},key_seed:'not-a-direct-url'}),
            outcome({fallback_api:'https://example.invalid/no-fetch'})
          ]);
          let registrations = 0, primary = 0, fallback = 0;
          const resolve = require('playback-recovery').createPlaybackRecovery({
            register:async()=>{registrations++;return{}},
            getModel:async()=>{primary++;throw Object.assign(new Error('empty'),{code:'EMPTY_RESPONSE',status:200})},
            postModel:async()=>{fallback++},consume:async()=>({})});
          try {await resolve('200',{options:{offlineDirect:true}})}catch(_){}
          return {clear:result.url===plain.main_url && result.contentKey===null,denied,registrations,primary,fallback};
        })()
        """#)
        let value = try dictionary(Data(raw.utf8))
        #expect(value["clear"] as? Bool == true)
        #expect(value["denied"] as? [String] == Array(repeating: "OFFLINE_CLEAR_UNAVAILABLE", count: 5))
        #expect(value["registrations"] as? Int == 1)
        #expect(value["primary"] as? Int == 1)
        #expect(value["fallback"] as? Int == 0)
    }

    private func source(_ url: URL, key: Data? = nil) -> NativeMediaSource {
        .init(url: url, contentKey: key, userAgent: "OfflineFixture", codec: "h264", quality: "720p")
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineTransferFixture-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private func httpDownloader() -> NativeMediaHTTPDownload {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineHTTPSProtocol.self]
        return NativeMediaHTTPDownload(configuration: configuration)
    }

    private func clearMP4(sampleEntry: String = "avc1", selfContained: Bool = true, truncatedToEOF: Bool = false) -> Data {
        func words(_ values: UInt32...) -> Data {
            var data = Data()
            for value in values { var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) } }
            return data
        }
        func box(_ name: String, _ body: Data) -> Data { words(UInt32(body.count + 8)) + Data(name.utf8) + body }
        let ftyp = box("ftyp", Data("isom".utf8) + words(0))
        var video = Data(repeating: 0, count: 78); video[7] = 1
        let descriptions = box("stsd", words(0, 1) + box(sampleEntry, video))
        let references = box("dinf", box("dref", words(0, 1) + box("url ", words(selfContained ? 1 : 0))))
        let timing = box("stts", words(0, 1, 1, 1000))
        let mapping = box("stsc", words(0, 1, 1, 1, 1))
        let sizes = box("stsz", words(0, 4, 1))
        func movie(_ offset: UInt32) -> Data {
            let index = box("stco", words(0, 1, offset))
            let table = box("stbl", descriptions + timing + mapping + sizes + index)
            return box("moov", box("trak", box("mdia", box("minf", references + table))))
        }
        let mediaStart = UInt32(ftyp.count + movie(0).count + 8)
        let media = truncatedToEOF ? words(0) + Data("mdat".utf8) + Data([1, 2]) : box("mdat", Data([1, 2, 3, 4]))
        return ftyp + movie(mediaStart) + media
    }
}
