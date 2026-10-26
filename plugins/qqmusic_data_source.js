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

/** 搜索 / 歌单 / 榜单里的歌曲 → 插件歌曲结构（时长单位：秒）。 */
function songOf(item) {
  if (!item) return null;
  var mid = item.songmid || item.mid || '';
  if (!mid) return null;
  var interval = Number(item.interval) || 0;
  return {
    id: String(mid),
    songId: String(item.songid || mid),
    songmid: String(mid),
    name: item.songname || item.name || item.title || '',
    singer: singersOf(item),
    albumName: albumNameOf(item),
    artwork: coverOfAlbumMid(albumMidOf(item)),
    duration: interval > 0 ? interval : 0,
    source: 'tx'
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
  return getJson(
    YQQ +
      '/v8/fcg-bin/fcg_myqq_toplist.fcg?g_tk=5381&loginUin=0&hostUin=0' +
      '&format=json&inCharset=utf8&outCharset=utf-8&notice=0' +
      '&platform=yqq&needNewCode=0'
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

function fetchSheetDetail(dissId) {
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
          song_begin: 0,
          song_num: 1000
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

/* ---------------------------------------------------------------- 插件接口 */

module.exports = {
  pluginInfo: {
    name: 'QQ音乐数据源',
    version: '1.0.0',
    author: 'MintMusic',
    description:
      '只提供搜索、歌单分类、榜单、歌单详情的 QQ音乐数据源；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记
    // 站点图标：导入插件时下载并缓存到插件目录（音源列表 / 切换按钮用它）
    iconUrl: 'https://y.qq.com/favicon.ico',
    isDataSource: true
  },

  sources: {
    tx: {
      name: 'QQ音乐',
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

  isDataSource: true,

  /* ------------------------------------------------------------ 搜索歌曲 */
  search: function (source, keyword, page, limit) {
    var size = limit || 30;
    var currentPage = page || 1;
    return fetchSearch(keyword, currentPage, size).then(function (body) {
      var data = body.data || {};
      var list = (data.song && data.song.list) || [];
      return JSON.stringify({ list: songsOf(list), page: currentPage });
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
      return JSON.stringify({ isEnd: list.length < size, playlists: playlists });
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
        // 分类歌单按页返回，不足一页即到底
        isEnd: playlists.length < 36,
        playlists: playlists
      });
    });
  },

  /* ------------------------------------------------------------- 榜单列表 */
  getTopLists: function () {
    return fetchTopLists().then(function (body) {
      var list = (body.data && body.data.topList) || [];
      var result = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        // 跳过 MV 榜（与内置源一致）
        if (Number(item.id) === 201) continue;
        result.push({
          id: String(item.id),
          name: String(item.topTitle || '').replace(/巅峰榜·/g, ''),
          coverUrl: String(item.picUrl || ''),
          playCount: formatPlayCount(item.listenCount),
          updateFrequency: ''
        });
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
      return JSON.stringify({
        isEnd: true,
        sheet: {
          title: info.title || info.topTitle || '排行榜',
          coverUrl: info.headPicUrl || info.frontPicUrl || '',
          description: info.updateTime || '',
          author: ''
        },
        songs: songs
      });
    });
  },

  /* ------------------------------------------------------------- 歌单详情 */
  getMusicSheetInfo: function (sheetId, page) {
    var raw = String(sheetId || '').replace(/^tx[_:]/, '');
    return fetchSheetDetail(raw).then(function (body) {
      var data = (body.req && body.req.data) || {};
      var dirinfo = data.dirinfo || {};
      var songs = songsOf(data.songlist || []);
      return JSON.stringify({
        isEnd: true,
        sheet: {
          title: dirinfo.title || '',
          coverUrl: String(dirinfo.picurl || '').replace(/\{size\}/g, '400'),
          description: stripBr(dirinfo.desc),
          author: dirinfo.creator && dirinfo.creator.nick
            ? String(dirinfo.creator.nick)
            : ''
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
    return fetchLyric(mid).then(function (body) {
      if (Number(body.retcode) !== 0 && Number(body.code) !== 0) {
        return '';
      }
      var lrc = base64Decode(body.lyric);
      var trans = base64Decode(body.trans);
      return JSON.stringify({ lyric: lrc, lrc: lrc, tlyric: trans });
    });
  },

  /* --------------------------------------------------------------- 封面 */
  getPic: function (source, musicInfo) {
    // QQ 音乐的封面在搜索 / 歌单结果里已经由 albummid 拼好，这里不需要再查。
    return Promise.resolve('');
  }
};
