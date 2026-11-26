import http from 'node:http';
import { timingSafeEqual } from 'node:crypto';
import { byteRange } from '../http.mjs';
import { ExistingLibrary, validID, failure, safeCode } from './library.mjs';
import { RelayCache } from './cache.mjs';

export async function createRelay({ token, jobsFile, mediaRoot, cacheRoot, provider, maxBytes, now = Date.now, onEvent = () => {} }) {
  if (typeof token !== 'string' || token.length < 32 || /\s/.test(token)) throw failure('TOKEN_REQUIRED');
  const library = new ExistingLibrary(jobsFile, mediaRoot);
  await library.refresh();
  const cache = new RelayCache(cacheRoot, { maxBytes, prepare: (id, fresh, context) => provider.stream(id, fresh, context), onEvent });
  await cache.init();
  const details = new Map(), pendingDetails = new Map();
  let refreshInFlight, nextRefresh = now() + 30_000, active = 0, checkRunning = false;
  let lastCheck = { state: 'not-run' };
  const metrics = { plays: 0, libraryHits: 0, cacheHits: 0, sourceHits: 0, bytesSent: 0, failures: 0 };
  function refreshLibrary(force = false) {
    if (refreshInFlight) return refreshInFlight;
    if (!force && now() < nextRefresh) return;
    refreshInFlight = library.refresh().then(() => true, error => {
      onEvent({ event: 'library_refresh_failed', code: safeCode(error) });
      return false;
    }).finally(() => {
      nextRefresh = now() + 30_000;
      refreshInFlight = undefined;
    });
    return refreshInFlight;
  }
  async function sourceDetail(seriesID, signal, episodeID) {
    signal.throwIfAborted();
    const known = details.get(seriesID);
    if (known && known.expires > now() && (!episodeID || known.missCheckedUntil > now()
        || known.value.episodes.some(episode => episode.id === episodeID))) return known.value;
    let pending = pendingDetails.get(seriesID);
    if (!pending) {
      if (pendingDetails.size >= 100) throw failure('RELAY_BUSY', 503);
      // Each waiter owns its cancellation. One disconnected client must not
      // cancel the catalog update that another play request has already joined.
      pending = Promise.resolve().then(() => provider.detail(seriesID, { signal: AbortSignal.timeout(20_000) }))
        .then(value => {
          const entry = { value, expires: now() + 300_000, missCheckedUntil: 0 };
          details.delete(seriesID);
          details.set(seriesID, entry);
          while (details.size > 100) details.delete(details.keys().next().value);
          return entry;
        }).finally(() => pendingDetails.delete(seriesID));
      pendingDetails.set(seriesID, pending);
    }
    const updated = await pending;
    signal.throwIfAborted();
    // A genuine mismatch should not trigger a new catalog request on every tap.
    if (episodeID && !updated.value.episodes.some(episode => episode.id === episodeID)) {
      updated.missCheckedUntil = now() + 5_000;
    }
    return updated.value;
  }
  async function detail(id, signal) {
    return library.series.get(id) || sourceDetail(id, signal);
  }
  async function resolve(episodeID, seriesID, fresh, signal) {
    const saved = await library.stream(episodeID, seriesID);
    if (saved) return saved;
    const savedSeries = library.savedSeries.get(episodeID);
    const owner = seriesID || savedSeries;
    // A completed cache entry for a known saved episode needs no network.
    // Refresh upstream metadata before opening a new source for a damaged copy.
    if (savedSeries && owner === savedSeries) {
      const fallback = await cache.cachedEpisode(episodeID);
      if (fallback) return fallback;
    }
    if (owner) {
      const show = await sourceDetail(owner, signal, episodeID);
      if (!show.episodes.some(episode => episode.id === episodeID)) throw failure('EPISODE_MISMATCH', 409);
    }
    signal.throwIfAborted();
    return cache.resolve(episodeID, fresh);
  }
  function prefetchAfter(stream, seriesID, episodeID) {
    cache.warm(stream).then(async () => {
      if (stream.failed || !seriesID || cache.warming.size >= 1) return;
      const show = library.series.get(seriesID) || details.get(seriesID)?.value;
      const at = show?.episodes.findIndex(e => e.id === episodeID) ?? -1;
      const next = at >= 0 ? show.episodes[at + 1] : null;
      if (!next || library.episodes.has(next.id) || cache.completed.has(next.id)) return;
      const prepared = await resolve(next.id, seriesID, false, AbortSignal.timeout(30_000));
      await cache.warm(prepared);
    }).catch(error => onEvent({ event: 'prefetch_failed', code: safeCode(error) }));
  }
  async function selfCheck({ seriesID, episodeID } = {}) {
    if (checkRunning) return lastCheck;
    checkRunning = true;
    const started = Date.now();
    try {
      if (await refreshLibrary(true) === false) throw failure('LIBRARY_REFRESH_FAILED');
      const selected = episodeID || library.episodes.keys().next().value;
      if (!selected) throw failure('NO_PROBE_MEDIA');
      let stream;
      if (episodeID && seriesID) {
        const show = await provider.detail(seriesID, { signal: AbortSignal.timeout(20_000) });
        if (!show.episodes.some(e => e.id === episodeID)) throw failure('EPISODE_MISMATCH');
        stream = { ...await provider.stream(episodeID, true, { signal: AbortSignal.timeout(30_000) }), origin: 'source' };
      } else { stream = await resolve(selected, seriesID, true, AbortSignal.timeout(30_000)); }
      const bytes = await stream.chunk(0, Math.min(stream.total, 512 * 1024) - 1, { signal: AbortSignal.timeout(20_000) });
      if (bytes.toString('ascii', 4, 8) !== 'ftyp') throw failure('INVALID_MEDIA');
      lastCheck = { state: 'passed', checkedAt: new Date().toISOString(), elapsedMs: Date.now() - started,
                    scope: episodeID && seriesID ? 'live-source-and-mp4-prefix' : 'source-and-mp4-prefix', origin: stream.origin, bytes: bytes.length };
      await cache.warm(stream);
    } catch (error) {
      lastCheck = { state: 'failed', checkedAt: new Date().toISOString(), elapsedMs: Date.now() - started, code: safeCode(error) };
    } finally { checkRunning = false; }
    onEvent({ event: 'self_check', ...lastCheck }); return lastCheck;
  }
  const server = http.createServer(async (req, res) => {
    const json = (status, value) => { res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' }); res.end(JSON.stringify(value)); };
    const actual = Buffer.from(req.headers.authorization || ''), expected = Buffer.from('Bearer ' + token);
    if (actual.length !== expected.length || !timingSafeEqual(actual, expected)) return json(401, { error: '需要有效的中繼口令' });
    const controller = new AbortController();
    const closed = () => { if (!res.writableFinished) controller.abort(); };
    res.once('close', closed);
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(5 * 60_000)]);
    try {
      const url = new URL(req.url, 'http://relay.invalid');
      if (!['GET', 'HEAD'].includes(req.method)) return json(405, { error: 'Method not allowed' });
      const refresh = refreshLibrary();
      // Playback and media ranges always use the last published snapshot.
      if (!url.pathname.startsWith('/api/media/') && !url.pathname.startsWith('/api/episodes/')) await refresh;
      if (url.pathname === '/health') return json(200, { service: 'hongguotv', version: '0.17.0', apiVersion: 1,
        capabilities: ['home-relay-v1', 'existing-library', 'persistent-cache', 'range', 'prefetch'],
        upstream: lastCheck.state, lastCheck, library: { series: library.series.size, episodes: library.episodes.size }, cache: cache.status() });
      if (url.pathname === '/api/status') return json(200, { metrics, cache: cache.status(), lastCheck });
      if (['/api/home', '/api/search'].includes(url.pathname)) {
        const page = Number(url.searchParams.get('page') || 1), q = (url.searchParams.get('q') || '').trim();
        if (!Number.isInteger(page) || page < 1 || page > 100 || q.length > 80 || url.pathname.endsWith('/search') && !q) throw failure('INVALID_QUERY', 400);
        return json(200, library.page(page, q));
      }
      const series = /^\/api\/series\/(\d{1,30})$/.exec(url.pathname);
      if (series) return json(200, await detail(series[1], signal));
      const play = /^\/api\/episodes\/(\d{1,30})\/play$/.exec(url.pathname);
      if (play) {
        const seriesID = url.searchParams.get('series_id') || undefined;
        if (seriesID && !validID(seriesID)) throw failure('INVALID_ID', 400);
        const stream = await resolve(play[1], seriesID, url.searchParams.get('fresh') === '1', signal);
        signal.throwIfAborted(); metrics.plays++;
        metrics[stream.origin === 'library' ? 'libraryHits' : stream.origin === 'cache' ? 'cacheHits' : 'sourceHits']++;
        json(200, { path: '/api/media/' + stream.id + '.mp4', contentType: 'video/mp4', origin: stream.origin, mediaVersion: stream.id });
        prefetchAfter(stream, seriesID, play[1]); return;
      }
      const media = /^\/api\/media\/([a-f0-9]{32,64})\.mp4$/.exec(url.pathname);
      if (!media) return json(404, { error: '接口不存在' });
      const stream = cache.get(media[1]) || await library.media(media[1]);
      if (!stream) return json(410, { error: '播放連結已過期，請重新取源' });
      if (active >= 8) return json(503, { error: '中繼忙碌，請稍後再試' });
      active++;
      try {
        let rangeHeader = req.headers.range;
        const etag = '"' + stream.id + '"';
        if (req.headers['if-range'] && req.headers['if-range'] !== etag) rangeHeader = undefined;
        const range = byteRange(rangeHeader, stream.total);
        if (!range) { res.writeHead(416, { 'Content-Range': `bytes */${stream.total}` }); return res.end(); }
        const [start, end] = range;
        const headers = { 'Content-Type': 'video/mp4', 'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes',
                          'Cache-Control': 'private, no-store', ETag: etag, 'X-Hongguo-Origin': stream.origin };
        if (rangeHeader) headers['Content-Range'] = `bytes ${start}-${end}/${stream.total}`;
        const size = 512 * 1024;
        const first = req.method === 'HEAD' ? null : await stream.chunk(start, Math.min(start + size - 1, end), { signal });
        res.writeHead(rangeHeader ? 206 : 200, headers);
        if (req.method === 'HEAD') return res.end();
        for (let offset = start; offset <= end && !res.destroyed; offset += size) {
          const chunk = offset === start ? first : await stream.chunk(offset, Math.min(offset + size - 1, end), { signal });
          metrics.bytesSent += chunk.length;
          if (!res.write(chunk)) {
            await new Promise(resolve => { const done = () => { res.off('drain', done); res.off('close', done); resolve(); }; res.once('drain', done); res.once('close', done); });
          }
        }
        res.end();
      } finally { active--; }
    } catch (error) {
      if (controller.signal.aborted || res.destroyed) return;
      metrics.failures++;
      const code = safeCode(error);
      onEvent({ event: 'request_failed', code });
      if (res.headersSent) res.destroy();
      else json([400, 401, 403, 404, 409, 410, 429, 503, 507].includes(error.status) ? error.status : 502,
                { error: code === 'EPISODE_MISMATCH' ? '這一集不在這部劇的選集清單中，請重新選集。' : '中繼暫時無法準備影片，請重試', code });
    }
  });
  server.requestTimeout = 45_000; server.headersTimeout = 15_000;
  return { server, library, cache, selfCheck, metrics };
}
