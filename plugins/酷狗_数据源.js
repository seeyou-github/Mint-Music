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
var ALBUM_SEARCH = 'http://msearch.kugou.com';
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

/**
 * 从 filename（「歌手 - 歌名」）里解析歌手。
 *
 * 歌单接口（special/song）**不返回 singername**，只有 filename；一旦
 * album_audio 补全没匹配上（见 hydrateSongs 里 hash 不一致的坑），整列歌手
 * 就是空的。这里做一层兜底，保证列表里始终能显示歌手。
 */
function singerFromFilename(item) {
  var fileName = String(item.filename || item.FileName || '');
  if (!fileName) return '';
  var parts = fileName.split(' - ');
  if (parts.length < 2) return '';
  return decodeName(parts[0].trim());
}

function coverOf(item) {  var albumInfo = item.album_info || {};
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
/**
 * 付费 / 版权状态 → 歌曲列表标签（App 侧 SongAccess）。
 *
 * 只认两个信号，别的都会误标：
 *   pay_type = 2   → 数字专辑（实测 Price = 1990 / 2590）
 *   privilege = 10 → VIP（实测未登录取地址直接 status=2）
 *
 * **privilege = 8 不能标 VIP**：实测这些歌未登录照样能拿到完整地址
 * （`v5/url` status=1，能正常播放），它表示的是「高音质要会员」，
 * 不是「这首歌要会员」。同理 `pay_type` 单独也不能当 VIP 依据
 * （privilege=8 的歌 pay_type 也是 3）。
 */
function accessOf(item) {
  if (!item) return '';
  var privRaw = item.Privilege !== undefined ? item.Privilege : item.privilege;
  var payTypeRaw = item.PayType !== undefined ? item.PayType : item.pay_type;
  var priv = privRaw === undefined || privRaw === null ? NaN : Number(privRaw);
  var payType =
    payTypeRaw === undefined || payTypeRaw === null ? NaN : Number(payTypeRaw);
  if (payType === 2) return 'album';
  if (priv === 10) return 'vip';
  return '';
}

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
  // 各接口字段大小写不一致：song_search_v2 给 AlbumID / PublishDate，
  // album_audio 给 album_id / publish_time。少读一套专辑 id 就是空，
  // 「按专辑查年份」也无从谈起。
  var albumId =
    item.album_id ||
    item.AlbumID ||
    albumInfo.album_id ||
    albumInfo.albumid ||
    '';
  return {
    id: String(hash),
    songId: String(hash),
    songmid: String(hash),
    // 补全歌手 / 封面时的精确匹配键：歌单接口给的 hash 与 album_audio 返回的
    // audio_info.hash 往往不是同一个文件（那是 128k 那档的 hash），只有 audio_id 稳定一致。
    audioId: item.audio_id || item.Audioid || undefined,
    // 带上专辑 id：封面补全失败时 getPic 还能按专辑再查一次
    albumId: albumId ? String(albumId) : '',
    // 评论接口要 mixsongid（与 hash / audio_id 不是一个值），搜索接口直接给
    mixSongId: item.MixSongID || item.mixsongid
      ? String(item.MixSongID || item.mixsongid)
      : '',
    // 发行年份：优先用搜索接口直接给的发行日期，没有就留空（对比界面再按专辑查）
    year: yearOfTimestamp(
      item.PublishDate ||
        item.PublishTime ||
        item.publish_time ||
        item.publishtime ||
        albumInfo.publish_time ||
        albumInfo.publish_date ||
        albumInfo.publishDate
    ),
    // 没有 songname 时用 filename（「歌手 - 歌名」），去掉歌手前缀
    name: (function () {
      var name = item.SongName || item.songname;
      if (name) return decodeName(name);
      var fileName = item.filename || '';
      var parts = String(fileName).split(' - ');
      return decodeName(parts.length > 1 ? parts.slice(1).join(' - ') : fileName);
    })(),
    singer: authorsOf(item) || singerFromFilename(item),
    albumName: decodeName(albumName),
    artwork: coverOf(item),
    duration: Math.floor(duration),
    source: 'kg',
    // 非免费标签（vip / album / paid），免费时为空串
    access: accessOf(item)
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
        var byAudioId = {};
        for (var r = 0; r < rows.length; r++) {
          var row = rows[r];
          if (Array.isArray(row)) row = row[0];
          if (!row || !row.audio_info) continue;
          // audio_id 是最稳的匹配键（歌单接口的 hash 与响应里的 audio_info.hash
          // 常常不是同一个文件，按 hash 匹配会大面积落空）。
          if (row.audio_info.audio_id) {
            byAudioId[String(row.audio_info.audio_id)] = row;
          }
          // 顺便把各档 hash 也登记上，兼容只给 hash 的接口（搜索 / 榜单）。
          var audioInfo = row.audio_info;
          var keys = [
            audioInfo.hash,
            audioInfo.hash_128,
            audioInfo.hash_320,
            audioInfo.hash_flac,
            audioInfo.hash_high,
            audioInfo.hash_super
          ];
          for (var k = 0; k < keys.length; k++) {
            if (!keys[k]) continue;
            byHash[String(keys[k]).toUpperCase()] = row;
          }
        }
        for (var s = 0; s < songs.length; s++) {
          var info =
            (songs[s].audioId && byAudioId[String(songs[s].audioId)]) ||
            byHash[String(songs[s].id).toUpperCase()];
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

/** 歌单 / 榜单详情每页歌曲数（与 App 歌单详情页一致）。 */
var SHEET_PAGE_SIZE = 50;

function fetchSpecialSongs(specialId, page) {
  // 只取当前页；总数由 special/info 的 songcount 提供
  var url =
    CDN +
    '/api/v3/special/song?' +
    encodeQuery({
      specialid: specialId,
      page: page,
      pagesize: SHEET_PAGE_SIZE,
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

/* 官方 rank 接口自带 classify 分类（数字 1-5），App 榜单页按它分组；
 * 接口没给组名文字，这里映射成与其他音源一致的组名。 */
var KUGOU_RANK_GROUPS = {
  1: '官方榜',
  2: '地区榜',
  3: '特色榜',
  4: '全球榜',
  5: '曲风榜'
};

/** classify 数字 → 组名；未知分类返回 null（App 里只进「全部」）。 */
function kugouRankGroup(classify) {
  var key = classify === undefined || classify === null ? '' : String(classify);
  return KUGOU_RANK_GROUPS[key] || null;
}

function fetchTopListDetail(rankId, page) {
  var url =
    CDNBJ +
    '/api/v5/rank/song?' +
    encodeQuery({
      version: 9108,
      ranktype: 1,
      plat: 0,
      pagesize: SHEET_PAGE_SIZE,
      area_code: 1,
      page: page,
      rankid: rankId,
      with_res_tag: 0,
      show_portrait_mv: 1
    });
  return getJson(url);
}

/** 搜索结果里的 <em> 高亮标签（专辑名 / 歌手名）需要剥掉。 */
function stripTags(text) {
  return String(text || '').replace(/<[^>]+>/g, '');
}

function fetchAlbumSearch(keyword, page, limit) {
  var url =
    ALBUM_SEARCH +
    '/api/v3/search/album?' +
    encodeQuery({
      version: 9108,
      iscorrection: 1,
      highlight: 'em',
      plat: 0,
      keyword: keyword,
      pagesize: limit,
      page: page,
      sver: 2,
      with_res_tag: 0
    });
  return getJson(url);
}

function fetchAlbumSongs(albumId, page) {
  var url =
    CDN +
    '/api/v3/album/song?' +
    encodeQuery({
      version: 9108,
      albumid: albumId,
      plat: 0,
      pagesize: SHEET_PAGE_SIZE,
      area_code: 1,
      page: page,
      with_res_tag: 0
    });
  return getJson(url);
}

function fetchAlbumInfo(albumId) {
  return getJson(
    CDN + '/api/v3/album/info?albumid=' + albumId + '&version=9108'
  )
    .then(function (body) {
      return body.data || null;
    })
    .catch(function () {
      return null;
    });
}

/* ------------------------------------------------------------ 作者（歌手） */

function fetchSingerSearch(keyword, page, limit) {
  var url =
    CDN +
    '/api/v3/search/singer?' +
    encodeQuery({
      version: 9108,
      keyword: keyword,
      page: page,
      pagesize: limit,
      singingtype: -100,
      accuracy: 1,
      istag: 1,
      area_code: 1
    });
  return getJson(url);
}

function fetchSingerInfo(singerId) {
  return getJson(
    CDN + '/api/v3/singer/info?' + encodeQuery({ singerid: singerId, version: 9108, area_code: 1 })
  )
    .then(function (body) {
      return body.data || null;
    })
    .catch(function () {
      return null;
    });
}

function fetchSingerSongs(singerId, page, order) {
  var url =
    CDN +
    '/api/v3/singer/song?' +
    encodeQuery({
      version: 9108,
      singerid: singerId,
      page: page,
      pagesize: SHEET_PAGE_SIZE,
      // 1 = 发行时间倒序（实测）；2 是其它序（不是时间）。
      // 未传 order 时沿用 1，和原来一致。
      sorttype: order === 'hot' ? 2 : 1,
      area_code: 1
    });
  return getJson(url);
}

/**
 * 作者名反查 singerid（收藏的旧数据可能没带 singerid）。
 * 搜索结果按名字精确匹配，匹配不到就取第一个。
 */
function resolveSingerId(name) {
  if (!name) return Promise.resolve('');
  return fetchSingerSearch(String(name), 1, 5)
    .then(function (body) {
      var data = body.data;
      var list = Array.isArray(data) ? data : data && data.info ? data.info : [];
      var wanted = String(name).trim().toLowerCase();
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        if (String(item.singername || '').trim().toLowerCase() === wanted) {
          return String(item.singerid || '');
        }
      }
      return list.length > 0 ? String((list[0] || {}).singerid || '') : '';
    })
    .catch(function () {
      return '';
    });
}

/** singer/search 直接返回 data 数组（不是 data.info），且无总数、固定 10 条。 */
function singerListOf(body) {
  var data = body && body.data;
  if (Array.isArray(data)) return data;
  if (data && Array.isArray(data.info)) return data.info;
  return [];
}

/**
 * 搜索作者：search/singer 只给 singerid + singername，作品数 / 头像 / 简介
 * 逐个再查一次 singer/info（并发，失败的用空值兜底，不影响列表本身）。
 */
function searchArtists(keyword, page, limit) {
  return fetchSingerSearch(keyword, page, limit)
    .then(function (body) {
      var list = singerListOf(body);
      var items = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        var singerId = item.singerid || item.id;
        if (!singerId) continue;
        items.push({
          id: String(singerId),
          title: decodeName(item.singername || item.name),
          coverUrl: '',
          worksNum: 0,
          description: '',
          // getArtistWorks 需要原样带回的信息
          raw: {
            id: String(singerId),
            singerid: String(singerId),
            name: decodeName(item.singername || item.name)
          }
        });
      }
      // 没有总数：请求一页条数，返回不足一页即到底（该接口固定最多 10 条）
      var pending = [];
      for (var j = 0; j < items.length; j++) {
        pending.push(
          fetchSingerInfo(items[j].id).then(
            (function (index) {
              return function (info) {
                if (!info) return;
                if (info.songcount !== undefined) {
                  items[index].worksNum = Number(info.songcount) || 0;
                }
                var cover = normalizeImage(info.imgurl, '400');
                if (cover) items[index].coverUrl = cover;
                var profile = decodeName(info.profile || info.intro || '');
                if (profile) items[index].description = profile;
              };
            })(j)
          )
        );
      }
      return Promise.all(pending).then(function () {
        return JSON.stringify({
          list: items,
          total: null,
          limit: limit,
          isEnd: items.length < limit
        });
      });
    })
    .catch(function () {
      return JSON.stringify({ list: [], total: null, limit: limit, isEnd: true });
    });
}

/** KRC 的异或密钥（去掉前 4 字节后按 16 字节循环异或，再 zlib 解压）。 */
var KRC_KEY = [
  0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce,
  0xd2, 0x6e, 0x69
];

/**
 * 酷狗的逐字歌词是 KRC：base64 → 去掉 4 字节头 → 异或 → zlib 解压 → UTF-8 文本。
 * App 的歌词解析器能直接认 KRC（[start,dur]<rel,dur,0>词…），所以解出来原样返回。
 */
function decodeKrc(base64Content) {
  if (!base64Content) return '';
  try {
    var raw = cerumusic.utils.buffer.from(base64Content, 'base64');
    if (!raw || raw.length <= 4) return '';
    var bytes = [];
    for (var i = 4; i < raw.length; i++) {
      bytes.push((raw[i] ^ KRC_KEY[(i - 4) % 16]) & 0xff);
    }
    return cerumusic.utils.zlib
      .inflate(bytes)
      .then(function (inflated) {
        return cerumusic.utils.buffer.bufToString(inflated, 'utf8');
      })
      .catch(function () {
        return '';
      });
  } catch (e) {
    return Promise.resolve('');
  }
}

/** 下载某首歌指定格式的歌词（krc = 逐字，lrc = 逐行）。 */
function downloadLyric(candidate, fmt) {
  var url =
    LYRICS +
    '/download?ver=1&client=pc&id=' +
    candidate.id +
    '&accesskey=' +
    encodeURIComponent(candidate.accesskey) +
    '&fmt=' +
    fmt +
    '&charset=utf8';
  return getJson(url).then(function (result) {
    if (Number(result.status) !== 200 || !result.content) return '';
    if (fmt === 'krc') return decodeKrc(result.content);
    return base64Decode(result.content);
  });
}

/** KRC 毫秒时间 → LRC 时间标签 [mm:ss.xx]（宿主 parseLrc 认这个格式）。 */
function lrcTimeTagOf(ms) {
  var centis = Math.floor(Number(ms) / 10);
  if (!isFinite(centis) || centis < 0) centis = 0;
  var cs = centis % 100;
  var seconds = Math.floor(centis / 100);
  var pad = function (n) {
    n = String(n);
    return n.length < 2 ? '0' + n : n;
  };
  return (
    '[' +
    pad(Math.floor(seconds / 60)) +
    ':' +
    pad(seconds % 60) +
    '.' +
    pad(cs) +
    ']'
  );
}

/**
 * 提取 KRC 的 [language:...] 标签 → 翻译 / 音译 LRC，并把标签行从文本剥掉。
 *
 * [language:] 是 base64 的 JSON：
 *   {"content":[{"type":1,"lyricContent":[[" "],["我看见你和她"],…],…}],"version":1}
 * lyricContent 与 KRC 的 [start,dur] 行按顺序一一对应（type 1 = 翻译、
 * 2 = 音译）。原样留在 KRC 文本里就是一大坨 base64（歌词编辑器 / 下载的
 * 内嵌歌词里很难看）；解出来正好交给宿主歌词结果的翻译通道（tlyric / rlyric）。
 */
function extractLanguageLrc(krcText) {
  var result = { krc: String(krcText || ''), trans: '', roma: '' };
  var match = /^\[language:([A-Za-z0-9+/=]+)\]\r?\n?/m.exec(result.krc);
  if (!match) return result;
  result.krc = result.krc.replace(/^\[language:[^\]]*\]\r?\n?/m, '');
  var parsed = null;
  try {
    parsed = JSON.parse(base64Decode(match[1]));
  } catch (e) {
    return result;
  }
  var contents = parsed && parsed.content;
  if (!Array.isArray(contents)) return result;
  // KRC 的 [start,dur] 行起始时间，给翻译行标时间戳用
  var times = [];
  var timed = /\[(\d+),(\d+)\]/g;
  var m;
  while ((m = timed.exec(krcText)) !== null) {
    times.push(Number(m[1]));
  }
  if (!times.length) return result;
  for (var c = 0; c < contents.length; c++) {
    var entry = contents[c] || {};
    var rows = entry.lyricContent;
    if (!Array.isArray(rows) || !rows.length) continue;
    var lines = [];
    for (var i = 0; i < rows.length && i < times.length; i++) {
      var row = rows[i];
      var line = String(Array.isArray(row) ? row.join('') : row || '').trim();
      if (!line) continue;
      lines.push(lrcTimeTagOf(times[i]) + line);
    }
    if (!lines.length) continue;
    var lrc = lines.join('\n');
    if (Number(entry.type) === 2) {
      if (!result.roma) result.roma = lrc;
    } else if (!result.trans) {
      result.trans = lrc;
    }
  }
  return result;
}

function fetchLyric(hash, duration) {
  // 先查歌词 id + accesskey，再按「逐字（krc）→ 逐行（lrc）」的顺序下载
  var searchUrl =
    KRCS +
    '/search?ver=1&man=yes&client=mobi&keyword=&duration=' +
    (duration || 0) +
    '&hash=' +
    hash;
  return getJson(searchUrl).then(function (body) {
    var candidates = body.candidates || [];
    if (!candidates.length) return null;
    var candidate = candidates[0];
    if (!candidate.id || !candidate.accesskey) return null;
    return downloadLyric(candidate, 'krc')
      .catch(function () {
        return '';
      })
      .then(function (krc) {
        if (krc) {
          // [language:...] 里是酷狗自带的逐行翻译 / 音译：解出来交给宿主的
          // 翻译通道，原样留在 KRC 文本里就是一大坨 base64
          var language = extractLanguageLrc(krc);
          return {
            krc: language.krc,
            lrc: '',
            trans: language.trans,
            roma: language.roma
          };
        }
        // 没有逐字歌词（或解码失败）再退回逐行，保证歌词不空
        return downloadLyric(candidate, 'lrc').then(function (lrc) {
          return lrc ? { krc: '', lrc: lrc, trans: '', roma: '' } : null;
        });
      });
  });
}

/* ---------------------------------------------------------------- 评论 */

var COMMENT_PAGE_SIZE = 20;
var COMMENT_HOST = 'https://gateway.kugou.com';
// 酷狗 Android 客户端的固定签名密钥 / 固定 code，公开值（cmtlist 只认它）
var COMMENT_SECRET = 'OIlwieks28dk2k092lksi2UIkp';
var COMMENT_CODE = 'fc4be23b4e972707f36b8a828a93ba8a';

/** 评论时间「YYYY-MM-DD HH:mm:ss」（北京时间）→ 毫秒时间戳。 */
function commentTimeOf(value) {
  var match = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2}):(\d{2})/.exec(
    String(value || '')
  );
  if (!match) return 0;
  var ms = Date.UTC(
    Number(match[1]),
    Number(match[2]) - 1,
    Number(match[3]),
    Number(match[4]) - 8,
    Number(match[5]),
    Number(match[6])
  );
  return isFinite(ms) && ms > 0 ? ms : 0;
}

function commentOf(item) {
  item = item || {};
  var like = item.like || {};
  var likeCount = like.count !== undefined ? like.count : like.likenum;
  return {
    id: String(item.id || ''),
    nickName: decodeName(item.user_name || item.username || ''),
    avatar: normalizeImage(item.user_pic || '', '200'),
    comment: decodeName(item.content || ''),
    like: totalOf(likeCount) || 0,
    createAt: commentTimeOf(item.addtime),
    location: decodeName(item.location || ''),
    replies: totalOf(item.reply_num) || 0,
    // 楼层评论（hot_replylist）要用这两个字段定位，原样带给宿主
    extra: { specialId: String(item.special_child_id || '') }
  };
}

function commentSign(params) {
  var keys = Object.keys(params).sort();
  var text = '';
  for (var i = 0; i < keys.length; i++) {
    text += keys[i] + '=' + params[keys[i]];
  }
  return cerumusic.utils.crypto.md5(COMMENT_SECRET + text + COMMENT_SECRET);
}

/**
 * 评论列表（cmtlist 固定按热度排，参数里没有时间排序开关）。
 * 参数必须放在 query string 上并带 android 签名，放 body 会回 err_code 10002。
 */
function fetchComments(mixSongId, page, size) {
  var params = {
    dfid: '-',
    mid: 'mintmusic',
    uuid: 'mintmusic',
    appid: '1005',
    clientver: '11309',
    userid: '0',
    clienttime: String(Math.floor(Date.now() / 1000)),
    mixsongid: String(mixSongId),
    need_show_image: '1',
    p: String(page),
    pagesize: String(size),
    show_classify: '1',
    show_hotword_list: '1',
    extdata: '0',
    code: COMMENT_CODE
  };
  var url =
    COMMENT_HOST +
    '/mcomment/v1/cmtlist?' +
    encodeQuery(params) +
    '&signature=' +
    commentSign(params);
  return getJson(url, {
    'User-Agent': 'KuGou2012-11309-Android',
    Referer: 'https://www.kugou.com/'
  });
}

/**
 * 一条评论下的二级回复（hot_replylist，参数与 cmtlist 一样带 android 签名）。
 * `childrenid` 是主评论的 special_child_id，`tid` 是主评论 id。
 */
function fetchCommentReplies(mixSongId, specialId, commentId, page, size) {
  var params = {
    dfid: '-',
    mid: 'mintmusic',
    uuid: 'mintmusic',
    appid: '1005',
    clientver: '11309',
    userid: '0',
    clienttime: String(Math.floor(Date.now() / 1000)),
    childrenid: String(specialId),
    mixsongid: String(mixSongId),
    need_show_image: '1',
    p: String(page),
    pagesize: String(size),
    show_classify: '1',
    show_hotword_list: '1',
    tid: String(commentId),
    code: COMMENT_CODE
  };
  var url =
    COMMENT_HOST +
    '/mcomment/v1/hot_replylist?' +
    encodeQuery(params) +
    '&signature=' +
    commentSign(params);
  return getJson(url, {
    'User-Agent': 'KuGou2012-11309-Android',
    Referer: 'https://www.kugou.com/'
  });
}

/** 老歌曲没透传 mixSongID 时，按「歌名 歌手」搜索一次，用 hash 匹配回填。 */
function mixSongIdFromSearch(keyword, hash) {
  if (!keyword) return Promise.resolve('');
  return fetchSearch(keyword, 1, 10)
    .then(function (body) {
      var lists = (body.data && body.data.lists) || [];
      var fallback = '';
      for (var i = 0; i < lists.length; i++) {
        var item = lists[i] || {};
        var mixId = item.MixSongID || item.mixsongid;
        if (!mixId) continue;
        if (
          hash &&
          String(item.FileHash || '').toUpperCase() === String(hash).toUpperCase()
        ) {
          return String(mixId);
        }
        if (!fallback) fallback = String(mixId);
      }
      return /^\d+$/.test(String(hash || '')) ? String(hash) : fallback;
    })
    .catch(function () {
      return /^\d+$/.test(String(hash || '')) ? String(hash) : '';
    });
}

function commentMixSongId(musicInfo) {
  musicInfo = musicInfo || {};
  if (musicInfo.mixSongId) return Promise.resolve(String(musicInfo.mixSongId));
  var id = String(musicInfo.songmid || musicInfo.songId || musicInfo.id || '');
  if (/^\d+$/.test(id)) return Promise.resolve(id);
  var keyword = [musicInfo.name || '', musicInfo.singer || '']
    .join(' ')
    .trim();
  return mixSongIdFromSearch(keyword, id);
}

/* ---------------------------------------------------------------- 插件接口 */

module.exports = {
  pluginInfo: {
    name: '酷狗_数据源',
    version: '1.9.1',
    author: 'MintMusic',
    description:
      '只提供搜索（歌曲 / 专辑 / 作者）、歌单分类、榜单（含分类）、歌单 / 专辑 / 作者详情的酷狗音乐数据源；' +
      '播放需要在「插件管理 → 数据源」里指定一个已安装的播放源。',
    // ★ 数据源标记
    // 站点图标：导入插件时下载并缓存到插件目录（音源列表 / 切换按钮用它）
    iconUrl: 'https://www.kugou.com/root/favicon.ico',
    isDataSource: true
  },

  sources: {
    kg: {
      name: '酷狗',
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

  /* ---------------------------------------------------- 搜索专辑 / 作者 */
  searchTyped: function (source, keyword, page, limit, type) {
    var size = limit || 20;
    var currentPage = page || 1;
    if (type === 'artist') return searchArtists(keyword, currentPage, size);
    if (type !== 'album') {
      return Promise.resolve(
        JSON.stringify({ list: [], total: null, limit: size, isEnd: true })
      );
    }
    return fetchAlbumSearch(keyword, currentPage, size).then(function (body) {
      var data = body.data || {};
      var list = data.info || [];
      var total = totalOf(data.total);
      var items = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        var albumId = item.albumid || item.id;
        if (!albumId) continue;
        items.push({
          id: String(albumId),
          title: decodeName(stripTags(item.albumname)),
          coverUrl: normalizeImage(item.imgurl, '400'),
          artist: decodeName(stripTags(item.singername)),
          worksNum: Number(item.songcount || 0),
          date: String(item.publishtime || '').slice(0, 10),
          description: decodeName(item.intro || ''),
          // getAlbumInfo 需要原样带回的信息
          raw: {
            id: String(albumId),
            albumid: String(albumId),
            artwork: normalizeImage(item.imgurl, '800'),
            title: decodeName(stripTags(item.albumname))
          }
        });
      }
      return JSON.stringify({
        list: items,
        total: total,
        limit: size,
        isEnd: isPageEnd(total, size * (currentPage - 1), list.length, size, data)
      });
    });
  },

  /* ------------------------------------------------------------ 作者作品 */
  getArtistWorks: function (source, artistItem, page, type, order) {
    var raw = (artistItem && artistItem.raw) || artistItem || {};
    var singerId = raw.singerid || raw.id || (artistItem && artistItem.id) || '';
    var name = raw.name || raw.title || (artistItem && artistItem.title) || '';
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
    var ready = /^\d+$/.test(String(singerId))
      ? Promise.resolve(String(singerId))
      : resolveSingerId(name);
    return ready.then(function (id) {
      if (!id) return JSON.stringify({ musicList: [] });
      return Promise.all([
        fetchSingerSongs(id, currentPage, order),
        currentPage === 1 ? fetchSingerInfo(id) : Promise.resolve(null)
      ]).then(function (results) {
        var body = results[0] || {};
        var info = results[1] || {};
        var data = body.data || {};
        var list = data.info || data.list || [];
        var songs = [];
        for (var i = 0; i < list.length; i++) {
          var item = list[i] || {};
          var hash = item.hash || '';
          if (!hash) continue;
          // filename 格式：「歌手 - 歌名」
          var fileName = String(item.filename || '');
          var parts = fileName.split(' - ');
          var songName = parts.length > 1 ? parts.slice(1).join(' - ') : fileName;
          var singer = parts.length > 1 ? parts[0].trim() : '';
          songs.push({
            id: String(hash),
            songId: String(hash),
            songmid: String(hash),
            albumId: item.album_id ? String(item.album_id) : '',
            mixSongId: item.mixsongid ? String(item.mixsongid) : '',
            name: decodeName(songName.trim()),
            singer: decodeName(singer),
            albumName: decodeName(item.album_name || ''),
            artwork: normalizeImage(
              item.trans_param && item.trans_param.union_cover,
              '800'
            ),
            duration: Math.floor(Number(item.duration || 0)),
            source: 'kg'
          });
        }
        // 个别老歌缺封面：用 album_audio 批量补
        return hydrateSongs(songs).then(function () {
          var total = totalOf(data.total);
          if (total === null && currentPage === 1) total = songs.length;
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
            artistItem: {
              id: String(id),
              title: decodeName(info.singername || name),
              coverUrl: normalizeImage(info.imgurl || raw.artwork || '', '400'),
              worksNum: total === null ? 0 : total,
              description: decodeName(info.profile || info.intro || '')
            },
            musicList: songs
          });
        });
      });
    });
  },

  /* ------------------------------------------------------- 作者专辑列表 */
  // 实测：sort=1 发行时间倒序（分页稳定）；2/3 是其它序，0 无效。
  getArtistAlbums: function (source, artistItem, page, order) {
    var raw = (artistItem && artistItem.raw) || artistItem || {};
    var singerId = raw.singerid || raw.id || (artistItem && artistItem.id) || '';
    var name = raw.name || raw.title || (artistItem && artistItem.title) || '';
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
    var ready = /^\d+$/.test(String(singerId))
      ? Promise.resolve(String(singerId))
      : resolveSingerId(name);
    return ready.then(function (id) {
      if (!id) return JSON.stringify({ albumList: [] });
      var url =
        CDN +
        '/api/v3/singer/album?' +
        encodeQuery({
          version: 9108,
          singerid: id,
          page: currentPage,
          pagesize: size,
          sort: order === 'hot' ? 2 : 1
        });
      return getJson(url).then(function (body) {
        var data = body.data || {};
        var list = data.info || [];
        var total = Number(data.total || 0);
        var albums = [];
        for (var i = 0; i < list.length; i++) {
          var it = list[i] || {};
          var albumId = it.albumid || it.album_id || '';
          if (!albumId) continue;
          albums.push({
            id: String(albumId),
            title: decodeName(it.albumname || ''),
            coverUrl: normalizeImage(it.imgurl, '400'),
            artist: decodeName(it.singername || name),
            worksNum: Number(it.songcount || 0),
            // publishtime 是「2026-03-25 00:00:00」，只留日期部分。
            date: String(it.publishtime || it.publish_time || '').slice(0, 10),
            raw: {
              id: String(albumId),
              albumid: String(albumId),
              title: decodeName(it.albumname || '')
            }
          });
        }
        return JSON.stringify({
          albumList: albums,
          total: total,
          limit: size,
          offset: (currentPage - 1) * size,
          isEnd: isPageEnd(
            total,
            (currentPage - 1) * size,
            albums.length,
            size,
            data
          )
        });
      });
    });
  },

  /* --------------------------------------------------------- 作者介绍 */
  getArtistInfo: function (source, artistItem) {
    var raw = (artistItem && artistItem.raw) || artistItem || {};
    var singerId = raw.singerid || raw.id || (artistItem && artistItem.id) || '';
    var name = raw.name || raw.title || (artistItem && artistItem.title) || '';
    var ready = /^\d+$/.test(String(singerId))
      ? Promise.resolve(String(singerId))
      : resolveSingerId(name);
    return ready.then(function (id) {
      if (!id) return JSON.stringify({});
      return fetchSingerInfo(id).then(function (info) {
        if (!info) return JSON.stringify({});
        return JSON.stringify({
          description: decodeName(info.profile || info.intro || ''),
          region: decodeName(info.country || ''),
          style: decodeName(info.style || ''),
          alias: decodeName(info.alias || ''),
          songCount: Number(info.songcount || 0),
          albumCount: Number(info.albumcount || 0)
        });
      });
    });
  },

  // 能力声明：UI 据此决定哪些按钮可点。
  artistCapabilities: function () {
    return JSON.stringify({
      workSort: true,
      albumList: true,
      albumSort: true,
      info: true
    });
  },

  /* ------------------------------------------------------------ 专辑详情 */
  getAlbumInfo: function (source, albumItem, page) {
    var raw = (albumItem && albumItem.raw) || albumItem || {};
    var albumId = raw.albumid || raw.id || (albumItem && albumItem.id) || '';
    if (!albumId) {
      return Promise.resolve(JSON.stringify({ musicList: [] }));
    }
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
    return Promise.all([
      fetchAlbumSongs(albumId, currentPage),
      currentPage === 1 ? fetchAlbumInfo(albumId) : Promise.resolve(null)
    ]).then(function (results) {
      var body = results[0] || {};
      var info = results[1] || {};
      var data = body.data || {};
      var list = data.info || [];
      var songs = [];
      for (var i = 0; i < list.length; i++) {
        var item = list[i] || {};
        var hash = item.hash || item.origin_hash || '';
        if (!hash) continue;
        // filename 格式：「歌手 - 歌名」
        var fileName = String(item.filename || '');
        var parts = fileName.split(' - ');
        var songName = parts.length > 1 ? parts.slice(1).join(' - ') : fileName;
        var artist = parts.length > 1 ? parts[0].trim() : '';
        var cover = normalizeImage(
          (item.trans_param && item.trans_param.union_cover) ||
            raw.artwork ||
            '',
          '800'
        );
        songs.push({
          id: String(hash),
          songId: String(hash),
          songmid: String(hash),
          albumId: String(albumId),
          mixSongId: item.mixsongid ? String(item.mixsongid) : '',
          name: decodeName(songName.trim()),
          singer: decodeName(artist),
          albumName: decodeName(item.remark || raw.title || ''),
          artwork: cover,
          duration: Math.floor(Number(item.duration || 0)),
          source: 'kg'
        });
      }
      var total = totalOf(data.total);
      if (total === null && currentPage === 1) total = songs.length;
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
        albumItem: {
          id: String(albumId),
          title: decodeName(info.albumname || raw.title || ''),
          coverUrl: normalizeImage(info.imgurl || raw.artwork || '', '400'),
          artist: decodeName(info.singername || ''),
          worksNum: total === null ? 0 : total,
          date: String(info.publishtime || '').slice(0, 10),
          description: decodeName(info.intro || '')
        },
        musicList: songs
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
            : '',
          // 官方接口自带 classify 分类（1-5），映射成组名给 App 分类栏
          group: kugouRankGroup(item.classify)
        });
      }
      return JSON.stringify(result);
    });
  },

  /* ------------------------------------------------------------- 榜单详情 */
  getTopListDetail: function (id, page) {
    var rankId = String(id || '').replace(/^kg_/, '');
    var currentPage = page || 1;
    var size = SHEET_PAGE_SIZE;
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
      // data.total 是榜单歌曲总数（可到 500），按页取
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
    var size = SHEET_PAGE_SIZE;
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

  /* --------------------------------------------------------------- 评论 */
  getMusicComments: function (source, musicInfo, page, sort) {
    var currentPage = Number(page) > 0 ? Math.floor(Number(page)) : 1;
    var size = COMMENT_PAGE_SIZE;
    return commentMixSongId(musicInfo).then(function (mixSongId) {
      if (!mixSongId) {
        return JSON.stringify({ comments: [], total: 0, hasMore: false });
      }
      return fetchComments(mixSongId, currentPage, size).then(function (body) {
        var list = body.list || [];
        var comments = [];
        for (var i = 0; i < list.length; i++) comments.push(commentOf(list[i]));
        var total = totalOf(body.count);
        if (total === null) total = comments.length;
        return JSON.stringify({
          comments: comments,
          total: total,
          hasMore: comments.length >= size && size * currentPage < total
        });
      });
    });
  },

  /** 公开接口只有热度排序（时间排序接口签名校验过不去），如实上报。 */
  commentCapabilities: function () {
    return JSON.stringify({ sorts: ['hot'], replies: true });
  },

  /** 一条评论下的二级回复。 */
  getMusicCommentReplies: function (source, musicInfo, commentInfo, page) {
    var info = commentInfo || {};
    var extra = info.extra || {};
    var commentId = String(info.id || '');
    var specialId = String(extra.specialId || '');
    var currentPage = Number(page) > 0 ? Math.floor(Number(page)) : 1;
    var size = COMMENT_PAGE_SIZE;
    if (!commentId || !specialId) {
      return Promise.resolve(
        JSON.stringify({ comments: [], total: 0, hasMore: false })
      );
    }
    return commentMixSongId(musicInfo).then(function (mixSongId) {
      if (!mixSongId) {
        return JSON.stringify({ comments: [], total: 0, hasMore: false });
      }
      return fetchCommentReplies(
        mixSongId,
        specialId,
        commentId,
        currentPage,
        size
      ).then(function (body) {
        var list = body.list || [];
        var comments = [];
        for (var i = 0; i < list.length; i++) comments.push(commentOf(list[i]));
        var total = totalOf(body.comments_num);
        return JSON.stringify({
          comments: comments,
          total: total,
          hasMore:
            comments.length >= size &&
            (total === null || size * currentPage < total)
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
    return fetchLyric(hash, 0).then(function (bundle) {
      if (!bundle) return '';
      var text = bundle.krc || bundle.lrc || '';
      if (!text) return '';
      // krc 放逐字通道（crlyric），lrc 放逐行通道，App 会优先用逐字那份；
      // 酷狗 KRC 自带的翻译 / 音译（[language:] 标签）放 tlyric / rlyric
      return JSON.stringify({
        lyric: text,
        lrc: bundle.lrc || '',
        krc: bundle.krc || '',
        crlyric: bundle.krc || '',
        tlyric: bundle.trans || '',
        rlyric: bundle.roma || ''
      });
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
