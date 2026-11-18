import fs from 'node:fs/promises';
import { createRelay } from './relay/server.mjs';
import { provider } from './modern-provider.mjs';

const token = (await fs.readFile(process.env.RELAY_TOKEN_FILE, 'utf8')).trim();
const relay = await createRelay({ token,
  jobsFile: process.env.RELAY_LIBRARY_JOBS, mediaRoot: process.env.RELAY_LIBRARY_ROOT,
  cacheRoot: process.env.RELAY_CACHE_ROOT,
  maxBytes: Number(process.env.RELAY_CACHE_BYTES || 2 * 1024 ** 3), provider,
  onEvent: event => console.log(JSON.stringify(event)) });
const host = process.env.RELAY_HOST || '127.0.0.1', port = Number(process.env.RELAY_PORT || 8940);
relay.server.listen(port, host, () => console.log(JSON.stringify({ event: 'listening', port, version: '0.17.0' })));
const probe = { seriesID: process.env.RELAY_PROBE_SERIES, episodeID: process.env.RELAY_PROBE_EPISODE };
const check = () => relay.selfCheck(probe).catch(() => {});
const interval = setInterval(check, 15 * 60_000); interval.unref();
check();
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => {
  clearInterval(interval); relay.server.close(); relay.server.closeAllConnections();
  setTimeout(() => process.exit(0), 500).unref();
});
