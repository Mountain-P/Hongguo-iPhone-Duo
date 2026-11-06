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

test('playback signs the exact uncompressed wire bytes with the verified playback profile', () => {
  const { api } = signerHarness();
  const request = api.audit.playbackRequest(payload, {
    ...anonymousIdentity, cookie: 'sessionid=must-not-leak', version_name: '9.9.9.99', accountToken: 'must-not-leak',
  });
  const url = new URL(request.url);
  const ts = Number(header(request, 'X-Khronos'));
  const ticket = Number(url.searchParams.get('_rticket'));
  assert.equal(url.hostname, 'api5-normal-sinfonlineb.fqnovel.com');
  assert.equal(url.searchParams.get('version_name'), '7.1.3.32');
  assert.equal(url.searchParams.get('version_code'), '71332');
  assert.equal(url.searchParams.has('cookie'), false);
  assert.equal(url.searchParams.has('accountToken'), false);
  assert.equal(header(request, 'Cookie'), undefined);
  assert.equal(header(request, 'X-Tt-Token'), undefined);
  assert.equal(url.searchParams.get('ts'), header(request, 'X-Khronos'));
  assert.equal(url.searchParams.get('_rticket'), header(request, 'X-SS-Req-Ticket'));
  assert.ok(ticket >= 1800000000999 && ticket < 1800000000999 + 256);
  assert.deepEqual(request.body, Buffer.from(payload));
  assert.equal(header(request, 'Content-Encoding'), undefined);
  assert.equal(header(request, 'X-SS-STUB'), crypto.createHash('md5').update(Buffer.from(payload)).digest('hex').toUpperCase());
  assert.equal(header(request, 'Passport-Sdk-Version'), '50561');
  assert.equal(header(request, 'X-Tt-Request-Tag'), 't=0;n=0');
  assert.equal(header(request, 'X-Vc-Bdturing-Sdk-Version'), '3.7.2.cn');
  for (const name of ['X-Argus', 'X-Gorgon', 'X-Medusa', 'X-Khronos', 'X-Ladon', 'X-Helios']) {
    assert.ok(header(request, name), `${name} must be present`);
  }
  assert.equal(Buffer.from(header(request, 'X-Argus'), 'base64').readUInt32LE(), ts);
  assert.equal(Buffer.from(header(request, 'X-Ladon'), 'base64').readUInt32BE(), ts);
  assert.equal(api.audit.branchOf(request.url, request.body, ts), 2);
  const signature = Buffer.from(header(request, 'X-Gorgon'), 'hex');
  const nonce = signature.readUInt16LE(2);
  assert.equal(header(request, 'X-Gorgon'), api.audit.xGorgon(url.search.slice(1), request.body, ts, nonce));
  assert.ok(header(request, 'X-Gorgon') !== api.audit.xGorgon(url.search.slice(1), Buffer.concat([request.body, Buffer.from(' ')]), ts, nonce), 'wire-byte changes must invalidate the signature');
});

test('alternate playback requests are freshly signed while preserving wire bytes', () => {
  const { api, setClock } = signerHarness();
  const first = api.audit.playbackRequest(payload, anonymousIdentity);
  setClock(1800000002999);
  const alternate = api.audit.playbackRequest(payload, anonymousIdentity, 'api5-normal-hl.fqnovel.com');
  assert.equal(new URL(alternate.url).hostname, 'api5-normal-hl.fqnovel.com');
  assert.deepEqual(first.body, alternate.body);
  assert.notEqual(header(first, 'X-Khronos'), header(alternate, 'X-Khronos'));
  assert.ok(header(first, 'X-Medusa') !== header(alternate, 'X-Medusa'), 'the alternate attempt must not reuse the old signature');
  assert.equal(api.audit.branchOf(alternate.url, alternate.body, Number(header(alternate, 'X-Khronos'))), 2);
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
