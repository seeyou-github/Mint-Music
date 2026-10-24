/**
 * 哔哩哔哩插件回归验证（真打 B 站接口）
 *
 * 用法：
 *   node verify-in-node.js [mid] [插件路径]
 *   例：node verify-in-node.js 85754245
 *
 * 做的事：
 *   1. 按 MintMusic 的 axios 桥语义加载插件（含 crypto-js / dayjs / he / cheerio）
 *   2. getArtistWorks 连取 3 页 + 跳页第 5 页，检查条数 / 去重 / isEnd
 *   3. getMediaSource 连取 3 首，检查是否拿到可播放音频流
 *
 * 通过标准：0 次失败、页内无重复、播放地址可解析出 host。
 */
const fs = require('fs');
const path = require('path');
const https = require('https');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '../..');
const PLUGIN = process.argv[3] || path.join(__dirname, 'bilibili-0.3.11-patched.js');
const MID = Number(process.argv[2] || 85754245);
const CALLS = [];

function httpRequest(url, opts) {
  opts = opts || {};
  return new Promise((resolve, reject) => {
    const u = new URL(url);
    const headers = Object.assign({}, opts.headers || {});
    const method = (opts.method || 'GET').toUpperCase();
    let body = null;
    if (opts.data !== undefined && opts.data !== null) {
      body = typeof opts.data === 'string' ? opts.data : JSON.stringify(opts.data);
      if (!Object.keys(headers).some((k) => k.toLowerCase() === 'content-type')) {
        headers['content-type'] = 'application/json';
      }
    }
    const r = https.request(
      { hostname: u.hostname, path: u.pathname + u.search, method, headers, timeout: 20000 },
      (res) => {
        const buf = [];
        res.on('data', (c) => buf.push(c));
        res.on('end', () => {
          let raw = Buffer.concat(buf);
          const enc = String(res.headers['content-encoding'] || '').toLowerCase();
          try {
            if (enc.includes('br')) raw = zlib.brotliDecompressSync(raw);
            else if (enc.includes('gzip')) raw = zlib.gunzipSync(raw);
          } catch (e) {}
          const text = raw.toString('utf8');
          let data = text;
          try { data = JSON.parse(text); } catch (e) {}
          CALLS.push({ url: u.hostname + u.pathname, status: res.statusCode, code: data && data.code });
          const response = { data, status: res.statusCode, headers: res.headers };
          if (res.statusCode >= 200 && res.statusCode < 300) resolve(response);
          else {
            const err = new Error('Request failed with status code ' + res.statusCode);
            err.response = response;
            reject(err);
          }
        });
      }
    );
    r.on('error', reject);
    r.on('timeout', () => { r.destroy(); reject(new Error('timeout')); });
    if (body) r.write(body);
    r.end();
  });
}

function buildUrl(url, params) {
  if (!params) return url;
  const qs = Object.keys(params)
    .map((k) => `${encodeURIComponent(k)}=${encodeURIComponent(params[k])}`)
    .join('&');
  return url + (url.includes('?') ? '&' : '?') + qs;
}

const axiosShim = {
  get(url, config) {
    config = config || {};
    return httpRequest(buildUrl(url, config.params), { headers: config.headers });
  },
  post(url, data, config) {
    config = config || {};
    return httpRequest(buildUrl(url, config.params), { method: 'POST', headers: config.headers, data });
  },
  defaults: { headers: { common: {} } },
  create() { return axiosShim; },
};
axiosShim.default = axiosShim;

const requireShim = (name) => {
  if (name === 'axios') return axiosShim;
  if (name === 'dayjs') return require(path.join(ROOT, 'assets/plugin_modules/dayjs.js'));
  if (name === 'he') return require(path.join(ROOT, 'assets/plugin_modules/he.js'));
  if (name === 'crypto-js') return require(path.join(ROOT, 'assets/plugin_modules/crypto-js.js'));
  if (name === 'cheerio') return { load: () => () => ({ text: () => '' }) };
  throw new Error('未提供的模块: ' + name);
};

const code = fs.readFileSync(PLUGIN, 'utf8');
const moduleObj = { exports: {} };
new Function('require', 'module', 'exports', '__filename', '__dirname', code)(
  requireShim, moduleObj, moduleObj.exports, PLUGIN, path.dirname(PLUGIN)
);
const plugin = moduleObj.exports;

let failed = 0;

(async () => {
  console.log('插件: %s (version %s)\n', path.basename(PLUGIN), plugin.version);

  /* ---- 1) 作者作品列表 ---- */
  const artist = { id: MID, name: '测试UP' };
  const seen = new Set();
  const songs = [];
  for (const page of [1, 2, 3, 5]) {
    CALLS.length = 0;
    const t0 = Date.now();
    try {
      const res = await plugin.getArtistWorks(artist, page, 'music');
      const dup = res.data.filter((x) => seen.has(x.id)).length;
      res.data.forEach((x) => seen.add(x.id));
      if (page <= 3) songs.push(...res.data);
      if (dup) failed++;
      console.log(
        '[作品 P%d] %d 条 | isEnd=%s | 重复=%d | %dms | HTTP=%s',
        page, res.data.length, res.isEnd, dup, Date.now() - t0,
        CALLS.map((c) => c.status).join(',')
      );
    } catch (e) {
      failed++;
      console.log('[作品 P%d] 失败: %s | 请求链: %s', page, String(e.message).slice(0, 80),
        CALLS.map((c) => `${c.url}→${c.status}`).join(','));
    }
  }

  /* ---- 2) 播放地址 ---- */
  for (const song of songs.slice(0, 3)) {
    CALLS.length = 0;
    const t0 = Date.now();
    try {
      const res = await plugin.getMediaSource(song, 'standard');
      const host = new URL(res.url).hostname;
      console.log('[播放] %s | %s | %dms | HTTP=%s', song.title.slice(0, 14), host, Date.now() - t0,
        CALLS.map((c) => c.status).join(','));
    } catch (e) {
      failed++;
      console.log('[播放] %s 失败: %s | 请求链: %s', song.title.slice(0, 14), String(e.message).slice(0, 80),
        CALLS.map((c) => `${c.url}→${c.status}`).join(','));
    }
  }

  console.log('\n%s', failed === 0 ? '全部通过 ✅' : `存在 ${failed} 处失败 ❌`);
  process.exit(failed === 0 ? 0 : 1);
})().catch((e) => {
  console.error('整体失败:', e && e.message);
  process.exit(1);
});
