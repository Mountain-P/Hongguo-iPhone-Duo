import Foundation
import Testing
@testable import HongguoCore

/// Optional check against freshly fetched pages. Snapshots stay outside the repository
/// because upstream cover and media URLs can contain expiring signatures.
@Suite
struct LiveSnapshotTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HONGGUO_LIVE_FIXTURES"] != nil))
    func currentWebsiteSnapshot() throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HONGGUO_LIVE_FIXTURES"]!)
        func html(_ file: String) throws -> String { try String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8) }
        let category = try WebsiteParser.catalog(html: html("category.html"))
        #expect(category.items.count == 24)
        #expect(category.hasMore)
        let detail = try WebsiteParser.detail(html: html("detail.html"), seriesID: "7701935931787316286")
        #expect(detail.episodes.count == 102)
        #expect(detail.episodes.filter(\.isAvailable).count == 3)
        let search = try WebsiteParser.search(data: Data(contentsOf: directory.appendingPathComponent("search.json")))
        #expect(search.items.count > 0)
        #expect(throws: CatalogError.protectedPlayback) {
            try WebsiteParser.playback(html: html("player.html"), seriesID: "7701935931787316286", episodeID: "7701937936731737112")
        }
    }
}
