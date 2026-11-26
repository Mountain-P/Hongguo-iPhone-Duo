import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { createRelay } from '../server/relay/server.mjs';
import { RelayCache } from '../server/relay/cache.mjs';
import { ExistingLibrary, fileStream } from '../server/relay/library.mjs';

const token = 'unit-test-only-relay-token-1234567890';
const bytes = (size = 1200000, value = 9) => { const b = Buffer.alloc(size, value); b.writeUInt32BE(24); b.write('ftyp', 4); b.write('isom', 8); return b; };
async function setup(run) {
  let timestamp = Date.now();
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'hongguo-relay-test-'));
  await fs.mkdir(path.join(root, 'videos'));
  await fs.writeFile(path.join(root, 'videos/one.mp4'), bytes());
  const jobsFile = path.join(root, 'jobs.json');
  await fs.writeFile(jobsFile, JSON.stringify([{ state: 'completed', vid: '200', series_id: '100', title: 'Fixture', episode: 1, file: 'one.mp4' }]));
  let calls = 0;
  const provider = {
    detail: async id => ({ id, title: 'Live fixture', episodes: [{ id: '201', number: 1, title: '1' }] }),
    stream: async () => { calls++; const b = bytes(1500000, calls); return { total: b.length, chunk: async (s, e) => b.subarray(s, e + 1) }; }
  };
  const options = { token, jobsFile, mediaRoot: path.join(root, 'videos'), cacheRoot: path.join(root, 'cache'), provider, now: () => timestamp };
  const relay = await createRelay(options);
  await new Promise(r => relay.server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${relay.server.address().port}`;
  const get = (p, options = {}) => fetch(base + p, { ...options, headers: { Authorization: 'Bearer ' + token, ...options.headers } });
  try { await run({ root, relay, provider, options, get, base, advance: ms => { timestamp += ms; }, calls: () => calls }); }
  finally { relay.server.closeAllConnections(); await new Promise(r => relay.server.close(r)); await fs.rm(root, { recursive: true, force: true }); }
}

test('existing server library plays byte-exact authenticated ranges without contacting a source', () => setup(async ({ get, base, calls, root }) => {
  assert.equal((await fetch(base + '/health')).status, 401);
  const health = await (await get('/health')).json();
  assert.ok(health.capabilities.includes('home-relay-v1')); assert.equal(health.library.episodes, 1);
  const play = await (await get('/api/episodes/200/play?series_id=100')).json();
  assert.equal(play.origin, 'library');
  for (const range of ['bytes=0-1', 'bytes=500000-600000', 'bytes=-31']) {
    const response = await get(play.path, { headers: { Range: range } });
    assert.equal(response.status, 206); assert.equal(response.headers.get('x-hongguo-origin'), 'library');
    const match = /bytes (\d+)-(\d+)\/(\d+)/.exec(response.headers.get('content-range'));
    assert.deepEqual(Buffer.from(await response.arrayBuffer()), bytes().subarray(Number(match[1]), Number(match[2]) + 1));
  }
  assert.equal((await get(play.path, { headers: { Range: 'bytes=99999999-' } })).status, 416);
  const head = await get(play.path, { method: 'HEAD' }); assert.equal(Number(head.headers.get('content-length')), bytes().length);
  assert.equal((await get('/api/episodes/200/play?series_id=999')).status, 409);
  assert.equal(calls(), 0);
  assert.deepEqual(await fs.readFile(path.join(root, 'videos/one.mp4')), bytes());
}));

test('new source fills persistent cache and survives cache restart without new source requests', () => setup(async ({ get, relay, options, calls }) => {
  const play = await (await get('/api/episodes/201/play?series_id=101')).json();
  assert.equal(play.origin, 'source');
  const response = await get(play.path); const body = Buffer.from(await response.arrayBuffer());
  assert.equal(body.length, 1500000); assert.deepEqual(body, bytes(1500000, 1));
  for (let i = 0; i < 100 && !relay.cache.completed.has('201'); i++) await new Promise(r => setTimeout(r, 10));
  assert.equal(relay.cache.completed.size, 1); assert.equal(relay.cache.status().reservedBytes, 0);
  const restarted = new RelayCache(options.cacheRoot, { prepare: () => { throw Error('must not resolve'); } });
  await restarted.init();
  const stream = await restarted.resolve('201', true);
  assert.equal(stream.id, play.mediaVersion); assert.equal(stream.origin, 'cache');
  assert.deepEqual(await stream.chunk(500000, 600000), body.subarray(500000, 600001));
  assert.equal(calls(), 1);
}));

test('partial source failures never become completed cache and retry gets a different media version', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'hongguo-cache-test-'));
  let broken = true, calls = 0;
  const cache = new RelayCache(root, { prepare: async () => {
    calls++; const fail = broken, b = bytes();
    return { total: b.length, chunk: async (s, e) => { if (s > 0 && fail) throw Error('network'); return b.subarray(s, e + 1); } };
  }});
  try {
    await cache.init(); const first = await cache.resolve('201'); await cache.warm(first);
    assert.equal(cache.completed.size, 0); assert.equal(cache.status().reservedBytes, 0);
    assert.equal((await fs.readdir(root)).filter(n => n.endsWith('.json') || n.endsWith('.part')).length, 0);
    broken = false; const next = await cache.resolve('201', true); assert.notEqual(first.id, next.id);
    await cache.warm(next); assert.equal(cache.completed.size, 1); assert.equal(calls, 2);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('library excludes traversal and symlinks outside its media root', () => setup(async ({ root, options }) => {
  await fs.writeFile(path.join(root, 'outside.mp4'), bytes());
  await fs.symlink(path.join(root, 'outside.mp4'), path.join(root, 'videos/link.mp4'));
  await fs.writeFile(options.jobsFile, JSON.stringify(['../outside.mp4', 'link.mp4'].map((file, i) => ({ state: 'completed', vid: String(300 + i), series_id: '100', title: 'Outside', episode: i + 1, file }))));
  const library = new ExistingLibrary(options.jobsFile, options.mediaRoot); await library.refresh(); assert.equal(library.episodes.size, 0);
}));

test('changed local media is rejected instead of splicing bytes', () => setup(async ({ root }) => {
  const file = path.join(root, 'videos/one.mp4'), stream = await fileStream(file, 'library');
  await fs.writeFile(file, bytes(1200000, 4));
  await assert.rejects(stream.chunk(0, 100), error => error.code === 'MEDIA_CHANGED');
}));

test('self-check reports actual prefix validation scope and no provider work for saved media', () => setup(async ({ relay, calls }) => {
  const result = await relay.selfCheck();
  assert.equal(result.state, 'passed'); assert.equal(result.scope, 'source-and-mp4-prefix'); assert.equal(calls(), 0);
}));

test('concurrent refreshes share a healthy version and orphan cache files are removed on restart', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'hongguo-cache-refresh-'));
  let calls = 0; const b = bytes();
  try {
    const cache = new RelayCache(root, { prepare: async () => { calls++; return { total: b.length, chunk: async (s,e) => b.subarray(s,e+1) }; } });
    await cache.init();
    const first = await cache.resolve('201');
    const [a,c] = await Promise.all([cache.resolve('201',true),cache.resolve('201',true)]);
    assert.equal(a.id,first.id); assert.equal(c.id,first.id);
    await Promise.all([cache.warm(first),cache.warm(a),cache.warm(c)]);
    assert.equal(calls,1); assert.equal(cache.bytes,b.length); assert.equal(cache.reserved,0);
    const orphan = 'a'.repeat(32)+'.mp4', temporary='202.'+'b'.repeat(32)+'.tmp';
    await fs.writeFile(path.join(root,orphan),b); await fs.writeFile(path.join(root,temporary),'{}');
    const restarted = new RelayCache(root,{prepare:async()=>{throw Error('unexpected');}}); await restarted.init();
    assert.equal(restarted.bytes,b.length); assert.equal(restarted.completed.size,1);
    assert.ok(!(await fs.readdir(root)).includes(orphan)); assert.ok(!(await fs.readdir(root)).includes(temporary));
  } finally { await fs.rm(root,{recursive:true,force:true}); }
});

test('legacy clear headers remove only parsed auxiliary metadata and preserve sample bytes and ranges', async () => {
  const { clearHeaderPatches, applyClearHeaderPatches } = await import('../server/relay/clear-header.mjs');
  const box = (type, body=Buffer.alloc(0)) => { const h=Buffer.alloc(8);h.writeUInt32BE(body.length+8);h.write(type,4);return Buffer.concat([h,body]); };
  const header = type => {
    const count=Buffer.alloc(8);count.writeUInt32BE(1,4);
    const stsd=box('stsd',Buffer.concat([count,box(type,Buffer.concat([Buffer.alloc(78),box('hvcC',Buffer.alloc(8))]))]));
    const stbl=box('stbl',Buffer.concat([stsd,box('senc',Buffer.alloc(20,3)),box('saiz',Buffer.alloc(12,4)),box('saio',Buffer.alloc(12,5))]));
    return Buffer.concat([box('ftyp',Buffer.from('isom0000')),box('moov',box('trak',box('mdia',box('minf',stbl))))]);
  };
  const head=header('hvc1'), original=Buffer.concat([head,box('mdat',Buffer.from('senc is sample data, leave it untouched'))]);
  const patches=clearHeaderPatches(head), normalized=applyClearHeaderPatches(Buffer.from(original),0,patches);
  assert.equal(patches.length,3); assert.equal(normalized.length,original.length);
  assert.deepEqual(normalized.subarray(head.length),original.subarray(head.length));
  for(const [start,end] of [[0,12],[13,head.length-1],[head.length-3,original.length-1]]) {
    assert.deepEqual(applyClearHeaderPatches(Buffer.from(original.subarray(start,end+1)),start,patches), normalized.subarray(start,end+1));
  }
  assert.throws(()=>clearHeaderPatches(header('encv')),error=>error.code==='UNSUPPORTED_CLEAR_HEADER');
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'hongguo-normalize-'));
  try {
    const file=path.join(root,'saved.mp4');await fs.writeFile(file,original);
    const stream=await fileStream(file,'library');assert.deepEqual(await stream.chunk(0,original.length-1),normalized);
    assert.deepEqual(await fs.readFile(file),original);
  } finally { await fs.rm(root,{recursive:true,force:true}); }
});

test('a damaged or missing saved episode falls back to the same episode and keeps valid cached media usable offline', () =>
  setup(async ({ root, relay, get, calls, provider, advance }) => {
    const local = path.join(root, 'videos/one.mp4');
    const first = await (await get('/api/episodes/200/play?series_id=100')).json();
    await fs.writeFile(local, Buffer.alloc(4096));
    let catalogReads = 0;
    provider.detail = async id => { catalogReads++; return { id, episodes: [{ id: '200', number: 1 }] }; };
    assert.equal((await get('/api/episodes/200/play?series_id=999')).status, 409);
    assert.equal(catalogReads, 0);
    assert.equal(calls(), 0);

    const fallback = await (await get('/api/episodes/200/play?series_id=100')).json();
    assert.equal(fallback.origin, 'source');
    assert.equal(catalogReads, 1);
    assert.notEqual(first.path, fallback.path);
    const range = await get(fallback.path, { headers: { Range: 'bytes=30-127' } });
    assert.equal(range.status, 206);
    assert.deepEqual(Buffer.from(await range.arrayBuffer()), bytes(1500000, 1).subarray(30,128));
    await relay.cache.warm(relay.cache.get(fallback.mediaVersion));
    assert.equal(calls(), 1);

    await fs.unlink(local);
    await relay.library.refresh();
    advance(301000);
    provider.detail = async () => { throw Error('catalog is offline'); };
    provider.stream = async () => { throw Error('stream provider offline'); };
    const cached = await (await get('/api/episodes/200/play?series_id=100&fresh=1')).json();
    assert.equal(cached.origin, 'cache');
    assert.equal(cached.mediaVersion, fallback.mediaVersion);
    assert.equal((await get('/api/episodes/200/play?series_id=999')).status, 409);
    assert.equal((await get(first.path)).status, 410);

    await fs.writeFile(local, bytes(4096, 8));
    await relay.library.refresh();
    const repaired = await (await get('/api/episodes/200/play?series_id=100')).json();
    assert.equal(repaired.origin, 'library');
    assert.notEqual(repaired.mediaVersion, first.mediaVersion);
  }));

test('a new episode updates fresh or expired metadata once for concurrent callers, and real mismatches stay rejected', () =>
  setup(async ({ get, advance, provider, calls, relay }) => {
    let lookups = 0, published = ['201'];
    let entered, release;
    provider.detail = async id => {
      lookups++;
      if (entered) { entered(); await new Promise(resolve => { release = resolve; }); }
      return { id, title: 'Catalog', episodes: published.map((id, i) => ({ id, number: i + 1, title: id })) };
    };
    assert.equal((await (await get('/api/series/101')).json()).episodes.length, 1);
    published.push('202');
    const starting = new Promise(resolve => { entered = resolve; });
    const play = () => get('/api/episodes/202/play?series_id=101');
    const reads = Promise.all([play(), play()]);
    await starting;
    entered = undefined;
    release();
    const [a, b] = await Promise.all((await reads).map(response => response.json()));
    assert.equal(a.origin, 'source'); assert.equal(a.mediaVersion, b.mediaVersion);
    assert.equal(lookups, 2);
    await relay.cache.warm(relay.cache.get(a.mediaVersion));
    assert.equal(calls(), 1);

    advance(301000);
    published = ['201','202','203'];
    const latest = await (await get('/api/episodes/203/play?series_id=101&fresh=1')).json();
    assert.equal(latest.origin, 'source'); assert.equal(lookups, 3);
    await relay.cache.warm(relay.cache.get(latest.mediaVersion));
    assert.equal((await get('/api/episodes/999/play?series_id=101')).status, 409);
    assert.equal((await get('/api/episodes/999/play?series_id=101&fresh=1')).status, 409);
    assert.equal(lookups, 4); assert.equal(calls(), 2);
  }));

test('media ranges finish during a single blocked index refresh; unchanged media keep their prepared headers', () =>
  setup(async ({ relay, root, options, get, advance }) => {
    const play = await (await get('/api/episodes/200/play?series_id=100')).json();
    const prepared = await relay.library.media(play.mediaVersion);
    const changed = bytes(2048, 3);
    await fs.writeFile(path.join(root, 'videos/two.mp4'), changed);
    const jobs = JSON.parse(await fs.readFile(options.jobsFile));
    jobs.push({ ...jobs[0], vid: '202', episode: 2, file: 'two.mp4' });
    await fs.writeFile(options.jobsFile, JSON.stringify(jobs));

    const refresh = relay.library.refresh.bind(relay.library);
    let release, scans = 0;
    const gate = new Promise(resolve => { release = resolve; });
    relay.library.refresh = async () => { scans++; await gate; await refresh(); };
    advance(31000);
    try {
      const ranges = await Promise.all([0, 16].map(async start => {
        const response = await get(play.path, { signal: AbortSignal.timeout(5000), headers: { Range: `bytes=${start}-${start+15}` } });
        assert.equal(response.status, 206);
        return Buffer.from(await response.arrayBuffer());
      }));
      assert.equal(scans, 1);
      const original = bytes();
      assert.deepEqual(ranges, [original.subarray(0,16), original.subarray(16,32)]);
      assert.equal((await (await get('/api/episodes/200/play?series_id=100', { signal: AbortSignal.timeout(5000) })).json()).origin, 'library');
      assert.equal(scans, 1);
    } finally { release(); }
    const health = await (await get('/health')).json();
    assert.equal(health.library.episodes, 2);
    assert.equal(scans, 1);
    assert.equal(await relay.library.media(play.mediaVersion), prepared);
    const added = await (await get('/api/episodes/202/play?series_id=100')).json();
    assert.equal(added.origin, 'library');
  }));

test('an unreadable index retains the previous snapshot and does not repeatedly rescan on media requests', () =>
  setup(async ({ relay, get, advance, options }) => {
    const play = await (await get('/api/episodes/200/play?series_id=100')).json();
    const refresh = relay.library.refresh.bind(relay.library);
    let scans = 0;
    relay.library.refresh = async () => { scans++; return refresh(); };
    await fs.writeFile(options.jobsFile, '{');
    advance(31000);
    assert.equal((await (await get('/health')).json()).library.episodes, 1);
    for (let i = 0; i < 2; i++) {
      const response = await get(play.path, { headers: { Range: 'bytes=0-11' } });
      assert.equal(response.status, 206);
      assert.equal((await response.arrayBuffer()).byteLength, 12);
    }
    assert.equal(scans, 1);
  }));

test('restarting the relay preserves existing library media URLs and validates the requested file lazily', () =>
  setup(async ({ relay, get, options }) => {
    const play = await (await get('/api/episodes/200/play?series_id=100')).json();
    const restarted = await createRelay(options);
    const opened = await restarted.library.media(play.mediaVersion);
    assert.equal(opened.id, play.mediaVersion);
    const same = await relay.library.media(play.mediaVersion);
    assert.deepEqual(await opened.chunk(32,64), await same.chunk(32,64));
  }));

test('a failed metadata refresh can be retried while a confirmed wrong series never opens the source', () =>
  setup(async ({ get, provider, calls, relay }) => {
    let attempt = 0;
    provider.detail = async id => {
      if (++attempt === 1) throw Error('temporary unavailable');
      return { id, episodes: [{ id: '204', number: 1 }] };
    };
    const route = '/api/episodes/204/play?series_id=102';
    assert.equal((await get(route)).status, 502);
    const result = await (await get(route)).json();
    assert.equal(attempt, 2); assert.equal(result.origin, 'source');
    await relay.cache.warm(relay.cache.get(result.mediaVersion));

    provider.detail = async id => ({ id, episodes: [{ id: '205', number: 1 }] });
    assert.equal((await get('/api/episodes/204/play?series_id=999')).status, 409);
    assert.equal(calls(), 1);
  }));


test('a corrupt persistent cache and corrupt library copy can recover to a newly validated source', () =>
  setup(async ({ root, options, relay, get, provider, calls, advance }) => {
    await fs.writeFile(path.join(root, 'videos/one.mp4'), Buffer.alloc(4096));
    let catalogReads = 0;
    provider.detail = async id => { catalogReads++; return { id, episodes: [{ id: '200', number: 1 }] }; };
    const route = '/api/episodes/200/play?series_id=100';
    const first = await (await get(route)).json();
    await relay.cache.warm(relay.cache.get(first.mediaVersion));
    await fs.writeFile(path.join(options.cacheRoot, first.mediaVersion + '.mp4'), Buffer.alloc(256));
    advance(301000);
    const [recovered, concurrent] = await Promise.all([get(route), get(route)].map(async request => (await request).json()));
    assert.equal(recovered.mediaVersion, concurrent.mediaVersion);
    assert.equal(recovered.origin, 'source'); assert.equal(catalogReads, 2); assert.equal(calls(), 2);
    assert.notEqual(recovered.mediaVersion, first.mediaVersion);
    await relay.cache.warm(relay.cache.get(recovered.mediaVersion));
    assert.equal(relay.cache.bytes, bytes(1500000).length);
    assert.equal((await get(first.path)).status, 410);
  }));
