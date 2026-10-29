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
 * 都没有才退化成「本页不足一页」。
 */
function isPageEnd(total, offset, count, limit, body) {
  if (total !== null) return offset + count >= total;
  if (typeof body.more === 'boolean') return !body.more;
  if (typeof body.hasMore === 'boolean') return !body.hasMore;
  return count < limit;
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
    albumId: item.ALBUMID || item.albumid ? String(item.ALBUMID || item.albumid) : '',
    // 发行年份：搜索接口没有，个别接口（专辑 / 榜单）里有
    year: yearOfTimestamp(item.pub || item.RELEASEDATE || item.releaseDate),
    artwork: cover,
    duration: Math.floor(duration),
    source: 'kw'
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

/**
 * 酷我搜索接口的「按类型」变体（专辑 / 作者 / 专辑详情 / 歌手作品）。
 * 关键是 itemset=web_2013 + pcjson=1，缺了会返回单引号 JSON 甚至空列表。
 */
function fetchTyped(params) {
  var query = {
    itemset: 'web_2013',
    client: 'kt',
    rformat: 'json',
    encoding: 'utf8',
    pcjson: 1,
    alflac: 1,
    show_copyright_off: 1,
    pcmp4: 1,
    plat: 'pc',
    thost: 'search.kuwo.cn',
    vipver: 'MUSIC_9.1.1.2_BCS2',
    devid: '38668888',
    newver: 1
  };
  for (var key in params) {
    if (!Object.prototype.hasOwnProperty.call(params, key)) continue;
    query[key] = params[key];
  }
  return getJson(SEARCH + '/r.s?' + encodeQuery(query));
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

/* 榜单分类派生：榜单树没有分组字段（官方网页/App 的分组是各自页面侧
 * 实现的），按官方 App 榜单页的板块习惯用精确名映射；映射表外的
 * 新榜兜底归「特色榜」（酷我 web 的分组名），不会丢榜。 */
var KUWO_BOARD_GROUPS = {
  官方榜: ['酷我飙升榜', '酷我新歌榜', '酷我热歌榜', '抖音热歌榜'],
  曲风榜: [
    'DJ嗨歌榜',
    '古风音乐榜',
    '酷我电音榜',
    '最强翻唱榜',
    '经典怀旧榜',
    'Vlog音乐榜',
    '酷我热评榜'
  ],
  语种榜: ['酷我华语榜', '酷我粤语榜', '酷我欧美榜', '酷我韩语榜', '酷我日语榜'],
  全球榜: [
    'Billboard榜',
    'beatport电音榜',
    '英国UK榜',
    '百大DJ榜',
    'YouTube音乐排行榜',
    '日本公信榜'
  ],
  '场景/内容榜': [
    '现场音乐榜',
    '影视金曲榜',
    '网红新歌榜',
    '腾讯音乐人原创榜',
    '流行趋势榜',
    '会员畅听榜',
    '儿童歌曲榜'
  ]
};

/** 榜单名 → 分类名（官方榜优先级最高，兜底「特色榜」）。 */
function kuwoBoardGroup(name) {
  for (var group in KUWO_BOARD_GROUPS) {
    if (!Object.prototype.hasOwnProperty.call(KUWO_BOARD_GROUPS, group)) continue;
    var names = KUWO_BOARD_GROUPS[group];
    for (var i = 0; i < names.length; i++) {
      if (names[i] === name) return group;
    }
  }
  return '特色榜';
}

/** 歌单 / 榜单详情每页歌曲数（与 App 歌单详情页一致）。 */
var SHEET_PAGE_SIZE = 50;

function fetchTopListDetail(boardId, page) {
  var url =
    KBANG +
    '/ksong.s?' +
    encodeQuery({
      from: 'pc',
      fmt: 'json',
      pn: page - 1,
      rn: SHEET_PAGE_SIZE,
      type: 'bang',
      data: 'content',
      id: boardId,
      show_copyright_off: 0,
      pcmp4: 1,
      isbang: 1
    });
  return getJson(url);
}

function fetchSheetDetail(pid, page, size) {
  var url =
    NPL +
    '/pl.svc?' +
    encodeQuery({
      op: 'getlistinfo',
      pid: pid,
      pn: (page || 1) - 1,
      rn: size || SHEET_PAGE_SIZE,
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

/**
 * 逐字歌词（LRCX）：newlyric.kuwo.cn 的加密接口。
 *
 * 参数用 'yeelion' 循环异或后 base64，响应是「tp=content 头 + 裸 deflate」，
 * 解压后是 base64 文本，再 base64 解码 + 同样的异或，得到 **GBK** 编码的
 * LRCX（`[mm:ss.mmm]<相对起始,时长>字`）。GBK 交给 App 侧转码。
 */
function xorBase64(text, key) {
  var bytes = cerumusic.utils.buffer.from(text, 'utf8');
  var out = [];
  for (var i = 0; i < bytes.length; i++) {
    out.push((bytes[i] ^ key.charCodeAt(i % key.length)) & 0xff);
  }
  return cerumusic.utils.buffer.bufToString(out, 'base64');
}

function fetchLrcx(rid) {
  if (!cerumusic.utils.zlib || !cerumusic.utils.charset) {
    // 老版本 App 没有 inflateRaw / charset 桥，直接放弃逐字
    return Promise.resolve('');
  }
  var params =
    'user=12345,web,web,web&requester=localhost&req=1&rid=MUSIC_' +
    rid +
    '&lrcx=1';
  var url =
    'http://newlyric.kuwo.cn/newlyric.lrc?' + xorBase64(params, 'yeelion');
  return cerumusic
    .request(url, {
      method: 'GET',
      headers: { 'User-Agent': UA },
      timeout: 15000
    })
    .then(function (res) {
      var raw = cerumusic.utils.buffer.from(
        (res && res.bodyBase64) || '',
        'base64'
      );
      // 跳过 `tp=content\r\n...\r\n\r\n` 头
      var start = -1;
      for (var i = 0; i + 3 < raw.length; i++) {
        if (raw[i] === 13 && raw[i + 1] === 10 && raw[i + 2] === 13 && raw[i + 3] === 10) {
          start = i + 4;
          break;
        }
      }
      if (start < 0) return '';
      var body = [];
      for (var j = start; j < raw.length; j++) body.push(raw[j]);
      return cerumusic.utils.zlib
        .inflateRaw(body)
        .catch(function () {
          return cerumusic.utils.zlib.inflate(body);
        })
        .then(function (inflated) {
          var base64Text = cerumusic.utils.buffer
            .bufToString(inflated, 'utf8')
            .trim();
          if (!base64Text) return '';
          var lrc = cerumusic.utils.buffer.from(base64Text, 'base64');
          var key = 'yeelion';
          var decoded = [];
          for (var k = 0; k < lrc.length; k++) {
            decoded.push((lrc[k] ^ key.charCodeAt(k % key.length)) & 0xff);
          }
          return cerumusic.utils.charset.decode(decoded, 'gbk');
        });
    })
    .catch(function () {
      return '';
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
    name: '酷我_数据源',
    version: '1.5.0',
    author: 'MintMusic',
    description:
      '只提供搜索、歌单分类（不含专区）、榜单（含分类，已过滤学习机/有声榜）、歌单详情的酷我音乐数据源；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记
    // 站点图标：导入插件时下载并缓存到插件目录（音源列表 / 切换按钮用它）
    iconUrl: 'https://www.kuwo.cn/favicon.ico',
    isDataSource: true
  },

  sources: {
    kw: {
      name: '酷我',
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

  /** 支持的搜索类型：歌曲 / 专辑 / 作者。 */
  supportedSearchTypes: function () {
    return ['music', 'album', 'artist'];
  },

  isDataSource: true,

  /* ------------------------------------------------------- 热门搜索（搜索页） */
  getHotSearchTags: function () {
    var url =
      'https://hotword.kuwo.cn/hotword.s?prod=kwplayer_ar_9.3.0.1&corp=kuwo' +
      '&newver=2&vipver=9.3.0.1&source=kwplayer_ar_9.3.0.1_40.apk&p2p=1' +
      '&notrace=0&uid=0&plat=kwplayer_ar&rformat=json&encoding=utf8&tabid=1';
    return getJson(url, {
      'User-Agent': 'Dalvik/2.1.0 (Linux; U; Android 9;)',
      Referer: 'https://kuwo.cn/'
    })
      .then(function (body) {
        if (String(body.status || '').toLowerCase() !== 'ok') return [];
        var list = body.tagvalue || [];
        var tags = [];
        for (var i = 0; i < list.length && tags.length < 10; i++) {
          var item = list[i] || {};
          var word = item.key || '';
          if (!word) continue;
          tags.push(String(word));
        }
        return tags;
      })
      .catch(function () {
        return [];
      })
      .then(function (tags) {
        return JSON.stringify(tags);
      });
  },

  /* ------------------------------------------------------------ 搜索歌曲 */
  search: function (source, keyword, page, limit) {
    var size = limit || 30;
    var currentPage = page || 1;
    return fetchSearch(keyword, currentPage, size).then(function (body) {
      // 无版权 / 无结果时 SHOW=0
      if (String(body.SHOW) === '0') {
        return JSON.stringify({
          list: [],
          page: currentPage,
          total: 0,
          limit: size,
          isEnd: true
        });
      }
      var list = body.abslist || [];
      var total = totalOf(body.TOTAL);
      return JSON.stringify({
        list: songsOf(list),
        page: currentPage,
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * (currentPage - 1), list.length, size, body)
      });
    });
  },

  /* ------------------------------------------------------------ 搜索歌单 */
  searchPlaylists: function (keyword, page) {
    var size = 30;
    return fetchPlaylistSearch(keyword, page || 1, size).then(function (body) {
      var list = body.abslist || [];
      var total = totalOf(body.TOTAL);
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
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * ((page || 1) - 1), list.length, size, body),
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------------- 搜索专辑 / 作者 */
  searchTyped: function (source, keyword, page, limit, type) {
    var size = limit || 30;
    var currentPage = page || 1;
    var isAlbum = type === 'album';
    return fetchTyped({
      all: keyword,
      ft: isAlbum ? 'album' : 'artist',
      pn: currentPage - 1,
      rn: size
    }).then(function (body) {
      var list = isAlbum ? body.albumlist || [] : body.abslist || [];
      var items = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (isAlbum) {
          var albumId = item.albumid || item.id;
          if (!albumId) continue;
          items.push({
            id: String(albumId),
            title: decodeName(item.name || item.title),
            coverUrl: normalizeCover(item.img || item.hts_img || item.pic),
            artist: decodeName(item.artist),
            worksNum: Number(item.musiccnt || 0),
            date: String(item.pub || item.showtime || ''),
            description: decodeName(item.info),
            // getAlbumInfo 需要原样带回的信息
            raw: {
              id: String(albumId),
              albumid: String(albumId),
              name: decodeName(item.name || item.title)
            }
          });
        } else {
          var artistId = item.ARTISTID || item.artistid;
          if (!artistId) continue;
          items.push({
            id: String(artistId),
            title: decodeName(item.ARTIST || item.artist),
            coverUrl: normalizeCover(
              item.PICPATH || item.pic || item.artistpic,
              true
            ),
            worksNum: Number(item.SONGNUM || item.songnum || 0),
            description: decodeName(item.desc || item.info),
            raw: {
              id: String(artistId),
              artistid: String(artistId),
              name: decodeName(item.ARTIST || item.artist)
            }
          });
        }
      }
      // 专辑接口的总数是小写 total，作者接口是大写 TOTAL，两个都要兜
      var total = totalOf(body.total);
      if (total === null) total = totalOf(body.TOTAL);
      return JSON.stringify({
        list: items,
        total: total,
        limit: size,
        isEnd: isPageEnd(
          total,
          size * (currentPage - 1),
          list.length,
          size,
          body
        )
      });
    });
  },

  /* ------------------------------------------------------------- 专辑详情 */
  getAlbumInfo: function (source, albumItem, page) {
    var raw = (albumItem && albumItem.raw) || albumItem || {};
    var albumId = raw.albumid || raw.id || (albumItem && albumItem.id) || '';
    if (!albumId) return Promise.resolve(JSON.stringify({ musicList: [] }));
    return fetchTyped({
      pn: 0,
      rn: 1000,
      albumid: albumId,
      stype: 'albuminfo',
      sortby: 0
    }).then(function (body) {
      var songs = songsOf(body.musiclist || []);
      return enrichCovers(songs).then(function () {
        var total = totalOf(body.songnum);
        if (total === null) total = songs.length;
        return JSON.stringify({
          // 专辑接口一次返回全部歌曲（rn=1000）
          isEnd: true,
          total: total,
          albumItem: {
            id: String(albumId),
            title: decodeName(body.name || body.title || raw.name),
            coverUrl: normalizeCover(body.img || body.hts_img || body.pic),
            artist: decodeName(body.artist),
            worksNum: total,
            date: String(body.pub || ''),
            description: decodeName(body.info)
          },
          musicList: songs
        });
      });
    });
  },

  /* ------------------------------------------------------------- 作者作品 */
  getArtistWorks: function (source, artistItem, page, type) {
    var raw = (artistItem && artistItem.raw) || artistItem || {};
    var artistId =
      raw.artistid || raw.id || (artistItem && artistItem.id) || '';
    if (!artistId) return Promise.resolve(JSON.stringify({ musicList: [] }));
    var size = 100;
    return fetchTyped({
      pn: (page || 1) - 1,
      rn: size,
      artistid: artistId,
      stype: 'artist2music',
      sortby: 0
    }).then(function (body) {
      var songs = songsOf(body.musiclist || body.abslist || []);
      var total = totalOf(body.total);
      if (total === null) total = songs.length;
      return enrichCovers(songs).then(function () {
        return JSON.stringify({
          total: total,
          limit: size,
          isEnd: isPageEnd(
            total,
            size * ((page || 1) - 1),
            songs.length,
            size,
            body
          ),
          artistItem: {
            id: String(artistId),
            title: decodeName(
              body.artist || raw.name || (artistItem && artistItem.title)
            ),
            coverUrl: (artistItem && artistItem.coverUrl) || '',
            worksNum: total
          },
          musicList: songs
        });
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
        // 「专区」分类拿不到数据（分类歌单接口不认这些标签），不入面板
        if (decodeName(group.name) === '专区') continue;
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
      var total = totalOf(body.data && body.data.total);
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
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * ((page || 1) - 1), playlists.length, size, body),
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------------------- 榜单列表 */
  getTopLists: function () {
    return fetchTopList().then(function (body) {
      var list = body.child || [];
      var result = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        // 只保留真实榜单（sourceid 是数字；「由你音乐榜」这类外链节点跳过）
        if (item.sourceid === undefined) continue;
        if (!/^\d+$/.test(String(item.sourceid))) continue;
        var name = decodeName(item.name);
        // 学习机内容与有声故事榜不属于音乐榜单，过滤
        if (/^青少年专属/.test(name) || name === '儿童故事榜') continue;
        result.push({
          id: String(item.sourceid),
          name: name,
          coverUrl: String(item.pic || ''),
          // 榜单树里的 listen 是在榜歌曲数 / 新增数，不是播放量：宁可不显示，
          // 也不要给用户一个错误的播放量。
          playCount: '',
          updateFrequency: item.info ? String(item.info) : '',
          group: kuwoBoardGroup(name)
        });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------------- 榜单详情 */
  getTopListDetail: function (id, page) {
    var boardId = String(id || '').replace(/^kw_/, '');
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
    return fetchTopListDetail(boardId, currentPage).then(function (body) {
      var list =
        body.musiclist || (body.bang && body.bang.musiclist) || [];
      var songs = songsOf(list);
      // num 是榜单总歌曲数（榜单通常固定 300 首），按 SHEET_PAGE_SIZE 一页翻
      var total = totalOf(body.num);
      if (total === null) total = songs.length;
      // 榜单接口不返回任何封面字段，逐首补图
      return enrichCovers(songs).then(function () {
        return JSON.stringify({
          total: total,
          limit: size,
          isEnd: isPageEnd(
            total,
            size * (currentPage - 1),
            songs.length,
            size,
            body
          ),
          sheet: {
            title: decodeName(body.title || body.name || '排行榜'),
            coverUrl: String(body.pic || ''),
            description: String(body.info || ''),
            author: String(body.uname || ''),
            songCount: total
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
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
    // pn 是页号（rn 为每页条数）；只取当前页，不再一次拉整张歌单
    return fetchSheetDetail(pid, currentPage, size).then(function (body) {
      var songs = songsOf(body.musiclist || []);
      var total = totalOf(body.total);
      if (total === null) total = songs.length;
      // 个别歌曲没有 albumpic，补一次封面（歌单详情整列占位图就是它导致的）
      return enrichCovers(songs).then(function () {
        return JSON.stringify({
          total: total,
          limit: size,
          isEnd: isPageEnd(
            total,
            size * (currentPage - 1),
            songs.length,
            size,
            body
          ),
          sheet: {
            title: decodeName(body.title || body.name || ''),
            coverUrl: normalizeCover(body.pic),
            description: String(body.info || ''),
            author: String(body.uname || ''),
            songCount: total
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
    // 逐行 LRC（兜底）与逐字 LRCX 并行，LRCX 放 crlyric 走逐字通道
    return Promise.all([
      once().then(function (lrc) {
        // 这个接口偶尔返回空壳，重试一次再放弃
        return lrc || once();
      }).catch(function () {
        return '';
      }),
      fetchLrcx(rid)
    ]).then(function (results) {
      var lrc = results[0] || '';
      var lrcx = results[1] || '';
      if (!lrc && !lrcx) return '';
      return JSON.stringify({
        lyric: lrc || lrcx,
        lrc: lrc,
        lrcx: lrcx,
        crlyric: lrcx
      });
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
