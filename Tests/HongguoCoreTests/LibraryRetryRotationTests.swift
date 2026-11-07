import Foundation
import Testing
@testable import HongguoCore

struct LibraryRetryRotationTests {
    @Test func failedFirstBatchCannotStarveLaterIDsAndRemovedACKsDoNotResetOrder() {
        let ids = (0..<30).map { _ in UUID() }
        var rotation = LibraryRetryRotation()
        let first = rotation.select(from: ids, limit: 20)
        #expect(first == Array(ids.prefix(20)))
        first.forEach { rotation.didAttempt($0) }
        let remaining = ids.filter { $0 != first.last! }
        let second = rotation.select(from: remaining, limit: 20)
        #expect(Array(second.prefix(10)) == Array(ids.suffix(10)))
    }

    @Test func cancellationBeforeAttemptDoesNotAdvanceAndOnlyActualAttemptsRotate() {
        let ids = (0..<4).map { _ in UUID() }
        var rotation = LibraryRetryRotation()
        #expect(rotation.select(from: ids, limit: 2) == Array(ids.prefix(2)))
        #expect(rotation.select(from: ids, limit: 2) == Array(ids.prefix(2)))
        rotation.didAttempt(ids[0])
        #expect(rotation.select(from: ids, limit: 2) == [ids[1], ids[2]])
    }

    @Test func newMutationUUIDReplacesOldOneAndUnknownAttemptsCannotGrowTheQueue() {
        let old = UUID(), other = UUID(), replacement = UUID()
        var rotation = LibraryRetryRotation()
        _ = rotation.select(from: [old, other], limit: 2)
        rotation.didAttempt(old); rotation.didAttempt(UUID())
        #expect(rotation.select(from: [other, replacement, replacement], limit: 20) == [other, replacement])
        #expect(rotation.select(from: [], limit: 20).isEmpty)
    }

    @Test func independentScopesAndBatchSizesDoNotShareRetryPermissionOrPosition() {
        let ids = (0..<15).map { _ in UUID() }
        var a = LibraryRetryRotation(), b = LibraryRetryRotation()
        let first = a.select(from: ids, limit: 10); first.forEach { a.didAttempt($0) }
        #expect(Array(a.select(from: ids, limit: 10).prefix(5)) == Array(ids.suffix(5)))
        #expect(b.select(from: ids, limit: 10) == first)
        #expect(a.select(from: ids, limit: -1).isEmpty)
    }
}
