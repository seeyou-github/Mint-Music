/*
 * MintMusic 数据源插件 —— 酷我音乐
 * ---------------------------------------------------------------------------
 * 与 netease_music_data_source.js 同一套约定：只提供搜索 / 发现页（歌单分类、
 * 榜单、歌单详情）/ 歌词等**元数据**，**不提供播放地址**（没有 musicUrl）。
 *
 * 数据源标记：pluginInfo.isDataSource === true
 *
 * 接口与内置源酷我音乐（lib/features/plugin/data/kw_music_source.dart）一致：
 *   · 搜索 / 歌单搜索走 search.kuwo.cn（返回单引号 JSON，需要容错解析）；
 *   · 分类 / 分类歌单走 wapi.kuwo.cn；
 *   · 榜单走 qukudata.kuwo.cn，榜单详情走 kbangserver.kuwo.cn；
 *   · 播放量格式：> 1 亿 → 「x.x亿」，> 1 万 → 「x.x万」，否则原样整数。
 * ---------------------------------------------------------------------------
 */

var UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
var SEARCH = 'http://search.kuwo.cn';
var WAPI = 'http://wapi.kuwo.cn';
var NPL = 'http://nplserver.kuwo.cn';
var QUKU = 'http://qukudata.kuwo.cn';
var KBANG = 'http://kbangserver.kuwo.cn';
var MOBILE = 'http://m.kuwo.cn';

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

function getText(url, headers) {
  return cerumusic
    .request(url, {
      method: 'GET',
      headers: Object.assign({ 'User-Agent': UA }, headers || {}),
      timeout: 15000
    })
    .then(function (res) {
      var body = res && res.body;
      if (body === undefined || body === null) {
        throw new Error('接口无返回');
      }
      return String(body);
    });
}

/** 酷我有些接口返回单引号 JSON（不是合法 JSON），这里容错解析。 */
function parseLoose(text) {
  if (!text) return null;
  var trimmed = String(text).trim();
  try {
    return JSON.parse(trimmed);
  } catch (e) {
    try {
      return JSON.parse(trimmed.replace(/'/g, '"'));
    } catch (e2) {
      return null;
    }
  }
}

function getJson(url, headers) {
  return getText(url, headers).then(function (text) {
    var parsed = parseLoose(text);
    if (!parsed || typeof parsed !== 'object') {
      throw new Error('接口返回异常：' + text.substring(0, 120));
    }
    return parsed;
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

function decodeName(name) {
  return String(name === undefined || name === null ? '' : name)
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

/** 酷我封面：可能是完整 URL，也可能是相对路径（补 albumcover 前缀）。 */
function normalizeCover(value, artist) {
  var raw = String(value === undefined || value === null ? '' : value).trim();
  if (!raw) return '';
  if (raw.indexOf('//') === 0) return 'http:' + raw;
  if (raw.indexOf('http://') === 0 || raw.indexOf('https://') === 0) return raw;
  var path = raw.replace(/^\/+/, '');
  var directory = artist ? 'starheads' : 'albumcover';
  return 'http://img1.kuwo.cn/star/' + directory + '/' + path;
}

function songOf(item) {
  if (!item) return null;
  // 搜索结果是 MUSICRID，歌单 / 榜单详情里是 id
  var rid = String(
    item.MUSICRID || item.musicrid || item.rid || item.id || ''
  )
    .replace(/^MUSIC_/i, '')
    .replace(/^kw_/i, '');
  if (!rid) return null;
  // 搜索 / 歌单用 DURATION / duration（秒）；榜单里的 duration 是「在榜天数」，
  // 真正的时长在 song_duration 里。
  var duration = Number(
    item.DURATION || item.song_duration || item.duration || 0
  );
  if (isNaN(duration)) duration = 0;
  var cover =
    normalizeCover(item.web_albumpic_short) ||
    normalizeCover(item.ALBUMPIC) ||
    normalizeCover(item.albumpic) ||
    normalizeCover(item.MUSICPIC) ||
    normalizeCover(item.musicPic) ||
    normalizeCover(item.web_artistpic_short, true);
  return {
    id: rid,
    songId: rid,
    songmid: rid,
    name: decodeName(item.SONGNAME || item.songname || item.name),
    singer: decodeName(item.ARTIST || item.artist || item.singer),
    albumName: decodeName(item.ALBUM || item.album),
    artwork: cover,
    duration: Math.floor(duration),
    source: 'kw'
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

/* ---------------------------------------------------------------- 接口请求 */

function fetchSearch(keyword, page, limit) {
  var url =
    SEARCH +
    '/r.s?' +
    encodeQuery({
      client: 'kt',
      all: keyword,
      pn: page - 1,
      rn: limit,
      uid: 794762570,
      ver: 'kwplayer_ar_9.2.2.1',
      vipver: 1,
      show_copyright_off: 1,
      newver: 1,
      ft: 'music',
      cluster: 0,
      strategy: 2012,
      encoding: 'utf8',
      rformat: 'json',
      vermerge: 1,
      mobi: 1,
      issubtitle: 1
    });
  return getJson(url);
}

function fetchPlaylistSearch(keyword, page, limit) {
  var url =
    SEARCH +
    '/r.s?' +
    encodeQuery({
      all: keyword,
      pn: page - 1,
      rn: limit,
      rformat: 'json',
      encoding: 'utf8',
      ver: 'mbox',
      vipver: 'MUSIC_8.7.7.0_BCS37',
      plat: 'pc',
      devid: 28156413,
      ft: 'playlist',
      pay: 0,
      needliveshow: 0
    });
  return getJson(url);
}

function fetchTagList() {
  var url =
    WAPI +
    '/api/pc/classify/playlist/getTagList?cmd=rcm_keyword_playlist&user=0' +
    '&prod=kwplayer_pc_9.0.5.0&vipver=9.0.5.0&source=kwplayer_pc_9.0.5.0' +
    '&loginUin=0&loginSid=0&appUid=76039576';
  return getJson(url);
}

function fetchHotTags() {
  var url =
    WAPI +
    '/api/pc/classify/playlist/getRcmTagList?loginUin=0&loginSid=0&appUid=76039576';
  return getJson(url);
}

function fetchSheets(tagId, page, limit) {
  var base = tagId
    ? WAPI +
      '/api/pc/classify/playlist/getTagPlayList?loginUid=0&loginSid=0' +
      '&appUid=76039576&pn=' +
      (page - 1) +
      '&id=' +
      encodeURIComponent(String(tagId).split('-')[0]) +
      '&rn=' +
      limit
    : WAPI +
      '/api/pc/classify/playlist/getRcmPlayList?loginUid=0&loginSid=0' +
      '&appUid=76039576&pn=' +
      (page - 1) +
      '&rn=' +
      limit +
      '&order=hot';
  return getJson(base);
}

function fetchTopList() {
  return getJson(
    QUKU + '/q.k?op=query&cont=tree&node=2&pn=0&rn=1000&fmt=json&level=3'
  );
}

function fetchTopListDetail(boardId, page) {
  var url =
    KBANG +
    '/ksong.s?' +
    encodeQuery({
      from: 'pc',
      fmt: 'json',
      pn: page - 1,
      rn: 100,
      type: 'bang',
      data: 'content',
      id: boardId,
      show_copyright_off: 0,
      pcmp4: 1,
      isbang: 1
    });
  return getJson(url);
}

function fetchSheetDetail(pid) {
  var url =
    NPL +
    '/pl.svc?' +
    encodeQuery({
      op: 'getlistinfo',
      pid: pid,
      pn: 0,
      rn: 1000,
      encode: 'utf8',
      keyset: 'pl2012',
      identity: 'kuwo',
      pcmp4: 1,
      plat: 'web',
      from: 'web',
      vipver: 'MUSIC_9.0.5.0_W1',
      newver: 1
    });
  return getJson(url);
}

/**
 * 有些接口（榜单、个别歌单）不返回封面字段，用 artistpicserver 逐首补。
 * 内置源也是这么补的：返回体是一行纯文本的图片地址。
 */
function fetchCoverText(rid) {
  var url =
    'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic' +
    '&pictype=500&size=500&rid=' +
    rid;
  return cerumusic
    .request(url, {
      method: 'GET',
      headers: { 'User-Agent': UA },
      timeout: 12000
    })
    .then(function (res) {
      var text = res && res.body ? String(res.body).trim() : '';
      return text.indexOf('http') === 0 ? text : '';
    })
    .catch(function () {
      return '';
    });
}

/** 给没有封面的歌曲补图（每批 10 首，避免一次打太多请求）。 */
function enrichCovers(songs) {
  var indexes = [];
  for (var i = 0; i < songs.length; i++) {
    if (!songs[i].artwork) indexes.push(i);
  }
  if (!indexes.length) return Promise.resolve(songs);

  var cursor = 0;
  function nextBatch() {
    if (cursor >= indexes.length) return Promise.resolve(songs);
    var batch = indexes.slice(cursor, cursor + 10);
    cursor += 10;
    return Promise.all(
      batch.map(function (index) {
        return fetchCoverText(songs[index].id).then(function (url) {
          if (url) songs[index].artwork = url;
        });
      })
    ).then(nextBatch);
  }
  return nextBatch();
}

function fetchLyric(rid) {
  var url = MOBILE + '/newh5/singles/songinfoandlrc?musicId=' + rid;
  return getJson(url, {
    'User-Agent':
      'Mozilla/5.0 (iPhone; CPU iPhone OS 13_2_3 like Mac OS X) ' +
      'AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
    Referer: 'http://m.kuwo.cn/'
  });
}

/** 酷我歌词是 [{time, lineLyric}]，拼成标准 LRC。 */
function lrcFromList(list) {
  if (!list || !list.length) return '';
  var lines = [];
  for (var i = 0; i < list.length; i++) {
    var item = list[i] || {};
    var text = item.lineLyric;
    if (text === undefined || text === null) continue;
    var seconds = Number(item.time);
    if (isNaN(seconds)) seconds = 0;
    var minutes = Math.floor(seconds / 60);
    var rest = seconds - minutes * 60;
    var restText = rest < 10 ? '0' + rest.toFixed(2) : rest.toFixed(2);
    var minuteText = minutes < 10 ? '0' + minutes : String(minutes);
    lines.push('[' + minuteText + ':' + restText + ']' + String(text));
  }
  return lines.join('\n');
}

/* ---------------------------------------------------------------- 插件接口 */

module.exports = {
  pluginInfo: {
    name: '酷我音乐数据源',
    version: '1.0.0',
    author: 'MintMusic',
    description:
      '只提供搜索、歌单分类、榜单、歌单详情的酷我音乐数据源；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记
    // 站点图标：导入插件时下载并缓存到插件目录（音源列表 / 切换按钮用它）
    iconUrl: 'https://www.kuwo.cn/favicon.ico',
    isDataSource: true
  },

  sources: {
    kw: {
      name: '酷我音乐',
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
      if (String(body.SHOW) === '0') return JSON.stringify({ list: [] });
      return JSON.stringify({
        list: songsOf(body.abslist || []),
        page: currentPage
      });
    });
  },

  /* ------------------------------------------------------------ 搜索歌单 */
  searchPlaylists: function (keyword, page) {
    var size = 30;
    return fetchPlaylistSearch(keyword, page || 1, size).then(function (body) {
      var list = body.abslist || [];
      var playlists = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        var id = item.playlistid || item.DC_TARGETID;
        if (!id) continue;
        playlists.push({
          id: String(id),
          title: decodeName(item.name),
          description: decodeName(item.intro),
          coverUrl: normalizeCover(item.pic || item.img),
          songCount: Number(item.songnum || 0),
          playCount: formatPlayCount(item.playcnt),
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
    return fetchTagList().then(function (body) {
      var groups = body.data || [];
      var result = [];
      for (var i = 0; i < groups.length; i++) {
        var group = groups[i] || {};
        var rawTags = group.data || [];
        var tags = [];
        for (var j = 0; j < rawTags.length; j++) {
          var tag = rawTags[j] || {};
          if (tag.id === undefined) continue;
          // 分类歌单接口只认 id，digest 用来区分同名分类
          var tagKey = String(tag.id) + '-' + String(tag.digest || '');
          tags.push({
            id: tagKey,
            name: decodeName(tag.name)
          });
        }
        if (!tags.length) continue;
        result.push({ name: decodeName(group.name) || '分类', tags: tags });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------- 热门标签（顶部） */
  getHotPlaylistTags: function () {
    return fetchHotTags().then(function (body) {
      var groups = body.data || [];
      var list = (groups[0] && groups[0].data) || [];
      var result = [];
      for (var i = 0; i < list.length; i++) {
        var tag = list[i] || {};
        if (tag.id === undefined) continue;
        result.push({
          id: String(tag.id) + '-' + String(tag.digest || ''),
          name: decodeName(tag.name)
        });
      }
      return JSON.stringify(result);
    });
  },

  /* --------------------------------------------------- 分类歌单（歌单卡片） */
  getRecommendSheetsByTag: function (tagId, page) {
    var size = 30;
    return fetchSheets(tagId || '', page || 1, size).then(function (body) {
      var data = (body.data && body.data.data) || [];
      var playlists = [];
      for (var i = 0; i < data.length; i++) {
        var item = data[i] || {};
        if (item.id === undefined) continue;
        playlists.push({
          // getMusicSheetInfo 需要从 id 里还原歌单号，digest 先带着
          id: 'digest-' + String(item.digest || 8) + '__' + String(item.id),
          title: decodeName(item.name),
          description: decodeName(item.desc),
          coverUrl: normalizeCover(item.img),
          songCount: Number(item.total || 0),
          playCount: formatPlayCount(item.listencnt),
          author: String(item.uname || '')
        });
      }
      return JSON.stringify({
        isEnd: playlists.length < size,
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------------------- 榜单列表 */
  getTopLists: function () {
    return fetchTopList().then(function (body) {
      var list = body.child || [];
      // 按收听量从高到低（与内置源一致）
      list.sort(function (a, b) {
        return Number(b.listen || 0) - Number(a.listen || 0);
      });
      var result = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        // 只保留真实榜单（sourceid 是数字；「由你音乐榜」这类外链节点跳过）
        if (item.sourceid === undefined) continue;
        if (!/^\d+$/.test(String(item.sourceid))) continue;
        result.push({
          id: String(item.sourceid),
          name: decodeName(item.name),
          coverUrl: String(item.pic || ''),
          // 榜单树里的 listen 是在榜歌曲数 / 新增数，不是播放量：宁可不显示，
          // 也不要给用户一个错误的播放量。
          playCount: '',
          updateFrequency: item.info ? String(item.info) : ''
        });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------------- 榜单详情 */
  getTopListDetail: function (id, page) {
    var boardId = String(id || '').replace(/^kw_/, '');
    return fetchTopListDetail(boardId, page || 1).then(function (body) {
      var list =
        body.musiclist || (body.bang && body.bang.musiclist) || [];
      var songs = songsOf(list);
      // 榜单接口不返回任何封面字段，逐首补图
      return enrichCovers(songs).then(function () {
        return JSON.stringify({
          isEnd: true,
          sheet: {
            title: decodeName(body.title || body.name || '排行榜'),
            coverUrl: String(body.pic || ''),
            description: String(body.info || ''),
            author: String(body.uname || '')
          },
          songs: songs
        });
      });
    });
  },

  /* ------------------------------------------------------------- 歌单详情 */
  getMusicSheetInfo: function (sheetId, page) {
    var raw = String(sheetId || '').replace(/^kw_/, '');
    var pid = raw;
    // `digest-8__123456` → 123456
    var parts = raw.split('__');
    if (parts.length === 2) pid = parts[1];
    return fetchSheetDetail(pid).then(function (body) {
      var songs = songsOf(body.musiclist || []);
      // 个别歌曲没有 albumpic，补一次封面（歌单详情整列占位图就是它导致的）
      return enrichCovers(songs).then(function () {
        return JSON.stringify({
          isEnd: true,
          sheet: {
            title: decodeName(body.title || body.name || ''),
            coverUrl: normalizeCover(body.pic),
            description: String(body.info || ''),
            author: String(body.uname || '')
          },
          songs: songs
        });
      });
    });
  },

  /* --------------------------------------------------------------- 歌词 */
  getLyric: function (source, musicInfo) {
    var rid = String(
      (musicInfo && (musicInfo.songmid || musicInfo.songId || musicInfo.id)) ||
        ''
    ).replace(/^MUSIC_/i, '');
    if (!rid) return Promise.resolve('');
    function once() {
      return fetchLyric(rid).then(function (body) {
        return lrcFromList(body.data && body.data.lrclist);
      });
    }
    return once().then(function (lrc) {
      // 这个接口偶尔返回空壳，重试一次再放弃
      if (lrc) return lrc;
      return once();
    }).then(function (lrc) {
      if (!lrc) return '';
      return JSON.stringify({ lyric: lrc, lrc: lrc });
    });
  },

  /* --------------------------------------------------------------- 封面 */
  getPic: function (source, musicInfo) {
    // 兜底：歌曲没带封面时按 rid 查一次 artistpicserver
    var rid = String(
      (musicInfo && (musicInfo.songmid || musicInfo.songId || musicInfo.id)) ||
        ''
    ).replace(/^MUSIC_/i, '');
    if (!rid) return Promise.resolve('');
    return fetchCoverText(rid);
  }
};
