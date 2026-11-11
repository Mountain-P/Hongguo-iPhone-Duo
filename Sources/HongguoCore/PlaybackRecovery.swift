// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Known transport failures qualify for the single fresh-source retry.
/// Provider denial, invalid media and cancellation take precedence over an outer network error.
public enum PlaybackRecovery {
    public static let assetErrorDomain = "HongguoNativeMediaAsset"
    public static let transientAssetErrorCode = -2001

    public static func shouldRetry(_ error: (any Error)?, attempt: Int) -> Bool {
        guard attempt == 0, let error else { return false }
        return isRetryable(error, fromAssetRead: false)
    }

    /// A version mismatch or rejected URL while reading a prepared asset can
    /// trigger one new source lookup through the player. The blocked URL stays
    /// blocked, and the new source goes through regular validation.
    public static func shouldRetryAssetRead(_ error: any Error) -> Bool {
        isRetryable(error, fromAssetRead: true)
    }

    private static func isRetryable(_ error: any Error, fromAssetRead: Bool) -> Bool {
        var current: (any Error)? = error
        var retryable = false
        for _ in 0...8 {
            guard let cause = current else { break }
            if fromAssetRead && ((cause as? NativeProgressiveError) == .changedSource
                                 || (cause as? NativeMediaError) == .unsafeURL) {
                retryable = true
            } else {
                if isTerminal(cause) { return false }
                if isTransient(cause) { retryable = true }
            }
            // Keep typed Swift errors when a wrapper carries them as its cause.
            current = (cause as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
        }
        return retryable
    }

    private static func isTerminal(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let value = error as? CatalogError {
            switch value {
            case .network: return false
            case .httpStatus(let status): return !(500...599).contains(status)
            default: return true
            }
        }
        if let value = error as? NativeMediaError {
            switch value {
            case .network: return false
            case .httpStatus(let status): return !(500...599).contains(status)
            default: return true
            }
        }
        if error is NativeProgressiveError { return true }
        if let value = error as? NativeSourceError { return !transientSourceCodes.contains(value.code) }
        let value = error as NSError
        if value.domain == NSURLErrorDomain { return value.code == URLError.cancelled.rawValue }
        if value.domain == assetErrorDomain {
            return value.code != transientAssetErrorCode && !(500...599).contains(value.code)
        }
        return false
    }

    private static func isTransient(_ error: any Error) -> Bool {
        if case CatalogError.network = error { return true }
        if case CatalogError.httpStatus(let status) = error { return (500...599).contains(status) }
        if case NativeMediaError.network = error { return true }
        if case NativeMediaError.httpStatus(let status) = error { return (500...599).contains(status) }
        if let value = error as? NativeSourceError { return transientSourceCodes.contains(value.code) }
        let value = error as NSError
        if value.domain == assetErrorDomain {
            return value.code == transientAssetErrorCode || (500...599).contains(value.code)
        }
        guard value.domain == NSURLErrorDomain else { return false }
        return [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                .dnsLookupFailed, .notConnectedToInternet].contains { $0.rawValue == value.code }
    }

    private static let transientSourceCodes: Set<String> = [
        "ETIMEDOUT", "ERR_NETWORK", "ECONNRESET", "ECONNREFUSED", "ENOTFOUND", "EAI_AGAIN",
        "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504"
    ]
}
