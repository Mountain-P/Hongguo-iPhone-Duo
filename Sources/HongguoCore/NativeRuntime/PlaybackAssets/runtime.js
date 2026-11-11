// SPDX-License-Identifier: GPL-3.0-only
// Local host adapters for the licensed CommonJS modules. No downloaded code runs.
(function (global) {
    'use strict';
    const modules = Object.create(null);
    const sources = global.__moduleSources;
    function native(op, args) {
        const result = JSON.parse(global._nativeInvoke(op, JSON.stringify(args || {})));
        if (result.error) throw Object.assign(new Error('Native operation failed'), { code: result.error });
        return result.value;
    }
    global.require = function require(name) {
        name = name.replace(/^\.\//, '').replace(/\.js$/, '');
        if (name === 'node:crypto') return crypto;
        if (name === 'node:zlib') return { gzipSync: data => Buffer.from(native('gzip', { data: Buffer.from(data).toString('base64') }), 'base64') };
        if (name === 'axios') return axios;
        if (modules[name]) return modules[name].exports;
        const source = sources[name];
        if (typeof source !== 'string') throw new Error('Unsupported bundled module');
        const module = { exports: {} }; modules[name] = module;
        new Function('module', 'exports', 'require', source)(module, module.exports, global.require);
        return module.exports;
    };
    global.Buffer = global.require('buffer').Buffer;
    const originalToString = Buffer.prototype.toString;
    Buffer.prototype.toString = function (encoding, start, end) {
        if (encoding === 'base64url') return originalToString.call(this, 'base64', start, end).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
        return originalToString.call(this, encoding, start, end);
    };
    const crypto = {
        randomBytes: count => Buffer.from(native('random', { count }), 'base64'),
        randomUUID: () => native('uuid'),
        createHash: algorithm => {
            const chunks = [];
            const hash = { update(value) { chunks.push(Buffer.from(value)); return hash; },
                digest(encoding) { const result = Buffer.from(native('hash', { algorithm, data: Buffer.concat(chunks).toString('base64') }), 'base64'); return encoding ? result.toString(encoding) : result; } };
            return hash;
        },
        createCipheriv: (algorithm, key, iv) => cipher(algorithm, key, iv, false),
        createDecipheriv: (algorithm, key, iv) => cipher(algorithm, key, iv, true),
    };
    function cipher(algorithm, key, iv, decrypt) {
        const chunks = []; let padding = true;
        const result = { setAutoPadding(value) { padding = value; return result; },
            update(value) { chunks.push(Buffer.from(value)); return Buffer.alloc(0); },
            final() { return Buffer.from(native('cipher', { algorithm, key: Buffer.from(key).toString('base64'), iv: Buffer.from(iv || []).toString('base64'),
                data: Buffer.concat(chunks).toString('base64'), decrypt, padding }), 'base64'); } };
        return result;
    }
    global.URL = class URL {
        constructor(value, base) { Object.assign(this, native('url', { value: String(value), ...(base ? { base: String(base) } : {}) })); this.searchParams = new URLSearchParams(this.search); }
        toString() { return this.href; }
    };
    global.URLSearchParams = class URLSearchParams {
        constructor(value) { this.entries = String(value || '').replace(/^\?/, '').split('&').filter(Boolean).map(row => { const at = row.indexOf('='); return [decodeURIComponent(at < 0 ? row : row.slice(0, at)), decodeURIComponent((at < 0 ? '' : row.slice(at + 1)).replace(/\+/g, ' '))]; }); }
        get(name) { return this.entries.find(row => row[0] === name)?.[1] ?? null; }
        has(name) { return this.entries.some(row => row[0] === name); }
    };
    let timerID = 0; const timers = new Map();
    global.setTimeout = (callback, delay, ...args) => { const id = ++timerID; timers.set(id, () => callback(...args)); global._nativeSchedule(id, Math.max(0, Number(delay) || 0)); return id; };
    global.clearTimeout = id => { timers.delete(id); global._nativeClearTimer(id); };
    global.__timerFire = id => { const callback = timers.get(id); timers.delete(id); callback?.(); };
    global.DOMException = class DOMException extends Error { constructor(message, name = 'Error') { super(message); this.name = name; this.code = name === 'TimeoutError' ? 'ETIMEDOUT' : 'ABORT_ERR'; } };
    global.AbortSignal = class AbortSignal {
        constructor() { this.aborted = false; this.reason = undefined; this.listeners = new Set(); }
        addEventListener(type, callback) { if (type === 'abort') this.listeners.add(callback); }
        removeEventListener(type, callback) { if (type === 'abort') this.listeners.delete(callback); }
        static timeout(delay) { const controller = new AbortController(); setTimeout(() => controller.abort(new DOMException('Timeout', 'TimeoutError')), delay); return controller.signal; }
        static any(signals) { const controller = new AbortController(); for (const signal of signals) { if (signal.aborted) { controller.abort(signal.reason); break; } signal.addEventListener('abort', () => controller.abort(signal.reason)); } return controller.signal; }
    };
    global.AbortController = class AbortController {
        constructor() { this.signal = new AbortSignal(); }
        abort(reason = new DOMException('Cancelled', 'AbortError')) { if (this.signal.aborted) return; this.signal.aborted = true; this.signal.reason = reason; for (const listener of [...this.signal.listeners]) listener(); this.signal.listeners.clear(); }
    };
    let requestID = 0; const pending = new Map();
    function axios(options) {
        return new Promise((resolve, reject) => {
            const id = String(++requestID), signal = options.signal;
            if (signal?.aborted) { reject(signal.reason); return; }
            const abort = () => { pending.delete(id); global._nativeCancelHTTP(id); reject(signal.reason); };
            pending.set(id, { resolve, reject, signal, abort });
            signal?.addEventListener('abort', abort, { once: true });
            global._nativeHTTP(id, JSON.stringify({ url: options.url, method: options.method || 'GET', headers: options.headers || {},
                timeout: options.timeout, ...(options.data ? { body: Buffer.from(options.data).toString('base64') } : {}) }));
        });
    }
    global.__httpDone = (id, text) => {
        const entry = pending.get(id); if (!entry) return;
        pending.delete(id); entry.signal?.removeEventListener('abort', entry.abort);
        const response = JSON.parse(text);
        if (response.error) entry.reject(Object.assign(new Error('Native network request failed'), { code: response.error }));
        else entry.resolve(response);
    };
    let controller;
    global.__cancelResolve = () => controller?.abort();
    global.__startPhoneAuth = request => {
        controller = new AbortController();
        global.require('native-phone-auth').phoneAuth(request, { signal: controller.signal }).then(value => {
            global._nativeComplete(JSON.stringify(value));
        }, error => {
            const code = String(error.code || error.name || 'ERR_NETWORK');
            global._nativeComplete(JSON.stringify({ error: /^[A-Z][A-Z0-9_]{0,40}$/.test(code) ? code : 'ERR_NETWORK',
                ...(Number.isInteger(error.status) && error.status >= 300 && error.status <= 599 ? { status: error.status } : {}),
                ...(Number.isInteger(error.retryAfter) && error.retryAfter >= 0 && error.retryAfter <= 3600 ? { retryAfter: error.retryAfter } : {}) }));
        });
    };
    function accountFailure(error) {
        const code = String(error.code || error.name || 'ERR_NETWORK');
        global._nativeComplete(JSON.stringify({ error: /^[A-Z][A-Z0-9_]{0,40}$/.test(code) ? code : 'ERR_NETWORK',
            ...(Number.isInteger(error.status) && error.status >= 400 && error.status <= 599 ? { status: error.status } : {}),
            ...(error.historyAccepted === true ? { historyAccepted: true } : {}) }));
    }
    global.__startAccountLibrary = request => {
        controller = new AbortController();
        global.require('account-library').accountLibrary(request, { signal: controller.signal }).then(value => {
            global._nativeComplete(JSON.stringify(value));
        }, accountFailure);
    };
    global.__startNewReleases = category => {
        controller = new AbortController();
        global.require('new-releases').fetchNewReleases(category, { signal: controller.signal }).then(value => {
            global._nativeComplete(JSON.stringify(value));
        }, error => {
            const code = String(error.code || error.name || 'ERR_NETWORK');
            global._nativeComplete(JSON.stringify({ error: /^[A-Z][A-Z0-9_]{0,40}$/.test(code) ? code : 'ERR_NETWORK',
                ...(Number.isInteger(error.status) && error.status >= 400 && error.status <= 599 ? { status: error.status } : {}) }));
        });
    };
    global.__startResolve = (episodeID, contentType, preference = 'automatic') => {
        if (!['automatic', 'dataSaver'].includes(preference)) {
            global._nativeComplete(JSON.stringify({ error: 'APP_INPUT' }));
            return;
        }
        controller = new AbortController();
        global.require('app-source').fetchAppPlayUrl(episodeID, { contentType, quality: 'auto', playbackQuality: preference, signal: controller.signal }).then(source => {
            global._nativeComplete(JSON.stringify({ url: source.url, contentKey: source.contentKey, userAgent: source.userAgent,
                codec: source.codec, quality: source.quality, preference, qualityFallback: source.qualityFallback === true,
                width: source.width, height: source.height }));
        }, error => {
            const status = Number(error.status);
            const registrationFailure = error.registrationFailure;
            let code = String(error.code || 'SOURCE_UNAVAILABLE');
            if (Number.isInteger(status) && status >= 400 && status <= 599) code = `HTTP_${status}`;
            else if (['HTTP_401', 'HTTP_403', 'HTTP_429', 'BUSINESS_REJECTED', 'SECURITY_BLOCKED'].includes(registrationFailure)) {
                code = registrationFailure;
            }
            global._nativeComplete(JSON.stringify({ error: code }));
        });
    };
})(globalThis);
