// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// A single settled card owns playback. No player or network work runs in this policy.
public struct RecommendationFeedActivation: Sendable {
    public struct Lease: Hashable, Sendable {
        public let seriesID: String
        public let token: UUID
    }

    public private(set) var lease: Lease?

    public init() {}

    /// Scrolling, leaving the tab, backgrounding, or presenting detail revokes old work.
    /// Returning to the same card starts a distinct activation so late replies stay stale.
    @discardableResult
    public mutating func update(selectedID: String?, isIdle: Bool, isActive: Bool,
                                isSceneActive: Bool, isDetailPresented: Bool) -> Lease? {
        guard let selectedID, !selectedID.isEmpty, isIdle, isActive,
              isSceneActive, !isDetailPresented else {
            invalidate()
            return nil
        }
        if lease?.seriesID != selectedID {
            lease = Lease(seriesID: selectedID, token: UUID())
        }
        return lease
    }

    public func accepts(_ candidate: Lease) -> Bool { lease == candidate }

    /// A source replacement must invalidate even when the new source has the same ID.
    public mutating func invalidate() { lease = nil }
}
