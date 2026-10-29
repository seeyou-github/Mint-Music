/*
 * MintMusic 数据源插件 —— QQ音乐
 * ---------------------------------------------------------------------------
 * 与 netease_music_data_source.js 同一套约定：只提供搜索 / 发现页（歌单分类、
 * 榜单、歌单详情）/ 歌词等**元数据**，**不提供播放地址**（没有 musicUrl）。
 *
 * 数据源标记：pluginInfo.isDataSource === true
 *   · 导入后归到「插件管理 → 数据源」分类；
 *   · 在数据源里指定一个已安装的播放源，播放时由它解析地址。
 *
 * 接口与内置源 QQ音乐（lib/features/plugin/data/tx_music_source.dart）一致：
 *   · 搜索 / 歌单搜索走 c.y.qq.com 的老接口（无需签名）；
 *   · 分类、分类歌单、歌单详情、榜单详情走 u.y.qq.com/cgi-bin/musicu.fcg；
 *   · 播放量格式：> 1 亿 → 「x.x亿」，> 1 万 → 「x.x万」，否则原样整数。
 * ---------------------------------------------------------------------------
 */

var UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
var YQQ = 'https://c.y.qq.com';
var MUSICU = 'https://u.y.qq.com/cgi-bin/musicu.fcg';
var HEADERS = {
  'User-Agent': UA,
  'Referer': 'https://y.qq.com/',
  'Origin': 'https://y.qq.com'
};

/* ---------------------------------------------------------------- 基础工具 */

function encodeQuery(params) {
  var parts = [];
  for (var key in params) {
    if (!Object.prototype.hasOwnProperty.call(params, key)) continue;
    var value = params[key];
    if (value === undefined || value === null) continue;
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
  }
  return parts.join('&');
}

function decodeBody(res) {
  var body = res && res.body;
  if (typeof body === 'string') {
    try {
      body = JSON.parse(body);
    } catch (e) {
      /* 保持原样 */
    }
  }
  if (!body || typeof body !== 'object') {
    var text = body === undefined || body === null ? '' : String(body);
    throw new Error('接口返回异常：' + text.substring(0, 120));
  }
  return body;
}

function getJson(url, headers) {
  return cerumusic
    .request(url, {
      method: 'GET',
      headers: Object.assign({}, HEADERS, headers || {}),
      timeout: 15000
    })
    .then(decodeBody);
}

/** 接口总数容错解析：只接受非负整数，异常一律视为「未知」。 */
function totalOf(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && !value.trim()) return null;
  var total = Number(value);
  return isFinite(total) && total >= 0 && Math.floor(total) === total &&
    total <= 9007199254740991 ? total : null;
}

/**
 * 是否翻到头了。有总数按总数判；接口给 more / hasMore 时以它为准；
 * 都没有才退化成「本页不足一页」（QQ 分类歌单接口不回总数时只能这么判）。
 */
function isPageEnd(total, offset, count, limit, body) {
  if (total !== null) return offset + count >= total;
  if (typeof body.more === 'boolean') return !body.more;
  if (typeof body.hasMore === 'boolean') return !body.hasMore;
  return count < limit;
}

/** musicu.fcg 的通用调用（GET + data=JSON，与内置源一致，无需签名）。 */
function musicu(data, modules) {
  var url =
    MUSICU +
    '?loginUin=0&hostUin=0&format=json&inCharset=utf-8&outCharset=utf-8' +
    '&notice=0&platform=wk_v15.json&needNewCode=0&data=' +
    encodeURIComponent(JSON.stringify(data));
  return getJson(url).then(function (body) {
    if (modules) {
      for (var i = 0; i < modules.length; i++) {
        var node = body[modules[i]];
        if (node && node.code !== undefined && Number(node.code) !== 0) {
          throw new Error('接口返回 code=' + node.code);
        }
      }
    }
    return body;
  });
}

/* ---------------------------------------------------------------- 字段映射 */

/**
 * 播放量格式化 —— 与内置源 _formatPlayCount 完全一致：
 *   > 100000000 → 「x.x亿」，> 10000 → 「x.x万」，否则整数。
 */
function formatPlayCount(count) {
  if (count === undefined || count === null) return '';
  var raw = String(count).replace(/[^0-9.]/g, '');
  if (raw === '') return String(count);
  var value = Number(raw);
  if (isNaN(value)) return String(count);
  if (value > 100000000) return (value / 100000000).toFixed(1) + '亿';
  if (value > 10000) return (value / 10000).toFixed(1) + '万';
  // 不足 1 万：用 K 为单位（1234 → 1.2K）
  if (value >= 1000) return (value / 1000).toFixed(1) + 'K';

  return String(Math.floor(value));
}

function singersOf(item) {
  var singers = item.singer || item.singers || [];
  if (!singers || !singers.length) return '';
  var names = [];
  for (var i = 0; i < singers.length; i++) {
    var name = singers[i] && singers[i].name;
    if (name) names.push(String(name));
  }
  return names.join('、');
}

function albumMidOf(item) {
  if (item.albummid) return String(item.albummid);
  if (item.album && item.album.mid) return String(item.album.mid);
  return '';
}

function albumNameOf(item) {
  if (item.albumname) return String(item.albumname);
  if (item.album && item.album.name) return String(item.album.name);
  return '';
}

function coverOfAlbumMid(mid) {
  if (!mid) return '';
  return 'https://y.gtimg.cn/music/photo_new/T002R800x800M000' + mid + '.jpg';
}

/** 歌手头像由 singerMID 拼 500x500（接口返回的只有 150x150）。 */
function coverOfSingerMid(mid) {
  if (!mid) return '';
  return 'https://y.gtimg.cn/music/photo_new/T001R500x500M000' + mid + '.jpg';
}

/** 搜索 / 歌单 / 榜单里的歌曲 → 插件歌曲结构（时长单位：秒）。 */
function songOf(item) {
  if (!item) return null;
  var mid = item.songmid || item.mid || '';
  if (!mid) return null;
  var interval = Number(item.interval) || 0;
  return {
    id: String(mid),
    songId: String(item.songid || item.id || mid),
    songmid: String(mid),
    name: item.songname || item.name || item.title || '',
    singer: singersOf(item),
    albumName: albumNameOf(item),
    albumId: albumMidOf(item) || '',
    // 发行年份：搜索结果里是 pubtime（秒）/ time_public（字符串）
    year: yearOfTimestamp(item.pubtime || item.publish_time || item.time_public),
    artwork: coverOfAlbumMid(albumMidOf(item)),
    duration: interval > 0 ? interval : 0,
    source: 'tx'
  };
}

/** 时间戳（秒 / 毫秒）或 'YYYY-MM-DD' → 年份；取不到返回 0。 */
function yearOfTimestamp(value) {
  if (value === undefined || value === null || value === '') return 0;
  var text = String(value).trim();
  var dateMatch = /^(\d{4})[-/]/.exec(text);
  if (dateMatch) return Number(dateMatch[1]) || 0;
  var num = Number(text);
  if (!num || num <= 0) return 0;
  if (num < 100000000000) num = num * 1000; // 秒 → 毫秒
  var year = new Date(num).getFullYear();
  return year > 1900 && year < 3000 ? year : 0;
}

function songsOf(list) {
  var result = [];
  if (!list || !list.length) return result;
  for (var i = 0; i < list.length; i++) {
    var song = songOf(list[i]);
    if (song) result.push(song);
  }
  return result;
}

/** HTML 实体解码（歌单标题 / 简介里常见 &#32; 这类数字实体）。 */
function decodeEntities(text) {
  var value = String(text === undefined || text === null ? '' : text);
  value = value.replace(/&#(\d+);/g, function (_, code) {
    return String.fromCharCode(Number(code));
  });
  value = value.replace(/&#x([0-9a-fA-F]+);/g, function (_, code) {
    return String.fromCharCode(parseInt(code, 16));
  });
  value = value
    .replace(/&nbsp;/g, ' ')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, '&');
  return value;
}

function stripBr(text) {
  return decodeEntities(text).replace(/<br\s*\/?>/g, '\n');
}

function coverFromMap(cover) {
  if (!cover) return '';
  if (typeof cover === 'string') return cover;
  return cover.medium_url || cover.default_url || cover.big_url || '';
}

/* ---------------------------------------------------------------- 接口请求 */

function fetchCategories() {
  return musicu(
    {
      tags: {
        method: 'get_all_categories',
        param: { qq: '' },
        module: 'playlist.PlaylistAllCategoriesServer'
      }
    },
    ['tags']
  ).then(function (body) {
    return (body.tags && body.tags.data && body.tags.data.v_group) || [];
  });
}

function fetchSheetsByTag(tagId, page) {
  if (tagId) {
    var id = parseInt(tagId, 10);
    if (isNaN(id)) id = 10000000;
    return musicu(
      {
        comm: { cv: 1602, ct: 20 },
        playlist: {
          method: 'get_category_content',
          param: {
            titleid: id,
            caller: '0',
            category_id: id,
            size: 36,
            page: page - 1,
            use_page: 1
          },
          module: 'playlist.PlayListCategoryServer'
        }
      },
      ['playlist']
    );
  }
  return musicu(
    {
      comm: { cv: 1602, ct: 20 },
      playlist: {
        method: 'get_playlist_by_tag',
        param: {
          id: 10000000,
          sin: 36 * (page - 1),
          size: 36,
          order: 5,
          cur_page: page
        },
        module: 'playlist.PlayListPlazaServer'
      }
    },
    ['playlist']
  );
}

function fetchTopLists() {
  // 官方排行榜页同源接口：topList.data.group[] 按 巅峰榜/地区榜/特色榜/全球榜 分组
  return musicu(
    {
      comm: { ct: 24, cv: 0 },
      topList: {
        module: 'musicToplist.ToplistInfoServer',
        method: 'GetAll',
        param: {}
      }
    },
    ['topList']
  );
}

function fetchTopListDetail(topId, page) {
  return musicu(
    {
      toplist: {
        module: 'musicToplist.ToplistInfoServer',
        method: 'GetDetail',
        param: { topid: Number(topId) || 0, num: 300, period: '' }
      },
      comm: { uin: 0, format: 'json', ct: 20, cv: 1859 }
    },
    ['toplist']
  );
}

/** 歌单详情每页歌曲数（与 App 歌单详情页一致）。 */
var SHEET_PAGE_SIZE = 50;

function fetchSheetDetail(dissId, page) {
  var currentPage = page || 1;
  return musicu(
    {
      comm: { ct: 19, cv: 1859 },
      req: {
        module: 'music.srfDissInfo.aiDissInfo',
        method: 'uniform_get_Dissinfo',
        param: {
          disstid: Number(dissId) || 0,
          enc_host_uin: '',
          tag: 1,
          userinfo: 1,
          song_begin: (currentPage - 1) * SHEET_PAGE_SIZE,
          song_num: SHEET_PAGE_SIZE
        }
      }
    },
    ['req']
  );
}

function fetchSearch(keyword, page, limit) {
  var url =
    YQQ +
    '/soso/fcgi-bin/search_for_qq_cp?' +
    encodeQuery({
      w: keyword,
      format: 'json',
      p: page,
      n: limit,
      catZhida: 1,
      remoteplace: 'txt.yqq.center',
      t: 0,
      aggr: 1,
      cr: 1,
      lossless: 0
    });
  return getJson(url);
}

function fetchPlaylistSearch(keyword, page, limit) {
  var url =
    YQQ +
    '/soso/fcgi-bin/client_music_search_songlist?' +
    encodeQuery({
      page_no: page - 1,
      num_per_page: limit,
      format: 'json',
      query: keyword,
      remoteplace: 'txt.yqq.playlist',
      inCharset: 'utf8',
      outCharset: 'utf-8'
    });
  return getJson(url, { Referer: 'http://y.qq.com/portal/search.html' });
}

/* ------------------------------------------------------ 专辑 / 作者搜索 */

/** search_type：2=专辑，1=歌手（与 musicu.fcg 的搜索类型码一致）。 */
function fetchTypedSearch(keyword, page, limit, searchType) {
  return musicu(
    {
      comm: { ct: 19, cv: 1859 },
      req_1: {
        method: 'DoSearchForQQMusicDesktop',
        module: 'music.search.SearchCgiService',
        param: {
          num_per_page: limit,
          page_num: page,
          query: keyword,
          search_type: searchType
        }
      }
    },
    ['req_1']
  );
}

function fetchAlbumSearch(keyword, page, limit) {
  return fetchTypedSearch(keyword, page, limit, 2);
}

function fetchSingerSearch(keyword, page, limit) {
  return fetchTypedSearch(keyword, page, limit, 1);
}

/** 作者作品（歌曲）按 50 首一页翻。 */
function fetchSingerSongs(singerMid, page) {
  var currentPage = page || 1;
  return musicu(
    {
      comm: { ct: 24, cv: 0 },
      singer: {
        method: 'get_singer_detail_info',
        param: {
          sort: 5,
          singermid: singerMid,
          sin: (currentPage - 1) * SHEET_PAGE_SIZE,
          num: SHEET_PAGE_SIZE
        },
        module: 'music.web_singer_info_svr'
      }
    },
    ['singer']
  );
}

function fetchAlbumSongs(albumMid, albumId) {
  return musicu(
    {
      comm: { ct: 24, cv: 10000 },
      albumSonglist: {
        method: 'GetAlbumSongList',
        param: {
          albumMid: albumMid,
          albumID: Number(albumId) || 0,
          begin: 0,
          num: 999,
          order: 2
        },
        module: 'music.musichallAlbum.AlbumSongList'
      }
    },
    ['albumSonglist']
  );
}

function fetchLyric(songMid) {
  var url =
    YQQ +
    '/lyric/fcgi-bin/fcg_query_lyric_new.fcg?' +
    encodeQuery({
      songmid: songMid,
      format: 'json',
      nobase64: 0,
      g_tk: 5381,
      loginUin: 0,
      hostUin: 0,
      inCharset: 'utf8',
      outCharset: 'utf-8',
      notice: 0,
      platform: 'yqq.json',
      needNewCode: 0
    });
  return getJson(url);
}

/** 接口里的歌词是 base64，需要解码成文本。 */
function base64Decode(text) {
  if (!text) return '';
  try {
    return cerumusic.utils.buffer.bufToString(
      cerumusic.utils.buffer.from(text, 'base64'),
      'utf8'
    );
  } catch (e) {
    return '';
  }
}

function utf8ToBase64(text) {
  return cerumusic.utils.buffer.bufToString(
    cerumusic.utils.buffer.from(String(text || ''), 'utf8'),
    'base64'
  );
}

/* --------------------------------------------------------------- 逐字歌词 */

/**
 * 逐字歌词（QRC）：GetPlayLyricInfo（qrc:1）返回 hex 密文，需要 3DES 解密
 * 再 zlib 解压，得到 `<QrcInfos>` XML（LyricContent 属性里是逐字正文）。
 *
 * 注意：QQ 的 3DES 是社区流传实现（LDDC / QQMusicDecoder 同源），位序按
 * 小端 32 位词处理，与 OpenSSL 等标准 DES **不兼容**，必须用下面这份移植。
 */

var QRC_3DES_KEY = '!@#)(*$%123ZXC!@!@#)(NHL';

var QRC_SBOX = [
  [14, 4, 13, 1, 2, 15, 11, 8, 3, 10, 6, 12, 5, 9, 0, 7, 0, 15, 7, 4, 14, 2, 13, 1, 10, 6, 12, 11, 9, 5, 3, 8, 4, 1, 14, 8, 13, 6, 2, 11, 15, 12, 9, 7, 3, 10, 5, 0, 15, 12, 8, 2, 4, 9, 1, 7, 5, 11, 3, 14, 10, 0, 6, 13],
  [15, 1, 8, 14, 6, 11, 3, 4, 9, 7, 2, 13, 12, 0, 5, 10, 3, 13, 4, 7, 15, 2, 8, 15, 12, 0, 1, 10, 6, 9, 11, 5, 0, 14, 7, 11, 10, 4, 13, 1, 5, 8, 12, 6, 9, 3, 2, 15, 13, 8, 10, 1, 3, 15, 4, 2, 11, 6, 7, 12, 0, 5, 14, 9],
  [10, 0, 9, 14, 6, 3, 15, 5, 1, 13, 12, 7, 11, 4, 2, 8, 13, 7, 0, 9, 3, 4, 6, 10, 2, 8, 5, 14, 12, 11, 15, 1, 13, 6, 4, 9, 8, 15, 3, 0, 11, 1, 2, 12, 5, 10, 14, 7, 1, 10, 13, 0, 6, 9, 8, 7, 4, 15, 14, 3, 11, 5, 2, 12],
  [7, 13, 14, 3, 0, 6, 9, 10, 1, 2, 8, 5, 11, 12, 4, 15, 13, 8, 11, 5, 6, 15, 0, 3, 4, 7, 2, 12, 1, 10, 14, 9, 10, 6, 9, 0, 12, 11, 7, 13, 15, 1, 3, 14, 5, 2, 8, 4, 3, 15, 0, 6, 10, 10, 13, 8, 9, 4, 5, 11, 12, 7, 2, 14],
  [2, 12, 4, 1, 7, 10, 11, 6, 8, 5, 3, 15, 13, 0, 14, 9, 14, 11, 2, 12, 4, 7, 13, 1, 5, 0, 15, 10, 3, 9, 8, 6, 4, 2, 1, 11, 10, 13, 7, 8, 15, 9, 12, 5, 6, 3, 0, 14, 11, 8, 12, 7, 1, 14, 2, 13, 6, 15, 0, 9, 10, 4, 5, 3],
  [12, 1, 10, 15, 9, 2, 6, 8, 0, 13, 3, 4, 14, 7, 5, 11, 10, 15, 4, 2, 7, 12, 9, 5, 6, 1, 13, 14, 0, 11, 3, 8, 9, 14, 15, 5, 2, 8, 12, 3, 7, 0, 4, 10, 1, 13, 11, 6, 4, 3, 2, 12, 9, 5, 15, 10, 11, 14, 1, 7, 6, 0, 8, 13],
  [4, 11, 2, 14, 15, 0, 8, 13, 3, 12, 9, 7, 5, 10, 6, 1, 13, 0, 11, 7, 4, 9, 1, 10, 14, 3, 5, 12, 2, 15, 8, 6, 1, 4, 11, 13, 12, 3, 7, 14, 10, 15, 6, 8, 0, 5, 9, 2, 6, 11, 13, 8, 1, 4, 10, 7, 9, 5, 0, 15, 14, 2, 3, 12],
  [13, 2, 8, 4, 6, 15, 11, 1, 10, 9, 3, 14, 5, 0, 12, 7, 1, 15, 13, 8, 10, 3, 7, 4, 12, 5, 6, 11, 0, 14, 9, 2, 7, 11, 4, 1, 9, 12, 14, 2, 0, 6, 10, 13, 15, 3, 5, 8, 2, 1, 14, 7, 4, 10, 8, 13, 15, 12, 9, 0, 3, 5, 6, 11]
];

var QRC_KEY_RND_SHIFT = [1, 1, 2, 2, 2, 2, 2, 2, 1, 2, 2, 2, 2, 2, 2, 1];
var QRC_KEY_PERM_C = [56, 48, 40, 32, 24, 16, 8, 0, 57, 49, 41, 33, 25, 17, 9, 1, 58, 50, 42, 34, 26, 18, 10, 2, 59, 51, 43, 35];
var QRC_KEY_PERM_D = [62, 54, 46, 38, 30, 22, 14, 6, 61, 53, 45, 37, 29, 21, 13, 5, 60, 52, 44, 36, 28, 20, 12, 4, 27, 19, 11, 3];
var QRC_KEY_COMPRESSION = [13, 16, 10, 23, 0, 4, 2, 27, 14, 5, 20, 9, 22, 18, 11, 3, 25, 7, 15, 6, 26, 19, 12, 1, 40, 51, 30, 36, 46, 54, 29, 39, 50, 44, 32, 47, 43, 48, 38, 55, 33, 52, 45, 41, 49, 35, 28, 31];

/** 字节串里取第 b 位（小端 32 位词的字节序）左移 c。 */
function qrcBitnum(bytes, b, c) {
  return (
    ((bytes[((b / 32) | 0) * 4 + 3 - (((b % 32) / 8) | 0)] >> (7 - (b % 8))) & 1) << c
  );
}

function qrcBitnumIntr(a, b, c) {
  return ((a >> (31 - b)) & 1) << c;
}

function qrcBitnumIntl(a, b, c) {
  return ((a << b) & 0x80000000) >>> c;
}

function qrcSboxBit(a) {
  return (a & 32) | ((a & 31) >> 1) | ((a & 1) << 4);
}

function qrcInitialPermutation(data) {
  var l = 0;
  var r = 0;
  for (var i = 0; i < 32; i++) {
    l |= qrcBitnum(data, QRC_IP_L[i], 31 - i);
    r |= qrcBitnum(data, QRC_IP_R[i], 31 - i);
  }
  return [l >>> 0, r >>> 0];
}

var QRC_IP_L = [
  57, 49, 41, 33, 25, 17, 9, 1, 59, 51, 43, 35, 27, 19, 11, 3,
  61, 53, 45, 37, 29, 21, 13, 5, 63, 55, 47, 39, 31, 23, 15, 7
];
var QRC_IP_R = [
  56, 48, 40, 32, 24, 16, 8, 0, 58, 50, 42, 34, 26, 18, 10, 2,
  60, 52, 44, 36, 28, 20, 12, 4, 62, 54, 46, 38, 30, 22, 14, 6
];

function qrcInversePermutation(s0, s1) {
  var data = new Array(8);
  data[3] =
    qrcBitnumIntr(s1, 7, 7) | qrcBitnumIntr(s0, 7, 6) | qrcBitnumIntr(s1, 15, 5) |
    qrcBitnumIntr(s0, 15, 4) | qrcBitnumIntr(s1, 23, 3) | qrcBitnumIntr(s0, 23, 2) |
    qrcBitnumIntr(s1, 31, 1) | qrcBitnumIntr(s0, 31, 0);
  data[2] =
    qrcBitnumIntr(s1, 6, 7) | qrcBitnumIntr(s0, 6, 6) | qrcBitnumIntr(s1, 14, 5) |
    qrcBitnumIntr(s0, 14, 4) | qrcBitnumIntr(s1, 22, 3) | qrcBitnumIntr(s0, 22, 2) |
    qrcBitnumIntr(s1, 30, 1) | qrcBitnumIntr(s0, 30, 0);
  data[1] =
    qrcBitnumIntr(s1, 5, 7) | qrcBitnumIntr(s0, 5, 6) | qrcBitnumIntr(s1, 13, 5) |
    qrcBitnumIntr(s0, 13, 4) | qrcBitnumIntr(s1, 21, 3) | qrcBitnumIntr(s0, 21, 2) |
    qrcBitnumIntr(s1, 29, 1) | qrcBitnumIntr(s0, 29, 0);
  data[0] =
    qrcBitnumIntr(s1, 4, 7) | qrcBitnumIntr(s0, 4, 6) | qrcBitnumIntr(s1, 12, 5) |
    qrcBitnumIntr(s0, 12, 4) | qrcBitnumIntr(s1, 20, 3) | qrcBitnumIntr(s0, 20, 2) |
    qrcBitnumIntr(s1, 28, 1) | qrcBitnumIntr(s0, 28, 0);
  data[7] =
    qrcBitnumIntr(s1, 3, 7) | qrcBitnumIntr(s0, 3, 6) | qrcBitnumIntr(s1, 11, 5) |
    qrcBitnumIntr(s0, 11, 4) | qrcBitnumIntr(s1, 19, 3) | qrcBitnumIntr(s0, 19, 2) |
    qrcBitnumIntr(s1, 27, 1) | qrcBitnumIntr(s0, 27, 0);
  data[6] =
    qrcBitnumIntr(s1, 2, 7) | qrcBitnumIntr(s0, 2, 6) | qrcBitnumIntr(s1, 10, 5) |
    qrcBitnumIntr(s0, 10, 4) | qrcBitnumIntr(s1, 18, 3) | qrcBitnumIntr(s0, 18, 2) |
    qrcBitnumIntr(s1, 26, 1) | qrcBitnumIntr(s0, 26, 0);
  data[5] =
    qrcBitnumIntr(s1, 1, 7) | qrcBitnumIntr(s0, 1, 6) | qrcBitnumIntr(s1, 9, 5) |
    qrcBitnumIntr(s0, 9, 4) | qrcBitnumIntr(s1, 17, 3) | qrcBitnumIntr(s0, 17, 2) |
    qrcBitnumIntr(s1, 25, 1) | qrcBitnumIntr(s0, 25, 0);
  data[4] =
    qrcBitnumIntr(s1, 0, 7) | qrcBitnumIntr(s0, 0, 6) | qrcBitnumIntr(s1, 8, 5) |
    qrcBitnumIntr(s0, 8, 4) | qrcBitnumIntr(s1, 16, 3) | qrcBitnumIntr(s0, 16, 2) |
    qrcBitnumIntr(s1, 24, 1) | qrcBitnumIntr(s0, 24, 0);
  return data;
}

/** 单轮 Feistel 函数。 */
function qrcFeistel(state, key) {
  var t1 =
    (qrcBitnumIntl(state, 31, 0) | ((state & 0xf0000000) >>> 1) | qrcBitnumIntl(state, 4, 5) |
      qrcBitnumIntl(state, 3, 6) | ((state & 0x0f000000) >>> 3) | qrcBitnumIntl(state, 8, 11) |
      qrcBitnumIntl(state, 7, 12) | ((state & 0x00f00000) >>> 5) | qrcBitnumIntl(state, 12, 17) |
      qrcBitnumIntl(state, 11, 18) | ((state & 0x000f0000) >>> 7) | qrcBitnumIntl(state, 16, 23)) >>> 0;
  var t2 =
    (qrcBitnumIntl(state, 15, 0) | ((state & 0x0000f000) << 15) | qrcBitnumIntl(state, 20, 5) |
      qrcBitnumIntl(state, 19, 6) | ((state & 0x00000f00) << 13) | qrcBitnumIntl(state, 24, 11) |
      qrcBitnumIntl(state, 23, 12) | ((state & 0x000000f0) << 11) | qrcBitnumIntl(state, 28, 17) |
      qrcBitnumIntl(state, 27, 18) | ((state & 0x0000000f) << 9) | qrcBitnumIntl(state, 0, 23)) >>> 0;

  var lrgstate = [
    (t1 >>> 24) & 0xff, (t1 >>> 16) & 0xff, (t1 >>> 8) & 0xff,
    (t2 >>> 24) & 0xff, (t2 >>> 16) & 0xff, (t2 >>> 8) & 0xff
  ];
  for (var i = 0; i < 6; i++) lrgstate[i] ^= key[i];

  var st =
    ((QRC_SBOX[0][qrcSboxBit(lrgstate[0] >>> 2)] << 28) |
      (QRC_SBOX[1][qrcSboxBit(((lrgstate[0] & 0x03) << 4) | (lrgstate[1] >>> 4))] << 24) |
      (QRC_SBOX[2][qrcSboxBit(((lrgstate[1] & 0x0f) << 2) | (lrgstate[2] >>> 6))] << 20) |
      (QRC_SBOX[3][qrcSboxBit(lrgstate[2] & 0x3f)] << 16) |
      (QRC_SBOX[4][qrcSboxBit(lrgstate[3] >>> 2)] << 12) |
      (QRC_SBOX[5][qrcSboxBit(((lrgstate[3] & 0x03) << 4) | (lrgstate[4] >>> 4))] << 8) |
      (QRC_SBOX[6][qrcSboxBit(((lrgstate[4] & 0x0f) << 2) | (lrgstate[5] >>> 6))] << 4) |
      QRC_SBOX[7][qrcSboxBit(lrgstate[5] & 0x3f)]) >>> 0;

  return (qrcBitnumIntl(st, 15, 0) | qrcBitnumIntl(st, 6, 1) | qrcBitnumIntl(st, 19, 2) |
    qrcBitnumIntl(st, 20, 3) | qrcBitnumIntl(st, 28, 4) | qrcBitnumIntl(st, 11, 5) |
    qrcBitnumIntl(st, 27, 6) | qrcBitnumIntl(st, 16, 7) | qrcBitnumIntl(st, 0, 8) |
    qrcBitnumIntl(st, 14, 9) | qrcBitnumIntl(st, 22, 10) | qrcBitnumIntl(st, 25, 11) |
    qrcBitnumIntl(st, 4, 12) | qrcBitnumIntl(st, 17, 13) | qrcBitnumIntl(st, 30, 14) |
    qrcBitnumIntl(st, 9, 15) | qrcBitnumIntl(st, 1, 16) | qrcBitnumIntl(st, 7, 17) |
    qrcBitnumIntl(st, 23, 18) | qrcBitnumIntl(st, 13, 19) | qrcBitnumIntl(st, 31, 20) |
    qrcBitnumIntl(st, 26, 21) | qrcBitnumIntl(st, 2, 22) | qrcBitnumIntl(st, 8, 23) |
    qrcBitnumIntl(st, 18, 24) | qrcBitnumIntl(st, 12, 25) | qrcBitnumIntl(st, 29, 26) |
    qrcBitnumIntl(st, 5, 27) | qrcBitnumIntl(st, 21, 28) | qrcBitnumIntl(st, 10, 29) |
    qrcBitnumIntl(st, 3, 30) | qrcBitnumIntl(st, 24, 31)) >>> 0;
}

/** 解密一个 8 字节块。 */
function qrcDesBlock(data, key) {
  var pair = qrcInitialPermutation(data);
  var s0 = pair[0];
  var s1 = pair[1];
  for (var idx = 0; idx < 15; idx++) {
    var previousS1 = s1;
    s1 = (qrcFeistel(s1, key[idx]) ^ s0) >>> 0;
    s0 = previousS1;
  }
  s0 = (qrcFeistel(s1, key[15]) ^ s0) >>> 0;
  return qrcInversePermutation(s0, s1);
}

function qrcKeySchedule(key, mode) {
  var schedule = [];
  for (var i = 0; i < 16; i++) schedule.push([0, 0, 0, 0, 0, 0]);
  var c = 0;
  var d = 0;
  for (var j = 0; j < 28; j++) c |= qrcBitnum(key, QRC_KEY_PERM_C[j], 31 - j);
  for (var k = 0; k < 28; k++) d |= qrcBitnum(key, QRC_KEY_PERM_D[k], 31 - k);
  c >>>= 0;
  d >>>= 0;
  for (var n = 0; n < 16; n++) {
    var shift = QRC_KEY_RND_SHIFT[n];
    c = (((c << shift) | (c >>> (28 - shift))) & 0xfffffff0) >>> 0;
    d = (((d << shift) | (d >>> (28 - shift))) & 0xfffffff0) >>> 0;
    var togen = mode === 0 ? 15 - n : n;
    for (var m = 0; m < 24; m++) {
      schedule[togen][m / 8 | 0] |= qrcBitnumIntr(c, QRC_KEY_COMPRESSION[m], 7 - (m % 8));
    }
    for (var p = 24; p < 48; p++) {
      schedule[togen][p / 8 | 0] |= qrcBitnumIntr(d, QRC_KEY_COMPRESSION[p] - 27, 7 - (p % 8));
    }
  }
  return schedule;
}

/** 3DES 密钥编排：mode 1 = 加密，0 = 解密。 */
function qrcTripleDesKeySetup(key, mode) {
  if (mode === 1) {
    return [
      qrcKeySchedule(key, 1),
      qrcKeySchedule(key.slice(8), 0),
      qrcKeySchedule(key.slice(16), 1)
    ];
  }
  return [
    qrcKeySchedule(key.slice(16), 0),
    qrcKeySchedule(key.slice(8), 1),
    qrcKeySchedule(key, 0)
  ];
}

function qrcTripleDesBlock(data, key) {
  var result = data;
  for (var i = 0; i < 3; i++) result = qrcDesBlock(result, key[i]);
  return result;
}

/** hex 密文 → 3DES 解密后的明文字节（尾部可能带填充，交给 zlib 容忍）。 */
function qrcDecryptHex(hex) {
  var cipher = cerumusic.utils.buffer.from(String(hex || ''), 'hex');
  if (!cipher || cipher.length < 16 || cipher.length % 8 !== 0) return [];
  var key = [];
  for (var i = 0; i < QRC_3DES_KEY.length; i++) {
    key.push(QRC_3DES_KEY.charCodeAt(i) & 0xff);
  }
  var schedule = qrcTripleDesKeySetup(key, 0);
  var out = [];
  for (var j = 0; j + 8 <= cipher.length; j += 8) {
    var block = qrcTripleDesBlock(cipher.slice(j), schedule);
    for (var k = 0; k < 8; k++) out.push(block[k]);
  }
  return out;
}

/** 「4:29」秒数化（musicInfo.interval 是 m:ss 文案；异常返回 0）。 */
function parseIntervalSeconds(text) {
  var value = String(text || '');
  if (!value) return 0;
  if (/^\d+$/.test(value)) return Number(value) || 0;
  var parts = value.split(':');
  var seconds = 0;
  for (var i = 0; i < parts.length; i++) {
    seconds = seconds * 60 + (Number(parts[i]) || 0);
  }
  return seconds;
}

/**
 * 拉取逐字歌词（QRC XML）。拿不到（无数字 songID / 无逐字 / 解密失败 /
 * 老版本 App 缺 zlib 桥）一律返回空串，调用方回退逐行 LRC。
 */
function fetchQrc(songId, songInfo) {
  if (!cerumusic.utils.zlib) return Promise.resolve('');
  if (!/^\d+$/.test(String(songId || ''))) return Promise.resolve('');
  var info = songInfo || {};
  return cerumusic
    .request(MUSICU, {
      method: 'POST',
      headers: {
        'User-Agent': UA,
        'Referer': 'https://y.qq.com/',
        'Origin': 'https://y.qq.com',
        'Content-Type': 'application/json'
      },
      body: {
        comm: { ct: 19, cv: 2111 },
        req_1: {
          module: 'music.musichallSong.PlayLyricInfo',
          method: 'GetPlayLyricInfo',
          param: {
            albumName: utf8ToBase64(info.albumName),
            crypt: 1,
            ct: 19,
            cv: 2111,
            interval: parseIntervalSeconds(info.interval),
            lrc_t: 0,
            qrc: 1,
            qrc_t: 0,
            roma: 1,
            roma_t: 0,
            singerName: utf8ToBase64(info.singer),
            // 服务端要求数字类型，传字符串会被 10006 拒绝
            songID: Number(songId),
            songName: utf8ToBase64(info.name),
            trans: 1,
            trans_t: 0,
            type: 0
          }
        }
      },
      timeout: 15000
    })
    .then(decodeBody)
    .then(function (body) {
      var data = body.req_1 && body.req_1.data;
      if (!data || Number(data.qrc) !== 1) return '';
      var lyric = data.lyric;
      if (typeof lyric !== 'string' || !/^[0-9a-fA-F]+$/.test(lyric)) return '';
      return qrcDecryptHex(lyric);
    })
    .then(function (plain) {
      if (!plain.length) return '';
      return cerumusic.utils.zlib.inflate(plain).then(function (inflated) {
        return cerumusic.utils.buffer.bufToString(inflated, 'utf8');
      });
    })
    .then(function (xml) {
      return xml.indexOf('LyricContent=') >= 0 ? xml : '';
    })
    .catch(function () {
      return '';
    });
}

/* ---------------------------------------------------------------- 插件接口 */

module.exports = {
  pluginInfo: {
    name: 'QQ_数据源',
    version: '1.7.0',
    author: 'MintMusic',
    description:
      '只提供搜索（歌曲 / 专辑 / 作者）、歌单分类、榜单（含分类）、歌单 / 专辑 / 作者详情的 QQ音乐数据源；' +
      '歌词支持逐字 QRC（需播放源提供数字歌曲 id）；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记
    // 站点图标：导入插件时下载并缓存到插件目录（音源列表 / 切换按钮用它）
    iconUrl: 'https://y.qq.com/favicon.ico',
    isDataSource: true
  },

  sources: {
    tx: {
      name: 'QQ',
      qualitys: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'],
      actions: ['musicSearch']
    }
  },

  capabilities: {
    sheets: true,
    sheetDetail: true,
    topList: true,
    playlistSearch: true
  },

  /** 支持的搜索类型：歌曲 / 专辑 / 作者。 */
  supportedSearchTypes: function () {
    return ['music', 'album', 'artist'];
  },

  isDataSource: true,

  /* ------------------------------------------------------- 热门搜索（搜索页） */
  getHotSearchTags: function () {
    return musicu(
      {
        comm: {
          ct: '19',
          cv: '1803',
          guid: '0',
          patch: '118',
          tmeAppID: 'qqmusic',
          tmeLoginType: 0,
          uin: '0',
          wid: '0'
        },
        hotkey: {
          method: 'GetHotkeyForQQMusicPC',
          module: 'tencent_musicsoso_hotkey.HotkeyService',
          param: { search_id: '', uin: 0 }
        }
      },
      ['hotkey']
    ).then(function (body) {
      var data = (body.hotkey && body.hotkey.data) || {};
      var list = data.vec_hotkey || [];
      var tags = [];
      for (var i = 0; i < list.length && tags.length < 10; i++) {
        var item = list[i] || {};
        var word = item.query || item.k || '';
        if (!word) continue;
        tags.push(String(word));
      }
      return JSON.stringify(tags);
    });
  },

  /* ------------------------------------------------------------ 搜索歌曲 */
  search: function (source, keyword, page, limit) {
    var size = limit || 30;
    var currentPage = page || 1;
    return fetchSearch(keyword, currentPage, size).then(function (body) {
      var data = body.data || {};
      var song = data.song || {};
      var list = song.list || [];
      var total = totalOf(song.totalnum);
      return JSON.stringify({
        list: songsOf(list),
        page: currentPage,
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * (currentPage - 1), list.length, size, data)
      });
    });
  },

  /* ------------------------------------------------------------ 搜索歌单 */
  searchPlaylists: function (keyword, page) {
    var size = 30;
    var currentPage = page || 1;
    return fetchPlaylistSearch(keyword, currentPage, size).then(function (
      body
    ) {
      var data = body.data || {};
      var list = data.list || [];
      // 该接口的总数叫 display_num（不是 total）
      var total = totalOf(data.display_num);
      var playlists = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        var id = item.dissid || '';
        if (!id) continue;
        var creator = item.creator || {};
        playlists.push({
          id: String(id),
          title: decodeEntities(item.dissname),
          description: stripBr(item.introduction),
          coverUrl: String(item.imgurl || '').replace(/\{size\}/g, '400'),
          songCount: Number(item.song_count || item.songcnt || 0),
          playCount: formatPlayCount(item.listennum),
          author: creator.name ? String(creator.name) : ''
        });
      }
      return JSON.stringify({
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * (currentPage - 1), list.length, size, data),
        playlists: playlists
      });
    });
  },

  /* ---------------------------------------------------- 搜索专辑 / 作者 */
  searchTyped: function (source, keyword, page, limit, type) {
    var isAlbum = type === 'album';
    var isArtist = type === 'artist';
    if (!isAlbum && !isArtist) {
      return Promise.resolve(
        JSON.stringify({ list: [], total: null, limit: limit || 20, isEnd: true })
      );
    }
    var size = limit || 20;
    var currentPage = page || 1;
    var fetcher = isAlbum
      ? fetchAlbumSearch(keyword, currentPage, size)
      : fetchSingerSearch(keyword, currentPage, size);
    return fetcher.then(function (body) {
      var data = (body.req_1 && body.req_1.data) || {};
      var meta = data.meta || {};
      var node = (data.body && (isAlbum ? data.body.album : data.body.singer)) || {};
      var list = node.list || [];
      var total = totalOf(meta.sum);
      var items = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (isAlbum) {
          var albumId = item.albumID;
          var albumMid = item.albumMID || item.album_mid;
          if (albumId === undefined && !albumMid) continue;
          var cover = coverOfAlbumMid(albumMid) || String(item.albumPic || '');
          items.push({
            id: String(albumId !== undefined ? albumId : albumMid),
            title: decodeEntities(item.albumName || item.album_name),
            coverUrl: cover,
            artist: decodeEntities(item.singerName || item.singer_name),
            worksNum: Number(item.song_count || item.songcnt || 0),
            date: String(item.publicTime || item.pub_time || ''),
            description: decodeEntities(item.desc || ''),
            // getAlbumInfo 需要原样带回的信息
            raw: {
              id: String(albumId !== undefined ? albumId : albumMid),
              albumMID: String(albumMid || ''),
              title: decodeEntities(item.albumName || item.album_name),
              artist: decodeEntities(item.singerName || item.singer_name),
              date: String(item.publicTime || ''),
              artwork: cover
            }
          });
        } else {
          var singerId = item.singerID;
          var singerMid = item.singerMID || item.singer_mid;
          if (singerId === undefined && !singerMid) continue;
          var avatar =
            coverOfSingerMid(singerMid) || String(item.singerPic || '');
          items.push({
            id: String(singerId !== undefined ? singerId : singerMid),
            title: decodeEntities(item.singerName || item.singer_name),
            coverUrl: avatar,
            worksNum: Number(item.songNum || item.song_num || 0),
            description: '',
            // getArtistWorks 需要原样带回的信息
            raw: {
              id: String(singerId !== undefined ? singerId : singerMid),
              singerMID: String(singerMid || ''),
              name: decodeEntities(item.singerName || item.singer_name),
              avatar: avatar
            }
          });
        }
      }
      return JSON.stringify({
        list: items,
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * (currentPage - 1), list.length, size, meta)
      });
    });
  },

  /* ------------------------------------------------------------ 作者作品 */
  getArtistWorks: function (source, artistItem, page, type) {
    var raw = (artistItem && artistItem.raw) || artistItem || {};
    var singerMid = raw.singerMID || raw.singermid || raw.mid || '';
    var singerId = raw.id || (artistItem && artistItem.id) || 0;
    if (!singerMid && !singerId) {
      return Promise.resolve(JSON.stringify({ musicList: [] }));
    }
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
    var offset = (currentPage - 1) * size;
    return fetchSingerSongs(String(singerMid), currentPage).then(function (
      body
    ) {
      var data = (body.singer && body.singer.data) || {};
      var songs = songsOf(data.songlist || []);
      var total = totalOf(data.total_song);
      if (total === null) total = songs.length;
      return JSON.stringify({
        total: total,
        limit: size,
        offset: offset,
        isEnd: isPageEnd(total, offset, songs.length, size, data),
        artistItem: {
          id: String(singerId || singerMid),
          title: decodeEntities(raw.name || ''),
          coverUrl: raw.avatar || coverOfSingerMid(singerMid),
          worksNum: total
        },
        musicList: songs
      });
    });
  },

  /* ------------------------------------------------------------ 专辑详情 */
  getAlbumInfo: function (source, albumItem, page) {
    var raw = (albumItem && albumItem.raw) || albumItem || {};
    var albumMid = raw.albumMID || raw.albummid || raw.mid || '';
    var albumId = raw.id || raw.albumid || (albumItem && albumItem.id) || 0;
    if (!albumMid && !albumId) {
      return Promise.resolve(JSON.stringify({ musicList: [] }));
    }
    return fetchAlbumSongs(String(albumMid), albumId).then(function (body) {
      var data = (body.albumSonglist && body.albumSonglist.data) || {};
      var rows = data.songList || [];
      var songs = [];
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i] || {};
        var song = songOf(row.songInfo || row);
        if (song) songs.push(song);
      }
      // 专辑接口一次全量返回（begin=0, num=999），无需翻页
      var total = totalOf(data.totalNum);
      if (total === null) total = songs.length;
      return JSON.stringify({
        isEnd: true,
        total: total,
        albumItem: {
          id: String(albumId || albumMid),
          title: decodeEntities(raw.title || ''),
          coverUrl: raw.artwork || coverOfAlbumMid(albumMid),
          artist: decodeEntities(raw.artist || ''),
          worksNum: total,
          date: raw.date || '',
          description: decodeEntities(raw.description || '')
        },
        musicList: songs
      });
    });
  },

  /* ------------------------------------------------- 歌单分类（更多分类面板） */
  getRecommendSheetTags: function () {
    return fetchCategories().then(function (groups) {
      var result = [];
      for (var i = 0; i < groups.length; i++) {
        var group = groups[i] || {};
        var rawTags = group.v_item || [];
        var tags = [];
        for (var j = 0; j < rawTags.length; j++) {
          var tag = rawTags[j] || {};
          if (tag.id === undefined) continue;
          tags.push({ id: String(tag.id), name: String(tag.name || '') });
        }
        if (!tags.length) continue;
        result.push({ name: String(group.group_name || '分类'), tags: tags });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------- 热门标签（顶部） */
  getHotPlaylistTags: function () {
    // 分类页是 HTML，热门标签只能从里面正则抠出来（与内置源一致）。
    return cerumusic
      .request(YQQ + '/node/pc/wk_v15/category_playlist.html', {
        method: 'GET',
        headers: HEADERS,
        timeout: 15000
      })
      .then(function (res) {
        var html = res && res.body ? String(res.body) : '';
        var pattern = /class="c_bg_link js_tag_item" data-id="(\w+)">(.+?)<\/a>/g;
        var result = [];
        var match;
        while ((match = pattern.exec(html)) !== null) {
          result.push({ id: match[1], name: match[2] });
        }
        return JSON.stringify(result);
      });
  },

  /* --------------------------------------------------- 分类歌单（歌单卡片） */
  getRecommendSheetsByTag: function (tagId, page) {
    var currentPage = page || 1;
    return fetchSheetsByTag(tagId || '', currentPage).then(function (body) {
      var data = (body.playlist && body.playlist.data) || {};
      // 带分类走 get_category_content，总数在 content.total_cnt；
      // 不带分类走 get_playlist_by_tag，总数在 data.total。
      var total = tagId
        ? totalOf(data.content && data.content.total_cnt)
        : totalOf(data.total);
      var playlists = [];
      if (tagId) {
        var content = (data.content && data.content.v_item) || [];
        for (var i = 0; i < content.length; i++) {
          var basic = (content[i] && content[i].basic) || {};
          var tid = basic.tid;
          if (tid === undefined) continue;
          var creator = basic.creator || {};
          playlists.push({
            id: String(tid),
            title: basic.title || '',
            description: stripBr(basic.desc),
            coverUrl: coverFromMap(basic.cover),
            songCount: Number(basic.song_cnt || basic.song_num || 0),
            playCount: formatPlayCount(basic.play_cnt),
            author: creator.nick ? String(creator.nick) : ''
          });
        }
      } else {
        var list = data.v_playlist || [];
        for (var k = 0; k < list.length; k++) {
          var item = list[k] || {};
          var itemId = item.tid;
          if (itemId === undefined) continue;
          var info = item.creator_info || {};
          playlists.push({
            id: String(itemId),
            title: item.title || '',
            description: stripBr(item.desc),
            coverUrl: String(item.cover_url_medium || ''),
            songCount: Array.isArray(item.song_ids)
              ? item.song_ids.length
              : Number(item.song_cnt || 0),
            playCount: formatPlayCount(item.access_num),
            author: info.nick ? String(info.nick) : ''
          });
        }
      }
      return JSON.stringify({
        // 分类歌单接口不回总数时按「不足一页即到底」兜底
        total: total,
        limit: 36,
        isEnd: isPageEnd(total, 36 * (currentPage - 1), playlists.length, 36, data),
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------------------- 榜单列表 */
  getTopLists: function () {
    return fetchTopLists().then(function (body) {
      var groups =
        (body.topList && body.topList.data && body.topList.data.group) || [];
      var result = [];
      for (var i = 0; i < groups.length; i++) {
        var group = groups[i] || {};
        var groupName = String(group.groupName || '');
        var items = group.toplist || [];
        for (var j = 0; j < items.length; j++) {
          var item = items[j] || {};
          var topId = item.topId;
          if (topId === undefined || topId === null || topId === '') continue;
          // MV 榜没法播，跳过（与旧行为一致）
          if (Number(topId) === 201) continue;
          result.push({
            id: String(topId),
            name: String(item.title || ''),
            coverUrl: String(item.frontPicUrl || item.headPicUrl || ''),
            playCount: formatPlayCount(item.listenNum),
            updateFrequency: String(item.updateTips || item.updateTime || ''),
            group: groupName
          });
        }
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------------- 榜单详情 */
  getTopListDetail: function (id, page) {
    return fetchTopListDetail(id, page).then(function (body) {
      var data = (body.toplist && body.toplist.data) || {};
      var info = data.data || data.topInfo || {};
      var songs = songsOf(data.songInfoList || []);
      // 榜单一次全量返回（toplist.data.data.totalNum），无需翻页
      var total = totalOf(data.data && data.data.totalNum);
      if (total === null) total = songs.length;
      return JSON.stringify({
        isEnd: true,
        total: total,
        sheet: {
          title: info.title || info.topTitle || '排行榜',
          coverUrl: info.headPicUrl || info.frontPicUrl || '',
          description: info.updateTime || '',
          author: '',
          songCount: total
        },
        songs: songs
      });
    });
  },

  /* ------------------------------------------------------------- 歌单详情 */
  getMusicSheetInfo: function (sheetId, page) {
    var raw = String(sheetId || '').replace(/^tx[_:]/, '');
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
    var offset = (currentPage - 1) * size;
    return fetchSheetDetail(raw, currentPage).then(function (body) {
      var data = (body.req && body.req.data) || {};
      var dirinfo = data.dirinfo || {};
      var songs = songsOf(data.songlist || []);
      // 总数优先取 total_song_num；未知时只有第一页能用本页条数兜底
      var total = totalOf(data.total_song_num);
      if (total === null) total = totalOf(dirinfo.songnum);
      if (total === null && currentPage === 1) total = songs.length;
      return JSON.stringify({
        isEnd: isPageEnd(total, offset, songs.length, size, data),
        total: total,
        limit: size,
        offset: offset,
        sheet: {
          title: dirinfo.title || '',
          coverUrl: String(dirinfo.picurl || '').replace(/\{size\}/g, '400'),
          description: stripBr(dirinfo.desc),
          author: dirinfo.creator && dirinfo.creator.nick
            ? String(dirinfo.creator.nick)
            : '',
          songCount: total === null ? 0 : total
        },
        songs: songs
      });
    });
  },

  /* --------------------------------------------------------------- 歌词 */
  getLyric: function (source, musicInfo) {
    var mid =
      musicInfo && (musicInfo.songmid || musicInfo.songId || musicInfo.id);
    if (!mid) return Promise.resolve('');
    // 并行：逐行 LRC（带翻译）+ 逐字 QRC（需要数字 songID）
    function lrcTask() {
      return fetchLyric(mid)
        .then(function (body) {
          if (Number(body.retcode) !== 0 && Number(body.code) !== 0) {
            return null;
          }
          var lrc = base64Decode(body.lyric);
          var trans = base64Decode(body.trans);
          return { lyric: lrc, lrc: lrc, tlyric: trans };
        })
        .catch(function () {
          return null;
        });
    }
    function qrcTask() {
      // 数字 songID 在搜索结果里由 songId 透传（songmid 是 base62 mid，
      // GetPlayLyricInfo 只认数字 id）
      return fetchQrc(musicInfo && musicInfo.songId, musicInfo);
    }
    return Promise.all([lrcTask(), qrcTask()]).then(function (results) {
      var base = results[0] || {};
      var lrc = base.lrc || '';
      var qrc = results[1] || '';
      if (!lrc && !qrc && !base.tlyric) return '';
      // QRC 放逐字通道（App 会优先用逐字那份），lrc 仍作逐行兜底
      return JSON.stringify({
        lyric: lrc || qrc,
        lrc: lrc,
        tlyric: base.tlyric || '',
        qrc: qrc,
        crlyric: qrc
      });
    });
  },

  /* --------------------------------------------------------------- 封面 */
  getPic: function (source, musicInfo) {
    // QQ 音乐的封面在搜索 / 歌单结果里已经由 albummid 拼好，这里不需要再查。
    return Promise.resolve('');
  }
};
