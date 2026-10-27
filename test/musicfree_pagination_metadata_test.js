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
const music = { id: '1', title: 'song', artist: 'artist' };

function adapter(reply) {
  const context = vm.createContext({ module: { exports: {} }, console: { log() {} } });
  vm.runInContext(adapterCode, context);
  context.module.exports = {
    platform: '网易云音乐',
    supportedSearchType: ['music', 'album', 'artist', 'sheet'],
    search: reply,
    getAlbumInfo: reply,
    getArtistWorks: reply,
    getMusicSheetInfo: reply,
    getTopListDetail: reply,
    getRecommendSheetsByTag: reply,
    getRecommendSheetTags: () => [],
    getTopLists: () => [{ title: 'group', data: [{ id: '1', title: 'board' }] }],
  };
  return context.module.exports;
}

const endpoints = {
  search: (api) => api.search('wy', 'song', 1, 30),
  albumSearch: (api) => api.searchTyped('wy', 'album', 1, 30, 'album'),
  artistSearch: (api) => api.searchTyped('wy', 'artist', 1, 30, 'artist'),
  album: (api) => api.getAlbumInfo('wy', { id: '1' }, 1),
  artist: (api) => api.getArtistWorks('wy', { id: '1' }, 1, 'music'),
  sheet: (api) => api.getMusicSheetInfo('1', 1),
  board: (api) => api.getTopListDetail('1', 1),
  playlistSearch: (api) => api.searchPlaylists('sheet', 1),
  recommend: (api) => api.getRecommendSheetsByTag('', 1),
};

for (const [name, invoke] of Object.entries(endpoints)) {
  test(`${name}: only explicit non-negative integer total is forwarded`, async () => {
    for (const total of [undefined, null, 0, 81, -1, 1.5, '81', NaN, Infinity]) {
      const api = adapter(() => ({ data: [music], musicList: [music], total, isEnd: false }));
      const result = await invoke(api);
      assert.equal(result.total, Number.isInteger(total) && total >= 0 ? total : null);
      assert.equal(result.isEnd, false);
    }
  });

  test(`${name}: plugin rejection and error bodies remain failures`, async () => {
    const rejected = adapter(() => Promise.reject(new Error('offline')));
    assert.match((await invoke(rejected)).error, /offline/);
    const errorBody = adapter(() => ({ data: [], total: 0, isEnd: true, error: 'rate limited' }));
    assert.match((await invoke(errorBody)).error, /rate limited/);
    const invalid = adapter(() => null);
    assert.ok((await invoke(invalid)).error);
  });

  test(`${name}: explicit zero and terminal empty page survive`, async () => {
    const result = await invoke(adapter(() => ({ data: [], musicList: [], total: 0, isEnd: true })));
    assert.equal(result.total, 0);
    assert.equal(result.isEnd, true);
    assert.equal(result.error, undefined);
  });
}

test('legacy search keeps unknown total and end marker null', async () => {
  const api = adapter(() => [music]);
  const result = await api.search('wy', 'song', 1, 1);
  assert.equal(result.list.length, 1);
  assert.equal(result.total, null);
  assert.equal(result.isEnd, null);
});

test('full search page cannot override explicit isEnd true', async () => {
  const api = adapter(() => ({ data: [music], total: 1, isEnd: true }));
  assert.equal((await api.search('wy', 'song', 1, 1)).isEnd, true);
});

test('sheet metadata preserves explicit song count without counting current page', async () => {
  const api = adapter(() => ({ musicList: [music], songCount: 80, total: 80, isEnd: false }));
  const result = await api.getMusicSheetInfo('1', 1);
  assert.equal(result.sheet.songCount, 80);
  assert.equal(result.total, 80);
  assert.equal(result.songs.length, 1);
  const unknown = await adapter(() => ({ musicList: [music], isEnd: false })).getMusicSheetInfo('1', 1);
  assert.equal(unknown.sheet.songCount, null);
  assert.equal(unknown.total, null);
});

test('getTopLists still exports an array', async () => {
  const result = await adapter(() => ({})).getTopLists();
  assert.equal(Array.isArray(result), true);
  assert.equal(result.length, 1);
});
