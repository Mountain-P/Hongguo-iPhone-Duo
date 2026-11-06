// SPDX-License-Identifier: GPL-3.0-only
// iPhone integration, 2026-11-06. See modern/UPSTREAM.md for pinned sources.
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import axios from 'axios';
import modern from './modern/app-source.js';
import streamCache from './modern/stream-cache.js';

const SITE = 'https://hongguoduanju.com';
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';
const http = axios.create({ timeout: 15000, maxContentLength: 16 * 1024 * 1024, headers: { 'User-Agent': UA, Referer: SITE + '/', 'Accept-Language': 'zh-CN,zh;q=0.9' } });
// Load only trusted pinned source, exposing its parser and CENC primitives.
// No fixed-identity App/search functions from the old source are called.
const context = vm.createContext({ require: name => { if (name === 'node:crypto') return crypto; throw new Error('Unsupported module'); }, Buffer, URL, URLSearchParams, axios: http });
vm.runInContext(fs.readFileSync(new URL('./vendor/hongguo.cjs', import.meta.url), 'utf8') + '\nthis.media = {extractAssignedJson, prepareCencHeader, decryptPartial};', context, { timeout: 5000 });
const media = context.media;
const episodeContexts = new Map();
const text = value => typeof value === 'string' ? value.trim() : '';
const id = value => { if (typeof value === 'number' && !Number.isSafeInteger(value)) throw new Error('Unsafe numeric identity'); const result = String(value ?? ''); if (!/^\d{1,30}$/.test(result)) throw new Error('Invalid identity'); return result; };
const card = item => {
  const value = item?.video_data && Object.keys(item.video_data).length ? item.video_data : item;
  return { id: id(value.series_id || item.keyword), title: text(value.series_name || value.series_title || item.name),
    cover: text(value.series_cover), description: text(value.series_intro),
    badge: text(value.episode_right_text) || (Number(value.episode_cnt) > 0 ? `共 ${Number(value.episode_cnt)} 集` : ''),
    tags: (Array.isArray(value.tags) ? value.tags : []).filter(value => typeof value === 'string').join('／') };
};
function cards(rows) {
  const seen = new Set();
  return rows.flatMap(row => { try { const value = card(row); if (!value.title || seen.has(value.id)) return []; seen.add(value.id); return [value]; } catch { return []; } });
}
async function siteGet(path, options) {
  for (let attempt = 0; ; attempt++) {
    try { return await http.get(SITE + path, options); }
    catch (error) {
      const transient = Number(error.response?.status) >= 500 || ['ECONNRESET', 'ETIMEDOUT', 'ECONNABORTED'].includes(error.code);
      if (attempt || !transient) throw error;
      await new Promise(resolve => setTimeout(resolve, 400));
    }
  }
}
async function router(path, signal) { return media.extractAssignedJson((await siteGet(path, { responseType: 'text', signal })).data); }

async function prepare(vid, { signal } = {}) {
  const context = episodeContexts.get(vid);
  const source = await modern.fetchAppPlayUrl(vid, { quality: 'auto', signal, contentType: context?.contentType || '1004' });
  if (!['h264', 'avc', 'avc1', 'hevc', 'h265', 'hvc1', 'hev1'].includes(source.codec)) throw Object.assign(new Error('No compatible iPhone codec'), { code: 'NO_COMPATIBLE_SOURCE' });
  const key = source.contentKey ? Buffer.from(source.contentKey, 'hex') : null;
  if (key && key.length !== 16) throw new Error('Invalid content key');
  let knownTotal;
  async function range(start, end, requestSignal) {
    const response = await http.get(source.url, { signal: requestSignal, responseType: 'arraybuffer', headers: { 'User-Agent': source.userAgent || UA, Referer: source.referer || 'https://novel.snssdk.com/', Range: `bytes=${start}-${end}` } });
    let data = Buffer.from(response.data);
    const total = Number(String(response.headers['content-range'] || '').match(/\/(\d+)$/)?.[1] || response.headers['content-length'] || data.length);
    if (response.status === 200) data = data.subarray(start, end + 1);
    const expected = Math.min(end + 1, total) - start;
    if (!Number.isSafeInteger(total) || total <= 0 || data.length !== expected) throw new Error('Invalid media range');
    if (response.status === 206) {
      const bounds = String(response.headers['content-range'] || '').match(/^bytes (\d+)-(\d+)\/(\d+)$/);
      if (!bounds || Number(bounds[1]) !== start || Number(bounds[2]) !== Math.min(end, total - 1)) throw new Error('Mismatched media range');
    }
    if (knownTotal && knownTotal !== total) throw new Error('Media changed during playback');
    knownTotal = total;
    return { data, total };
  }
  const first = await range(0, 256 * 1024 - 1, signal);
  let head = first.data;
  if (head.length < 16 || head.toString('ascii', 4, 8) !== 'ftyp') throw new Error('Invalid MP4');
  const ftypSize = head.readUInt32BE(0);
  if (ftypSize < 8 || ftypSize + 8 > head.length || head.toString('ascii', ftypSize + 4, ftypSize + 8) !== 'moov') throw new Error('Unsupported MP4 layout');
  const moovEnd = ftypSize + head.readUInt32BE(ftypSize);
  if (moovEnd <= ftypSize + 8 || moovEnd > first.total || moovEnd > 8 * 1024 * 1024) throw new Error('Invalid MP4 header');
  if (moovEnd > head.length) head = Buffer.concat([head, (await range(head.length, moovEnd - 1, signal)).data]);
  head = head.subarray(0, moovEnd);
  const prepared = key ? media.prepareCencHeader(head, key) : { header: head, samples: [] };
  // The pinned CENC helper assumes HEVC. Restore AVC sample-entry type when
  // the verified current App model explicitly identifies an H.264 rendition.
  if (key && ['h264', 'avc', 'avc1'].includes(source.codec)) {
    for (let at = 0; (at = head.indexOf(Buffer.from('encv'), at)) >= 0; at += 4) {
      if (at >= 4 && head.readUInt32BE(at - 4) >= 8 && at - 4 + head.readUInt32BE(at - 4) <= head.length) prepared.header.write('avc1', at, 'ascii');
    }
  }
  return { total: first.total, chunk: async (start, end, { signal: chunkSignal } = {}) => media.decryptPartial((await range(start, end, chunkSignal)).data, start, key, prepared) };
}

const preparedStream = streamCache.createPreparedStreamCache(prepare);

export const provider = {
  async home(page = 1, { signal } = {}) {
    const data = await router(`/category/real-drama?page=${page}`, signal);
    const listing = Object.values(data.loaderData || {}).find(value => value?.categoryRoute?.contentType === 'real-drama');
    if (!Array.isArray(listing?.recommendList)) throw new Error('Catalog schema changed');
    return { items: cards(listing.recommendList), page };
  },
  async search(keyword, page = 1, { signal } = {}) {
    const data = (await siteGet('/api/search/result', { signal, params: { aid: '8662', query: keyword, page } })).data;
    if (!Array.isArray(data?.searchList)) throw new Error('Search schema changed');
    return { items: cards(data.searchList), page };
  },
  async detail(seriesId, { signal } = {}) {
    seriesId = id(seriesId);
    const data = await router(`/detail?series_id=${seriesId}`, signal);
    const detail = Object.values(data.loaderData || {}).find(value => String(value?.seriesDetail?.series_id) === seriesId && value.isSuccess !== false)?.seriesDetail;
    if (!Array.isArray(detail?.vid_list) || !detail.vid_list.length) throw new Error('Series unavailable');
    const contentType = String(detail.content_type || '1004');
    if (!/^\d{1,16}$/.test(contentType)) throw new Error('Invalid content type');
    const episodes = Array.from(detail.vid_list, (value, index) => ({ id: id(value), title: `第 ${index + 1} 集`, number: index + 1 }));
    if (new Set(episodes.map(episode => episode.id)).size !== episodes.length) throw new Error('Duplicate episodes');
    // Full authoritative vid_list, never accessible_episode_cnt from the public website.
    for (const episode of episodes) episodeContexts.set(episode.id, { seriesId, contentType });
    while (episodeContexts.size > 10000) episodeContexts.delete(episodeContexts.keys().next().value);
    return { ...card(detail), episodes };
  },
  async stream(episodeId, fresh = false, { signal } = {}) {
    const vid = id(episodeId);
    return preparedStream(vid, fresh, signal);
  },
};
