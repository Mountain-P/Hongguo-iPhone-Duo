import fs from 'node:fs/promises';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import { fileStream, validID, failure, safeCode } from './library.mjs';

const CHUNK = 512 * 1024;
const MAX_FILE = 256 * 1024 * 1024;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

function transientRead(error) {
  const status = error.status ?? error.response?.status;
  if (status) return [408, 429, 500, 502, 503, 504].includes(status);
  return ['ECONNRESET', 'ECONNREFUSED', 'ETIMEDOUT', 'ECONNABORTED', 'EAI_AGAIN',
        'ENETUNREACH', 'EHOSTUNREACH', 'ERR_NETWORK', 'ERR_CANCELED'].includes(error.code)
    || error.name === 'TimeoutError';
}

/// Each preparation has a unique immutable media URL. No cache bytes are shared
/// across re-resolved renditions, even if their episode ID and byte length match.
export class RelayCache {
  constructor(root, { maxBytes = 2 * 1024 ** 3, prepare, onEvent = () => {} } = {}) {
    if (!Number.isSafeInteger(maxBytes) || maxBytes < 1024 * 1024) throw failure('INVALID_CACHE_LIMIT');
    this.root = root; this.maxBytes = maxBytes; this.prepare = prepare; this.onEvent = onEvent;
    this.completed = new Map(); this.active = new Map(); this.pending = new Map(); this.byID = new Map(); this.removals = new Map();
    this.warming = new Set(); this.work = new Map(); this.preparing = 0; this.bytes = 0; this.reserved = 0;
  }
  async init() {
    await fs.mkdir(this.root, { recursive: true, mode: 0o700 });
    for (const name of await fs.readdir(this.root)) {
      if (/^[a-f0-9]{32}\.part$/.test(name)) { await fs.unlink(path.join(this.root, name)); continue; }
      if (!/^\d{1,30}\.json$/.test(name)) continue;
      try {
        const data = JSON.parse(await fs.readFile(path.join(this.root, name), 'utf8'));
        if (data.formatVersion !== 1 || !validID(data.episodeID) || name !== data.episodeID + '.json' || !/^[a-f0-9]{32}$/.test(data.id)) continue;
        const stream = await fileStream(path.join(this.root, data.id + '.mp4'), 'cache');
        if (stream.total !== data.total) continue;
        stream.id = data.id;
        if (!validID(data.seriesID)) delete data.seriesID;
        this.completed.set(data.episodeID, { ...data, stream }); this.bytes += stream.total;
        this.byID.set(stream.id, stream);
      } catch { /* An incomplete cache record is not playable. */ }
    }
    const retained = new Set([...this.completed.values()].map(record => record.id + '.mp4'));
    for (const name of await fs.readdir(this.root)) {
      if (/^[a-f0-9]{32}\.mp4$/.test(name) && !retained.has(name) || /^\d{1,30}\.[a-f0-9]{32}\.tmp$/.test(name)) {
        await fs.unlink(path.join(this.root, name));
      }
    }
    await this.makeRoom(0);
  }
  removeRecord(record) {
    const episodeID = record.episodeID;
    if (this.completed.get(episodeID) !== record) return this.removals.get(episodeID);
    this.completed.delete(episodeID); this.byID.delete(record.id); this.bytes -= record.total;
    // Release this version once and finish removing its manifest before another
    // resolve for the same episode can write a replacement.
    const removal = Promise.resolve(record.binding).catch(() => {}).then(() => Promise.all([
      fs.unlink(path.join(this.root, record.id + '.mp4')).catch(() => {}),
      fs.unlink(path.join(this.root, episodeID + '.json')).catch(() => {})
    ])).finally(() => this.removals.delete(episodeID));
    this.removals.set(episodeID, removal);
    return removal;
  }
  async writeRecord({ episodeID, id, total, used, seriesID }) {
    const record = { formatVersion: 1, episodeID, id, total, used, seriesID };
    const temp = path.join(this.root, episodeID + '.' + id + '.tmp');
    await fs.writeFile(temp, JSON.stringify(record), { mode: 0o600 });
    await fs.rename(temp, path.join(this.root, episodeID + '.json'));
  }
  // Call only after the catalog or saved library verified this episode's owner.
  // Older manifests without a series are upgraded on their first verified play.
  async bindSeries(episodeID, stream, seriesID) {
    if (!seriesID) return stream;
    const record = this.completed.get(episodeID);
    const owner = record?.seriesID || stream.seriesID;
    if (owner && owner !== seriesID) throw failure('EPISODE_MISMATCH', 409);
    stream.seriesID = seriesID;
    if (record?.id === stream.id && !record.seriesID) {
      record.binding ??= this.writeRecord({ ...record, seriesID }).then(() => { record.seriesID = seriesID; })
        .finally(() => { delete record.binding; });
      await record.binding;
    }
    return stream;
  }
  async makeRoom(reserve) {
    while (this.bytes + this.reserved + reserve > this.maxBytes) {
      const victim = [...this.completed.values()].filter(v => !v.pinnedUntil || v.pinnedUntil < Date.now()).sort((a, b) => a.used - b.used)[0];
      if (!victim) throw failure('CACHE_FULL', 507);
      await this.removeRecord(victim);
    }
  }
  async cachedEpisode(episodeID) {
    const removing = this.removals.get(episodeID);
    if (removing) await removing;
    const record = this.completed.get(episodeID);
    if (!record) return null;
    try {
      // The read checks the open file's version before serving any bytes.
      const prefix = await record.stream.chunk(0, 7);
      if (prefix.toString('ascii', 4, 8) !== 'ftyp') throw failure('INVALID_MEDIA');
    } catch (error) {
      if (!['ENOENT', 'ENOTDIR', 'ELOOP', 'MEDIA_CHANGED', 'INVALID_MEDIA', 'SHORT_MEDIA'].includes(error.code)) throw error;
      await this.removeRecord(record);
      return null;
    }
    if (this.completed.get(episodeID) !== record) {
      await this.removals.get(episodeID);
      return null;
    }
    record.used = Date.now(); record.pinnedUntil = record.used + 30 * 60_000;
    return record.stream;
  }
  async resolve(episodeID, fresh = false, verifiedSeriesID) {
    if (!validID(episodeID)) throw failure('INVALID_ID', 400);
    for (const [key, stream] of this.active) {
      if ((stream.failed || stream.expires < Date.now()) && !this.work.has(stream.id)) {
        await stream.discard();
        if (this.active.get(key) === stream) this.active.delete(key);
        this.byID.delete(stream.id);
      }
    }
    for (const [id, stream] of this.byID) {
      if (stream.retired && (stream.failed || stream.expires < Date.now())) await stream.discard();
      if (stream.failed && !this.work.has(id)) this.byID.delete(id);
    }
    const cached = await this.cachedEpisode(episodeID);
    if (cached) return this.bindSeries(episodeID, cached, verifiedSeriesID);
    if (this.pending.has(episodeID)) return this.bindSeries(episodeID, await this.pending.get(episodeID), verifiedSeriesID);
    const active = this.active.get(episodeID);
    // While a bounded repair is running, refresh callers share its version.
    if (active && !active.failed && (active.expires > Date.now() || this.work.has(active.id))) {
      if (!fresh || !active.warmDeferred) return this.bindSeries(episodeID, active, verifiedSeriesID);
      // Keep the old URL readable for other viewers until its lease expires.
      // Only its replacement may publish a completed manifest for this episode.
      active.retired = true;
      this.active.delete(episodeID);
    }
    if (this.preparing >= 2 || this.active.size >= 12) throw failure('RELAY_BUSY', 503);
    this.preparing++;
    const promise = this.create(episodeID, fresh).finally(() => { this.preparing--; this.pending.delete(episodeID); });
    this.pending.set(episodeID, promise);
    return this.bindSeries(episodeID, await promise, verifiedSeriesID);
  }
  async create(episodeID, fresh) {
    const upstream = await this.prepare(episodeID, fresh, { signal: AbortSignal.timeout(30_000) });
    if (!Number.isSafeInteger(upstream.total) || upstream.total < 16 || upstream.total > MAX_FILE) throw failure('MEDIA_SIZE_LIMIT');
    await this.makeRoom(upstream.total);
    const available = await fs.statfs(this.root);
    if (available.bavail * available.bsize < upstream.total + 512 * 1024 ** 2) throw failure('DISK_FULL', 507);
    const id = randomBytes(16).toString('hex');
    const partial = path.join(this.root, id + '.part');
    await fs.writeFile(partial, Buffer.alloc(0), { flag: 'wx', mode: 0o600 });
    // No await between reservation and subsequent checks: concurrent preparations
    // account for in-progress disk usage as well as completed files.
    if (this.bytes + this.reserved + upstream.total > this.maxBytes) {
      await fs.unlink(partial); throw failure('CACHE_FULL', 507);
    }
    this.reserved += upstream.total;
    const ready = new Set(), inflight = new Map();
    let localFile = partial, complete = false, released = false;
    const cache = this;
    const stream = {
      id, total: upstream.total, origin: 'source', expires: Date.now() + 20 * 60_000, failed: false,
      async discard() {
        if (released) return;
        released = true; stream.failed = true;
        await Promise.allSettled([...inflight.values()]);
        await fs.unlink(localFile).catch(() => {});
        cache.reserved -= stream.total;
      },
      async block(index) {
        if (ready.has(index)) return;
        if (inflight.has(index)) return inflight.get(index);
        if (stream.failed) throw failure('SOURCE_FAILED');
        const task = (async () => {
          const start = index * CHUNK, end = Math.min(start + CHUNK, stream.total) - 1;
          let data;
          for (let attempt = 0; ; attempt++) {
            try { data = await upstream.chunk(start, end, { signal: AbortSignal.timeout(20_000) }); break; }
            catch (error) {
              if (!transientRead(error)) throw error;
              if (attempt >= 1) throw failure('SOURCE_TEMPORARY', 503);
            }
          }
          if (data.length !== end - start + 1) throw failure('SHORT_MEDIA');
          const handle = await fs.open(localFile, 'r+');
          try {
            let written = 0;
            while (written < data.length) {
              const result = await handle.write(data, written, data.length - written, start + written);
              if (!result.bytesWritten) throw failure('CACHE_WRITE_FAILED');
              written += result.bytesWritten;
            }
          } finally { await handle.close(); }
          ready.add(index);
        })().catch(error => {
          if (error.code !== 'SOURCE_TEMPORARY') stream.failed = true;
          throw error;
        }).finally(() => inflight.delete(index));
        inflight.set(index, task); return task;
      },
      async chunk(start, end, { signal } = {}) {
        signal?.throwIfAborted();
        let needsFetch = false;
        for (let index = Math.floor(start / CHUNK); index <= Math.floor(end / CHUNK); index++) {
          if (!ready.has(index)) needsFetch = true;
          await stream.block(index); signal?.throwIfAborted();
        }
        if (needsFetch && stream.warmDeferred && !stream.retired) cache.warm(stream);
        // Each read opens the current path; rename occurs only after every block is ready.
        let handle;
        try { handle = await fs.open(localFile, 'r'); }
        catch (error) { if (error.code !== 'ENOENT' || !complete) throw error; handle = await fs.open(localFile, 'r'); }
        try {
          const data = Buffer.alloc(end - start + 1);
          const result = await handle.read(data, 0, data.length, start);
          if (result.bytesRead !== data.length) throw failure('SHORT_CACHE');
          return data;
        } finally { await handle.close(); }
      },
      async warm(deadline) {
        for (let index = 0; index < Math.ceil(stream.total / CHUNK); index++) {
          if (Date.now() > deadline) throw failure('PREFETCH_TIMEOUT');
          await stream.block(index);
        }
        await fileStream(partial, 'cache');
        const destination = path.join(cache.root, id + '.mp4');
        await fs.rename(partial, destination); localFile = destination; complete = true;
        // Completed playback needs no source URL, key, or per-sample decrypt tables.
        // Existing readers may finish their immutable stream; new readers use disk only.
        const diskStream = await fileStream(destination, 'cache'); diskStream.id = id;
        const record = { episodeID, id, total: stream.total, used: Date.now() };
        // A previously unscoped caller can be joined by a verified play during
        // publication. A series is bound once, so at most one rewrite is needed.
        do {
          record.seriesID = stream.seriesID;
          await cache.writeRecord(record);
        } while (record.seriesID !== stream.seriesID);
        stream.origin = 'cache';
        cache.byID.set(id, diskStream);
        cache.completed.set(episodeID, { ...record, stream: diskStream, pinnedUntil: Date.now() + 30 * 60_000 });
        if (cache.active.get(episodeID) === stream) cache.active.delete(episodeID);
        cache.bytes += stream.total; cache.reserved -= stream.total; released = true;
        cache.onEvent({ event: 'cache_complete', episodeID, bytes: stream.total });
      }
    };
    try {
      const first = await stream.chunk(0, Math.min(stream.total, 16) - 1);
      if (first.toString('ascii', 4, 8) !== 'ftyp') throw failure('INVALID_MEDIA');
    } catch (error) { await stream.discard(); throw error; }
    this.active.set(episodeID, stream); this.byID.set(id, stream);
    return stream;
  }
  warm(stream) {
    if (this.work.has(stream.id)) return this.work.get(stream.id);
    if (!stream.warm || stream.origin !== 'source' || stream.retired || stream.failed) return Promise.resolve();
    stream.warmDeferred = false;
    const job = (async () => {
      while (this.warming.size >= 2) await new Promise(resolve => setTimeout(resolve, 100));
      this.warming.add(stream.id);
      const deadline = Date.now() + 5 * 60_000;
      const backoff = [500, 1500];
      for (let attempt = 0; ; attempt++) {
        const delay = backoff[attempt - 1];
        if (delay) await pause(delay);
        try { await stream.warm(deadline); return; }
        catch (error) {
          if (error.code !== 'SOURCE_TEMPORARY' || attempt >= backoff.length) throw error;
        }
      }
    })().catch(async error => {
      if (!stream.failed && ['SOURCE_TEMPORARY', 'PREFETCH_TIMEOUT'].includes(error.code)) {
        stream.warmDeferred = true;
        this.onEvent({ event: 'cache_deferred', code: safeCode(error) });
        return;
      }
      stream.failed = true;
      this.onEvent({ event: 'cache_failed', code: safeCode(error) });
      // Retain its identity until the client requests a new source; never mix bytes.
      for (const [episodeID, value] of this.active) if (value === stream) this.active.delete(episodeID);
      await stream.discard();
    }).finally(() => { this.warming.delete(stream.id); this.work.delete(stream.id); });
    this.work.set(stream.id, job);
    return job;
  }
  get(id) { return this.byID.get(id); }
  status() { return { completed: this.completed.size, bytes: this.bytes, reservedBytes: this.reserved, warming: this.warming.size, preparing: this.preparing, limitBytes: this.maxBytes }; }
}
