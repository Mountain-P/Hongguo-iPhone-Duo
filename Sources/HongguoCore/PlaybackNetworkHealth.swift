// SPDX-License-Identifier: GPL-3.0-only
import Foundation

public struct PlaybackTransferSnapshot: Sendable {
    public var bytesPerSecond: Double = 0
    public var completedRanges: Int = 0
    public var failures: Int = 0
    public var idleSeconds: Double = 0
    public var activeRanges: Int = 0
    public init(bytesPerSecond: Double = 0, completedRanges: Int = 0, failures: Int = 0, idleSeconds: Double = 0, activeRanges: Int = 0) {
        self.bytesPerSecond = bytesPerSecond; self.completedRanges = completedRanges
        self.failures = failures; self.idleSeconds = idleSeconds; self.activeRanges = activeRanges
    }
}

/// Records network transfers only. Cache hits and queued requests are not speed samples.
final class NativeTransferHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var active: [UUID: (start: Double, received: Double)] = [:]
    private var value = PlaybackTransferSnapshot()
    func begin(id: UUID) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock { active[id] = (now, now) }
    }
    func received(id: UUID) { lock.withLock { active[id]?.received = ProcessInfo.processInfo.systemUptime } }
    func finish(id: UUID, bytes: Int, cancelled: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            guard let request = active.removeValue(forKey: id), !cancelled else { return }
            if bytes > 0 {
                let speed = Double(bytes) / max(0.001, now - request.start)
                value.bytesPerSecond = value.completedRanges == 0 ? speed : value.bytesPerSecond * 0.5 + speed * 0.5
                value.completedRanges += 1; value.failures = 0
            } else { value.failures += 1 }
        }
    }
    var snapshot: PlaybackTransferSnapshot {
        lock.withLock {
            var result = value
            result.activeRanges = active.count
            result.idleSeconds = active.values.map { ProcessInfo.processInfo.systemUptime - $0.received }.max() ?? 0
            return result
        }
    }
}

/// Short-lived host performance. Never stores signed URLs, keys or account data.
final class NativeCDNPerformance: @unchecked Sendable {
    static let shared = NativeCDNPerformance()
    private struct Entry { var speed: Double; var expires: Double; var failed: Bool }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    func record(host: String, bytes: Int, seconds: Double, failed: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard seconds.isFinite, seconds > 0, failed || bytes >= 128 * 1024 else { return }
        lock.withLock {
            entries = entries.filter { $0.value.expires > now }
            let measured = Double(bytes) / max(0.001, seconds)
            let speed = entries[host].map { $0.speed * 0.5 + measured * 0.5 } ?? measured
            entries[host] = Entry(speed: speed, expires: now + (failed ? 30 : 120), failed: failed)
            if entries.count > 32, let oldest = entries.min(by: { $0.value.expires < $1.value.expires }) { entries.removeValue(forKey: oldest.key) }
        }
    }
    func ranked(_ sources: [NativeMediaSource], now: Double = ProcessInfo.processInfo.systemUptime) -> [NativeMediaSource] {
        lock.withLock {
            entries = entries.filter { $0.value.expires > now }
            return sources.enumerated().sorted { a, b in
                let x = entries[a.element.url.host ?? ""], y = entries[b.element.url.host ?? ""]
                func score(_ value: Entry?) -> Int {
                    guard let value else { return 0 }
                    if value.failed { return -1 }
                    return 1 + Int(log(max(1, value.speed)) / log(1.25))
                }
                let left = score(x), right = score(y)
                return left == right ? a.offset < b.offset : left > right
            }.map(\.element)
        }
    }
}

public enum PlaybackTransferContext {
    @TaskLocal public static var isBackground = false
    @TaskLocal public static var raceAlternates = false
}

/// Renewable pressure leases avoid leaving offline work suspended after a player disappears.
public final class PlaybackNetworkPriority: @unchecked Sendable {
    public static let shared = PlaybackNetworkPriority()
    private let lock = NSLock()
    private var leases: [UUID: Double] = [:]
    public init() {}
    public func update(owner: UUID, constrained: Bool, now: Double = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            leases = leases.filter { $0.value > now }
            if constrained { leases[owner] = now + 5 } else { leases.removeValue(forKey: owner) }
        }
    }
    public func isConstrained(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.withLock { leases.values.contains { $0 > now } }
    }
    public func waitForForeground() async throws {
        while isConstrained() { try await Task.sleep(for: .milliseconds(250)) }
        try Task.checkCancellation()
    }
}

/// Wall-clock thresholds are independent of 1x/2x media time. One instance per item.
public struct PlaybackContinuityPolicy: Sendable {
    public enum Reason: Sendable { case terminal, stalled, slow }
    private var poorSince: Double?
    private var lastPreparation: Double?
    public init() {}
    public mutating func update(now: Double, eligible: Bool, terminal: Bool, waiting: Bool,
                                bufferedWallSeconds: Double, requiredBytesPerSecond: Double,
                                transfer: PlaybackTransferSnapshot) -> Reason? {
        guard eligible, now.isFinite, bufferedWallSeconds.isFinite else { poorSince = nil; return nil }
        let slow = transfer.activeRanges > 0 && transfer.completedRanges >= 3 && requiredBytesPerSecond > 0
            && transfer.bytesPerSecond < requiredBytesPerSecond * 1.15
        let poor = waiting || (bufferedWallSeconds < 12 && (slow || transfer.idleSeconds >= 3 || transfer.failures > 0))
        if !poor && !terminal { poorSince = nil; return nil }
        if poorSince == nil { poorSince = now }
        guard lastPreparation.map({ now - $0 >= 20 }) ?? true else { return nil }
        guard terminal || now - (poorSince ?? now) >= (waiting ? 3 : 4) else { return nil }
        lastPreparation = now; poorSince = nil
        return terminal ? .terminal : (waiting ? .stalled : .slow)
    }
}
