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

/// Only a user-initiated resume can refresh a confirmed obsolete media URL after a long pause.
public struct LongPauseSourceRecovery: Sendable {
    public enum Decision { case ordinary, waitForPlay, refresh }
    public enum PlayDecision: Equatable { case ordinary, refresh, showExpired(Int) }
    private var pausedAt: Double?
    private var expiredStatus: Int?
    private var resumedAt: Double?

    public init() {}

    public mutating func pause(at time: Double) {
        if pausedAt == nil { pausedAt = time }
    }

    public mutating func explicitPlay(at time: Double) -> PlayDecision {
        guard let pausedAt else { return .ordinary }
        let longPause = time - pausedAt >= 30
        self.pausedAt = nil
        defer { expiredStatus = nil }
        if let expiredStatus {
            let refresh = longPause || resumedAt != nil
            resumedAt = nil
            return refresh ? .refresh : .showExpired(expiredStatus)
        }
        if longPause { resumedAt = time }
        return .ordinary
    }

    /// A cached prefix can outlast any wall-clock grace period. Only a validated
    /// foreground network request started after resume proves this URL is still usable.
    public mutating func failure(_ error: (any Error)?, at time: Double,
                                 lastValidatedRequestStartedAt: Double? = nil) -> Decision {
        if let resumedAt, let lastValidatedRequestStartedAt,
           lastValidatedRequestStartedAt >= resumedAt, lastValidatedRequestStartedAt <= time {
            self.resumedAt = nil
        }
        var cause = error
        var obsolete: Int?
        for _ in 0..<8 {
            guard let value = cause else { break }
            if case CatalogError.unauthorized = value { return .ordinary }
            let ns = value as NSError
            let status: Int?
            if case CatalogError.httpStatus(let code) = value { status = code }
            else if case NativeMediaError.httpStatus(let code) = value { status = code }
            else if ns.domain == PlaybackRecovery.assetErrorDomain { status = ns.code }
            else { status = nil }
            if status == 401 || status == 403 { return .ordinary }
            if status == 404 || status == 410 { obsolete = status }
            cause = ns.userInfo[NSUnderlyingErrorKey] as? any Error
        }
        guard let obsolete else { return .ordinary }
        if pausedAt != nil {
            expiredStatus = obsolete
            return .waitForPlay
        }
        if resumedAt != nil {
            resumedAt = nil
            return .refresh
        }
        return .ordinary
    }
}
