// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

public enum RecommendationTopicPreferenceError: Error, Sendable, Equatable, LocalizedError {
    case invalidTag, limitReached, invalidScope, invalidData, capacity
    public var errorDescription: String? {
        switch self {
        case .invalidTag: "這個題材無法設定偏好。"
        case .limitReached: "最多設定 32 個題材，請先恢復部分偏好。"
        case .invalidScope: "目前片庫或來源無法保存題材偏好。"
        case .invalidData, .capacity: "無法保存題材偏好，原有設定已保留。"
        }
    }
}

/// The same source-tag rules used for local ranking: never infer a topic from a title.
public enum RecommendationTopicTag {
    public static let maximumLength = 40
    private static let genericTags: Set<String> = ["剧情", "短剧", "短剧推荐", "热门", "热播", "全部", "真人", "真人剧", "真人短剧",
        "短篇", "连载", "完结", "全集", "高清", "漫剧", "动漫", "动画", "ai", "ai剧", "ai短剧", "ai漫剧"]

    public static func normalized(_ raw: String) -> (key: String, title: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maximumLength,
              !trimmed.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        let title = trimmed.precomposedStringWithCompatibilityMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = title.lowercased()
        guard title.count <= maximumLength, !title.contains("://"),
              !["http:", "https:", "file:", "data:", "ftp:"].contains(where: { lower.hasPrefix($0) }) else { return nil }
        let key = SearchText.comparisonKey(title)
        guard !key.isEmpty, !genericTags.contains(key) else { return nil }
        return (key, title)
    }
}

/// Explicit device-local choices, independent of single-work exclusions and watch history.
public struct RecommendationTopicPreferences: Codable, Equatable, Sendable {
    public enum Preference: String, Codable, CaseIterable, Sendable { case more, less, neutral }
    public struct Entry: Codable, Equatable, Sendable, Identifiable {
        public let key: String
        public let title: String
        public let preference: Preference
        public var id: String { key }
        private enum CodingKeys: String, CodingKey { case title, preference }
        fileprivate init(key: String, title: String, preference: Preference) {
            self.key = key; self.title = title; self.preference = preference
        }
        public init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            let title = try values.decode(String.self, forKey: .title)
            guard let normalized = RecommendationTopicTag.normalized(title) else { throw RecommendationTopicPreferenceError.invalidData }
            self.key = normalized.key; self.title = normalized.title
            preference = try values.decode(Preference.self, forKey: .preference)
        }
    }
    public static let maximumEntries = 32
    public private(set) var entries: [Entry] = []
    public var isEmpty: Bool { entries.isEmpty }
    public init() {}

    public mutating func set(tag: String, preference: Preference) throws {
        guard let normalized = RecommendationTopicTag.normalized(tag) else { throw RecommendationTopicPreferenceError.invalidTag }
        if preference != .neutral, !entries.contains(where: { $0.key == normalized.key }), entries.count >= Self.maximumEntries {
            throw RecommendationTopicPreferenceError.limitReached
        }
        entries.removeAll { $0.key == normalized.key }
        if preference != .neutral { entries.insert(.init(key: normalized.key, title: normalized.title, preference: preference), at: 0) }
    }

    public func preference(for tag: String) -> Preference {
        guard let key = RecommendationTopicTag.normalized(tag)?.key else { return .neutral }
        return entries.first(where: { $0.key == key })?.preference ?? .neutral
    }
    public mutating func clear() { entries = [] }
    private enum CodingKeys: String, CodingKey { case entries }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let rows = try values.decodeIfPresent([Entry].self, forKey: .entries) ?? []
        guard rows.count <= Self.maximumEntries else { throw RecommendationTopicPreferenceError.invalidData }
        var seen: Set<String> = []
        entries = rows.filter { seen.insert($0.key).inserted && $0.preference != .neutral }
    }
}

/// One bounded UserDefaults blob. Raw scope/account identifiers and URLs never enter storage.
/// All encoding and I/O run on this serial background queue, outside the main actor.
public final class RecommendationTopicPreferencesStore: @unchecked Sendable {
    public static let shared = RecommendationTopicPreferencesStore(defaults: .standard)
    public static let maximumScopes = 8
    public static let maximumBytes = 128 * 1024
    private struct Envelope: Codable { let version: Int; var scopes: [StoredScope] }
    private struct StoredScope: Codable {
        let key: String
        let updated: Date
        let preferences: RecommendationTopicPreferences
    }
    private let defaults: UserDefaults
    private let storageKey: String
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "tw.mountainp.hongguo.topic-preferences", qos: .utility)

    public init(defaults: UserDefaults, storageKey: String = "recommendation.topics.v1",
                now: @escaping @Sendable () -> Date = Date.init) {
        self.defaults = defaults; self.storageKey = storageKey; self.now = now
    }

    public func load(scope: LibraryScope, category: DirectWebService.Category) async throws -> RecommendationTopicPreferences {
        let key = try Self.scopeKey(scope, category: category)
        return try await access { [self] in envelope().scopes.first(where: { $0.key == key })?.preferences ?? .init() }
    }

    public func save(_ preferences: RecommendationTopicPreferences, scope: LibraryScope,
                     category: DirectWebService.Category) async throws {
        let key = try Self.scopeKey(scope, category: category)
        try await access { [self] in
            var scopes = envelope().scopes.filter { $0.key != key }
            if !preferences.isEmpty {
                let date = now()
                guard date.timeIntervalSince1970.isFinite else { throw RecommendationTopicPreferenceError.invalidData }
                let entry = StoredScope(key: key, updated: date, preferences: preferences)
                scopes.insert(entry, at: 0)
                // The current explicit update wins timestamp ties; old scopes remain in recency order.
                scopes = Array(scopes.prefix(Self.maximumScopes))
            }
            if scopes.isEmpty { defaults.removeObject(forKey: storageKey); return }
            let data = try JSONEncoder().encode(Envelope(version: 1, scopes: scopes))
            guard data.count <= Self.maximumBytes else { throw RecommendationTopicPreferenceError.capacity }
            defaults.set(data, forKey: storageKey)
        }
    }

    public func clear(scope: LibraryScope, category: DirectWebService.Category) async throws {
        try await save(.init(), scope: scope, category: category)
    }

    private func envelope() -> Envelope {
        guard let data = defaults.data(forKey: storageKey), data.count <= Self.maximumBytes,
              let value = try? JSONDecoder().decode(Envelope.self, from: data), value.version == 1,
              value.scopes.count <= Self.maximumScopes else { return Envelope(version: 1, scopes: []) }
        var seen: Set<String> = []
        let valid = value.scopes.filter {
            $0.key.count == 64 && $0.key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                && $0.updated.timeIntervalSince1970.isFinite && seen.insert($0.key).inserted
        }
        return Envelope(version: 1, scopes: valid)
    }

    private static func scopeKey(_ scope: LibraryScope, category: DirectWebService.Category) throws -> String {
        func valid(_ value: String, limit: Int) -> Bool {
            !value.isEmpty && value.count <= limit && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
        guard valid(scope.sourceID, limit: 512) else { throw RecommendationTopicPreferenceError.invalidScope }
        let owner: String
        switch scope.owner {
        case .guest: owner = "guest"
        case .account(let id):
            guard valid(id, limit: 256) else { throw RecommendationTopicPreferenceError.invalidScope }
            owner = "account:" + id
        }
        let data = try JSONSerialization.data(withJSONObject: [owner, scope.sourceID, category.rawValue])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func access<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async { continuation.resume(with: Result(catching: work)) }
        }
        try Task.checkCancellation()
        return result
    }
}
