import Testing
@testable import HongguoCore

struct RecommendationFeedActivationTests {
    @Test func intermediateCardsNeverOwnPlaybackUntilScrollingSettles() throws {
        var activation = RecommendationFeedActivation()
        #expect(update(&activation, "10", idle: false) == nil)
        #expect(update(&activation, "20", idle: false) == nil)
        #expect(update(&activation, "30", idle: false) == nil)
        let settled = try #require(update(&activation, "30"))
        #expect(settled.seriesID == "30")
        #expect(activation.accepts(settled))
    }

    @Test func repeatedIdleFeedbackDoesNotRestartTheSameCard() throws {
        var activation = RecommendationFeedActivation()
        let first = try #require(update(&activation, "10"))
        for _ in 0..<20 { #expect(update(&activation, "10") == first) }
        #expect(activation.lease == first)
    }

    @Test func rapidAtoBtoACannotAcceptTheFirstAResponse() throws {
        var activation = RecommendationFeedActivation()
        let firstA = try #require(update(&activation, "10"))
        let b = try #require(update(&activation, "20"))
        let secondA = try #require(update(&activation, "10"))
        #expect(firstA.seriesID == secondA.seriesID)
        #expect(firstA.token != secondA.token)
        #expect(!activation.accepts(firstA))
        #expect(!activation.accepts(b))
        #expect(activation.accepts(secondA))
    }

    @Test func everyIneligibleStateImmediatelyRevokesTheOnlyLease() throws {
        var activation = RecommendationFeedActivation()
        for gate in 0..<4 {
            let old = try #require(update(&activation, "10"))
            let result = activation.update(selectedID: "10", isIdle: gate != 0,
                                           isActive: gate != 1, isSceneActive: gate != 2,
                                           isDetailPresented: gate == 3)
            #expect(result == nil)
            #expect(activation.lease == nil)
            #expect(!activation.accepts(old))
            let resumed = try #require(update(&activation, "10"))
            #expect(resumed.token != old.token)
        }
    }

    @Test func detailDismissalCanRemainPausedUntilExplicitUserResume() throws {
        var activation = RecommendationFeedActivation()
        let old = try #require(update(&activation, "10"))
        #expect(activation.update(selectedID: "10", isIdle: true, isActive: true,
                                  isSceneActive: true, isDetailPresented: true) == nil)
        // The view folds its manual-resume-after-detail gate into isActive.
        #expect(activation.update(selectedID: "10", isIdle: true, isActive: false,
                                  isSceneActive: true, isDetailPresented: false) == nil)
        let resumed = try #require(update(&activation, "10"))
        #expect(!activation.accepts(old))
        #expect(resumed.token != old.token)
    }

    @Test func missingSelectionAndSourceReplacementCannotKeepStaleWorkAlive() throws {
        var activation = RecommendationFeedActivation()
        let old = try #require(update(&activation, "10"))
        activation.invalidate()
        #expect(!activation.accepts(old))
        let newSource = try #require(update(&activation, "10"))
        #expect(newSource.token != old.token)
        #expect(update(&activation, nil) == nil)
        #expect(!activation.accepts(newSource))
        #expect(update(&activation, "") == nil)
    }

    @Test func coastingBetweenTwoVisitsToACreatesADistinctActivation() throws {
        var activation = RecommendationFeedActivation()
        let old = try #require(update(&activation, "10"))
        #expect(update(&activation, "10", idle: false) == nil)
        #expect(update(&activation, "20", idle: false) == nil)
        #expect(update(&activation, "10", idle: false) == nil)
        let returned = try #require(update(&activation, "10"))
        #expect(returned.token != old.token)
        #expect(!activation.accepts(old))
    }

    private func update(_ activation: inout RecommendationFeedActivation,
                        _ id: String?, idle: Bool = true) -> RecommendationFeedActivation.Lease? {
        activation.update(selectedID: id, isIdle: idle, isActive: true,
                          isSceneActive: true, isDetailPresented: false)
    }
}
