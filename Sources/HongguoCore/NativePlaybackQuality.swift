// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Best/low rendition selection, plus an opt-in conservative adaptive playback policy.
public enum NativePlaybackQuality: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic, smooth, dataSaver
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .automatic: "自動（最佳可用）"
        case .smooth: "自動流暢"
        case .dataSaver: "省流量"
        }
    }
    public var sourcePreference: Self { self == .smooth ? .automatic : self }
}

/// The selected rendition's displayable facts. Contains no media URL, key or identity.
public struct NativeMediaVariant: Sendable, Equatable {
    public let preference: NativePlaybackQuality
    public let codec: String
    public let quality: String
    public let width: Int?
    public let height: Int?
    public let qualityFallback: Bool

    init(source: NativeMediaSource) {
        preference = source.preference; codec = source.codec; quality = source.quality
        width = source.width; height = source.height; qualityFallback = source.qualityFallback
    }
}

@MainActor
public final class NativePlaybackQualityStore {
    public static let shared = NativePlaybackQualityStore()
    public static let key = "nativePlaybackQuality.v1"
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func load() -> NativePlaybackQuality {
        defaults.string(forKey: Self.key).flatMap(NativePlaybackQuality.init(rawValue:)) ?? .automatic
    }
    public func save(_ quality: NativePlaybackQuality) { defaults.set(quality.rawValue, forKey: Self.key) }
}
