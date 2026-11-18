// Simulator-only transparent fault adapter. No credentials are stored or logged.
// node scripts/relay-fault-proxy.mjs https://your-relay.example 8941
import http from 'node:http';
import https from 'node:https';
const target = new URL(process.argv[2]);
if (target.protocol !== 'https:' || target.username || target.password || target.search) throw Error('HTTPS origin required');
let fired = false, unavailableUntil = 0, mediaRequests = 0;
const server = http.createServer((req, res) => {
  if (/^\/api\/media\//.test(req.url)) console.log(JSON.stringify({event:'media_request',range:req.headers.range || 'full',unavailable:Date.now()<unavailableUntil}));
  if (Date.now() < unavailableUntil) { res.writeHead(503); res.end(); return; }
  const dest = new URL(req.url, target);
  if (dest.origin !== target.origin) { res.writeHead(400); res.end(); return; }
  const upstream = https.request(dest, { method: req.method, headers: { ...req.headers, host: target.host } }, response => {
    const isMedia = /^\/api\/media\//.test(dest.pathname);
    if (isMedia) mediaRequests++;
    const interrupt = !fired && isMedia && Number(response.headers['content-length']) > 512 * 1024;
    res.writeHead(response.statusCode, response.headers);
    if (!interrupt) { response.pipe(res); return; }
    let bytes = 0;
    response.on('data', chunk => {
      if (fired) return;
      bytes += chunk.length; res.write(chunk);
      if (bytes >= 256 * 1024) {
        fired = true; unavailableUntil = Date.now() + 8000;
        console.log(JSON.stringify({ event: 'fault_injected', afterBytes: bytes, outageMs: 8000 }));
        response.destroy(); res.destroy();
      }
    });
    response.on('end', () => res.end());
  });
  upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
  res.on('close', () => upstream.destroy());
  req.pipe(upstream);
});
server.listen(Number(process.argv[3] || 8941), '127.0.0.1', () => console.log('Fault proxy ready on loopback'));
process.on('SIGTERM', () => {
  console.log(JSON.stringify({ event: 'fault_summary', fired, mediaRequests }));
  server.closeAllConnections(); server.close();
});
