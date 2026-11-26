// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

public struct OfflineDownloadKey: Hashable, Codable, Sendable {
    public let scope: String
    public let seriesID: String
    public let episodeID: String

    public init(scope: String, seriesID: String, episodeID: String) {
        self.scope = scope
        self.seriesID = seriesID
        self.episodeID = episodeID
    }
}

public enum OfflineDownloadState: String, Codable, Sendable {
    case queued, downloading, waiting, paused, completed, failed, cancelled
}

public struct OfflineDownloadItem: Identifiable, Equatable, Codable, Sendable {
    public let key: OfflineDownloadKey
    public let seriesTitle: String
    public let episodeNumber: Int
    public let episodeTitle: String
    public fileprivate(set) var state: OfflineDownloadState = .queued
    public fileprivate(set) var receivedBytes: Int64 = 0
    public fileprivate(set) var totalBytes: Int64?
    public fileprivate(set) var failure: String?
    public fileprivate(set) var retryAfter: Date?
    public fileprivate(set) var sourceRetryAttempt: Int?
    private var offlineUnsupported: Bool?
    public fileprivate(set) var position: Double = 0
    public fileprivate(set) var duration: Double = 0
    public fileprivate(set) var lastWatchedAt: Date?
    public var isFinishedOffline: Bool { duration > 0 && position >= duration - 0.25 }
    public var canResumeOffline: Bool { position > 0 && duration > 0 && !isFinishedOffline }
    public var id: OfflineDownloadKey { key }
    public var isOfflineUnsupported: Bool {
        // Older builds saved clear-only failures as unsupported. The episode can now be retried.
        state == .failed && offlineUnsupported == true && failure != "來源未提供可離線儲存的未加密 MP4。"
    }
    public var canRetryFailedDownload: Bool {
        [.failed, .paused].contains(state) && key.scope != OfflineDownloads.importedScope && !isOfflineUnsupported
    }

    public init(key: OfflineDownloadKey, seriesTitle: String, episodeNumber: Int, episodeTitle: String = "",
                position: Double = 0, duration: Double = 0) {
        self.key = key
        self.seriesTitle = seriesTitle
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.position = position
        self.duration = duration
    }

    /// Select from one series. Older libraries have progress but no watch dates.
    public static func nextToWatch(in episodes: [Self]) -> Self? {
        let saved = episodes.filter { $0.state == .completed }.sorted {
            ($0.episodeNumber, $0.key.episodeID) < ($1.episodeNumber, $1.key.episodeID)
        }
        let latest = saved.filter { $0.lastWatchedAt != nil && $0.position > 0 }.max {
            ($0.lastWatchedAt ?? .distantPast) < ($1.lastWatchedAt ?? .distantPast)
        }
        if let latest {
            if latest.canResumeOffline { return latest }
            if let next = saved.first(where: { $0.episodeNumber > latest.episodeNumber && !$0.isFinishedOffline }) {
                return next
            }
        }
        if let unfinished = saved.first(where: \.canResumeOffline) { return unfinished }
        if latest == nil, let finished = saved.last(where: \.isFinishedOffline),
           let next = saved.first(where: { $0.episodeNumber > finished.episodeNumber && !$0.isFinishedOffline }) {
            return next
        }
        return saved.first(where: { !$0.isFinishedOffline }) ?? saved.first
    }

    fileprivate mutating func resetTransfer(to state: OfflineDownloadState, failure: String? = nil,
                                            offlineUnsupported: Bool? = nil) {
        self.state = state
        receivedBytes = 0
        totalBytes = nil
        self.failure = failure
        self.offlineUnsupported = offlineUnsupported
        retryAfter = nil
        sourceRetryAttempt = nil
    }
}

public enum OfflineDownloadError: Error, LocalizedError, Equatable, Sendable {
    case invalidItem, tooManyItems, storageFull, fileTooLarge, invalidFile, storageUnavailable, invalidIndex, busy

    public var errorDescription: String? {
        switch self {
        case .invalidItem: "這一集的下載資料不完整。"
        case .tooManyItems: "已達下載集數上限，請先刪除一些下載。"
        case .storageFull: "離線下載空間不足，請清出空間後重試。"
        case .fileTooLarge: "這一集超過離線下載的檔案大小上限。"
        case .invalidFile: "離線影片不完整，請重新下載。"
        case .storageUnavailable: "目前無法存取離線下載，請稍後再試。"
        case .invalidIndex: "無法讀取離線下載清單，已保留現有檔案。"
        case .busy: "片庫正在下載或匯入影片，請稍後再試。"
        }
    }
}

/// One queue owns one application-private directory. The provider writes the
/// complete playable file at its assigned staging URL and respects the byte cap.
public actor OfflineDownloads {
    public static let importedScope = "local.import.v1"
    public typealias Progress = @Sendable (Int64, Int64?) async -> Void
    public typealias Provider = @Sendable (OfflineDownloadItem, URL, Int64, @escaping Progress) async throws -> Void

    public struct Limits: Sendable {
        public let maximumItems: Int
        public let maximumBytesPerItem: Int64
        public let maximumTotalBytes: Int64
        public let reserveBytes: Int64

        public init(maximumItems: Int = 250, maximumBytesPerItem: Int64 = 512 * 1024 * 1024,
                    maximumTotalBytes: Int64 = 10 * 1024 * 1024 * 1024, reserveBytes: Int64 = 256 * 1024 * 1024) {
            self.maximumItems = min(max(maximumItems, 1), 250)
            self.maximumTotalBytes = max(maximumTotalBytes, 1)
            self.maximumBytesPerItem = min(max(maximumBytesPerItem, 1), self.maximumTotalBytes)
            self.reserveBytes = max(reserveBytes, 0)
        }
    }

    private struct Record: Codable, Equatable, Sendable {
        var item: OfflineDownloadItem
        let fileID: UUID
        var checksum: Data?
        var resumedAfterTermination: Bool?
    }

    private struct Index: Codable {
        let version: Int
        let records: [Record]
    }

    private struct Job {
        let key: OfflineDownloadKey
        let token: UUID
        let directory: URL
        let maximumBytes: Int64
        let task: Task<Void, Never>
        var lastCheckpoint: TimeInterval = -.infinity
    }

    private struct Cooldown {
        let token: UUID
        let deadline: Date
        let task: Task<Void, Never>
    }

    private let disk: Disk
    private let limits: Limits
    private let provider: Provider
    private var records: [Record]
    private var job: Job?
    private var cooldown: Cooldown?
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var isImporting = false
    private var nextProgressPublication = ContinuousClock.now
    private var progressPublication: Task<Void, Never>?
    private var observers: [UUID: AsyncStream<[OfflineDownloadItem]>.Continuation] = [:]

    public init(directory: URL, limits: Limits = .init(), provider: @escaping Provider) throws {
        try self.init(directory: directory, limits: limits, now: Date.init,
                      sleep: { try await Task.sleep(for: $0) }, provider: provider)
    }

    init(directory: URL, limits: Limits = .init(), now: @escaping @Sendable () -> Date,
         sleep: @escaping @Sendable (Duration) async throws -> Void, provider: @escaping Provider) throws {
        let disk = try Disk(directory: directory)
        self.disk = disk
        self.limits = limits
        self.provider = provider
        self.records = try disk.load()
        self.now = now
        self.sleep = sleep
    }

    deinit {
        job?.task.cancel()
        cooldown?.task.cancel()
        progressPublication?.cancel()
        for observer in observers.values { observer.finish() }
    }

    public func snapshot() -> [OfflineDownloadItem] { records.map(\.item) }

    public func updates() -> AsyncStream<[OfflineDownloadItem]> {
        let token = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: [OfflineDownloadItem].self,
                                                           bufferingPolicy: .bufferingNewest(1))
        observers[token] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(token) }
        }
        return stream
    }

    /// Resume the waiting queue when the app opens this library.
    public func start() { startNext() }

    public func enqueue(_ item: OfflineDownloadItem) throws { try enqueue([item]) }

    public func enqueue(_ items: [OfflineDownloadItem], catalog: SeriesDetail? = nil) throws {
        if let catalog, let first = items.first {
            let available = Set(catalog.episodes.filter(\.isAvailable).map(\.id))
            guard items.allSatisfy({ item in
                item.key.scope == first.key.scope && item.key.seriesID == catalog.series.id
                    && available.contains(item.key.episodeID)
            }) else { throw OfflineDownloadError.invalidItem }
        }
        var keys = Set(records.map(\.item.key))
        var updated = records
        for var item in items {
            guard Disk.valid(item) else { throw OfflineDownloadError.invalidItem }
            guard keys.insert(item.key).inserted else { continue }
            guard updated.count < limits.maximumItems else { throw OfflineDownloadError.tooManyItems }
            item.resetTransfer(to: .queued)
            if let pending = updated.first(where: {
                $0.item.key.scope == item.key.scope && [.waiting, .paused].contains($0.item.state)
            })?.item {
                item.state = pending.state
                item.failure = pending.failure
                item.retryAfter = pending.retryAfter
                item.sourceRetryAttempt = pending.sourceRetryAttempt
            }
            updated.append(Record(item: item, fileID: UUID()))
        }
        if updated.count != records.count { try commit(updated) }
        if let catalog, let scope = items.first?.key.scope { disk.saveCatalog(catalog, scope: scope) }
        startNext()
    }

    /// Copies a user-selected file into the same private, integrity-checked library.
    public func importVideo(from source: URL, title: String) async throws {
        guard source.isFileURL, source.pathExtension.lowercased() == "mp4" else {
            throw OfflineDownloadError.invalidFile
        }
        guard !isImporting, job == nil else { throw OfflineDownloadError.busy }
        guard records.count < limits.maximumItems else { throw OfflineDownloadError.tooManyItems }
        let fileID = UUID()
        let id = fileID.uuidString
        let key = OfflineDownloadKey(scope: Self.importedScope, seriesID: id, episodeID: id)
        var item = OfflineDownloadItem(key: key, seriesTitle: title, episodeNumber: 1)
        guard Disk.valid(item) else { throw OfflineDownloadError.invalidItem }
        let maximumBytes = try transferLimit()
        let folder = disk.staging.appendingPathComponent(id, isDirectory: true)
        let destination = folder.appendingPathComponent("import.mp4")
        try disk.createDirectory(folder)
        isImporting = true
        defer {
            disk.remove(folder)
            isImporting = false
            startNext()
        }
        let copy = Task.detached(priority: .utility) {
            try Disk.prepareImport(source: source, destination: destination, maximumBytes: maximumBytes)
        }
        let (size, checksum) = try await withTaskCancellationHandler {
            try await copy.value
        } onCancel: { copy.cancel() }
        try Task.checkCancellation()
        guard records.count < limits.maximumItems else { throw OfflineDownloadError.tooManyItems }
        guard try disk.availableBytes() >= limits.reserveBytes else { throw OfflineDownloadError.storageFull }
        let final = disk.movie(fileID)
        try disk.move(destination, to: final)
        item.state = .completed
        item.receivedBytes = size
        item.totalBytes = size
        do { try commit(records + [Record(item: item, fileID: fileID, checksum: checksum)]) }
        catch { disk.remove(final); throw error }
    }

    public func cancel(_ key: OfflineDownloadKey) throws {
        guard let index = index(for: key), [.queued, .downloading, .waiting, .paused].contains(records[index].item.state) else { return }
        var updated = records
        updated[index].item.resetTransfer(to: .cancelled)
        try commit(updated)
        if job?.key == key { job?.task.cancel() }
        startNext()
    }

    public func retry(_ key: OfflineDownloadKey) throws {
        guard key.scope != Self.importedScope, let index = index(for: key), [.failed, .cancelled, .paused].contains(records[index].item.state),
              !records[index].item.isOfflineUnsupported else { return }
        var updated = records
        var record = updated.remove(at: index)
        // A corrupt movie may still be present after earlier cleanup was refused.
        try disk.deleteFile(disk.movie(record.fileID))
        record.resumedAfterTermination = nil
        record.item.resetTransfer(to: .queued)
        inheritActiveCooldown(&record.item)
        updated.append(record)
        try commit(updated)
        startNext()
    }

    /// Requeues only still-failed, supported downloads from the requested snapshot.
    /// Persist the whole batch before starting work; preserve the active queue and completed files.
    @discardableResult
    public func retryFailed(_ keys: [OfflineDownloadKey]) throws -> Int {
        let requested = Set(keys)
        var retried = records.filter { requested.contains($0.item.key) && $0.item.canRetryFailedDownload }
        guard !retried.isEmpty else { return 0 }
        for index in retried.indices {
            try disk.deleteFile(disk.movie(retried[index].fileID))
            retried[index].item.resetTransfer(to: .queued)
            inheritActiveCooldown(&retried[index].item)
            retried[index].checksum = nil
            retried[index].resumedAfterTermination = nil
        }
        let retriedKeys = Set(retried.map(\.item.key))
        try commit(records.filter { !retriedKeys.contains($0.item.key) } + retried)
        startNext()
        return retried.count
    }

    public func delete(_ key: OfflineDownloadKey) throws {
        try delete([key])
    }

    /// Removes a drama's saved episodes and its outstanding downloads.
    public func deleteSeries(scope: String, seriesID: String) throws {
        guard scope != Self.importedScope else { return }
        let keys = records.lazy.map(\.item.key).filter { $0.scope == scope && $0.seriesID == seriesID }
        try delete(Array(keys))
    }

    /// Removes the selected downloads. A storage error can leave only the refused items in the library.
    public func delete(_ keys: [OfflineDownloadKey]) throws {
        let requested = Set(keys)
        let removed = records.filter { requested.contains($0.item.key) }
        guard !removed.isEmpty else { return }
        var updated = records.filter { !requested.contains($0.item.key) }
        try disk.save(updated)

        var refused = Set<OfflineDownloadKey>()
        var deletionError: (any Error)?
        for record in removed {
            do { try disk.deleteFile(disk.movie(record.fileID)) }
            catch {
                refused.insert(record.item.key)
                deletionError = deletionError ?? error
            }
        }
        if !refused.isEmpty {
            // Restore rows whose files could not be removed. If the second save
            // fails, reopen will clean up files absent from the last durable index.
            let restored = records.filter { !requested.contains($0.item.key) || refused.contains($0.item.key) }
            if (try? disk.save(restored)) != nil { updated = restored }
        }

        let retainedCatalogs = Set(updated.map { disk.catalogURL(scope: $0.item.key.scope, seriesID: $0.item.key.seriesID) })
        for record in removed {
            let file = disk.catalogURL(scope: record.item.key.scope, seriesID: record.item.key.seriesID)
            if !retainedCatalogs.contains(file) { disk.remove(file) }
        }
        records = updated
        publish()
        if let key = job?.key, requested.contains(key), index(for: key) == nil { job?.task.cancel() }
        startNext()
        if let deletionError { throw deletionError }
    }

    public func recordProgress(for key: OfflineDownloadKey, position: Double, duration: Double) throws {
        guard let index = index(for: key), records[index].item.state == .completed,
              position.isFinite, position >= 0, duration.isFinite, duration > 0 else { return }
        let position = min(position, duration)
        guard records[index].item.position != position || records[index].item.duration != duration else { return }
        var updated = records
        updated[index].item.position = position
        updated[index].item.duration = duration
        updated[index].item.lastWatchedAt = now()
        try commit(updated)
    }

    /// Only expose a catalogue snapshot if this owner still has a completed
    /// episode. Older indexes have no snapshot and can still open their saved rows.
    func savedDetail(scope: String, seriesID: String, continuing record: WatchRecord? = nil, allowPartial: Bool = false) -> SeriesDetail? {
        guard scope != Self.importedScope else { return nil }
        let saved = records.map(\.item).filter {
            $0.key.scope == scope && $0.key.seriesID == seriesID && $0.state == .completed
        }.sorted { ($0.episodeNumber, $0.key.episodeID) < ($1.episodeNumber, $1.key.episodeID) }
        guard let first = saved.first else { return nil }
        let catalog = disk.readCatalog(scope: scope, seriesID: seriesID)
        let detail = catalog ?? SeriesDetail(series: record?.series ?? .init(id: seriesID, title: first.seriesTitle),
            episodes: saved.map { .init(id: $0.key.episodeID, number: $0.episodeNumber, title: $0.episodeTitle) })
        if let record {
            guard detail.episodes.contains(where: { $0.id == record.episode.id }),
                  let target = PlaybackContinuation.preferred(seriesID: seriesID, episodes: detail.episodes, record: record),
                  saved.contains(where: { $0.key.episodeID == target.episode.id }) else { return nil }
            // A pre-snapshot index can only describe downloaded episodes. Online
            // lookup should retain the full season when available.
            if catalog == nil {
                guard allowPartial,
                      let i = detail.episodes.firstIndex(where: { $0.id == record.episode.id }) else { return nil }
                // A legacy snapshot cannot fill gaps with guessed episode IDs.
                // Limit automatic navigation to consecutive downloaded episodes.
                var first = i, last = i
                while first > 0 && detail.episodes[first - 1].number == detail.episodes[first].number - 1 { first -= 1 }
                while last + 1 < detail.episodes.count && detail.episodes[last + 1].number == detail.episodes[last].number + 1 { last += 1 }
                return .init(series: detail.series, episodes: Array(detail.episodes[first...last]))
            }
        }
        return detail
    }

    public func localURL(for key: OfflineDownloadKey) throws -> URL? {
        guard let index = index(for: key), records[index].item.state == .completed else { return nil }
        let record = records[index]
        let url = disk.movie(record.fileID)
        do {
            guard try disk.fileSize(url) == record.item.receivedBytes,
                  try disk.checksum(url, size: record.item.receivedBytes) == record.checksum else {
                throw OfflineDownloadError.invalidFile
            }
            return url
        } catch OfflineDownloadError.invalidFile {
            var updated = records
            updated[index].item.resetTransfer(to: .failed, failure: OfflineDownloadError.invalidFile.localizedDescription)
            updated[index].checksum = nil
            try commit(updated)
            disk.remove(url)
            return nil
        }
    }

    private func startNext() {
        armCooldown()
        guard job == nil, !isImporting else { return }
        while let index = records.firstIndex(where: { $0.item.state == .queued }) {
            let token = UUID()
            let folder = disk.staging.appendingPathComponent(token.uuidString, isDirectory: true)
            let destination = folder.appendingPathComponent("episode.mp4")
            do {
                let maximumBytes = try transferLimit()
                try disk.createDirectory(folder)
                var updated = records
                let attempt = updated[index].item.sourceRetryAttempt
                updated[index].item.resetTransfer(to: .downloading)
                updated[index].item.sourceRetryAttempt = attempt
                try commit(updated)
                let item = records[index].item
                let provider = provider
                let task = Task { [weak self] in
                    let result: Result<Data, any Error>
                    do {
                        try Task.checkCancellation()
                        try await PlaybackTransferContext.$isBackground.withValue(true) {
                            try await PlaybackNetworkPriority.shared.waitForForeground()
                            try await provider(item, destination, maximumBytes) { [weak self] bytes, total in
                                await self?.receiveProgress(token: token, bytes: bytes, total: total)
                            }
                        }
                        try Task.checkCancellation()
                        let size = try Disk.validatedSize(destination, maximumBytes: maximumBytes)
                        result = .success(try Disk.hashFile(destination, size: size))
                    } catch { result = .failure(error) }
                    if let self { await self.finish(token: token, destination: destination, result: result) }
                    else { try? FileManager.default.removeItem(at: folder) }
                }
                job = Job(key: item.key, token: token, directory: folder, maximumBytes: maximumBytes, task: task)
                return
            } catch {
                disk.remove(folder)
                if !fail(index: index, error: error) { return }
            }
        }
    }

    private func transferLimit() throws -> Int64 {
        var quota = limits.maximumTotalBytes
        for record in records where record.item.state == .completed {
            quota = max(quota - record.item.receivedBytes, 0)
        }
        let available = try disk.availableBytes()
        guard available > limits.reserveBytes else { throw OfflineDownloadError.storageFull }
        let maximum = min(quota, limits.maximumBytesPerItem, available - limits.reserveBytes)
        guard maximum > 0 else { throw OfflineDownloadError.storageFull }
        return maximum
    }

    private func receiveProgress(token: UUID, bytes: Int64, total: Int64?) {
        guard let current = job, current.token == token, let index = index(for: current.key),
              records[index].item.state == .downloading, bytes >= records[index].item.receivedBytes else { return }
        let total = total ?? records[index].item.totalBytes
        if bytes > current.maximumBytes || total.map({ $0 > current.maximumBytes }) == true {
            _ = fail(index: index, error: OfflineDownloadError.fileTooLarge)
            current.task.cancel()
            return
        }
        guard total.map({ $0 > 0 && $0 >= bytes }) != false,
              records[index].item.receivedBytes != bytes || records[index].item.totalBytes != total else { return }
        records[index].item.receivedBytes = bytes
        records[index].item.totalBytes = total
        let now = ProcessInfo.processInfo.systemUptime
        if now - current.lastCheckpoint >= 1 {
            do {
                try disk.save(records)
                job?.lastCheckpoint = now
            } catch {
                _ = fail(index: index, error: error)
                current.task.cancel()
                return
            }
        }
        publishProgress()
    }

    private func finish(token: UUID, destination: URL, result: Result<Data, any Error>) {
        guard let current = job, current.token == token else { return }
        job = nil
        defer { disk.remove(current.directory); startNext() }
        guard let index = index(for: current.key), records[index].item.state == .downloading else { return }
        do {
            let checksum = try result.get()
            let size = try Disk.validatedSize(destination, maximumBytes: current.maximumBytes)
            guard try disk.availableBytes() >= limits.reserveBytes else { throw OfflineDownloadError.storageFull }
            let final = disk.movie(records[index].fileID)
            try disk.move(destination, to: final)
            var updated = records
            updated[index].checksum = checksum
            updated[index].item.state = .completed
            updated[index].item.receivedBytes = size
            updated[index].item.totalBytes = size
            updated[index].item.sourceRetryAttempt = nil
            // Only a successful provider transfer clears the queue's retry budget.
            // Reading a completed local file or importing a movie never gets here.
            for i in updated.indices where updated[i].item.key.scope == current.key.scope
                && updated[i].item.state == .queued {
                updated[i].item.sourceRetryAttempt = nil
            }
            do { try commit(updated) }
            catch { disk.remove(final); throw error }
        } catch {
            if OfflineSourceRecovery.shouldWait(error), current.key.scope != Self.importedScope {
                deferSource(index: index, error: error)
            } else { _ = fail(index: index, error: error) }
        }
    }

    private func inheritActiveCooldown(_ item: inout OfflineDownloadItem) {
        guard let pending = records.first(where: {
            $0.item.key.scope == item.key.scope && $0.item.state == .waiting
        })?.item else { return }
        item.state = .waiting
        item.failure = pending.failure
        item.retryAfter = pending.retryAfter
        item.sourceRetryAttempt = pending.sourceRetryAttempt
    }

    private func deferSource(index: Int, error: any Error) {
        let scope = records[index].item.key.scope
        let attempt = (records[index].item.sourceRetryAttempt ?? 0) + 1
        let automatic = attempt <= OfflineSourceRecovery.delays.count
        let deadline = automatic ? now().addingTimeInterval(OfflineSourceRecovery.delays[attempt - 1]) : nil
        var updated = records
        for i in updated.indices where updated[i].item.key.scope == scope
            && (i == index || [.queued, .waiting].contains(updated[i].item.state)) {
            updated[i].item.resetTransfer(to: automatic ? .waiting : .paused,
                failure: (error as? NativeSourceError)?.errorDescription ?? "來源連線暫時異常。")
            updated[i].item.retryAfter = deadline
            updated[i].item.sourceRetryAttempt = min(attempt, OfflineSourceRecovery.delays.count)
        }
        do { try commit(updated) }
        catch {
            // Keep the whole affected queue stopped even when the index cannot be saved.
            for i in updated.indices where updated[i].item.key.scope == scope
                && [.waiting, .paused].contains(updated[i].item.state) {
                updated[i].item.resetTransfer(to: .paused, failure: OfflineDownloadError.storageUnavailable.localizedDescription)
            }
            records = updated
            publish()
        }
    }

    private func armCooldown() {
        let deadline = records.filter { $0.item.state == .waiting }.compactMap(\.item.retryAfter).min()
        guard deadline != cooldown?.deadline else { return }
        cooldown?.task.cancel()
        cooldown = nil
        guard let deadline else { return }
        let token = UUID(), sleep = sleep
        // A wall-clock change must not create an unbounded wait after reopening.
        let delay = min(max(deadline.timeIntervalSince(now()), 0), OfflineSourceRecovery.delays.last!)
        let task = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
                try Task.checkCancellation()
                await self?.resumeWaiting(token: token, deadline: deadline)
            } catch { /* Cancellation cannot requeue removed or cancelled episodes. */ }
        }
        cooldown = Cooldown(token: token, deadline: deadline, task: task)
    }

    private func resumeWaiting(token: UUID, deadline: Date) {
        guard cooldown?.token == token else { return }
        cooldown = nil
        var updated = records
        let ready = updated.indices.filter {
            updated[$0].item.state == .waiting && updated[$0].item.retryAfter.map { $0 <= deadline } == true
        }
        for i in ready {
            let attempt = updated[i].item.sourceRetryAttempt
            updated[i].item.resetTransfer(to: .queued)
            updated[i].item.sourceRetryAttempt = attempt
        }
        do { try commit(updated) }
        catch {
            for i in ready {
                updated[i].item.resetTransfer(to: .paused, failure: OfflineDownloadError.storageUnavailable.localizedDescription)
            }
            records = updated
            publish()
        }
        startNext()
    }

    /// A failed write leaves the previous index intact. Keep the row in memory
    /// with its error so a temporarily unavailable disk can be retried.
    @discardableResult
    private func fail(index: Int, error: any Error) -> Bool {
        let source = error as? NativeSourceError
        let media = error as? NativeMediaError
        let unsupported = source?.code == "OFFLINE_CLEAR_UNAVAILABLE" || media == .unsupportedEncryption
        let description = (error as? OfflineDownloadError)?.errorDescription ?? media?.errorDescription
            ?? (error as? CatalogError)?.errorDescription ?? source?.errorDescription
            ?? (error as? NativeProgressiveError)?.errorDescription
            ?? "下載中斷，請稍後再試。"
        var updated = records
        updated[index].item.resetTransfer(to: .failed, failure: description, offlineUnsupported: unsupported ? true : nil)
        updated[index].checksum = nil
        do { try commit(updated); return true }
        catch {
            updated[index].item.resetTransfer(to: .failed, failure: OfflineDownloadError.storageUnavailable.localizedDescription)
            records = updated
            publish()
            return false
        }
    }

    private func index(for key: OfflineDownloadKey) -> Int? { records.firstIndex { $0.item.key == key } }

    private func commit(_ updated: [Record]) throws {
        try disk.save(updated)
        records = updated
        publish()
    }

    private func publishProgress() {
        guard !observers.isEmpty, progressPublication == nil else { return }
        let deadline = nextProgressPublication
        guard ContinuousClock.now < deadline else { publish(); return }
        progressPublication = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            await self?.flushPendingProgress()
        }
    }

    private func flushPendingProgress() {
        guard !Task.isCancelled else { return }
        publish()
    }

    private func publish() {
        // State changes publish immediately, including the newest byte count.
        progressPublication?.cancel()
        progressPublication = nil
        guard !observers.isEmpty else { return }
        nextProgressPublication = ContinuousClock.now.advanced(by: .milliseconds(250))
        let items = snapshot()
        for observer in observers.values { observer.yield(items) }
    }

    private func removeObserver(_ token: UUID) { observers.removeValue(forKey: token) }

    private struct Disk: Sendable {
        private static let maximumIndexBytes: Int64 = 2 * 1024 * 1024
        let root: URL
        let completed: URL
        let staging: URL
        let manifest: URL
        let catalogs: URL

        init(directory: URL) throws {
            guard directory.isFileURL else { throw OfflineDownloadError.storageUnavailable }
            root = directory.standardizedFileURL
            completed = root.appendingPathComponent("completed", isDirectory: true)
            staging = root.appendingPathComponent("staging", isDirectory: true)
            manifest = root.appendingPathComponent("index.json")
            catalogs = root.appendingPathComponent("catalogs", isDirectory: true)
            try createDirectory(root)
            try createDirectory(completed)
            try createDirectory(staging)
            try createDirectory(catalogs)
            #if os(iOS)
            var excluded = root
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? excluded.setResourceValues(values)
            #endif
        }

        func load() throws -> [Record] {
            let completedFiles = try contents(completed)
            let index: Index
            do {
                guard let size = try fileSize(manifest) else {
                    guard !completedFiles.contains(where: Self.isMovie) else { throw OfflineDownloadError.invalidIndex }
                    cleanStaging()
                    return []
                }
                guard size <= Self.maximumIndexBytes else { throw OfflineDownloadError.invalidIndex }
                index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: manifest))
            } catch is DecodingError { throw OfflineDownloadError.invalidIndex }
            catch OfflineDownloadError.invalidFile { throw OfflineDownloadError.invalidIndex }
            catch let error as OfflineDownloadError { throw error }
            catch { throw OfflineDownloadError.storageUnavailable }

            guard index.version == 1, index.records.count <= 250,
                  Set(index.records.map(\.item.key)).count == index.records.count,
                  Set(index.records.map(\.fileID)).count == index.records.count else { throw OfflineDownloadError.invalidIndex }
            var recovered = index.records
            for i in recovered.indices {
                let record = recovered[i]
                guard Self.valid(record.item) else { throw OfflineDownloadError.invalidIndex }
                if record.item.state == .downloading {
                    if record.resumedAfterTermination == true {
                        recovered[i].item.resetTransfer(to: .failed, failure: "下載再次中斷，請重新下載。")
                    } else {
                        recovered[i].resumedAfterTermination = true
                        recovered[i].item.resetTransfer(to: .queued)
                    }
                } else if record.item.state == .completed {
                    let valid: Bool
                    do {
                        valid = try fileSize(movie(record.fileID)) == record.item.receivedBytes
                            && record.checksum?.count == 32
                            && record.item.totalBytes == record.item.receivedBytes
                    } catch OfflineDownloadError.invalidFile { valid = false }
                    if !valid {
                        recovered[i].checksum = nil
                        recovered[i].item.resetTransfer(to: .failed, failure: OfflineDownloadError.invalidFile.localizedDescription)
                    }
                }
            }
            if recovered != index.records { try save(recovered) }
            let retained = Set(recovered.filter { $0.item.state == .completed }.map { movie($0.fileID).lastPathComponent })
            for file in completedFiles where Self.isMovie(file) && !retained.contains(file.lastPathComponent) { remove(file) }
            let catalogsInUse = Set(recovered.map { catalogURL(scope: $0.item.key.scope, seriesID: $0.item.key.seriesID).lastPathComponent })
            for url in (try? contents(catalogs)) ?? [] where !catalogsInUse.contains(url.lastPathComponent) { remove(url) }
            cleanStaging()
            return recovered
        }

        func catalogURL(scope: String, seriesID: String) -> URL {
            let digest = SHA256.hash(data: Data((scope + "\0" + seriesID).utf8)).map { String(format: "%02x", $0) }.joined()
            return catalogs.appendingPathComponent(digest + ".json")
        }

        func saveCatalog(_ detail: SeriesDetail, scope: String) {
            let snapshot = SeriesDetail(series: detail.series, episodes: detail.episodes)
            guard (try? EpisodeSelection(seriesID: detail.series.id, episodes: detail.episodes)) != nil,
                  let bytes = try? JSONEncoder().encode(snapshot), bytes.count <= Self.maximumIndexBytes else { return }
            try? bytes.write(to: catalogURL(scope: scope, seriesID: detail.series.id),
                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }

        func readCatalog(scope: String, seriesID: String) -> SeriesDetail? {
            let url = catalogURL(scope: scope, seriesID: seriesID)
            guard let size = try? fileSize(url), size <= Self.maximumIndexBytes,
                  let bytes = try? Data(contentsOf: url), let detail = try? JSONDecoder().decode(SeriesDetail.self, from: bytes),
                  detail.series.id == seriesID, (try? EpisodeSelection(seriesID: seriesID, episodes: detail.episodes)) != nil else { return nil }
            return detail
        }

        func save(_ records: [Record]) throws {
            do {
                let data = try JSONEncoder().encode(Index(version: 1, records: records))
                guard data.count <= Self.maximumIndexBytes else { throw OfflineDownloadError.invalidIndex }
                try data.write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch let error as OfflineDownloadError { throw error }
            catch { throw OfflineDownloadError.storageUnavailable }
        }

        static func valid(_ item: OfflineDownloadItem) -> Bool {
            func validText(_ value: String, maximum: Int, allowEmpty: Bool = false) -> Bool {
                (allowEmpty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    && value.utf8.count <= maximum
                    && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
            return validText(item.key.scope, maximum: 256)
                && validText(item.key.seriesID, maximum: 128)
                && validText(item.key.episodeID, maximum: 128)
                && validText(item.seriesTitle, maximum: 1024)
                && validText(item.episodeTitle, maximum: 1024, allowEmpty: true)
                && item.episodeNumber > 0 && item.receivedBytes >= 0
                && item.totalBytes.map { $0 > 0 && $0 >= item.receivedBytes } != false
                && item.failure.map { validText($0, maximum: 512) } != false
                && item.sourceRetryAttempt.map { (1...OfflineSourceRecovery.delays.count).contains($0) } != false
                && item.retryAfter.map { $0.timeIntervalSince1970.isFinite } != false
                && (item.state != .waiting || (item.retryAfter != nil && item.sourceRetryAttempt != nil))
                && (item.state == .waiting || item.retryAfter == nil)
                && item.position.isFinite && item.duration.isFinite
                && item.position >= 0 && item.duration >= item.position
        }

        func createDirectory(_ url: URL) throws {
            do {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw OfflineDownloadError.storageUnavailable }
            } catch { throw OfflineDownloadError.storageUnavailable }
        }

        func movie(_ id: UUID) -> URL { completed.appendingPathComponent(id.uuidString + ".mp4") }

        func move(_ staging: URL, to final: URL) throws {
            do {
                var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
                #if os(iOS)
                attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
                #endif
                try FileManager.default.setAttributes(attributes, ofItemAtPath: staging.path)
                try FileManager.default.moveItem(at: staging, to: final)
            } catch { throw OfflineDownloadError.storageUnavailable }
        }

        func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

        func deleteFile(_ url: URL) throws {
            do { try FileManager.default.removeItem(at: url) }
            catch where Self.isMissing(error) { return }
            catch { throw OfflineDownloadError.storageUnavailable }
        }

        func availableBytes() throws -> Int64 {
            do {
                let info = try FileManager.default.attributesOfFileSystem(forPath: root.path)
                guard let size = info[.systemFreeSize] as? NSNumber else { throw OfflineDownloadError.storageUnavailable }
                return max(size.int64Value, 0)
            } catch { throw OfflineDownloadError.storageUnavailable }
        }

        func fileSize(_ url: URL) throws -> Int64? { try Self.regularFileSize(url) }
        func checksum(_ url: URL, size: Int64) throws -> Data { try Self.hashFile(url, size: size) }

        private static func regularFileSize(_ url: URL) throws -> Int64? {
            let attributes: [FileAttributeKey: Any]
            do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
            catch where isMissing(error) { return nil }
            catch { throw OfflineDownloadError.storageUnavailable }
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
                  let size = (attributes[.size] as? NSNumber)?.int64Value, size > 0 else { throw OfflineDownloadError.invalidFile }
            return size
        }

        private static func isMissing(_ error: any Error) -> Bool {
            let error = error as NSError
            return (error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code))
                || (error.domain == NSPOSIXErrorDomain && error.code == Int(POSIXErrorCode.ENOENT.rawValue))
        }

        static func validatedSize(_ url: URL, maximumBytes: Int64) throws -> Int64 {
            guard let size = try regularFileSize(url) else { throw OfflineDownloadError.invalidFile }
            guard size <= maximumBytes else { throw OfflineDownloadError.fileTooLarge }
            return size
        }

        static func prepareImport(source: URL, destination: URL, maximumBytes: Int64) throws -> (Int64, Data) {
            var coordinationError: NSError?
            var outcome: Result<(Int64, Data), any Error>?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { url in
                outcome = Result {
                    let size = try validatedSize(url, maximumBytes: maximumBytes)
                    guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                         attributes: [.posixPermissions: 0o600]) else {
                        throw OfflineDownloadError.storageUnavailable
                    }
                    let input = try FileHandle(forReadingFrom: url)
                    defer { try? input.close() }
                    let output = try FileHandle(forWritingTo: destination)
                    defer { try? output.close() }
                    var hash = SHA256()
                    var copied: Int64 = 0
                    while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                        try Task.checkCancellation()
                        guard Int64(bytes.count) <= size - copied else { throw OfflineDownloadError.invalidFile }
                        try output.write(contentsOf: bytes)
                        hash.update(data: bytes)
                        copied += Int64(bytes.count)
                    }
                    guard copied == size else { throw OfflineDownloadError.invalidFile }
                    let media = try Data(contentsOf: destination, options: .mappedIfSafe)
                    do { try NativeMP4.validateOfflineClear(data: media, maximumBytes: maximumBytes) }
                    catch is NativeMediaError { throw OfflineDownloadError.invalidFile }
                    return (copied, Data(hash.finalize()))
                }
            }
            guard coordinationError == nil, let outcome else { throw OfflineDownloadError.storageUnavailable }
            return try outcome.get()
        }

        static func hashFile(_ url: URL, size: Int64) throws -> Data {
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var hash = SHA256()
                var remaining = size
                while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    guard remaining >= Int64(data.count) else { throw OfflineDownloadError.invalidFile }
                    remaining -= Int64(data.count)
                    hash.update(data: data)
                }
                guard remaining == 0 else { throw OfflineDownloadError.invalidFile }
                return Data(hash.finalize())
            } catch is CancellationError { throw CancellationError() }
            catch let error as OfflineDownloadError { throw error }
            catch { throw OfflineDownloadError.storageUnavailable }
        }

        private func contents(_ directory: URL) throws -> [URL] {
            do { return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) }
            catch { throw OfflineDownloadError.storageUnavailable }
        }

        private func cleanStaging() {
            for file in (try? contents(staging)) ?? [] where UUID(uuidString: file.lastPathComponent) != nil { remove(file) }
        }

        private static func isMovie(_ url: URL) -> Bool {
            url.pathExtension == "mp4" && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        }
    }
}
