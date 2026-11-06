import assert from 'node:assert/strict';

const base = new URL(process.env.BRIDGE_URL || 'http://127.0.0.1:8787');
const timeout = Number(process.env.PROBE_TIMEOUT_MS || 45000);
const headers = process.env.BRIDGE_TOKEN ? { Authorization: `Bearer ${process.env.BRIDGE_TOKEN}` } : {};
const summary = [];
async function request(path, extra = {}) {
  const response = await fetch(new URL(path, base), {
    ...extra, headers: { ...headers, ...extra.headers }, signal: AbortSignal.timeout(timeout),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`HTTP ${response.status}`);
  }
  return response;
}
async function step(name, action) {
  const started = Date.now();
  try {
    const value = await action();
    summary.push({ check: name, ok: true, elapsedMs: Date.now() - started, ...value });
    console.log(JSON.stringify(summary.at(-1)));
    return value;
  } catch (error) {
    summary.push({ check: name, ok: false, elapsedMs: Date.now() - started, error: error.name === 'TimeoutError' ? 'timeout' : error.message });
    console.log(JSON.stringify(summary.at(-1)));
    process.exitCode = 1;
    return null;
  }
}
await step('health', async () => {
  const body = await (await request('/health')).json();
  assert.equal(body.service, 'hongguotv');
  assert.equal(body.apiVersion, 1);
  return { upstream: body.upstream };
});
const home = await step('home', async () => {
  const body = await (await request('/api/home')).json();
  assert.ok(Array.isArray(body.items) && body.items.length, 'empty home');
  assert.ok(/^\d+$/.test(body.items[0].id), 'invalid series ID');
  return { count: body.items.length, seriesId: body.items[0].id };
});
const query = process.env.PROBE_QUERY || '總裁';
const search = await step('search', async () => {
  const body = await (await request(`/api/search?q=${encodeURIComponent(query)}&page=1`)).json();
  assert.ok(Array.isArray(body.items) && body.items.length, 'empty search');
  return { count: body.items.length, seriesId: body.items[0].id };
});
const sid = process.env.PROBE_SERIES_ID || home?.seriesId || search?.seriesId;
let detail;
if (sid) detail = await step('detail', async () => {
  const body = await (await request(`/api/series/${sid}`)).json();
  assert.equal(body.id, sid);
  assert.ok(Array.isArray(body.episodes) && body.episodes.length, 'empty episodes');
  return { count: body.episodes.length, episodeId: body.episodes[0].id };
});
if (detail) await step('media-range', async () => {
  const response = await request(`/api/episodes/${detail.episodeId}/stream`, { headers: { Range: 'bytes=0-31' } });
  assert.equal(response.status, 206);
  assert.match(response.headers.get('content-type') || '', /^video\/mp4/);
  const data = Buffer.from(await response.arrayBuffer());
  assert.equal(data.length, 32);
  assert.equal(data.subarray(4, 8).toString(), 'ftyp');
  return { bytes: data.length, mp4Signature: true };
});
if (!sid || !detail) process.exitCode = 1;
console.log(JSON.stringify({ result: process.exitCode ? 'incomplete-or-failed' : 'passed', checks: summary.length, scope: 'One catalog/search/detail and first 32 media bytes only; no full playback claim.' }));
