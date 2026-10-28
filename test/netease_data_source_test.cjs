'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const pluginPath = path.resolve(__dirname, '../plugins/数据源-网易.js');
const script = new vm.Script(readFileSync(pluginPath, 'utf8'), { filename: pluginPath });

function loadPlugin(respond) {
  const requests = [];
  const context = {
    module: { exports: {} },
    cerumusic: {
      async request(url, options) {
        const request = { url: new URL(url), ...JSON.parse(JSON.stringify(options)) };
        requests.push(request);
        const body = await respond(request, requests.length);
        return { body: JSON.stringify(body) };
      }
    }
  };
  // 不提供 require/fetch，插件的所有网络入口都由 fixture 接管。
  script.runInNewContext(context);
  return { plugin: context.module.exports, requests };
}

async function resultOf(promise) {
  return JSON.parse(await promise);
}

function song(id) {
  return {
    id, name: `歌曲${id}`, dt: 180000,
    ar: [{ id: 6452, name: '周杰伦' }],
    al: { id: 10, name: '专辑', picUrl: 'http://p1.music.126.net/cover.jpg' }
  };
}

function items(count, start = 1) {
  return Array.from({ length: count }, (_, index) => song(start + index));
}

const pagedRoutes = [
  {
    name: '歌曲搜索 songCount', countKey: 'songCount', listKey: 'songs', output: 'list',
    size: 30, type: 1,
    invoke: (plugin, page) => plugin.search('wy', '周杰伦', page, 30)
  },
  {
    name: '歌单搜索 playlistCount', countKey: 'playlistCount', listKey: 'playlists', output: 'playlists',
    size: 30, type: 1000,
    invoke: (plugin, page) => plugin.searchPlaylists('周杰伦', page)
  },
  {
    name: '专辑搜索 albumCount', countKey: 'albumCount', listKey: 'albums', output: 'list',
    size: 30, type: 10,
    invoke: (plugin, page) => plugin.searchTyped('wy', '周杰伦', page, 30, 'album')
  },
  {
    name: '作者搜索 artistCount', countKey: 'artistCount', listKey: 'artists', output: 'list',
    size: 30, type: 100,
    invoke: (plugin, page) => plugin.searchTyped('wy', '周杰伦', page, 30, 'artist')
  },
  {
    name: '分类歌单 total', countKey: 'total', listKey: 'playlists', output: 'playlists',
    size: 30, pathname: '/api/playlist/list',
    invoke: (plugin, page) => plugin.getRecommendSheetsByTag('华语', page)
  },
  {
    name: '作者作品 total', countKey: 'total', listKey: 'songs', output: 'musicList',
    size: 50, pathname: '/api/v1/artist/songs',
    invoke: (plugin, page) => plugin.getArtistWorks('wy', { id: '6452' }, page, 'music')
  }
];

async function pagedFixture(route, total, count, page = 1, flags = {}) {
  const data = { [route.countKey]: total, [route.listKey]: items(count), ...flags };
  const body = { code: 200, ...(route.type ? { result: data } : data) };
  const { plugin, requests } = loadPlugin(() => body);
  const result = await resultOf(route.invoke(plugin, page));
  assert.equal(requests.length, 1);
  const request = requests[0];
  const offset = (page - 1) * route.size;
  assert.equal(request.url.hostname, 'music.163.com');
  assert.equal(request.url.pathname, route.pathname || '/api/cloudsearch/pc');
  if (route.type) {
    assert.equal(request.method, 'POST');
    assert.deepEqual(request.form, { s: '周杰伦', type: route.type, limit: route.size, offset });
  } else {
    assert.equal(request.method, 'GET');
    assert.equal(request.url.searchParams.get('limit'), String(route.size));
    assert.equal(request.url.searchParams.get('offset'), String(offset));
    if (route.pathname.includes('/artist/')) {
      assert.equal(request.url.searchParams.get('id'), '6452');
      assert.equal(request.url.searchParams.get('order'), 'hot');
      assert.equal(result.artistItem.worksNum, result.total);
    } else {
      assert.equal(request.url.searchParams.get('cat'), '华语');
      assert.equal(request.url.searchParams.get('order'), 'hot');
    }
  }
  assert.equal(result.limit, route.size);
  assert.equal(result.offset, offset);
  assert.equal(result[route.output].length, count);
  return result;
}

for (const route of pagedRoutes) {
  test(`${route.name}：规范化总数，保留真实零，缺失/无效为 null`, async () => {
    const cases = [
      [7, 7], ['7', 7], [' 7 ', 7], [0, 0], ['0', 0],
      [undefined, null], [null, null], ['', null], ['  ', null],
      [-1, null], ['-1', null], [1.5, null], ['1.5', null],
      ['7首', null], [true, null], [false, null], [[], null], [{}, null],
      [Infinity, null], [NaN, null], [9007199254740992, null]
    ];
    for (const [value, expected] of cases) {
      const result = await pagedFixture(route, value, 1, 1, { more: false });
      assert.equal(result.total, expected, `total=${String(value)}`);
      assert.equal(result.isEnd, expected === null || expected === 0);
    }
  });

  test(`${route.name}：首末页及 total > more/hasMore > 短页优先级`, async () => {
    const cases = [
      { total: route.size + 1, count: 1, page: 1, flags: { more: false, hasMore: false }, end: false },
      { total: route.size + 1, count: 1, page: 2, flags: { more: true, hasMore: true }, end: true },
      { total: route.size, count: route.size, flags: { more: true }, end: true },
      { total: route.size * 2, count: 0, flags: { more: false }, end: false },
      { count: 1, flags: { more: true }, end: false },
      { count: route.size, flags: { more: false }, end: true },
      { count: 1, flags: { hasMore: true }, end: false },
      { count: route.size, flags: { hasMore: false }, end: true },
      { count: 1, flags: { more: 'invalid', hasMore: true }, end: false },
      { count: route.size, flags: { more: false, hasMore: true }, end: true },
      { count: route.size, end: false },
      { count: 1, end: true },
      { count: 0, end: true }
    ];
    for (const fixture of cases) {
      const result = await pagedFixture(route, fixture.total, fixture.count, fixture.page || 1, fixture.flags);
      assert.equal(result.isEnd, fixture.end, JSON.stringify(fixture));
    }
  });
}

test('歌曲搜索：cloudsearch 失败回退老接口，并用代理 song/detail 补封面', async () => {
  const { plugin, requests } = loadPlugin(request => {
    const path = request.url.pathname;
    if (path === '/api/cloudsearch/pc') {
      // 直连 cloudsearch 挂掉：走老接口兜底
      return { code: 405 };
    }
    if (path === '/api/search/get') {
      return {
        code: 200,
        result: {
          hasMore: true,
          songs: [{ id: 1, name: '旧歌曲', duration: 180000, artists: [{ name: '歌手' }], album: { name: '旧专辑' } }]
        }
      };
    }
    if (path === '/song/detail') {
      return {
        code: 200,
        songs: [{ id: 1, name: '旧歌曲', al: { name: '旧专辑', picUrl: 'http://p1.music.126.net/cover.jpg' } }]
      };
    }
    throw new Error('未预期的请求: ' + request.url.href);
  });
  const result = await resultOf(plugin.search('wy', '旧歌曲', 3, 2));
  assert.deepEqual(
    requests.map(request => request.url.pathname),
    ['/api/cloudsearch/pc', '/cloudsearch', '/api/search/get', '/song/detail']
  );
  assert.equal(requests[0].method, 'POST');
  assert.equal(requests[0].form.offset, 4);
  assert.equal(requests[3].url.searchParams.get('ids'), '1');
  assert.equal(result.total, null);
  assert.equal(result.isEnd, false);
  assert.equal(result.limit, 2);
  assert.equal(result.offset, 4);
  assert.equal(result.page, 3);
  assert.equal(result.list[0].singer, '歌手');
  assert.equal(result.list[0].albumName, '旧专辑');
  assert.equal(result.list[0].duration, 180);
  assert.equal(
    result.list[0].artwork,
    'https://p1.music.126.net/cover.jpg?param=400y400',
    '老接口的歌曲补上了封面'
  );
});

test('cloudsearch 响应的歌曲自带封面，不再额外补图', async () => {
  const { plugin, requests } = loadPlugin(request => {
    assert.equal(request.url.pathname, '/api/cloudsearch/pc');
    assert.equal(request.method, 'POST');
    return {
      code: 200,
      result: {
        songCount: 293,
        songs: [{
          id: 1, name: '歌', duration: 180000,
          ar: [{ name: '歌手' }],
          al: { name: '专辑', picUrl: 'http://p2.music.126.net/al.jpg' }
        }]
      }
    };
  });
  const result = await resultOf(plugin.search('wy', '陈奕迅', 1, 30));
  assert.equal(requests.length, 1);
  assert.equal(result.total, 293);
  assert.equal(result.list[0].artwork, 'https://p2.music.126.net/al.jpg?param=400y400');
});

test('作者匿名 6452：total=580，offset=550 返回最后 30 首', async () => {
  const route = pagedRoutes.find(route => route.pathname === '/api/v1/artist/songs');
  const result = await pagedFixture(route, 580, 30, 12, { more: false });
  assert.equal(result.offset, 550);
  assert.equal(result.total, 580);
  assert.equal(result.artistItem.worksNum, 580);
  assert.equal(result.isEnd, true);
});

test('作者回退只使用支持分页的 /artist/songs，不请求 top/song 或 /artists', async () => {
  for (const successAt of [2, 3]) {
    const { plugin, requests } = loadPlugin((request, index) => {
      assert.ok(['/api/v1/artist/songs', '/artist/songs'].includes(request.url.pathname));
      assert.equal(request.url.searchParams.get('offset'), '50');
      assert.equal(request.url.searchParams.get('limit'), '50');
      assert.equal(request.url.searchParams.get('order'), 'hot');
      if (index < successAt) throw new Error(`offline-${index}`);
      return { code: 200, songs: items(30, 51), total: '80', more: false };
    });
    const result = await resultOf(plugin.getArtistWorks('wy', { raw: { id: 6452 } }, 2));
    assert.equal(requests.length, successAt);
    assert.equal(result.musicList[0].id, '51');
    assert.equal(result.total, 80);
    assert.equal(result.isEnd, true);
  }
  const { plugin, requests } = loadPlugin(() => { throw new Error('artist-offline'); });
  await assert.rejects(plugin.getArtistWorks('wy', { id: 6452 }, 1), /artist-offline/);
  assert.deepEqual(requests.map(request => request.url.pathname), [
    '/api/v1/artist/songs', '/artist/songs', '/artist/songs'
  ]);
});

test('专辑搜索误返全部 592 条时，首/中/末/越界页按全局 offset 切片', async () => {
  for (const successAt of [1, 2, 3, 4]) {
    for (const [page, length, firstId, isEnd] of [
      [1, 30, '1', false], [5, 30, '121', false], [20, 22, '571', true], [21, 0, undefined, true]
    ]) {
      const { plugin, requests } = loadPlugin((request, index) => {
        if (index < successAt) throw new Error('search-offline');
        return { code: 200, result: { albumCount: '592', albums: items(592), hasMore: false } };
      });
      const result = await resultOf(plugin.searchTyped('wy', '周杰伦', page, 30, 'album'));
      assert.equal(requests.length, successAt);
      assert.equal(result.list.length, length);
      assert.equal(result.list[0]?.id, firstId);
      assert.equal(result.offset, (page - 1) * 30);
      assert.equal(result.limit, 30);
      assert.equal(result.total, 592);
      assert.equal(result.isEnd, isEnd);
    }
  }
});

test('专辑搜索超长但非全量的页不能误用全局 offset 切成空页', async () => {
  for (const total of [592, '592', undefined, 10]) {
    const { plugin } = loadPlugin(() => ({
      code: 200, result: { albumCount: total, albums: items(40, 571) }
    }));
    const result = await resultOf(plugin.searchTyped('wy', '周杰伦', 20, 30, 'album'));
    assert.equal(result.list.length, 40);
    assert.equal(result.list[0].id, '571');
    assert.equal(result.list[39].id, '610');
  }
});

test('专辑详情全量返回，size 优先且保留零，无有效 size 时使用全量歌曲数', async () => {
  for (const nested of [true, false]) {
    for (const [size, expected] of [[75, 75], ['75', 75], [0, 0], ['0', 0], [undefined, 75], [null, 75], ['bad', 75]]) {
      const songs = items(75);
      const album = { id: 10, name: '专辑', size, ...(nested ? { songs } : {}) };
      const { plugin, requests } = loadPlugin(request => {
        assert.equal(request.url.pathname, '/api/album/10');
        return { code: 200, album, ...(nested ? {} : { songs }) };
      });
      const result = await resultOf(plugin.getAlbumInfo('wy', { id: 10 }, 3));
      assert.equal(requests.length, 1);
      assert.equal(result.total, expected);
      assert.equal(result.albumItem.worksNum, expected);
      assert.equal(result.musicList.length, 75);
      assert.equal(result.isEnd, true);
    }
  }
});

const detailRoutes = [
  { name: '歌单', call: (plugin, page) => plugin.getMusicSheetInfo('wy_99', page) },
  { name: '榜单', call: (plugin, page) => plugin.getTopListDetail('99', page) }
];

for (const route of detailRoutes) {
  test(`${route.name}详情按页取歌：第 1 页 50 首，第 2 页接着取，元数据复用`, async () => {
    const tracks = items(120);
    const { plugin, requests } = loadPlugin((request, index) => {
      if (index === 1) {
        assert.equal(request.url.pathname, '/api/v3/playlist/detail');
        assert.equal(request.url.searchParams.get('id'), '99');
        assert.equal(request.url.searchParams.get('n'), '0');
        return { code: 200, playlist: {
          id: 99, name: '完整歌单', trackCount: '120',
          trackIds: tracks.map(track => ({ id: track.id }))
        } };
      }
      assert.equal(request.url.pathname, '/api/song/detail');
      const ids = JSON.parse(request.url.searchParams.get('ids'));
      return { code: 200, songs: ids.map(song) };
    });

    const first = await resultOf(route.call(plugin, 1));
    assert.equal(first.limit, 50);
    assert.equal(first.offset, 0);
    assert.equal(first.total, 120);
    assert.equal(first.isEnd, false);
    assert.equal(first.sheet.songCount, 120);
    assert.equal(first.sheet.title, '完整歌单');
    assert.deepEqual(first.songs.map(song => song.id), items(50).map(song => String(song.id)));

    const second = await resultOf(route.call(plugin, 2));
    assert.equal(second.offset, 50);
    assert.equal(second.isEnd, false);
    assert.deepEqual(
      second.songs.map(song => song.id),
      items(50, 51).map(song => String(song.id))
    );

    // 翻页复用歌单元数据，只额外请求当前页的歌曲详情
    assert.equal(requests.length, 3);
    assert.deepEqual(
      requests.slice(1).map(request => JSON.parse(request.url.searchParams.get('ids'))),
      [items(50).map(song => song.id), items(50, 51).map(song => song.id)]
    );
  });

  test(`${route.name}详情末页截短并标记 isEnd，越界页返回空`, async () => {
    const tracks = items(120);
    const { plugin, requests } = loadPlugin((request, index) => {
      if (index === 1) return { code: 200, playlist: {
        id: 99, name: '完整歌单', trackCount: 120,
        trackIds: tracks.map(track => ({ id: track.id }))
      } };
      const ids = JSON.parse(request.url.searchParams.get('ids'));
      return { code: 200, songs: ids.map(song) };
    });

    const last = await resultOf(route.call(plugin, 3));
    assert.equal(last.offset, 100);
    assert.equal(last.songs.length, 20);
    assert.equal(last.isEnd, true);
    assert.deepEqual(last.songs.map(song => song.id), items(20, 101).map(song => String(song.id)));

    const overflow = await resultOf(route.call(plugin, 4));
    assert.equal(overflow.songs.length, 0);
    assert.equal(overflow.isEnd, true);
    assert.equal(requests.length, 2);
  });

  test(`${route.name}详情以 trackIds 长度判定末页，trackCount 偏大不会出现空尾页`, async () => {
    const tracks = items(120);
    const { plugin } = loadPlugin((request, index) => index === 1
      ? { code: 200, playlist: {
        trackCount: 500, trackIds: tracks.map(track => ({ id: track.id }))
      } }
      : { code: 200, songs: JSON.parse(request.url.searchParams.get('ids')).map(song) });
    const result = await resultOf(route.call(plugin, 3));
    assert.equal(result.sheet.songCount, 500, '展示的总数仍用上游 trackCount');
    assert.equal(result.total, 120, '页数按实际可取的 trackIds 计算');
    assert.equal(result.songs.length, 20);
    assert.equal(result.isEnd, true);
  });

  test(`${route.name}详情 total/songCount 保留零，未知总数时用实际可取的歌曲数`, async () => {
    for (const [trackCount, expectedTotal, expectedCount] of [
      [0, 0, 0], ['0', 0, 0], [undefined, null, 2], [null, null, 2],
      ['', null, 2], [-1, null, 2], ['2首', null, 2]
    ]) {
      const { plugin, requests } = loadPlugin(() => ({
        code: 200, result: { trackCount, tracks: items(2) }
      }));
      const result = await resultOf(route.call(plugin, 1));
      assert.equal(result.total, expectedTotal);
      assert.equal(result.sheet.songCount, expectedCount);
      assert.equal(result.songs.length, 2);
      assert.equal(result.isEnd, true);
      assert.equal(requests.length, 1);
    }
  });

  test(`${route.name}详情补齐当前页缺失的 trackIds、尊重 ID 顺序并排除不可用歌曲`, async () => {
    const { plugin, requests } = loadPlugin((request, index) => {
      if (index === 1) return { code: 200, playlist: {
        trackCount: 6,
        trackIds: [5, 3, 1, 4, 2, 6].map(id => ({ id })),
        tracks: [song(1), song(3), { id: 5 }]
      } };
      assert.equal(request.url.pathname, '/api/song/detail');
      assert.deepEqual(JSON.parse(request.url.searchParams.get('ids')), [5, 4, 2, 6]);
      return { code: 200, songs: [song(6), song(2), song(5), { id: 4, name: '' }] };
    });
    const result = await resultOf(route.call(plugin, 1));
    assert.equal(requests.length, 2);
    assert.deepEqual(result.songs.map(song => song.id), ['5', '3', '1', '2', '6']);
    assert.ok(result.songs.every(song => song.name));
    assert.equal(result.total, 6);
    assert.equal(result.sheet.songCount, 6);
    assert.equal(result.isEnd, true);
  });

  test(`${route.name}只有 trackIds 时补齐，成功响应省略的 ID 才可排除`, async () => {
    for (const songs of [[song(2)], []]) {
      const { plugin, requests } = loadPlugin((request, index) => index === 1
        ? { code: 200, playlist: { trackCount: 2, trackIds: [{ id: 1 }, { id: 2 }] } }
        : { code: 200, songs });
      const result = await resultOf(route.call(plugin, 1));
      assert.equal(requests.length, 2);
      assert.deepEqual(result.songs.map(song => song.id), songs.map(song => String(song.id)));
      assert.equal(result.total, 2);
      assert.equal(result.isEnd, true);
    }
  });

  test(`${route.name}当前页补齐失败必须抛错，保留直连及代理错误`, async () => {
    const { plugin, requests } = loadPlugin((request, index) => {
      if (index === 1) return { code: 200, playlist: {
        trackCount: 2, tracks: [song(1)], trackIds: [{ id: 1 }, { id: 2 }]
      } };
      if (index === 2) throw new Error('direct-offline');
      if (index === 3) return { code: 503 };
      return { code: 200 };
    });
    await assert.rejects(route.call(plugin, 1), error => {
      assert.match(error.message, /direct-offline/);
      assert.match(error.message, /code=503/);
      assert.match(error.message, /缺少 songs/);
      return true;
    });
    assert.equal(requests.length, 4);
  });
}

test('500 首歌单第 10 页只请求最后一首，不重复拉前 9 页', async () => {
  const tracks = items(500);
  const batches = [];
  const { plugin, requests } = loadPlugin((request, index) => {
    if (index === 1) return { code: 200, playlist: {
      trackCount: 500, trackIds: tracks.map(track => ({ id: track.id }))
    } };
    assert.equal(request.url.pathname, '/api/song/detail');
    const ids = JSON.parse(request.url.searchParams.get('ids'));
    batches.push(ids);
    return { code: 200, songs: ids.map(song).reverse() };
  });
  const result = await resultOf(plugin.getMusicSheetInfo('99', 10));
  assert.deepEqual(batches, [[451, 452, 453, 454, 455, 456, 457, 458, 459, 460,
    461, 462, 463, 464, 465, 466, 467, 468, 469, 470, 471, 472, 473, 474, 475,
    476, 477, 478, 479, 480, 481, 482, 483, 484, 485, 486, 487, 488, 489, 490,
    491, 492, 493, 494, 495, 496, 497, 498, 499, 500]]);
  assert.equal(requests.length, 2);
  assert.deepEqual(result.songs.map(song => song.id), batches[0].map(String));
  assert.equal(result.total, 500);
  assert.equal(result.isEnd, true);
});

test('当前页歌曲详情全部失败时整页报错，不回退成空页', async () => {
  const { plugin, requests } = loadPlugin((request, index) => {
    if (index === 1) return { code: 200, playlist: {
      trackCount: 120, trackIds: items(120).map(track => ({ id: track.id }))
    } };
    throw new Error(`offline-${index}`);
  });
  await assert.rejects(plugin.getMusicSheetInfo('99', 2), /offline-2/);
  assert.equal(requests.length, 4);
});

test('歌曲详情代理接收逗号分隔 IDs，两个代理均可回退补齐', async () => {
  for (const successAt of [3, 4]) {
    const { plugin, requests } = loadPlugin((request, index) => {
      if (index === 1) return { code: 200, playlist: {
        trackCount: 3, tracks: [song(2)], trackIds: [{ id: 3 }, { id: 2 }, { id: 1 }]
      } };
      if (index === 2) {
        assert.equal(request.url.searchParams.get('ids'), '[3,1]');
        throw new Error('direct-offline');
      }
      assert.equal(request.url.pathname, '/song/detail');
      assert.equal(request.url.searchParams.get('ids'), '3,1');
      if (index < successAt) throw new Error('proxy-offline');
      return { code: 200, songs: [song(1), song(3)] };
    });
    const result = await resultOf(plugin.getMusicSheetInfo('wy:99', 1));
    assert.equal(requests.length, successAt);
    assert.deepEqual(result.songs.map(song => song.id), ['3', '2', '1']);
    assert.equal(result.isEnd, true);
  }
});

test('已知 tracks 不完整却无 trackIds 时不能仅凭 n 值标记末页', async () => {
  const { plugin, requests } = loadPlugin(() => ({
    code: 200, playlist: { trackCount: 3, tracks: [song(1)] }
  }));
  await assert.rejects(plugin.getMusicSheetInfo('99', 1), /缺少可补齐的 trackIds/);
  assert.equal(requests.length, 1);
});

test('榜单列表仍是数组，插件版本为 1.3.0', async () => {
  const { plugin } = loadPlugin(request => {
    assert.equal(request.url.pathname, '/api/toplist');
    return { code: 200, list: [{ id: 99, name: '榜单', updateFrequency: '每天更新' }] };
  });
  const result = await resultOf(plugin.getTopLists());
  assert.ok(Array.isArray(result));
  assert.equal(result.length, 1);
  assert.equal(result[0].updateFrequency, '每天更新');
  assert.equal(plugin.pluginInfo.version, '1.3.0');
});

test('单曲封面走代理优先的 song/detail', async () => {
  const { plugin, requests } = loadPlugin(request => {
    assert.equal(request.url.pathname, '/song/detail');
    assert.equal(request.url.searchParams.get('ids'), '1');
    return { code: 200, songs: [song(1)] };
  });
  assert.equal(await plugin.getPic('wy', { id: 1 }), 'https://p1.music.126.net/cover.jpg?param=400y400');
  assert.equal(requests.length, 1, '代理命中后不再请求直连');
});
