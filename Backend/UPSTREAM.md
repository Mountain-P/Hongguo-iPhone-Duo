# Pinned upstream

The files in `server/`, `tests/server.test.mjs`, and `LICENSE` originate from:

- Repository: https://github.com/N3urda/hongguoTV
- Commit: `eea73e6a45569a2cbbb9440f7cd5290c459b0b70`
- License: GPL-3.0-only; see `LICENSE`.
- Original provider source attribution: `server/vendor/NOTICE.md`.

All original copyright notices, comments and license files are retained. The original source files, tests and license files were verified byte-for-byte against the pinned Git blob hashes before local integration. Two upstream files now have narrow local changes: `server/package-lock.json` normalizes Tencent mirror tarball URLs to `registry.npmjs.org` without changing versions or integrity; `server/http.mjs` propagates an optional request AbortSignal to provider operations and fresh media chunks, stopping work on an unfinished client disconnect. Its authorization checks, API shape, Range behavior and error status codes remain intact. The provider's `hongguo.cjs` originates from woshishiq1/drpys commit `22261adfa31435e3b3ef5a730b8a2a75bcaf1715`; see its original header and `server/vendor/LICENSE.drpys`.

The local `package.json`, `scripts/`, `fixtures/`, `.gitignore`, README and documentation were added for this iPhone project on 2026-11-06 under GPL-3.0-only. They provide reproducible launch commands, an explicit source probe, and a synthetic local fixture. No change was made to the pinned provider, signing or media implementation.

The default entry point is now the separately added `server/modern-index.mjs` and `modern-provider.mjs`. Current anonymous playback/signature modules originate from jackotom/hongguo-drama commit `2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0`; their source, local recovery changes and transitive provenance are retained in `server/modern/UPSTREAM.md` and `server/modern/licenses/`. They do not supply account credentials or previously saved device identities. Anonymous registration cookies are allowlisted and held only in memory for the independent GET identity. The adapter uses pinned N3urda pure JSON/CENC helpers but does not call its stale fixed-identity App request functions.

The old entry point remains available as `npm run start:legacy`. The original `server/Dockerfile` and `server/compose.yaml` also launch that legacy entry point. The new root `Dockerfile` and `compose.yaml` launch the current provider; use `docker compose up --build -d` from Backend for ordinary use.

For historical comparison only, the original Docker build context is **this Backend directory**, because the upstream Dockerfile expects both `LICENSE` and `server/` at its context root:

```sh
docker compose -f server/compose.yaml up --build -d
```

This packages the optional Node bridge only; it is not an iPhone App build.
