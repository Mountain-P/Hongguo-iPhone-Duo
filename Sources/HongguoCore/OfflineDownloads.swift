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
    case queued, downloading, completed, failed, cancelled
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
    private var offlineUnsupported: Bool?
    public fileprivate(set) var position: Double = 0
    public fileprivate(set) var duration: Double = 0
    public var id: OfflineDownloadKey { key }
    public var isOfflineUnsupported: Bool {
        // Older builds saved clear-only failures as unsupported. The episode can now be retried.
        state == .failed && offlineUnsupported == true && failure != "來源未提供可離線儲存的未加密 MP4。"
    }
    public var canRetryFailedDownload: Bool {
        state == .failed && key.scope != OfflineDownloads.importedScope && !isOfflineUnsupported
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

    fileprivate mutating func resetTransfer(to state: OfflineDownloadState, failure: String? = nil,
                                            offlineUnsupported: Bool? = nil) {
        self.state = state
        receivedBytes = 0
        totalBytes = nil
        self.failure = failure
        self.offlineUnsupported = offlineUnsupported
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

    private let disk: Disk
    private let limits: Limits
    private let provider: Provider
    private var records: [Record]
    private var job: Job?
    private var isImporting = false
    private var observers: [UUID: AsyncStream<[OfflineDownloadItem]>.Continuation] = [:]

    public init(directory: URL, limits: Limits = .init(), provider: @escaping Provider) throws {
        let disk = try Disk(directory: directory)
        self.disk = disk
        self.limits = limits
        self.provider = provider
        self.records = try disk.load()
    }

    deinit {
        job?.task.cancel()
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

    public func enqueue(_ items: [OfflineDownloadItem]) throws {
        var keys = Set(records.map(\.item.key))
        var updated = records
        for var item in items {
            guard Disk.valid(item) else { throw OfflineDownloadError.invalidItem }
            guard keys.insert(item.key).inserted else { continue }
            guard updated.count < limits.maximumItems else { throw OfflineDownloadError.tooManyItems }
            item.resetTransfer(to: .queued)
            updated.append(Record(item: item, fileID: UUID()))
        }
        guard updated.count != records.count else { return }
        try commit(updated)
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
        guard let index = index(for: key), [.queued, .downloading].contains(records[index].item.state) else { return }
        var updated = records
        updated[index].item.resetTransfer(to: .cancelled)
        try commit(updated)
        if job?.key == key { job?.task.cancel() }
        startNext()
    }

    public func retry(_ key: OfflineDownloadKey) throws {
        guard key.scope != Self.importedScope, let index = index(for: key), [.failed, .cancelled].contains(records[index].item.state),
              !records[index].item.isOfflineUnsupported else { return }
        var updated = records
        var record = updated.remove(at: index)
        // A corrupt movie may still be present after earlier cleanup was refused.
        try disk.deleteFile(disk.movie(record.fileID))
        record.item.resetTransfer(to: .queued)
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
            retried[index].checksum = nil
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
        try commit(updated)
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
        guard job == nil, !isImporting else { return }
        while let index = records.firstIndex(where: { $0.item.state == .queued }) {
            let token = UUID()
            let folder = disk.staging.appendingPathComponent(token.uuidString, isDirectory: true)
            let destination = folder.appendingPathComponent("episode.mp4")
            do {
                let maximumBytes = try transferLimit()
                try disk.createDirectory(folder)
                var updated = records
                updated[index].item.resetTransfer(to: .downloading)
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
        publish()
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
            do { try commit(updated) }
            catch { disk.remove(final); throw error }
        } catch { _ = fail(index: index, error: error) }
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

    private func publish() {
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

        init(directory: URL) throws {
            guard directory.isFileURL else { throw OfflineDownloadError.storageUnavailable }
            root = directory.standardizedFileURL
            completed = root.appendingPathComponent("completed", isDirectory: true)
            staging = root.appendingPathComponent("staging", isDirectory: true)
            manifest = root.appendingPathComponent("index.json")
            try createDirectory(root)
            try createDirectory(completed)
            try createDirectory(staging)
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
                    recovered[i].item.resetTransfer(to: .failed, failure: "下載已中斷，請重新下載。")
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
            cleanStaging()
            return recovered
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
