// 洛雪（LX）格式插件的运行时探针：记录它请求过的所有 URL。
// 用途：分析混淆插件（如 大鱼吃小鱼）到底打了哪些接口。
const fs = require('fs')
const vm = require('vm')
const crypto = require('crypto')

const CODE = fs.readFileSync(process.argv[2], 'utf8')
const MODE = process.argv[3] || 'fail' // fail | ok
const TIMEOUT = Number(process.argv[4] || 15000)

function buildSandbox(vars, calls) {
  let inited = null
  const handlers = {}
  const logs = []

  const sandbox = {
    console: {
      log: (...a) => logs.push(a.join(' ')),
      error: (...a) => logs.push('ERR ' + a.join(' ')),
      warn: (...a) => logs.push('WARN ' + a.join(' ')),
      info: (...a) => logs.push(a.join(' ')),
      debug: () => {},
    },
    setTimeout,
    clearTimeout,
    setInterval,
    clearInterval,
    Promise,
    JSON,
    String,
    Number,
    Math,
    RegExp,
    Object,
    Array,
    Error,
    Date,
    Uint8Array,
    ArrayBuffer,
    TextDecoder,
    TextEncoder,
    URL,
    URLSearchParams,
    Buffer,
    atob: (s) => Buffer.from(String(s), 'base64').toString('binary'),
    btoa: (s) => Buffer.from(String(s), 'binary').toString('base64'),
    encodeURIComponent,
    decodeURIComponent,
    encodeURI,
    decodeURI,
    parseInt,
    parseFloat,
    isNaN,
    module: { exports: {} },
    exports: {},
  }
  sandbox.globalThis = sandbox
  sandbox.window = sandbox

  sandbox.lx = {
    version: '2.0.0',
    apiVersion: 1,
    env: 'desktop',
    currentScriptInfo: {
      name: 'probe',
      rawScript: CODE,
      userVariables: { ...vars },
    },
    EVENT_NAMES: {
      inited: 'inited',
      request: 'request',
      updateAlert: 'updateAlert',
      log: 'log',
    },
    on: (n, f) => {
      handlers[n] = f
    },
    send: (n, d) => {
      if (n === 'inited') inited = d
    },
    getUserVariables: () => ({ ...vars }),
    utils: {
      buffer: {
        from: (d, e) => Buffer.from(d, e),
        bufToString: (b, e) => Buffer.from(b).toString(e),
      },
      crypto: {
        md5: (s) => crypto.createHash('md5').update(String(s), 'utf8').digest('hex'),
        randomBytes: (n) => crypto.randomBytes(n),
        aesEncrypt: (buf, mode, key, iv) => {
          const k = Buffer.from(String(key), 'utf8')
          const algo = 'aes-' + (k.length === 16 ? '128' : k.length === 24 ? '192' : '256') + '-ecb'
          const c = crypto.createCipheriv(algo, k, null)
          return Buffer.concat([
            c.update(Buffer.isBuffer(buf) ? buf : Buffer.from(String(buf), 'utf8')),
            c.final(),
          ])
        },
        rsaEncrypt: () => Buffer.alloc(0),
      },
      zlib: {
        inflate: (b) => Buffer.from(b),
        deflate: (b) => Buffer.from(b),
      },
    },
    request: (url, options, callback) => {
      const opt = options || {}
      const method = (opt.method || 'GET').toUpperCase()
      let bodyText = ''
      if (opt.body) bodyText = String(opt.body).slice(0, 120)
      else if (opt.form) bodyText = JSON.stringify(opt.form).slice(0, 120)
      else if (opt.data) bodyText = String(opt.data).slice(0, 120)
      calls.push({ url: String(url), method, body: bodyText, headers: opt.headers || {} })
      const done = typeof callback === 'function' ? callback : () => {}
      setTimeout(() => {
        const isOfficial = /music\.163\.com/.test(String(url))
        const ok = MODE === 'ok' || MODE === 'trial' || (MODE === 'official' && isOfficial)
        if (ok) {
          // 伪造一个「官方接口成功」的响应，看它是否还会继续兜底。
          done(null, {
            statusCode: 200,
            headers: {},
            body: JSON.stringify({
              code: 200,
              data: [
                {
                  id: '1',
                  url: 'https://m7.music.126.net/probe.mp3?vuutv=PROBE_TOKEN',
                  br: 320000,
                  size: 1000,
                  level: 'exhigh',
                  type: 'mp3',
                  code: 200,
                  fee: 1,
                  freeTrialInfo: MODE === 'trial' ? { start: 0, end: 30 } : null,
                },
              ],
            }),
          })
        } else {
          done(new Error('probe: simulated network failure'))
        }
      }, 1)
    },
  }

  vm.createContext(sandbox)
  return { sandbox, handlers, getInited: () => inited, logs }
}

async function main() {
  const calls = []
  const env = buildSandbox({}, calls)
  try {
    vm.runInContext(CODE, env.sandbox, { timeout: TIMEOUT })
  } catch (e) {
    console.log('!! 脚本执行异常:', e.message)
  }
  const inited = env.getInited()
  if (!inited) {
    console.log('!! 没有收到 inited（不是标准洛雪脚本 / 需要额外环境）')
    console.log('日志:', env.logs.slice(0, 20))
    return
  }
  const sources = inited.sources || {}
  console.log('=== 声明 ===')
  for (const [id, s] of Object.entries(sources)) {
    console.log(
      `  ${id}: name=${s.name} actions=${JSON.stringify(s.actions)} qualitys=${JSON.stringify(s.qualitys)}`,
    )
  }
  console.log('handler?', Object.keys(env.handlers))

  const handler = env.handlers.request || env.handlers.req
  if (!handler) {
    console.log('!! 没有注册 request 处理器')
    return
  }

  const tests = []
  const wy = sources.wy
  if (wy) {
    for (const q of wy.qualitys || ['128k', '320k', 'flac']) tests.push(['wy', q])
  }
  console.log('\n=== 播放请求（MODE=' + MODE + '）===')
  for (const [source, quality] of tests) {
    calls.length = 0
    try {
      const res = await withTimeout(
        handler({
          source,
          action: 'musicUrl',
          info: { type: quality, musicInfo: { songmid: '347230', songId: '347230', id: '347230', name: '海阔天空', singer: 'Beyond', hash: '' } },
        }),
        8000,
      )
      console.log(`-- ${source}/${quality} => ${JSON.stringify(res).slice(0, 120)}`)
    } catch (e) {
      console.log(`-- ${source}/${quality} => 失败: ${e.message}`)
    }
    for (const c of calls) {
      const h = Object.entries(c.headers || {})
        .filter(([k]) => /cookie|referer|user-agent|origin|x-/i.test(k))
        .map(([k, v]) => `${k}=${String(v).slice(0, 60)}`)
        .join('; ')
      console.log(`     ${c.method} ${c.url}  body=${c.body}  ${h ? '[' + h + ']' : ''}`)
    }
  }
  console.log('\n=== 插件日志 ===')
  console.log(env.logs.slice(0, 40).join('\n'))
}

function withTimeout(p, ms) {
  return Promise.race([
    Promise.resolve(p),
    new Promise((_, rej) => setTimeout(() => rej(new Error('timeout ' + ms)), ms)),
  ])
}

process.on('unhandledRejection', () => {})
process.on('uncaughtException', (e) => console.log('uncaught:', e.message))
main().then(() => process.exit(0)).catch((e) => {
  console.log('崩溃:', e.message)
  process.exit(1)
})
