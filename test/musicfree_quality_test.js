'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

const adapterCode = readFileSync(
  path.resolve(__dirname, '../assets/plugin_modules/musicfree_adapter.js'),
  'utf8'
);
const url = 'https://audio.example/song';
const directUrl = 'https://audio.example/direct';
const groups = [
  ['low', '64k'],
  ['standard', '128k'],
  ['high', 'hq', '320k'],
  ['super', 'lossless', 'flac'],
];

function adapter(reply) {
  const calls = [];
  const context = vm.createContext({ module: { exports: {} }, console: { log() {} } });
  vm.runInContext(adapterCode, context);
  context.module.exports = {
    platform: '网易云音乐',
    ...(reply && {
      getMediaSource(item, quality) {
        calls.push({ item, quality });
        return reply(item, quality);
      },
    }),
  };
  return {
    calls,
    resolve(quality, item = { id: '1', url: directUrl, qualities: { high: directUrl } }) {
      if (arguments.length === 0) quality = '320k';
      return context.module.exports.musicUrl('wy', { extra: { musicItem: item } }, quality);
    },
  };
}

for (const [name, reply, error] of [
  ['empty', () => null],
  ['undefined', () => undefined],
  ['empty URL', () => ({ url: '' })],
  ['throw', () => { throw new Error('sync failure'); }, /sync failure/],
  ['rejection', () => Promise.reject(new Error('offline')), /offline/],
  ['error body', () => ({ error: 'unsupported by plugin' }), /unsupported by plugin/],
  ['invalid protocol', () => ({ url: 'file:///song.mp3' })],
  ['invalid HTTP URL', () => ({ url: 'https://' })],
  ['missing URL host', () => 'https:/song.mp3'],
]) {
  test(`${name}: request once without quality or direct URL fallback`, async () => {
    const api = adapter(reply);
    const result = await api.resolve();
    assert.deepEqual(api.calls.map((call) => call.quality), ['high']);
    assert.ok(!result || !result.url);
    if (error) assert.match(result.error, error);
  });
}

test('HTTP error details survive the single failed request', async () => {
  const api = adapter(() => Promise.reject({ response: { status: 412, data: { message: 'blocked' } } }));
  assert.match((await api.resolve()).error, /HTTP 412 blocked/);
  assert.equal(api.calls.length, 1);
});

for (const group of groups) {
  test(`${group[0]}: only equivalent labels map to the same request`, async () => {
    for (const requested of group) {
      const api = adapter(() => url);
      const result = await api.resolve(requested);
      assert.deepEqual(api.calls.map((call) => call.quality), [group[0]]);
      assert.equal(result.url, url);
      assert.equal(result.quality, group.at(-1));
    }
  });

  test(`${group[0]}: preserve explicit equivalent response qualities`, async () => {
    for (const quality of group) {
      for (const response of [{ url, quality }, { data: { url, quality } }]) {
        const api = adapter(() => response);
        const result = await api.resolve(group[0]);
        assert.equal(result.quality, quality);
        assert.equal(result.url, url);
        assert.equal(api.calls.length, 1);
      }
    }
  });
}

for (const quality of ['192k', 'flac24bit', 'hires', 'atmos', 'master', '24bit', 'mp3', 'unknown', '', null, undefined]) {
  test(`unsupported ${String(quality)}: refuse before calling plugin`, async () => {
    const api = adapter(() => url);
    assert.match((await api.resolve(quality)).error, /Unsupported quality/);
    assert.equal(api.calls.length, 0);
    assert.match((await adapter().resolve(quality)).error, /Unsupported quality/);
  });
}

for (const quality of ['128k', 'low', 'flac', '192k', 'hires', 'mp3', 'unknown']) {
  test(`explicit ${quality} cannot replace requested 320k`, async () => {
    for (const response of [
      { url, quality },
      { data: { url, quality } },
      { url, quality: 'high', data: { quality } },
    ]) {
      const api = adapter(() => response);
      const result = await api.resolve();
      assert.match(result.error, /Quality mismatch/);
      assert.ok(result.error.includes(quality));
      assert.equal(result.url, undefined);
      assert.equal(api.calls.length, 1);
    }
  });
}

test('empty reported quality uses the request label without inspecting format', async () => {
  for (const quality of [undefined, null, '', '  ']) {
    const api = adapter(() => ({ url, quality, format: 'mp3' }));
    const result = await api.resolve('64k');
    assert.equal(result.quality, '64k');
    assert.equal(api.calls.length, 1);
  }
});

test('preserve headers and user agent, including nested data', async () => {
  for (const nested of [false, true]) {
    const response = { url, quality: 'hq', headers: { Referer: 'https://example.test', Count: 1, Omit: null }, userAgent: 'test-agent' };
    const api = adapter(() => nested ? { data: response } : response);
    const result = await api.resolve();
    assert.deepEqual({ ...result.headers }, { Referer: 'https://example.test', Count: '1', 'User-Agent': 'test-agent' });
    assert.equal(api.calls.length, 1);
  }
  const api = adapter(() => ({ url, headers: { 'user-agent': 'original' }, userAgent: 'replacement' }));
  assert.deepEqual({ ...(await api.resolve()).headers }, { 'user-agent': 'original' });
});

test('without getMediaSource, prefer a requested-quality entry over item.url', async () => {
  for (const key of ['320k', 'high', 'hq']) {
    const result = await adapter().resolve('320k', {
      url: directUrl,
      quality: '128k',
      qualities: { standard: directUrl, [key]: { url, quality: 'hq', headers: { Referer: 'entry' } } },
    });
    assert.equal(result.url, url);
    assert.equal(result.quality, 'hq');
    assert.equal(result.headers.Referer, 'entry');
  }
  const result = await adapter().resolve('320k', { qualities: { '320k': url, high: directUrl } });
  assert.equal(result.url, url);
});

test('direct URLs never select a different quality key or bypass entry mismatch', async () => {
  assert.equal(await adapter().resolve('320k', { qualities: { standard: url, super: url } }), null);
  const mismatch = await adapter().resolve('320k', { url: directUrl, qualities: { high: { url, quality: '128k' } } });
  assert.match(mismatch.error, /Quality mismatch/);
  assert.equal(mismatch.url, undefined);
});

test('bare item.url is allowed only without an explicit quality mismatch', async () => {
  for (const quality of [undefined, '', ' ', 'high', '320k']) {
    const result = await adapter().resolve('320k', { url, quality, headers: { Referer: 'direct' } });
    assert.equal(result.url, url);
    assert.equal(result.headers.Referer, 'direct');
  }
  const metadataOnly = await adapter().resolve('320k', { url, qualities: { high: {}, standard: directUrl } });
  assert.equal(metadataOnly.url, url);
  for (const quality of ['128k', 'hires', 'unknown']) {
    const result = await adapter().resolve('320k', { url, quality });
    assert.match(result.error, /Quality mismatch/);
    assert.equal(result.url, undefined);
  }
});
