/// Included only in the isolated simulator target. The library action and player are production views.
@MainActor
enum HistoryOfflineQA {
    static let series = Series(id: "8801101", title: "離線續看驗收")
    static let episodes = [Episode(id: "201", number: 1, title: "第一集"), Episode(id: "202", number: 2, title: "第二集")]
    static let resume: Double = 12
    static let offline = CommandLine.arguments.contains("qa-history-offline")
    static weak var playerModel: PlayerModel?

    static func log(_ message: String) {
        FileHandle.standardOutput.write(Data(("HISTORY " + message + "\n").utf8))
    }

    static func seed(app: AppModel) async throws {
        app.useNativePlayback()
        app.selectLibraryOwner(.guest)
        let portText = try String(contentsOf: URL.documentsDirectory.appendingPathComponent("history-port"), encoding: .utf8)
        guard let port = UInt16(portText) else { throw URLError(.badURL) }
        let folder = URL.applicationSupportDirectory.appendingPathComponent("OfflineEpisodes.v1", isDirectory: true)
        let store = try OfflineDownloads(directory: folder) { item, file, _, _ in
            let url = URL(string: "http://127.0.0.1:\(port)/\(item.key.episodeID).mp4")!
            let (temp, response) = try await URLSession.shared.download(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.moveItem(at: temp, to: file)
        }
        let detail = SeriesDetail(series: series, episodes: episodes)
        let items = episodes.map { episode in
            OfflineDownloadItem(key: .init(scope: OfflinePlaybackAccess.scope(for: .guest), seriesID: series.id, episodeID: episode.id),
                                seriesTitle: series.title, episodeNumber: episode.number, episodeTitle: episode.title)
        }
        for item in items { try await store.delete(item.key) }
        try await store.enqueue(items, catalog: detail)
        let deadline = ContinuousClock.now + .seconds(30)
        while await store.snapshot().filter({ items.map(\.key).contains($0.key) && $0.state == .completed }).count != 2 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(100))
        }
        for item in items {
            guard try await store.localURL(for: item.key)?.isFileURL == true else { throw OfflineDownloadError.invalidFile }
        }
        app.playbackProgressHandler(for: series, episodes: episodes)(episodes[0], resume, 32)
        await app.flushLibrary()
        guard app.record(for: series)?.seconds == resume else { throw URLError(.cannotWriteToFile) }
        log("SEEDED downloaded=2 resume=12")
    }

    static func observe() async throws {
        let deadline = ContinuousClock.now + .seconds(75)
        var lastItem: AVPlayerItem?
        var output: AVPlayerItemVideoOutput?
        var counts = [Int:Int]()
        var initialPlaySent = false
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(90))
            guard let model = playerModel else { continue }
            if let error = model.errorMessage { log("FAIL " + error); return }
            guard let item = model.player.currentItem, let episode = model.currentEpisode else { continue }
            if item !== lastItem {
                guard let asset = item.asset as? AVURLAsset, asset.url.isFileURL else { log("FAIL nonlocal media"); return }
                let video = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
                item.add(video); lastItem = item; output = video
            }
            if model.isInitialSeekComplete, model.player.rate == 0, !model.canPausePlayback, !initialPlaySent, counts.isEmpty {
                initialPlaySent = true; model.togglePlayback()
            }
            let time = model.player.currentTime()
            guard model.isInitialSeekComplete, model.player.rate > 0, let output, output.hasNewPixelBuffer(forItemTime: time),
                  output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) != nil else { continue }
            if counts[episode.number] == nil {
                log(String(format: "FRAME episode=%d position=%.2f file=1", episode.number, time.seconds))
                if episode.number == 1 && !(resume - 1 ... resume + 2).contains(time.seconds) { log("FAIL wrong resume"); return }
                if episode.number == 2 && (counts[1, default: 0] < 5 || time.seconds > 2) { log("FAIL wrong next episode"); return }
            }
            counts[episode.number, default: 0] += 1
            if counts[2, default: 0] >= 8 {
                log("RESULT historyResume=12 downloadedEpisodes=2 frames=\(counts[1,default:0]),\(counts[2,default:0])")
                return
            }
        }
        log("FAIL timed out waiting for history playback")
    }
}
