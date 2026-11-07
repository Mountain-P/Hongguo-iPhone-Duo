// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Darwin
import Foundation

/// Process-local raw media chunks. Disk contents are never trusted across launches.
actor NativeChunkDiskCache {
    static let shared = NativeChunkDiskCache()
    static let maximumBytes = 512 * 1024 * 1024
    static let maximumChunkBytes = 512 * 1024
    static let minimumFreeBytes: Int64 = 128 * 1024 * 1024

    struct Lookup: Sendable {
        let data: Data?
        let generation: UUID
    }

    private struct Key: Hashable {
        let streamID: UUID
        let index: Int
        var name: String { "\(streamID.uuidString.lowercased())-\(index)" }
    }

    private struct Entry {
        let bytes: Int
        let checksum: Data
        var access: UInt64
        var usable = true
    }

    // A failed cleanup remains charged to the budget until it can be removed.
    private struct Orphan {
        let streamID: UUID
        let reservedBytes: Int
    }

    private let directory: URL
    private let directoryFD: Int32
    private let byteLimit: Int
    private let freeSpaceProvider: @Sendable (URL) -> Int64?
    private var entries: [Key: Entry] = [:]
    private var orphans: [String: Orphan] = [:]
    private var epoch = UUID()
    private var access: UInt64 = 0
    private(set) var byteCount = 0
    var allowsPrefetch: Bool { byteLimit > 0 && canUseDisk }

    init(directory: URL = NativeChunkDiskCache.defaultDirectory,
         byteLimit: Int = NativeChunkDiskCache.maximumBytes,
         freeSpaceProvider: @escaping @Sendable (URL) -> Int64? = NativeChunkDiskCache.availableCapacity) {
        self.directory = directory
        self.byteLimit = max(0, min(byteLimit, Self.maximumBytes))
        self.freeSpaceProvider = freeSpaceProvider
        directoryFD = Self.prepareDirectory(directory)
    }

    deinit {
        if directoryFD >= 0 { Darwin.close(directoryFD) }
    }

    func lookup(streamID: UUID, index: Int, expectedBytes: Int) -> Lookup {
        let generation = epoch
        guard !Task.isCancelled, index >= 0, expectedBytes > 0,
              expectedBytes <= Self.maximumChunkBytes, directoryFD >= 0 else {
            return Lookup(data: nil, generation: generation)
        }
        let key = Key(streamID: streamID, index: index)
        guard var entry = entries[key] else { return Lookup(data: nil, generation: generation) }
        guard entry.usable, entry.bytes == expectedBytes,
              let data = Self.read(name: key.name, directoryFD: directoryFD, count: expectedBytes),
              Data(SHA256.hash(data: data)) == entry.checksum else {
            _ = erase(key)
            return Lookup(data: nil, generation: generation)
        }
        guard !Task.isCancelled else { return Lookup(data: nil, generation: generation) }
        access &+= 1; entry.access = access; entries[key] = entry
        return Lookup(data: data, generation: generation)
    }

    /// The caller must pass the generation returned before fetching these raw bytes.
    @discardableResult
    func store(_ data: Data, streamID: UUID, index: Int, generation: UUID) -> Bool {
        guard !Task.isCancelled, generation == epoch, index >= 0, !data.isEmpty,
              data.count <= Self.maximumChunkBytes, data.count <= byteLimit, canUseDisk else { return false }
        let key = Key(streamID: streamID, index: index)
        if entries[key] != nil, !erase(key) { return false }
        for name in Array(orphans.keys) { _ = eraseOrphan(name) }
        while byteCount > byteLimit - data.count {
            guard let victim = entries.min(by: { $0.value.access < $1.value.access })?.key,
                  erase(victim) else { return false }
        }
        // Never replace a file that has no entry in this process's metadata.
        var existing = stat()
        guard fstatat(directoryFD, key.name, &existing, AT_SYMLINK_NOFOLLOW) != 0,
              errno == ENOENT, !Task.isCancelled, generation == epoch else { return false }

        let temporary = Key(streamID: UUID(), index: index).name
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        let written = Self.write(data, to: fd)
        let closed = Darwin.close(fd) == 0
        guard written, closed, !Task.isCancelled, generation == epoch else {
            discard(temporary, streamID: streamID, reservedBytes: data.count)
            return false
        }
        guard renameat(directoryFD, temporary, directoryFD, key.name) == 0 else {
            discard(temporary, streamID: streamID, reservedBytes: data.count)
            return false
        }
        guard !Task.isCancelled, generation == epoch else {
            discard(key.name, streamID: streamID, reservedBytes: data.count)
            return false
        }
        access &+= 1
        entries[key] = Entry(bytes: data.count, checksum: Data(SHA256.hash(data: data)), access: access)
        byteCount += data.count
        return true
    }

    func remove(streamID: UUID) {
        // Changing the global epoch also invalidates old writers for other streams,
        // while their already committed chunks remain available.
        epoch = UUID()
        for key in Array(entries.keys) where key.streamID == streamID { _ = erase(key) }
        for (name, orphan) in Array(orphans) where orphan.streamID == streamID { _ = eraseOrphan(name) }
    }

    func clear() {
        epoch = UUID()
        for key in Array(entries.keys) { _ = erase(key) }
        for name in Array(orphans.keys) { _ = eraseOrphan(name) }
    }

    private var canUseDisk: Bool {
        directoryFD >= 0 && (freeSpaceProvider(directory).map { $0 >= Self.minimumFreeBytes } ?? false)
    }

    @discardableResult private func erase(_ key: Key) -> Bool {
        guard var entry = entries[key] else { return true }
        guard unlinkat(directoryFD, key.name, 0) == 0 || errno == ENOENT else {
            entry.usable = false; entries[key] = entry
            return false
        }
        entries.removeValue(forKey: key); byteCount -= entry.bytes
        return true
    }

    private func eraseOrphan(_ name: String) -> Bool {
        guard let orphan = orphans[name] else { return true }
        guard unlinkat(directoryFD, name, 0) == 0 || errno == ENOENT else { return false }
        orphans.removeValue(forKey: name); byteCount -= orphan.reservedBytes
        return true
    }

    private func discard(_ name: String, streamID: UUID, reservedBytes: Int) {
        guard unlinkat(directoryFD, name, 0) != 0, errno != ENOENT else { return }
        orphans[name] = Orphan(streamID: streamID, reservedBytes: reservedBytes)
        byteCount += reservedBytes
    }

    private static var defaultDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("Hongguo", isDirectory: true)
            .appendingPathComponent("PlaybackChunks", isDirectory: true)
    }

    private static func availableCapacity(_ directory: URL) -> Int64? {
        if let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage { return capacity }
        return (try? FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func prepareDirectory(_ directory: URL) -> Int32 {
        guard directory.isFileURL, !directory.path.isEmpty, !directory.path.contains("\0") else { return -1 }
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT else { return -1 }
            do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
            catch { return -1 }
        }
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        // Only our UUID-index files are disposable; no recursion or symlink following.
        guard let names = names(in: fd) else { Darwin.close(fd); return -1 }
        for name in names where legalName(name) {
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                Darwin.close(fd); return -1
            }
            let kind = info.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK,
                  unlinkat(fd, name, 0) == 0 || errno == ENOENT else {
                Darwin.close(fd); return -1
            }
        }
        return fd
    }

    private static func legalName(_ name: String) -> Bool {
        guard name.utf8.count >= 38, name.utf8.count <= 57 else { return false }
        let split = name.index(name.startIndex, offsetBy: 36)
        guard name[split] == "-", UUID(uuidString: String(name[..<split])) != nil else { return false }
        let index = name[name.index(after: split)...]
        return !index.isEmpty && index.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } && Int(index) != nil
    }

    private static func names(in fd: Int32) -> [String]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let directory = fdopendir(copy) else { Darwin.close(copy); return nil }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? names : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(cString: $0)
                }
            }
            names.append(name)
        }
    }

    private static func read(name: String, directoryFD: Int32, count: Int) -> Data? {
        let fd = openat(directoryFD, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size == count else { return nil }
        var data = Data(count: count)
        let complete = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < count {
                if Task.isCancelled { return false }
                let size = Darwin.read(fd, base.advanced(by: offset), count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { return false }
                offset += size
            }
            return true
        }
        guard complete, fstat(fd, &info) == 0, info.st_size == count else { return nil }
        return data
    }

    private static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < data.count {
                if Task.isCancelled { return false }
                let size = Darwin.write(fd, base.advanced(by: offset), data.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { return false }
                offset += size
            }
            return true
        }
    }
}
