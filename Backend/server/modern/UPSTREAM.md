# Current anonymous playback adapter

`app-source.js`, `playback-device.js`, `download-quality.js` and `sm3.js` originate from jackotom/hongguo-drama commit `2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0`, GPL-3.0:

https://github.com/jackotom/hongguo-drama/tree/2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0/src/native

Their original notices and algorithm provenance are retained in `licenses/NOTICE.txt` and `licenses/LICENSE.drpys.txt`. The anonymous registration protocol is attributed in `playback-device.js` to tsukiyo-zero/hongguoTV commit `388931852ddc614db8b00775a3dc54c5ede6307f`, adapted from charlie901208/HGTV, GPL-3.0-only.

`download-quality.js` and `sm3.js` remain unmodified. Local changes to `app-source.js` and `playback-device.js` add cancellation, an independent anonymous video-tab identity with registration-cookie allowlisting, and bounded recovery through freshly registered POST identities. Playback uses the existing branch-2 signing implementation, 256 ticket attempts, the 7.1.3.32 playback profile, and an MD5 of the exact uncompressed POST bytes; account, search and metadata signing profiles remain separate. `playback-recovery.js` and `stream-cache.js` are new local orchestration modules under GPL-3.0-only.

The request ordering and playback-profile contract were checked against the user-provided Quest 1.5.2 source snapshot and aston314/hongguo-tv commit `36508246eeca2cf5ef1f29f7f17f8e985d50ae2e` (v0.2.150), specifically `core/cmd/hongguotv/minireel*.go` and its device/passport signing helpers. No Go algorithm implementation was copied. The available reference subset has no license file; this document makes no license claim for that Go repository. Synthetic fixed signing vectors in `Backend/tests/fixtures/signing-vectors.json` record parity without account credentials, anonymous device identities or signed playback URLs.

`modern-provider.mjs` and `modern-index.mjs` were added on 2026-11-06 for this iPhone project, under GPL-3.0-only. They use the official website for metadata/search, the full official detail `vid_list` to bind video IDs to series/content type, fresh anonymous device registration for current App playback, and the pinned N3urda media primitives for CENC Range preparation. The original `provider.mjs` and `index.mjs` remain intact for comparison. No account Cookie, old deployment credential or persistent device identity is supplied. The GET registration can retain only allowlisted anonymous registration cookies in process memory; those cookies are never transferred to POST recovery identities.

The provider requires a compatible H.264/HEVC response with validated source metadata. It rejects unsupported ByteVC2 rather than claiming it can play it on iPhone. Public website restrictions are preserved by the direct Swift client; the bridge uses the upstream anonymous App response and does not call reward, unlock or purchase endpoints.
