"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const axios_1 = require("axios");
const dayjs = require("dayjs");
const he = require("he");
const CryptoJs = require("crypto-js");
const { load } = require("cheerio");
const UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36";
/** 浏览器标准请求头（space / 网页接口风控会校验 sec-ch-ua / priority 等，缺失会被打高分）。 */
const BROWSER_HINTS = {
    "sec-ch-ua": '"Chromium";v="121", "Not A(Brand";v="99", "Google Chrome";v="121"',
    "sec-ch-ua-mobile": "?0",
    "sec-ch-ua-platform": '"Windows"',
    priority: "u=1, i",
    dnt: "1",
};
/**
 * 注意：accept-encoding 不能带 br。
 * MintMusic 的 JS 宿主用 dart:io HttpClient 转发请求，它只自动解压 gzip，
 * 服务端返回 brotli 时拿到的是乱码字节（表现为 code 为 undefined 的解析错误）。
 * 实测 api.bilibili.com 的 space/wbi/arc/search 在声明 br 时确实回 br。
 */
const ACCEPT_ENCODING = "gzip, deflate";
const headers = {
    "user-agent": UA,
    accept: "*/*",
    "accept-encoding": ACCEPT_ENCODING,
    "accept-language": "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
};
/* ------------------------------------------------------------------ *
 * App 端接口凭据（与 PiliPlus 一致）
 *
 * 作者投稿列表走 app.bilibili.com 的 /x/v2/space/archive/cursor：
 * 只需要 appkey + sign，不校验 buvid / WBI / dm_img，也不会回 412。
 * ------------------------------------------------------------------ */
const APP_UA = "Mozilla/5.0 BiliDroid/8.43.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/8430300 channel/master innerVer/8430300 osVer/15 network/2";
const APP_KEY = "dfca71928277209b";
const APP_SEC = "b5475a8825547a4fc26c7d518eaaa02e";
const APP_STATISTICS = '{"appId":1,"platform":3,"version":"8.43.0","abtest":""}';
const APP_BASE_HEADERS = {
    "user-agent": APP_UA,
    accept: "*/*",
    "accept-encoding": ACCEPT_ENCODING,
    env: "prod",
    "app-key": "android64",
    "x-bili-aurora-zone": "sh001",
    referer: "https://www.bilibili.com",
};
let cookie = null;
/** 字节数组 → base64（复用 crypto-js 的 Base64 编码器）。 */
function bytesToBase64(bytes) {
    const words = [];
    for (let i = 0; i < bytes.length; i++) {
        words[i >> 2] = (words[i >> 2] || 0) | ((bytes[i] & 0xff) << (24 - 8 * (i & 3)));
    }
    return CryptoJs.enc.Base64.stringify(CryptoJs.lib.WordArray.create(words, bytes.length));
}
/** 随机设备指纹字段（与 PiliPlus 一致：字节取 0x26~0x7E 不含 '%'，base64 后去掉末尾2字符）。 */
function randomDmImgStr(minLength, maxLength) {
    const length = minLength + Math.floor(Math.random() * (maxLength - minLength + 1));
    const bytes = [];
    for (let i = 0; i < length; i++) {
        bytes.push(0x26 + Math.floor(Math.random() * 0x59));
    }
    return bytesToBase64(bytes).slice(0, -2);
}
/** 本地生成 buvid3：UUIDv4 大写 + 5位随机数字 + 'infoc'（网页端 / PiliPlus 同款格式）。 */
function genBuvid3() {
    const hex = () => Math.floor(Math.random() * 16).toString(16).toUpperCase();
    let s = "";
    for (let i = 0; i < 32; i++) {
        s += hex();
        if (i === 7 || i === 11 || i === 15 || i === 19)
            s += "-";
    }
    s = s.slice(0, 14) + "4" + s.slice(15); // UUID version
    s = s.slice(0, 19) + "8" + s.slice(20); // UUID variant(10xx)
    const digits = String(Math.floor(Math.random() * 100000)).padStart(5, "0");
    return `${s}${digits}infoc`;
}
/** 激活 buvid：向 ExClimbWuzhi 上报指纹（参考 PiliPlus / 网页端行为）。
 *  未激活的 buvid 是 B 站风控 412 的主要触发条件；激活失败不阻塞后续请求。 */
async function activateBuvid() {
    const bytes = [];
    for (let i = 0; i < 32; i++)
        bytes.push(Math.floor(Math.random() * 256));
    bytes.push(0, 0, 0, 0, 73, 69, 78, 68); // PNG IEND 尾巴
    for (let i = 0; i < 4; i++)
        bytes.push(Math.floor(Math.random() * 256));
    const pngEnd = bytesToBase64(bytes);
    const payload = JSON.stringify({
        3064: 1,
        "39c8": "333.1387.fp.risk",
        "3c43": { adca: "Linux", bfe9: pngEnd.substring(pngEnd.length - 50) },
    });
    try {
        await axios_1.default.post("https://api.bilibili.com/x/internal/gaia-gateway/ExClimbWuzhi", { payload }, {
            headers: {
                "user-agent": UA,
                "content-type": "application/json",
                origin: "https://www.bilibili.com",
                referer: "https://www.bilibili.com/",
                cookie: `buvid3=${cookie.b_3}`,
            },
        });
    }
    catch (_a) {
        // 激活失败不阻塞：后续请求仍可用（只是风控概率略高）
    }
}
/** 领取 buvid4（网页端首访即由服务端下发）。只带 buvid3 的 cookie 是明显的
 *  脚本特征：实测缺 buvid4 / buvid_fp 时 space 接口 412 概率明显升高。 */
async function fetchBuvid4() {
    try {
        const res = (await axios_1.default.get("https://api.bilibili.com/x/frontend/finger/spi", {
            headers: { "user-agent": UA, "accept-encoding": ACCEPT_ENCODING },
        })).data;
        if (res && res.code === 0 && res.data) {
            return res.data.b_4 || "";
        }
    }
    catch (_a) {
        // 领不到就用空值：网页接口只是概率变差，不影响 App 接口
    }
    return "";
}
async function getCookie() {
    if (!cookie) {
        // buvid3 本地生成并激活，不再从 finger/spi 领取：
        // 接口领取的匿名 buvid 未激活，极易被风控 412（PiliPlus 同样本地生成 + 激活）。
        cookie = { b_3: genBuvid3(), b_nut: Math.floor(Date.now() / 1000) };
        await activateBuvid();
        cookie.b_4 = await fetchBuvid4();
    }
    return cookie;
}
function getCookieString() {
    const parts = [];
    if (cookie) {
        parts.push(`buvid3=${cookie.b_3}`);
        if (cookie.b_4)
            parts.push(`buvid4=${cookie.b_4}`);
        if (cookie.b_nut)
            parts.push(`b_nut=${cookie.b_nut}`);
        // buvid_fp：网页端由本地指纹算法生成，这里用 buvid3 前缀占位，
        // 目的只是让 cookie 形态贴近真实浏览器。
        parts.push(`buvid_fp=${String(cookie.b_3).split("-")[0].toLowerCase()}`);
        parts.push("CURRENT_FNVAL=4048");
    }
    if (auth) {
        parts.push(`bili_ticket=${auth.ticket}`, `bili_ticket_expires=${auth.expiresAt}`);
    }
    // 分隔符必须是 "; "（分号 + 空格）。真实浏览器一律带空格，实测
    // playurl 接口对 "a=1;b=2" 这种紧凑写法会直接回 412（2/2 命中），
    // 换成 "a=1; b=2" 后 0/2 —— 这是「所有歌曲播放失败」的真正根因。
    return parts.join("; ");
}
async function getCid(bvid, aid) {
    const params = bvid ? { bvid } : { aid };
    // view 接口裸 headers（不带 cookie）容易被风控拦截：返回 HTML / 空
    // 响应（HTTP 200 但不是 JSON），上层读 code 时是 undefined。
    await getCookie();
    const cidRes = (await axios_1.default.get("https://api.bilibili.com/x/web-interface/view", {
        headers: Object.assign(Object.assign({}, headers), { cookie: getCookieString() }),
        params,
    })).data;
    return cidRes;
}
function durationToSec(duration) {
    if (typeof duration === "number") {
        return duration;
    }
    if (typeof duration === "string") {
        const dur = duration.split(":");
        return dur.reduce(function (prev, curr) {
            return 60 * prev + +curr;
        }, 0);
    }
    return 0;
}
const searchHeaders = {
    "user-agent": UA,
    accept: "application/json, text/plain, */*",
    "accept-encoding": ACCEPT_ENCODING,
    origin: "https://search.bilibili.com",
    "sec-fetch-site": "same-site",
    "sec-fetch-mode": "cors",
    "sec-fetch-dest": "empty",
    referer: "https://search.bilibili.com/",
    "accept-language": "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
};
const pageSize = 20;
async function searchBase(keyword, page, searchType) {
    await getCookie();
    const params = {
        context: "",
        page,
        order: "",
        page_size: pageSize,
        keyword,
        duration: "",
        tids_1: "",
        tids_2: "",
        __refresh__: true,
        _extra: "",
        highlight: 1,
        single_column: 0,
        platform: "pc",
        from_source: "",
        search_type: searchType,
        dynamic_offset: 0,
    };
    const res = (await axios_1.default.get("https://api.bilibili.com/x/web-interface/search/type", {
        headers: Object.assign(Object.assign({}, searchHeaders), { cookie: getCookieString() }),
        params,
    })).data;
    // 搜索接口非零错误码（风控等）时 data 为空，先校验并给出明确错误，
    // 避免上层 result.map 抛 "cannot read property ... of undefined"。
    if (!res || res.code !== 0 || res.data == null) {
        throw new Error(`bilibili 搜索 ${res && res.code}: ${(res && res.message) || "无法获取搜索结果"}`);
    }
    return res.data;
}
async function getFavoriteList(id) {
    const result = [];
    const pageSize = 20;
    let page = 1;
    while (true) {
        try {
            const { data: { data: { medias, has_more }, }, } = await axios_1.default.get("https://api.bilibili.com/x/v3/fav/resource/list", {
                params: {
                    media_id: id,
                    platform: "web",
                    ps: pageSize,
                    pn: page,
                },
            });
            result.push(...medias);
            if (!has_more) {
                break;
            }
            page += 1;
        }
        catch (error) {
            console.warn(error);
            break;
        }
    }
    return result;
}
function formatMedia(result) {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
    const title = he.decode((_b = (_a = result.title) === null || _a === void 0 ? void 0 : _a.replace(/(\<em(.*?)\>)|(\<\/em\>)/g, "")) !== null && _b !== void 0 ? _b : "");
    const media = {
        id: (_d = (_c = result.cid) !== null && _c !== void 0 ? _c : result.bvid) !== null && _d !== void 0 ? _d : result.aid,
        aid: result.aid,
        bvid: result.bvid,
        artist: (_e = result.author) !== null && _e !== void 0 ? _e : (_f = result.owner) === null || _f === void 0 ? void 0 : _f.name,
        title,
        alias: (_g = title.match(/《(.+?)》/)) === null || _g === void 0 ? void 0 : _g[1],
        album: (_h = result.bvid) !== null && _h !== void 0 ? _h : result.aid,
        artwork: ((_j = result.pic) === null || _j === void 0 ? void 0 : _j.startsWith("//"))
            ? "http:".concat(result.pic)
            : result.pic,
        duration: durationToSec(result.duration),
        tags: (_k = result.tag) === null || _k === void 0 ? void 0 : _k.split(","),
        date: dayjs.unix(result.pubdate || result.created).format("YYYY-MM-DD"),
    };
    // 充电专属视频（与 PiliPlus 一致：投稿列表 vlist 的 is_charging_arc），
    // 标记后透传给 MintMusic 显示「会员」标签 / 按设置过滤。
    if (result.is_charging_arc === true) {
        media.vipExclusive = true;
    }
    return media;
}
async function searchAlbum(keyword, page) {
    const resultData = await searchBase(keyword, page, "video");
    const albums = (resultData.result || []).map(formatMedia);
    return {
        isEnd: (resultData.numResults || 0) <= page * pageSize,
        data: albums,
    };
}
async function searchArtist(keyword, page) {
    const resultData = await searchBase(keyword, page, "bili_user");
    const artists = ((resultData.result || [])).map((result) => {
        var _a;
        return ({
            name: result.uname,
            id: result.mid,
            fans: result.fans,
            description: result.usign,
            avatar: ((_a = result.upic) === null || _a === void 0 ? void 0 : _a.startsWith("//"))
                ? `https://${result.upic}`
                : result.upic,
            worksNum: result.videos,
        });
    });
    return {
        isEnd: (resultData.numResults || 0) <= page * pageSize,
        data: artists,
    };
}
function getMixinKey(e) {
    var t = [];
    return ([
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5,
        49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55,
        40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57,
        62, 11, 36, 20, 34, 44, 52,
    ].forEach(function (r) {
        e.charAt(r) && t.push(e.charAt(r));
    }),
        t.join("").slice(0, 32));
}
function hmacSha256(key, message) {
    const hmac = CryptoJs.HmacSHA256(message, key);
    return hmac.toString(CryptoJs.enc.Hex);
}
async function getBiliTicket(csrf) {
    const ts = Math.floor(Date.now() / 1000);
    const hexSign = hmacSha256('XgwSnGZ1p', `ts${ts}`);
    const url = 'https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket';
    try {
        const response = await axios_1.default.post(url, null, {
            params: {
                key_id: 'ec02',
                hexsign: hexSign,
                'context[ts]': ts,
                csrf: csrf || ''
            },
            headers: Object.assign({ 'User-Agent': UA, referer: 'https://www.bilibili.com/' }, cookie
                ? { cookie: `buvid3=${cookie.b_3}` }
                : {})
        });
        const data = await response.data;
        return data.data;
    }
    catch (e) {
        throw e;
    }
}
const WBI_KEY_TTL_MS = 12 * 60 * 60 * 1000;
const TICKET_REFRESH_MARGIN = 300;
let auth = null;
let authPromise = null;
function extractKey(url) {
    if (!url)
        return '';
    return url.slice(url.lastIndexOf('/') + 1, url.lastIndexOf('.'));
}
async function fetchAuth() {
    // ticket 会与该 buvid 绑定,先确保匿名 buvid 已就绪
    await getCookie();
    const data = await getBiliTicket('');
    if (!data || !data.ticket || !data.nav) {
        throw new Error('bilibili: GenWebTicket returned incomplete data');
    }
    const now = Math.floor(Date.now() / 1000);
    const createdAt = Number(data.created_at) || now;
    const ttl = Number(data.ttl) || 259200;
    return {
        ticket: data.ticket,
        createdAt,
        expiresAt: createdAt + ttl,
        img: extractKey(data.nav.img),
        sub: extractKey(data.nav.sub),
        fetchedAt: Date.now()
    };
}
async function ensureAuth(force = false) {
    const nowSec = Math.floor(Date.now() / 1000);
    const fresh = auth &&
        nowSec < auth.expiresAt - TICKET_REFRESH_MARGIN &&
        Date.now() - auth.fetchedAt < WBI_KEY_TTL_MS;
    if (!force && fresh)
        return auth;
    if (!authPromise) {
        authPromise = fetchAuth()
            .then((next) => {
            auth = next;
            return next;
        })
            .finally(() => {
            authPromise = null;
        });
    }
    return authPromise;
}
// 412 后丢弃 ticket 与 WBI key,下一次请求重新换取
function invalidateAuth() {
    auth = null;
}
async function getWBIKeys() {
    const current = await ensureAuth();
    if (!current.img || !current.sub) {
        throw new Error('bilibili: WBI keys missing');
    }
    return {
        img: current.img,
        sub: current.sub
    };
}
async function getRid(params) {
    const wbiKeys = await getWBIKeys();
    const npi = wbiKeys.img + wbiKeys.sub;
    const o = getMixinKey(npi);
    const l = Object.keys(params).sort();
    let c = [];
    for (let d = 0, u = /[!'\(\)*]/g; d < l.length; ++d) {
        let [h, p] = [l[d], params[l[d]]];
        p && "string" == typeof p && (p = p.replace(u, "")),
            null != p &&
                c.push("".concat(encodeURIComponent(h), "=").concat(encodeURIComponent(p)));
    }
    const f = c.join("&");
    const w_rid = CryptoJs.MD5(f + o).toString();
    return w_rid;
}
let w_webid;
let w_webid_date;
async function getWWebId(id) {
    if (w_webid && w_webid_date && (Date.now() - w_webid_date.getTime() < 1000 * 60 * 60)) {
        return w_webid;
    }
    const html = (await axios_1.default.get("https://space.bilibili.com/" + id, {
        headers: {
            "user-agent": UA,
        }
    })).data;
    const $ = load(html);
    const content = $("#__RENDER_DATA__").text();
    const jsonContent = JSON.parse(decodeURIComponent(content));
    w_webid = jsonContent.access_id;
    w_webid_date = new Date();
    return w_webid;
}
/* ================================================================== *
 * 作者投稿列表
 *
 * 主路径：App 接口 app.bilibili.com/x/v2/space/archive/cursor
 *   —— 与 PiliPlus「作者主页 → 投稿」完全同款。只需要 appkey + sign，
 *      不校验 buvid3/buvid4/WBI 签名/dm_img_*，因此不会返回 412。
 *      实测：网页 WBI 接口 412 命中率 0~80%（随机采样），App 接口 0/N。
 * 兜底：网页 WBI 接口 /x/space/wbi/arc/search（补齐浏览器指纹后概率更低，
 *      仍失败则换 buvid 重试一次）。
 * ================================================================== */

/** App 接口签名：appkey + ts + MD5(排序后的 query + appsec)。 */
function appSign(params) {
    params.appkey = APP_KEY;
    params.ts = String(Math.floor(Date.now() / 1000));
    const query = Object.keys(params)
        .sort()
        .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(params[key])}`)
        .join("&");
    params.sign = CryptoJs.MD5(query + APP_SEC).toString();
    return params;
}
const APP_PAGE_SIZE = 20;
/**
 * App 接口是「aid 游标」分页，不是 pn 分页：
 *   - 实测 pn=2 会重复返回第 1 页；
 *   - 响应里的 next_cursor 当 next 参数传回去也无效；
 *   - 传 aid=<上一页最后一条的 param> 才能翻页（PiliPlus 也是这么做的）。
 * 这里按 mid 缓存「取第 p+1 页要用的 aid」，正常顺序翻页时零额外请求。
 */
const arcChains = new Map();
const ARC_CHAIN_LIMIT = 200;
function arcChain(mid) {
    let chain = arcChains.get(mid);
    if (!chain) {
        // 上限保护：长会话里浏览很多 UP 时不至于无限涨内存
        if (arcChains.size >= ARC_CHAIN_LIMIT) {
            const oldest = arcChains.keys().next();
            if (!oldest.done) {
                arcChains.delete(oldest.value);
            }
        }
        chain = { aids: [], isEnd: false };
        arcChains.set(mid, chain);
    }
    return chain;
}
async function fetchAppArcPage(mid, page, aid) {
    const params = {
        vmid: mid,
        build: 8430300,
        version: "8.43.0",
        c_locale: "zh_CN",
        s_locale: "zh_CN",
        channel: "master",
        mobi_app: "android",
        platform: "android",
        ps: APP_PAGE_SIZE,
        qn: 80,
        order: "pubdate",
        statistics: APP_STATISTICS,
    };
    if (aid) {
        params.aid = String(aid);
    }
    const signed = appSign(params);
    const res = (await axios_1.default.get("https://app.bilibili.com/x/v2/space/archive/cursor", {
        headers: APP_BASE_HEADERS,
        params: signed,
    })).data;
    if (!res || res.code !== 0 || !res.data) {
        const err = new Error(`bilibili 投稿列表(app) ${res && res.code}: ${(res && res.message) || "无法获取投稿列表"}`);
        if (res && typeof res.code === "number") {
            err.code = res.code;
        }
        throw err;
    }
    const items = res.data.item || [];
    // 记录「取下一页要用的 aid 游标」
    const chain = arcChain(mid);
    chain.aids[page] = items.length ? items[items.length - 1].param : null;
    chain.isEnd = res.data.has_next === false;
    return {
        isEnd: res.data.has_next === false || items.length === 0,
        data: items.map(formatAppMedia),
    };
}
/** 取第 page 页要用的 aid 游标；缓存缺失（跳页）时逐页补齐。 */
async function resolveAppCursor(mid, page) {
    if (page <= 1) {
        return null;
    }
    const chain = arcChain(mid);
    for (let p = 1; p < page; p++) {
        if (chain.aids[p] !== undefined) {
            continue;
        }
        if (p > 20) {
            // 跳得太远，放弃补齐，交给网页接口兜底
            return undefined;
        }
        await fetchAppArcPage(mid, p, p === 1 ? null : chain.aids[p - 1]);
        if (chain.aids[p] === undefined) {
            return undefined;
        }
    }
    return chain.aids[page - 1] || null;
}
async function fetchArtistWorksApp(artistItem, page) {
    const aid = await resolveAppCursor(artistItem.id, page);
    if (aid === undefined) {
        const err = new Error("bilibili 投稿列表(app): 分页游标缺失");
        err.noCursor = true;
        throw err;
    }
    return await fetchAppArcPage(artistItem.id, page, aid);
}
/** App 列表项 → MusicFree 媒体项。字段名与网页 vlist 不同，单独映射。 */
function formatAppMedia(item) {
    const title = he.decode(item.title || "");
    const cover = item.cover || "";
    const media = {
        // 保持与网页接口一致的 id 语义（bvid 优先），避免历史收藏/歌单失配
        id: item.bvid || item.param,
        aid: Number(item.param) || item.param,
        bvid: item.bvid,
        // App 列表直接带 first_cid：播放时省掉一次风控敏感的 view 请求
        cid: item.first_cid,
        artist: item.author,
        title,
        alias: (title.match(/《(.+?)》/) || [])[1],
        album: item.bvid || item.param,
        artwork: cover.startsWith("//")
            ? `https:${cover}`
            : cover.replace(/^http:/, "https:"),
        duration: typeof item.duration === "number" ? item.duration : durationToSec(item.length),
        tags: [],
        date: item.ctime || item.pubdate
            ? dayjs.unix(item.ctime || item.pubdate).format("YYYY-MM-DD")
            : undefined,
    };
    // 充电专属：App 列表用 is_ugcpay 标记（网页 vlist 是 is_charging_arc）
    if (item.is_ugcpay === true) {
        media.vipExclusive = true;
    }
    return media;
}

/* ---------------- 网页 WBI 接口（兜底路径） ---------------- */
async function fetchArtistWorksWebOnce(artistItem, page, type) {
    const queryHeaders = Object.assign(Object.assign({
        "user-agent": UA,
        accept: "application/json, text/plain, */*",
        "accept-encoding": ACCEPT_ENCODING,
        origin: "https://space.bilibili.com",
        "sec-fetch-site": "same-site",
        "sec-fetch-mode": "cors",
        "sec-fetch-dest": "empty",
        referer: `https://space.bilibili.com/${artistItem.id}/video`,
        "accept-language": "zh-CN,zh;q=0.9,en;q=0.8,en-GB;q=0.7,en-US;q=0.6",
    }, BROWSER_HINTS), { "cache-control": "no-cache", pragma: "no-cache" });
    await getCookie();
    const now = Math.round(Date.now() / 1e3);
    const params = {
        mid: artistItem.id,
        ps: 30,
        tid: 0,
        pn: page,
        web_location: 1550101,
        order_avoided: true,
        order: "pubdate",
        keyword: "",
        platform: "web",
        dm_img_list: "[]",
        // 每次请求随机生成（与 PiliPlus 一致）：固定值的设备指纹等于主动给
        // 风控提供黑名单特征。
        dm_img_str: randomDmImgStr(16, 64),
        dm_cover_img_str: randomDmImgStr(32, 128),
        dm_img_inter: '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
        wts: now.toString(),
    };
    const w_rid = await getRid(params);
    const res = (await axios_1.default.get("https://api.bilibili.com/x/space/wbi/arc/search", {
        headers: Object.assign(Object.assign({}, queryHeaders), { cookie: getCookieString() }),
        params: Object.assign(Object.assign({}, params), { w_rid }),
    })).data;
    // 非零错误码（如 -352 风控校验失败）时 res.data 为空，直接读
    // list.vlist 会抛 "cannot read property 'list' of undefined"。
    // 先校验并抛出带错误码的明确错误，code 记在 err.code 供重试判断。
    if (!res || res.code !== 0 || !res.data || !res.data.list || !res.data.list.vlist) {
        const err = new Error(`bilibili 投稿列表 ${res && res.code}: ${(res && res.message) || "无法获取投稿列表"}`);
        if (res && typeof res.code === "number") {
            err.code = res.code;
        }
        throw err;
    }
    const resultData = res.data;
    const albums = resultData.list.vlist.map(formatMedia);
    return {
        isEnd: resultData.page.pn * resultData.page.ps >= resultData.page.count,
        data: albums,
    };
}
const worksRequests = new Map();
function getArtistWorks(artistItem, page, type) {
    const key = `${artistItem.id}:${page}`;
    const running = worksRequests.get(key);
    if (running)
        return running;
    const task = fetchArtistWorksWithRetry(artistItem, page, type)
        .finally(() => {
        worksRequests.delete(key);
    });
    worksRequests.set(key, task);
    return task;
}
async function fetchArtistWorksWithRetry(artistItem, page, type) {
    let appError = null;
    try {
        return await fetchArtistWorksApp(artistItem, page);
    }
    catch (error) {
        appError = error;
        // App 接口失败（网络 / 签名 / 游标）→ 网页接口兜底
        console.warn(`[bilibili] App 投稿接口失败，改用网页接口: ${(error && error.message) || error}`);
    }
    try {
        return await fetchArtistWorksWebOnce(artistItem, page, type);
    }
    catch (error) {
        const http412 = !!(error && error.response && error.response.status === 412);
        const riskCode = !!error && (error.code === -352 || error.code === -412);
        // 网页接口也失败且不是风控 → 抛 App 接口的错误（信息更准确）
        if (!http412 && !riskCode) {
            throw appError || error;
        }
        // 412 / -352：整个身份重置（丢 ticket + WBI key，换新 buvid3 并重新激活），
        // 冷却后只重试一次，避免连点继续撞风控。
        invalidateAuth();
        cookie = null;
        await new Promise((resolve) => setTimeout(resolve, 1800));
        try {
            return await fetchArtistWorksWebOnce(artistItem, page, type);
        }
        catch (retryError) {
            throw appError || retryError;
        }
    }
}
/**
 * 从 musicItem 里解析出 bvid / aid / cid。
 *
 * 收藏 / 歌单里存的歌曲可能只剩最小字段：MusicFree 适配层在拿不到
 * `extra.musicItem` 时会回退成 `{ id, title, singer, ... }`，没有 bvid/aid。
 * 此时若直接调 view/playurl，会带空参数过去，B 站返回 -400「请求错误」。
 * 这里按 id / album / `_info` 依次兜底：
 *   - 本插件的 id 就是 bvid（formatMedia/formatAppMedia 都按 bvid 优先），
 *   - album 也是 bvid，
 *   - 适配层回退对象会把原始 info 挂在 `_info` 上。
 */
function resolveVideoIds(musicItem) {
    const item = musicItem || {};
    const info = item._info && typeof item._info === "object" ? item._info : {};
    const pick = function () {
        for (let i = 0; i < arguments.length; i++) {
            const v = arguments[i];
            if (v !== undefined && v !== null && v !== "" && v !== 0) {
                return v;
            }
        }
        return undefined;
    };
    const BV_RE = /^BV[0-9A-Za-z]{10}$/;
    const idStr = String(pick(item.id, item.songmid, info.id, "") || "");
    let bvid = pick(item.bvid, info.bvid);
    if (!bvid && BV_RE.test(idStr)) {
        bvid = idStr;
    }
    if (!bvid && typeof item.album === "string" && BV_RE.test(item.album)) {
        bvid = item.album;
    }
    let aid = pick(item.aid, info.aid, info.param);
    if (!aid && /^\d+$/.test(idStr)) {
        aid = idStr;
    }
    const cid = pick(item.cid, info.cid, info.first_cid);
    return { bvid: bvid, aid: aid, cid: cid };
}
async function getMediaSourceOnce(musicItem, quality, tryLook) {
    var _a, _b, _c, _d, _e, _f;
    await getCookie();
    const ids = resolveVideoIds(musicItem);
    if (!ids.bvid && !ids.aid) {
        throw new Error("bilibili: 歌曲缺少 bvid/aid（收藏/歌单里的旧数据丢了插件字段，重新收藏该歌曲即可）");
    }
    let cid = ids.cid;
    if (!cid) {
        const viewRes = await getCid(ids.bvid, ids.aid);
        // view 接口错误（风控 / 稿件删除 / 需要登录）时 data 为空，
        // 直接读 .data.cid 会抛 "cannot read property 'cid' of undefined"，
        // 这里给出带错误码的明确提示。
        if (!viewRes || viewRes.code !== 0 || !viewRes.data) {
            const isObj = !!viewRes && typeof viewRes === "object";
            throw new Error(`bilibili 视频信息 ${isObj ? viewRes.code : "被风控拦截（接口未返回 JSON）"}: ${(isObj && viewRes.message) || "无法获取视频信息"}`);
        }
        cid = viewRes.data.cid;
    }
    const vid = (_f = (ids.bvid !== null && ids.bvid !== undefined
        ? ids.bvid
        : ids.aid)) !== null && _f !== void 0 ? _f : "";
    // 0.3.2 已验证可用的请求形态：未签名的 playurl + cookie。
    // 0.3.4 试过的「wbi/playurl + WBI 签名 + gaia/dm_img 参数」实测持续
    // 412 已回退。try_look（免登录试看，PiliPlus 同款）仅在首请求拿不到
    // 音流时补发，见 getMediaSource。
    //
    // 0.3.11：本接口 412 的真正根因是 Cookie 头的格式 —— getCookieString()
    // 之前用 "; " 之外的紧凑分隔符，playurl 的 WAF 规则会直接判为脚本
    // （实测 6/6 → 412；改成 "; " 后 6/6 → 200）。referer 也补齐成
    // 网页端形态（PiliPlus 每次播放都会带）。
    const params = ids.bvid
        ? { bvid: ids.bvid, cid: cid, fnval: 16 }
        : { aid: ids.aid, cid: cid, fnval: 16 };
    if (tryLook) {
        params.try_look = 1;
    }
    const res = (await axios_1.default.get("https://api.bilibili.com/x/player/playurl", {
        headers: Object.assign(Object.assign({}, headers), {
            referer: "https://www.bilibili.com/",
            origin: "https://www.bilibili.com",
            cookie: getCookieString(),
        }),
        params: params,
    })).data;
    // 接口返回错误码时给出明确报错（大会员专享 / 充电专属 / 区域限制等），
    // 而不是在下面读 res.data.durl 时抛出难以理解的 TypeError。
    if (!res || res.code !== 0) {
        throw new Error(`bilibili playurl ${res && res.code}: ${(res && res.message) || "无法获取播放地址"}`);
    }
    let url;
    if (res.data && res.data.dash) {
        const audios = res.data.dash.audio;
        audios.sort((a, b) => a.bandwidth - b.bandwidth);
        const len = audios.length;
        switch (quality) {
            case "low":
                url = (_a = audios[0]) === null || _a === void 0 ? void 0 : _a.baseUrl;
                break;
            case "standard":
                url = (_b = audios[Math.min(1, len - 1)]) === null || _b === void 0 ? void 0 : _b.baseUrl;
                break;
            case "high":
                url = (_c = audios[Math.min(2, len - 1)]) === null || _c === void 0 ? void 0 : _c.baseUrl;
                break;
            case "super":
                url = (_d = audios[len - 1]) === null || _d === void 0 ? void 0 : _d.baseUrl;
                break;
        }
        if (!url) {
            url = (_e = audios[len - 1]) === null || _e === void 0 ? void 0 : _e.baseUrl;
        }
    }
    else if (res.data && res.data.durl && res.data.durl.length) {
        url = res.data.durl[0].url;
    }
    else {
        // code 0 但没有任何流：匿名请求被限制（未登录不给流），标记后由
        // getMediaSource 带 try_look 免登录试看参数重试。
        const err = new Error("bilibili: 响应中没有可用的音频流（该视频可能需要登录或大会员）");
        err.noStream = true;
        throw err;
    }
    const hostUrl = url.substring(url.indexOf("/") + 2);
    const _headers = {
        "user-agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/89.0.4389.90 Safari/537.36 Edg/89.0.774.63",
        accept: "*/*",
        host: hostUrl.substring(0, hostUrl.indexOf("/")),
        "accept-encoding": "gzip, deflate, br",
        connection: "keep-alive",
        referer: "https://www.bilibili.com/video/".concat(vid),
    };
    return {
        url: url,
        headers: _headers,
    };
}
async function getMediaSource(musicItem, quality) {
    try {
        try {
            return await getMediaSourceOnce(musicItem, quality, false);
        }
        catch (first) {
            // code 0 但没有任何音视频流：匿名请求被限制，带 try_look
            // （免登录试看，PiliPlus 每次播放都带）再试一次。
            if (first && first.noStream) {
                return await getMediaSourceOnce(musicItem, quality, true);
            }
            throw first;
        }
    }
    catch (error) {
        if (!error || !error.response || error.response.status !== 412)
            throw error;
        // 412 风控：整个身份重置——丢弃 ticket / WBI key，并换一个全新的
        // buvid（下次请求会本地重新生成 + 重新激活），冷却后只重试一次。
        invalidateAuth();
        cookie = null;
        await new Promise((resolve) => setTimeout(resolve, 1500));
        return await getMediaSourceOnce(musicItem, quality);
    }
}
async function getTopLists() {
    await getCookie();
    const precious = {
        title: "入站必刷",
        data: [
            {
                id: "popular/precious?page_size=100&page=1",
                title: "入站必刷",
                coverImg: "https://s1.hdslb.com/bfs/static/jinkela/popular/assets/icon_history.png",
            },
        ],
    };
    const weekly = {
        title: "每周必看",
        data: [],
    };
    const weeklyRes = await axios_1.default.get("https://api.bilibili.com/x/web-interface/popular/series/list", {
        headers: Object.assign(Object.assign({}, headers), { cookie: getCookieString() }),
    });
    weekly.data = weeklyRes.data.data.list.slice(0, 8).map((e) => ({
        id: `popular/series/one?number=${e.number}`,
        title: e.subject,
        description: e.name,
        coverImg: "https://s1.hdslb.com/bfs/static/jinkela/popular/assets/icon_weekly.png",
    }));
    const boardKeys = [
        {
            id: "ranking/v2?rid=0&type=all",
            title: "全站",
        },
        {
            id: "ranking/v2?rid=3&type=all",
            title: "音乐",
        },
        {
            id: "ranking/v2?rid=1&type=all",
            title: "动画",
        },
        {
            id: "ranking/v2?rid=119&type=all",
            title: "鬼畜",
        },
        {
            id: "ranking/v2?rid=168&type=all",
            title: "国创相关",
        },
        {
            id: "ranking/v2?rid=129&type=all",
            title: "舞蹈",
        },
        {
            id: "ranking/v2?rid=4&type=all",
            title: "游戏",
        },
        {
            id: "ranking/v2?rid=36&type=all",
            title: "知识",
        },
        {
            id: "ranking/v2?rid=188&type=all",
            title: "科技",
        },
        {
            id: "ranking/v2?rid=234&type=all",
            title: "运动",
        },
        {
            id: "ranking/v2?rid=223&type=all",
            title: "汽车",
        },
        {
            id: "ranking/v2?rid=160&type=all",
            title: "生活",
        },
        {
            id: "ranking/v2?rid=211&type=all",
            title: "美食",
        },
        {
            id: "ranking/v2?rid=217&type=all",
            title: "动物圈",
        },
        {
            id: "ranking/v2?rid=155&type=all",
            title: "时尚",
        },
        {
            id: "ranking/v2?rid=5&type=all",
            title: "娱乐",
        },
        {
            id: "ranking/v2?rid=181&type=all",
            title: "影视",
        },
        {
            id: "ranking/v2?rid=0&type=origin",
            title: "原创",
        },
        {
            id: "ranking/v2?rid=0&type=rookie",
            title: "新人",
        },
    ];
    const board = {
        title: "排行榜",
        data: boardKeys.map((_) => (Object.assign(Object.assign({}, _), { coverImg: "https://s1.hdslb.com/bfs/static/jinkela/popular/assets/icon_rank.png" }))),
    };
    return [weekly, precious, board];
}
async function getTopListDetail(topListItem) {
    var _a;
    await getCookie();
    const res = await axios_1.default.get(`https://api.bilibili.com/x/web-interface/${topListItem.id}`, {
        headers: Object.assign(Object.assign({}, headers), { referer: "https://www.bilibili.com/", cookie: getCookieString() }),
    });
    return Object.assign(Object.assign({}, topListItem), { musicList: (((_a = res.data.data) === null || _a === void 0 ? void 0 : _a.list) || []).map(formatMedia) });
}
async function importMusicSheet(urlLike) {
    var _a, _b, _c, _d;
    let id;
    if (!id) {
        id = (_a = urlLike.match(/^\s*(\d+)\s*$/)) === null || _a === void 0 ? void 0 : _a[1];
    }
    if (!id) {
        id = (_b = urlLike.match(/^(?:.*)fid=(\d+).*$/)) === null || _b === void 0 ? void 0 : _b[1];
    }
    if (!id) {
        id = (_c = urlLike.match(/\/playlist\/pl(\d+)/i)) === null || _c === void 0 ? void 0 : _c[1];
    }
    if (!id) {
        id = (_d = urlLike.match(/\/list\/ml(\d+)/i)) === null || _d === void 0 ? void 0 : _d[1];
    }
    if (!id) {
        return;
    }
    const musicSheet = await getFavoriteList(id);
    return musicSheet.map((_) => {
        var _a, _b;
        return ({
            id: _.id,
            aid: _.aid,
            bvid: _.bvid,
            artwork: _.cover,
            title: _.title,
            artist: (_a = _.upper) === null || _a === void 0 ? void 0 : _a.name,
            album: (_b = _.bvid) !== null && _b !== void 0 ? _b : _.aid,
            duration: durationToSec(_.duration),
        });
    });
}
function formatComment(item) {
    var _a, _b, _c, _d, _e;
    return {
        id: item.rpid,
        nickName: (_a = item.member) === null || _a === void 0 ? void 0 : _a.uname,
        avatar: (_b = item.member) === null || _b === void 0 ? void 0 : _b.avatar,
        comment: (_c = item.content) === null || _c === void 0 ? void 0 : _c.message,
        like: item.like,
        createAt: item.ctime * 1000,
        location: ((_e = (_d = item.reply_control) === null || _d === void 0 ? void 0 : _d.location) === null || _e === void 0 ? void 0 : _e.startsWith("IP属地：")) ? item.reply_control.location.slice(5) : undefined
    };
}
async function getMusicComments(musicItem) {
    var _a, _b;
    const ids = resolveVideoIds(musicItem);
    if (!ids.aid) {
        // 收藏/歌单里的旧数据可能没有 aid，评论区直接按「没有评论」处理
        return { isEnd: true, data: [] };
    }
    const params = {
        type: 1,
        mode: 3,
        oid: ids.aid,
        plat: 1,
        web_location: 1315875,
        wts: Math.floor(Date.now() / 1000)
    };
    const w_rid = await getRid(params);
    const res = (await (axios_1.default.get("https://api.bilibili.com/x/v2/reply/wbi/main", {
        params: Object.assign(Object.assign({}, params), { w_rid })
    }))).data;
    // 评论区关闭 / 需要登录等：replies 为空时按「没有评论」处理，不崩溃。
    const data = (res && res.code === 0 && res.data && res.data.replies) || [];
    const comments = [];
    for (let i = 0; i < data.length; ++i) {
        comments[i] = formatComment(data[i]);
        if ((_a = data[i].replies) === null || _a === void 0 ? void 0 : _a.length) {
            comments[i].replies = (_b = data[i]) === null || _b === void 0 ? void 0 : _b.replies.map(formatComment);
        }
    }
    return {
        isEnd: true,
        data: comments
    };
}
module.exports = {
    platform: "bilibili",
    appVersion: ">=0.0",
    version: "0.3.12-patched",
    author: "猫头猫",
    cacheControl: "no-cache",
    srcUrl: "https://gitee.com/maotoumao/MusicFreePlugins/raw/v0.1/dist/bilibili/index.js",
    primaryKey: ["id", "aid", "bvid", "cid"],
    hints: {
        importMusicSheet: [
            "bilibili 移动端：APP点击我的，空间，右上角分享，复制链接，浏览器打开切换桌面版网站，点击播放全部视频，复制链接",
            "bilibili H5/PC端：复制收藏夹URL，或者直接输入ID即可",
            "非公开收藏夹无法导入，编辑收藏夹改为公开即可",
            "导入时间和歌单大小有关，请耐心等待",
        ],
    },
    supportedSearchType: ["music", "album", "artist"],
    async search(keyword, page, type) {
        if (type === "album" || type === "music") {
            return await searchAlbum(keyword, page);
        }
        if (type === "artist") {
            return await searchArtist(keyword, page);
        }
    },
    getMediaSource,
    async getAlbumInfo(albumItem) {
        var _a;
        const ids = resolveVideoIds(albumItem);
        if (!ids.bvid && !ids.aid) {
            throw new Error("bilibili: 歌曲缺少 bvid/aid（收藏/歌单里的旧数据丢了插件字段，重新收藏该歌曲即可）");
        }
        const cidRes = await getCid(ids.bvid, ids.aid);
        // view 接口错误（稿件删除 / 区域限制 / 风控）时 data 为空，
        // 给出明确错误而不是让 pages.length 崩溃。
        if (!cidRes || cidRes.code !== 0 || !cidRes.data) {
            const isObj = !!cidRes && typeof cidRes === "object";
            throw new Error(`bilibili 视频信息 ${isObj ? cidRes.code : "被风控拦截（接口未返回 JSON）"}: ${(isObj && cidRes.message) || "无法获取视频信息"}`);
        }
        const _ref2 = cidRes.data;
        const cid = _ref2.cid;
        const pages = _ref2.pages || [];
        // 大会员 / 充电专属视频（view 接口的 is_upower_exclusive，
        // 与 PiliPlus 的判断字段一致），标记到每一首（分 P）上。
        const upowerExclusive = _ref2.is_upower_exclusive === true;
        let musicList;
        if (pages.length === 1) {
            musicList = [Object.assign(Object.assign({}, albumItem), { cid: cid })];
        }
        else {
            musicList = pages.map(function (_) {
                return Object.assign(Object.assign({}, albumItem), { cid: _.cid, title: _.part, duration: durationToSec(_.duration), id: _.cid });
            });
        }
        if (upowerExclusive) {
            musicList = musicList.map(function (_) { return (Object.assign(Object.assign({}, _), { vipExclusive: true })); });
        }
        return {
            musicList,
        };
    },
    getArtistWorks,
    getTopLists,
    getTopListDetail,
    importMusicSheet,
    getMusicComments
};
