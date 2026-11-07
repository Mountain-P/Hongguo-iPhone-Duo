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
const episodeCount = Number(process.env.FIXTURE_EPISODES || 3);
if (!Number.isSafeInteger(episodeCount) || episodeCount < 1 || episodeCount > 600) {
  throw new Error('FIXTURE_EPISODES must be an integer between 1 and 600.');
}
const requestedEpisodes = new Set();
let streamRequests = 0;
const series = {
  id: '900000000000000001', title: '測試片段・紅果 iPhone', cover: '',
  description: '本機產生的四秒測試影片，用於確認播放、拖曳、選集與續播；不是平台劇集。',
  badge: `共 ${episodeCount} 集・測試資料`, tags: '本機測試',
  episodes: Array.from({ length: episodeCount }, (_, index) => {
    const number = index + 1;
    return { id: (900000000000000001n + BigInt(number)).toString(), title: `第 ${number} 集`, number };
  }),
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
    streamRequests += 1;
    requestedEpisodes.add(id);
    return { total: bytes.length, chunk: async (start, end) => bytes.subarray(start, end + 1) };
  },
};
const host = process.env.BRIDGE_HOST || '127.0.0.1';
const port = Number(process.env.PORT || 8788);
const server = createServer(provider, process.env.BRIDGE_TOKEN || '');
server.listen(port, host, () => console.log(`LOCAL FIXTURE ONLY: http://${host}:${port} · ${episodeCount} synthetic episodes`));
const report = setInterval(() => console.log(JSON.stringify({ fixture: true, streamRequests, distinctEpisodes: requestedEpisodes.size })), 60_000);
report.unref();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  clearInterval(report); server.closeAllConnections(); server.close();
});
