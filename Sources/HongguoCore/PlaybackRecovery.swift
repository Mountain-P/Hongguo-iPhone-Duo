// SPDX-License-Identifier: GPL-3.0-only
import Foundation

/// Only known transport failures qualify for the single fresh-source retry.
/// Provider denial, invalid media and cancellation take precedence over an outer network error.
public enum PlaybackRecovery {
    public static let assetErrorDomain = "HongguoNativeMediaAsset"
    public static let transientAssetErrorCode = -2001

    public static func shouldRetry(_ error: (any Error)?, attempt: Int) -> Bool {
        guard attempt == 0, let error else { return false }
        var errors: [any Error] = [error]
        var current = error as NSError
        for _ in 0..<8 {
            guard let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
            errors.append(underlying); current = underlying
        }
        if errors.contains(where: isTerminal) { return false }
        return errors.contains(where: isTransient)
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
