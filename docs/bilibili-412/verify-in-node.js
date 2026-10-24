/* 在 Node 里按 MintMusic 的桥接语义跑通补丁插件（真打 B 站接口） */
const fs = require('fs');
const path = require('path');
const https = require('https');
const zlib = require('zlib');

const ROOT = path.resolve(__dirname, '../..');
const PLUGIN = process.argv[3] || path.join(__dirname, 'bilibili-0.3.10-patched.js');

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
    const r = https.request({ hostname: u.hostname, path: u.pathname + u.search, method, headers, timeout: 20000 }, (res) => {
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
        const response = { data, status: res.statusCode, headers: res.headers };
        if (res.statusCode >= 200 && res.statusCode < 300) resolve(response);
        else {
          const err = new Error('Request failed with status code ' + res.statusCode);
          err.response = response;
          reject(err);
        }
      });
    });
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
const fn = new Function('require', 'module', 'exports', '__filename', '__dirname', code);
fn(requireShim, moduleObj, moduleObj.exports, PLUGIN, path.dirname(PLUGIN));
const plugin = moduleObj.exports;

(async () => {
  console.log('插件版本:', plugin.version, '| 平台:', plugin.platform);

  const mid = Number(process.argv[2] || 85754245);
  const artist = { id: mid, name: '测试UP' };

  const seen = new Set();
  for (let page = 1; page <= 3; page++) {
    const t0 = Date.now();
    const res = await plugin.getArtistWorks(artist, page, 'music');
    const ids = res.data.map((x) => x.id);
    const dup = ids.filter((x) => seen.has(x)).length;
    ids.forEach((x) => seen.add(x));
    console.log(
      '第%d页: %d 条 | isEnd=%s | 重复=%d | 耗时=%dms | 首条=%s',
      page, res.data.length, res.isEnd, dup, Date.now() - t0,
      JSON.stringify({ id: res.data[0].id, aid: res.data[0].aid, cid: res.data[0].cid, title: res.data[0].title.slice(0, 18), dur: res.data[0].duration, date: res.data[0].date, vip: res.data[0].vipExclusive })
    );
  }

  // 跳页（游标缺失）路径
  const jump = await plugin.getArtistWorks(artist, 5, 'music');
  console.log('跳页第5页: %d 条, 重复=%d', jump.data.length, jump.data.filter((x) => seen.has(x.id)).length);
})().catch((e) => {
  console.error('失败:', e && e.message);
  if (e && e.response) console.error('HTTP', e.response.status, String(e.response.data).slice(0, 200));
  process.exit(1);
});
