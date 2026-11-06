// SPDX-License-Identifier: GPL-3.0-only
// Metadata request contract adapted from jackotom/hongguo-drama
// 2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0/src/native/hongguo-app-new.js.
// Local bounded, single-category snapshot. No account, playback, or fallback feed.
'use strict';
const { signedMetadataRequest, requestJson } = require('./app-source');
const API = '/reading/distribution/category/landpage/v/';
const CONFIG = { realDrama: ['default', 'short_play', 1], aiDrama: ['ai_series', 'ai_series', 1004] };
const failure = code => Object.assign(new Error('New release catalogue unavailable'), { code });
const text = (value, max) => typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, max) : '';

function pageBody(config, offset, sessionId) {
    return { filter_ids: '', req_scene: config[0], offset, need_selector_panel: false, limit: 50,
        select_items: { genre: [config[1]], sort: ['online_time'], category_dim_theme: [], category_dim_role: [],
            category_dim_epoch: [], gender: [], online_time: ['days_7'], creation_status: [] },
        session_id: sessionId, req_type: offset ? 'only_content' : 'default', client_req_type: 3 };
}

function cover(value) {
    try {
        const url = new URL(value);
        if (url.protocol !== 'https:' || url.username || url.password || (url.port && url.port !== '443') ||
            !['fqnovelpic.com', 'byteimg.com'].some(host => url.hostname === host || url.hostname.endsWith('.' + host))) return '';
        // Public JPEG variant used by the pinned upstream catalogue adapter.
        if (url.pathname.startsWith('/novel-pic/') && url.pathname.includes('~')) {
            return 'https://p3-novel.byteimg.com' + url.pathname.split('~', 1)[0] + '~tplv-shrink:640:0.image';
        }
        return url.href;
    } catch (_) { return ''; }
}

function card(row, config) {
    if (!row || typeof row !== 'object' || (typeof row.series_id === 'number' && !Number.isSafeInteger(row.series_id))) return null;
    const id = String(row.series_id ?? ''), title = text(row.title || row.series_title || row.series_name, 300);
    if (!/^\d{1,30}$/.test(id) || !title || (row.content_type != null && Number(row.content_type) !== config[2])) return null;
    const labels = [text(row.tag_info?.text, 160), ...(Array.isArray(row.sub_title_list) ? row.sub_title_list.map(item => text(item?.content, 160)) : [])].filter(Boolean);
    const count = Number(row.episode_cnt);
    return { id, title, cover: cover(row.cover), description: text(row.video_desc || row.series_intro, 2000),
        episodeCount: Number.isSafeInteger(count) && count > 0 && count <= 5000 ? count : 0,
        tags: [...new Set(labels.filter(value => value !== '新剧' && value !== '今日上新'))].slice(0, 4),
        statusText: labels.includes('今日上新') ? '今日上新' : labels.includes('新剧') ? '新剧' : '' };
}

async function defaultRequest(signed, deadline, signal) {
    return requestJson(signed.url, { method: 'POST', headers: signed.headers, data: signed.body,
        preserveLargeIntegerFields: ['series_id'], forbidRedirects: true }, deadline, signal);
}

async function fetchNewReleases(category, options = {}) {
    if (!Object.hasOwn(CONFIG, category)) throw failure('APP_INPUT');
    const config = CONFIG[category], controller = new AbortController();
    const budget = Math.max(1, Math.min(8000, Number(options.budgetMS) || 8000));
    const deadline = Date.now() + budget, request = options.request || defaultRequest;
    const timer = setTimeout(() => controller.abort(new DOMException('Timeout', 'TimeoutError')), budget);
    const external = options.signal;
    const abort = () => controller.abort(external.reason);
    if (external?.aborted) abort(); else external?.addEventListener('abort', abort, { once: true });
    const items = [], seen = new Set();
    let offset = 0, sessionId = '';
    try {
        for (let page = 0; page < 2; page++) {
            if (controller.signal.aborted) throw controller.signal.reason;
            if (Date.now() >= deadline) throw failure('ETIMEDOUT');
            const signed = signedMetadataRequest(API, {}, pageBody(config, offset, sessionId));
            const payload = await request(signed, deadline, controller.signal);
            if (controller.signal.aborted) throw controller.signal.reason;
            if (Date.now() >= deadline) throw failure('ETIMEDOUT');
            if (!payload || typeof payload !== 'object' || !Object.hasOwn(payload, 'code')) throw failure('APP_SCHEMA');
            if (Number(payload.code) !== 0) throw failure('APP_BUSINESS');
            const data = payload.data;
            if (!data || !Array.isArray(data.video_data) || data.video_data.length > 50) throw failure('APP_SCHEMA');
            const cards = data.video_data.map(row => card(row, config)).filter(Boolean);
            if (data.video_data.length && !cards.length) throw failure('APP_SCHEMA');
            for (const item of cards) if (!seen.has(item.id)) { seen.add(item.id); items.push(item); }
            if (data.has_more !== true || page === 1) break;
            const next = Number(data.next_offset);
            if (!Number.isSafeInteger(next) || next <= offset || typeof data.session_id !== 'string' || !data.session_id || data.session_id.length > 4096) throw failure('APP_CURSOR');
            offset = next; sessionId = data.session_id;
        }
        return { items };
    } finally {
        clearTimeout(timer); external?.removeEventListener('abort', abort);
    }
}

module.exports = { fetchNewReleases };
