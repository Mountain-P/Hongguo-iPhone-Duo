// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// An in-memory, single-owner claim policy, not a persistent playback or library identity.
/// The runtime token must privately own this value and serialize claim/promotion together.
public struct PlaybackHandoffEligibility: Sendable, Equatable {
    public static let positionTolerance: Double = 2
    public static let maximumAge: Double = 60

    public struct Context: Sendable, Equatable {
        public let scope: LibraryScope
        public let revision: UUID
        public let quality: NativePlaybackQuality

        public init(scope: LibraryScope, revision: UUID, quality: NativePlaybackQuality) {
            self.scope = scope; self.revision = revision; self.quality = quality
        }
    }

    /// A fresh observation of the paused preview, supplied when the latest route is ready.
    public struct Playback: Sendable, Equatable {
        public let seriesID: String
        public let episodeID: String
        public let position: Double
        public let duration: Double
        public let itemID: UUID
        public let isReady: Bool
        public let isSeeking: Bool

        public init(seriesID: String, episodeID: String, position: Double, duration: Double,
                    itemID: UUID, isReady: Bool, isSeeking: Bool) {
            self.seriesID = seriesID; self.episodeID = episodeID
            self.position = position; self.duration = duration; self.itemID = itemID
            self.isReady = isReady; self.isSeeking = isSeeking
        }
    }

    public enum Status: Sendable, Equatable { case available, claimed, disposed }
    public enum RejectionReason: Sendable, Equatable {
        case invalidInput, requestChanged, scopeChanged, revisionChanged, qualityChanged
        case itemChanged, episodeChanged, positionChanged, notReady, seeking, inactiveScene, expired, cancelled
    }

    public private(set) var status: Status
    public private(set) var rejectionReason: RejectionReason?
    private let requestID: UUID
    private let context: Context
    private let snapshot: PreviewPlaybackSnapshot
    private let itemID: UUID
    private let createdAt: Double
    private let timeToLive: Double

    /// `createdAt` and `now` must share the same process-local monotonic clock.
    /// A requested lifetime longer than the bounded maximum is capped at 60 seconds.
    public init(requestID: UUID, context: Context, snapshot: PreviewPlaybackSnapshot, itemID: UUID,
                createdAt: Double, timeToLive: Double = Self.maximumAge) {
        self.requestID = requestID; self.context = context; self.snapshot = snapshot; self.itemID = itemID
        self.createdAt = createdAt
        self.timeToLive = timeToLive.isFinite ? min(timeToLive, Self.maximumAge) : 0
        let valid = Self.valid(context: context) && !snapshot.seriesID.isEmpty && !snapshot.episodeID.isEmpty
            && Self.valid(position: snapshot.position, duration: snapshot.duration)
            && createdAt.isFinite && createdAt >= 0 && timeToLive.isFinite && timeToLive > 0
        status = valid ? .available : .disposed
        rejectionReason = valid ? nil : .invalidInput
    }

    /// A failed attempt disposes this claim too. Callers fall back to a new player instead of
    /// reviving a token after a source/scope/route change. This method never seeks or writes history.
    public mutating func claim(requestID: UUID, context: Context, seriesID: String, episodeID: String,
                               position: Double, playback: Playback, isSceneActive: Bool, now: Double) -> Bool {
        guard status == .available else { return false }
        guard isSceneActive else { return reject(.inactiveScene) }
        guard self.requestID == requestID else { return reject(.requestChanged) }
        guard self.context.scope == context.scope else { return reject(.scopeChanged) }
        guard self.context.revision == context.revision else { return reject(.revisionChanged) }
        guard self.context.quality == context.quality else { return reject(.qualityChanged) }
        guard now.isFinite, now >= createdAt else { return reject(.invalidInput) }
        guard now - createdAt < timeToLive else { return reject(.expired) }
        guard itemID == playback.itemID else { return reject(.itemChanged) }
        guard seriesID == snapshot.seriesID, episodeID == snapshot.episodeID,
              playback.seriesID == snapshot.seriesID, playback.episodeID == snapshot.episodeID else {
            return reject(.episodeChanged)
        }
        guard position.isFinite, position >= 0, position <= playback.duration,
              Self.valid(position: playback.position, duration: playback.duration) else { return reject(.invalidInput) }
        guard playback.isReady else { return reject(.notReady) }
        guard !playback.isSeeking else { return reject(.seeking) }
        guard abs(position - snapshot.position) <= Self.positionTolerance,
              abs(playback.position - snapshot.position) <= Self.positionTolerance,
              abs(position - playback.position) <= Self.positionTolerance else { return reject(.positionChanged) }
        status = .claimed
        return true
    }

    /// Cancelling an unclaimed token is terminal. A completed ownership transfer cannot be undone.
    public mutating func cancel() {
        guard status == .available else { return }
        status = .disposed; rejectionReason = .cancelled
    }

    private mutating func reject(_ reason: RejectionReason) -> Bool {
        status = .disposed; rejectionReason = reason
        return false
    }

    private static func valid(position: Double, duration: Double) -> Bool {
        position.isFinite && position >= 0 && duration.isFinite && duration > 0 && position <= duration
    }

    private static func valid(context: Context) -> Bool {
        guard !context.scope.sourceID.isEmpty else { return false }
        if case .account(let id) = context.scope.owner { return !id.isEmpty }
        return true
    }
}
