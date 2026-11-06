import { test } from 'node:test';
import assert from 'node:assert/strict';
import recovery from '../server/modern/playback-recovery.js';
import devices from '../server/modern/playback-device.js';

const empty = () => Object.assign(new Error('empty'), { code: 'EMPTY_RESPONSE', status: 200 });
const envelope = vid => ({ code: 0, data: { [vid]: { video_model: { marker: vid } } } });
const tabEnvelope = vid => ({ code: 0, data: { video_model_data: envelope(vid).data } });
const consume = async (response, vid) => {
  if (Number(response.code || 0)) throw Object.assign(new Error('denied'), { code: 'BUSINESS_REJECTED' });
  assert.equal(response.data[vid].video_model.marker, vid);
  return { vid };
};

test('video_tab success uses only its separate registration and exact requested entry', async () => {
  const registrations = [], posts = [];
  const resolve = recovery.createPlaybackRecovery({
    register: async context => { registrations.push(context.scope); return { device_id: 'tab', cookie: 'install_id=one' }; },
    getModel: async (vid, identity) => { assert.equal(identity.device_id, 'tab'); assert.equal(identity.cookie, 'install_id=one'); return tabEnvelope(vid); },
    postModel: async () => { posts.push(true); throw Error('unexpected'); }, consume,
  });
  assert.deepEqual((await resolve('100')).recovery, { route: 'video_tab', attempts: 1 });
  assert.deepEqual(registrations, ['tab']); assert.equal(posts.length, 0);
});

test('empty GET recovers with at most two fresh rounds and two re-signed hosts per round', async () => {
  const registered = [], requests = [];
  const resolve = recovery.createPlaybackRecovery({
    register: async ({ scope }) => { const identity = { device_id: `${scope}-${registered.length}` }; registered.push(identity); return identity; },
    getModel: async () => { throw empty(); },
    postModel: async (vid, type, identity, host) => {
      requests.push({ vid, type, identity, host });
      if (requests.length < 4) throw empty();
      return envelope(vid);
    }, consume,
  });
  const result = await resolve('100', { contentType: '1006' });
  assert.deepEqual(result.recovery, { route: 'registered_post', attempts: 4, round: 2 });
  assert.deepEqual(requests.map(x => x.host), [...recovery.LEGACY_HOSTS, ...recovery.LEGACY_HOSTS]);
  assert.equal(registered.length, 3);
  assert.equal(requests[0].identity, requests[1].identity);
  assert.equal(requests[2].identity, requests[3].identity);
  assert.notEqual(requests[0].identity, requests[2].identity);
  assert.notEqual(requests[0].identity, registered[0]);
  assert.ok(requests.every(x => x.type === '1006'));
});

test('POST budget stops at four and each new episode gets new legacy registrations', async () => {
  const scopes = []; let posts = 0;
  const resolve = recovery.createPlaybackRecovery({
    register: async ({ scope }) => { scopes.push(scope); return { device_id: String(scopes.length) }; },
    getModel: async () => { throw empty(); },
    postModel: async () => { posts++; throw empty(); }, consume,
  });
  await assert.rejects(resolve('100'), error => error.code === 'EMPTY_RESPONSE');
  assert.equal(posts, 4);
  await assert.rejects(resolve('101'), error => error.code === 'EMPTY_RESPONSE');
  assert.equal(posts, 8);
  assert.deepEqual(scopes, ['tab', 'legacy', 'legacy', 'legacy', 'legacy']);
});

test('first valid POST stops recovery immediately', async () => {
  let posts = 0, registrations = 0;
  const resolve = recovery.createPlaybackRecovery({
    register: async () => ({ device_id: String(++registrations) }), getModel: async () => { throw empty(); },
    postModel: async vid => { posts++; return envelope(vid); }, consume,
  });
  assert.equal((await resolve('100')).recovery.attempts, 1);
  assert.equal(posts, 1); assert.equal(registrations, 2);
});

test('explicit HTTP authorization, business rejection and unsupported codecs never rotate around denial', async () => {
  let rejectedRegistration;
  await assert.rejects(devices.registerPlaybackDevice(async () => ({ code: 110001 }), { isolated: true }), error => {
    rejectedRegistration = error;
    return error.registrationFailure === 'BUSINESS_REJECTED';
  });
  for (const error of [{ status: 401 }, { status: 403 }, { code: 'BUSINESS_REJECTED' }, { code: 'NO_COMPATIBLE_SOURCE' }, { code: 'SECURITY_BLOCKED' },
    rejectedRegistration, { code: 'DEVICE_REGISTRATION_FAILED', registrationFailure: 'SECURITY_BLOCKED' }]) {
    let posts = 0;
    const resolve = recovery.createPlaybackRecovery({ register: async () => ({}), getModel: async () => { throw Object.assign(Error('stop'), error); },
      postModel: async () => { posts++; }, consume });
    await assert.rejects(resolve('100')); assert.equal(posts, 0);
  }
  let posts = 0;
  const resolve = recovery.createPlaybackRecovery({ register: async () => ({}), getModel: async () => { throw empty(); },
    postModel: async () => { posts++; throw Object.assign(Error('denied'), { status: 403 }); }, consume });
  await assert.rejects(resolve('100')); assert.equal(posts, 1);
});

test('cancellation after any async stage prevents the next model or registration request', async () => {
  for (const stage of ['register', 'get', 'post', 'consume']) {
    const controller = new AbortController(); let registrations = 0, posts = 0;
    const resolve = recovery.createPlaybackRecovery({
      register: async () => { registrations++; if (stage === 'register') controller.abort(); return {}; },
      getModel: async vid => { if (stage === 'get') controller.abort(); if (stage === 'consume') return tabEnvelope(vid); throw empty(); },
      postModel: async vid => { posts++; if (stage === 'post') controller.abort(); return envelope(vid); },
      consume: async () => { controller.abort(); return {}; },
    });
    await assert.rejects(resolve('100', { signal: controller.signal }), error => error.name === 'AbortError');
    assert.ok(registrations <= 2); assert.ok(posts <= 1);
    if (['register', 'get', 'consume'].includes(stage)) assert.equal(posts, 0);
  }
});

test('one total deadline bounds the whole model preparation', async () => {
  let now = 0, posts = 0;
  const resolve = recovery.createPlaybackRecovery({ now: () => now, register: async () => ({}), getModel: async () => { throw empty(); },
    postModel: async () => { posts++; now = 100; throw empty(); }, consume });
  await assert.rejects(resolve('100', { deadline: 100 }), error => error.code === 'ETIMEDOUT');
  assert.equal(posts, 1);
});

test('a fallback_api empty response is not miscounted as another empty POST model attempt', async () => {
  let posts = 0;
  const resolve = recovery.createPlaybackRecovery({ register: async () => ({}), getModel: async () => { throw empty(); },
    postModel: async vid => { posts++; return envelope(vid); },
    consume: async () => { throw Object.assign(empty(), { stage: 'fallback_api' }); } });
  await assert.rejects(resolve('100')); assert.equal(posts, 1);
});

test('video_tab never adopts another episode and registration Cookie allowlist excludes accounts', () => {
  assert.throws(() => recovery.normalizeVideoTabEnvelope('100', tabEnvelope('101')), error => error.code === 'MISSING_MODEL');
  assert.equal(devices.registrationCookieHeader({ 'set-cookie': [
    'install_id=123; Secure', 'ttreq=abc=def; HttpOnly', 'store-region=cn; Path=/', 'store-region-src=did',
    'sessionid=account-secret', 'sid_tt=account-secret', 'ttreq=bad\r\nInjected',
  ] }), 'install_id=123; store-region=cn; store-region-src=did; ttreq=abc=def');
});
