import Foundation
import Testing
import HongguoCore
@testable import HongguoAppSupport

@MainActor
struct PlaybackRouteSessionTests {
    @Test func routeCopiesRetainTheSameChangedEpisodePositionAndPauseState() throws {
        let route = try fixtureRoute()
        var creations = 0
        let original = try #require(route.session.resolve {
            creations += 1
            return RouteResourceProbe()
        })
        original.episode = 5
        original.position = 58
        original.paused = true
        let copiedRoute = route
        let remounted = copiedRoute.session.resolve {
            creations += 1
            return RouteResourceProbe()
        }
        #expect(route.id == copiedRoute.id && route.session === copiedRoute.session)
        #expect(remounted === original && creations == 1)
        #expect(remounted?.episode == 5 && remounted?.position == 58 && remounted?.paused == true)
        route.session.dispose()
    }

    @Test func disposingIsOnceOnlyAndLateFactoriesCannotReviveTheRoute() {
        var session: PlaybackRouteSession? = PlaybackRouteSession()
        let resource = session?.resolve { RouteResourceProbe() }
        session?.dispose()
        session?.dispose()
        var called = false
        let late = session?.resolve {
            called = true
            return RouteResourceProbe()
        }
        #expect(session?.isDisposed == true && late == nil && !called)
        #expect(resource?.stops == 1)
        session = nil
        #expect(resource?.stops == 1)
    }

    @Test func aDifferentResourceTypeCannotReplaceTheCachedPlayer() {
        let session = PlaybackRouteSession()
        let original = session.resolve { RouteResourceProbe() }
        var called = false
        let mismatch: OtherRouteResource? = session.resolve {
            called = true
            return OtherRouteResource()
        }
        #expect(mismatch == nil && !called && original?.stops == 0)
        session.dispose()
        #expect(original?.stops == 1)
    }

    @Test func aFactoryCannotReenterAndCreateASecondResource() {
        let session = PlaybackRouteSession()
        var nestedCalled = false
        var nested: RouteResourceProbe?
        let original = session.resolve {
            nested = session.resolve {
                nestedCalled = true
                return RouteResourceProbe()
            }
            return RouteResourceProbe()
        }
        #expect(original != nil && nested == nil && !nestedCalled)
        session.dispose()
    }

    @Test func closingDuringCreationStopsTheCandidateInsteadOfInstallingIt() {
        let session = PlaybackRouteSession()
        let candidate = RouteResourceProbe()
        let result = session.resolve {
            session.dispose()
            return candidate
        }
        #expect(result == nil && session.isDisposed && candidate.stops == 1)
        session.dispose()
        #expect(candidate.stops == 1)
    }

    @Test func abandoningTheLastSessionOwnerStopsTheResource() async throws {
        var session: PlaybackRouteSession? = PlaybackRouteSession()
        let resolved = session?.resolve { RouteResourceProbe() }
        let resource = try #require(resolved)
        session = nil
        await resource.waitUntilStopped()
        #expect(resource.stops == 1)
    }

    @Test func distinctRoutesNeverShareTheirResources() throws {
        let first = try fixtureRoute(), second = try fixtureRoute()
        let a = first.session.resolve { RouteResourceProbe() }
        let b = second.session.resolve { RouteResourceProbe() }
        #expect(first.id != second.id && first.session !== second.session && a !== b)
        first.session.dispose()
        #expect(a?.stops == 1 && b?.stops == 0)
        second.session.dispose()
        #expect(b?.stops == 1)
    }

    @Test func launcherDismissDisposesEvenWhenTheCoverStillRetainsACopy() async throws {
        let (launcher, route, _) = try await launchedFixture()
        let resource = route.session.resolve { RouteResourceProbe() }
        launcher.dismiss()
        #expect(launcher.route == nil && route.session.isDisposed && resource?.stops == 1)
        launcher.dismiss()
        #expect(resource?.stops == 1)
    }

    @Test func identityAndParentChangesDisposeThePresentedRoute() async throws {
        for change in 0..<3 {
            let (launcher, route, context) = try await launchedFixture()
            let resource = route.session.resolve { RouteResourceProbe() }
            let next: ContinuePlaybackContext
            switch change {
            case 0: next = .init(owner: .account(id: "42"), revision: context.revision, sceneActive: true)
            case 1: next = .init(owner: .guest, revision: UUID(), sceneActive: true)
            default: next = .init(owner: .guest, revision: context.revision, sceneActive: true, parentActive: false)
            }
            launcher.updateContext(next)
            #expect(launcher.route == nil && route.session.isDisposed && resource?.stops == 1)
        }
    }

    @Test func backgroundContextRetainsTheRouteResourceForThePlayersPausePolicy() async throws {
        let (launcher, route, context) = try await launchedFixture()
        let resource = route.session.resolve { RouteResourceProbe() }
        launcher.updateContext(.init(owner: context.owner, revision: context.revision, sceneActive: false))
        #expect(launcher.route?.id == route.id && !route.session.isDisposed && resource?.stops == 0)
        launcher.updateContext(context)
        #expect(launcher.route?.session === route.session && resource?.stops == 0)
        launcher.dismiss()
        #expect(resource?.stops == 1)
    }

    private func fixtureRoute() throws -> ContinuePlaybackRoute {
        let detail = fixtureDetail()
        let continuation = try #require(PlaybackContinuation.selected(seriesID: detail.series.id,
                                                                      episode: detail.episodes[0], record: nil))
        return .init(detail: detail, continuation: continuation, service: RouteFixtureService(), onProgress: { _, _, _ in })
    }

    private func launchedFixture() async throws -> (ContinuePlaybackModel, ContinuePlaybackRoute, ContinuePlaybackContext) {
        let detail = fixtureDetail()
        let context = ContinuePlaybackContext(owner: .guest, revision: UUID(), sceneActive: true)
        let launcher = ContinuePlaybackModel(loadDetail: { _, _ in detail })
        launcher.start(series: detail.series, context: context, service: RouteFixtureService(),
            currentContext: { context }, latestRecord: { nil }, progressFactory: { _ in { _, _, _ in } })
        let operation = try #require(launcher.operation)
        await operation.value
        return (launcher, try #require(launcher.route), context)
    }

    private func fixtureDetail() -> SeriesDetail {
        .init(series: .init(id: "100", title: "Route fixture"),
              episodes: [.init(id: "900", number: 4, title: "Fourth"), .init(id: "901", number: 5, title: "Fifth")])
    }
}

@MainActor
private final class RouteResourceProbe: PlaybackRouteResource {
    var stops = 0
    var episode = 4
    var position: Double = 64
    var paused = false
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    func stop() {
        stops += 1
        let waiters = stopWaiters
        stopWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitUntilStopped() async {
        if stops > 0 { return }
        await withCheckedContinuation { stopWaiters.append($0) }
    }
}

@MainActor
private final class OtherRouteResource: PlaybackRouteResource {
    func stop() {}
}

private struct RouteFixtureService: CatalogService {
    func home(page: Int) async throws -> SeriesPage { .init(items: [], page: page, hasMore: false) }
    func search(query: String, page: Int) async throws -> SeriesPage { try await home(page: page) }
    func detail(id: String) async throws -> SeriesDetail { throw CatalogError.unavailablePlayback }
    func playback(seriesID: String, episodeID: String, fresh: Bool) async throws -> PlaybackSource {
        throw CatalogError.unavailablePlayback
    }
}
