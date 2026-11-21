// 1) 从 nmobi 拿一个新鲜签名 URL
// 2) 用不同 User-Agent 请求同一 URL，比较 content-length / 时长
const http = require('http');
const https = require('https');
const { URL } = require('url');

function fetch(url, headers = {}) {
  return new Promise((resolve, reject) => {
    let parsed;
    try {
      parsed = new URL(url);
    } catch (e) {
      return reject(e);
    }
    const client = parsed.protocol === 'https:' ? https : http;
    const req = client.request(
      {
        hostname: parsed.hostname,
        port: parsed.port,
        path: parsed.pathname + parsed.search,
        method: 'GET',
        headers: Object.assign({ Range: 'bytes=0-300000' }, headers),
      },
      (res) => {
        const chunks = [];
        res.on('data', (c) => chunks.push(c));
        res.on('end', () => {
          resolve({
            statusCode: res.statusCode,
            headers: res.headers,
            bytes: Buffer.concat(chunks),
          });
        });
      }
    );
    req.on('error', reject);
    req.setTimeout(25000, () => req.destroy(new Error('timeout')));
    req.end();
  });
}

function getNmobiUrl(rid, br) {
  const user = String(100000000 + Math.floor(Math.random() * 900000000));
  const loginUid = String(1000000000 + Math.floor(Math.random() * 3000000000));
  const url =
    'https://nmobi.kuwo.cn/mobi.s?f=web&source=kwplayercar_ar_6.0.0.9_B_jiakong_vh.apk&type=convert_url_with_sign&rid=' +
    rid +
    '&br=' +
    br +
    '&user=' +
    user +
    '&loginUid=' +
    loginUid;
  return fetch(url, { Referer: 'http://www.kuwo.cn/', 'User-Agent': 'Mozilla/5.0 (Linux; Android 6.0; Nexus 5) AppleWebKit/537.36' }).then((r) => {
    const body = r.bytes.toString('utf8');
    try {
      const parsed = JSON.parse(body);
      return parsed.data && parsed.data.url;
    } catch (_) {
      return null;
    }
  });
}

// 估算 mp3 时长：content-length + bitrate
function estDuration(totalBytes, bitrateKbps) {
  return (totalBytes * 8) / (bitrateKbps * 1000);
}

(async () => {
  const rid = process.argv[2] || '93157';
  const mediaUrl = await getNmobiUrl(rid, '128kmp3');
  console.log('fresh media URL:', mediaUrl);
  if (!mediaUrl) {
    console.log('FAILED to get media url');
    return;
  }

  const uas = {
    '无UA(裸)': {},
    'ExoPlayer': { 'User-Agent': 'ExoPlayerLib/2.19.1 (Linux; Android 14)' },
    'Chrome桌面': { 'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36' },
    'just_audio默认(Dart)': { 'User-Agent': 'Dart/3.4 (dart:io)' },
  };

  for (const [name, headers] of Object.entries(uas)) {
    try {
      const r = await fetch(mediaUrl, headers);
      const total = parseInt(
        (r.headers['content-range'] || '').split('/')[1] || r.headers['content-length'] || '0',
        10,
      );
      const firstBytes = r.bytes.slice(0, 200).toString('utf8');
      const isMp3 = total > 100000;
      console.log(
        `[${name}] status=${r.statusCode} totalBytes=${total} ` +
          `estDuration(128k)=${isMp3 ? estDuration(total, 128).toFixed(1) : '?'}s ` +
          `type=${r.headers['content-type']} head=${JSON.stringify(firstBytes.slice(0, 60))}`,
      );
    } catch (e) {
      console.log(`[${name}] ERROR: ${e.message}`);
    }
  }
})();
