/*
 * MintMusic 数据源插件 —— 酷狗音乐
 * ---------------------------------------------------------------------------
 * 与 netease_music_data_source.js 同一套约定：只提供搜索 / 发现页（歌单分类、
 * 榜单、歌单详情）/ 歌词等**元数据**，**不提供播放地址**（没有 musicUrl）。
 *
 * 数据源标记：pluginInfo.isDataSource === true
 *
 * 接口与内置源酷狗音乐（lib/features/plugin/data/kugou_music_source.dart）一致：
 *   · 搜索走 songsearch.kugou.com，歌单搜索走 msearchretry.kugou.com；
 *   · 分类歌单走 www2.kugou.kugou.com/yueku/v9/special/getSpecial；
 *   · 榜单 / 榜单详情走 mobilecdnbj.kugou.com；
 *   · 歌单歌曲走 mobilecdn.kugou.com（special/song），歌单标题与歌曲数走
 *     special/info；
 *   · 播放量格式：≥ 1 亿 → 「x.x亿」，≥ 1 万 → 「x.x万」，已经是
 *     「xx万 / xx亿」的字符串原样返回（与内置源一致）。
 * ---------------------------------------------------------------------------
 */

var UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
var SEARCH = 'https://songsearch.kugou.com';
var MSEARCH = 'http://msearchretry.kugou.com';
var CDN = 'http://mobilecdn.kugou.com';
var CDNBJ = 'http://mobilecdnbj.kugou.com';
var YUEKU = 'http://www2.kugou.kugou.com';
var KRCS = 'https://krcs.kugou.com';
var LYRICS = 'http://lyrics.kugou.com';

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
      headers: Object.assign({ 'User-Agent': UA }, headers || {}),
      timeout: 15000
    })
    .then(decodeBody);
}

/* ---------------------------------------------------------------- 字段映射 */

/**
 * 播放量格式化 —— 与内置源 _formatPlayCount 一致：
 *   已经是「xx万 / xx亿」的字符串原样返回；≥ 1 亿 → 亿；≥ 1 万 → 万。
 */
function formatPlayCount(count) {
  if (count === undefined || count === null) return '';
  if (typeof count === 'string') {
    if (count.indexOf('亿') >= 0 || count.indexOf('万') >= 0) return count;
    if (count === '') return '';
  }
  var value = Number(count);
  if (isNaN(value)) {
    value = parseInt(String(count).replace(/[^0-9]/g, ''), 10);
    if (isNaN(value)) return String(count);
  }
  if (value >= 100000000) return (value / 100000000).toFixed(1) + '亿';
  if (value >= 10000) return (value / 10000).toFixed(1) + '万';
  return String(Math.floor(value));
}

function decodeName(name) {
  return String(name === undefined || name === null ? '' : name)
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&nbsp;/g, ' ');
}

/** 酷狗图片地址里的 {size} 占位符要替换成具体尺寸。 */
function normalizeImage(url, size) {
  var value = String(url === undefined || url === null ? '' : url);
  if (!value) return '';
  value = value.replace(/\{size\}/g, size);
  if (value.indexOf('//') === 0) value = 'https:' + value;
  return value.replace(/^http:\/\//, 'https://');
}

function authorsOf(item) {
  if (item.SingerName) return decodeName(item.SingerName);
  if (item.singername) return decodeName(item.singername);
  var authors = item.authors || item.author;
  if (!authors) return '';
  if (typeof authors === 'string') return decodeName(authors);
  if (!authors.length) return '';
  var names = [];
  for (var i = 0; i < authors.length; i++) {
    var author = authors[i] || {};
    var name = author.author_name || author.name;
    if (name) names.push(decodeName(name));
  }
  return names.join('、');
}

function coverOf(item) {
  var albumInfo = item.album_info || {};
  var candidates = [
    item.sizable_cover,
    item.album_sizable_cover,
    albumInfo.sizable_cover,
    albumInfo.album_img,
    albumInfo.img,
    item.img,
    item.pic,
    item.Image,
    item.album_img
  ];
  for (var i = 0; i < candidates.length; i++) {
    var image = normalizeImage(candidates[i], '800');
    if (image) return image;
  }
  return '';
}

/** 搜索 / 歌单 / 榜单里的歌曲 → 插件歌曲结构（时长单位：秒）。 */
function songOf(item) {
  if (!item) return null;
  var hash = item.FileHash || item.hash || '';
  if (!hash) return null;
  var albumInfo = item.album_info || {};
  var albumName =
    item.AlbumName ||
    item.album_name ||
    albumInfo.album_name ||
    albumInfo.albumName ||
    '';
  var duration = Number(item.Duration || item.duration || 0);
  if (isNaN(duration)) duration = 0;
  return {
    id: String(hash),
    songId: String(hash),
    songmid: String(hash),
    // 没有 songname 时用 filename（「歌手 - 歌名」），去掉歌手前缀
    name: (function () {
      var name = item.SongName || item.songname;
      if (name) return decodeName(name);
      var fileName = item.filename || '';
      var parts = String(fileName).split(' - ');
      return decodeName(parts.length > 1 ? parts.slice(1).join(' - ') : fileName);
    })(),
    singer: authorsOf(item),
    albumName: decodeName(albumName),
    artwork: coverOf(item),
    duration: Math.floor(duration),
    source: 'kg'
  };
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

/* ---------------------------------------------------------------- 接口请求 */

function fetchSearch(keyword, page, limit) {
  var url =
    SEARCH +
    '/song_search_v2?' +
    encodeQuery({
      keyword: keyword,
      page: page,
      pagesize: limit,
      userid: 0,
      clientver: '',
      platform: 'WebFilter',
      filter: 2,
      iscorrection: 1,
      privilege_filter: 0,
      area_code: 1
    });
  return getJson(url);
}

function fetchPlaylistSearch(keyword, page, limit) {
  var url =
    MSEARCH +
    '/api/v3/search/special?' +
    encodeQuery({
      keyword: keyword,
      page: page,
      pagesize: limit,
      showtype: 10,
      filter: 0,
      version: 7910,
      sver: 2
    });
  return getJson(url);
}

function fetchSheets(tagId, page) {
  // t=6 → 热门排序；c=分类 id
  var url =
    YUEKU +
    '/yueku/v9/special/getSpecial?is_ajax=1&cdn=cdn&t=6&c=' +
    encodeURIComponent(tagId || '') +
    '&p=' +
    page;
  return getJson(url);
}

/** 歌单真实歌曲数（列表接口里的 song_count 恒为 0）。 */
function fetchSpecialInfo(specialId) {
  return getJson(
    CDN + '/api/v3/special/info?specialid=' + specialId + '&version=9108'
  )
    .then(function (body) {
      return body.data || null;
    })
    .catch(function () {
      return null;
    });
}

function fetchSpecialSongs(specialId, page) {
  // 实测 pagesize 可以给到 1000：一次取回整张歌单，详情页的「N 首歌曲」才对得上
  var url =
    CDN +
    '/api/v3/special/song?' +
    encodeQuery({
      specialid: specialId,
      page: page,
      pagesize: 1000,
      version: 9108,
      plat: 0,
      area_code: 1
    });
  return getJson(url);
}

function fetchTopLists() {
  return getJson(
    CDNBJ +
      '/api/v5/rank/list?version=9108&plat=0&showtype=2&parentid=0' +
      '&apiver=6&area_code=1&withsong=1'
  );
}

function fetchTopListDetail(rankId, page) {
  var url =
    CDNBJ +
    '/api/v5/rank/song?' +
    encodeQuery({
      version: 9108,
      ranktype: 1,
      plat: 0,
      pagesize: 100,
      area_code: 1,
      page: page,
      rankid: rankId,
      with_res_tag: 0,
      show_portrait_mv: 1
    });
  return getJson(url);
}

function fetchLyric(hash, duration) {
  // 先查歌词 id + accesskey，再下载 LRC（内容仍是 base64）
  var searchUrl =
    KRCS +
    '/search?ver=1&man=yes&client=mobi&keyword=&duration=' +
    (duration || 0) +
    '&hash=' +
    hash;
  return getJson(searchUrl).then(function (body) {
    var candidates = body.candidates || [];
    if (!candidates.length) return '';
    var candidate = candidates[0];
    if (!candidate.id || !candidate.accesskey) return '';
    var downloadUrl =
      LYRICS +
      '/download?ver=1&client=pc&id=' +
      candidate.id +
      '&accesskey=' +
      encodeURIComponent(candidate.accesskey) +
      '&fmt=lrc&charset=utf8';
    return getJson(downloadUrl).then(function (result) {
      if (Number(result.status) !== 200) return '';
      return base64Decode(result.content);
    });
  });
}

/* ---------------------------------------------------------------- 插件接口 */

module.exports = {
  pluginInfo: {
    name: '酷狗音乐数据源',
    version: '1.0.0',
    author: 'MintMusic',
    description:
      '只提供搜索、歌单分类、榜单、歌单详情的酷狗音乐数据源；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记
    isDataSource: true
  },

  sources: {
    kg: {
      name: '酷狗音乐',
      qualitys: ['128k', '320k', 'flac', 'flac24bit', 'hires'],
      actions: ['musicSearch']
    }
  },

  capabilities: {
    sheets: true,
    sheetDetail: true,
    topList: true,
    playlistSearch: true
  },

  isDataSource: true,

  /* ------------------------------------------------------------ 搜索歌曲 */
  search: function (source, keyword, page, limit) {
    var size = limit || 30;
    var currentPage = page || 1;
    return fetchSearch(keyword, currentPage, size).then(function (body) {
      var data = body.data || {};
      var list = data.lists || data.info || [];
      return JSON.stringify({ list: songsOf(list), page: currentPage });
    });
  },

  /* ------------------------------------------------------------ 搜索歌单 */
  searchPlaylists: function (keyword, page) {
    var size = 30;
    return fetchPlaylistSearch(keyword, page || 1, size).then(function (body) {
      var list = (body.data && body.data.info) || [];
      var playlists = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (item.specialid === undefined) continue;
        playlists.push({
          id: String(item.specialid),
          title: decodeName(item.specialname),
          description: decodeName(item.intro),
          coverUrl: normalizeImage(item.imgurl, '400'),
          songCount: Number(item.songcount || 0),
          playCount: formatPlayCount(item.playcount),
          author: decodeName(item.nickname)
        });
      }
      return JSON.stringify({
        isEnd: list.length < size,
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------- 歌单分类（更多分类面板） */
  getRecommendSheetTags: function () {
    // 酷狗没有可用的分类接口，与内置源保持一致：用固定分类
    return Promise.resolve(
      JSON.stringify([
        {
          name: '语种',
          tags: [
            { id: '', name: '全部' },
            { id: '11', name: '华语' },
            { id: '15', name: '欧美' }
          ]
        },
        {
          name: '风格',
          tags: [
            { id: '30', name: '流行' },
            { id: '850', name: '电子' },
            { id: '10', name: 'DJ' }
          ]
        }
      ])
    );
  },

  /* ------------------------------------------------------- 热门标签（顶部） */
  getHotPlaylistTags: function () {
    return Promise.resolve(
      JSON.stringify([
        { id: '11', name: '华语' },
        { id: '30', name: '流行' },
        { id: '850', name: '电子' }
      ])
    );
  },

  /* --------------------------------------------------- 分类歌单（歌单卡片） */
  getRecommendSheetsByTag: function (tagId, page) {
    var size = 30;
    return fetchSheets(tagId || '', page || 1).then(function (body) {
      var list = body.special_db || [];
      var playlists = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (item.specialid === undefined) continue;
        playlists.push({
          id: String(item.specialid),
          title: decodeName(item.specialname),
          description: decodeName(item.intro),
          coverUrl: normalizeImage(item.img || item.imgurl, '400'),
          songCount: Number(item.song_count || item.songcount || 0),
          playCount: formatPlayCount(item.total_play_count),
          author: String(item.nickname || '')
        });
      }
      // 列表接口不给歌曲数，逐个补一次（并发，与内置源一致）
      var pending = [];
      for (var j = 0; j < playlists.length; j++) {
        if (playlists[j].songCount > 0) continue;
        pending.push(
          fetchSpecialInfo(playlists[j].id).then(
            (function (index) {
              return function (info) {
                if (info && info.songcount !== undefined) {
                  playlists[index].songCount = Number(info.songcount) || 0;
                }
              };
            })(j)
          )
        );
      }
      return Promise.all(pending).then(function () {
        return JSON.stringify({
          isEnd: playlists.length < size,
          playlists: playlists
        });
      });
    });
  },

  /* ------------------------------------------------------------- 榜单列表 */
  getTopLists: function () {
    return fetchTopLists().then(function (body) {
      var list = (body.data && body.data.info) || [];
      var result = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (String(item.isvol) !== '1') continue;
        var id = item.rankid !== undefined ? item.rankid : item.id;
        if (id === undefined) continue;
        result.push({
          id: String(id),
          name: decodeName(item.rankname),
          coverUrl: normalizeImage(
            item.banner_9 || item.table_plaque || item.album_img_9,
            '400'
          ),
          playCount: formatPlayCount(item.play_times),
          // update_frequency 是文本（「每天」）；update_frequency_type 是数字码，
          // 直接显示会被误当成歌曲数。
          updateFrequency: item.update_frequency
            ? String(item.update_frequency)
            : ''
        });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------------- 榜单详情 */
  getTopListDetail: function (id, page) {
    var rankId = String(id || '').replace(/^kg_/, '');
    // 榜单歌曲接口不返回榜单名 / 封面，从榜单列表里补一次
    var metaPromise = fetchTopLists()
      .then(function (body) {
        var list = (body.data && body.data.info) || [];
        for (var i = 0; i < list.length; i++) {
          var item = list[i] || {};
          var itemId = item.rankid !== undefined ? item.rankid : item.id;
          if (String(itemId) === rankId) return item;
        }
        return null;
      })
      .catch(function () {
        return null;
      });
    return Promise.all([
      fetchTopListDetail(rankId, page || 1),
      metaPromise
    ]).then(function (results) {
      var data = (results[0] && results[0].data) || {};
      var meta = results[1] || {};
      var songs = songsOf(data.info || data.list || []);
      return JSON.stringify({
        isEnd: true,
        sheet: {
          title: decodeName(meta.rankname || data.rankname || '排行榜'),
          coverUrl: normalizeImage(
            meta.banner_9 ||
              meta.table_plaque ||
              meta.album_img_9 ||
              data.imgurl ||
              '',
            '400'
          ),
          description: String(data.intro || ''),
          author: ''
        },
        songs: songs
      });
    });
  },

  /* ------------------------------------------------------------- 歌单详情 */
  getMusicSheetInfo: function (sheetId, page) {
    var specialId = String(sheetId || '').replace(/^kg_/, '');
    var currentPage = page || 1;
    return Promise.all([
      fetchSpecialSongs(specialId, currentPage),
      currentPage === 1 ? fetchSpecialInfo(specialId) : Promise.resolve(null)
    ]).then(function (results) {
      var body = results[0] || {};
      var info = results[1] || {};
      var data = body.data || {};
      var songs = songsOf(data.info || data.list || []);
      var total = Number(info.songcount || data.total || songs.length);
      return JSON.stringify({
        isEnd: songs.length >= total || songs.length < 100,
        sheet: {
          title: decodeName(info.specialname || data.specialname || ''),
          coverUrl: normalizeImage(info.imgurl || data.imgurl || '', '400'),
          description: decodeName(info.intro || ''),
          author: String(info.nickname || '')
        },
        songs: songs
      });
    });
  },

  /* --------------------------------------------------------------- 歌词 */
  getLyric: function (source, musicInfo) {
    var hash =
      musicInfo && (musicInfo.songmid || musicInfo.songId || musicInfo.id);
    if (!hash) return Promise.resolve('');
    // duration 只用于歌词匹配的候选排序，传 0 也能拿到第一个候选
    return fetchLyric(hash, 0).then(function (lrc) {
      if (!lrc) return '';
      return JSON.stringify({ lyric: lrc, lrc: lrc });
    });
  },

  /* --------------------------------------------------------------- 封面 */
  getPic: function (source, musicInfo) {
    // 封面在搜索 / 歌单结果里已经带上，这里不需要再查。
    return Promise.resolve('');
  }
};
