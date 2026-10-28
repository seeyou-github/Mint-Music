// QQ / 酷我 / 酷狗 数据源插件：各位置 total 与 isEnd 输出契约。
// 与 netease_data_source_test.cjs 同一套夹具方式：接管 cerumusic.request，
// 按 URL 特征路由到固定响应，不发起真实网络请求。
'use strict';

const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const PLUGIN_DIR = path.resolve(__dirname, '../plugins');

function loadPlugin(fileName, route) {
  const requests = [];
  const script = new vm.Script(readFileSync(path.join(PLUGIN_DIR, fileName), 'utf8'), {
    filename: fileName
  });
  const context = {
    module: { exports: {} },
    cerumusic: {
      async request(url, options) {
        const parsed = new URL(url);
        const request = { url: parsed, method: options.method || 'GET', form: options.form };
        requests.push(request);
        const body = route(parsed, request, requests.length);
        if (body === undefined) throw new Error('夹具未覆盖: ' + url);
        return { body: JSON.stringify(body) };
      }
    }
  };
  script.runInNewContext(context);
  return { plugin: context.module.exports, requests };
}

async function resultOf(promise) {
  return JSON.parse(await promise);
}

/** musicu.fcg 的 data 参数里按模块名找业务节点。 */
function musicuNode(request, moduleName) {
  const data = JSON.parse(request.url.searchParams.get('data') || '{}');
  for (const value of Object.values(data)) {
    if (value && value.module === moduleName) return value;
  }
  return null;
}

function range(count, start, make) {
  return Array.from({ length: count }, (_, i) => make(start + i));
}

/* ------------------------------------------------------------------ QQ 音乐 */

function qqSong(index) {
  return {
    mid: 'M' + index,
    songname: '歌' + index,
    interval: 180,
    singer: [{ name: '歌手' }],
    album: { mid: 'AM', name: '专辑' }
  };
}

test('QQ：supportedSearchTypes 包含 album', () => {
  const { plugin } = loadPlugin('数据源-QQ.js', () => undefined);
  const types = plugin.supportedSearchTypes();
  assert.ok(Array.isArray(types));
  assert.ok(types.includes('album'), 'album 应在支持列表里');
  assert.ok(!types.includes('artist'), 'QQ 侧未开放作者搜索');
});

/* --------------------------------------------------------- QQ：专辑搜索 / 详情 */

function qqAlbumSearchItem(index) {
  return {
    albumID: 700000 + index,
    albumMID: 'ALBM' + index,
    albumName: '专辑' + index,
    albumPic: 'http://y.gtimg.cn/music/photo_new/T002R180x180M000ALBM' + index + '_1.jpg',
    publicTime: '2024-06-0' + (index % 9 + 1),
    singerID: 4558,
    singerMID: 'SINGER',
    singerName: '歌手' + index,
    song_count: 10 + index
  };
}

test('QQ：专辑搜索走 SearchCgiService（search_type=2），meta.sum 当总数', async () => {
  const { plugin, requests } = loadPlugin('数据源-QQ.js', (url, request) => {
    const node = musicuNode(request, 'music.search.SearchCgiService');
    if (node) {
      const page = node.param.page_num;
      const size = node.param.num_per_page;
      const sum = 45;
      const count = page === 3 ? 5 : size;
      return {
        req_1: {
          code: 0,
          data: {
            meta: { sum },
            body: { album: { list: range(count, (page - 1) * size + 1, qqAlbumSearchItem) } }
          }
        }
      };
    }
    return undefined;
  });

  const first = await resultOf(plugin.searchTyped('tx', '周杰伦', 1, 20, 'album'));
  assert.equal(first.total, 45);
  assert.equal(first.limit, 20);
  assert.equal(first.isEnd, false, '20 < 45');
  assert.equal(first.list.length, 20);
  assert.equal(first.list[0].id, '700001');
  assert.equal(first.list[0].title, '专辑1');
  assert.equal(first.list[0].artist, '歌手1');
  assert.equal(first.list[0].worksNum, 11);
  assert.equal(first.list[0].date, '2024-06-02');
  assert.ok(first.list[0].coverUrl.includes('T002R800x800M000ALBM1.jpg'), '封面应由 albumMID 拼成 800x800');
  assert.equal(first.list[0].raw.albumMID, 'ALBM1', 'raw 须带回 albumMID 供 getAlbumInfo 使用');
  const searchReq = requests[0];
  const node = musicuNode(searchReq, 'music.search.SearchCgiService');
  assert.equal(node.param.search_type, 2);
  assert.equal(node.param.query, '周杰伦');

  const last = await resultOf(plugin.searchTyped('tx', '周杰伦', 3, 20, 'album'));
  assert.equal(last.isEnd, true, '40 + 5 >= 45');
  assert.equal(last.list.length, 5);
});

test('QQ：searchTyped 未知类型返回空列表', async () => {
  const { plugin } = loadPlugin('数据源-QQ.js', () => undefined);
  const r = await resultOf(plugin.searchTyped('tx', '周杰伦', 1, 20, 'mv'));
  assert.equal(r.list.length, 0);
  assert.equal(r.isEnd, true);
});

test('QQ：专辑详情一次全量（AlbumSongList），isEnd=true，歌曲带封面', async () => {
  const { plugin, requests } = loadPlugin('数据源-QQ.js', (url, request) => {
    const node = musicuNode(request, 'music.musichallAlbum.AlbumSongList');
    if (node) {
      const size = node.param.num;
      return {
        albumSonglist: {
          code: 0,
          data: {
            albumMid: node.param.albumMid,
            totalNum: 12,
            songList: range(12, 1, (i) => ({
              songInfo: {
                mid: 'SM' + i,
                songid: 900000 + i,
                name: '曲' + i,
                interval: 200 + i,
                singer: [{ name: '歌手' }],
                album: { mid: 'ALBM1', name: '专辑1' }
              }
            })).slice(0, size)
          }
        }
      };
    }
    return undefined;
  });

  const albumItem = { raw: { id: '700001', albumMID: 'ALBM1', title: '专辑1', artist: '歌手1', date: '2024-06-01', artwork: 'http://cover' } };

  const r = await resultOf(plugin.getAlbumInfo('tx', albumItem, 1));
  assert.equal(r.total, 12);
  assert.equal(r.isEnd, true, '专辑一次全量返回');
  assert.equal(r.musicList.length, 12);
  assert.equal(r.albumItem.title, '专辑1');
  assert.equal(r.albumItem.artist, '歌手1');
  assert.equal(r.albumItem.worksNum, 12);
  assert.equal(r.albumItem.coverUrl, 'http://cover');
  assert.equal(r.musicList[0].id, 'SM1');
  assert.equal(r.musicList[0].songId, '900001');
  assert.equal(r.musicList[0].name, '曲1');
  assert.equal(r.musicList[0].singer, '歌手');
  assert.equal(r.musicList[0].albumName, '专辑1');
  assert.equal(r.musicList[0].source, 'tx');
  assert.ok(r.musicList[0].artwork.includes('T002R800x800M000ALBM1.jpg'));
  const detailReq = requests[0];
  const node = musicuNode(detailReq, 'music.musichallAlbum.AlbumSongList');
  assert.equal(node.param.albumMid, 'ALBM1');
  assert.equal(node.param.num, 999, '一次全量取完');
});

test('QQ：专辑详情 raw 无 albumMID 时也能用 id 兜底，空专辑返回空列表', async () => {
  const { plugin } = loadPlugin('数据源-QQ.js', (url, request) => {
    const node = musicuNode(request, 'music.musichallAlbum.AlbumSongList');
    if (node) {
      return {
        albumSonglist: {
          code: 0,
          data: { totalNum: 1, songList: [{ songInfo: { mid: 'SM1', name: '曲1', singer: [{ name: '歌手' }] } }] }
        }
      };
    }
    return undefined;
  });

  const r = await resultOf(plugin.getAlbumInfo('tx', { id: '700001' }, 1));
  assert.equal(r.musicList.length, 1);
  assert.equal(r.albumItem.title, '');

  const empty = await resultOf(plugin.getAlbumInfo('tx', {}, 1));
  assert.equal(empty.musicList.length, 0);
});

test('QQ：搜索歌曲 / 歌单搜索输出 totalnum / display_num', async () => {
  const { plugin, requests } = loadPlugin('数据源-QQ.js', (url) => {
    if (url.pathname.includes('search_for_qq_cp')) {
      const page = Number(url.searchParams.get('p'));
      return {
        data: {
          song: {
            list: range(30, (page - 1) * 30 + 1, qqSong),
            totalnum: 600,
            curnum: 30
          }
        }
      };
    }
    if (url.pathname.includes('client_music_search_songlist')) {
      const page = Number(url.searchParams.get('page_no')) + 1;
      return {
        data: {
          list: [{ dissid: 'D' + page, dissname: '歌单' }],
          display_num: 91
        }
      };
    }
    return undefined;
  });

  const first = await resultOf(plugin.search('tx', '周杰伦', 1, 30));
  assert.equal(first.total, 600);
  assert.equal(first.isEnd, false);
  assert.equal(requests[0].url.searchParams.get('p'), '1');

  const last = await resultOf(plugin.search('tx', '周杰伦', 20, 30));
  assert.equal(last.isEnd, true, '570 + 30 >= 600');

  const playlists = await resultOf(plugin.searchPlaylists('华语', 4));
  assert.equal(playlists.total, 91);
  assert.equal(playlists.isEnd, true, '90 + 1 >= 91（短页）');
  assert.equal(requests[2].url.searchParams.get('page_no'), '3');
  assert.equal(playlists.playlists[0].id, 'D4');
});

test('QQ：分类歌单带分类取 content.total_cnt，不带分类取 data.total', async () => {
  const { plugin, requests } = loadPlugin('数据源-QQ.js', (url, request) => {
    if (musicuNode(request, 'playlist.PlayListCategoryServer')) {
      return {
        playlist: {
          data: {
            content: {
              total_cnt: 10,
              v_item: [{ basic: { tid: 1, title: '歌单' } }]
            }
          }
        }
      };
    }
    if (musicuNode(request, 'playlist.PlayListPlazaServer')) {
      return {
        playlist: { data: { total: 11617, v_playlist: [{ tid: 2, title: '歌单' }] } }
      };
    }
    return undefined;
  });

  const tagged = await resultOf(plugin.getRecommendSheetsByTag('3316', 1));
  assert.equal(tagged.total, 10);
  assert.equal(tagged.isEnd, false, '第 1 页 1 条 < total=10');
  assert.equal(
    musicuNode(requests[0], 'playlist.PlayListCategoryServer').param.page,
    0,
    '分类内容接口 page 从 0 开始'
  );

  const plaza = await resultOf(plugin.getRecommendSheetsByTag('', 3));
  assert.equal(plaza.total, 11617);
  assert.equal(plaza.isEnd, false);
  assert.equal(plaza.limit, 36);
});

test('QQ：榜单 / 歌单详情透出 total 与 sheet.songCount', async () => {
  const { plugin, requests } = loadPlugin('数据源-QQ.js', (url, request) => {
    if (musicuNode(request, 'musicToplist.ToplistInfoServer')) {
      return {
        toplist: {
          data: {
            songInfoList: [qqSong(1), qqSong(2)],
            data: { totalNum: 300, title: '巅峰榜' }
          }
        }
      };
    }
    if (musicuNode(request, 'music.srfDissInfo.aiDissInfo')) {
      const param = musicuNode(request, 'music.srfDissInfo.aiDissInfo').param;
      return {
        req: {
          data: {
            total_song_num: 80,
            dirinfo: { title: '歌单', songnum: 80 },
            songlist: range(param.song_begin === 50 ? 30 : 50, param.song_begin + 1, qqSong)
          }
        }
      };
    }
    return undefined;
  });

  const board = await resultOf(plugin.getTopListDetail('26', 1));
  assert.equal(board.total, 300);
  assert.equal(board.sheet.songCount, 300);
  assert.equal(board.isEnd, true, '榜单一次全量返回');

  const sheetFirst = await resultOf(plugin.getMusicSheetInfo('8825915544', 1));
  assert.equal(sheetFirst.total, 80);
  assert.equal(sheetFirst.sheet.songCount, 80);
  assert.equal(sheetFirst.limit, 50);
  assert.equal(sheetFirst.offset, 0);
  assert.equal(sheetFirst.songs.length, 50);
  assert.equal(sheetFirst.isEnd, false, '0 + 50 < 80');

  const sheetLast = await resultOf(plugin.getMusicSheetInfo('8825915544', 2));
  assert.equal(sheetLast.offset, 50);
  assert.equal(sheetLast.songs.length, 30);
  assert.equal(sheetLast.isEnd, true, '50 + 30 >= 80');
  const sheetRequest = musicuNode(requests[requests.length - 1], 'music.srfDissInfo.aiDissInfo');
  assert.equal(sheetRequest.param.song_begin, 50);
  assert.equal(sheetRequest.param.song_num, 50);
});

/* -------------------------------------------------------------------- 酷我 */

function kwSong(index) {
  // 带封面字段，避免触发逐首补图请求
  return {
    MUSICRID: 'MUSIC_' + index,
    SONGNAME: '歌' + index,
    ARTIST: '歌手',
    DURATION: 180,
    web_albumpic_short: 'cover/' + index + '.jpg'
  };
}

test('酷我：搜索歌曲 / 歌单 / 专辑 / 作者的 TOTAL 与大小写差异', async () => {
  const { plugin, requests } = loadPlugin('数据源-酷我.js', (url) => {
    const params = url.searchParams;
    if (url.hostname !== 'search.kuwo.cn') return undefined;
    const page = Number(params.get('pn')) + 1;
    if (params.get('ft') === 'music') {
      return { TOTAL: 3292, abslist: range(30, (page - 1) * 30 + 1, kwSong) };
    }
    if (params.get('ft') === 'playlist') {
      return {
        TOTAL: 150,
        abslist: range(30, (page - 1) * 30 + 1, (i) => ({
          playlistid: i,
          name: '歌单',
          songnum: 9,
          nickname: '作者'
        }))
      };
    }
    if (params.get('ft') === 'album') {
      // 专辑接口的总数是小写 total
      return { total: 106, albumlist: [{ albumid: page, name: '专辑', artist: '歌手' }] };
    }
    if (params.get('ft') === 'artist') {
      // 作者接口的总数是大写 TOTAL
      return {
        TOTAL: 58,
        abslist: range(30, (page - 1) * 30 + 1, (i) => ({ ARTISTID: i, ARTIST: '周杰伦' }))
      };
    }
    return undefined;
  });

  const songs = await resultOf(plugin.search('kw', '周杰伦', 1, 30));
  assert.equal(songs.total, 3292);
  assert.equal(songs.isEnd, false);
  assert.equal(songs.list[0].id, '1');

  const playlists = await resultOf(plugin.searchPlaylists('华语', 5));
  assert.equal(playlists.total, 150);
  assert.equal(playlists.isEnd, true, '120 + 30 >= 150');
  assert.equal(playlists.playlists[0].id, '121');

  const albums = await resultOf(plugin.searchTyped('kw', '周杰伦', 1, 30, 'album'));
  assert.equal(albums.total, 106);
  assert.equal(albums.isEnd, false);

  const artists = await resultOf(plugin.searchTyped('kw', '周杰伦', 2, 30, 'artist'));
  assert.equal(artists.total, 58, '大写 TOTAL 也要读到');
  assert.equal(artists.isEnd, true, '30 + 30 >= 58');
  assert.equal(artists.list[0].id, '31');

  assert.equal(requests[0].url.searchParams.get('ft'), 'music');
  assert.equal(requests[3].url.searchParams.get('ft'), 'artist');
});

test('酷我：分类歌单取 data.total，专辑 / 作者详情透出顶层 total', async () => {
  const { plugin, requests } = loadPlugin('数据源-酷我.js', (url) => {
    const params = url.searchParams;
    if (url.hostname === 'wapi.kuwo.cn') {
      return {
        data: {
          total: 1753,
          data: [{ id: 9, name: '歌单', digest: '8', total: 17, uname: '作者' }]
        }
      };
    }
    if (url.hostname === 'search.kuwo.cn') {
      if (params.get('stype') === 'albuminfo') {
        return { songnum: 12, name: '专辑', artist: '歌手', musiclist: [kwSong(1), kwSong(2)] };
      }
      if (params.get('stype') === 'artist2music') {
        const page = Number(params.get('pn')) + 1;
        const count = page === 3 ? 50 : 100;
        return {
          total: 250,
          musiclist: range(count, (page - 1) * 100 + 1, kwSong)
        };
      }
    }
    return undefined;
  });

  const sheets = await resultOf(plugin.getRecommendSheetsByTag('1848-8', 1));
  assert.equal(sheets.total, 1753);
  assert.equal(sheets.isEnd, false);
  assert.equal(sheets.playlists[0].id, 'digest-8__9');

  const album = await resultOf(plugin.getAlbumInfo('kw', { albumid: '1' }, 1));
  assert.equal(album.total, 12);
  assert.equal(album.isEnd, true, '专辑一次返回全部歌曲');

  const worksFirst = await resultOf(
    plugin.getArtistWorks('kw', { artistid: '336' }, 1, 'music')
  );
  assert.equal(worksFirst.total, 250);
  assert.equal(worksFirst.artistItem.worksNum, 250);
  assert.equal(worksFirst.isEnd, false);
  const typedCall = requests[requests.length - 1];
  assert.equal(typedCall.url.searchParams.get('pn'), '0');
  assert.equal(typedCall.url.searchParams.get('rn'), '100');

  const worksLast = await resultOf(
    plugin.getArtistWorks('kw', { artistid: '336' }, 3, 'music')
  );
  assert.equal(worksLast.isEnd, true, '200 + 50 >= 250');
});

test('酷我：歌单详情按 pn 翻页（total=1877，每页 50 首），榜单按 num 翻页', async () => {
  const { plugin, requests } = loadPlugin('数据源-酷我.js', (url) => {
    const params = url.searchParams;
    if (url.hostname === 'nplserver.kuwo.cn') {
      const page = Number(params.get('pn')) + 1;
      return {
        total: 1877,
        musiclist: range(page === 38 ? 27 : 50, (page - 1) * 50 + 1, kwSong),
        title: '华语',
        info: '简介'
      };
    }
    if (url.hostname === 'kbangserver.kuwo.cn') {
      const page = Number(params.get('pn')) + 1;
      return {
        num: 300,
        musiclist: range(50, (page - 1) * 50 + 1, kwSong),
        title: '飙升榜'
      };
    }
    return undefined;
  });

  const sheetFirst = await resultOf(plugin.getMusicSheetInfo('3690679141', 1));
  assert.equal(sheetFirst.total, 1877);
  assert.equal(sheetFirst.sheet.songCount, 1877);
  assert.equal(sheetFirst.limit, 50);
  assert.equal(sheetFirst.isEnd, false, '第 1 页 50 < 1877');
  assert.equal(sheetFirst.songs.length, 50);
  assert.equal(requests[0].url.searchParams.get('pn'), '0');
  assert.equal(requests[0].url.searchParams.get('rn'), '50');

  const sheetSecond = await resultOf(plugin.getMusicSheetInfo('3690679141', 2));
  assert.equal(sheetSecond.isEnd, false, '100 < 1877');
  assert.equal(requests[1].url.searchParams.get('pn'), '1', '第 2 页 pn=1');
  assert.equal(sheetSecond.songs[0].id, '51');

  const sheetLast = await resultOf(plugin.getMusicSheetInfo('3690679141', 38));
  assert.equal(sheetLast.isEnd, true, '1850 + 27 >= 1877');
  assert.equal(sheetLast.songs.length, 27);
  assert.equal(requests[2].url.searchParams.get('pn'), '37');
  assert.equal(sheetLast.songs[0].id, '1851');

  const boardLast = await resultOf(plugin.getTopListDetail('93', 6));
  assert.equal(boardLast.total, 300);
  assert.equal(boardLast.sheet.songCount, 300);
  assert.equal(boardLast.isEnd, true, '250 + 50 >= 300');
  assert.equal(requests[3].url.searchParams.get('pn'), '5');
  assert.equal(requests[3].url.searchParams.get('rn'), '50');
});

/* -------------------------------------------------------------------- 酷狗 */

function kgSong(index) {
  return {
    FileHash: 'HASH' + index,
    SongName: '歌' + index,
    SingerName: '歌手',
    Duration: 180,
    album_info: { sizable_cover: 'http://img/cover/{size}.jpg' }
  };
}

test('酷狗：搜索歌曲 / 歌单取 data.total', async () => {
  const { plugin, requests } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.hostname === 'songsearch.kugou.com') {
      const page = Number(url.searchParams.get('page'));
      return { data: { total: 480, lists: range(30, (page - 1) * 30 + 1, kgSong) } };
    }
    if (url.hostname === 'msearchretry.kugou.com') {
      const page = Number(url.searchParams.get('page'));
      return {
        data: {
          total: 480,
          info: range(30, (page - 1) * 30 + 1, (i) => ({
            specialid: i,
            specialname: '歌单',
            songcount: 9,
            nickname: '作者'
          }))
        }
      };
    }
    return undefined;
  });

  const songs = await resultOf(plugin.search('kg', '周杰伦', 1, 30));
  assert.equal(songs.total, 480);
  assert.equal(songs.isEnd, false);
  assert.equal(songs.list[0].id, 'HASH1');

  const playlists = await resultOf(plugin.searchPlaylists('华语', 16));
  assert.equal(playlists.total, 480);
  assert.equal(playlists.isEnd, true, '450 + 30 >= 480');
  assert.equal(requests[1].url.searchParams.get('page'), '16');
  assert.equal(playlists.playlists[0].id, '451');
});

test('酷狗：分类歌单接口无总数（total=null），固定 20 条/页判底', async () => {
  const { plugin } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.hostname === 'www2.kugou.kugou.com') {
      const page = Number(url.searchParams.get('p'));
      return {
        status: 1,
        special_db: range(page === 1 ? 20 : 8, page * 100, (i) => ({
          specialid: i,
          specialname: '歌单',
          song_count: 5,
          nickname: '作者'
        }))
      };
    }
    return undefined;
  });

  const first = await resultOf(plugin.getRecommendSheetsByTag('', 1));
  assert.equal(first.total, null, 'getSpecial 不返回总数');
  assert.equal(first.limit, 20);
  assert.equal(first.isEnd, false, '整页 20 条 → 还有下一页');
  assert.equal(first.playlists.length, 20);

  const second = await resultOf(plugin.getRecommendSheetsByTag('', 2));
  assert.equal(second.isEnd, true, '短页 8 条 → 到底');
  assert.equal(second.playlists.length, 8);
});

test('酷狗：歌单详情 songcount / data.total，榜单 data.total=500 按 50 首一页翻', async () => {
  const rankSongPages = [];
  const { plugin } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/special/song')) {
      const page = Number(url.searchParams.get('page'));
      return {
        data: {
          total: 1234,
          info: range(page === 25 ? 34 : 50, (page - 1) * 50 + 1, kgSong)
        }
      };
    }
    if (url.pathname.includes('/special/info')) {
      return { data: { songcount: 1234, specialname: '歌单', nickname: '作者' } };
    }
    if (url.pathname.includes('/rank/list')) {
      return {
        data: { info: [{ isvol: '1', rankid: 8888, rankname: 'TOP500', banner_9: 'http://img/{size}' }] }
      };
    }
    if (url.pathname.includes('/rank/song')) {
      const page = Number(url.searchParams.get('page'));
      rankSongPages.push(page);
      return {
        data: { total: 500, info: range(50, (page - 1) * 50 + 1, kgSong) }
      };
    }
    return undefined;
  });

  const sheetFirst = await resultOf(plugin.getMusicSheetInfo('64463', 1));
  assert.equal(sheetFirst.total, 1234);
  assert.equal(sheetFirst.sheet.songCount, 1234);
  assert.equal(sheetFirst.limit, 50);
  assert.equal(sheetFirst.isEnd, false, '第 1 页 50 < 1234');
  assert.equal(sheetFirst.songs.length, 50);

  const sheetSecond = await resultOf(plugin.getMusicSheetInfo('64463', 2));
  assert.equal(sheetSecond.total, 1234, '第 2 页从 data.total 取总数');
  assert.equal(sheetSecond.isEnd, false, '100 < 1234');
  assert.equal(sheetSecond.songs.length, 50);

  const sheetLast = await resultOf(plugin.getMusicSheetInfo('64463', 25));
  assert.equal(sheetLast.isEnd, true, '1200 + 34 >= 1234');
  assert.equal(sheetLast.songs.length, 34);

  const boardFirst = await resultOf(plugin.getTopListDetail('8888', 1));
  assert.equal(boardFirst.total, 500);
  assert.equal(boardFirst.sheet.title, 'TOP500');
  assert.equal(boardFirst.isEnd, false, '榜单不再一次判死，50 < 500');

  const boardLast = await resultOf(plugin.getTopListDetail('8888', 10));
  assert.equal(boardLast.isEnd, true, '450 + 50 >= 500');
  assert.deepEqual(rankSongPages, [1, 10], 'rank/song 的 page 参数逐页递增');
});

/* ------------------------------------------------------- 酷狗：专辑搜索 / 详情 */

function kgAlbum(index) {
  return {
    albumid: 900000 + index,
    albumname: '专辑<em>' + index + '</em>',
    singername: '<em>歌手</em>' + index,
    imgurl: 'http://imge.kugou.com/stdmusic/{size}/20240101/cover' + index + '.jpg',
    publishtime: '2024-01-0' + (index % 9 + 1) + ' 00:00:00',
    songcount: 10 + index,
    intro: '简介' + index
  };
}

function kgAlbumSong(index) {
  return {
    hash: 'AHASH' + index,
    filename: '歌手' + index + ' - 曲' + index,
    duration: 180 + index,
    album_id: '900001',
    album_audio_id: 30000000 + index,
    trans_param: { union_cover: 'http://imge.kugou.com/stdmusic/{size}/20240101/cover1.jpg' },
    remark: '专辑1'
  };
}

test('酷狗：supportedSearchTypes 包含 album 与 artist', () => {
  const { plugin } = loadPlugin('数据源-酷狗.js', () => undefined);
  const types = plugin.supportedSearchTypes();
  assert.ok(Array.isArray(types));
  assert.ok(types.includes('album'), 'album 应在支持列表里');
  assert.ok(types.includes('artist'), 'artist 应在支持列表里');
});

test('酷狗：专辑搜索取 data.total，<em> 标签剥掉，raw 带回 albumid', async () => {
  const { plugin, requests } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/search/album')) {
      const page = Number(url.searchParams.get('page'));
      const size = Number(url.searchParams.get('pagesize'));
      return {
        data: {
          total: 42,
          info: range(page === 3 ? 2 : size, (page - 1) * size + 1, kgAlbum)
        }
      };
    }
    return undefined;
  });

  const first = await resultOf(plugin.searchTyped('kg', '周杰伦', 1, 20, 'album'));
  assert.equal(first.total, 42);
  assert.equal(first.limit, 20);
  assert.equal(first.isEnd, false, '20 < 42');
  assert.equal(first.list.length, 20);
  assert.equal(first.list[0].id, '900001');
  assert.equal(first.list[0].title, '专辑1', '<em> 标签应剥掉');
  assert.equal(first.list[0].artist, '歌手1', '<em> 标签应剥掉');
  assert.equal(first.list[0].worksNum, 11);
  assert.equal(first.list[0].date, '2024-01-02');
  assert.equal(first.list[0].raw.albumid, '900001', 'raw 须带回 albumid 供 getAlbumInfo 使用');
  assert.ok(first.list[0].coverUrl.startsWith('https://'), '封面应升级为 https');
  assert.equal(requests[0].url.searchParams.get('keyword'), '周杰伦');

  const last = await resultOf(plugin.searchTyped('kg', '周杰伦', 3, 20, 'album'));
  assert.equal(last.isEnd, true, '40 + 2 >= 42');
  assert.equal(last.list.length, 2);
});

test('酷狗：searchTyped 未知类型返回空列表', async () => {
  const { plugin } = loadPlugin('数据源-酷狗.js', () => undefined);
  const r = await resultOf(plugin.searchTyped('kg', '周杰伦', 1, 20, 'mv'));
  assert.equal(r.list.length, 0);
  assert.equal(r.isEnd, true);
});

/* ------------------------------------------------------- 酷狗：作者搜索 / 作品 */

function kgSinger(id, name) {
  return { singerid: id, singername: name };
}

function kgSingerInfo(id, name) {
  return {
    singerid: id,
    singername: name,
    songcount: 1000 + id,
    imgurl: 'http://singerimg.kugou.com/uploadpic/softhead/{size}/20260324/avatar' + id + '.jpg',
    profile: '简介' + id
  };
}

function kgSingerSong(index) {
  return {
    hash: 'SHASH' + index,
    filename: '歌手 - 曲' + index,
    duration: 200 + index,
    album_id: '800000' + index,
    album_name: '专辑' + index,
    album_audio_id: 90000000 + index,
    trans_param: { union_cover: 'http://imge.kugou.com/stdmusic/{size}/20240101/c' + index + '.jpg' }
  };
}

test('酷狗：作者搜索补 singer/info（头像 / 作品数 / 简介），data 为数组且无总数', async () => {
  const { plugin, requests } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/search/singer')) {
      // 该接口 data 直接是数组，无 total，固定最多 10 条
      return { status: 1, data: [kgSinger(3520, '周杰伦'), kgSinger(720479, '情敌周杰伦')] };
    }
    if (url.pathname.includes('/api/v3/singer/info')) {
      const id = Number(url.searchParams.get('singerid'));
      return { status: 1, data: kgSingerInfo(id, '名字' + id) };
    }
    return undefined;
  });

  const r = await resultOf(plugin.searchTyped('kg', '周杰伦', 1, 20, 'artist'));
  assert.equal(r.total, null, 'search/singer 不返回总数');
  assert.equal(r.limit, 20);
  assert.equal(r.isEnd, true, '2 < 20 → 到底');
  assert.equal(r.list.length, 2);
  assert.equal(r.list[0].id, '3520');
  assert.equal(r.list[0].title, '周杰伦');
  assert.equal(r.list[0].worksNum, 1000 + 3520, '作品数来自 singer/info');
  assert.ok(r.list[0].coverUrl.startsWith('https://singerimg'), '头像应升级为 https');
  assert.equal(r.list[0].description, '简介3520');
  assert.equal(r.list[0].raw.singerid, '3520', 'raw 须带回 singerid 供 getArtistWorks 使用');
  // 1 次搜索 + 2 次 singer/info
  assert.equal(requests.length, 3);
});

test('酷狗：作者搜索 singer/info 失败时不影响列表', async () => {
  const { plugin } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/search/singer')) {
      return { status: 1, data: [kgSinger(3520, '周杰伦')] };
    }
    if (url.pathname.includes('/api/v3/singer/info')) {
      throw new Error('接口挂了');
    }
    return undefined;
  });

  const r = await resultOf(plugin.searchTyped('kg', '周杰伦', 1, 20, 'artist'));
  assert.equal(r.list.length, 1);
  assert.equal(r.list[0].worksNum, 0);
  assert.equal(r.list[0].coverUrl, '');
});

test('酷狗：作者作品按 50 首一页翻，第 1 页取 singer/info，翻页不再取', async () => {
  const songPages = [];
  const { plugin, requests } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/singer/song')) {
      const page = Number(url.searchParams.get('page'));
      songPages.push(page);
      const size = Number(url.searchParams.get('pagesize'));
      const total = 130;
      const count = page === 3 ? 30 : size;
      return { status: 1, data: { total, info: range(count, (page - 1) * size + 1, kgSingerSong) } };
    }
    if (url.pathname.includes('/api/v3/singer/info')) {
      return { status: 1, data: kgSingerInfo(3520, '周杰伦') };
    }
    return undefined;
  });

  const artistItem = { raw: { id: '3520', singerid: '3520', name: '周杰伦' } };

  const p1 = await resultOf(plugin.getArtistWorks('kg', artistItem, 1, 'music'));
  assert.equal(p1.total, 130);
  assert.equal(p1.limit, 50);
  assert.equal(p1.isEnd, false, '50 < 130');
  assert.equal(p1.musicList.length, 50);
  assert.equal(p1.artistItem.title, '周杰伦');
  assert.equal(p1.artistItem.worksNum, 130);
  assert.equal(p1.artistItem.description, '简介3520');
  assert.ok(p1.artistItem.coverUrl.startsWith('https://singerimg'));
  assert.equal(p1.musicList[0].id, 'SHASH1');
  assert.equal(p1.musicList[0].name, '曲1');
  assert.equal(p1.musicList[0].singer, '歌手');
  assert.equal(p1.musicList[0].source, 'kg');
  assert.ok(p1.musicList[0].artwork.startsWith('https://'));
  assert.equal(requests.filter((r) => r.url.pathname.includes('/singer/info')).length, 1, 'singer/info 只在第 1 页请求');

  const p2 = await resultOf(plugin.getArtistWorks('kg', artistItem, 2, 'music'));
  assert.equal(p2.isEnd, false, '100 < 130');
  assert.equal(requests.filter((r) => r.url.pathname.includes('/singer/info')).length, 1, '翻页不再请求 singer/info');

  const p3 = await resultOf(plugin.getArtistWorks('kg', artistItem, 3, 'music'));
  assert.equal(p3.isEnd, true, '100 + 30 >= 130');
  assert.equal(p3.musicList.length, 30);
  assert.deepEqual(songPages, [1, 2, 3], 'singer/song 的 page 参数逐页递增');
});

test('酷狗：作者作品 raw 没有 singerid 时按名字反查', async () => {
  const { plugin, requests } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/search/singer')) {
      return { status: 1, data: [kgSinger(111, '别人'), kgSinger(3520, '周杰伦')] };
    }
    if (url.pathname.includes('/api/v3/singer/song')) {
      return { status: 1, data: { total: 1, info: [kgSingerSong(1)] } };
    }
    if (url.pathname.includes('/api/v3/singer/info')) {
      return { status: 1, data: kgSingerInfo(3520, '周杰伦') };
    }
    return undefined;
  });

  const r = await resultOf(
    plugin.getArtistWorks('kg', { raw: { name: '周杰伦' } }, 1, 'music')
  );
  assert.equal(r.musicList.length, 1);
  assert.equal(r.artistItem.id, '3520', '按名字精确匹配到 singerid');
  const searchReq = requests.find((r) => r.url.pathname.includes('/search/singer'));
  assert.equal(searchReq.url.searchParams.get('keyword'), '周杰伦');
});

test('酷狗：作者作品 singerid 反查不到时返回空 musicList', async () => {
  const { plugin } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/search/singer')) {
      return { status: 1, data: [] };
    }
    return undefined;
  });

  const r = await resultOf(
    plugin.getArtistWorks('kg', { raw: { name: '不存在' } }, 1, 'music')
  );
  assert.equal(r.musicList.length, 0);
});

test('酷狗：专辑详情第 1 页取 album/info 元数据，翻页只取 album/song', async () => {
  const albumSongPages = [];
  const { plugin, requests } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/album/song')) {
      const page = Number(url.searchParams.get('page'));
      albumSongPages.push(page);
      const size = Number(url.searchParams.get('pagesize'));
      const total = 120;
      const count = page === 3 ? 20 : size;
      return {
        data: { total, info: range(count, (page - 1) * size + 1, kgAlbumSong) }
      };
    }
    if (url.pathname.includes('/api/v3/album/info')) {
      return {
        data: {
          albumid: 900001,
          albumname: '专辑1',
          singername: '歌手1',
          imgurl: 'http://imge.kugou.com/stdmusic/{size}/20240101/cover1.jpg',
          publishtime: '2024-01-02 00:00:00',
          intro: '专辑简介',
          songcount: 0
        }
      };
    }
    return undefined;
  });

  const albumItem = { raw: { id: '900001', albumid: '900001', artwork: 'http://x/{size}.jpg', title: '专辑1' } };

  const p1 = await resultOf(plugin.getAlbumInfo('kg', albumItem, 1));
  assert.equal(p1.total, 120);
  assert.equal(p1.limit, 50);
  assert.equal(p1.isEnd, false, '50 < 120');
  assert.equal(p1.musicList.length, 50);
  assert.equal(p1.albumItem.title, '专辑1');
  assert.equal(p1.albumItem.artist, '歌手1');
  assert.equal(p1.albumItem.date, '2024-01-02');
  assert.equal(p1.albumItem.worksNum, 120);
  assert.equal(p1.musicList[0].id, 'AHASH1');
  assert.equal(p1.musicList[0].name, '曲1');
  assert.equal(p1.musicList[0].singer, '歌手1');
  assert.equal(p1.musicList[0].albumName, '专辑1');
  assert.equal(p1.musicList[0].source, 'kg');
  assert.ok(p1.musicList[0].artwork.startsWith('https://'), '封面应升级为 https');
  // 第 1 页同时请求 album/song 和 album/info
  assert.equal(requests.filter((r) => r.url.pathname.includes('/album/info')).length, 1);

  const p2 = await resultOf(plugin.getAlbumInfo('kg', albumItem, 2));
  assert.equal(p2.isEnd, false, '100 < 120');
  assert.equal(p2.musicList.length, 50);
  // 第 2 页不再请求 album/info
  assert.equal(requests.filter((r) => r.url.pathname.includes('/album/info')).length, 1, 'album/info 只在第 1 页请求');

  const p3 = await resultOf(plugin.getAlbumInfo('kg', albumItem, 3));
  assert.equal(p3.isEnd, true, '100 + 20 >= 120');
  assert.equal(p3.musicList.length, 20);
  assert.deepEqual(albumSongPages, [1, 2, 3], 'album/song 的 page 参数逐页递增');
});

test('酷狗：专辑详情 albumItem 无 raw 时直接用 id', async () => {
  const { plugin } = loadPlugin('数据源-酷狗.js', (url) => {
    if (url.pathname.includes('/api/v3/album/song')) {
      return { data: { total: 1, info: [kgAlbumSong(1)] } };
    }
    if (url.pathname.includes('/api/v3/album/info')) {
      return { data: { albumname: '直接ID', singername: '歌手', imgurl: '', publishtime: '', intro: '' } };
    }
    return undefined;
  });

  const r = await resultOf(plugin.getAlbumInfo('kg', { id: '900001' }, 1));
  assert.equal(r.musicList.length, 1);
  assert.equal(r.albumItem.title, '直接ID');
});

test('酷狗：专辑详情 albumId 为空时返回空 musicList', async () => {
  const { plugin } = loadPlugin('数据源-酷狗.js', () => undefined);
  const r = await resultOf(plugin.getAlbumInfo('kg', {}, 1));
  assert.equal(r.musicList.length, 0);
});
