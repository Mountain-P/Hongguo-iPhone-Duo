import fs from 'node:fs/promises';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { clearHeaderPatches, applyClearHeaderPatches } from './clear-header.mjs';

export const validID = value => typeof value === 'string' && /^\d{1,30}$/.test(value);
export const failure = (code, status = 502) => Object.assign(new Error(code), { code, status });
export const safeCode = error => /^[A-Z0-9_]{1,60}$/.test(error?.code || '') ? error.code : 'UPSTREAM_ERROR';

export async function fileStream(file, origin, expected) {
  const stat = await fs.stat(file);
  if (!stat.isFile() || stat.size < 16 || !Number.isSafeInteger(stat.size)) throw failure('INVALID_MEDIA');
  const version = `${stat.dev}:${stat.ino}:${stat.size}:${stat.mtimeMs}`;
  if (expected && expected !== version) throw failure('MEDIA_CHANGED', 409);
  const fd = await fs.open(file, 'r');
  const header = Buffer.alloc(12);
  let patches = [];
  try {
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
    id: createHash('sha256').update('clear-header-v1:' + file + version).digest('hex'), total: stat.size, origin, version,
    async chunk(start, end, { signal } = {}) {
      signal?.throwIfAborted();
      const handle = await fs.open(file, 'r');
      try {
        const current = await handle.stat();
        if (`${current.dev}:${current.ino}:${current.size}:${current.mtimeMs}` !== version) throw failure('MEDIA_CHANGED', 409);
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
  constructor(jobsFile, mediaRoot) { this.jobsFile = jobsFile; this.mediaRoot = mediaRoot; this.episodes = new Map(); this.series = new Map(); }
  async refresh() {
    if (!this.jobsFile || !this.mediaRoot) return;
    const stat = await fs.stat(this.jobsFile);
    if (stat.size > 16 * 1024 * 1024) throw failure('LIBRARY_TOO_LARGE');
    const root = await fs.realpath(this.mediaRoot);
    const jobs = JSON.parse(await fs.readFile(this.jobsFile, 'utf8'));
    if (!Array.isArray(jobs)) throw failure('INVALID_LIBRARY');
    const episodes = new Map(), series = new Map();
    for (const job of jobs) {
      if (job.state !== 'completed' || !validID(job.vid) || !validID(job.series_id) ||
          typeof job.file !== 'string' || !Number.isInteger(job.episode) || job.episode < 1) continue;
      const file = await fs.realpath(path.resolve(root, job.file)).catch(() => null);
      if (!file || !file.startsWith(root + path.sep)) continue;
      const stat = await fs.stat(file).catch(() => null);
      if (!stat?.isFile() || stat.size < 16) continue;
      const item = { id: job.vid, number: job.episode, title: `第 ${job.episode} 集`, seriesID: job.series_id, file };
      episodes.set(item.id, item);
      let show = series.get(job.series_id);
      if (!show) {
        show = { id: job.series_id, title: String(job.title || '已儲存劇集'), cover: '', description: '家中伺服器已儲存的劇集', tags: '伺服器片庫', episodes: [] };
        series.set(show.id, show);
      }
      show.episodes.push({ id: item.id, title: item.title, number: item.number });
    }
    for (const show of series.values()) {
      show.episodes.sort((a, b) => a.number - b.number);
      show.badge = `已儲存 ${show.episodes.length} 集`;
    }
    this.episodes = episodes; this.series = series;
  }
  page(page = 1, keyword = '') {
    const all = [...this.series.values()].filter(s => s.title.includes(keyword));
    return { items: all.slice((page - 1) * 24, page * 24).map(({ episodes, ...card }) => card), page, hasMore: all.length > page * 24 };
  }
  async stream(episodeID, seriesID) {
    const episode = this.episodes.get(episodeID);
    if (!episode) return null;
    if (seriesID && episode.seriesID !== seriesID) throw failure('EPISODE_MISMATCH', 409);
    return fileStream(episode.file, 'library');
  }
}
