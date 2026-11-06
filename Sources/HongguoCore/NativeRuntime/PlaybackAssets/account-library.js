// SPDX-License-Identifier: GPL-3.0-only
// Local account-library adapter. Read-session profile/signing derives from
// jackotom/hongguo-drama 2bab5cf15529ece7bfe657f93c6d1a2a4a17fef0.
// Favorites/progress JSON contracts were independently rewritten from the
// inspected Quest source; no Go signing implementation is copied.
'use strict';
const { signedAccountLibraryRequest, requestJson } = require('./app-source');
const HOST = 'api5-normal-lq.fqnovel.com';
const fail = (code, extra) => Object.assign(new Error('Account library request failed'), { code, ...extra });
const id = value => typeof value === 'string' && /^\d{1,30}$/.test(value) && /[1-9]/.test(value);
const str = (value, limit = 300) => typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, limit) : '';
const number = value => typeof value === 'boolean' || value == null || value === '' ? NaN : Number(value);
function timestamp(value) {
    let n = number(value);
    if (Number.isFinite(n) && n > 0 && n < 100000000000) n *= 1000;
    return Number.isSafeInteger(n) && n > 0 && n <= 4102444800000 ? n : null;
}
function image(value) {
    try {
        const u = new URL(value);
        if (u.protocol !== 'https:' || u.username || u.password || (u.port && u.port !== '443') || String(value).length > 8192) return '';
        if (u.pathname.startsWith('/novel-pic/') && u.pathname.includes('~') && /\.(?:byteimg|fqnovelpic)\.com$/.test('.' + u.hostname)) {
            return 'https://p3-novel.byteimg.com' + u.pathname.split('~', 1)[0] + '~tplv-shrink:640:0.image';
        }
        return u.href;
    } catch (_) { return ''; }
}
function item(row, favorite = false) {
    if (!row || typeof row !== 'object') throw fail('INVALID_RESPONSE');
    const seriesID = row.book_id_str ?? row.series_id ?? row.book_id;
    if (!id(seriesID)) throw fail('INVALID_RESPONSE');
    const episode = number(row.vid_index), episodeID = row.vid ?? row.item_id ?? '';
    const milliseconds = value => { const n = number(value); return Number.isFinite(n) && n >= 0 && n <= 86400000 ? n / 1000 : 0; };
    const count = number(row.episode_cnt ?? row.episode_count);
    const tags = (Array.isArray(row.tags) ? row.tags : Array.isArray(row.category_list) ? row.category_list : [])
        .map(value => str(typeof value === 'string' ? value : value?.name, 160)).filter(Boolean).slice(0, 8);
    return { series: { id: seriesID, title: str(row.series_title || row.book_name || row.series_name),
        cover: image(row.series_cover_url || row.thumb_url || row.series_cover || row.cover), description: str(row.series_intro, 2000),
        badge: Number.isSafeInteger(count) && count > 0 && count <= 10000 ? count + ' 集' : '', tags },
        episodeID: id(episodeID) ? episodeID : '', episodeNumber: Number.isSafeInteger(episode) && episode > 0 && episode <= 10000 ? episode : 0,
        positionSeconds: milliseconds(row.current_play_position ?? row.current_play_time), durationSeconds: milliseconds(row.duration ?? row.current_total_time),
        updatedAtMilliseconds: favorite ? null : timestamp(row.read_timestamp_ms ?? row.last_watch_time),
        collectedAtMilliseconds: favorite ? timestamp(row.collect_time) : null };
}
function validate(request) {
    if (!request || !id(request.accountID) || typeof request.cookie !== 'string' || request.cookie.length > 32768 || /[\r\n]/.test(request.cookie) ||
        (!request.cookie && !request.token) || (request.token != null && (typeof request.token !== 'string' || request.token.length > 8192 || !/^[\x21-\x7e]+$/.test(request.token))) ||
        !['history', 'favorites', 'favorite', 'progress'].includes(request.operation)) throw fail('INVALID_INPUT');
    if (request.operation === 'favorite' && (!id(request.seriesID) || typeof request.favorite !== 'boolean')) throw fail('INVALID_INPUT');
    if (request.operation === 'progress') {
        const p = request.progress;
        if (!p || !id(p.seriesID) || !id(p.episodeID) || !Number.isSafeInteger(p.episodeNumber) || p.episodeNumber < 1 || p.episodeNumber > 10000 ||
            !Number.isSafeInteger(p.episodeCount) || p.episodeCount < 0 || p.episodeCount > 10000 ||
            !Number.isSafeInteger(p.seasonIndex) || p.seasonIndex < 0 || p.seasonIndex > 10000 || typeof p.isMultiSeason !== 'boolean' ||
            !Number.isFinite(p.positionSeconds) || p.positionSeconds < 0 || p.positionSeconds > 86400 ||
            !Number.isFinite(p.durationSeconds) || p.durationSeconds < 0 || p.durationSeconds > 86400 ||
            !Number.isSafeInteger(p.watchedAtMilliseconds) || p.watchedAtMilliseconds < 946684800000 || p.watchedAtMilliseconds > 4102444800000) throw fail('INVALID_INPUT');
    }
}
async function nativeRequest(signed, method, deadline, signal, cookie, token) {
    const url = new URL(signed.url);
    if (url.protocol !== 'https:' || url.hostname !== HOST || url.username || url.password || (url.port && url.port !== '443')) throw fail('SECURITY_BLOCKED');
    return requestJson(signed.url, { method, headers: { ...signed.headers, ...(cookie ? { Cookie: cookie } : {}), ...(token ? { 'X-Tt-Token': token } : {}) }, data: signed.body,
        forbidRedirects: true, preserveLargeIntegerFields: ['book_id', 'series_id', 'vid', 'video_id', 'item_id'] }, deadline, signal);
}
function accepted(payload) {
    if (!payload || typeof payload !== 'object' || (payload.code !== 0 && payload.code !== '0') ||
        (payload.error_code != null && Number(payload.error_code) !== 0)) throw fail('BUSINESS_REJECTED');
    const data = payload.data;
    if (data && typeof data === 'object' && ((data.error_code != null && Number(data.error_code) !== 0) || (data.code != null && Number(data.code) !== 0))) throw fail('BUSINESS_REJECTED');
    return payload;
}

async function accountLibrary(request, options = {}) {
    validate(request);
    const controller = new AbortController(), budget = Math.max(1, Math.min(20000, Number(options.budgetMS) || 20000));
    const deadline = Date.now() + budget, timer = setTimeout(() => controller.abort(new DOMException('Timeout', 'TimeoutError')), budget);
    const external = options.signal, abort = () => controller.abort(external.reason);
    if (external?.aborted) abort(); else external?.addEventListener('abort', abort, { once: true });
    let historyAccepted = false;
    const check = () => { if (controller.signal.aborted) throw controller.signal.reason; if (Date.now() >= deadline) throw fail('ETIMEDOUT'); };
    try {
        check();
        // Registration never receives the account cookie. One profile is retained for this entire operation.
        const identity = request.identity || options.identity;
        if (!identity) throw fail('INVALID_INPUT');
        const send = async (method, path, query = {}, body = null) => {
            check();
            const signed = signedAccountLibraryRequest(method, path, query, identity, body);
            const response = accepted(await (options.request || nativeRequest)(signed, method, deadline, controller.signal, request.cookie, request.token));
            if (method === 'POST' && path === '/reading/bookapi/read_history/update/v') historyAccepted = true;
            check(); return response;
        };
        if (request.operation === 'history') {
            let offset = 0, complete = false, pagesRead = 0;
            const records = new Map(), pages = new Set();
            for (let page = 0; page < 10; page++) {
                const payload = await send('GET', '/reading/bookapi/read_history/list/v', { book_type: '2', limit: '0', offset: String(offset),
                    last_min_read_timestamp_ms: '0', full_field: 'false', is_first_load: String(offset === 0), query_soft_deleted: 'false' });
                const data = payload.data, rows = data?.data_list;
                if (!Array.isArray(rows) || rows.length > 500) throw fail('INVALID_RESPONSE');
                pagesRead++;
                const fingerprint = JSON.stringify(rows.map(row => [row?.book_id_str ?? row?.book_id, row?.vid, row?.read_timestamp_ms]));
                if (rows.length && pages.has(fingerprint)) throw fail('INVALID_CURSOR');
                pages.add(fingerprint);
                for (const row of rows) {
                    if (row?.is_delete === true) continue;
                    const value = item(row), old = records.get(value.series.id);
                    if (!old || (value.updatedAtMilliseconds || 0) > (old.updatedAtMilliseconds || 0)) records.set(value.series.id, value);
                }
                if (data.has_more !== true) { complete = data.has_more === false; break; }
                if (!rows.length) throw fail('INVALID_CURSOR');
                const next = number(data.next_offset);
                offset = Number.isSafeInteger(next) && next > offset ? next : offset + 500;
            }
            return { items: [...records.values()].sort((a, b) => (b.updatedAtMilliseconds || 0) - (a.updatedAtMilliseconds || 0)), isComplete: complete, pagesRead };
        }
        if (request.operation === 'favorites') {
            const payload = await send('GET', '/reading/bookapi/bookshelf/video/list/v', { target_user_id: request.accountID });
            const rows = payload.data?.video_shelf_info;
            if (!Array.isArray(rows) || rows.length > 5000) throw fail('INVALID_RESPONSE');
            const records = new Map();
            for (const row of rows) { const value = item(row, true); if (!records.has(value.series.id)) records.set(value.series.id, value); }
            return { items: [...records.values()], isComplete: payload.data.has_more === false, pagesRead: 1 };
        }
        if (request.operation === 'favorite') {
            await send('POST', '/reading/bookapi/bookshelf/video/update/v', {}, { is_cancelled: false,
                shark_extra: { enter_from: '0', previous_page: '0', page_list: '0', is_active_behavior: '1', inactive_type: '0' },
                update_bookshelf_video_list: [{ book_id: request.seriesID, book_type: 2, modify_time: Date.now(), video_shelf_operate_type: request.favorite ? 0 : 1 }] });
            return { acknowledged: true };
        }
        const p = request.progress, millis = value => Math.trunc(value * 1000);
        const row = { book_id: p.seriesID, book_type: 2, vid: p.episodeID, vid_index: p.episodeNumber, chapter_index: 0,
            current_play_position: millis(p.positionSeconds), player_accumulate_total_time: millis(p.positionSeconds),
            read_timestamp_ms: p.watchedAtMilliseconds, update_timestamp_ms: p.watchedAtMilliseconds, is_delete: false, is_interactive_game: false,
            is_listen_mode: false, is_multi_season: p.isMultiSeason ? 1 : 0, season_index: p.seasonIndex, duration: millis(p.durationSeconds),
            episode_cnt: p.episodeCount, digged_count: 0, user_digg: false, origin_novel_book_id: 0, recent_reads: 0, retain_video_play_time: 0,
            series_play_cnt: 0, tone_id: 0, use_soft_delete: false, meet_guide_comment_tag: false, user_playlet_comment_flag: false };
        // Preserve numeric wire IDs exactly without converting 64-bit identifiers to JavaScript Number.
        const historyBody = JSON.stringify({ update_datas: [row] }).replace(/"(book_id|vid)":"(\d{1,30})"/g, '"$1":$2');
        await send('POST', '/reading/bookapi/read_history/update/v', {}, historyBody);
        historyAccepted = true;
        await send('POST', '/reading/bookapi/read_progress/upload/v', {}, { books: [{ book_id: p.seriesID, book_type: 2, item_id: p.episodeID,
            vid_index: p.episodeNumber, current_play_time: millis(p.positionSeconds), player_cumulative_total_duration: millis(p.positionSeconds),
            read_timestamp_ms: p.watchedAtMilliseconds, progress_type: 0, channel_id: 0, cur_channel_id: 0, check_timestamp: false,
            is_listen_mode: false, is_local_book: false, listen_and_read: false, page_index: 0, page_progress_rate: 0, paragraph_offset: 0, tone_id: 0 }] });
        return { acknowledged: true };
    } catch (error) {
        if (historyAccepted) error.historyAccepted = true;
        throw error;
    } finally { clearTimeout(timer); external?.removeEventListener('abort', abort); }
}

module.exports = { accountLibrary };
