import Foundation
import Testing
@testable import HongguoCore

struct MetadataHydrationTests {
    @Test func fiftyFailuresCannotStarveLaterUntriedItems() {
        var scheduler = MetadataHydrationScheduler(cooldown: 30)
        let ids = (100..<160).map(String.init), start = Date(timeIntervalSince1970: 1000)
        let first = scheduler.batch(candidates: ids, now: start)
        #expect(first == Array(ids.prefix(50)))
        first.forEach { scheduler.completed($0, succeeded: false, now: start) }
        #expect(scheduler.batch(candidates: ids, now: start.addingTimeInterval(1)) == Array(ids.suffix(10)))
        let next = scheduler.batch(candidates: ids, now: start.addingTimeInterval(31))
        #expect(next == first)
    }

    @Test func repeatedFailuresBackOffWithoutRetryingOrDroppingOtherCandidates() {
        var scheduler = MetadataHydrationScheduler(cooldown: 10)
        let start = Date(timeIntervalSince1970: 1000)
        #expect(scheduler.batch(candidates: ["10"], now: start) == ["10"])
        scheduler.completed("10", succeeded: false, now: start)
        #expect(scheduler.batch(candidates: ["10"], now: start.addingTimeInterval(9)).isEmpty)
        #expect(scheduler.batch(candidates: ["10"], now: start.addingTimeInterval(10)) == ["10"])
        scheduler.completed("10", succeeded: false, now: start.addingTimeInterval(10))
        #expect(scheduler.batch(candidates: ["10", "20"], now: start.addingTimeInterval(29)) == ["20"])
        #expect(scheduler.batch(candidates: ["10"], now: start.addingTimeInterval(30)) == ["10"])
    }

    @Test func rotationDeduplicatesCapsEachRoundAndDropsRemovedSourceIDs() {
        var scheduler = MetadataHydrationScheduler(capacity: 60)
        let ids = (100..<180).map(String.init)
        #expect(scheduler.batch(candidates: ids + ids, limit: 500).count == 50)
        let rotated = scheduler.batch(candidates: ids, limit: 50)
        #expect(Array(rotated.prefix(10)) == (150..<160).map(String.init))
        #expect(scheduler.batch(candidates: ["999"], limit: 50) == ["999"])
        #expect(scheduler.batch(candidates: [], limit: 50).isEmpty)
    }

    @Test func anOldBatchCannotClearOrDeliverResultsIntoItsReplacement() {
        let scope = LibraryScope(owner: .account(id: "42"), sourceID: "native")
        var generation = MetadataHydrationGeneration()
        let old = generation.begin(scope: scope), replacement = generation.begin(scope: scope)
        #expect(!generation.accepts(old))
        #expect(generation.accepts(replacement))
        generation.invalidate()
        #expect(!generation.accepts(replacement))
        let other = generation.begin(scope: .init(owner: .account(id: "43"), sourceID: "native"))
        #expect(!generation.accepts(old) && !generation.accepts(replacement))
        #expect(generation.accepts(other))
    }

    @Test func detailCacheExpiresByTTLAndEvictsLeastRecentlyUsed() {
        var cache = LibraryDetailCache(capacity: 2, ttl: 10)
        let start = Date(timeIntervalSince1970: 1000)
        cache.insert(detail("10"), now: start)
        cache.insert(detail("20"), now: start)
        #expect(cache.value(for: "10", now: start.addingTimeInterval(1)) != nil)
        cache.insert(detail("30"), now: start.addingTimeInterval(2))
        #expect(cache.value(for: "20", now: start.addingTimeInterval(2)) == nil)
        #expect(cache.count == 2)
        #expect(cache.value(for: "10", now: start.addingTimeInterval(10)) == nil)
        #expect(cache.value(for: "30", now: start.addingTimeInterval(11)) != nil)
        #expect(cache.value(for: "30", now: start.addingTimeInterval(12)) == nil)
    }

    @Test func cacheEpisodeBudgetAndSourceClearBoundMemoryIndependentlyOfEntryCount() {
        var cache = LibraryDetailCache(capacity: 10, maximumEpisodes: 5)
        cache.insert(detail("10", episodes: 3)); cache.insert(detail("20", episodes: 3))
        #expect(cache.count == 1 && cache.episodeCount == 3)
        #expect(cache.value(for: "10") == nil)
        cache.insert(detail("30", episodes: 6))
        #expect(cache.value(for: "30") == nil)
        #expect(cache.value(for: "20") != nil)
        cache.removeAll()
        #expect(cache.count == 0 && cache.episodeCount == 0)
    }

    private func detail(_ id: String, episodes: Int = 1) -> SeriesDetail {
        .init(series: .init(id: id, title: "測試劇"), episodes: (1...episodes).map {
            .init(id: String(1000 + $0), number: $0, title: "第\($0)集")
        })
    }
}
