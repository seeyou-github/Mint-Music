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
 *
 * 混淆过的插件依然会走 `module.exports` 赋值（只是写法被混淆），因此捕获器
 * 依然有效；一个对象都找不到时说明这根本不是 MusicFree 插件，直接报错，
 * 免得装出一个没有音源的空插件。
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
  if (!fallback) {
    throw new Error(
      '未找到 MusicFree 插件导出（module.exports）：该脚本可能不是 MusicFree 插件'
    );
  }
  return fallback;
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
  var pic = __mfNormalizeCover(
    item.artwork || item.picUrl || item.img || item.cover || item.artworkUrl
  );
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
      if (pic && /^https?:/i.test(pic)) return __mfNormalizeCover(pic);
      if (item._info) {
        pic = __mfText(item._info.img || item._info.picUrl || item._info.pic || '', '');
        if (pic && /^https?:/i.test(pic)) return __mfNormalizeCover(pic);
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
          return /^https?:/i.test(url) ? __mfNormalizeCover(url) : null;
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
 * 榜单 / 推荐歌单（发现页数据）
 *
 * MusicFree 的发现接口接收的是「条目对象」而不是 id：
 *   getTopListDetail(topListItem, page)
 *   getRecommendSheetsByTag(tagItem, page)
 *   getMusicSheetInfo(sheetItem, page)
 * 因此适配器把最近一次通过 getTopLists / getRecommendSheetTags /
 * getRecommendSheetsByTag 拿到的原始对象缓存在内存里，按 id 反查；缓存缺失
 * （例如 App 重启后用持久化的 id 打开）时退化为最小 `{ id }` 对象——示例插件
 * 都只依赖 id。
 * ------------------------------------------------------------------ */

var __mfTopListCache = null; // 扁平化榜单 [{id,name,group,coverUrl,description}]
var __mfTopListRawCache = null; // id -> 原始 topListItem
var __mfSheetTagGroupCache = null; // [{name,tags:[{id,name}]}]
var __mfSheetTagRawCache = null; // id -> 原始 tagItem
var __mfSheetRawCache = null; // id -> 原始 sheetItem（含分页续传字段）

function __mfFirstArray(values) {
  for (var i = 0; i < values.length; i++) {
    if (Array.isArray(values[i])) return values[i];
  }
  return [];
}

/**
 * 统一封面地址：
 * - 补全协议（`//host/...` → `https://host/...`，`http://` → `https://`）；
 * - 网易 CDN 的 `?param=NyN` 只是服务端缩略图（榜单页给的通常是 200x200），
 *   卡片按 2 倍图解码时会被放大到发糊，这里与内置音源保持一致换成 400x400。
 */
function __mfNormalizeCover(value) {
  var url = __mfText(value, '');
  if (!url) return '';
  if (url.indexOf('//') === 0) {
    url = 'https:' + url;
  } else if (/^http:\/\//i.test(url)) {
    url = 'https://' + url.substring(7);
  }
  if (url.indexOf('music.126.net') !== -1) {
    var queryIndex = url.indexOf('?');
    if (queryIndex !== -1) url = url.substring(0, queryIndex);
    url += '?param=400y400';
  }
  return url;
}

function __mfCoverOf(item) {
  if (!item || typeof item !== 'object') return '';
  return __mfNormalizeCover(
    item.coverImg || item.artwork || item.picUrl || item.img || item.cover
  );
}

function __mfIdOf(item) {
  if (!item || typeof item !== 'object') return '';
  var id = item.id;
  if (id === null || id === undefined) return '';
  return String(id);
}

/** 把 MusicFree 的分页结果（{isEnd, musicList}）展平成本项目可用的歌曲页。 */
function __mfNormalizeSongPage(response) {
  var list = [];
  if (Array.isArray(response)) {
    list = response;
  } else if (response && typeof response === 'object') {
    list = __mfFirstArray([
      response.musicList,
      response.data,
      response.list,
    ]);
  }

  var sourceId = __mfSourceId();
  var songs = [];
  for (var i = 0; i < list.length; i++) {
    var mapped = __mfMapMusicItem(list[i], sourceId);
    if (mapped) songs.push(mapped);
  }

  var isEnd = true;
  if (response && typeof response === 'object' && response.isEnd === false) {
    isEnd = false;
  }
  return { isEnd: isEnd, songs: songs };
}

/** 榜单 / 歌单条目的元信息，供宿主渲染详情页头部。 */
function __mfSheetMeta(item) {
  if (!item || typeof item !== 'object') return null;
  return {
    id: __mfIdOf(item),
    title: __mfText(item.title || item.name, ''),
    coverUrl: __mfCoverOf(item),
    description: __mfText(item.description, ''),
    author: __mfText(
      item.artist || item.author || item.creator || item.nickName || item.nickname,
      ''
    ),
  };
}

function __mfLoadTopLists() {
  if (__mfTopListCache) return Promise.resolve(__mfTopListCache);

  var plugin = __mfPluginObject();
  if (typeof plugin.getTopLists !== 'function') return Promise.resolve([]);

  return Promise.resolve(plugin.getTopLists())
    .then(function (response) {
      var groups = [];
      if (Array.isArray(response)) groups = response;
      else if (response && typeof response === 'object') {
        groups = __mfFirstArray([response.data, response.list]);
      }

      var flat = [];
      var raw = {};
      for (var i = 0; i < groups.length; i++) {
        var group = groups[i] || {};
        var groupTitle = __mfText(group.title || group.name, '');
        var items = Array.isArray(group.data)
          ? group.data
          : __mfFirstArray([group.list]);
        for (var j = 0; j < items.length; j++) {
          var item = items[j];
          if (!item || typeof item !== 'object') continue;
          var id = __mfIdOf(item);
          if (!id || raw[id]) continue;
          raw[id] = item;
          flat.push({
            id: id,
            name: __mfText(item.title || item.name, id),
            group: groupTitle,
            coverUrl: __mfCoverOf(item),
            description: __mfText(item.description, ''),
          });
        }
      }

      if (flat.length) {
        __mfTopListRawCache = raw;
        __mfTopListCache = flat;
      }
      return flat;
    })
    .then(null, function (error) {
      if (typeof console !== 'undefined' && console.log) {
        console.log(
          '[MusicFree] getTopLists 失败: ' +
            (error && error.message ? error.message : error)
        );
      }
      return [];
    });
}

function __mfLoadSheetTags() {
  if (__mfSheetTagGroupCache) return Promise.resolve(__mfSheetTagGroupCache);

  var plugin = __mfPluginObject();
  if (typeof plugin.getRecommendSheetTags !== 'function') {
    return Promise.resolve([]);
  }

  return Promise.resolve(plugin.getRecommendSheetTags())
    .then(function (response) {
      var pinned = [];
      var groups = [];
      if (Array.isArray(response)) {
        groups = response;
      } else if (response && typeof response === 'object') {
        pinned = __mfFirstArray([response.pinned]);
        groups = __mfFirstArray([response.data, response.list]);
      }

      var raw = {};
      function convertTags(list) {
        var tags = [];
        for (var i = 0; i < list.length; i++) {
          var tag = list[i];
          if (!tag || typeof tag !== 'object') continue;
          var id = __mfIdOf(tag);
          if (!id) continue;
          if (!raw[id]) raw[id] = tag;
          tags.push({ id: id, name: __mfText(tag.title || tag.name, id) });
        }
        return tags;
      }

      var result = [];
      var pinnedTags = convertTags(pinned);
      if (pinnedTags.length) result.push({ name: '推荐', tags: pinnedTags });
      for (var i = 0; i < groups.length; i++) {
        var group = groups[i] || {};
        var tags = convertTags(
          Array.isArray(group.data) ? group.data : __mfFirstArray([group.list])
        );
        if (!tags.length) continue;
        result.push({ name: __mfText(group.title || group.name, '分类'), tags: tags });
      }

      if (result.length) {
        __mfSheetTagRawCache = raw;
        __mfSheetTagGroupCache = result;
      }
      return result;
    })
    .then(null, function (error) {
      if (typeof console !== 'undefined' && console.log) {
        console.log(
          '[MusicFree] getRecommendSheetTags 失败: ' +
            (error && error.message ? error.message : error)
        );
      }
      return [];
    });
}

function __mfTopListDetail(id, page) {
  var key = id === null || id === undefined ? '' : String(id);
  return __mfLoadTopLists().then(function () {
    var plugin = __mfPluginObject();
    if (typeof plugin.getTopListDetail !== 'function') {
      return { isEnd: true, songs: [] };
    }
    var item = (__mfTopListRawCache && __mfTopListRawCache[key]) || {
      id: key,
      title: '',
    };
    var pageNumber = typeof page === 'number' && page > 0 ? page : 1;
    return Promise.resolve(plugin.getTopListDetail(item, pageNumber))
      .then(function (response) {
        var result = __mfNormalizeSongPage(response);
        // 与歌单详情一样，把插件回传的续页状态合并回缓存的原始条目。
        if (response && typeof response === 'object') {
          var merged = {};
          Object.keys(item).forEach(function (k) {
            merged[k] = item[k];
          });
          Object.keys(response).forEach(function (k) {
            if (k === 'musicList' || k === 'isEnd') return;
            merged[k] = response[k];
          });
          if (!__mfTopListRawCache) __mfTopListRawCache = {};
          __mfTopListRawCache[key] = merged;
          result.sheet = __mfSheetMeta(merged);
        } else {
          result.sheet = __mfSheetMeta(item);
        }
        return result;
      })
      .then(null, function (error) {
        if (typeof console !== 'undefined' && console.log) {
          console.log(
            '[MusicFree] getTopListDetail 失败: ' +
              (error && error.message ? error.message : error)
          );
        }
        return { isEnd: true, songs: [] };
      });
  });
}

function __mfRecommendSheetsByTag(tagId, page) {
  var key = tagId === null || tagId === undefined ? '' : String(tagId);
  var plugin = __mfPluginObject();
  if (typeof plugin.getRecommendSheetsByTag !== 'function') {
    return Promise.resolve({ isEnd: true, playlists: [] });
  }

  return __mfLoadSheetTags().then(function () {
    var tag = (__mfSheetTagRawCache && __mfSheetTagRawCache[key]) || {
      id: key,
      title: key,
    };
    var pageNumber = typeof page === 'number' && page > 0 ? page : 1;
    return Promise.resolve(plugin.getRecommendSheetsByTag(tag, pageNumber))
      .then(function (response) {
        var list = [];
        if (Array.isArray(response)) list = response;
        else if (response && typeof response === 'object') {
          list = __mfFirstArray([response.data, response.list]);
        }

        var playlists = [];
        for (var i = 0; i < list.length; i++) {
          var sheet = list[i];
          if (!sheet || typeof sheet !== 'object') continue;
          var id = __mfIdOf(sheet);
          if (!id) continue;
          if (!__mfSheetRawCache) __mfSheetRawCache = {};
          if (!__mfSheetRawCache[id]) __mfSheetRawCache[id] = sheet;
          playlists.push({
            id: id,
            title: __mfText(sheet.title || sheet.name, id),
            coverUrl: __mfCoverOf(sheet),
            description: __mfText(sheet.description, ''),
            playCount: __mfText(sheet.playCount, ''),
            author: __mfText(
              sheet.artist ||
                sheet.author ||
                sheet.creator ||
                sheet.nickName ||
                sheet.nickname,
              ''
            ),
            songCount:
              typeof sheet.musicList === 'object' && sheet.musicList
                ? __mfFirstArray([sheet.musicList]).length
                : 0,
          });
        }

        var isEnd = true;
        if (response && typeof response === 'object' && response.isEnd === false) {
          isEnd = false;
        }
        return { isEnd: isEnd, playlists: playlists };
      })
      .then(null, function (error) {
        if (typeof console !== 'undefined' && console.log) {
          console.log(
            '[MusicFree] getRecommendSheetsByTag 失败: ' +
              (error && error.message ? error.message : error)
          );
        }
        return { isEnd: true, playlists: [] };
      });
  });
}

function __mfMusicSheetInfo(sheetId, page) {
  var key = sheetId === null || sheetId === undefined ? '' : String(sheetId);
  var plugin = __mfPluginObject();
  if (typeof plugin.getMusicSheetInfo !== 'function') {
    return Promise.resolve({ isEnd: true, songs: [] });
  }

  return Promise.resolve().then(function () {
    var sheet = (__mfSheetRawCache && __mfSheetRawCache[key]) || {
      id: key,
      title: '',
    };
    var pageNumber = typeof page === 'number' && page > 0 ? page : 1;
    return Promise.resolve(plugin.getMusicSheetInfo(sheet, pageNumber))
      .then(function (response) {
        var result = __mfNormalizeSongPage(response);
        // 部分插件（如网易）在第一页回传 `_trackIds` 之类的续页状态，需要
        // 合并回缓存的 sheetItem，否则第二页会重新拉整张歌单。
        if (response && typeof response === 'object') {
          var merged = {};
          Object.keys(sheet).forEach(function (k) {
            merged[k] = sheet[k];
          });
          Object.keys(response).forEach(function (k) {
            if (k === 'musicList' || k === 'isEnd') return;
            merged[k] = response[k];
          });
          if (!__mfSheetRawCache) __mfSheetRawCache = {};
          __mfSheetRawCache[key] = merged;
          result.sheet = __mfSheetMeta(merged);
        } else {
          result.sheet = __mfSheetMeta(sheet);
        }
        return result;
      })
      .then(null, function (error) {
        if (typeof console !== 'undefined' && console.log) {
          console.log(
            '[MusicFree] getMusicSheetInfo 失败: ' +
              (error && error.message ? error.message : error)
          );
        }
        return { isEnd: true, songs: [] };
      });
  });
}

/** 插件实现了哪些「发现页」能力（宿主据此决定音源是否出现在发现页）。 */
function __mfCapabilities() {
  var plugin = __mfPluginObject();
  return {
    topList:
      typeof plugin.getTopLists === 'function' &&
      typeof plugin.getTopListDetail === 'function',
    sheets:
      typeof plugin.getRecommendSheetTags === 'function' &&
      typeof plugin.getRecommendSheetsByTag === 'function',
    sheetDetail: typeof plugin.getMusicSheetInfo === 'function',
  };
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

/* 发现页（榜单 / 推荐歌单）。插件未实现时返回空结果，宿主不会把这些音源列进
 * 发现页音源选择器（见 `capabilities`）。 */
__mfContract.getTopLists = function () {
  return __mfLoadTopLists();
};
__mfContract.getTopListDetail = __mfTopListDetail;
__mfContract.getRecommendSheetTags = function () {
  return __mfLoadSheetTags();
};
__mfContract.getRecommendSheetsByTag = __mfRecommendSheetsByTag;
__mfContract.getMusicSheetInfo = __mfMusicSheetInfo;

Object.defineProperty(__mfContract, 'capabilities', {
  enumerable: true,
  configurable: true,
  get: function () {
    return __mfCapabilities();
  },
});
