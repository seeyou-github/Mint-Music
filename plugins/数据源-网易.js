/*
 * MintMusic 数据源插件 —— 网易云音乐
 * ---------------------------------------------------------------------------
 * 这是一个「数据源」插件：只提供搜索 / 发现页（歌单分类、榜单、歌单详情）/
 * 专辑 / 作者 / 歌词 / 封面等**元数据**，**不提供播放地址**（没有 musicUrl）。
 *
 * 数据源标记：pluginInfo.isDataSource === true
 *   · 导入时会被归到「插件管理 → 数据源」分类（与内置音源、普通插件音源并列）；
 *   · 在「数据源」里给这个插件指定一个已安装的播放源，播放时用该播放源解析
 *     地址（数据源只负责“有哪些歌”）。
 *
 * 接口与内置源网易云音乐保持一致（lib/features/plugin/data/netease_music_source.dart）：
 *   · 直连 music.163.com 的 /api/* 老接口（等价于内置源的 linuxapi 通道）；
 *   · 直连失败时依次回退到内置源用到的两个代理；
 *   · 播放量格式与内置源完全相同：≥1 亿 → 「x.x亿」，≥1 万 → 「x.x万」，否则原样；
 *   · 榜单更新时间直接透传网易云的 updateFrequency（「刚刚更新」/「每周四更新」/
 *     「更新20首」…）。
 * ---------------------------------------------------------------------------
 */

var HOST = 'https://music.163.com';
var PROXIES = [
  'https://netease-cloud-music-api.fe-mm.com',
  'https://ncmapi.btwoa.com'
];

var BASE_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
  'Referer': 'https://music.163.com/',
  'Origin': 'https://music.163.com',
  'Accept': 'application/json, text/plain, */*',
  'Cookie': 'os=pc; appver=2.9.7; osver=Microsoft-Windows-10; deviceId=mintmusic'
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
      /* 保持原样，交给下面判断 */
    }
  }
  if (!body || typeof body !== 'object') {
    var text = body === undefined || body === null ? '' : String(body);
    throw new Error('接口返回异常：' + text.substring(0, 120));
  }
  if (body.code !== undefined && Number(body.code) !== 200) {
    throw new Error('接口返回 code=' + body.code);
  }
  return body;
}

function getJson(url) {
  return cerumusic
    .request(url, { method: 'GET', headers: BASE_HEADERS, timeout: 15000 })
    .then(decodeBody);
}

function postForm(url, form) {
  return cerumusic
    .request(url, {
      method: 'POST',
      headers: BASE_HEADERS,
      form: form,
      timeout: 15000
    })
    .then(decodeBody);
}

/** eapi 的固定密钥（AES-128-ECB，PKCS7）。 */
var EAPI_KEY = 'e82ckenh8dichen8';
var EAPI_UA = 'NeteaseMusicDesktop/2.10.13.201538 (Windows 10)';

function utf8ToBase64(text) {
  return cerumusic.utils.buffer.bufToString(
    cerumusic.utils.buffer.from(text, 'utf8'),
    'base64'
  );
}

function base64ToHex(base64) {
  return cerumusic.utils.buffer.bufToString(
    cerumusic.utils.buffer.from(base64, 'base64'),
    'hex'
  );
}

/**
 * eapi 加密参数：`url-36cd479b6b5-json-36cd479b6b5-md5`，AES-128-ECB 后转大写 hex。
 * 网易云的逐字歌词（yrc）只在这个加密接口里返回。
 */
function eapiParams(url, payload) {
  var text = JSON.stringify(payload);
  var digest = cerumusic.utils.crypto.md5(
    'nobody' + url + 'use' + text + 'md5forencrypt'
  );
  var data = url + '-36cd479b6b5-' + text + '-36cd479b6b5-' + digest;
  // aesEncrypt 是异步桥（返回 Promise），必须链式等待后再转 hex；
  // 同步取值会把 Promise 传给 Buffer.from 得到空串，params 恒为空。
  return cerumusic.utils.crypto
    .aesEncrypt(utf8ToBase64(data), 'aes-128-ecb', utf8ToBase64(EAPI_KEY), '')
    .then(function (encrypted) {
      return base64ToHex(encrypted).toUpperCase();
    });
}

/**
 * 逐字歌词（yrc）：走 eapi 加密接口，没拿到（老歌 / 接口异常）就返回空串，
 * 调用方继续用普通 LRC。
 */
function fetchYrcLyric(id) {
  var url = '/api/song/lyric/v1';
  var payload = {
    id: String(id),
    cp: false,
    lv: -1,
    kv: -1,
    tv: -1,
    rv: -1,
    yv: -1,
    ytv: -1,
    yrv: -1
  };
  return eapiParams(url, payload)
    .then(function (params) {
      return cerumusic.request('https://music.163.com/eapi/song/lyric/v1', {
        method: 'POST',
        headers: {
          'User-Agent': EAPI_UA,
          'Referer': 'https://music.163.com/',
          'Cookie': BASE_HEADERS['Cookie']
        },
        form: { params: params },
        timeout: 15000
      });
    })
    .then(function (res) {
      var body = res && res.body;
      if (typeof body === 'string') {
        try {
          body = JSON.parse(body);
        } catch (e) {
          return '';
        }
      }
      var yrc = body && body.yrc && body.yrc.lyric;
      return yrc ? String(yrc) : '';
    })
    .catch(function () {
      return '';
    });
}

/**
 * 依次尝试多个请求，返回第一个成功的结果。
 * 全部失败时抛出最后一个错误（错误文案里带上每个失败原因，便于排查）。
 */
function chain(steps) {
  var errors = [];
  var index = 0;
  function next() {
    if (index >= steps.length) {
      throw new Error(
        errors.length ? errors.join(' / ') : '接口不可用（未配置请求）'
      );
    }
    var step = steps[index++];
    return Promise.resolve()
      .then(step)
      .catch(function (err) {
        errors.push((err && err.message) || String(err));
        return next();
      });
  }
  return Promise.resolve().then(next);
}

function totalOf(value) {
  if (typeof value !== 'number' && typeof value !== 'string') return null;
  if (typeof value === 'string' && !value.trim()) return null;
  var total = Number(value);
  return isFinite(total) && total >= 0 && Math.floor(total) === total &&
    total <= 9007199254740991 ? total : null;
}

function isPageEnd(total, offset, count, limit, body) {
  if (total !== null) return offset + count >= total;
  if (typeof body.more === 'boolean') return !body.more;
  if (typeof body.hasMore === 'boolean') return !body.hasMore;
  return count < limit;
}

/* ---------------------------------------------------------------- 字段映射 */

/** 封面地址规范化（与内置源 _normalizeCoverUrl 一致：https + 400x400）。 */
function normalizeCover(url) {
  if (!url) return '';
  var value = String(url).trim();
  if (!value) return '';
  if (value.indexOf('//') === 0) value = 'https:' + value;
  if (value.indexOf('http://') === 0) value = 'https://' + value.substring(7);
  if (value.indexOf('music.126.net') >= 0) {
    var queryIndex = value.indexOf('?');
    if (queryIndex >= 0) value = value.substring(0, queryIndex);
    value = value + '?param=400y400';
  }
  return value;
}

/**
 * 播放量格式化 —— 与内置源 _formatPlayCount 完全一致：
 *   ≥ 100000000 → 「x.x亿」，≥ 10000 → 「x.x万」，否则整数原样。
 */
function formatPlayCount(count) {
  if (count === undefined || count === null || count === '') return '';
  var n = typeof count === 'number' ? count : parseInt(count, 10);
  if (isNaN(n)) n = 0;
  if (n >= 100000000) return (n / 100000000).toFixed(1) + '亿';
  if (n >= 10000) return (n / 10000).toFixed(1) + '万';
  if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
  return String(n);
}

function artistsOf(track) {
  var artists = track.ar || track.artists || [];
  if (!artists || !artists.length) return '';
  var names = [];
  for (var i = 0; i < artists.length; i++) {
    var name = artists[i] && artists[i].name;
    if (name) names.push(String(name));
  }
  return names.join('、');
}

function albumOf(track) {
  var album = track.al || track.album || {};
  return {
    id: album.id,
    name: album.name || track.albumName || '',
    picUrl: album.picUrl || album.pic_url || album.blurPicUrl || track.picUrl || ''
  };
}

/** 网易云歌曲 → 插件歌曲结构（时长统一换算成秒）。 */
function songOf(track) {
  if (!track) return null;
  var album = albumOf(track);
  var rawDuration = track.dt || track.duration || 0;
  var ms = Number(rawDuration) || 0;
  var seconds = ms > 10000 ? Math.floor(ms / 1000) : Math.floor(ms);
  var id = track.id !== undefined && track.id !== null ? String(track.id) : '';
  return {
    id: id,
    songId: id,
    songmid: id,
    name: track.name || track.title || '',
    singer: artistsOf(track),
    albumName: album.name,
    artwork: normalizeCover(album.picUrl),
    duration: seconds,
    source: 'wy'
  };
}

function songsOf(list) {
  var result = [];
  if (!list || !list.length) return result;
  for (var i = 0; i < list.length; i++) {
    var song = songOf(list[i]);
    if (song && song.id) result.push(song);
  }
  return result;
}

/** 网易云歌单 → 插件歌单结构（播放量已格式化）。 */
function playlistOf(item) {
  var creator = item.creator || {};
  return {
    id: String(item.id),
    title: item.name || '',
    description: item.description || '',
    coverUrl: normalizeCover(item.coverImgUrl || item.picUrl),
    songCount: Number(item.trackCount || 0),
    playCount: formatPlayCount(item.playCount),
    author: creator.nickname ? String(creator.nickname) : ''
  };
}

function playlistsOf(list) {
  var result = [];
  if (!list || !list.length) return result;
  for (var i = 0; i < list.length; i++) {
    if (!list[i] || list[i].id === undefined) continue;
    result.push(playlistOf(list[i]));
  }
  return result;
}

/* ---------------------------------------------------------------- 接口请求 */

function fetchCategories() {
  return chain([
    function () {
      return getJson(HOST + '/api/playlist/catalogue');
    },
    function () {
      return getJson(PROXIES[0] + '/playlist/catlist');
    },
    function () {
      return getJson(PROXIES[1] + '/playlist/catlist');
    }
  ]);
}

function fetchHotTags() {
  return chain([
    function () {
      return getJson(HOST + '/api/playlist/hottags');
    },
    function () {
      return getJson(PROXIES[0] + '/playlist/hot');
    },
    function () {
      return getJson(PROXIES[1] + '/playlist/hot');
    }
  ]);
}

function fetchPlaylistList(cat, order, limit, offset) {
  var params = { cat: cat, order: order, limit: limit, offset: offset };
  return chain([
    function () {
      return getJson(HOST + '/api/playlist/list?' + encodeQuery(params));
    },
    function () {
      return postForm(HOST + '/api/playlist/list', {
        cat: cat,
        order: order,
        limit: limit,
        offset: offset,
        total: 'true'
      });
    },
    function () {
      return getJson(PROXIES[0] + '/top/playlist?' + encodeQuery(params));
    },
    function () {
      return getJson(PROXIES[1] + '/top/playlist?' + encodeQuery(params));
    }
  ]);
}

/**
 * 歌单 / 榜单详情的每页歌曲数。
 *
 * 与 App 歌单详情页一致（每页 50 首）：打开第 N 页只取这一页的歌曲，
 * 不再一次把上千首歌的详情全部拉回来。
 */
var SHEET_PAGE_SIZE = 50;

/** 歌单元数据（含完整 trackIds）的复用时长：翻其它页时不用重复拉全部 ID。 */
var SHEET_META_TTL = 5 * 60 * 1000;
var sheetMetaCache = { id: '', body: null, time: 0 };

function fetchPlaylistDetail(id) {
  // n=0：只要歌单元数据 + 完整 trackIds。上千首的歌单如果带 tracks，
  // 响应会有几 MB，实际歌曲详情按页单独取。
  var params = { id: id, n: 0, s: 8 };
  return chain([
    function () {
      return getJson(HOST + '/api/v3/playlist/detail?' + encodeQuery(params));
    },
    function () {
      return getJson(PROXIES[0] + '/playlist/detail?' + encodeQuery(params));
    },
    function () {
      return getJson(PROXIES[1] + '/playlist/detail?' + encodeQuery(params));
    },
    function () {
      return getJson(HOST + '/api/playlist/detail?' + encodeQuery(params));
    }
  ]);
}

/** 取歌单元数据（同一个歌单短时间内的多次翻页共用一次请求）。 */
function fetchPlaylistMeta(id) {
  var key = String(id || '');
  var now = Date.now();
  if (
    sheetMetaCache.body &&
    sheetMetaCache.id === key &&
    now - sheetMetaCache.time < SHEET_META_TTL
  ) {
    return Promise.resolve(sheetMetaCache.body);
  }
  return fetchPlaylistDetail(key).then(function (body) {
    sheetMetaCache = { id: key, body: body, time: Date.now() };
    return body;
  });
}

function fetchTopList() {
  return chain([
    function () {
      return getJson(HOST + '/api/toplist');
    },
    function () {
      return getJson(PROXIES[0] + '/toplist');
    },
    function () {
      return getJson(PROXIES[1] + '/toplist');
    }
  ]);
}

/* 榜单分类派生：/api/toplist 是扁平数组（官方网页/App 的分组都是页面侧
 * 自己实现的），这里按官方 App 榜单页的板块习惯派生 group。 */

// 品牌合作 / 运营榜（车厂、音乐合伙人、直播/游戏联名等），官方 App 榜单页
// 不作主列表展示，直接过滤。命中任一模式返回 null。
var NETEASE_BOARD_BRAND_PATTERNS = [
  /车友爱听榜$/,
  /^音乐合伙人/,
  /^小天才/,
  /^荣耀音乐/,
  /蛋仔派对/,
  /^LOOK直播/,
  /^星云榜/,
  /喜力/,
  /^乐夏榜$/,
  /^赏音榜$/,
  /^BEAT排行榜$/,
  /^潮流风向榜$/
];

/** 榜单 → 分类名；命中品牌榜模式返回 null（过滤）。 */
function neteaseBoardGroup(item) {
  var name = String(item.name || '');
  for (var i = 0; i < NETEASE_BOARD_BRAND_PATTERNS.length; i++) {
    if (NETEASE_BOARD_BRAND_PATTERNS[i].test(name)) return null;
  }
  // ToplistType（S/N/O/H）只存在于飙升/新歌/原创/热歌官方四榜
  if (item.ToplistType) return '官方榜';
  if (/^网易云(韩语|日语|欧美热歌|欧美新歌)榜$/.test(name)) return '语种榜';
  if (/^(俄语|越南语|泰语)榜$/.test(name)) return '语种榜';
  if (/^(UK排行榜|美国Billboard|Beatport全球电子舞曲|KTV唛榜|日本Oricon|法国|俄罗斯top hit)/.test(name)) {
    return '全球媒体榜';
  }
  if (/^网易云/.test(name) || /^(中文慢摇DJ榜|欧美R&B榜)$/.test(name)) {
    return '曲风榜';
  }
  // 听歌识曲、潜力爆款、网络热歌、AI歌曲、实时热度/分享、黑胶VIP系列等
  return '精选榜';
}

function fetchSearch(keyword, type, limit, offset) {
  var form = { s: keyword, type: type, limit: limit, offset: offset };
  var query = {
    keywords: keyword,
    type: type,
    limit: limit,
    offset: offset
  };
  return chain([
    // 新版 cloudsearch：歌曲自带 ar/al（含封面），数量字段也更全
    function () {
      return postForm(HOST + '/api/cloudsearch/pc', form);
    },
    function () {
      return getJson(PROXIES[0] + '/cloudsearch?' + encodeQuery(query));
    },
    // 老接口兜底：响应里没有封面，search 出口用代理 song/detail 批量补
    function () {
      return postForm(HOST + '/api/search/get', form);
    },
    function () {
      return getJson(HOST + '/api/search/get?' + encodeQuery(form));
    },
    function () {
      return getJson(PROXIES[0] + '/search?' + encodeQuery(query));
    },
    function () {
      return getJson(PROXIES[1] + '/search?' + encodeQuery(query));
    }
  ]);
}

function fetchAlbum(id) {
  return chain([
    // 注意：music.163.com 没有 /api/v3/album/<id>（会返回 code=404），
    // 老接口 /api/album/<id> 的歌曲在 album.songs 里。
    function () {
      return getJson(HOST + '/api/album/' + encodeURIComponent(id));
    },
    function () {
      return getJson(PROXIES[0] + '/album?' + encodeQuery({ id: id }));
    },
    function () {
      return getJson(PROXIES[1] + '/album?' + encodeQuery({ id: id }));
    }
  ]);
}

function fetchArtistSongs(id, limit, offset) {
  var params = { id: id, order: 'hot', limit: limit, offset: offset };
  // 热门 50 首接口不支持翻页，不能作为全部作品的回退。
  return chain([
    function () {
      return getJson(HOST + '/api/v1/artist/songs?' + encodeQuery(params));
    },
    function () {
      return getJson(PROXIES[0] + '/artist/songs?' + encodeQuery(params));
    },
    function () {
      return getJson(PROXIES[1] + '/artist/songs?' + encodeQuery(params));
    }
  ]);
}

function fetchLyric(id) {
  var params = { id: id, lv: -1, kv: -1, tv: -1 };
  return chain([
    function () {
      return getJson(HOST + '/api/song/lyric?' + encodeQuery(params));
    },
    function () {
      return getJson(PROXIES[0] + '/lyric?' + encodeQuery(params));
    },
    function () {
      return getJson(PROXIES[1] + '/lyric?' + encodeQuery(params));
    }
  ]);
}

function fetchSongDetails(ids) {
  function checked(url) {
    return getJson(url).then(function (body) {
      if (!Array.isArray(body.songs)) throw new Error('歌曲详情缺少 songs');
      return body;
    });
  }
  return chain([
    function () {
      return checked(
        HOST + '/api/song/detail?' + encodeQuery({ ids: '[' + ids.join(',') + ']' })
      );
    },
    function () {
      return checked(PROXIES[0] + '/song/detail?' + encodeQuery({ ids: ids.join(',') }));
    },
    function () {
      return checked(PROXIES[1] + '/song/detail?' + encodeQuery({ ids: ids.join(',') }));
    }
  ]);
}

function fetchSongDetail(id) {
  return fetchSongDetails([id]);
}

/**
 * 封面专用详情：代理优先。
 * 直连老接口 /api/song/detail 的歌曲对象不带 picUrl，只有代理的响应里有，
 * 所以查封面必须先走代理；代理都挂了再退回直连（至少保证歌曲信息可用）。
 */
function fetchCoverDetails(ids) {
  function once(url) {
    return getJson(url).then(function (body) {
      if (!Array.isArray(body.songs)) throw new Error('歌曲详情缺少 songs');
      return body.songs;
    });
  }
  return chain([
    function () {
      return once(PROXIES[0] + '/song/detail?' + encodeQuery({ ids: ids.join(',') }));
    },
    function () {
      return once(PROXIES[1] + '/song/detail?' + encodeQuery({ ids: ids.join(',') }));
    },
    function () {
      return once(
        HOST + '/api/song/detail?' + encodeQuery({ ids: '[' + ids.join(',') + ']' })
      );
    }
  ]);
}

/** 老搜索接口的歌曲没有封面：按 id 批量补（一次请求，缺封面才发）。 */
function hydrateSearchCovers(songs) {
  var missing = {};
  for (var i = 0; i < songs.length; i++) {
    if (!songs[i].artwork) missing[songs[i].id] = true;
  }
  var ids = Object.keys(missing);
  if (!ids.length) return Promise.resolve(songs);
  return fetchCoverDetails(ids.slice(0, 50))
    .then(function (details) {
      var byId = {};
      for (var d = 0; d < details.length; d++) {
        var song = songOf(details[d]);
        if (song && song.artwork) byId[song.id] = song.artwork;
      }
      for (var s = 0; s < songs.length; s++) {
        if (!songs[s].artwork && byId[songs[s].id]) {
          songs[s].artwork = byId[songs[s].id];
        }
      }
      return songs;
    })
    .catch(function () {
      // 补封面失败不影响列表本身
      return songs;
    });
}

/* ---------------------------------------------------------------- 解析工具 */

/** 搜索结果里的歌曲列表（直连老接口用 artists/album，代理用 ar/al）。 */
function songsFromSearch(body) {
  var result = (body && body.result) || {};
  var songs = result.songs || result.data || [];
  return songsOf(songs);
}

/**
 * 歌单 / 榜单详情的第 [page] 页。
 *
 * 元数据（含完整 trackIds）决定歌曲顺序与总数；这里只切出当前页的 ID，
 * 再为这些 ID 批量补歌曲详情，响应大小与页数无关。
 */
function playlistPageOf(body, fallbackId, page) {
  var playlist = body.playlist || body.result || {};
  var total = totalOf(playlist.trackCount);
  var limit = SHEET_PAGE_SIZE;
  var currentPage = Number(page) > 0 ? Math.floor(Number(page)) : 1;
  var offset = (currentPage - 1) * limit;

  var tracks = songsOf(playlist.tracks || []).filter(function (song) {
    return String(song.name).trim();
  });
  var byId = Object.create(null);
  for (var j = 0; j < tracks.length; j++) {
    byId[tracks[j].id] = tracks[j];
  }

  var orderedIds = [];
  var seen = Object.create(null);
  var trackIds = playlist.trackIds || [];
  for (var i = 0; i < trackIds.length; i++) {
    var item = trackIds[i];
    var id = item && typeof item === 'object' ? item.id : item;
    if (id === undefined || id === null || String(id) === '') continue;
    id = String(id);
    if (seen[id]) continue;
    seen[id] = true;
    orderedIds.push(id);
  }
  // 老接口不带 trackIds，只能用响应里已经带的 tracks（顺序按接口给的）
  for (var k = 0; k < tracks.length; k++) {
    if (!seen[tracks[k].id]) {
      seen[tracks[k].id] = true;
      orderedIds.push(tracks[k].id);
    }
  }
  if (!trackIds.length && total !== null && tracks.length < total) {
    throw new Error('歌单详情不完整，缺少可补齐的 trackIds');
  }

  var pageIds = orderedIds.slice(offset, offset + limit);
  var missing = [];
  for (var m = 0; m < pageIds.length; m++) {
    if (!byId[pageIds[m]]) missing.push(pageIds[m]);
  }

  var cursor = 0;
  function fillNextBatch() {
    if (cursor >= missing.length) return Promise.resolve();
    var batch = missing.slice(cursor, cursor + 200);
    cursor += batch.length;
    // 成功响应中仍缺失的歌曲才视为不可用（下架 / 无版权）。
    return fetchSongDetails(batch).then(function (detail) {
      var songs = songsOf(detail.songs);
      for (var i = 0; i < songs.length; i++) {
        if (String(songs[i].name).trim()) byId[songs[i].id] = songs[i];
      }
      return fillNextBatch();
    });
  }

  // 有 trackIds 且比 trackCount 少（上游统计偏大）时，页数按实际可取的
  // trackIds 计算，否则会出现永远取不到数据的空尾页。
  var knownCount = total;
  if (trackIds.length && orderedIds.length < total) {
    knownCount = orderedIds.length;
  }

  return fillNextBatch().then(function () {
    var songs = [];
    for (var n = 0; n < pageIds.length; n++) {
      if (byId[pageIds[n]]) songs.push(byId[pageIds[n]]);
    }
    var creator = playlist.creator || {};
    return {
      id: String(playlist.id || fallbackId || ''),
      title: playlist.name || '',
      description: playlist.description || '',
      coverUrl: normalizeCover(playlist.coverImgUrl),
      author: creator.nickname ? String(creator.nickname) : '',
      songCount: total !== null ? total : orderedIds.length,
      // total 参与 App 的页数计算，用实际可取的歌曲数，避免上游偏大时出现空尾页
      total: knownCount,
      limit: limit,
      offset: offset,
      songs: songs,
      isEnd:
        knownCount !== null ? offset + limit >= knownCount : songs.length < limit
    };
  });
}

/** 歌单 / 榜单详情接口的统一出口（按页返回）。 */
function sheetDetailOf(id, page) {
  return fetchPlaylistMeta(id)
    .then(function (body) {
      return playlistPageOf(body, id, page);
    })
    .then(function (detail) {
      return JSON.stringify({
        isEnd: detail.isEnd,
        total: detail.total,
        limit: detail.limit,
        offset: detail.offset,
        sheet: {
          title: detail.title,
          coverUrl: detail.coverUrl,
          description: detail.description,
          author: detail.author,
          songCount: detail.songCount
        },
        songs: detail.songs
      });
    });
}

function textOf(block) {
  if (!block) return '';
  if (typeof block === 'string') return block;
  var value = block.lyric;
  return value ? String(value) : '';
}

/* ---------------------------------------------------------------- 插件接口 */

module.exports = {
  pluginInfo: {
    name: '数据源-网易',
    version: '1.5.0',
    author: 'MintMusic',
    description:
      '只提供搜索、歌单分类、榜单（含分类，已过滤品牌运营榜）、歌单 / 专辑 / 作者详情的网易云数据源；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记：导入时会归到「插件管理 → 数据源」分类
    // 站点图标：导入插件时下载并缓存到插件目录（音源列表 / 切换按钮用它）
    iconUrl: 'https://s1.music.126.net/style/favicon.ico',
    isDataSource: true
  },

  // 只声明搜索能力，不声明 musicUrl —— 数据源不解析播放地址
  sources: {
    wy: {
      name: '网易云音乐',
      qualitys: ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos'],
      actions: ['musicSearch']
    }
  },

  capabilities: {
    sheets: true,
    sheetDetail: true,
    topList: true,
    playlistSearch: true
  },

  // 数据源标记（部分宿主读取顶层字段，这里再写一份，保持兼容）
  isDataSource: true,

  /** 支持的搜索类型：歌曲 / 专辑 / 作者。 */
  supportedSearchTypes: function () {
    return ['music', 'album', 'artist'];
  },

  /* ------------------------------------------------------- 热门搜索（搜索页） */
  getHotSearchTags: function () {
    // 直连：热搜榜详情（eapi 的老接口，不需要签名）
    var url =
      HOST +
      '/api/search/chart/detail?id=' +
      encodeURIComponent('HOT_SEARCH_SONG#@#');
    return getJson(url)
      .then(function (body) {
        var items = (body.data && body.data.itemList) || [];
        return items
          .map(function (item) {
            return item && item.searchWord ? String(item.searchWord) : '';
          })
          .filter(function (word) {
            return word;
          })
          .slice(0, 10);
      })
      .catch(function () {
        // 兜底：代理的热搜接口
        return getJson(PROXIES[0] + '/search/hot')
          .then(function (body) {
            var hots = (body.result && body.result.hots) || [];
            return hots
              .map(function (item) {
                return item && item.first ? String(item.first) : '';
              })
              .filter(function (word) {
                return word;
              })
              .slice(0, 10);
          })
          .catch(function () {
            return [];
          });
      })
      .then(function (tags) {
        return JSON.stringify(tags);
      });
  },

  /* ------------------------------------------------------------ 搜索歌曲 */
  search: function (source, keyword, page, limit) {
    var size = limit || 30;
    var offset = (page || 1) > 1 ? size * ((page || 1) - 1) : 0;
    return fetchSearch(keyword, 1, size, offset).then(function (body) {
      var result = (body && body.result) || {};
      var songs = songsFromSearch(body);
      var total = totalOf(result.songCount);
      // 直连老接口兜底时响应里没有封面：用代理批量补一次
      return hydrateSearchCovers(songs).then(function (filled) {
        return JSON.stringify({
          list: filled,
          page: page || 1,
          total: total,
          limit: size,
          offset: offset,
          isEnd: isPageEnd(total, offset, songs.length, size, result)
        });
      });
    });
  },

  /* ------------------------------------------------------------ 搜索歌单 */
  searchPlaylists: function (keyword, page) {
    var size = 30;
    var offset = (page || 1) > 1 ? size * ((page || 1) - 1) : 0;
    return fetchSearch(keyword, 1000, size, offset).then(function (body) {
      var result = (body && body.result) || {};
      var playlists = playlistsOf(result.playlists || []);
      var total = totalOf(result.playlistCount);
      return JSON.stringify({
        total: total,
        limit: size,
        offset: offset,
        isEnd: isPageEnd(total, offset, playlists.length, size, result),
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------------- 搜索专辑 / 作者 */
  searchTyped: function (source, keyword, page, limit, type) {
    var size = limit || 30;
    var offset = (page || 1) > 1 ? size * ((page || 1) - 1) : 0;
    var isAlbum = type === 'album';
    var searchType = isAlbum ? 10 : 100;
    return fetchSearch(keyword, searchType, size, offset).then(function (body) {
      var result = (body && body.result) || {};
      var list = isAlbum ? result.albums || [] : result.artists || [];
      var total = totalOf(isAlbum ? result.albumCount : result.artistCount);
      // 部分专辑搜索接口忽略分页；仅确认返回全量时才按全局 offset 切片。
      if (isAlbum && list.length > size && list.length === total) {
        list = list.slice(offset, offset + size);
      }
      var items = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (item.id === undefined) continue;
        if (isAlbum) {
          var artist = item.artist || {};
          // 老接口里 item.artist 可能是空对象，真正的歌手在 item.artists 数组里
          var artistName = artist.name ? String(artist.name) : '';
          if (!artistName && item.artists && item.artists.length) {
            var names = [];
            for (var j = 0; j < item.artists.length; j++) {
              var artistName2 = item.artists[j] && item.artists[j].name;
              if (artistName2) names.push(String(artistName2));
            }
            artistName = names.join('、');
          }
          items.push({
            id: String(item.id),
            title: item.name || '',
            coverUrl: normalizeCover(item.picUrl),
            artist: artistName,
            worksNum: Number(item.size || 0),
            date: item.publishTime ? formatDate(item.publishTime) : '',
            description: item.description || '',
            // getAlbumInfo 需要原样带回的信息
            raw: { id: String(item.id), name: item.name || '' }
          });
        } else {
          items.push({
            id: String(item.id),
            title: item.name || '',
            coverUrl: normalizeCover(item.picUrl || item.img1v1Url),
            // musicSize 是歌曲数（详情页作者作品总数同口径）；
            // albumSize 是专辑数，老代码优先取它导致「133 首 / 1841 首」对不上
            worksNum: Number(item.musicSize || item.albumSize || 0),
            description: item.briefDesc || '',
            raw: { id: String(item.id), name: item.name || '' }
          });
        }
      }
      return JSON.stringify({
        list: items,
        total: total,
        limit: size,
        offset: offset,
        isEnd: isPageEnd(total, offset, items.length, size, result)
      });
    });
  },

  /* ------------------------------------------------------------- 专辑详情 */
  getAlbumInfo: function (source, albumItem, page) {
    var raw = (albumItem && albumItem.raw) || albumItem || {};
    var id = raw.id || (albumItem && albumItem.id) || '';
    return fetchAlbum(id).then(function (body) {
      var album = body.album || {};
      // 直连老接口把歌曲放在 album.songs 里，代理接口放在顶层 songs。
      var songs = songsOf(body.songs || album.songs || []);
      var artist = album.artist || {};
      var total = totalOf(album.size);
      if (total === null) total = songs.length;
      return JSON.stringify({
        isEnd: true,
        total: total,
        albumItem: {
          id: String(album.id || id),
          title: album.name || (albumItem && albumItem.title) || raw.name || '',
          coverUrl: normalizeCover(album.picUrl),
          artist: artist.name ? String(artist.name) : '',
          worksNum: total,
          date: album.publishTime ? formatDate(album.publishTime) : '',
          description: album.description || ''
        },
        musicList: songs
      });
    });
  },

  /* ------------------------------------------------------------- 作者作品 */
  getArtistWorks: function (source, artistItem, page, type) {
    var raw = (artistItem && artistItem.raw) || artistItem || {};
    var id = raw.id || (artistItem && artistItem.id) || '';
    var size = 50;
    var offset = (page || 1) > 1 ? size * ((page || 1) - 1) : 0;
    return fetchArtistSongs(id, size, offset).then(function (body) {
      var songs = songsOf(body.songs || []);
      var total = totalOf(body.total);
      return JSON.stringify({
        total: total,
        limit: size,
        offset: offset,
        isEnd: isPageEnd(total, offset, songs.length, size, body),
        artistItem: {
          id: String(id),
          title: (artistItem && artistItem.title) || raw.name || '',
          coverUrl: (artistItem && artistItem.coverUrl) || '',
          worksNum: total
        },
        musicList: songs
      });
    });
  },

  /* ------------------------------------------------- 歌单分类（更多分类面板） */
  getRecommendSheetTags: function () {
    return fetchCategories().then(function (body) {
      var categories = body.categories || {};
      var sub = body.sub || [];
      var groups = {};
      for (var i = 0; i < sub.length; i++) {
        var item = sub[i] || {};
        var key = String(item.category === undefined ? 0 : item.category);
        if (!groups[key]) groups[key] = [];
        var name = item.name ? String(item.name) : '';
        if (!name) continue;
        groups[key].push({ id: name, name: name });
      }
      var result = [];
      for (var categoryKey in categories) {
        if (!Object.prototype.hasOwnProperty.call(categories, categoryKey)) continue;
        var tags = groups[categoryKey] || [];
        if (!tags.length) continue;
        result.push({
          name: String(categories[categoryKey]),
          tags: tags
        });
      }
      return JSON.stringify(result);
    });
  },

  /* --------------------------------------------------- 分类歌单（歌单卡片） */
  getRecommendSheetsByTag: function (tagId, page) {
    var size = 30;
    var currentPage = page || 1;
    var offset = currentPage > 1 ? size * (currentPage - 1) : 0;
    var cat = tagId ? tagId : '全部';
    return fetchPlaylistList(cat, 'hot', size, offset).then(function (body) {
      var playlists = playlistsOf(body.playlists || []);
      var total = totalOf(body.total);
      return JSON.stringify({
        total: total,
        limit: size,
        offset: offset,
        isEnd: isPageEnd(total, offset, playlists.length, size, body),
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------------- 热门标签（顶部） */
  getHotPlaylistTags: function () {
    return fetchHotTags().then(function (body) {
      var tags = body.tags || [];
      var result = [];
      for (var i = 0; i < tags.length; i++) {
        var tag = tags[i] || {};
        var playlistTag = tag.playlistTag || tag;
        var name = playlistTag.name ? String(playlistTag.name) : '';
        if (!name) continue;
        result.push({ id: name, name: name });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------------- 榜单列表 */
  getTopLists: function () {
    return fetchTopList().then(function (body) {
      var list = body.list || [];
      var result = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (item.id === undefined) continue;
        // 品牌合作/运营榜不入列表（neteaseBoardGroup 返回 null）
        var group = neteaseBoardGroup(item);
        if (!group) continue;
        result.push({
          id: String(item.id),
          name: item.name || '',
          coverUrl: normalizeCover(item.coverImgUrl),
          playCount: formatPlayCount(item.playCount),
          updateFrequency: item.updateFrequency ? String(item.updateFrequency) : '',
          description: item.description || '',
          group: group
        });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------------- 榜单详情 */
  getTopListDetail: function (id, page) {
    return sheetDetailOf(id, page);
  },

  /* ------------------------------------------------------------- 歌单详情 */
  getMusicSheetInfo: function (sheetId, page) {
    // 兼容 `wy_xxx` / `wy:xxx` 形式的 id
    var raw = String(sheetId || '').replace(/^wy[_:]/, '');
    return sheetDetailOf(raw, page);
  },

  /* --------------------------------------------------------------- 歌词 */
  getLyric: function (source, musicInfo) {
    var id = musicInfo && (musicInfo.songmid || musicInfo.songId || musicInfo.id);
    if (!id) return Promise.resolve('');
    // 并行：普通 LRC（带翻译 / 音译） + 逐字 yrc（eapi 加密接口）
    return Promise.all([
      fetchLyric(id).catch(function () {
        return null;
      }),
      fetchYrcLyric(id)
    ]).then(function (results) {
      var body = results[0] || {};
      var yrc = results[1] || '';
      var lrc = textOf(body.lrc);
      var tlyric = textOf(body.tlyric);
      var romalrc = textOf(body.romalrc);
      if (!lrc && !yrc) return '';
      // yrc 放逐字通道（App 的解析器认网易云的 JSON yrc），lrc 仍作逐行兜底
      return JSON.stringify({
        lyric: lrc || yrc,
        lrc: lrc,
        tlyric: tlyric,
        romalrc: romalrc,
        yrc: yrc,
        crlyric: yrc
      });
    });
  },

  /* --------------------------------------------------------------- 封面 */
  getPic: function (source, musicInfo) {
    var id = musicInfo && (musicInfo.songmid || musicInfo.songId || musicInfo.id);
    if (!id) return Promise.resolve('');
    // 封面只在代理的 song/detail 响应里有，走代理优先的查询
    return fetchCoverDetails([id]).then(function (songs) {
      if (!songs.length) return '';
      return normalizeCover(albumOf(songs[0]).picUrl);
    });
  }
};

/** 毫秒时间戳 → yyyy-MM-dd（专辑发行日期）。 */
function formatDate(timestamp) {
  var value = Number(timestamp);
  if (!value || isNaN(value)) return '';
  var date = new Date(value);
  var month = date.getMonth() + 1;
  var day = date.getDate();
  return (
    date.getFullYear() +
    '-' +
    (month < 10 ? '0' + month : String(month)) +
    '-' +
    (day < 10 ? '0' + day : String(day))
  );
}
