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
    // 带上专辑 id：封面补全失败时 getPic 还能按专辑再查一次
    albumId: item.album_id ? String(item.album_id) : '',
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

/** 歌单详情（整张歌单）：members 里带 album_img，歌曲封面从这里来。 */
/**
 * 歌单歌曲接口（special/song）不返回专辑信息，封面 / 歌名 / 歌手都得另外补。
 * 用内置源同款的 album_audio 接口批量查（一次 100 首）。
 *
 * 注：以前试过 m.kugou.com/plist/list（members 里带 album_img），但该地址现在
 * 直接 301 到 HTML 页面，拿不到 JSON，所以统一走 album_audio 补全。
 */
function fetchAlbumAudio(hashes) {
  return cerumusic
    .request('http://gateway.kugou.com/v2/album_audio/audio', {
      method: 'POST',
      headers: {
        'User-Agent':
          'Android712-AndroidPhone-11451-376-0-FeeCacheUpdate-wifi',
        'KG-THash': '13a3164',
        'KG-RC': '1',
        'KG-Fake': '0',
        'KG-RF': '00869891',
        'x-router': 'kmr.service.kugou.com',
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({
        area_code: '1',
        show_privilege: 1,
        show_album_info: '1',
        is_publish: '',
        appid: 1005,
        clientver: 11451,
        mid: '1',
        dfid: '-',
        clienttime: Date.now(),
        key: 'OIlwieks28dk2k092lksi2UIkp',
        fields: 'album_info,author_name,audio_info,ori_audio_name,base,songname',
        data: hashes.map(function (hash) {
          return { hash: hash };
        })
      }),
      timeout: 20000
    })
    .then(decodeBody)
    .then(function (body) {
      return body.data || [];
    });
}

/** 给缺封面 / 歌名 / 歌手的歌曲补全信息（按 hash 匹配，一次 100 首）。 */
function hydrateSongs(songs) {
  var missing = [];
  for (var i = 0; i < songs.length; i++) {
    if (!songs[i].artwork || !songs[i].name || !songs[i].singer) {
      missing.push(songs[i].id);
    }
  }
  if (!missing.length) return Promise.resolve(songs);

  var chunks = [];
  for (var start = 0; start < missing.length; start += 100) {
    chunks.push(missing.slice(start, start + 100));
  }

  var index = 0;
  function nextChunk() {
    if (index >= chunks.length) return Promise.resolve(songs);
    var chunk = chunks[index++];
    return fetchAlbumAudio(chunk)
      .then(function (rows) {
        var byHash = {};
        for (var r = 0; r < rows.length; r++) {
          var row = rows[r];
          if (Array.isArray(row)) row = row[0];
          if (!row || !row.audio_info) continue;
          var hash = row.audio_info.hash;
          if (hash) byHash[String(hash).toUpperCase()] = row;
        }
        for (var s = 0; s < songs.length; s++) {
          var info = byHash[String(songs[s].id).toUpperCase()];
          if (!info) continue;
          if (!songs[s].artwork) {
            songs[s].artwork = normalizeImage(
              info.album_info && info.album_info.sizable_cover,
              '800'
            );
          }
          if (!songs[s].name && info.songname) {
            songs[s].name = decodeName(info.songname);
          }
          if (!songs[s].singer && info.author_name) {
            songs[s].singer = decodeName(info.author_name);
          }
        }
      })
      .catch(function () {
        /* 补全失败不影响歌曲列表本身 */
      })
      .then(nextChunk);
  }
  return nextChunk();
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
    name: '数据源-酷狗',
    version: '1.2.0',
    author: 'MintMusic',
    description:
      '只提供搜索、歌单分类、榜单、歌单详情的酷狗音乐数据源；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记
    // 站点图标：导入插件时下载并缓存到插件目录（音源列表 / 切换按钮用它）
    iconUrl: 'https://www.kugou.com/root/favicon.ico',
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

  /* ------------------------------------------------------- 热门搜索（搜索页） */
  getHotSearchTags: function () {
    var url =
      'https://gateway.kugou.com/api/v3/search/hot_tab' +
      '?signature=ee44edb9d7155821412d220bcaf509dd&appid=1005' +
      '&clientver=10026&plat=0';
    return cerumusic
      .request(url, {
        method: 'GET',
        headers: {
          dfid: '1ssiv93oVqMp27cirf2CvoF1',
          mid: '156798703528610303473757548878786007104',
          clienttime: '1584257267',
          'x-router': 'msearch.kugou.com',
          'kg-rc': '1',
          'User-Agent':
            'Android9-AndroidPhone-10020-130-0-searchrecommendprotocol-wifi'
        },
        timeout: 15000
      })
      .then(decodeBody)
      .then(function (body) {
        var data = body.data || {};
        var list = data.list || [];
        var tags = [];
        for (var i = 0; i < list.length; i++) {
          var keywords = (list[i] && list[i].keywords) || [];
          for (var j = 0; j < keywords.length; j++) {
            var word = keywords[j] && keywords[j].keyword;
            if (!word) continue;
            var text = String(word);
            if (tags.indexOf(text) >= 0) continue;
            tags.push(text);
            if (tags.length >= 10) return JSON.stringify(tags);
          }
        }
        return JSON.stringify(tags);
      })
      .catch(function () {
        return JSON.stringify([]);
      });
  },

  /* ------------------------------------------------------------ 搜索歌曲 */
  search: function (source, keyword, page, limit) {
    var size = limit || 30;
    var currentPage = page || 1;
    return fetchSearch(keyword, currentPage, size).then(function (body) {
      var data = body.data || {};
      var list = data.lists || data.info || [];
      var total = totalOf(data.total);
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
    return fetchPlaylistSearch(keyword, page || 1, size).then(function (body) {
      var data = body.data || {};
      var list = data.info || [];
      var total = totalOf(data.total);
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
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * ((page || 1) - 1), list.length, size, data),
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
    // getSpecial 固定每页 20 条，且不返回总数，只能按「不足一页即到底」判
    var size = 20;
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
          total: null,
          limit: size,
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
    var currentPage = page || 1;
    var size = 100;
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
      fetchTopListDetail(rankId, currentPage),
      metaPromise
    ]).then(function (results) {
      var data = (results[0] && results[0].data) || {};
      var meta = results[1] || {};
      var songs = songsOf(data.info || data.list || []);
      // data.total 是榜单歌曲总数（可到 500），100 首一页翻页拿全
      var total = totalOf(data.total);
      if (total === null) total = songs.length;
      return JSON.stringify({
        total: total,
        limit: size,
        isEnd: isPageEnd(
          total,
          size * (currentPage - 1),
          songs.length,
          size,
          data
        ),
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
          author: '',
          songCount: total
        },
        songs: songs
      });
    });
  },

  /* ------------------------------------------------------------- 歌单详情 */
  getMusicSheetInfo: function (sheetId, page) {
    var specialId = String(sheetId || '').replace(/^kg_/, '');
    var currentPage = page || 1;
    var size = 1000;
    return Promise.all([
      fetchSpecialSongs(specialId, currentPage),
      currentPage === 1 ? fetchSpecialInfo(specialId) : Promise.resolve(null)
    ]).then(function (results) {
      var body = results[0] || {};
      var info = results[1] || {};
      var data = body.data || {};
      var songs = songsOf(data.info || data.list || []);
      // 歌曲数优先取 special/info 的 songcount，其次 special/song 的
      // data.total；只有第一页才允许用「本页条数」兜底，翻页时宁缺毋滥。
      var total = totalOf(info.songcount);
      if (total === null) total = totalOf(data.total);
      if (total === null && currentPage === 1) total = songs.length;
      // special/song 不返回专辑信息：封面 / 歌名 / 歌手用 album_audio 批量补，
      // 否则歌单详情页的歌曲列表整列都是灰底音符占位图。
      return hydrateSongs(songs).then(function () {
        return JSON.stringify({
          total: total,
          limit: size,
          isEnd: isPageEnd(
            total,
            size * (currentPage - 1),
            songs.length,
            size,
            data
          ),
          sheet: {
            title: decodeName(info.specialname || data.specialname || ''),
            coverUrl: normalizeImage(info.imgurl || data.imgurl || '', '400'),
            description: decodeName(info.intro || ''),
            author: String(info.nickname || ''),
            songCount: total === null ? 0 : total
          },
          songs: songs
        });
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
    // 兜底：歌曲没带封面时按专辑 id 再查一次（歌单详情里个别老歌会走到这里）
    var albumId =
      musicInfo && (musicInfo.albumId || musicInfo.albumid || '');
    if (!albumId) return Promise.resolve('');
    return getJson(
      CDN + '/api/v3/album/info?albumid=' + albumId + '&version=9108'
    )
      .then(function (body) {
        var info = body.data || {};
        return normalizeImage(info.imgurl, '800');
      })
      .catch(function () {
        return '';
      });
  }
};
