import fs from 'node:fs/promises';
import path from 'node:path';
import { constants } from 'node:fs';
import { createHash } from 'node:crypto';
import { clearHeaderPatches, applyClearHeaderPatches } from './clear-header.mjs';

export const validID = value => typeof value === 'string' && /^\d{1,30}$/.test(value);
export const failure = (code, status = 502) => Object.assign(new Error(code), { code, status });
export const safeCode = error => /^[A-Z0-9_]{1,60}$/.test(error?.code || '') ? error.code : 'UPSTREAM_ERROR';

const fileVersion = stat => `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}`;
const mediaID = (file, version) => createHash('sha256').update('clear-header-v1:' + file + version).digest('hex');
const readableFile = constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK;
const missingFile = error => ['ENOENT', 'ENOTDIR', 'ELOOP'].includes(error?.code);
const damagedFile = error => ['INVALID_MEDIA', 'SHORT_MEDIA'].includes(error?.code);

export async function fileStream(file, origin, expected) {
  const fd = await fs.open(file, readableFile);
  let stat, version;
  const header = Buffer.alloc(12);
  let patches = [];
  try {
    stat = await fd.stat();
    if (!stat.isFile() || stat.size < 16 || !Number.isSafeInteger(stat.size)) throw failure('INVALID_MEDIA');
    version = fileVersion(stat);
    if (expected && expected !== version) throw failure('MEDIA_CHANGED', 409);
    await fd.read(header, 0, header.length, 0);
    const ftypSize = header.readUInt32BE(0);
    if (ftypSize >= 16 && ftypSize <= 65536 && ftypSize + 8 <= stat.size) {
      const next = Buffer.alloc(8); await fd.read(next,0,8,ftypSize);
      if (next.toString('ascii',4,8) === 'moov') {
        const end = ftypSize + next.readUInt32BE(0);
        if (end > 8*1024*1024 || end > stat.size || end <= ftypSize+8) throw failure('INVALID_MEDIA');
        const prefix=Buffer.alloc(end); const read=await fd.read(prefix,0,end,0);
        if(read.bytesRead!==end) throw failure('SHORT_MEDIA');
        patches=clearHeaderPatches(prefix);
      }
    }
  } finally { await fd.close(); }
  if (header.toString('ascii', 4, 8) !== 'ftyp') throw failure('INVALID_MEDIA');
  return {
    id: mediaID(file, version), total: stat.size, origin, version,
    async chunk(start, end, { signal } = {}) {
      signal?.throwIfAborted();
      const handle = await fs.open(file, readableFile);
      try {
        const current = await handle.stat();
        if (fileVersion(current) !== version) throw failure('MEDIA_CHANGED', 409);
        const data = Buffer.alloc(end - start + 1);
        let offset = 0;
        while (offset < data.length) {
          signal?.throwIfAborted();
          const { bytesRead } = await handle.read(data, offset, data.length - offset, start + offset);
          if (!bytesRead) throw failure('SHORT_MEDIA');
          offset += bytesRead;
        }
        return applyClearHeaderPatches(data, start, patches);
      } finally { await handle.close(); }
    }
  };
}

/// Reads only completed downloader jobs. Never writes the existing library.
export class ExistingLibrary {
  constructor(jobsFile, mediaRoot) {
    this.jobsFile = jobsFile; this.mediaRoot = mediaRoot;
    this.episodes = new Map(); this.series = new Map(); this.mediaByID = new Map(); this.savedSeries = new Map();
  }
  async inspect(root, candidate, previous) {
    try {
      const file = await fs.realpath(candidate);
      if (!file.startsWith(root + path.sep)) throw failure('OUTSIDE_LIBRARY');
      const stat = await fs.stat(file);
      if (!stat.isFile() || stat.size < 16 || !Number.isSafeInteger(stat.size)) return null;
      const version = fileVersion(stat);
      if (previous?.file === file && previous.version === version) return previous;
      return { file, version, id: mediaID(file, version) };
    } catch (error) {
      if (missingFile(error)) return null;
      throw error;
    }
  }

  // Cache the header check by immutable file version, including a known damaged
  // header. A transient filesystem error can be retried on the next request.
  prepare(media) {
    if (!media.prepared) {
      media.prepared = fileStream(media.file, 'library', media.version).catch(error => {
        if (damagedFile(error)) return null;
        media.prepared = undefined;
        throw error;
      });
    }
    return media.prepared;
  }
  async media(id) {
    const media = this.mediaByID.get(id);
    return media ? this.prepare(media) : null;
  }

  async readJobs() {
    const stat = await fs.stat(this.jobsFile);
    if (!stat.isFile()) throw failure('INVALID_LIBRARY');
    if (stat.size > 16 * 1024 * 1024) throw failure('LIBRARY_TOO_LARGE');
    const version = fileVersion(stat);
    if (this.jobSnapshot?.version === version) return this.jobSnapshot;
    const jobs = JSON.parse(await fs.readFile(this.jobsFile, 'utf8'));
    if (!Array.isArray(jobs)) throw failure('INVALID_LIBRARY');
    const rows = [];
    for (const job of jobs) {
      if (job?.state !== 'completed' || !validID(job.vid) || !validID(job.series_id) ||
          typeof job.file !== 'string' || !Number.isInteger(job.episode) || job.episode < 1) continue;
      const { vid, series_id, file, episode, title } = job;
      rows.push({ vid, series_id, file, episode, title: String(title || '已儲存劇集') });
    }
    return { version, rows };
  }
  async refresh() {
    if (!this.jobsFile || !this.mediaRoot) return;
    const root = await fs.realpath(this.mediaRoot);
    const jobs = await this.readJobs();
    const episodes = new Map(), series = new Map(), mediaByID = new Map(), savedSeries = new Map();
    for (const job of jobs.rows) {
      const declaredSeries = savedSeries.get(job.vid);
      if (episodes.has(job.vid) || (declaredSeries && declaredSeries !== job.series_id)) continue;
      const candidate = path.resolve(root, job.file);
      if (!candidate.startsWith(root + path.sep)) continue;
      let media;
      try { media = await this.inspect(root, candidate, this.episodes.get(job.vid)?.media); }
      catch (error) { if (error.code === 'OUTSIDE_LIBRARY') continue; throw error; }
      savedSeries.set(job.vid, job.series_id);
      if (!media) continue;
      const item = { id: job.vid, number: job.episode, title: `第 ${job.episode} 集`, seriesID: job.series_id,
                     root, candidate, media };
      mediaByID.set(media.id, media);
      episodes.set(item.id, item);
      let show = series.get(job.series_id);
      if (!show) {
        show = { id: job.series_id, title: job.title, cover: '', description: '家中伺服器已儲存的劇集', tags: '伺服器片庫', episodes: [] };
        series.set(show.id, show);
      }
      show.episodes.push({ id: item.id, title: item.title, number: item.number });
    }
    for (const show of series.values()) {
      show.episodes.sort((a, b) => a.number - b.number);
      show.badge = `已儲存 ${show.episodes.length} 集`;
    }
    this.jobSnapshot = jobs;
    this.episodes = episodes; this.series = series;
    this.mediaByID = mediaByID; this.savedSeries = savedSeries;
  }
  page(page = 1, keyword = '') {
    const all = [...this.series.values()].filter(s => s.title.includes(keyword));
    return { items: all.slice((page - 1) * 24, page * 24).map(({ episodes, ...card }) => card), page, hasMore: all.length > page * 24 };
  }
  async stream(episodeID, seriesID) {
    const savedSeries = this.savedSeries.get(episodeID);
    if (seriesID && savedSeries && savedSeries !== seriesID) throw failure('EPISODE_MISMATCH', 409);
    const episode = this.episodes.get(episodeID);
    if (!episode) return null;
    const media = await this.inspect(episode.root, episode.candidate, episode.media);
    if (this.episodes.get(episodeID) !== episode) return this.stream(episodeID, seriesID);
    if (!media) return null;
    if (media !== episode.media) {
      this.mediaByID.delete(episode.media.id);
      this.mediaByID.set(media.id, media);
      episode.media = media;
    }
    try {
      return await this.prepare(media);
    } catch (error) {
      if (missingFile(error) || error.code === 'MEDIA_CHANGED') return null;
      throw error;
    }
  }
}
