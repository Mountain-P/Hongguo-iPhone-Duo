// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only explicit user choices are persisted. Temporary boosts and locks are excluded.
public struct PlaybackPreferences: Sendable, Equatable {
    public let normalRate: Float
    public let autoNext: Bool

    public init(normalRate: Float = 1, autoNext: Bool = true) {
        self.normalRate = normalRate.isFinite && (0.25...4).contains(normalRate) ? normalRate : 1
        self.autoNext = autoNext
    }

    public func resolved(isPreview: Bool) -> PlaybackPreferences {
        PlaybackPreferences(normalRate: normalRate, autoNext: !isPreview && autoNext)
    }
}

@MainActor
public final class PlaybackPreferencesStore {
    public static let shared = PlaybackPreferencesStore()
    public static let normalRateKey = "player.normalRate.v1"
    public static let autoNextKey = "player.autoNext.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> PlaybackPreferences {
        PlaybackPreferences(normalRate: (defaults.object(forKey: Self.normalRateKey) as? NSNumber)?.floatValue ?? 1,
                            autoNext: defaults.object(forKey: Self.autoNextKey) as? Bool ?? true)
    }

    public func setNormalRate(_ rate: Float) {
        guard rate.isFinite, (0.25...4).contains(rate) else { return }
        defaults.set(rate, forKey: Self.normalRateKey)
    }

    public func setAutoNext(_ enabled: Bool) { defaults.set(enabled, forKey: Self.autoNextKey) }
}

public enum PlaybackReplay {
    /// Unknown/non-finite durations are not evidence that an item reached its end.
    public static func shouldRestart(position: Double, duration: Double, reachedEnd: Bool) -> Bool {
        guard duration.isFinite, duration > 0, position.isFinite, position >= 0 else { return false }
        return reachedEnd || position >= duration - min(0.25, duration * 0.02)
    }
}
