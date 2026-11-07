import Foundation
import Testing
@testable import HongguoCore

struct RecommendationTopicPreferencesTests {
    private let key = "synthetic.topics"
    private let guest = LibraryScope(owner: .guest, sourceID: "source-a")

    private func fixture() throws -> (name: String, defaults: UserDefaults, store: RecommendationTopicPreferencesStore) {
        let name = "Hongguo.TopicPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (name, defaults, RecommendationTopicPreferencesStore(defaults: defaults, storageKey: key,
            now: { Date(timeIntervalSince1970: 10_000) }))
    }
    private func preferences(_ tag: String, _ value: RecommendationTopicPreferences.Preference) throws -> RecommendationTopicPreferences {
        var result = RecommendationTopicPreferences(); try result.set(tag: tag, preference: value); return result
    }

    @Test func normalizationSharesTraditionalSimplifiedCompatibilityAndCaseKeys() throws {
        let traditional = try #require(RecommendationTopicTag.normalized(" 甜寵 "))
        let simplified = try #require(RecommendationTopicTag.normalized("甜宠"))
        #expect(traditional.key == simplified.key && traditional.title == "甜寵")
        let wide = try #require(RecommendationTopicTag.normalized("ＲＯＭＡＮＣＥ"))
        let plain = try #require(RecommendationTopicTag.normalized("romance"))
        #expect(wide.title == "ROMANCE" && wide.key == plain.key)
        #expect(RecommendationTopicTag.normalized("都市  愛情")?.key == RecommendationTopicTag.normalized("都市　爱情")?.key)
    }

    @Test func genericMalformedAndURLTagsCannotBecomeExplicitTopics() {
        for tag in ["", " \n ", "剧情", "短劇", "全部", "ＡＩ", "高清", "真人短劇", "都\n市", "都\0市",
                    "https://unit.invalid", "file:/fixture", "data:fixture", String(repeating: "題", count: 41), String(repeating: "㍿", count: 11)] {
            #expect(RecommendationTopicTag.normalized(tag) == nil)
        }
        #expect(RecommendationTopicTag.normalized(String(repeating: "題", count: 40)) != nil)
    }

    @Test func moreLessAndNeutralOperateOnOneNormalizedEntryAndClearRemovesOnlyTopics() throws {
        var value = RecommendationTopicPreferences()
        try value.set(tag: "甜寵", preference: .more)
        #expect(value.preference(for: "甜宠") == .more)
        try value.set(tag: "甜宠", preference: .less)
        #expect(value.entries.count == 1 && value.preference(for: "甜寵") == .less)
        try value.set(tag: "都市", preference: .more)
        try value.set(tag: "甜寵", preference: .neutral)
        #expect(value.entries.map(\.title) == ["都市"] && value.preference(for: "甜宠") == .neutral)
        value.clear()
        #expect(value.isEmpty && value.preference(for: "都市") == .neutral)
    }

    @Test func theThirtyTwoEntryLimitRejectsNewTopicsAtomicallyButAllowsUpdatesAndRemoval() throws {
        var value = RecommendationTopicPreferences()
        for index in 0..<RecommendationTopicPreferences.maximumEntries { try value.set(tag: "題材\(index)", preference: .more) }
        let before = value
        #expect(throws: RecommendationTopicPreferenceError.self) { try value.set(tag: "新題材", preference: .less) }
        #expect(value == before)
        try value.set(tag: "題材0", preference: .less)
        #expect(value.entries.count == 32 && value.preference(for: "題材0") == .less)
        try value.set(tag: "題材1", preference: .neutral)
        try value.set(tag: "新題材", preference: .more)
        #expect(value.entries.count == 32 && value.preference(for: "新題材") == .more)
    }

    @Test func codableRoundTripCanonicalizesAliasesAndNeutralSuppressesOlderDuplicates() throws {
        let value = try preferences("甜寵", .less)
        #expect(try JSONDecoder().decode(RecommendationTopicPreferences.self, from: JSONEncoder().encode(value)) == value)
        let raw = Data(#"{"entries":[{"title":"甜寵","preference":"neutral"},{"title":"甜宠","preference":"more"},{"title":"都市","preference":"less"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(RecommendationTopicPreferences.self, from: raw)
        #expect(decoded.entries.count == 1 && decoded.preference(for: "甜寵") == .neutral)
        #expect(decoded.preference(for: "都市") == .less)
        for invalid in [#"{"entries":[{"title":"都市","preference":"unknown"}]}"#,
                        #"{"entries":[{"title":"全部","preference":"more"}]}"#] {
            #expect(throws: (any Error).self) { try JSONDecoder().decode(RecommendationTopicPreferences.self, from: Data(invalid.utf8)) }
        }
        let oversized = try JSONSerialization.data(withJSONObject: ["entries": (0...32).map { ["title": "題材\($0)", "preference": "more"] }])
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RecommendationTopicPreferences.self, from: oversized) }
    }

    @Test func ownerSourceAndCategoryAreIsolatedAcrossARecreatedStore() async throws {
        let f = try fixture(); defer { f.defaults.removePersistentDomain(forName: f.name) }
        let more = try preferences("都市", .more), less = try preferences("都市", .less)
        let account = LibraryScope(owner: .account(id: "42"), sourceID: guest.sourceID)
        try await f.store.save(more, scope: guest, category: .realDrama)
        try await f.store.save(less, scope: account, category: .realDrama)
        try await f.store.save(less, scope: guest, category: .aiDrama)
        let recreated = RecommendationTopicPreferencesStore(defaults: f.defaults, storageKey: key)
        #expect(try await recreated.load(scope: guest, category: .realDrama) == more)
        #expect(try await recreated.load(scope: account, category: .realDrama) == less)
        #expect(try await recreated.load(scope: guest, category: .aiDrama) == less)
        #expect(try await recreated.load(scope: guest, category: .comicDrama).isEmpty)
        #expect(try await recreated.load(scope: .init(owner: .account(id: "43"), sourceID: guest.sourceID), category: .realDrama).isEmpty)
        #expect(try await recreated.load(scope: .init(owner: .guest, sourceID: "source-b"), category: .realDrama).isEmpty)
    }

    @Test func scopedClearPreservesOtherScopesAndFormalLibraryAndStoresNoRawScopeOrURL() async throws {
        let f = try fixture(); defer { f.defaults.removePersistentDomain(forName: f.name) }
        let formal = Data("synthetic formal library".utf8)
        f.defaults.set(formal, forKey: "library.v1.synthetic")
        let privateScope = LibraryScope(owner: .account(id: "123456789123456789"), sourceID: "https://unit.invalid/private-source")
        let more = try preferences("都市", .more)
        try await f.store.save(more, scope: guest, category: .realDrama)
        try await f.store.save(more, scope: privateScope, category: .realDrama)
        let data = try #require(f.defaults.data(forKey: key)), text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("https://") && !text.contains("private-source") && !text.contains("123456789123456789"))
        try await f.store.clear(scope: guest, category: .realDrama)
        #expect(try await f.store.load(scope: guest, category: .realDrama).isEmpty)
        #expect(try await f.store.load(scope: privateScope, category: .realDrama) == more)
        #expect(f.defaults.data(forKey: "library.v1.synthetic") == formal)
        try await f.store.clear(scope: privateScope, category: .realDrama)
        #expect(f.defaults.data(forKey: key) == nil)
    }

    @Test func scopeAndEncodedSizeLimitsBoundTheStoreAndKeepTheLatestExplicitScope() async throws {
        let f = try fixture(); defer { f.defaults.removePersistentDomain(forName: f.name) }
        var value = RecommendationTopicPreferences()
        for index in 0..<32 { try value.set(tag: String(repeating: "題", count: 35) + String(index), preference: .more) }
        for index in 0...RecommendationTopicPreferencesStore.maximumScopes {
            try await f.store.save(value, scope: .init(owner: .guest, sourceID: "scope-\(index)"), category: .realDrama)
        }
        #expect(try await f.store.load(scope: .init(owner: .guest, sourceID: "scope-0"), category: .realDrama).isEmpty)
        #expect(try await f.store.load(scope: .init(owner: .guest, sourceID: "scope-8"), category: .realDrama) == value)
        let data = try #require(f.defaults.data(forKey: key))
        #expect(data.count <= RecommendationTopicPreferencesStore.maximumBytes)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["scopes"] as? [Any])?.count == RecommendationTopicPreferencesStore.maximumScopes)
    }

    @Test func corruptOversizedOrUnsupportedDataReadAsEmptyWithoutMutatingStoredBytes() async throws {
        let f = try fixture(); defer { f.defaults.removePersistentDomain(forName: f.name) }
        for bytes in [Data("broken".utf8), Data(repeating: 0x61, count: RecommendationTopicPreferencesStore.maximumBytes + 1),
                      Data(#"{"version":2,"scopes":[]}"#.utf8),
                      Data(#"{"version":1,"scopes":[{"key":"bad","updated":0,"preferences":{"entries":[{"title":"都市","preference":"unknown"}]}}]}"#.utf8)] {
            f.defaults.set(bytes, forKey: key)
            #expect(try await f.store.load(scope: guest, category: .realDrama).isEmpty)
            #expect(f.defaults.data(forKey: key) == bytes)
        }
    }

    @Test func invalidScopesPreserveTheOldDataAndConcurrentDifferentScopeWritesDoNotLoseEachOther() async throws {
        let f = try fixture(); defer { f.defaults.removePersistentDomain(forName: f.name) }
        let more = try preferences("都市", .more), less = try preferences("甜寵", .less)
        let store = f.store
        async let first: Void = store.save(more, scope: guest, category: .realDrama)
        async let second: Void = store.save(less, scope: .init(owner: .guest, sourceID: "other"), category: .realDrama)
        _ = try await (first, second)
        #expect(try await f.store.load(scope: guest, category: .realDrama) == more)
        #expect(try await f.store.load(scope: .init(owner: .guest, sourceID: "other"), category: .realDrama) == less)
        let original = f.defaults.data(forKey: key)
        for invalid in [LibraryScope(owner: .guest, sourceID: ""), .init(owner: .account(id: ""), sourceID: "source"),
                        .init(owner: .guest, sourceID: "with\ncontrol"), .init(owner: .guest, sourceID: String(repeating: "a", count: 513))] {
            await #expect(throws: RecommendationTopicPreferenceError.self) { try await f.store.save(more, scope: invalid, category: .realDrama) }
        }
        #expect(f.defaults.data(forKey: key) == original)
    }
}
