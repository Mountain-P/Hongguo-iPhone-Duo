import Foundation

/// User-initiated retry order. Selecting a batch never grants automatic resend permission.
public struct LibraryRetryRotation: Sendable {
    private var order: [UUID] = []
    public init() {}

    public mutating func select(from candidates: [UUID], limit: Int) -> [UUID] {
        var seen: Set<UUID> = []
        let candidates = candidates.filter { seen.insert($0).inserted }
        let valid = Set(candidates)
        order.removeAll { !valid.contains($0) }
        let existing = Set(order)
        order.append(contentsOf: candidates.filter { !existing.contains($0) })
        return Array(order.prefix(max(0, limit)))
    }

    /// Advance only after a durable attempt gate and cancellation/scope checks.
    public mutating func didAttempt(_ id: UUID) {
        guard let index = order.firstIndex(of: id) else { return }
        order.remove(at: index); order.append(id)
    }
}
