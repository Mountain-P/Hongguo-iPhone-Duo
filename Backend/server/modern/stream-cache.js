// SPDX-License-Identifier: GPL-3.0-only
// Shared preparation with per-client cancellation. Prepared chunks use NEW request signals.
function createPreparedStreamCache(prepare, { ttl = 240000, maxEntries = 16, now = Date.now } = {}) {
    const cache = new Map();
    const pending = new Map();
    const versions = new Map();
    return async function get(id, fresh = false, signal) {
        if (signal?.aborted) throw signal.reason;
        if (fresh) { cache.delete(id); versions.set(id, (versions.get(id) || 0) + 1); }
        const version = versions.get(id) || 0;
        const cached = cache.get(id);
        if (cached?.expires > now()) return cached.value;
        let entry = pending.get(id);
        if (!entry || entry.controller.signal.aborted || entry.version !== version) {
            entry = { controller: new AbortController(), clients: 0, settled: false, version };
            const current = entry;
            entry.promise = Promise.resolve().then(() => prepare(id, { signal: current.controller.signal })).then(value => {
                current.settled = true;
                if (!current.controller.signal.aborted && (versions.get(id) || 0) === current.version) {
                    cache.set(id, { value, expires: now() + ttl });
                    while (cache.size > maxEntries) cache.delete(cache.keys().next().value);
                }
                return value;
            }).finally(() => {
                current.settled = true;
                if (pending.get(id) === current) pending.delete(id);
            });
            entry.promise.catch(() => {});
            pending.set(id, entry);
        }
        entry.clients++;
        return new Promise((resolve, reject) => {
            let finished = false;
            const done = (error, value) => {
                if (finished) return;
                finished = true;
                signal?.removeEventListener('abort', abort);
                entry.clients--;
                if (!entry.clients && !entry.settled) entry.controller.abort(new DOMException('播放准备已取消', 'AbortError'));
                if (error) reject(error); else resolve(value);
            };
            const abort = () => done(signal.reason || new DOMException('播放准备已取消', 'AbortError'));
            signal?.addEventListener('abort', abort, { once: true });
            if (signal?.aborted) abort();
            entry.promise.then(value => done(null, value), error => done(error));
        });
    };
}
module.exports = { createPreparedStreamCache };
