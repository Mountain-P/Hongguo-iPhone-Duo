// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// A disposable preview-only cache. Restored rows have no cover URL or description.
public struct PreviewSession: Sendable {
    public let items: [Series]
    public let currentStableID: String
    public let snapshot: PreviewPlaybackSnapshot?

    /// A saved episode ID is never a playback authority, including when episode numbering changed.
    public func resumeSeconds(in detail: SeriesDetail) -> Double {
        guard detail.series.id == currentStableID, let snapshot,
              snapshot.seriesID == currentStableID,
              let first = try? RecommendationPreviewQueue.firstEpisode(in: detail, expectedSeriesID: currentStableID),
              first.id == snapshot.episodeID,
              snapshot.position.isFinite, snapshot.position >= 0,
              snapshot.duration.isFinite, snapshot.duration > 0,
              snapshot.position < snapshot.duration * 0.98 else { return 0 }
        return min(snapshot.position, snapshot.duration)
    }
}

public enum PreviewSessionError: Error, Sendable, Equatable { case invalidScope, invalidSession, capacity }

/// Encoding and UserDefaults access are confined to one background queue. No account credentials,
/// media URLs, image bytes, source cursors or running work are accepted by the stored DTOs.
public final class PreviewSessionStore: @unchecked Sendable {
    public static let shared = PreviewSessionStore(defaults: .standard)
    public static let timeToLive: TimeInterval = 24 * 60 * 60
    public static let maximumSessions = 8
    public static let maximumItems = 24
    public static let maximumBytes = 128 * 1024
    static let defaultKey = "preview.sessions.v1"
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.preview-session", qos: .utility)
    private let defaults: UserDefaults
    private let key: String
    private let now: @Sendable () -> Date

    public init(defaults: UserDefaults, storageKey: String = "preview.sessions.v1",
                now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults; key = storageKey; self.now = now
    }

    public func load(scope: LibraryScope, category: DirectWebService.Category,
                     preferences: RecommendationPreferences) async throws -> PreviewSession? {
        guard preferences.category == category else { return nil }
        let scopeKey = try Self.scopeKey(scope, category: category)
        return try await access { [self] in
            let date = now()
            guard date.timeIntervalSince1970.isFinite,
                  let stored = envelope().sessions.first(where: { $0.scopeKey == scopeKey }),
                  validAge(stored.savedAt, at: date), stored.items.count <= Self.maximumItems,
                  let originalIndex = stored.items.firstIndex(where: { $0.id == stored.currentStableID }) else { return nil }
            let rows = stored.items.compactMap { $0.series }
            let allowed = preferences.filter(rows)
            guard !allowed.isEmpty else { return nil }
            let allowedIDs = Set(allowed.map(\.id))
            let current: String
            if allowedIDs.contains(stored.currentStableID) { current = stored.currentStableID }
            else {
                current = stored.items.dropFirst(originalIndex + 1).first(where: { allowedIDs.contains($0.id) })?.id
                    ?? stored.items.prefix(originalIndex).last(where: { allowedIDs.contains($0.id) })?.id
                    ?? allowed[0].id
            }
            let snapshot = current == stored.currentStableID ? stored.position?.snapshot(seriesID: current) : nil
            return PreviewSession(items: allowed, currentStableID: current, snapshot: snapshot)
        }
    }

    public func save(scope: LibraryScope, category: DirectWebService.Category, items: [Series],
                     currentStableID: String, snapshot: PreviewPlaybackSnapshot?) async throws {
        let scopeKey = try Self.scopeKey(scope, category: category)
        // Bound the work before hopping to the queue; the feed itself holds at most 500 cards.
        guard items.count <= 500 else { throw PreviewSessionError.capacity }
        try await access { [self] in
            var seen: Set<String> = []
            let rows = items.compactMap(StoredItem.init).filter { seen.insert($0.id).inserted }
            guard let index = rows.firstIndex(where: { $0.id == currentStableID }) else { throw PreviewSessionError.invalidSession }
            let start = max(0, min(index - 4, rows.count - min(Self.maximumItems, rows.count)))
            let selection = Array(rows[start..<min(rows.count, start + Self.maximumItems)])
            let date = now()
            guard date.timeIntervalSince1970.isFinite else { throw PreviewSessionError.invalidSession }
            let position = snapshot.flatMap { StoredPosition($0, seriesID: currentStableID) }
            let entry = StoredSession(scopeKey: scopeKey, savedAt: date, items: selection,
                                      currentStableID: currentStableID, position: position)
            var values = envelope().sessions.filter { $0.scopeKey != scopeKey && validAge($0.savedAt, at: date) }
            values.append(entry); values.sort { $0.savedAt > $1.savedAt }
            values = Array(values.prefix(Self.maximumSessions))
            // Equal timestamps cannot evict the current write.
            if !values.contains(where: { $0.scopeKey == scopeKey }) {
                if !values.isEmpty { values.removeLast() }; values.append(entry)
            }
            var encoded = try Self.encoder().encode(Envelope(version: 1, sessions: values))
            while encoded.count > Self.maximumBytes, values.count > 1 {
                guard let oldest = values.indices.reversed().first(where: { values[$0].scopeKey != scopeKey }) else { break }
                values.remove(at: oldest)
                encoded = try Self.encoder().encode(Envelope(version: 1, sessions: values))
            }
            guard encoded.count <= Self.maximumBytes else { throw PreviewSessionError.capacity }
            defaults.set(encoded, forKey: key)
        }
    }

    public func remove(scope: LibraryScope, category: DirectWebService.Category) async throws {
        let scopeKey = try Self.scopeKey(scope, category: category)
        try await access { [self] in
            let values = envelope().sessions.filter { $0.scopeKey != scopeKey }
            if values.isEmpty { defaults.removeObject(forKey: key) }
            else { defaults.set(try Self.encoder().encode(Envelope(version: 1, sessions: values)), forKey: key) }
        }
    }

    private struct Envelope: Codable { let version: Int; let sessions: [StoredSession] }
    private struct StoredSession: Codable {
        let scopeKey: String
        let savedAt: Date
        let items: [StoredItem]
        let currentStableID: String
        let position: StoredPosition?
    }
    private struct StoredItem: Codable {
        let id: String
        let title: String
        let badge: String
        let tags: [String]
        init?(_ series: Series) {
            guard Self.validID(series.id), let title = PreviewSessionStore.text(series.title, limit: 80) else { return nil }
            id = series.id; self.title = title
            badge = PreviewSessionStore.text(series.badge, limit: 48) ?? ""
            var seen: Set<String> = []
            tags = Array(series.tags.prefix(16).compactMap { PreviewSessionStore.text($0, limit: 24) }
                .filter { seen.insert($0).inserted }.prefix(6))
        }
        var series: Series? {
            guard Self.validID(id), let clean = StoredItem(Series(id: id, title: title, badge: badge, tags: tags)),
                  clean.title == title, clean.badge == badge, clean.tags == tags else { return nil }
            return Series(id: id, title: title, badge: badge, tags: tags)
        }
        private static func validID(_ id: String) -> Bool {
            (try? validateID(id)) != nil && id.contains(where: { $0 != "0" })
        }
    }
    private struct StoredPosition: Codable {
        let episodeID: String
        let position: Double
        let duration: Double
        init?(_ snapshot: PreviewPlaybackSnapshot, seriesID: String) {
            guard snapshot.seriesID == seriesID, (try? validateID(snapshot.episodeID)) != nil,
                  snapshot.episodeID.contains(where: { $0 != "0" }), snapshot.position.isFinite, snapshot.position >= 0,
                  snapshot.duration.isFinite, snapshot.duration > 0, snapshot.duration <= 4 * 60 * 60 else { return nil }
            episodeID = snapshot.episodeID; position = min(snapshot.position, snapshot.duration); duration = snapshot.duration
        }
        func snapshot(seriesID: String) -> PreviewPlaybackSnapshot? {
            let value = PreviewPlaybackSnapshot(seriesID: seriesID, episodeID: episodeID, position: position, duration: duration)
            guard let clean = StoredPosition(value, seriesID: seriesID), clean.position == position else { return nil }
            return value
        }
    }

    private func envelope() -> Envelope {
        guard let data = defaults.data(forKey: key), data.count <= Self.maximumBytes,
              let value = try? Self.decoder().decode(Envelope.self, from: data), value.version == 1,
              value.sessions.count <= Self.maximumSessions else { return Envelope(version: 1, sessions: []) }
        let sessions = value.sessions.compactMap { session -> StoredSession? in
            guard session.scopeKey.count == 64, session.scopeKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  !session.items.isEmpty, session.items.count <= Self.maximumItems,
                  session.items.allSatisfy({ $0.series != nil }),
                  Set(session.items.map(\.id)).count == session.items.count,
                  session.items.contains(where: { $0.id == session.currentStableID }) else { return nil }
            let position = session.position.flatMap { $0.snapshot(seriesID: session.currentStableID) }
                .flatMap { StoredPosition($0, seriesID: session.currentStableID) }
            return StoredSession(scopeKey: session.scopeKey, savedAt: session.savedAt, items: session.items,
                                 currentStableID: session.currentStableID, position: position)
        }
        return Envelope(version: 1, sessions: sessions)
    }
    private func validAge(_ date: Date, at now: Date) -> Bool {
        date.timeIntervalSince1970.isFinite && date <= now.addingTimeInterval(300)
            && now.timeIntervalSince(date) < Self.timeToLive
    }
    private static func scopeKey(_ scope: LibraryScope, category: DirectWebService.Category) throws -> String {
        let owner: String
        switch scope.owner {
        case .guest: owner = "guest"
        case .account(let id):
            guard let clean = text(id, limit: 256), clean == id else { throw PreviewSessionError.invalidScope }
            owner = "account:" + id
        }
        guard let source = text(scope.sourceID, limit: 512), source == scope.sourceID else { throw PreviewSessionError.invalidScope }
        let raw = try JSONSerialization.data(withJSONObject: [owner, source, category.rawValue])
        return SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
    }
    private static func text(_ raw: String, limit: Int) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("://"), !value.lowercased().hasPrefix("data:"),
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return String(value.prefix(limit))
    }
    private static func encoder() -> JSONEncoder {
        let value = JSONEncoder(); value.dateEncodingStrategy = .millisecondsSince1970; return value
    }
    private static func decoder() -> JSONDecoder {
        let value = JSONDecoder(); value.dateDecodingStrategy = .millisecondsSince1970; return value
    }
    private func access<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
        try Task.checkCancellation()
        return value
    }
}
