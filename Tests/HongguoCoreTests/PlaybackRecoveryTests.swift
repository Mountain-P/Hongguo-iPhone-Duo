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

    @Test func onlyAnAssetReadRejectionCanRequestANewValidatedSource() {
        let blocked = NativeMediaError.unsafeURL
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11800,
                              userInfo: [NSUnderlyingErrorKey: blocked])
        #expect(PlaybackRecovery.shouldRetryAssetRead(blocked))
        #expect(PlaybackRecovery.shouldRetryAssetRead(wrapped))
        #expect(!PlaybackRecovery.shouldRetry(blocked, attempt: 0))
        #expect(!PlaybackRecovery.shouldRetry(wrapped, attempt: 0))
        #expect(!PlaybackRecovery.shouldRetryAssetRead(CatalogError.unsafePlaybackURL))
        #expect(!PlaybackRecovery.shouldRetryAssetRead(URLError(.redirectToNonExistentLocation)))
    }

    @Test func nestedDenialAndCancellationOverrideAnAssetRetrySignal() {
        let terminal: [any Error] = [CatalogError.unauthorized, CatalogError.httpStatus(401),
            CatalogError.httpStatus(403), NativeMediaError.httpStatus(401), NativeMediaError.httpStatus(403),
            CatalogError.unsafePlaybackURL, CancellationError(), URLError(.cancelled),
            NSError(domain: PlaybackRecovery.assetErrorDomain, code: 401),
            NSError(domain: PlaybackRecovery.assetErrorDomain, code: 403),
            NSError(domain: PlaybackRecovery.assetErrorDomain, code: 429)]
        for cause in terminal {
            let wrapped = NSError(domain: PlaybackRecovery.assetErrorDomain,
                                  code: PlaybackRecovery.transientAssetErrorCode,
                                  userInfo: [NSUnderlyingErrorKey: cause])
            #expect(!PlaybackRecovery.shouldRetryAssetRead(wrapped))
            #expect(!PlaybackRecovery.shouldRetry(wrapped, attempt: 0))
        }
    }

    @Test func expiredSourceDuringLongPauseWaitsForOneExplicitPlay() {
        var policy = LongPauseSourceRecovery()
        policy.pause(at: 1)
        #expect(policy.failure(CatalogError.httpStatus(410), at: 4) == .waitForPlay)
        policy.pause(at: 23)
        #expect(policy.failure(CatalogError.httpStatus(410), at: 33) == .waitForPlay)
        #expect(policy.explicitPlay(at: 45) == .refresh)
        #expect(policy.explicitPlay(at: 46) == .ordinary)
        #expect(policy.failure(CatalogError.httpStatus(410), at: 48) == .ordinary)
    }

    @Test func validSourcesAndDenialsNeverTriggerLongPauseRefresh() {
        var policy = LongPauseSourceRecovery()
        policy.pause(at: 1)
        #expect(policy.explicitPlay(at: 41) == .ordinary)
        #expect(policy.failure(CatalogError.unauthorized, at: 42) == .ordinary)
        let denied = NSError(domain: PlaybackRecovery.assetErrorDomain, code: 403)
        let wrapped = NSError(domain: PlaybackRecovery.assetErrorDomain, code: 410, userInfo: [NSUnderlyingErrorKey: denied])
        #expect(policy.failure(wrapped, at: 42) == .ordinary)
        #expect(policy.failure(NativeMediaError.httpStatus(404), at: 43) == .refresh)
        #expect(policy.failure(NativeMediaError.httpStatus(404), at: 44) == .ordinary)
        policy.pause(at: 100)
        #expect(policy.explicitPlay(at: 101) == .ordinary)
        #expect(policy.failure(NativeMediaError.httpStatus(404), at: 102) == .ordinary)
        policy.pause(at: 104)
        #expect(policy.failure(CatalogError.httpStatus(410), at: 105) == .waitForPlay)
        #expect(policy.explicitPlay(at: 106) == .showExpired(410))
        policy.pause(at: 110)
        #expect(policy.explicitPlay(at: 141) == .ordinary)
        #expect(policy.failure(NativeMediaError.httpStatus(404), at: 180) == .ordinary)
    }
}
