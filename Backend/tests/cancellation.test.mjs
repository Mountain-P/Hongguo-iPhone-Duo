import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createServer } from '../server/http.mjs';
import cacheModule from '../server/modern/stream-cache.js';

const deferred = () => { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; };

test('two clients share preparation; cancelling one does not cancel the remaining client', async () => {
  const prepared = deferred(); let underlying, calls = 0;
  const get = cacheModule.createPreparedStreamCache(async (_id, { signal }) => { calls++; underlying = signal; return prepared.promise; });
  const first = new AbortController(), second = new AbortController();
  const a = get('100', false, first.signal), b = get('100', false, second.signal);
  await Promise.resolve();
  first.abort();
  await assert.rejects(a, error => error.name === 'AbortError');
  assert.equal(underlying.aborted, false);
  const value = { total: 10 };
  prepared.resolve(value);
  assert.equal(await b, value); second.abort();
  assert.equal(underlying.aborted, false);
  assert.equal(await get('100'), value); assert.equal(calls, 1);
});

test('last waiter cancellation aborts upstream work and the next client gets a new preparation', async () => {
  let calls = 0, underlying;
  const get = cacheModule.createPreparedStreamCache(async (_id, { signal }) => {
    calls++; underlying = signal;
    if (calls > 1) return { total: 2 };
    return new Promise((_resolve, reject) => signal.addEventListener('abort', () => reject(signal.reason), { once: true }));
  });
  const controller = new AbortController();
  const result = get('100', false, controller.signal);
  await Promise.resolve(); controller.abort();
  await assert.rejects(result); assert.equal(underlying.aborted, true);
  assert.equal((await get('100')).total, 2); assert.equal(calls, 2);
});

test('a fresh preparation cannot be overwritten by an older concurrent result', async () => {
  const old = deferred(), fresh = deferred(); let calls = 0;
  const get = cacheModule.createPreparedStreamCache(async () => ++calls === 1 ? old.promise : fresh.promise);
  const a = get('100'), b = get('100', true);
  const latest = { total: 20 };
  fresh.resolve(latest); assert.equal(await b, latest);
  old.resolve({ total: 10 }); assert.equal((await a).total, 10);
  assert.equal(await get('100'), latest);
});

test('real HTTP disconnect cancellation preserves the other waiter and later media request', async t => {
  const prepared = deferred(), started = deferred(); let upstreamSignal, calls = 0;
  const get = cacheModule.createPreparedStreamCache(async (_id, { signal }) => {
    upstreamSignal = signal; calls++; started.resolve(); return prepared.promise;
  });
  const server = createServer({ stream: (id, fresh, { signal }) => get(id, fresh, signal) });
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(() => { server.closeAllConnections(); server.close(); });
  const url = `http://127.0.0.1:${server.address().port}`;
  const controller = new AbortController();
  const a = fetch(url + '/api/episodes/100/play', { signal: controller.signal });
  a.catch(() => {});
  await started.promise;
  const b = fetch(url + '/api/episodes/100/play');
  // A deterministic server request event ensures both clients reached the handler.
  await once(server, 'request');
  controller.abort(); await assert.rejects(a);
  assert.equal(upstreamSignal.aborted, false);
  prepared.resolve({ total: 4, chunk: async (start, end, { signal }) => {
    assert.equal(signal.aborted, false); return Buffer.from('test').subarray(start, end + 1);
  } });
  assert.equal((await b).status, 200);
  const media = await fetch(url + '/api/episodes/100/stream', { headers: { Range: 'bytes=0-3' } });
  assert.equal(media.status, 206); assert.equal(await media.text(), 'test');
  assert.equal(calls, 1);
});
