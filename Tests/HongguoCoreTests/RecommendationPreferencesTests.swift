import Foundation
import Testing
@testable import HongguoCore

struct RecommendationPreferencesTests {
    @Test func everyCategoryAndLocalChoiceSurvivesRoundTrip() throws {
        for category in DirectWebService.Category.allCases {
            var value = RecommendationPreferences(category: category, skipsPreviewed: true)
            try value.setNotInterested(seriesID: "10", value: true)
            try value.markPreviewed(seriesID: "20")
            #expect(try JSONDecoder().decode(RecommendationPreferences.self, from: JSONEncoder().encode(value)) == value)
        }
        #expect(try JSONDecoder().decode(RecommendationPreferences.self, from: Data("{}".utf8)) == RecommendationPreferences())
    }

    @Test func rememberedIDsAreBoundedUniqueAndMostRecentFirst() throws {
        var value = RecommendationPreferences()
        for number in 1...1_005 {
            try value.setNotInterested(seriesID: String(number), value: true)
            try value.markPreviewed(seriesID: String(number))
        }
        #expect(value.notInterestedIDs.count == 1_000)
        #expect(value.previewedIDs.count == 1_000)
        #expect(value.notInterestedIDs.first == "1005")
        #expect(value.notInterestedIDs.last == "6")
        try value.setNotInterested(seriesID: "500", value: true)
        try value.markPreviewed(seriesID: "500")
        #expect(value.notInterestedIDs.first == "500")
        #expect(value.previewedIDs.first == "500")
        #expect(Set(value.notInterestedIDs).count == 1_000)
        #expect(Set(value.previewedIDs).count == 1_000)
    }

    @Test func filteringPreservesSourceOrderAndCanBeUndoneWithoutChangingTheInput() throws {
        let items = ["10", "20", "10", "30", "40"].map { Series(id: $0, title: "劇\($0)") }
        var value = RecommendationPreferences()
        try value.setNotInterested(seriesID: "20", value: true)
        try value.markPreviewed(seriesID: "30")
        #expect(value.filter(items).map(\.id) == ["10", "30", "40"])
        value.skipsPreviewed = true
        #expect(value.filter(items).map(\.id) == ["10", "40"])
        try value.setNotInterested(seriesID: "20", value: false)
        value.restorePreviewed(seriesID: "30")
        #expect(value.filter(items).map(\.id) == ["10", "20", "30", "40"])
        #expect(items.map(\.id) == ["10", "20", "10", "30", "40"])
    }

    @Test func clearingListsRetainsOtherChoicesAndResetRestoresDefaults() throws {
        var value = RecommendationPreferences(category: .aiDrama, skipsPreviewed: true)
        try value.setNotInterested(seriesID: "10", value: true)
        try value.markPreviewed(seriesID: "20")
        value.clearNotInterested()
        #expect(value.allows(seriesID: "10"))
        #expect(!value.allows(seriesID: "20"))
        #expect(value.category == .aiDrama)
        value.clearPreviewed()
        #expect(value.allows(seriesID: "20"))
        #expect(value.skipsPreviewed)
        value.reset()
        #expect(value == RecommendationPreferences())
    }

    @Test func invalidIDsCannotMutateOrRestoreMalformedPreferences() throws {
        var value = RecommendationPreferences()
        try value.markPreviewed(seriesID: "10")
        let original = value
        for invalid in ["", "0", "../10", "123\n", String(repeating: "9", count: 31)] {
            #expect(throws: CatalogError.invalidID) { try value.setNotInterested(seriesID: invalid, value: true) }
            #expect(throws: CatalogError.invalidID) { try value.markPreviewed(seriesID: invalid) }
            #expect(!value.allows(seriesID: invalid))
        }
        #expect(value == original)
        let malformed = Data(#"{"previewedIDs":["10","bad"]}"#.utf8)
        #expect(throws: CatalogError.invalidID) { try JSONDecoder().decode(RecommendationPreferences.self, from: malformed) }
    }

    @Test func oversizedDecodedListsAreDeduplicatedAndBounded() throws {
        let ids = ["10", "10"] + (11...1_100).map(String.init)
        let data = try JSONSerialization.data(withJSONObject: ["notInterestedIDs": ids, "previewedIDs": ids])
        let decoded = try JSONDecoder().decode(RecommendationPreferences.self, from: data)
        #expect(decoded.notInterestedIDs.count == 1_000)
        #expect(decoded.previewedIDs.count == 1_000)
        #expect(decoded.previewedIDs.first == "10")
        #expect(Set(decoded.previewedIDs).count == 1_000)
    }

    @Test func excludedPagesAdvanceAndAllowTheNextEligibleSeries() throws {
        var value = RecommendationPreferences(skipsPreviewed: true)
        try value.setNotInterested(seriesID: "10", value: true)
        try value.markPreviewed(seriesID: "20")
        var queue = RecommendationPreviewQueue()
        let first = queue.beginPageRequest()!
        try queue.receive(page(1, ["10", "20"], more: true), for: first, preferences: value)
        #expect(queue.items.isEmpty)
        #expect(queue.page == 1)
        #expect(queue.hasMore)
        let next = queue.beginPageRequest()!
        try queue.receive(page(2, ["10", "30", "30"], more: false), for: next, preferences: value)
        #expect(queue.items.map(\.id) == ["30"])
        #expect(queue.current?.id == "30")
        #expect(!queue.hasMore)
    }

    @Test func allExcludedPagesStillReachTheHardPageLimitWithoutLooping() throws {
        var value = RecommendationPreferences()
        try value.setNotInterested(seriesID: "10", value: true)
        var queue = RecommendationPreviewQueue()
        for number in 1...100 {
            let request = queue.beginPageRequest()!
            #expect(request.page == number)
            try queue.receive(page(number, ["10"], more: true), for: request, preferences: value)
            #expect(queue.items.isEmpty)
        }
        #expect(queue.beginPageRequest() == nil)
        #expect(!queue.hasMore)
    }

    @Test func restoredChoicesCanRestartTheCatalogueWithoutAcceptingAnOldPage() throws {
        var value = RecommendationPreferences()
        try value.setNotInterested(seriesID: "10", value: true)
        var queue = RecommendationPreviewQueue()
        let oldRequest = queue.beginPageRequest()!
        try queue.receive(page(1, ["10"], more: false), for: oldRequest, preferences: value)
        #expect(queue.items.isEmpty)
        try value.setNotInterested(seriesID: "10", value: false)
        queue.reset()
        #expect(try !queue.receive(page(1, ["20"], more: false), for: oldRequest, preferences: value))
        let newRequest = queue.beginPageRequest()!
        try queue.receive(page(1, ["10"], more: false), for: newRequest, preferences: value)
        #expect(queue.items.map(\.id) == ["10"])
    }

    private func page(_ number: Int, _ ids: [String], more: Bool) -> SeriesPage {
        .init(items: ids.map { .init(id: $0, title: "劇\($0)") }, page: number, hasMore: more)
    }
}
