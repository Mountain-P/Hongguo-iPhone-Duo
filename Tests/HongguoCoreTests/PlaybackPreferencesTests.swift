// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Testing
@testable import HongguoCore

@MainActor
struct PlaybackPreferencesTests {
    @Test func reopeningRestoresExplicitChoicesButNotTemporaryBoostOrLock() throws {
        let suite = "HongguoPlaybackFixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPreferencesStore(defaults: defaults)
        #expect(store.load() == PlaybackPreferences())
        store.setNormalRate(1.5); store.setAutoNext(false)
        var state = PlaybackSpeedState()
        state.selectRate(store.load().normalRate)
        state.beginHold(); state.lock()
        #expect(state.effectiveRate == 2)
        let reopened = PlaybackPreferencesStore(defaults: try #require(UserDefaults(suiteName: suite)))
        #expect(reopened.load() == PlaybackPreferences(normalRate: 1.5, autoNext: false))
        var nextPlayer = PlaybackSpeedState()
        nextPlayer.selectRate(reopened.load().normalRate)
        #expect(nextPlayer.effectiveRate == 1.5)
        #expect(!nextPlayer.isLocked && !nextPlayer.isPressing)
    }

    @Test func previewOverrideDoesNotReplaceTheSavedAutoplayChoice() throws {
        let suite = "HongguoPlaybackFixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPreferencesStore(defaults: defaults)
        store.setNormalRate(2); store.setAutoNext(true)
        let preview = store.load().resolved(isPreview: true)
        #expect(!preview.autoNext && preview.normalRate == 2)
        #expect(store.load().resolved(isPreview: false).autoNext)
        store.setAutoNext(false)
        #expect(!store.load().resolved(isPreview: false).autoNext)
        #expect(!store.load().resolved(isPreview: true).autoNext)
    }

    @Test func invalidPersistedOrSelectedRatesCannotPoisonPlayback() throws {
        let suite = "HongguoPlaybackFixture." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PlaybackPreferencesStore(defaults: defaults)
        store.setNormalRate(1.25)
        for invalid: Float in [.nan, .infinity, 0, -1, 4.01] {
            store.setNormalRate(invalid)
            #expect(store.load().normalRate == 1.25)
        }
        defaults.set("invalid", forKey: PlaybackPreferencesStore.normalRateKey)
        #expect(store.load().normalRate == 1)
        defaults.set(100, forKey: PlaybackPreferencesStore.normalRateKey)
        #expect(store.load().normalRate == 1)
    }
}

struct PlaybackReplayTests {
    @Test func endedReplayDiffersFromPausedSeekAndUnknownDuration() {
        #expect(PlaybackReplay.shouldRestart(position: 100, duration: 100, reachedEnd: true))
        #expect(PlaybackReplay.shouldRestart(position: 99.9, duration: 100, reachedEnd: false))
        #expect(!PlaybackReplay.shouldRestart(position: 50, duration: 100, reachedEnd: false))
        #expect(!PlaybackReplay.shouldRestart(position: 0, duration: 0.1, reachedEnd: false))
        #expect(!PlaybackReplay.shouldRestart(position: 0, duration: 0, reachedEnd: true))
        #expect(!PlaybackReplay.shouldRestart(position: .nan, duration: 100, reachedEnd: true))
        #expect(!PlaybackReplay.shouldRestart(position: 100, duration: .infinity, reachedEnd: true))
    }
}
