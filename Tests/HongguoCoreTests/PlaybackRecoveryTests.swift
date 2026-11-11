// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

struct PlaybackRecoveryTests {
    @Test func onlyKnownTransportFailuresGetOneFreshRetry() {
        let errors: [any Error] = [CatalogError.network, CatalogError.httpStatus(503),
            NativeMediaError.network, NativeMediaError.httpStatus(502),
            NativeSourceError(code: "ETIMEDOUT"), NativeSourceError(code: "ECONNRESET"),
            URLError(.timedOut), URLError(.networkConnectionLost),
            NSError(domain: PlaybackRecovery.assetErrorDomain, code: PlaybackRecovery.transientAssetErrorCode)]
        for error in errors {
            #expect(PlaybackRecovery.shouldRetry(error, attempt: 0))
            #expect(PlaybackRecovery.shouldRetryAssetRead(error))
            #expect(!PlaybackRecovery.shouldRetry(error, attempt: 1))
            #expect(!PlaybackRecovery.shouldRetry(error, attempt: 2))
        }
    }

    @Test func denialFormatCancellationAndUnknownFailuresDoNotRetry() {
        let errors: [any Error] = [CatalogError.unauthorized, CatalogError.httpStatus(401), CatalogError.httpStatus(403),
            NativeMediaError.httpStatus(403), NativeMediaError.unsupportedCodec,
            NativeMediaError.unsupportedEncryption, NativeProgressiveError.unsupportedRange,
            NativeProgressiveError.changedSource, NativeSourceError(code: "BUSINESS_REJECTED"),
            NativeSourceError(code: "NO_COMPATIBLE_SOURCE"), NativeSourceError(code: "UNKNOWN"),
            URLError(.cancelled), URLError(.badServerResponse), CancellationError(),
            NSError(domain: PlaybackRecovery.assetErrorDomain, code: 2)]
        for error in errors { #expect(!PlaybackRecovery.shouldRetry(error, attempt: 0)) }
        #expect(!PlaybackRecovery.shouldRetry(nil, attempt: 0))
    }

    @Test func underlyingDenialOverridesAnOuterNetworkFailure() {
        let denial = NSError(domain: PlaybackRecovery.assetErrorDomain, code: 403)
        let wrapped = NSError(domain: NSURLErrorDomain, code: URLError.timedOut.rawValue,
                              userInfo: [NSUnderlyingErrorKey: denial])
        #expect(!PlaybackRecovery.shouldRetry(wrapped, attempt: 0))
        let network = NSError(domain: NSURLErrorDomain, code: URLError.networkConnectionLost.rawValue)
        let avError = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: network])
        #expect(PlaybackRecovery.shouldRetry(avError, attempt: 0))
    }

    @Test func onlyAssetReadsClassifyAChangedSourceForFreshRecovery() {
        let changed = NativeProgressiveError.changedSource
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: changed])
        #expect(PlaybackRecovery.shouldRetryAssetRead(changed))
        #expect(PlaybackRecovery.shouldRetryAssetRead(wrapped))
        #expect(!PlaybackRecovery.shouldRetry(changed, attempt: 0))
        #expect(!PlaybackRecovery.shouldRetry(wrapped, attempt: 0))
        #expect(!PlaybackRecovery.shouldRetryAssetRead(NativeProgressiveError.invalidRange))
        #expect(!PlaybackRecovery.shouldRetryAssetRead(NativeProgressiveError.unsupportedRange))

        let sanitized = NSError(domain: PlaybackRecovery.assetErrorDomain,
                                code: PlaybackRecovery.transientAssetErrorCode)
        #expect(PlaybackRecovery.shouldRetry(sanitized, attempt: 0))
        #expect(!PlaybackRecovery.shouldRetry(sanitized, attempt: 1))
    }

    @Test func nestedDenialUnsafeURLAndCancellationOverrideAnAssetRetrySignal() {
        let terminal: [any Error] = [CatalogError.unauthorized, CatalogError.httpStatus(403),
            CatalogError.unsafePlaybackURL, NativeMediaError.unsafeURL, CancellationError(), URLError(.cancelled),
            NSError(domain: PlaybackRecovery.assetErrorDomain, code: 429)]
        for cause in terminal {
            let wrapped = NSError(domain: PlaybackRecovery.assetErrorDomain,
                                  code: PlaybackRecovery.transientAssetErrorCode,
                                  userInfo: [NSUnderlyingErrorKey: cause])
            #expect(!PlaybackRecovery.shouldRetryAssetRead(wrapped))
            #expect(!PlaybackRecovery.shouldRetry(wrapped, attempt: 0))
        }
    }
}
