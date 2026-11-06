import Foundation
import Testing
@testable import HongguoCore

struct NativeMediaStoreTests {
    @Test
    func onlyOfficialHTTPSHostsAndSafeHeadersAreAllowed() throws {
        for address in ["https://qznovelvod.com/video", "https://v3.fqnovelvod.com:443/a?signature=opaque", "https://V6.DOUYINVOD.COM/video"] {
            #expect(NativeMediaPolicy.allows(try #require(URL(string: address))))
        }
        for address in ["http://v3.qznovelvod.com/video", "https://qznovelvod.com.evil.test/video", "https://evilqznovelvod.com/video",
                        "https://user:password@v3.qznovelvod.com/video", "https://v3.qznovelvod.com:8443/video",
                        "https://v3.qznovelvod.com/video#fragment", "https://127.0.0.1/video", "file:///tmp/video.mp4"] {
            #expect(!NativeMediaPolicy.allows(try #require(URL(string: address))))
        }
        #expect(throws: NativeMediaError.unsafeURL) { try NativeMediaPolicy.validate(storeSource(userAgent: "agent\r\nAuthorization: secret")) }
        #expect(throws: NativeMediaError.unsupportedCodec) { try NativeMediaPolicy.validate(storeSource(codec: "bytevc2")) }
        #expect(throws: NativeMediaError.invalidKey) { try NativeMediaPolicy.validate(storeSource(key: Data(repeating: 0, count: 15))) }
    }

    @Test
    func invalidSourceOrEpisodeStopsBeforeDownload() async throws {
        let directory = storeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = StoreFixtureDownload(data: storeClearMP4())
        let store = NativeMediaStore(cacheDirectory: directory, downloader: downloader)
        await #expect(throws: NativeMediaError.unsafeURL) {
            try await store.prepare(source: storeSource(url: URL(string: "https://example.org/a")!), episodeID: "1")
        }
        await #expect(throws: CatalogError.invalidID) { try await store.prepare(source: storeSource(), episodeID: "../1") }
        #expect(await downloader.count() == 0)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test
    func clearFileIsPrivateCachedAndFreshReplacesIt() async throws {
        let directory = storeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = storeClearMP4()
        let downloader = StoreFixtureDownload(data: fixture)
        let store = NativeMediaStore(cacheDirectory: directory, downloader: downloader)
        let first = try await store.prepare(source: storeSource(), episodeID: "1")
        #expect(first.isFileURL)
        #expect(try Data(contentsOf: first) == fixture)
        #expect(try (FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try await store.prepare(source: storeSource(), episodeID: "1") == first)
        #expect(await downloader.count() == 1)
        let renewedURL = URL(string: "https://v6.qznovelvod.com/video?signature=new")!
        #expect(try await store.prepare(source: storeSource(url: renewedURL), episodeID: "1") == first)
        let fresh = try await store.prepare(source: storeSource(), episodeID: "1", fresh: true)
        #expect(first != fresh)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(try Data(contentsOf: fresh) == fixture)
        #expect(await downloader.count() == 2)
        #expect(try storeFiles(in: directory).map(\.pathExtension) == ["mp4"])
    }

    @Test
    func oversizeOrMalformedFileCleansPartialOutput() async throws {
        for fixture in [storeClearMP4(), Data("not an mp4".utf8)] {
            let directory = storeTestDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let tooLarge = fixture.count > 20
            let store = NativeMediaStore(cacheDirectory: directory, downloader: StoreFixtureDownload(data: fixture), byteLimit: tooLarge ? fixture.count - 1 : 1024)
            await #expect(throws: tooLarge ? NativeMediaError.tooLarge : NativeMediaError.malformedMP4) {
                try await store.prepare(source: storeSource(), episodeID: "1")
            }
            #expect(try storeFiles(in: directory).isEmpty)
        }
    }

    @Test
    func cancellationCleansDownloadAndDoesNotProducePlayableURL() async throws {
        let directory = storeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = StoreFixtureDownload(data: storeClearMP4(), suspend: true)
        let store = NativeMediaStore(cacheDirectory: directory, downloader: downloader)
        let task = Task { try await store.prepare(source: storeSource(), episodeID: "1") }
        await downloader.waitUntilStarted()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try storeFiles(in: directory).isEmpty)
    }

    @Test
    func explicitDenialPreservesStatusAndDoesNotRetry() async throws {
        let directory = storeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = StoreFixtureDownload(data: Data(), failure: .httpStatus(403))
        let store = NativeMediaStore(cacheDirectory: directory, downloader: downloader)
        await #expect(throws: CatalogError.httpStatus(403)) { try await store.prepare(source: storeSource(), episodeID: "1") }
        #expect(await downloader.count() == 1)
        #expect(try storeFiles(in: directory).isEmpty)
    }

    @Test
    func completedCacheKeepsAtMostSixFilesAndRedownloadsEvictedEntry() async throws {
        let directory = storeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloader = StoreFixtureDownload(data: storeClearMP4())
        let store = NativeMediaStore(cacheDirectory: directory, downloader: downloader)
        var urls: [URL] = []
        for id in 1...8 { urls.append(try await store.prepare(source: storeSource(), episodeID: String(id))) }
        #expect(try storeFiles(in: directory).count == 6)
        #expect(!FileManager.default.fileExists(atPath: urls[0].path))
        #expect(!FileManager.default.fileExists(atPath: urls[1].path))
        #expect(FileManager.default.fileExists(atPath: urls[7].path))
        _ = try await store.prepare(source: storeSource(), episodeID: "1")
        #expect(await downloader.count() == 9)
        #expect(try storeFiles(in: directory).count == 6)
    }

    @Test
    func previousRunCacheIsAlsoBoundedToThreeHundredMiB() async throws {
        let directory = storeTestDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Sparse files exercise the byte budget without allocating 400 MB in memory or on disk.
        for index in 0..<5 {
            let url = directory.appendingPathComponent("previous-\(index).mp4")
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 80 * 1024 * 1024)
            try handle.close()
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(Double(index - 10))], ofItemAtPath: url.path)
        }
        let store = NativeMediaStore(cacheDirectory: directory, downloader: StoreFixtureDownload(data: storeClearMP4()))
        let current = try await store.prepare(source: storeSource(), episodeID: "1")
        let files = try storeFiles(in: directory)
        let bytes = try files.reduce(0) { total, url in
            total + ((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0)
        }
        #expect(bytes <= 300 * 1024 * 1024)
        #expect(files.contains { $0.lastPathComponent == current.lastPathComponent })
        #expect(FileManager.default.fileExists(atPath: current.path))
    }
}

private actor StoreFixtureDownload: NativeMediaDownloading {
    let data: Data
    let failure: CatalogError?
    let suspend: Bool
    private var calls = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(data: Data, failure: CatalogError? = nil, suspend: Bool = false) {
        self.data = data; self.failure = failure; self.suspend = suspend
    }

    func download(source: NativeMediaSource, destination: URL, maximumBytes: Int64) async throws {
        calls += 1
        try data.write(to: destination)
        for waiter in waiters { waiter.resume() }
        waiters = []
        if suspend { try await Task.sleep(for: .seconds(30)) }
        if let failure { throw failure }
    }
    func count() -> Int { calls }
    func waitUntilStarted() async {
        if calls > 0 { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}

private func storeSource(url: URL = URL(string: "https://v3.qznovelvod.com/video?signature=opaque")!,
                         key: Data? = nil, userAgent: String = "HongguoFixture", codec: String = "h264") -> NativeMediaSource {
    NativeMediaSource(url: url, contentKey: key, userAgent: userAgent, codec: codec, quality: "1080p")
}

private func storeTestDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-store-test-" + UUID().uuidString) }
private func storeFiles(in directory: URL) throws -> [URL] { try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }

/// Clear MP4 structural fixture; codec decoding is checked separately against real media.
private func storeClearMP4() -> Data {
    func u32(_ value: UInt32) -> Data { var big = value.bigEndian; return withUnsafeBytes(of: &big) { Data($0) } }
    func box(_ type: String, _ body: Data) -> Data { u32(UInt32(body.count + 8)) + Data(type.utf8) + body }
    let stsd = box("stsd", u32(0) + u32(1) + box("avc1", Data(repeating: 0, count: 78)))
    let movie = box("moov", box("trak", box("mdia", box("minf", box("stbl", stsd)))))
    return box("ftyp", Data("isom".utf8) + u32(0)) + movie + box("mdat", Data([0, 1, 2, 3]))
}
