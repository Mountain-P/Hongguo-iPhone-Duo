// Optional current-source entry point; pinned upstream index.mjs remains intact.
import { createServer } from './http.mjs';
import { provider } from './modern-provider.mjs';
import os from 'node:os';
const host = process.env.BRIDGE_HOST || (process.argv.includes('--lan') ? '0.0.0.0' : '127.0.0.1');
const port = Number(process.env.PORT || 8787);
const server = createServer(provider, process.env.BRIDGE_TOKEN || '');
server.listen(port, host, () => {
  console.log(`Hongguo iPhone current-source bridge: http://${host}:${port}`);
  if (host === '0.0.0.0') for (const list of Object.values(os.networkInterfaces())) for (const nic of list || []) {
    if (nic.family === 'IPv4' && !nic.internal) console.log(`iPhone 服務位址：http://${nic.address}:${port}`);
  }
});
server.on('error', error => { console.error(error.code); process.exitCode = 1; });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => { server.closeAllConnections(); server.close(); });
