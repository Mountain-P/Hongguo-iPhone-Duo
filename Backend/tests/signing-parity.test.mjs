import { gunzipSync } from 'node:zlib';
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

const sourceURL = new URL('../server/modern/app-source.js', import.meta.url);
const vectors = JSON.parse(fs.readFileSync(new URL('./fixtures/signing-vectors.json', import.meta.url), 'utf8'));

function signerHarness() {
  let clock = 1800000000999;
  const fakeMath = Object.create(Math);
  fakeMath.random = () => vectors.heliosNonce / 0x100000000;
  class Clock extends Date { static now() { return clock; } }
  const context = vm.createContext({
    Buffer, URL, URLSearchParams, AbortSignal, setTimeout, clearTimeout,
    require: createRequire(sourceURL), module: { exports: {} }, Math: fakeMath, Date: Clock,
  });
  // Test-only access to pure primitives; production exports stay unchanged.
  vm.runInContext(fs.readFileSync(sourceURL, 'utf8') + '\nmodule.exports.audit = { hashF13, sm3, helios, xGorgon, branchOf, playbackRequest };', context);
  return { api: context.module.exports, setClock(value) { clock = value; } };
}

function header(request, name) {
  return Object.entries(request.headers).find(([key]) => key.toLowerCase() === name.toLowerCase())?.[1];
}

const anonymousIdentity = {
  device_id: '7000000000000000001', iid: '7000000000000000002',
  cdid: '00000000-0000-4000-8000-000000000001',
};
const payload = '{"biz_param": {"device_level":3},"mixed_video_id_map":{"1004":["7000000000000000001"]},"label":"測試 & bytes"}\n';

test('signing primitives match the authoritative fixed Go F13/Gorgon/Helios vectors', () => {
  const { api } = signerHarness();
  const { audit } = api;
  const timestamp = Buffer.alloc(4);
  timestamp.writeUInt32LE(vectors.ts);
  const queryHash = audit.sm3(vectors.query);
  const bodyHash = crypto.createHash('md5').update(vectors.body).digest();
  assert.equal(audit.branchOf(`https://fixture.invalid/?${vectors.query}`, Buffer.from(vectors.body), vectors.ts), 2);
  assert.equal(audit.hashF13(queryHash, bodyHash, timestamp, vectors.ts).toString('hex'), vectors.f13);
  assert.equal(audit.helios(vectors.ts), vectors.helios);
  assert.equal(audit.xGorgon(vectors.query, Buffer.from(vectors.body), vectors.ts, vectors.gorgonNonce), vectors.gorgon);
});

test('legacy fallback signs exact gzip bytes with current profile and isolated identity', () => {
  const { api } = signerHarness();
  const request = api.audit.playbackRequest(payload, { ...anonymousIdentity, cookie: 'private', accountToken: 'private' });
  const url = new URL(request.url);
  assert.equal(url.searchParams.get('version_name'), '7.4.3.32');
  assert.equal(url.searchParams.get('version_code'), '74332');
  assert.equal(header(request, 'Content-Encoding'), 'gzip');
  assert.equal(gunzipSync(request.body).toString(), payload);
  assert.equal(header(request, 'X-SS-STUB').toLowerCase(), crypto.createHash('md5').update(request.body).digest('hex'));
  assert.ok(header(request, 'X-Argus')); assert.ok(header(request, 'X-Ladon'));
  assert.equal(url.searchParams.has('accountToken'), false); assert.equal(header(request, 'Cookie'), undefined);
});

test('alternate legacy requests re-sign compressed bytes using the new timestamp', () => {
  const { api, setClock } = signerHarness();
  const first = api.audit.playbackRequest(payload, anonymousIdentity);
  setClock(1800000002999);
  const alternate = api.audit.playbackRequest(payload, anonymousIdentity, 'api5-normal-hl.fqnovel.com');
  assert.deepEqual(first.body, alternate.body);
  assert.notEqual(header(first, 'X-Khronos'), header(alternate, 'X-Khronos'));
  assert.notEqual(header(first, 'X-Argus'), header(alternate, 'X-Argus'));
});

test('playback changes leave the existing search/account/metadata profiles isolated', () => {
  const { api } = signerHarness();
  const search = api.signedSearchRequest({ keyword: 'fixture', identity: anonymousIdentity });
  const account = api.signedAccountRequest('/reading/user/info/v1/', {}, anonymousIdentity);
  for (const request of [search, account]) {
    assert.equal(new URL(request.url).searchParams.get('version_name'), '7.2.2.32');
    assert.equal(api.audit.branchOf(request.url, null, Number(header(request, 'X-Khronos'))), 0);
  }
  const metadata = api.signedMetadataRequest('/reading/distribution/category/landpage/v/');
  assert.equal(new URL(metadata.url).searchParams.get('version_name'), '7.3.5.32');
  assert.equal(api.audit.branchOf(metadata.url, null, Number(header(metadata, 'X-Khronos'))), 0);
});
