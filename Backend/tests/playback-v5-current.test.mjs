import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { createRequire } from 'node:module';

test('current V5 signature matches the independent Kotlin full-wire vector', () => {
  const fixture = JSON.parse(fs.readFileSync(new URL('./fixtures/signing-v5-playback-312.json', import.meta.url)));
  const source = new URL('../server/modern/playback-v5.js', import.meta.url);
  const originalRequire = createRequire(source);
  const fixedCrypto = { ...crypto, randomBytes: count => count === 18
    ? { toString: () => 'synthetic' } : Buffer.from('00000080', 'hex') };
  class Clock extends Date { static now() { return 1800000000000; } }
  const context = vm.createContext({ Buffer, URL, Date: Clock, module: { exports: {} },
    require: name => name === 'node:crypto' ? fixedCrypto : originalRequire(name) });
  vm.runInContext(fs.readFileSync(source, 'utf8') + '\nmodule.exports.audit = { hashF13, medusa, helios };', context);
  const a = context.module.exports.audit;
  const query = originalRequire('./sm3')(Buffer.from(new URL(fixture.url).search.slice(1)));
  const body = crypto.createHash('md5').update(Buffer.from(fixture.body, 'base64')).digest();
  const ts = Number(fixture.headers['x-khronos']);
  assert.equal(a.medusa(query, a.hashF13(query, body, ts), ts, fixture.identity), fixture.headers['x-medusa']);
  assert.equal(a.helios(ts), fixture.headers['x-helios']);
});
