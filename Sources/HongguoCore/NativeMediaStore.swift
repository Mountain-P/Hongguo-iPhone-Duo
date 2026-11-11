// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CryptoKit
import OSLog

public enum NativeMediaError: Error, LocalizedError, Equatable, Sendable {
    case unsafeURL, unsupportedCodec, invalidKey, tooLarge, invalidResponse
    case httpStatus(Int), malformedMP4, unsupportedEncryption, missingEncryptionMetadata
    case decryptionFailed, storage, network, busy

    public var errorDescription: String? {
        switch self {
        case .unsafeURL: "影片來源網址不符合安全規則。"
        case .unsupportedCodec: "目前影片格式無法由 iPhone 播放。"
        case .invalidKey: "影片解密資料無效。"
        case .tooLarge: "這一集過大，暫時無法準備。"
        case .invalidResponse: "影片來源回應不完整，請重試。"
        case .httpStatus(403): "影片來源拒絕存取，請稍後再試或在官方平台觀看。"
        case .httpStatus(let status): "影片來源暫時無法使用（HTTP \(status)）。"
        case .malformedMP4: "影片結構不完整或格式已變更。"
        case .unsupportedEncryption: "目前尚不支援此影片的加密格式。"
        case .missingEncryptionMetadata: "影片缺少必要的解密索引。"
        case .decryptionFailed: "無法解密此影片。"
        case .storage: "無法準備本機影片檔案，請確認裝置空間。"
        case .network: "影片下載中斷，請檢查網路後重試。"
        case .busy: "正在準備其他影片，請稍後重試。"
        }
    }
}

public actor NativeMediaStore {
    public static let shared = NativeMediaStore()
    public static let maximumBytes = 100 * 1024 * 1024
    private struct CachedFile {
        let url: URL
        let date: Date
    }
    private let directory: URL
    private let downloader: any NativeMediaDownloading
    private let byteLimit: Int
    private var prepared: [String: CachedFile] = [:]
    private var activeDownloads = 0
    private var didCleanOldFiles = false

    public init() {
        self.directory = (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("HongguoNativeMedia", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        self.downloader = NativeMediaHTTPDownload()
        self.byteLimit = Self.maximumBytes
    }

    init(cacheDirectory: URL, downloader: any NativeMediaDownloading, byteLimit: Int = NativeMediaStore.maximumBytes) {
        self.directory = cacheDirectory.standardizedFileURL.resolvingSymlinksInPath()
        self.downloader = downloader
        self.byteLimit = min(max(byteLimit, 1), Self.maximumBytes)
    }

    public func prepare(source: NativeMediaSource, episodeID: String, fresh: Bool = false) async throws -> URL {
        try Task.checkCancellation()
        try validateID(episodeID)
        try NativeMediaPolicy.validate(source)
        let identity = episodeID + "\n" + source.codec.lowercased() + "\n" + source.quality + "\n"
            + (source.contentKey.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() } ?? "clear")
        let cacheKey = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if !fresh, let file = prepared[cacheKey], Date().timeIntervalSince(file.date) < 6 * 60 * 60,
           FileManager.default.fileExists(atPath: file.url.path) {
            return file.url
        }
        guard activeDownloads < 2 else { throw NativeMediaError.busy }
        activeDownloads += 1
        defer { activeDownloads -= 1 }
        let staging = directory.appendingPathComponent(UUID().uuidString + ".download")
        let destination = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            if !didCleanOldFiles {
                didCleanOldFiles = true
                cleanOldFiles()
            }
            try await downloader.download(source: source, destination: staging, maximumBytes: Int64(byteLimit))
            try Task.checkCancellation()
            let attributes = try FileManager.default.attributesOfItem(atPath: staging.path)
            guard let size = attributes[.size] as? NSNumber, size.int64Value > 0 else { throw NativeMediaError.invalidResponse }
            guard size.int64Value <= Int64(byteLimit) else { throw NativeMediaError.tooLarge }
            let encrypted = try Data(contentsOf: staging, options: .mappedIfSafe)
            let clear = try NativeMP4.decrypt(data: encrypted, contentKey: source.contentKey, codec: source.codec)
            try Task.checkCancellation()
            try clear.write(to: destination, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try Task.checkCancellation()
            try? FileManager.default.removeItem(at: staging)
            let superseded = prepared[cacheKey]?.url
            prepared[cacheKey] = .init(url: destination, date: Date())
            if let superseded, superseded != destination { try? FileManager.default.removeItem(at: superseded) }
            trimCache(keeping: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: destination)
            if error is CancellationError { throw CancellationError() }
            if let safe = error as? NativeMediaError { throw safe }
            if let safe = error as? CatalogError { throw safe }
            throw NativeMediaError.storage
        }
    }

    private func cleanOldFiles() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        for file in files {
            guard ["mp4", "download"].contains(file.pathExtension),
                  let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate, Date().timeIntervalSince(date) > 24 * 60 * 60 else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Keep two newest files available for overlapping preparations/player handoff.
    /// Downloads are separately bounded to two 100 MB transfers.
    private func trimCache(keeping current: URL) {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { file -> (url: URL, date: Date, bytes: Int)? in
            guard file.pathExtension == "mp4", let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true, let date = values.contentModificationDate,
                  let bytes = values.fileSize else { return nil }
            return (file, date, bytes)
        }.sorted { $0.date > $1.date }
        // Foundation can represent the same temporary directory with /var or /private/var.
        // UUID filenames are the stable identity within this one cache directory.
        let protected = Set(entries.prefix(2).map { $0.url.lastPathComponent }).union([current.lastPathComponent])
        var count = entries.count
        var bytes = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.reversed() where !protected.contains(entry.url.lastPathComponent) {
            guard count > 6 || bytes > 300 * 1024 * 1024 else { break }
            if (try? FileManager.default.removeItem(at: entry.url)) != nil {
                count -= 1
                bytes -= entry.bytes
                prepared = prepared.filter { $0.value.url.lastPathComponent != entry.url.lastPathComponent }
            }
        }
    }
}

enum NativeMediaPolicy {
    enum Rejection: String {
        case missingURL, scheme, credentials, fragment, port, urlLength, host
        case userAgentLength, userAgentControlCharacter, redirectLimit
    }

    enum Stage: String { case source, rangeRedirect, rangeResponse }

    private static let domains = ["qznovelvod.com", "fqnovelvod.com", "douyinvod.com"]
    private static let scheduledPlaybackOrigins: Set<String> = [
        "v5-reading-video-a.qznovelvod.com", "v5-reading-video-b.qznovelvod.com",
        "v5-ex-reading-video-a.qznovelvod.com"
    ]
    private enum ScheduledCDN: String, CaseIterable {
        case vegslb = ".vegslb.com"
        case bdcgslb = ".bdcgslb.com"
    }
    private static let logger = Logger(subsystem: "tw.mountainp.hongguo", category: "media-policy")

    static func allows(_ url: URL) -> Bool {
        rejection(of: url) == nil
    }

    static func rejection(of url: URL?) -> Rejection? {
        guard let url else { return .missingURL }
        guard url.scheme?.lowercased() == "https" else { return .scheme }
        guard url.user == nil, url.password == nil else { return .credentials }
        guard url.fragment == nil else { return .fragment }
        guard url.port == nil || url.port == 443 else { return .port }
        guard url.absoluteString.count <= 32_768 else { return .urlLength }
        guard let host = url.host?.lowercased(), domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            return .host
        }
        return nil
    }

    static func redirectRejection(of url: URL?, hops: Int) -> Rejection? {
        guard hops <= 3 else { return .redirectLimit }
        return rejection(of: url)
    }

    static func isScheduledPlaybackOrigin(_ url: URL) -> Bool {
        guard allows(url), let host = url.host(percentEncoded: true) else { return false }
        return scheduledPlaybackOrigins.contains(host.lowercased())
    }

    static func allowsScheduledCDNRedirect(from origin: URL, to target: URL?) -> Bool {
        isScheduledPlaybackOrigin(origin) && scheduledCDN(for: target) != nil
    }

    static func allowsScheduledCDNRelay(from approvedURL: URL?, to target: URL?) -> Bool {
        scheduledCDN(for: approvedURL) == .vegslb && scheduledCDN(for: target) == .bdcgslb
    }

    private static func scheduledCDN(for target: URL?) -> ScheduledCDN? {
        guard rejection(of: target) == .host,
              let host = target?.host(percentEncoded: true),
              let family = ScheduledCDN.allCases.first(where: { host.hasSuffix($0.rawValue) }) else { return nil }
        let label = host.dropLast(family.rawValue.count).utf8
        let hyphen = UInt8(ascii: "-")
        guard (1...63).contains(label.count), label.first != hyphen, label.last != hyphen else { return nil }
        let lowercase = UInt8(ascii: "a")...UInt8(ascii: "z")
        let digits = UInt8(ascii: "0")...UInt8(ascii: "9")
        return label.allSatisfy { lowercase.contains($0) || digits.contains($0) || $0 == hyphen } ? family : nil
    }

    static func sourceRejection(_ source: NativeMediaSource) -> Rejection? {
        if let reason = rejection(of: source.url) { return reason }
        guard source.userAgent.utf8.count <= 2048 else { return .userAgentLength }
        guard !source.userAgent.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return .userAgentControlCharacter
        }
        return nil
    }

    static func report(_ reason: Rejection, stage: Stage, status: Int = 0, hops: Int = 0) {
        // Never interpolate URLs, header values, source objects, or raw errors here.
        logger.notice("Rejected media stage=\(stage.rawValue, privacy: .public) reason=\(reason.rawValue, privacy: .public) status=\(status, privacy: .public) hops=\(hops, privacy: .public)")
    }

    static func validate(_ source: NativeMediaSource) throws {
        if let reason = sourceRejection(source) {
            report(reason, stage: .source)
            throw NativeMediaError.unsafeURL
        }
        guard ["h264", "avc", "avc1", "avc3", "hevc", "h265", "hvc1", "hev1", "bytevc1"].contains(source.codec.lowercased()) else {
            throw NativeMediaError.unsupportedCodec
        }
        if let key = source.contentKey, key.count != 16 { throw NativeMediaError.invalidKey }
    }
}
