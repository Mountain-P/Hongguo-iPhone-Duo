// SPDX-License-Identifier: GPL-3.0-only
// Native Passport transport using the existing GPL signing/registration primitives.
// Request fields and mode-4 vectors are independently expressed protocol facts;
// no phone number, code, credential, or signed request is logged.
'use strict';
const { signedNativePhoneRequest, preserveLargeJsonIntegers, requestJson } = require('./app-source');
const { registerPlaybackDevice } = require('./playback-device');
const crypto = require('node:crypto');
const allowedCookies = new Set(['sessionid', 'sessionid_ss', 'sid_tt', 'sid_guard', 'uid_tt', 'uid_tt_ss', 'passport_csrf_token',
    'passport_csrf_token_default', 'passport_auth_status', 'passport_auth_status_ss', 'ttwid', 's_v_web_id', 'tt_scid', 'store-region',
    'store-region-src', 'store-region-sign', 'install_id', 'odin_tt', 'ttreq', 'sid_ucp_v1', 'ssid_ucp_v1', 'passport_status']);
const failure = (code, extra) => Object.assign(new Error('Native phone authentication unavailable'), { code, ...extra });
const validID = value => typeof value === 'string' && /^\d{1,30}$/.test(value) && /[1-9]/.test(value);
const xor = value => Buffer.from(value, 'utf8').map(byte => byte ^ 5).toString('hex');
const encode = value => encodeURIComponent(String(value)).replace(/[!'()*]/g, char => '%' + char.charCodeAt(0).toString(16).toUpperCase()).replace(/%20/g, '+');
const form = value => Object.keys(value).sort().map(key => encode(key) + '=' + encode(value[key])).join('&');

function cookieMap(value) {
    const result = {};
    if (value && typeof value === 'object' && !Array.isArray(value)) {
        for (const [name, entry] of Object.entries(value).slice(0, 32)) {
            if (allowedCookies.has(name) && typeof entry === 'string' && entry.length <= 4096 && !/[\x00-\x20\x7f;"\\]/.test(entry)) result[name] = entry;
        }
    }
    return result;
}
function cookieHeader(value) { return Object.keys(value).sort().filter(name => value[name]).map(name => name + '=' + value[name]).join('; '); }
function mergeCookies(value, headers) {
    const entries = headers?.['set-cookie'];
    for (const line of (Array.isArray(entries) ? entries : entries ? [entries] : []).slice(0, 32)) {
        if (typeof line !== 'string' || line.length > 8192) continue;
        const pair = line.split(';', 1)[0], at = pair.indexOf('=');
        if (at < 1) continue;
        const name = pair.slice(0, at).trim(), raw = pair.slice(at + 1).trim();
        const accepted = cookieMap({ [name]: raw });
        if (Object.hasOwn(accepted, name)) { if (raw) value[name] = raw; else delete value[name]; }
    }
}
function identity(device) {
    if (!device || !validID(device.deviceID) || !validID(device.installID) || typeof device.cdid !== 'string' ||
        !/^[a-f0-9-]{36}$/i.test(device.cdid) || typeof device.openUDID !== 'string' || !/^[a-f0-9]{16}$/i.test(device.openUDID)) throw failure('INVALID_INPUT');
    return { device_id: device.deviceID, iid: device.installID, cdid: device.cdid, openudid: device.openUDID };
}

async function phoneAuth(request, options = {}) {
    if (!request || !['register', 'sendCode', 'loginSMS', 'verifyMFA', 'validate', 'logout'].includes(request.operation)) throw failure('INVALID_INPUT');
    if (request.operation === 'validate') throw failure('UNSUPPORTED_VALIDATION');
    if (request.operation === 'logout') return { device: request.device || null, payload: {}, cookies: {}, token: '' };
    const controller = new AbortController(), deadline = Date.now() + 15000;
    const timer = setTimeout(() => controller.abort(new DOMException('Timeout', 'TimeoutError')), 15000);
    const external = options.signal, abort = () => controller.abort(external.reason);
    if (external?.aborted) abort(); else external?.addEventListener('abort', abort, { once: true });
    try {
        if (controller.signal.aborted) throw controller.signal.reason;
        if (request.operation === 'register') {
            const registered = await registerPlaybackDevice(requestJson, { isolated: true, captureCookies: true, accountProfile: true, deadline, signal: controller.signal });
            const cookies = {};
            for (const pair of (registered.cookie || '').split(';')) { const at = pair.indexOf('='); if (at > 0) Object.assign(cookies, cookieMap({ [pair.slice(0, at).trim()]: pair.slice(at + 1).trim() })); }
            cookies.install_id = registered.iid;
            const device = { deviceID: registered.device_id, installID: registered.iid, cdid: registered.cdid, clientUDID: registered.clientudid,
                openUDID: registered.openudid, createdAtMilliseconds: registered.createdAtMilliseconds, registrationCookies: cookies };
            return { device, payload: {}, cookies, token: '' };
        }
        const device = request.device, appIdentity = identity(device);
        if (typeof request.phone !== 'string' || !/^\+[1-9]\d{6,14}$/.test(request.phone)) throw failure('INVALID_INPUT');
        const wire = request.wirePhone || request.phone;
        if (typeof wire !== 'string' || wire.length > 64 || !/^\+[0-9 ]+$/.test(wire)) throw failure('INVALID_INPUT');
        // +886 must be matched before +86, including a source-supported leading-zero local number.
        const mode = request.phone.startsWith('+86') && !request.phone.startsWith('+886') ? 0 : 4;
        let path, values;
        if (request.operation === 'verifyMFA') {
            const m = request.mfa;
            if (!m || !['encryptUID', 'codeKey'].every(key => typeof m[key] === 'string' && m[key].length > 0 && m[key].length <= 4096 && !/[\r\n]/.test(m[key])) ||
                typeof m.logID !== 'string' || m.logID.length > 4096 || /[\r\n]/.test(m.logID)) throw failure('INVALID_INPUT');
            path = '/passport/upsms/verify/';
            values = { encrypt_uid: m.encryptUID, verify_ticket: '', verify_scene: 'sms_login', verify_reason: 'ato', copywriting_key: 'sms_login',
                ies_safety_diversion_tag: 'mfa', new_verify_flow: '', new_authn_sdk_version: '1.1.31', new_authn_sdk_verify_reason: 'ato',
                new_authn_sdk_verify_scene: 'sms_login', request_tag_from: 'h5', biz_params: JSON.stringify({ passport_mfa_retry_tag: '1', sms_code_key: m.codeKey }),
                new_authn_sdk_log_id: m.logID };
        } else {
            values = { mobile: xor(wire), account_sdk_source: 'app', passport_support_flow: 'captcha,verify', mix_mode: '1' };
            if (request.operation === 'sendCode') {
                path = '/passport/mobile/send_code/v1/'; Object.assign(values, { auto_read: '0', unbind_exist: '34', type: xor('24') });
            } else {
                if (typeof request.code !== 'string' || !/^\d{4,8}$/.test(request.code)) throw failure('INVALID_INPUT');
                path = '/passport/mobile/sms_login/'; values.code = xor(request.code);
                if (request.ticket) {
                    if (typeof request.ticket !== 'string' || request.ticket.length > 4096 || /[\r\n]/.test(request.ticket)) throw failure('INVALID_INPUT');
                    values.passport_mfa_retry_tag = '1'; values.sms_code_key = xor(request.ticket);
                }
            }
        }
        const signed = signedNativePhoneRequest(path, appIdentity, form(values), mode), url = new URL(signed.url);
        if (url.protocol !== 'https:' || url.hostname !== 'api5-normal-lq.fqnovel.com' || url.username || url.password || url.port) throw failure('SECURITY_BLOCKED');
        const cookies = { ...cookieMap(device.registrationCookies), ...cookieMap(request.cookies) }, headers = { ...signed.headers };
        const cookie = cookieHeader(cookies); if (cookie) headers.Cookie = cookie;
        let token = typeof request.token === 'string' && request.token.length <= 8192 && !/[\r\n]/.test(request.token) ? request.token : '';
        if (token) headers['X-Tt-Token'] = token;
        const response = await (options.transport || require('axios'))({ url: signed.url, method: 'POST', headers, data: signed.body,
            timeout: Math.max(1, deadline - Date.now()), signal: controller.signal, maxRedirects: 0 });
        if (controller.signal.aborted) throw controller.signal.reason;
        if (response.status !== 200) {
            const retry = Number(response.headers?.['retry-after']);
            throw failure('HTTP_ERROR', { status: response.status, ...(Number.isInteger(retry) && retry >= 0 && retry <= 3600 ? { retryAfter: retry } : {}) });
        }
        if (typeof response.data !== 'string' || response.data.length > 2 * 1024 * 1024) throw failure('INVALID_RESPONSE');
        let payload;
        try { payload = JSON.parse(preserveLargeJsonIntegers(response.data, ['user_id', 'user_id_str', 'device_id', 'install_id'])); } catch (_) { throw failure('INVALID_RESPONSE'); }
        if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw failure('INVALID_RESPONSE');
        mergeCookies(cookies, response.headers);
        const next = response.headers?.['x-tt-token'];
        if (typeof next === 'string' && next.length <= 8192 && !/[\r\n]/.test(next)) token = next;
        return { device, payload, cookies, token };
    } finally { clearTimeout(timer); external?.removeEventListener('abort', abort); }
}

module.exports = { phoneAuth };
