// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Short-lived anonymous playback identities shared by one-shot JS contexts.
/// Account sessions/cookies are never accepted or persisted here.
final class NativePlaybackIdentityCache: @unchecked Sendable {
    static let shared = NativePlaybackIdentityCache()
    private struct Entry { let json: String; let expires: TimeInterval }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let now: @Sendable () -> TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
    }

    func read(scope: String) -> String {
        lock.withLock {
            guard let entry = entries[scope], entry.expires > now() else {
                entries.removeValue(forKey: scope)
                return "null"
            }
            return entry.json
        }
    }

    @discardableResult
    func write(scope: String, json: String) -> Bool {
        guard ["tab", "legacy"].contains(scope), let data = json.data(using: .utf8), data.count < 512,
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              Set(value.keys) == ["device_id", "iid", "cdid"],
              let cdid = value["cdid"], UUID(uuidString: cdid) != nil else { return false }
        for key in ["device_id", "iid"] {
            guard let id = value[key], id.range(of: #"^\d{1,30}$"#, options: .regularExpression) != nil,
                  id.contains(where: { $0 != "0" }) else { return false }
        }
        lock.withLock { entries[scope] = Entry(json: json, expires: now() + 300) }
        return true
    }
}
