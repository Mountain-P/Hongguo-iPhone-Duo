# 0.16.5 playback protocol recovery

## Failure and upstream evidence

On 2026-11-18, version 0.16.4 / build 54 on the iPhone Duo iOS 27.2
simulator failed before playback on Qingmei episodes 1, 20, 21 and 22, and
two preview titles. The download path also returned `EMPTY_RESPONSE` for
episodes 1, 20 and 21; no media bytes were downloaded. The response parser
raises this code for an empty HTTP 200 body, not for a CDN buffer underrun.

Reference projects were checked live:

- [jackotom/hongguo-drama v7.5](https://github.com/jackotom/hongguo-drama/releases/tag/v7.5)
  describes the same empty HTTP 200 regression and a v5 player protocol fix.
- [N3urda/hongguoTV PR 60](https://github.com/N3urda/hongguoTV/pull/60)
  records the Kotlin v5 playback repair, released in 0.16.5; its latest
  0.16.8 also changes remote-control episode switching behavior.
- [aston314 0.2.173](https://github.com/aston314/hongguo-tv-releases/releases/tag/v0.2.173)
  reports restored playback URL resolution.
- [yangbin1322 1.2.29](https://github.com/yangbin1322/hongguo-player/releases/tag/v1.2.29)
  contains player/layout fixes; its README also identifies outdated clients
  as a cause of empty playback responses.

## Integrated change and provenance

The native iPhone runtime now uses the current gzip POST endpoint
`/novel/player/multi_video_model/player/v1`, signs the exact outgoing bytes
with v5, and sends `dr_scene: player`. The requested content type and episode
remain exact; the new content-type-keyed response envelope is supported.

`playback-v5.js` is byte-for-byte from jackotom/hongguo-drama commit
`100d7c7bfa40328d2304b29eb852ca304f53e59b`, Git blob
`4019afdd2a8fe707cc31895502622e2f0ac5082b`. It is GPL-3.0-only and retains
the original header attributing the Kotlin v5 implementation to
N3urda/hongguoTV `18c37c2afd0567520135abcae312352542f09083` and drpys.
The app's bundled NOTICE records the update. No new SDK or remote signing
service is required.

The v5 route registers a fresh anonymous identity for each resolution,
because the current protocol can consume playback identities. Only an empty
HTTP 200 primary response enables one attempt on the second official host,
using the same identity. Existing legacy recovery remains bounded by the
same overall deadline. Explicit HTTP 401/403/429, provider denials,
cancellation, and URL restrictions remain terminal. Account/login and
metadata profiles are unchanged. The optional Backend bridge is not used by
the native app and is not migrated in this change.

The native zlib adapter now exposes the existing, 2 MiB bounded gunzip
operation to the bundled signer. The resource manifest covers all 14 JS
files. Test-only hooks expose v5 primitives only in the existing test runtime.

## Verification

NativePlaybackV5Tests checks 32 independent F13 vectors and four carrier
permutations in JavaScriptCore, exact gzip request binding, typed episode
matching, fresh identities, bounded alternate-host recovery and terminal
denials. Existing registration, account, media validation, cancellation,
download and playback tests remain in the full suite.

The same previously failing episode 20 resolved to 1080p HEVC and decoded
its first frame in 4.95 seconds in the standalone macOS core check. This is
pipeline evidence, separate from iOS UI, simulator playback or a physical phone.

Simulator acceptance on iPhone Duo / iOS 27.2:

- Qingmei episodes 20–22 completed at an observed AVPlayer rate of 2x, with
  two automatic episode transitions. The production player harness recorded
  zero stalls and zero reloads across all three episodes (122.22 seconds).
  Startup was 12.34 / 4.17 / 0.11 seconds respectively; this does not claim
  that every cold start is instant or every network will behave identically.
- Real offline queue download of episodes 20–29: 10 completed, zero failed,
  48,014,236 bytes, 43.51 seconds including harness startup.
- After terminating and relaunching the isolated offline app, all ten local
  files decoded start/middle/end frames (30 frames total), retained resume
  position 2 seconds and played past 8 seconds at 2x. The download provider
  was replaced by a throwing implementation; provider calls were zero.
  This validates local playback without a source service, not a test of
  toggling the host Mac's network or physical iPhone airplane mode.
- Full working-tree Swift test run: 633 Core and 112 AppSupport tests passed
  (includes the pre-existing, uncommitted resource-integrity test). The
  existing 22 bridge tests and 11 upstream v5 synthetic tests also passed.
- All three simulator builds read back 0.16.5 / build 55 and all 14 bundled
  JS resource hashes matched source and manifest.

The production UI also showed real playback for both previously failing
preview titles, 少夫人来自东北3 and 嫌疑人的秘密2藏金生死线. The second
preview displayed video after expanding Duo, and its 追這部 action opened
the normal player at the current progress. This is a visual playback smoke
test, not full acceptance of every gesture or rotation transition.

These are ten sampled downloads, not a claim that all 91 episodes were
batch-downloaded or that a physical iPhone was tested. Local detailed logs
stay in ignored `build/source-repair-20261118/`; they are not included in the
public repository.
