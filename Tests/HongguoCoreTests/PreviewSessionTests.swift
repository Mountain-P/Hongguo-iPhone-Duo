import Foundation
import Testing
@testable import HongguoCore

private final class SessionClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 10_000)
    func now() -> Date { lock.withLock { date } }
    func advance(_ seconds: Double) { lock.withLock { date += seconds } }
}

struct PreviewSessionTests {
    private let scope = LibraryScope(owner: .guest, sourceID: "fixture-source")
    private let key = "synthetic.preview-session"
    private func cards(_ ids: [String]) -> [Series] {
        ids.map { .init(id: $0, title: "劇\($0)", cover: "https://example.invalid/poster", description: "SYNTHETIC_PRIVATE_DESCRIPTION", badge: "3 集", tags: ["都市"]) }
    }
    private func fixture() throws -> (String, UserDefaults) {
        let name = "Hongguo.PreviewSessionTests.\(UUID().uuidString)"
        return (name, try #require(UserDefaults(suiteName: name)))
    }

    @Test func aNewStoreRestoresOnlyBoundedMetadataAndPositionWithoutTouchingFormalHistory() async throws {
        let (name, defaults) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let formal = Data("unchanged formal history".utf8)
        defaults.set(formal, forKey: "library.v1.fixture")
        let account = LibraryScope(owner: .account(id: "123456789123456789"), sourceID: "private-source-marker")
        let store = PreviewSessionStore(defaults: defaults, storageKey: key)
        try await store.save(scope: account, category: .realDrama, items: cards(["10", "20", "30"]), currentStableID: "20",
                             snapshot: .init(seriesID: "20", episodeID: "201", position: 35, duration: 90))
        let recreated = PreviewSessionStore(defaults: defaults, storageKey: key)
        let restored = try #require(try await recreated.load(scope: account, category: .realDrama, preferences: .init()))
        #expect(restored.currentStableID == "20" && restored.snapshot?.position == 35)
        #expect(restored.items.map(\.id) == ["10", "20", "30"])
        #expect(restored.items.allSatisfy { $0.cover.isEmpty && $0.description.isEmpty })
        let raw = String(decoding: try #require(defaults.data(forKey: key)), as: UTF8.self)
        #expect(!raw.contains("https://") && !raw.contains("SYNTHETIC_PRIVATE_DESCRIPTION"))
        #expect(!raw.contains("123456789123456789") && !raw.contains("private-source-marker"))
        #expect(defaults.data(forKey: "library.v1.fixture") == formal)
    }

    @Test func guestAccountsSourcesAndCategoriesNeverShareSessions() async throws {
        let (name, defaults) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let store = PreviewSessionStore(defaults: defaults, storageKey: key)
        try await store.save(scope: scope, category: .realDrama, items: cards(["10"]), currentStableID: "10", snapshot: nil)
        for other in [LibraryScope(owner: .account(id: "42"), sourceID: scope.sourceID),
                      LibraryScope(owner: .account(id: "43"), sourceID: scope.sourceID),
                      LibraryScope(owner: .guest, sourceID: "other-source")] {
            #expect(try await store.load(scope: other, category: .realDrama, preferences: .init()) == nil)
        }
        #expect(try await store.load(scope: scope, category: .comicDrama, preferences: .init(category: .comicDrama)) == nil)
        #expect(try await store.load(scope: scope, category: .realDrama, preferences: .init(category: .aiDrama)) == nil)
    }

    @Test func sessionsExpireAtTwentyFourHoursAndCorruptOversizedOrUnknownDataAreIgnored() async throws {
        let (name, defaults) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let clock = SessionClock(), store = PreviewSessionStore(defaults: defaults, storageKey: key, now: { clock.now() })
        try await store.save(scope: scope, category: .realDrama, items: cards(["10"]), currentStableID: "10", snapshot: nil)
        clock.advance(PreviewSessionStore.timeToLive - 1)
        #expect(try await store.load(scope: scope, category: .realDrama, preferences: .init()) != nil)
        clock.advance(1)
        #expect(try await store.load(scope: scope, category: .realDrama, preferences: .init()) == nil)
        for bad in [Data("broken JSON".utf8), Data(repeating: 0x61, count: PreviewSessionStore.maximumBytes + 1), Data(#"{"version":2,"sessions":[]}"#.utf8)] {
            defaults.set(bad, forKey: key)
            #expect(try await store.load(scope: scope, category: .realDrama, preferences: .init()) == nil)
            #expect(defaults.data(forKey: key) == bad)
        }
    }

    @Test func boundsKeepTheCurrentCardAndEvictOldScopesWithoutGrowingTheBlob() async throws {
        let (name, defaults) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let clock = SessionClock(), store = PreviewSessionStore(defaults: defaults, storageKey: key, now: { clock.now() })
        let rows = cards((1...100).map(String.init))
        for index in 0...PreviewSessionStore.maximumSessions {
            clock.advance(1)
            try await store.save(scope: .init(owner: .guest, sourceID: "source-\(index)"), category: .realDrama,
                                 items: rows, currentStableID: "80", snapshot: nil)
        }
        let oldest = LibraryScope(owner: .guest, sourceID: "source-0")
        #expect(try await store.load(scope: oldest, category: .realDrama, preferences: .init()) == nil)
        let latest = LibraryScope(owner: .guest, sourceID: "source-\(PreviewSessionStore.maximumSessions)")
        let restored = try #require(try await store.load(scope: latest, category: .realDrama, preferences: .init()))
        #expect(restored.items.count == PreviewSessionStore.maximumItems && restored.currentStableID == "80")
        #expect(restored.items.contains { $0.id == "80" })
        #expect(try #require(defaults.data(forKey: key)).count <= PreviewSessionStore.maximumBytes)
    }

    @Test func exclusionsChooseTheNextAllowedCardAndDropTheOldCardsPosition() async throws {
        let (name, defaults) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let store = PreviewSessionStore(defaults: defaults, storageKey: key)
        try await store.save(scope: scope, category: .realDrama, items: cards(["10", "20", "30"]), currentStableID: "20",
                             snapshot: .init(seriesID: "20", episodeID: "201", position: 35, duration: 90))
        var prefs = RecommendationPreferences()
        try prefs.setNotInterested(seriesID: "20", value: true)
        let restored = try #require(try await store.load(scope: scope, category: .realDrama, preferences: prefs))
        #expect(restored.currentStableID == "30" && restored.snapshot == nil)
        #expect(restored.items.map(\.id) == ["10", "30"])
        try prefs.setNotInterested(seriesID: "10", value: true)
        try prefs.setNotInterested(seriesID: "30", value: true)
        #expect(try await store.load(scope: scope, category: .realDrama, preferences: prefs) == nil)
    }

    @Test func resumeRequiresTheLatestAvailableFirstEpisodeAndCompletedPreviewsRestart() {
        let snapshot = PreviewPlaybackSnapshot(seriesID: "20", episodeID: "201", position: 35, duration: 90)
        let session = PreviewSession(items: cards(["20"]), currentStableID: "20", snapshot: snapshot)
        let valid = SeriesDetail(series: .init(id: "20", title: "Fresh"), episodes: [.init(id: "201", number: 1, title: "1")])
        #expect(session.resumeSeconds(in: valid) == 35)
        let invalid = [
            SeriesDetail(series: .init(id: "99", title: "Other"), episodes: valid.episodes),
            SeriesDetail(series: valid.series, episodes: [.init(id: "202", number: 1, title: "New first")]),
            SeriesDetail(series: valid.series, episodes: [.init(id: "201", number: 2, title: "2")]),
            SeriesDetail(series: valid.series, episodes: [.init(id: "201", number: 1, title: "1", isAvailable: false)])
        ]
        for detail in invalid { #expect(session.resumeSeconds(in: detail) == 0) }
        let completed = PreviewSession(items: session.items, currentStableID: "20",
                                      snapshot: .init(seriesID: "20", episodeID: "201", position: 89, duration: 90))
        #expect(completed.resumeSeconds(in: valid) == 0)
    }

    @Test func invalidPositionsAreDiscardedAndInvalidWritesPreserveThePreviousCache() async throws {
        let (name, defaults) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let store = PreviewSessionStore(defaults: defaults, storageKey: key)
        for snapshot in [PreviewPlaybackSnapshot(seriesID: "20", episodeID: "201", position: .nan, duration: 90),
                         .init(seriesID: "20", episodeID: "201", position: 10, duration: 0),
                         .init(seriesID: "99", episodeID: "201", position: 10, duration: 90),
                         .init(seriesID: "20", episodeID: "bad-id", position: 10, duration: 90)] {
            try await store.save(scope: scope, category: .realDrama, items: cards(["20"]), currentStableID: "20", snapshot: snapshot)
            #expect(try await store.load(scope: scope, category: .realDrama, preferences: .init())?.snapshot == nil)
        }
        let original = defaults.data(forKey: key)
        await #expect(throws: PreviewSessionError.self) {
            try await store.save(scope: scope, category: .realDrama, items: cards(["20"]), currentStableID: "99", snapshot: nil)
        }
        await #expect(throws: PreviewSessionError.self) {
            try await store.save(scope: .init(owner: .guest, sourceID: ""), category: .realDrama,
                                 items: cards(["20"]), currentStableID: "20", snapshot: nil)
        }
        #expect(defaults.data(forKey: key) == original)
    }

    @Test func malformedStoredMetadataCannotBeReencodedIntoAnotherScopesSession() async throws {
        let (name, defaults) = try fixture(); defer { defaults.removePersistentDomain(forName: name) }
        let store = PreviewSessionStore(defaults: defaults, storageKey: key)
        try await store.save(scope: scope, category: .realDrama, items: cards(["20"]), currentStableID: "20", snapshot: nil)
        let data = try #require(defaults.data(forKey: key))
        var root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var sessions = try #require(root["sessions"] as? [[String: Any]])
        var items = try #require(sessions[0]["items"] as? [[String: Any]])
        items[0]["title"] = "https://example.invalid/untrusted"
        sessions[0]["items"] = items; root["sessions"] = sessions
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: key)
        #expect(try await store.load(scope: scope, category: .realDrama, preferences: .init()) == nil)
        try await store.save(scope: .init(owner: .guest, sourceID: "clean-source"), category: .realDrama,
                             items: cards(["30"]), currentStableID: "30", snapshot: nil)
        let clean = String(decoding: try #require(defaults.data(forKey: key)), as: UTF8.self)
        #expect(!clean.contains("https://") && !clean.contains("untrusted"))
    }

    @Test func restoringALocalPrefixKeepsCurrentAndStillRequestsTheRealFirstPage() throws {
        var queue = RecommendationPreviewQueue()
        #expect(try queue.restoreLocalPrefix(items: cards(["10", "20"]), currentStableID: "20"))
        #expect(queue.current?.id == "20" && queue.page == 0 && queue.hasMore)
        let pending = queue.beginPageRequest()
        let request = try #require(pending)
        #expect(request.page == 1)
        #expect(try queue.receive(.init(items: cards(["20", "30"]), page: 1, hasMore: false), for: request))
        #expect(queue.items.map(\.id) == ["10", "20", "30"] && queue.current?.id == "20" && queue.page == 1)
        #expect(!queue.hasMore)
    }

    @Test func localPrefixRejectsInvalidMetadataAndCannotOverwriteAnActiveSourceCursor() throws {
        var queue = RecommendationPreviewQueue()
        #expect(throws: CatalogError.self) { try queue.restoreLocalPrefix(items: cards(["bad-id"]), currentStableID: "bad-id") }
        #expect(queue.items.isEmpty && queue.page == 0)
        let pending = queue.beginPageRequest()
        let request = try #require(pending)
        #expect(throws: CatalogError.self) { try queue.restoreLocalPrefix(items: cards(["10"]), currentStableID: "10") }
        #expect(try queue.receive(.init(items: cards(["20"]), page: 1, hasMore: false), for: request))
        #expect(queue.items.map(\.id) == ["20"] && queue.page == 1)
    }
}
