// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only exhausted, explicitly classified temporary registration failures pause
/// the source queue. This does not expand online playback's retry policy.
enum OfflineSourceRecovery {
    static let delays: [TimeInterval] = [10, 20, 40]
    private static let codes: Set<String> = [
        "REGISTRATION_UNAVAILABLE", "REGISTRATION_TIMEOUT", "REGISTRATION_NETWORK_ERROR",
        "REGISTRATION_HTTP_500", "REGISTRATION_HTTP_502", "REGISTRATION_HTTP_503", "REGISTRATION_HTTP_504"
    ]

    static func shouldWait(_ error: any Error) -> Bool {
        var current: (any Error)? = error
        var temporary = false
        for _ in 0...8 {
            guard let cause = current else { return temporary }
            if cause is CancellationError { return false }
            if let source = cause as? NativeSourceError {
                guard codes.contains(source.code) else { return false }
                temporary = true
            }
            if let media = cause as? NativeMediaError {
                guard case .network = media else { return false }
            }
            if let catalog = cause as? CatalogError {
                guard case .network = catalog else { return false }
            }
            if cause is NativeProgressiveError || cause is OfflineDownloadError { return false }
            let ns = cause as NSError
            if ns.domain == NSURLErrorDomain && ns.code == URLError.cancelled.rawValue { return false }
            current = ns.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return false // Never infer recovery from a truncated or cyclic cause chain.
    }
}
