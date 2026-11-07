import Foundation
import Testing
@testable import HongguoCore

struct PersonalizedRecommendationTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let scope = LibraryScope(owner: .guest, sourceID: "public-catalogue")

    @Test func emptyProfileFallsBackToSourceOrderAndDeduplicatesValidMetadata() {
        let items = [series("20"), series("10"), series("20", title: "另一快照"),
                     series("bad"), series("0"), series("30", title: " "), series("40", title: "bad\u{0000}title")]
        let result = rank(items)
        #expect(result.map(\.series.id) == ["20", "10"])
        #expect(result.allSatisfy { $0.reason == nil })
    }

    @Test func favoriteIsStrongerThanAnIndividualSufficientHistorySignal() {
        let favorite = series("1", title: "收藏的劇", tags: ["懸疑"])
        let watched = record(series("2", title: "最近看的劇", tags: ["甜寵"]))
        let profile = profile(favorites: [favorite], history: [watched])
        let items = [series("10", tags: ["甜寵"]), series("20", tags: ["懸疑"]), series("30", tags: ["校園"])]
        let result = rank(items, profile)
        #expect(result.map(\.series.id) == ["20", "10", "30"])
        #expect(result[0].reason?.kind == .favorite)
        #expect(result[0].reason?.sourceSeriesID == "1")
        #expect(result[0].reason?.tag == "懸疑")
        #expect(result[0].reason?.displayText == "因你收藏《收藏的劇》· 懸疑")
        #expect(result[1].reason?.kind == .recentlyWatched)
        #expect(result[1].reason?.displayText == "你最近看的《最近看的劇》也有「甜寵」")
    }

    @Test func historyRequiresReliableDurationThirtySecondsAndHalfAnEpisode() {
        let watched = series("1", tags: ["懸疑"])
        for pair: (Double, Double) in [(29, 40), (30, 100), (0, 0), (80, 60), (.nan, 60), (40, .infinity)] {
            let value = record(watched, seconds: pair.0, duration: pair.1)
            #expect(!PersonalizedRecommendationProfile.hasSufficientPosition(value))
            #expect(!profile(history: [value]).hasSignals)
        }
        let threshold = record(watched, seconds: 30, duration: 60)
        #expect(PersonalizedRecommendationProfile.hasSufficientPosition(threshold))
        #expect(profile(history: [threshold]).hasSignals)
    }

    @Test func genericTagsAndTitlesNeverBecomeInferredInterests() {
        let favorite = series("1", title: "霸總重生甜寵", tags: ["劇情", "短劇", "真人", "完結", "AI"])
        let value = profile(favorites: [favorite])
        #expect(value.isEmpty)
        let items = [series("10", tags: ["校園"]), series("20", tags: ["霸總", "甜寵"])]
        #expect(rank(items, value).map(\.series.id) == ["10", "20"])
        #expect(rank(items, value).allSatisfy { $0.reason == nil })
    }

    @Test func simplifiedTraditionalAndWidthVariantsShareOnlyRealTags() {
        let value = profile(favorites: [series("1", tags: ["懸疑", " 懸疑 ", "ＡＩ", "劇情"])])
        #expect(value.tagCount == 1)
        let result = rank([series("10", tags: ["校园"]), series("20", tags: ["悬疑"])], value)
        #expect(result.first?.series.id == "20")
        #expect(result.first?.reason?.tag == "悬疑")
    }

    @Test func ownerAndSourceMismatchCannotReuseAnotherLibrarysInterests() {
        let accountA = LibraryScope(owner: .account(id: "account-a"), sourceID: scope.sourceID)
        let accountB = LibraryScope(owner: .account(id: "account-b"), sourceID: scope.sourceID)
        let value = PersonalizedRecommendationProfile(scope: accountA, favorites: [series("1", tags: ["懸疑"])], history: [], now: now)
        let items = [series("10", tags: ["校園"]), series("20", tags: ["懸疑"])]
        for other in [scope, accountB, LibraryScope(owner: accountA.owner, sourceID: "another-source")] {
            let result = PersonalizedRecommendation.rank(items, using: value, scope: other)
            #expect(result.map(\.series.id) == ["10", "20"])
            #expect(result.allSatisfy { $0.reason == nil })
        }
        #expect(PersonalizedRecommendation.rank(items, using: value, scope: accountA).first?.series.id == "20")
    }

    @Test func progressTicksDoNotChangeTheSemanticProfile() {
        let watched = series("1", tags: ["懸疑"])
        let earlier = record(watched, seconds: 35, duration: 60)
        var later = earlier
        later.seconds = 36; later.updatedAt = now.addingTimeInterval(1)
        #expect(profile(history: [earlier]) == profile(history: [later], clock: now.addingTimeInterval(1)))
        later.seconds = 20
        #expect(profile(history: [earlier]) != profile(history: [later], clock: now.addingTimeInterval(1)))
    }

    @Test func duplicateSignalsDoNotAmplifyAndLatestHistoryRecordWins() {
        let work = series("1", tags: ["懸疑", "悬疑"])
        let single = profile(favorites: [work])
        #expect(single == profile(favorites: [work, work], history: [record(work)]))
        let old = record(work)
        let new = record(work, seconds: 5, duration: 60, date: now.addingTimeInterval(1))
        #expect(profile(history: [old, new], clock: now.addingTimeInterval(1)).isEmpty)
        #expect(profile(history: [new, old], clock: now.addingTimeInterval(1)).isEmpty)
    }

    @Test func staleFutureAndMalformedHistoryDoNotSupplyReasons() {
        let work = series("1", tags: ["懸疑"])
        let old = record(work, date: now.addingTimeInterval(-PersonalizedRecommendationProfile.historyLifetime - 1))
        let future = record(series("2", tags: ["甜寵"]), date: now.addingTimeInterval(301))
        var invalidEpisode = record(series("3", tags: ["校園"]))
        invalidEpisode.episode.id = "bad"
        var invalidDate = record(series("4", tags: ["穿越"]))
        invalidDate.updatedAt = Date(timeIntervalSince1970: .nan)
        #expect(profile(history: [old, future, invalidEpisode, invalidDate]).isEmpty)
    }

    @Test func theSameWorkDoesNotInventASelfRecommendation() {
        let favorite = series("1", tags: ["懸疑"])
        let result = rank([series("10", tags: ["校園"]), favorite], profile(favorites: [favorite]))
        #expect(result.map(\.series.id) == ["10", "1"])
        #expect(result.allSatisfy { $0.reason == nil })
    }

    @Test func everyFourthSlotKeepsAnUnmatchedSourceCandidateForExploration() {
        let value = profile(favorites: [series("1", tags: ["懸疑"])])
        let items = [series("10", tags: ["校園"])] + (20...27).map { series(String($0), tags: ["懸疑"]) }
            + [series("40", tags: ["穿越"])]
        let result = rank(items, value)
        #expect(result[3].series.id == "10")
        #expect(result[7].series.id == "40")
        #expect(result[3].reason == nil && result[7].reason == nil)
        #expect(Set(result.map(\.series.id)) == Set(items.map(\.id)))
    }

    @Test func sharedTopicsInterleaveAfterTwoWhileTiesRemainStable() {
        let value = profile(favorites: [series("1", tags: ["懸疑"]), series("2", tags: ["甜寵"])])
        let items = [series("10", tags: ["懸疑"]), series("20", tags: ["懸疑"]), series("30", tags: ["懸疑"]),
                     series("40", tags: ["甜寵"]), series("50", tags: ["校園"])]
        let result = rank(items, value)
        #expect(result.map(\.series.id) == ["10", "20", "40", "50", "30"])
        #expect(result == rank(items, value))
    }

    @Test func noMatchingCandidateKeepsTheCompleteSourceOrder() {
        let items = [series("30", tags: ["校園"]), series("20"), series("10", tags: ["穿越"])]
        let result = rank(items, profile(favorites: [series("1", tags: ["懸疑"])]))
        #expect(result.map(\.series.id) == items.map(\.id))
        #expect(result.allSatisfy { $0.reason == nil })
    }

    @Test func profilesCandidatesAndEvidenceHaveExplicitBounds() {
        let favorites = (1...500).map { id in
            series(String(id), tags: (1...20).map { "題材\(id)-\($0)" })
        }
        let value = profile(favorites: favorites)
        #expect(value.tagCount == PersonalizedRecommendationProfile.maximumTags)
        #expect(value.signalCount <= PersonalizedRecommendationProfile.maximumFavorites)
        let repeated = profile(favorites: (1...500).map { series(String($0), tags: ["懸疑"]) })
        #expect(repeated.signalCount == PersonalizedRecommendationProfile.maximumEvidencePerTag)
        let candidates = (1...600).map { series(String($0 + 1000), tags: ["校園"]) }
        #expect(rank(candidates, repeated).count == PersonalizedRecommendation.maximumCandidates)
        let beyond = (1...PersonalizedRecommendationProfile.maximumFavorites).map { series(String($0)) }
            + [series("9999", tags: ["懸疑"])]
        #expect(profile(favorites: beyond).isEmpty)
    }

    @Test func reasonsAlwaysPointToAnotherKnownWorkWithAnActualSharedTag() {
        let favorites = [series("1", tags: ["懸疑", "復仇"]), series("2", tags: ["校園"])]
        let watched = record(series("3", tags: ["甜寵"]))
        let items = [series("1", tags: ["懸疑"]), series("10", tags: ["复仇"]), series("20", tags: ["校園"]),
                     series("30", tags: ["甜寵"]), series("40", title: "懸疑校園復仇", tags: [])]
        let result = rank(items, profile(favorites: favorites, history: [watched]))
        for item in result {
            guard let reason = item.reason else { continue }
            let source = (favorites + [watched.series]).first { $0.id == reason.sourceSeriesID }
            #expect(source != nil)
            #expect(reason.sourceSeriesID != item.series.id)
            #expect(item.series.tags.contains { SearchText.comparisonKey($0) == SearchText.comparisonKey(reason.tag) })
            #expect(source?.tags.contains { SearchText.comparisonKey($0) == SearchText.comparisonKey(reason.tag) } == true)
        }
        #expect(result.first(where: { $0.series.id == "40" })?.reason == nil)
        #expect(result.count == items.count)
    }

    @Test func emptyOrMalformedScopeCannotCreateAnActiveProfile() {
        for invalid in [LibraryScope(owner: .guest, sourceID: " "), LibraryScope(owner: .account(id: ""), sourceID: "source")] {
            let value = PersonalizedRecommendationProfile(scope: invalid, favorites: [series("1", tags: ["懸疑"])], history: [], now: now)
            #expect(value.isEmpty)
        }
    }

    @Test func aNewBatchUsesOnlyTheLastTwoCommittedTopics() {
        let value = profile(favorites: [series("1", tags: ["懸疑"]), series("2", tags: ["甜寵"])])
        let next = [series("30", tags: ["懸疑"]), series("40", tags: ["甜寵"])]
        let tail = [series("5", tags: ["甜寵"]), series("10", tags: ["懸疑"]), series("20", tags: ["悬疑"])]
        let result = PersonalizedRecommendation.rank(next, using: value, scope: scope, recentSeries: tail)
        #expect(result.map(\.series.id) == ["40", "30"])
        #expect(tail.map(\.id) == ["5", "10", "20"])
        #expect(PersonalizedRecommendation.rank(next, using: value, scope: scope, recentSeries: Array(tail.suffix(2))) == result)
    }

    @Test func diversityUsesRealTopicsEvenWithoutLibrarySignalsButNeverInventsAnAlternative() {
        let tail = [series("10", tags: ["懸疑"]), series("20", tags: ["懸疑"])]
        let items = [series("30", tags: ["懸疑"]), series("40", tags: ["校園"]), series("50", tags: ["懸疑"])]
        let result = PersonalizedRecommendation.rank(items, using: profile(), scope: scope, recentSeries: tail)
        #expect(result.map(\.series.id) == ["40", "30", "50"])
        #expect(result.allSatisfy { $0.reason == nil })
        #expect(PersonalizedRecommendation.rank([items[0], items[2]], using: profile(), scope: scope,
                                              recentSeries: tail).map(\.series.id) == ["30", "50"])
    }

    @Test func unknownOrGenericTailMetadataBreaksAConsecutiveTopicRun() {
        let value = profile(favorites: [series("1", tags: ["懸疑"]), series("2", tags: ["校園"])])
        let items = [series("30", tags: ["懸疑"]), series("40", tags: ["校園"])]
        for tail in [[series("10", tags: ["懸疑"]), series("20", tags: ["劇情"])],
                     [series("10", tags: ["懸疑"]), series("bad", tags: ["懸疑"])]] {
            #expect(PersonalizedRecommendation.rank(items, using: value, scope: scope,
                                                   recentSeries: tail).map(\.series.id) == ["30", "40"])
        }
    }

    @Test func negativeOnlyTopicsReduceMatchingCandidatesAndNeutralRestoresSourceOrder() throws {
        var topics = RecommendationTopicPreferences()
        try topics.set(tag: "懸疑", preference: .less)
        let value = PersonalizedRecommendationProfile(scope: scope, favorites: [], history: [], now: now, topicPreferences: topics)
        #expect(value.hasSignals && value.signalCount == 1)
        let items = [series("10", tags: ["悬疑"]), series("20", tags: ["校園"]), series("30", tags: ["懸疑"])]
        #expect(rank(items, value).map(\.series.id) == ["20", "10", "30"])
        #expect(rank(items, value).allSatisfy { $0.reason == nil })
        try topics.set(tag: "悬疑", preference: .neutral)
        let neutral = PersonalizedRecommendationProfile(scope: scope, favorites: [], history: [], now: now, topicPreferences: topics)
        #expect(neutral.isEmpty)
        #expect(rank(items, neutral).map(\.series.id) == ["10", "20", "30"])
    }

    @Test func explicitMoreUsesOnlyActualSharedTagsAndAnHonestReason() throws {
        var topics = RecommendationTopicPreferences()
        try topics.set(tag: "懸疑", preference: .more)
        let value = PersonalizedRecommendationProfile(scope: scope, favorites: [], history: [], now: now, topicPreferences: topics)
        let result = rank([series("10", title: "懸疑劇", tags: ["校園"]), series("20", tags: ["悬疑"])], value)
        #expect(result.map(\.series.id) == ["20", "10"])
        let reason = try #require(result[0].reason)
        #expect(reason.kind == .topicPreference && reason.tag == "悬疑")
        #expect(reason.sourceSeriesID.isEmpty && reason.sourceTitle.isEmpty)
        #expect(reason.displayText == "你選擇多看「悬疑」")
        #expect(result[1].reason == nil)
    }

    @Test func lessIsNotPromotedAsExplorationOrAsTheDiversityAlternative() throws {
        var topics = RecommendationTopicPreferences()
        try topics.set(tag: "甜寵", preference: .less)
        let value = PersonalizedRecommendationProfile(scope: scope, favorites: [series("1", tags: ["懸疑"])],
                                                     history: [], now: now, topicPreferences: topics)
        let items = [series("10", tags: ["甜寵"])] + (20...24).map { series(String($0), tags: ["懸疑"]) }
            + [series("40", tags: ["校園"])]
        let result = rank(items, value)
        #expect(result.last?.series.id == "10")
        #expect(result.firstIndex(where: { $0.series.id == "40" }) == 3)
        #expect(result.filter { $0.series.id != "10" }.count == 6)
        #expect(Set(result.map(\.series.id)).count == items.count)
    }

    @Test func explicitLessOutweighsTheMaximumInferredWeightOfThatTopic() throws {
        var topics = RecommendationTopicPreferences()
        try topics.set(tag: "懸疑", preference: .less)
        let favorites = (1...6).map { series(String($0), tags: ["懸疑"]) }
        let value = PersonalizedRecommendationProfile(scope: scope, favorites: favorites, history: [], now: now, topicPreferences: topics)
        let result = rank([series("10", tags: ["懸疑"]), series("20", tags: ["校園"])], value)
        #expect(result.map(\.series.id) == ["20", "10"])
        #expect(result.allSatisfy { $0.reason == nil })
    }

    @Test func mixedTopicScoresCancellingToZeroDoNotDisguiseLessAsUnmatchedExploration() throws {
        var topics = RecommendationTopicPreferences()
        try topics.set(tag: "懸疑", preference: .less)
        try topics.set(tag: "甜寵", preference: .more)
        let favorites = (1...3).map { series(String($0), tags: ["懸疑"]) }
        let value = PersonalizedRecommendationProfile(scope: scope, favorites: favorites,
            history: [record(series("4", tags: ["校園"]))], now: now, topicPreferences: topics)
        // 18 from favorites + 12 explicit more + 2 from history - 32 explicit less = 0.
        let items = [series("100", tags: ["懸疑", "甜寵", "校園"])]
            + (110...112).map { series(String($0), tags: ["甜寵"]) } + [series("140", tags: ["穿越"])]
        let result = rank(items, value)
        #expect(result.map(\.series.id) == ["110", "111", "112", "140", "100"])
        #expect(result[3].reason == nil && result[4].reason == nil)
    }

    @Test func scopeMismatchIgnoresBothTopicChoicesAndPreviousBatchContext() throws {
        var topics = RecommendationTopicPreferences()
        try topics.set(tag: "懸疑", preference: .less)
        let value = PersonalizedRecommendationProfile(scope: scope, favorites: [], history: [], now: now, topicPreferences: topics)
        let items = [series("10", tags: ["懸疑"]), series("20", tags: ["校園"])]
        let other = LibraryScope(owner: .account(id: "other"), sourceID: scope.sourceID)
        let result = PersonalizedRecommendation.rank(items, using: value, scope: other,
                                                     recentSeries: [series("30", tags: ["懸疑"]), series("40", tags: ["懸疑"])])
        #expect(result.map(\.series.id) == ["10", "20"] && result.allSatisfy { $0.reason == nil })
    }

    private func series(_ id: String, title: String? = nil, tags: [String] = []) -> Series {
        .init(id: id, title: title ?? "劇\(id)", tags: tags)
    }
    private func record(_ work: Series, seconds: Double = 40, duration: Double = 60, date: Date? = nil) -> WatchRecord {
        .init(series: work, episode: .init(id: "999", number: 1, title: "第1集"), seconds: seconds, duration: duration, updatedAt: date ?? now)
    }
    private func profile(favorites: [Series] = [], history: [WatchRecord] = [], clock: Date? = nil) -> PersonalizedRecommendationProfile {
        .init(scope: scope, favorites: favorites, history: history, now: clock ?? now)
    }
    private func rank(_ items: [Series], _ value: PersonalizedRecommendationProfile? = nil) -> [PersonalizedRecommendationItem] {
        PersonalizedRecommendation.rank(items, using: value ?? profile(), scope: scope)
    }
}
