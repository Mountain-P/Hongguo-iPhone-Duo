import Foundation

/// Fair bounded metadata batches. Failed IDs move behind untried IDs and cool down.
public struct MetadataHydrationScheduler: Sendable {
    private var order: [String] = []
    private struct Failure: Sendable { var count: Int; var retryAt: Date }
    private var failures: [String: Failure] = [:]
    private let capacity: Int
    private let cooldown: TimeInterval

    public init(capacity: Int = 10_000, cooldown: TimeInterval = 30) {
        self.capacity = max(1, min(capacity, 10_000))
        self.cooldown = cooldown.isFinite ? max(1, min(cooldown, 300)) : 30
    }

    public mutating func batch(candidates: [String], now: Date = Date(), limit: Int = 50) -> [String] {
        var seen: Set<String> = []
        let candidates = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }.prefix(capacity)
        let current = Set(candidates)
        order.removeAll { !current.contains($0) }
        failures = failures.filter { current.contains($0.key) }
        let existing = Set(order)
        order.append(contentsOf: candidates.filter { !existing.contains($0) })
        let selected = Array(order.filter { failures[$0].map { $0.retryAt <= now } ?? true }.prefix(max(0, min(limit, 50))))
        let selectedSet = Set(selected)
        order.removeAll { selectedSet.contains($0) }
        order.append(contentsOf: selected)
        return selected
    }

    public mutating func completed(_ id: String, succeeded: Bool, now: Date = Date()) {
        guard order.contains(id) else { return }
        if succeeded { failures.removeValue(forKey: id) }
        else {
            let count = min((failures[id]?.count ?? 0) + 1, 5)
            failures[id] = Failure(count: count, retryAt: now.addingTimeInterval(min(300, cooldown * pow(2, Double(count - 1)))))
        }
    }
}

/// A cancelled batch's defer or result cannot mutate a replacement batch's state.
public struct MetadataHydrationGeneration: Sendable {
    public struct Lease: Hashable, Sendable { public let scope: LibraryScope; private let id = UUID() }
    private var current: Lease?
    public init() {}
    public mutating func begin(scope: LibraryScope) -> Lease {
        let lease = Lease(scope: scope); current = lease; return lease
    }
    public func accepts(_ lease: Lease) -> Bool { current == lease }
    public mutating func invalidate() { current = nil }
}

/// LRU/TTL bounds include episode count, since one series may contain thousands of episodes.
public struct LibraryDetailCache: Sendable {
    private struct Entry: Sendable { let detail: SeriesDetail; let expiry: Date; var access: UInt64 }
    private var entries: [String: Entry] = [:]
    private var sequence: UInt64 = 0
    private let capacity: Int
    private let ttl: TimeInterval
    private let maximumEpisodes: Int
    public var count: Int { entries.count }
    public var episodeCount: Int { entries.values.reduce(0) { $0 + $1.detail.episodes.count } }

    public init(capacity: Int = 48, ttl: TimeInterval = 600, maximumEpisodes: Int = 12_000) {
        self.capacity = max(1, min(capacity, 500))
        self.ttl = ttl.isFinite ? max(1, ttl) : 600
        self.maximumEpisodes = max(1, maximumEpisodes)
    }
    public mutating func value(for id: String, now: Date = Date()) -> SeriesDetail? {
        purge(now)
        guard var entry = entries[id] else { return nil }
        sequence &+= 1; entry.access = sequence; entries[id] = entry
        return entry.detail
    }
    public mutating func insert(_ detail: SeriesDetail, now: Date = Date()) {
        purge(now)
        guard detail.episodes.count <= maximumEpisodes else { return }
        sequence &+= 1
        entries[detail.series.id] = Entry(detail: detail, expiry: now.addingTimeInterval(ttl), access: sequence)
        while entries.count > capacity || episodeCount > maximumEpisodes {
            guard let oldest = entries.min(by: { $0.value.access < $1.value.access })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }
    public mutating func removeAll() { entries.removeAll(); sequence = 0 }
    private mutating func purge(_ now: Date) { entries = entries.filter { $0.value.expiry > now } }
}
