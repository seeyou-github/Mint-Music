/* ==========================================================================
 * Mint-Music: MusicFree 格式适配器
 *
 * MusicFree 插件是一个 CommonJS 模块，形如：
 *
 *   module.exports = {
 *     platform: 'xxx', version: '1.0.0', author: '...', srcUrl: '...',
 *     cacheControl: 'no-cache',
 *     supportedSearchType: ['music', 'album', 'sheet', 'artist'],
 *     search(keyword, page, type)            -> { isEnd, data: [...] }
 *     getMediaSource(musicItem, quality)     -> { url, headers? }
 *     getLyric(musicItem)                    -> { rawLrc, translation? }
 *     getAlbumInfo / getArtistWorks / getTopLists / ...
 *   }
 *
 * 本文件把上述协议适配成本项目的插件契约：
 *   module.exports = { pluginInfo, sources, sourceActions, search, musicUrl, getPic, getLyric }
 *
 * 执行顺序（由 PluginHost 控制）：
 *   1. 先执行本适配器：安装 module.exports 捕获器、声明契约、暴露 require；
 *   2. 再执行原始 MusicFree 插件脚本：它调用 require('axios') 等依赖并最终
 *      `module.exports = {...}`，写入被捕获器截获，插件本体不会覆盖本契约；
 *   3. PluginHost 读取 module.exports（即本契约），pluginInfo / sources 通过
 *      getter 在插件本体执行完成后再惰性求值。
 * ========================================================================== */

var __mintMusicFreeAdapter = true;

var __mfContract = {};
var __mfLegacyExports = {};
var __mfCapturedExports = null;
var __mfInfoCache = null;
var __mfSourcesCache = null;
var __mfActionsCache = null;
var __mfSourceIdCache = null;

/* 本适配器支持的音质标签（与内置源保持一致，便于复用音质回退逻辑）。 */
var __mfQualityLabels = ['128k', '320k', 'flac'];

/* ------------------------------------------------------------------ *
 * 捕获原始插件导出
 *
 * MusicFree 插件执行 `module.exports = {...}`。这里把 module.exports 改造成
 * 访问器：读取时返回本适配器的契约，写入时截获插件本体。这样 PluginHost
 * 解析到的始终是契约，同时插件本体在适配器内部可见。
 * ------------------------------------------------------------------ */

Object.defineProperty(module, 'exports', {
  configurable: true,
  get: function () {
    return __mfContract;
  },
  set: function (value) {
    if (value && value !== __mfContract) __mfCapturedExports = value;
  },
});

/* `exports.foo = ...` 风格的插件：宿主在适配器之前已缓存旧对象，这里替换掉。 */
exports = __mfLegacyExports;

/* 必需的模块依赖（axios / cheerio / crypto-js ...）由运行时提供。 */
if (typeof __mfExposeRequire === 'function') {
  __mfExposeRequire();
}

/* ------------------------------------------------------------------ *
 * 工具函数
 * ------------------------------------------------------------------ */

function __mfLooksLikePlugin(value) {
  return (
    !!value &&
    typeof value === 'object' &&
    (value.platform ||
      typeof value.search === 'function' ||
      typeof value.getMediaSource === 'function' ||
      typeof value.getLyric === 'function' ||
      value.supportedSearchType)
  );
}

/**
 * 找到原始 MusicFree 插件导出的对象。
 *
 * 依次考察：
 *   1. `module.exports = {...}` 被捕获器截获的对象；
 *   2. `exports.foo = ...` 风格写入的对象；
 *   3. `module.exports.default = {...}`（ESM 互操作写法）写入契约的 default。
 * 每种情况都额外识别一层 `{ default: {...} }` 包装。
 */
function __mfPluginObject() {
  var candidates = [__mfCapturedExports, __mfLegacyExports, __mfContract.default];
  var fallback = null;
  for (var i = 0; i < candidates.length; i++) {
    var candidate = candidates[i];
    if (!candidate || typeof candidate !== 'object') continue;
    if (
      candidate.default &&
      candidate.default !== candidate &&
      __mfLooksLikePlugin(candidate.default)
    ) {
      return candidate.default;
    }
    if (!fallback && __mfLooksLikePlugin(candidate)) fallback = candidate;
  }
  return fallback || {};
}

function __mfText(value, fallback) {
  if (value === null || value === undefined) return fallback;
  var text;
  if (Array.isArray(value)) {
    text = value.join(', ');
  } else if (typeof value === 'object') {
    try {
      text = JSON.stringify(value);
    } catch (e) {
      text = '';
    }
  } else {
    text = String(value);
  }
  text = text.replace(/\s+/g, ' ').trim();
  return text.length ? text : fallback;
}

function __mfLimitText(text, max) {
  if (!text || text.length <= max) return text;
  return text.substring(0, max - 1) + '…';
}

function __mfArray(value) {
  if (Array.isArray(value)) return value;
  if (typeof value === 'string' && value.trim()) {
    return value
      .split(',')
      .map(function (item) {
        return item.trim();
      })
      .filter(function (item) {
        return item.length > 0;
      });
  }
  return [];
}

/**
 * 平台名 -> 音源 id。
 * 规则必须与 Dart 侧 SourceIdMapping 保持一致，否则搜索源选择器会拿不到结果。
 */
function __mfSourceIdFromName(name) {
  var raw = __mfText(name, 'MusicFree');
  var lower = raw.toLowerCase();
  var known = null;
  if (lower.indexOf('\u7f51\u6613') >= 0 || lower.indexOf('netease') >= 0 || lower.indexOf('163') >= 0) {
    known = 'wy';
  } else if (lower.indexOf('\u9177\u72d7') >= 0 || lower.indexOf('kugou') >= 0) {
    known = 'kg';
  } else if (lower.indexOf('\u9177\u6211') >= 0 || lower.indexOf('kuwo') >= 0) {
    known = 'kw';
  } else if (lower.indexOf('qq') >= 0) {
    known = 'tx';
  } else if (lower.indexOf('\u54aa\u5495') >= 0 || lower.indexOf('migu') >= 0) {
    known = 'mg';
  } else if (lower.indexOf('\u6c7d\u6c34') >= 0 || lower.indexOf('qsvip') >= 0) {
    known = 'qsvip';
  }
  if (known) return known;
  var ascii = lower.replace(/[^a-z0-9]/g, '');
  return ascii.length ? ascii : raw;
}

function __mfSourceId() {
  if (!__mfSourceIdCache) {
    __mfSourceIdCache = __mfSourceIdFromName(__mfPluginMeta().name);
  }
  return __mfSourceIdCache;
}

function __mfPluginMeta() {
  if (__mfInfoCache) return __mfInfoCache;
  var plugin = __mfPluginObject();
  __mfInfoCache = {
    name: __mfText(plugin.platform, 'MusicFree 音源'),
    version: __mfText(plugin.version, '1.0.0'),
    author: __mfText(plugin.author, '未知作者'),
    description: __mfLimitText(__mfText(plugin.description, ''), 200),
    homepage: __mfText(plugin.srcUrl, ''),
  };
  return __mfInfoCache;
}

function __mfSupportsMusicSearch(plugin) {
  if (typeof plugin.search !== 'function') return false;
  var supported = __mfArray(plugin.supportedSearchType);
  if (!supported.length) return true;
  for (var i = 0; i < supported.length; i++) {
    if (String(supported[i]).toLowerCase() === 'music') return true;
  }
  return false;
}

function __mfActionList() {
  var plugin = __mfPluginObject();
  var actions = [];
  if (typeof plugin.getMediaSource === 'function') actions.push('musicUrl');
  else actions.push('musicUrl');
  if (__mfSupportsMusicSearch(plugin)) actions.push('musicSearch');
  actions.push('musicPic');
  if (typeof plugin.getLyric === 'function') actions.push('lyric');
  return actions;
}

function __mfSourcesObject() {
  if (!__mfSourcesCache) {
    var meta = __mfPluginMeta();
    __mfSourcesCache = {};
    __mfSourcesCache[__mfSourceId()] = {
      name: meta.name,
      type: 'music',
      qualitys: __mfQualityLabels.slice(),
      qualities: __mfQualityLabels.slice(),
      actions: __mfActionList(),
    };
  }
  return __mfSourcesCache;
}

function __mfSourceActionsObject() {
  if (!__mfActionsCache) {
    var plugin = __mfPluginObject();
    __mfActionsCache = {};
    __mfActionsCache[__mfSourceId()] = __mfActionList().map(function (action) {
      return String(action).toLowerCase();
    });
  }
  return __mfActionsCache;
}

/* ------------------------------------------------------------------ *
 * musicItem 适配
 * ------------------------------------------------------------------ */

/** 把本项目的 musicInfo 还原成插件需要的 MusicFree musicItem。 */
function __mfUnwrapItem(musicInfo) {
  var info = musicInfo && typeof musicInfo === 'object' ? musicInfo : {};
  var extra = info.extra;
  if (extra && typeof extra === 'object' && extra.musicItem && typeof extra.musicItem === 'object') {
    return extra.musicItem;
  }
  // 回退：用本项目字段拼一个最小可用的 musicItem（例如内置源搜索到的歌曲
  // 交给 MusicFree 插件解析播放地址）。
  var id = info.songmid || info.songId || info.songid || info.id || '';
  return {
    id: id,
    platform: __mfPluginMeta().name,
    title: __mfText(info.name || info.title, ''),
    artist: __mfText(info.singer || info.artist, ''),
    album: __mfText(info.albumName || info.album, ''),
    artwork: __mfText(info.img || info.picUrl || info.pic || info.cover, ''),
    duration: typeof info.duration === 'number' ? info.duration : 0,
    _info: info,
  };
}

/** 把 MusicFree musicItem 展平成本项目 _musicInfoToSong 可识别的字段。 */
function __mfMapMusicItem(item, sourceId) {
  if (!item || typeof item !== 'object') return null;

  var title = __mfText(item.title || item.name || item.songname, '');
  if (!title) return null;

  var artist = __mfText(item.artist || item.singer || item.artists, '');
  var pic = __mfText(item.artwork || item.picUrl || item.img || item.cover || item.artworkUrl, '');
  var album = item.album;
  if (album && typeof album === 'object') album = album.name;
  album = __mfText(album || item.albumName, '');

  var duration = item.duration;
  if (typeof duration === 'string') {
    var parsed = parseFloat(duration);
    duration = isNaN(parsed) ? 0 : parsed;
  }
  if (typeof duration !== 'number' || !isFinite(duration) || duration < 0) duration = 0;

  var id = item.id === null || item.id === undefined ? '' : String(item.id);

  return {
    id: item.id,
    songmid: id,
    songId: item.id,
    songid: item.id,
    hash: id,
    name: title,
    title: title,
    singer: artist,
    artist: artist,
    albumName: album,
    album: album,
    duration: duration,
    interval: duration,
    img: pic,
    picUrl: pic,
    artwork: pic,
    source: sourceId,
    // 原始 musicItem：解析播放地址 / 歌词时原样回传给插件，避免二次请求。
    extra: { musicItem: item },
  };
}

/* ------------------------------------------------------------------ *
 * 契约实现
 * ------------------------------------------------------------------ */

function __mfSearch(source, keyword, page, limit) {
  return Promise.resolve()
    .then(function () {
      var plugin = __mfPluginObject();
      if (!__mfSupportsMusicSearch(plugin)) {
        return { list: [], total: 0, isEnd: true, source: source };
      }
      var keywordText = __mfText(keyword, '');
      var pageNumber = typeof page === 'number' && page > 0 ? page : 1;
      var result = plugin.search(keywordText, pageNumber, 'music');
      return Promise.resolve(result).then(function (response) {
        var rawList = [];
        if (Array.isArray(response)) rawList = response;
        else if (response && Array.isArray(response.data)) rawList = response.data;
        else if (response && Array.isArray(response.list)) rawList = response.list;

        var sourceId = __mfSourceId();
        var list = [];
        for (var i = 0; i < rawList.length; i++) {
          var mapped = __mfMapMusicItem(rawList[i], sourceId);
          if (mapped) list.push(mapped);
        }

        var isEnd = true;
        if (response && typeof response === 'object' && response.isEnd === false) {
          isEnd = false;
        } else if (typeof limit === 'number' && limit > 0 && list.length >= limit) {
          isEnd = false;
        }
        return { list: list, total: list.length, isEnd: isEnd, source: source };
      });
    })
    .then(
      function (value) {
        return value;
      },
      function (error) {
        if (typeof console !== 'undefined' && console.log) {
          console.log('[MusicFree] search 失败: ' + (error && error.message ? error.message : error));
        }
        return { list: [], total: 0, isEnd: true, source: source };
      }
    );
}

function __mfMusicUrl(source, musicInfo, quality) {
  return Promise.resolve()
    .then(function () {
      var plugin = __mfPluginObject();
      var item = __mfUnwrapItem(musicInfo);

      if (typeof plugin.getMediaSource !== 'function') {
        return __mfDirectUrl(item, quality);
      }

      // 按「请求音质 → standard → high → low → super」的顺序尝试：
      // 有些插件只实现了部分音质（例如「网易128k」仅支持 standard），
      // 直接失败会让用户完全无法播放，这里退化为它能提供的音质。
      var requested = __mfQualityKey(quality);
      var candidates = [requested];
      ['standard', 'high', 'low', 'super'].forEach(function (key) {
        if (candidates.indexOf(key) < 0) candidates.push(key);
      });

      var index = 0;
      function attempt() {
        if (index >= candidates.length) return __mfDirectUrl(item, quality);
        var key = candidates[index++];
        return Promise.resolve(plugin.getMediaSource(item, key)).then(
          function (response) {
            var parsed = __mfParseMediaSource(response, key);
            if (parsed) return parsed;
            return attempt();
          },
          function (error) {
            if (typeof console !== 'undefined' && console.log) {
              console.log(
                '[MusicFree] getMediaSource(' +
                  key +
                  ') 失败: ' +
                  (error && error.message ? error.message : error)
              );
            }
            return attempt();
          }
        );
      }

      return attempt();
    })
    .then(
      function (value) {
        return value;
      },
      function (error) {
        if (typeof console !== 'undefined' && console.log) {
          console.log('[MusicFree] getMediaSource 失败: ' + (error && error.message ? error.message : error));
        }
        return null;
      }
    );
}

/** 归一化 getMediaSource 的返回值。返回 null 表示没有可用地址。 */
function __mfParseMediaSource(response, qualityKey) {
  if (!response) return null;
  var url = '';
  var headers = null;
  var userAgent = '';
  if (typeof response === 'string') {
    url = response;
  } else if (typeof response === 'object') {
    url = response.url || (response.data && response.data.url) || '';
    headers = response.headers || (response.data && response.data.headers) || null;
    userAgent = response.userAgent || '';
  }
  url = __mfText(url, '');
  if (!/^https?:/i.test(url)) return null;

  var resultHeaders = {};
  if (headers && typeof headers === 'object') {
    Object.keys(headers).forEach(function (key) {
      if (headers[key] !== null && headers[key] !== undefined) {
        resultHeaders[key] = String(headers[key]);
      }
    });
  }
  if (userAgent) {
    var hasUa = false;
    Object.keys(resultHeaders).forEach(function (key) {
      if (key.toLowerCase() === 'user-agent') hasUa = true;
    });
    if (!hasUa) resultHeaders['User-Agent'] = userAgent;
  }
  return {
    url: url,
    headers: resultHeaders,
    quality: __mfQualityLabel(qualityKey),
  };
}

/** MusicFree 音质键 → 本项目音质标签。 */
function __mfQualityLabel(qualityKey) {
  if (qualityKey === 'super') return 'flac';
  if (qualityKey === 'high') return '320k';
  return '128k';
}

function __mfDirectUrl(item, quality) {
  var direct = '';
  if (item && item.url) direct = String(item.url);
  if (!direct && item && item.qualities && typeof item.qualities === 'object') {
    var entry = item.qualities[quality] || item.qualities[__mfQualityKey(quality)];
    if (typeof entry === 'string') direct = entry;
    else if (entry && typeof entry === 'object' && entry.url) direct = String(entry.url);
  }
  if (direct && /^https?:/i.test(direct)) {
    return { url: direct, headers: {}, quality: quality };
  }
  return null;
}

function __mfGetPic(source, musicInfo) {
  return Promise.resolve()
    .then(function () {
      var plugin = __mfPluginObject();
      var item = __mfUnwrapItem(musicInfo);
      var pic = __mfText(item.artwork || item.picUrl || item.img || item.cover, '');
      if (pic && /^https?:/i.test(pic)) return pic;
      if (item._info) {
        pic = __mfText(item._info.img || item._info.picUrl || item._info.pic || '', '');
        if (pic && /^https?:/i.test(pic)) return pic;
      }
      // 搜索结果里没有封面时（部分插件只在 getPic 里取封面）再调用插件方法。
      if (typeof plugin.getPic !== 'function') return null;
      return Promise.resolve(plugin.getPic(item, 'standard')).then(
        function (response) {
          var url = '';
          if (typeof response === 'string') {
            url = response;
          } else if (response && typeof response === 'object') {
            url =
              response.url ||
              response.pic ||
              response.artwork ||
              response.img ||
              '';
          }
          url = __mfText(url, '');
          return /^https?:/i.test(url) ? url : null;
        },
        function () {
          return null;
        }
      );
    })
    .then(null, function () {
      return null;
    });
}

function __mfGetLyric(source, musicInfo) {
  return Promise.resolve()
    .then(function () {
      var plugin = __mfPluginObject();
      if (typeof plugin.getLyric !== 'function') return null;
      var item = __mfUnwrapItem(musicInfo);
      return Promise.resolve(plugin.getLyric(item)).then(function (response) {
        if (!response) return null;
        if (typeof response === 'string') {
          var text = response.trim();
          return text ? { lrc: text } : null;
        }
        if (typeof response !== 'object') return null;
        var lrc = __mfText(response.rawLrc || response.lrc || response.lyric || response.raw || '', '');
        var translation = __mfText(response.translation || response.tlyric || response.trans || '', '');
        if (!lrc && !translation) return null;
        return { lrc: lrc, tlyric: translation };
      });
    })
    .then(null, function (error) {
      if (typeof console !== 'undefined' && console.log) {
        console.log('[MusicFree] getLyric 失败: ' + (error && error.message ? error.message : error));
      }
      return null;
    });
}

/** 本项目音质标签 -> MusicFree 音质键（low / standard / high / super）。 */
function __mfQualityKey(quality) {
  var value = String(quality === null || quality === undefined ? '' : quality).toLowerCase();
  if (value === 'low' || value === '64k') return 'low';
  if (value === 'standard' || value === '128k' || value === '192k') return 'standard';
  if (value === 'high' || value === '320k' || value === 'hq') return 'high';
  if (
    value === 'super' ||
    value === 'flac' ||
    value === 'flac24bit' ||
    value === 'hires' ||
    value === 'atmos' ||
    value === 'master' ||
    value === 'lossless'
  ) {
    return 'super';
  }
  return 'standard';
}

/* ------------------------------------------------------------------ *
 * 契约导出
 * ------------------------------------------------------------------ */

Object.defineProperty(__mfContract, 'pluginInfo', {
  enumerable: true,
  configurable: true,
  get: function () {
    return __mfPluginMeta();
  },
});

Object.defineProperty(__mfContract, 'sources', {
  enumerable: true,
  configurable: true,
  get: function () {
    return __mfSourcesObject();
  },
});

Object.defineProperty(__mfContract, 'sourceActions', {
  enumerable: true,
  configurable: true,
  get: function () {
    return __mfSourceActionsObject();
  },
});

__mfContract.search = __mfSearch;
__mfContract.musicUrl = __mfMusicUrl;
__mfContract.getPic = __mfGetPic;
__mfContract.getLyric = __mfGetLyric;
__mfContract.getLyricResult = __mfGetLyric;
