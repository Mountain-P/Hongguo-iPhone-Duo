// Deterministic integration fixture; it never contacts a drama platform.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import { createServer } from '../server/http.mjs';

const directory = path.dirname(fileURLToPath(import.meta.url));
const media = path.join(directory, 'sample.mp4');
if (!fs.existsSync(media) || fs.statSync(media).size < 32) {
  const generation = spawnSync('xcrun', ['swift', '-module-cache-path', path.join(os.tmpdir(), 'hongguo-fixture-swift-cache'), path.join(directory, 'generate-video.swift'), media], { stdio: 'inherit' });
  if (generation.status !== 0) throw new Error('Fixture clip generation needs macOS Command Line Tools. Run generate-video.swift on a Mac first.');
}
const bytes = fs.readFileSync(media);
if (bytes.length < 32 || bytes.subarray(4, 8).toString() !== 'ftyp') throw new Error('Fixture media is not a complete MP4; regenerate sample.mp4.');
const series = {
  id: '900000000000000001', title: '測試片段・紅果 iPhone', cover: '',
  description: '本機產生的四秒測試影片，用於確認播放、拖曳、選集與續播；不是平台劇集。',
  badge: '共 3 集・測試資料', tags: '本機測試',
  episodes: [1, 2, 3].map(number => ({ id: `90000000000000000${number + 1}`, title: `第 ${number} 集`, number })),
};
const provider = {
  home: async page => ({ items: [series], page }),
  search: async (_keyword, page) => ({ items: [series], page }),
  detail: async id => {
    if (id !== series.id) throw new Error('Fixture series does not exist');
    return series;
  },
  stream: async id => {
    if (!series.episodes.some(episode => episode.id === id)) throw new Error('Fixture episode does not exist');
    return { total: bytes.length, chunk: async (start, end) => bytes.subarray(start, end + 1) };
  },
};
const host = process.env.BRIDGE_HOST || '127.0.0.1';
const port = Number(process.env.PORT || 8788);
const server = createServer(provider, process.env.BRIDGE_TOKEN || '');
server.listen(port, host, () => console.log(`LOCAL FIXTURE ONLY: http://${host}:${port} · series ${series.id}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { server.closeAllConnections(); server.close(); });
