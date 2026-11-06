import Foundation

/// Pure range validation shared by the AVFoundation resource loader.
struct MediaByteRange: Equatable {
    let start: Int64
    let end: Int64
    let total: Int64

    static func parse(_ value: String) -> MediaByteRange? {
        let fields = value.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 2, fields[0].lowercased() == "bytes" else { return nil }
        let parts = fields[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let total = Int64(parts[1]), total > 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]), let end = Int64(bounds[1]),
              start >= 0, end >= start, end < total else { return nil }
        return MediaByteRange(start: start, end: end, total: total)
    }

    static func requestHeader(offset: Int64, length: Int, allToEnd: Bool) -> String? {
        guard offset >= 0, length > 0 else { return nil }
        if allToEnd { return "bytes=\(offset)-" }
        let (end, overflow) = offset.addingReportingOverflow(Int64(length - 1))
        guard !overflow else { return nil }
        return "bytes=\(offset)-\(end)"
    }

    static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func port(_ url: URL) -> Int? { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && port(first) == port(second)
    }
}
