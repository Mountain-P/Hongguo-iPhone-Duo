import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
const modules = ['app-source.js','playback-device.js','playback-recovery.js','playback-signature.js','playback-v5.js','sm3.js','download-quality.js'];
const native = new URL('../../Sources/HongguoCore/NativeRuntime/PlaybackAssets/', import.meta.url);
// Standalone server deployments intentionally do not contain the iOS tree.
let nativeExists = true;
try { await fs.access(native); } catch { nativeExists = false; }
test('server protocol modules match the reviewed bundled iOS runtime bytes', { skip: !nativeExists }, async () => {
  for (const name of modules) {
    assert.deepEqual(await fs.readFile(new URL('../server/modern/'+name,import.meta.url)),await fs.readFile(new URL(name,native)),name);
  }
});
