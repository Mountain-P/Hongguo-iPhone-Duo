import { test } from 'node:test';
import assert from 'node:assert/strict';
import source from '../server/modern/app-source.js';

const row = (name, codec, pixels, extra = {}) => ({
  main_url: `https://unit.fqnovelvod.com/${name}.mp4`,
  codec_type: codec, width: pixels, height: Math.round(pixels * 16 / 9), encrypt: false, ...extra,
});
const model = videos => ({ video_id: 'fixture-200', video_duration: 60, video_list: videos });

test('auto playback chooses highest supported resolution and preserves its episode', () => {
  const sourceModel = model({
    h264: row('avc720', 'h264', 720),
    hevc: row('hevc1080', 'hevc', 1080),
    unsupported: row('unsupported1080', 'bytevc2', 1080),
    unsupportedHigher: row('unsupported1440', 'bytevc2', 1440),
  });
  const chosen = source.parseAppPlayModel(sourceModel, '200', { quality: 'auto', playbackQuality: 'automatic' }, true);
  assert.equal(chosen.vid, '200');
  assert.equal(chosen.codec, 'hevc');
  assert.equal(chosen.width, 1080);
  assert.deepEqual(chosen.variants.map(x => [x.vid, x.codec]), [['200', 'hevc']]);
  assert.deepEqual(chosen.alternateURLs, []);
});

test('equal resolution prefers AVC and does not reuse its metadata for other encodings', () => {
  const chosen = source.parseAppPlayModel(model({
    first: row('hevc', 'hevc', 1080),
    second: row('avc', 'avc1', 1080, { backup_url: 'https://unit.fqnovelvod.com/avc-backup.mp4' }),
    unsupported: row('unsupported', 'bytevc2', 1080),
  }), '201', { quality: 'auto' }, true);
  assert.equal(chosen.vid, '201');
  assert.equal(chosen.codec, 'avc1');
  assert.deepEqual(chosen.alternateURLs, ['https://unit.fqnovelvod.com/avc-backup.mp4']);
  assert.deepEqual(chosen.variants.map(x => x.codec), ['avc1', 'avc1', 'hevc']);
});

test('data saver, strict download, and ByteVC2-only negotiation input retain their policies', () => {
  const m = model({ low: row('low', 'h264', 480), high: row('high', 'hevc', 1080) });
  assert.equal(source.parseAppPlayModel(m, '200', { playbackQuality: 'dataSaver' }, true).codec, 'h264');
  assert.equal(source.parseAppPlayModel(m, '200', { quality: '1080p', offlineDirect: true }, true).codec, 'hevc');
  assert.throws(() => source.parseAppPlayModel(model({ low: m.video_list.low }), '200',
    { quality: '1080p', offlineDirect: true }, true), { code: 'QUALITY_UNAVAILABLE' });
  assert.equal(source.parseAppPlayModel(model({ only: row('only', 'bytevc2', 1080) }),
    '200', { quality: 'auto' }, true).codec, 'bytevc2');
});
