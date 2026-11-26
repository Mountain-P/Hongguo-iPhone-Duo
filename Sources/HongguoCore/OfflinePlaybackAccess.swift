// SPDX-License-Identifier: GPL-3.0-only
import CryptoKit
import Foundation

/// A playback session captures its library owner once. A matching completed
/// download can be read before either the catalogue or the media service is reachable.
public struct OfflinePlaybackAccess: Sendable {
    public let scope: String
    private let storage: @Sendable () async -> OfflineDownloads?

    public init(scope: String, storage: @escaping @Sendable () async -> OfflineDownloads?) {
        self.scope = scope
        self.storage = storage
    }

    public static func scope(for owner: LibraryOwner) -> String {
        switch owner {
        case .guest: return "native.public.v1"
        case .account(let id):
            let digest = SHA256.hash(data: Data(id.utf8)).map { String(format: "%02x", $0) }.joined()
            return "native.account.v1." + digest
        }
    }

    public func source(seriesID: String, episodeID: String) async -> PlaybackSource? {
        guard scope != OfflineDownloads.importedScope, let library = await storage(),
              let file = try? await library.localURL(for: .init(scope: scope, seriesID: seriesID, episodeID: episodeID)) else { return nil }
        return .init(url: file)
    }

    public func detail(for record: WatchRecord) async -> SeriesDetail? {
        guard let library = await storage() else { return nil }
        return await library.savedDetail(scope: scope, seriesID: record.series.id, continuing: record)
    }

    public func fallbackDetail(seriesID: String, continuing record: WatchRecord? = nil) async -> SeriesDetail? {
        guard let library = await storage() else { return nil }
        return await library.savedDetail(scope: scope, seriesID: seriesID, continuing: record, allowPartial: true)
    }
}
