/* ==========================================================================
 * Mint-Music: MusicFree 兼容运行时
 *
 * 由 JsEngineService 在加载 MusicFree 格式插件前注入到插件运行时的全局作用域。
 * 负责提供 MusicFree 插件所依赖的运行环境：
 *   1. require() 注册表（axios / cheerio / crypto-js / dayjs / he / qs ...）
 *   2. axios 适配层：把 axios 的调用语义映射到本项目的 cerumusic.request 桥
 *   3. 浏览器 / Node 常见内置对象垫片：atob / btoa / TextEncoder / URL /
 *      URLSearchParams / fetch / localStorage / crypto / process / env
 *
 * 只在本文件中使用 ES5 语法（QuickJS 可以跑 ES2020，但保持与洛雪适配器一致
 * 的写法便于两种格式共用同一套桥接代码）。
 * ========================================================================== */

var __mfModules = {};
var __mfUserVariables = {};
var __mfRuntimeInstalled = true;

/* ------------------------------------------------------------------ *
 * 模块注册表
 * ------------------------------------------------------------------ */

function __mfRegisterModule(name, exportsObject) {
  if (exportsObject === null || exportsObject === undefined) {
    exportsObject = {};
  }
  __mfModules[String(name)] = exportsObject;
  return exportsObject;
}

function __mfRequire(name) {
  var key = name === null || name === undefined ? '' : String(name);
  var normalized = key.replace(/^node:/, '');
  var mod = __mfModules[key];
  if (mod === undefined) mod = __mfModules[normalized];
  if (mod === undefined) {
    // 未提供的依赖返回空对象而不是抛错：MusicFree 官方运行时同样只提供
    // 有限的内置模块，插件通常把这类依赖当作可选能力使用。
    if (typeof console !== 'undefined' && console.log) {
      console.log('[MusicFree] 未提供的模块: ' + key);
    }
    mod = {};
    __mfModules[key] = mod;
  }
  return mod;
}

function __mfExposeRequire() {
  var target = typeof globalThis !== 'undefined' ? globalThis : this;
  target.require = __mfRequire;
  if (typeof window !== 'undefined' && window) window.require = __mfRequire;
}

/* ------------------------------------------------------------------ *
 * 编解码工具
 * ------------------------------------------------------------------ */

function __mfBytesToBase64(bytes) {
  var b = bytes || [];
  var chars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = '';
  for (var i = 0; i < b.length; i += 3) {
    var b0 = b[i] & 0xff;
    var b1 = i + 1 < b.length ? b[i + 1] & 0xff : -1;
    var b2 = i + 2 < b.length ? b[i + 2] & 0xff : -1;
    out += chars.charAt(b0 >> 2);
    out += chars.charAt(((b0 & 3) << 4) | (b1 >= 0 ? b1 >> 4 : 0));
    out += b1 >= 0 ? chars.charAt(((b1 & 15) << 2) | (b2 >= 0 ? b2 >> 6 : 0)) : '=';
    out += b2 >= 0 ? chars.charAt(b2 & 63) : '=';
  }
  return out;
}

function __mfBase64ToBytes(input) {
  var text = String(input || '').replace(/[^A-Za-z0-9+/=]/g, '');
  var chars =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = [];
  var buffer = 0;
  var bits = 0;
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i);
    if (ch === '=') break;
    var value = chars.indexOf(ch);
    if (value < 0) continue;
    buffer = (buffer << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push((buffer >> bits) & 0xff);
    }
  }
  return out;
}

function __mfUtf8Encode(text) {
  var str = String(text === null || text === undefined ? '' : text);
  if (typeof __stringToBytes === 'function') {
    try {
      return __stringToBytes(str);
    } catch (e) {}
  }
  var bytes = [];
  for (var i = 0; i < str.length; i++) {
    var code = str.charCodeAt(i);
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code >= 0xd800 && code < 0xe000) {
      // 代理对：与低代理项组合成完整码点
      var next = i + 1 < str.length ? str.charCodeAt(i + 1) : 0;
      if (code < 0xdc00 && next >= 0xdc00 && next < 0xe000) {
        var point = (code - 0xd800) * 0x400 + (next - 0xdc00) + 0x10000;
        i++;
        bytes.push(
          0xf0 | (point >> 18),
          0x80 | ((point >> 12) & 0x3f),
          0x80 | ((point >> 6) & 0x3f),
          0x80 | (point & 0x3f)
        );
        continue;
      }
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      bytes.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return bytes;
}

function __mfUtf8Decode(bytes) {
  var b = bytes || [];
  var out = '';
  var i = 0;
  while (i < b.length) {
    var c = b[i++] & 0xff;
    if (c < 0x80) {
      out += String.fromCharCode(c);
    } else if (c >= 0xc0 && c < 0xe0) {
      out += String.fromCharCode(((c & 0x1f) << 6) | (b[i++] & 0x3f));
    } else if (c >= 0xe0 && c < 0xf0) {
      out += String.fromCharCode(
        ((c & 0x0f) << 12) | ((b[i++] & 0x3f) << 6) | (b[i++] & 0x3f)
      );
    } else {
      var point =
        ((c & 0x07) << 18) |
        ((b[i++] & 0x3f) << 12) |
        ((b[i++] & 0x3f) << 6) |
        (b[i++] & 0x3f);
      point -= 0x10000;
      out += String.fromCharCode(0xd800 + (point >> 10), 0xdc00 + (point & 0x3ff));
    }
  }
  return out;
}

function __mfLatin1String(bytes) {
  var b = bytes || [];
  var out = '';
  for (var i = 0; i < b.length; i++) {
    out += String.fromCharCode(b[i] & 0xff);
  }
  return out;
}

/* ------------------------------------------------------------------ *
 * 全局垫片
 * ------------------------------------------------------------------ */

var __mfGlobal = typeof globalThis !== 'undefined' ? globalThis : this;

if (typeof __mfGlobal.btoa !== 'function') {
  __mfGlobal.btoa = function (input) {
    return __mfBytesToBase64(__mfLatin1Bytes(String(input)));
  };
}

if (typeof __mfGlobal.atob !== 'function') {
  __mfGlobal.atob = function (input) {
    return __mfLatin1String(__mfBase64ToBytes(input));
  };
}

function __mfLatin1Bytes(text) {
  var bytes = [];
  for (var i = 0; i < text.length; i++) bytes.push(text.charCodeAt(i) & 0xff);
  return bytes;
}

if (typeof __mfGlobal.TextEncoder !== 'function') {
  __mfGlobal.TextEncoder = function () {};
  __mfGlobal.TextEncoder.prototype.encode = function (text) {
    return __mfUtf8Encode(text);
  };
  __mfGlobal.TextEncoder.prototype.encodeInto = function (text, target) {
    var bytes = __mfUtf8Encode(text);
    for (var i = 0; i < bytes.length && i < target.length; i++) target[i] = bytes[i];
    return { read: String(text).length, written: bytes.length };
  };
}

if (typeof __mfGlobal.TextDecoder !== 'function') {
  __mfGlobal.TextDecoder = function () {};
  __mfGlobal.TextDecoder.prototype.decode = function (bytes) {
    if (bytes === null || bytes === undefined) return '';
    if (typeof bytes === 'string') return bytes;
    return __mfUtf8Decode(bytes);
  };
}

if (typeof __mfGlobal.URLSearchParams !== 'function') {
  __mfGlobal.URLSearchParams = function (init) {
    this._entries = [];
    var self = this;
    if (typeof init === 'string') {
      var query = init.charAt(0) === '?' ? init.substring(1) : init;
      if (query) {
        var parts = query.split('&');
        for (var i = 0; i < parts.length; i++) {
          if (!parts[i]) continue;
          var eq = parts[i].indexOf('=');
          var key = eq >= 0 ? parts[i].substring(0, eq) : parts[i];
          var value = eq >= 0 ? parts[i].substring(eq + 1) : '';
          try {
            self._entries.push([__mfDecodeUri(key), __mfDecodeUri(value)]);
          } catch (e) {
            self._entries.push([key, value]);
          }
        }
      }
    } else if (init && typeof init === 'object') {
      var keys = Object.keys(init);
      for (var k = 0; k < keys.length; k++) {
        var v = init[keys[k]];
        if (Array.isArray(v)) {
          for (var j = 0; j < v.length; j++) self._entries.push([keys[k], String(v[j])]);
        } else {
          self._entries.push([keys[k], String(v)]);
        }
      }
    }
    this._init = true;
  };
  __mfGlobal.URLSearchParams.prototype.get = function (name) {
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === name) return this._entries[i][1];
    }
    return null;
  };
  __mfGlobal.URLSearchParams.prototype.getAll = function (name) {
    var out = [];
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] === name) out.push(this._entries[i][1]);
    }
    return out;
  };
  __mfGlobal.URLSearchParams.prototype.has = function (name) {
    return this.get(name) !== null;
  };
  __mfGlobal.URLSearchParams.prototype.set = function (name, value) {
    this['delete'](name);
    this._entries.push([String(name), String(value)]);
  };
  __mfGlobal.URLSearchParams.prototype['delete'] = function (name) {
    var out = [];
    for (var i = 0; i < this._entries.length; i++) {
      if (this._entries[i][0] !== name) out.push(this._entries[i]);
    }
    this._entries = out;
  };
  __mfGlobal.URLSearchParams.prototype.append = function (name, value) {
    this._entries.push([String(name), String(value)]);
  };
  __mfGlobal.URLSearchParams.prototype.toString = function () {
    var parts = [];
    for (var i = 0; i < this._entries.length; i++) {
      parts.push(
        encodeURIComponent(this._entries[i][0]) +
          '=' +
          encodeURIComponent(this._entries[i][1])
      );
    }
    return parts.join('&');
  };
  __mfGlobal.URLSearchParams.prototype.forEach = function (callback, thisArg) {
    for (var i = 0; i < this._entries.length; i++) {
      callback.call(thisArg, this._entries[i][1], this._entries[i][0], this);
    }
  };
  __mfGlobal.URLSearchParams.prototype.keys = function () {
    var out = [];
    for (var i = 0; i < this._entries.length; i++) out.push(this._entries[i][0]);
    return out;
  };
}

function __mfDecodeUri(text) {
  try {
    return decodeURIComponent(String(text).replace(/\+/g, ' '));
  } catch (e) {
    return String(text);
  }
}

if (typeof __mfGlobal.URL !== 'function') {
  __mfGlobal.URL = function (url, base) {
    var raw = String(url === null || url === undefined ? '' : url);
    if (base && !/^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(raw)) {
      var baseMatch = /^([a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^/?#]*)([^?#]*)/.exec(String(base));
      if (baseMatch) {
        var prefix = baseMatch[1];
        var dir = baseMatch[2] || '/';
        if (raw.charAt(0) === '/') {
          raw = prefix + raw;
        } else {
          raw =
            prefix +
            (dir.charAt(dir.length - 1) === '/' ? dir : dir.replace(/[^/]*$/, '')) +
            raw;
        }
      }
    }
    var match = /^([a-zA-Z][a-zA-Z0-9+.-]*:)?(\/\/[^/?#]*)?([^?#]*)(\?[^#]*)?(#.*)?$/.exec(raw) || [];
    this.href = raw;
    this.protocol = match[1] || '';
    var authority = match[2] || '';
    this.host = authority.replace(/^\/\//, '');
    this.hostname = this.host.replace(/:\d+$/, '');
    this.port = (/:(\d+)$/.exec(this.host) || ['', ''])[1];
    this.pathname = match[3] || (authority ? '/' : '');
    this.search = match[4] || '';
    this.hash = match[5] || '';
    this.origin = this.protocol ? this.protocol + authority : '';
    this.searchParams = new __mfGlobal.URLSearchParams(this.search);
  };
  __mfGlobal.URL.prototype.toString = function () {
    return this.href;
  };
  __mfGlobal.URL.prototype.toJSON = function () {
    return this.href;
  };
}

if (typeof __mfGlobal.localStorage === 'undefined') {
  var __mfStorage = {};
  __mfGlobal.localStorage = {
    getItem: function (key) {
      var value = __mfStorage[String(key)];
      return value === undefined ? null : value;
    },
    setItem: function (key, value) {
      __mfStorage[String(key)] = String(value);
    },
    removeItem: function (key) {
      delete __mfStorage[String(key)];
    },
    clear: function () {
      __mfStorage = {};
    },
    key: function (index) {
      return Object.keys(__mfStorage)[index] || null;
    },
  };
  Object.defineProperty(__mfGlobal.localStorage, 'length', {
    get: function () {
      return Object.keys(__mfStorage).length;
    },
  });
}

if (typeof __mfGlobal.crypto === 'undefined') {
  __mfGlobal.crypto = {
    getRandomValues: function (array) {
      for (var i = 0; i < array.length; i++) {
        array[i] = Math.floor(Math.random() * 256);
      }
      return array;
    },
    randomUUID: function () {
      var hex = '0123456789abcdef';
      var out = '';
      for (var i = 0; i < 32; i++) out += hex.charAt(Math.floor(Math.random() * 16));
      return (
        out.substring(0, 8) +
        '-' +
        out.substring(8, 12) +
        '-4' +
        out.substring(13, 16) +
        '-a' +
        out.substring(17, 20) +
        '-' +
        out.substring(20)
      );
    },
  };
}

/* ------------------------------------------------------------------ *
 * process / env（MusicFree 插件通过 env.getUserVariables() 读取用户配置）
 * ------------------------------------------------------------------ */

if (typeof __mfGlobal.process === 'undefined') {
  __mfGlobal.process = {
    env: {},
    platform: 'win32',
    version: 'v18.0.0',
    versions: { node: '18.0.0' },
    nextTick: function (callback) {
      if (typeof __mintSafeSetTimeout === 'function') {
        return __mintSafeSetTimeout(callback, 0);
      }
      return setTimeout(callback, 0);
    },
    cwd: function () {
      return '/';
    },
  };
}

var env = {
  getUserVariables: function () {
    return __mfUserVariables || {};
  },
  userVariables: __mfUserVariables,
  os: 'windows',
};

if (typeof __mfGlobal.console === 'undefined') {
  __mfGlobal.console = { log: function () {}, warn: function () {}, error: function () {}, info: function () {}, debug: function () {} };
}

/* ------------------------------------------------------------------ *
 * axios 适配层：把 axios 语义映射到 cerumusic.request 桥
 *
 * 需要兼容的调用形式：
 *   axios({ url, method, params, data, headers })
 *   axios.get(url, config) / .post(url, data, config) / .put / .delete / .patch / .head
 *   axios.create(config)            —— 插件里常见的实例化写法
 *   axios.defaults.headers.common   —— 少数插件会写默认请求头
 *   axios.interceptors.request/response.use  —— 少量插件用于统一处理 cookie
 * 返回值：{ data, status, statusText, headers, config, request }
 * ------------------------------------------------------------------ */

function __mfMergeConfig(base, override) {
  var result = {};
  var key;
  for (key in base) {
    if (Object.prototype.hasOwnProperty.call(base, key)) result[key] = base[key];
  }
  if (override) {
    for (key in override) {
      if (!Object.prototype.hasOwnProperty.call(override, key)) continue;
      if (override[key] === undefined) continue;
      result[key] = override[key];
    }
  }
  // headers 需要合并而不是整体覆盖
  var headers = {};
  var headerSources = [base ? base.headers : null, override ? override.headers : null];
  for (var i = 0; i < headerSources.length; i++) {
    var source = headerSources[i];
    if (!source) continue;
    for (key in source) {
      if (!Object.prototype.hasOwnProperty.call(source, key)) continue;
      var value = source[key];
      if (value && typeof value === 'object' && !Array.isArray(value)) {
        headers[key] = __mfMergeConfig(headers[key] || {}, value);
        if (key === 'common') {
          // 常见写法：axios.defaults.headers.common 需要在所有请求上生效
          for (var commonKey in value) {
            if (Object.prototype.hasOwnProperty.call(value, commonKey)) {
              if (headers[commonKey] === undefined) headers[commonKey] = value[commonKey];
            }
          }
        }
      } else if (value !== undefined) {
        headers[key] = value;
      }
    }
  }
  result.headers = headers;
  return result;
}

function __mfMethodHeaders(headers, method) {
  var lower = String(method || 'get').toLowerCase();
  var methodDefaults = headers[lower];
  if (methodDefaults && typeof methodDefaults === 'object') {
    for (var key in methodDefaults) {
      if (Object.prototype.hasOwnProperty.call(methodDefaults, key)) {
        if (headers[key] === undefined) headers[key] = methodDefaults[key];
      }
    }
  }
  for (var name in headers) {
    if (!Object.prototype.hasOwnProperty.call(headers, name)) continue;
    var value = headers[name];
    if (value === null || value === undefined || typeof value === 'object' || typeof value === 'function') {
      delete headers[name];
    }
  }
  return headers;
}

function __mfSerializeParams(params, serializer) {
  if (serializer) {
    try {
      if (typeof serializer === 'function') return serializer(params);
      if (typeof serializer.serialize === 'function') return serializer.serialize(params);
    } catch (e) {}
  }
  var parts = [];
  function append(key, value) {
    if (value === null || value === undefined) return;
    if (Array.isArray(value)) {
      for (var i = 0; i < value.length; i++) append(key + '[]', value[i]);
      return;
    }
    if (typeof value === 'object') {
      for (var k in value) {
        if (Object.prototype.hasOwnProperty.call(value, k)) append(key + '[' + k + ']', value[k]);
      }
      return;
    }
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
  }
  for (var key in params) {
    if (Object.prototype.hasOwnProperty.call(params, key)) append(key, params[key]);
  }
  return parts.join('&');
}

function __mfBuildUrl(config) {
  var url = String(config.url === null || config.url === undefined ? '' : config.url);
  var baseURL = config.baseURL ? String(config.baseURL) : '';
  if (baseURL && !/^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(url)) {
    url = baseURL.replace(/\/+$/, '') + (url.charAt(0) === '/' ? '' : '/') + url;
  }
  var params = config.params;
  var query = '';
  if (params && typeof params === 'object') {
    query = __mfSerializeParams(params, config.paramsSerializer);
  } else if (typeof params === 'string') {
    query = params.replace(/^\?/, '');
  }
  if (query) url += (url.indexOf('?') >= 0 ? '&' : '?') + query;
  return url;
}

function __mfPrepareBody(config, headers) {
  var data = config.data;
  if (data === null || data === undefined) return null;
  if (typeof data === 'string') {
    if (!__mfHasHeader(headers, 'content-type')) {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
    }
    return data;
  }
  if (Array.isArray(data) || data instanceof Uint8Array || (typeof ArrayBuffer !== 'undefined' && data instanceof ArrayBuffer)) {
    var bytes = Array.isArray(data)
      ? data
      : data instanceof Uint8Array
        ? Array.prototype.slice.call(data)
        : Array.prototype.slice.call(new Uint8Array(data));
    config._bodyBase64 = __mfBytesToBase64(bytes);
    return null;
  }
  if (typeof data === 'object') {
    if (!__mfHasHeader(headers, 'content-type')) {
      headers['Content-Type'] = 'application/json;charset=utf-8';
    }
    return data;
  }
  return String(data);
}

function __mfHasHeader(headers, name) {
  var lower = String(name).toLowerCase();
  for (var key in headers) {
    if (Object.prototype.hasOwnProperty.call(headers, key) && String(key).toLowerCase() === lower) {
      return true;
    }
  }
  return false;
}

function __mfNormalizeHeaders(headers) {
  var out = {};
  if (!headers || typeof headers !== 'object') return out;
  for (var key in headers) {
    if (!Object.prototype.hasOwnProperty.call(headers, key)) continue;
    var value = headers[key];
    if (value === null || value === undefined) continue;
    if (Array.isArray(value)) value = value.join(', ');
    out[String(key).toLowerCase()] = String(value);
  }
  return out;
}

function __mfAxiosError(message, config, response) {
  var error = new Error(message);
  error.isAxiosError = true;
  error.config = config;
  if (response) {
    error.response = response;
    error.status = response.status;
  }
  return error;
}

function __mfParseResponseData(raw, responseType) {
  var bodyText = typeof raw.body === 'string' ? raw.body : raw.body === null || raw.body === undefined ? '' : String(raw.body);
  if (responseType === 'arraybuffer' || responseType === 'blob') {
    return __mfBase64ToBytes(raw.bodyBase64 || '');
  }
  if (responseType === 'text' || responseType === 'stream') return bodyText;
  if (!bodyText) return '';
  try {
    return JSON.parse(bodyText);
  } catch (e) {
    return bodyText;
  }
}

function __mfCreateAxios(initialConfig) {
  var defaults = __mfMergeConfig(
    {
      baseURL: '',
      timeout: 15000,
      responseType: 'json',
      maxRedirects: 5,
      headers: { common: {}, get: {}, post: {}, put: {}, delete: {}, patch: {}, head: {} },
    },
    initialConfig || {}
  );

  var requestInterceptors = [];
  var responseInterceptors = [];

  function dispatch(config) {
    var method = String(config.method || 'get').toUpperCase();
    var headers = __mfMethodHeaders(__mfNormalizeHeaders(config.headers), String(config.method || 'get').toLowerCase());
    var url = __mfBuildUrl(config);
    if (!url) {
      return Promise.reject(__mfAxiosError('axios: 缺少请求地址', config, null));
    }
    var body = __mfPrepareBody(config, headers);
    var options = {
      method: method,
      headers: headers,
      timeout: typeof config.timeout === 'number' && config.timeout > 0 ? config.timeout : defaults.timeout,
      follow_max: config.maxRedirects === undefined ? defaults.maxRedirects : config.maxRedirects,
    };
    if (body !== null) options.body = body;
    if (config._bodyBase64) options.bodyBase64 = config._bodyBase64;
    if (config.form && typeof config.form === 'object') options.form = config.form;

    return new Promise(function (resolve, reject) {
      var promise;
      try {
        promise = cerumusic.request(url, options);
      } catch (e) {
        reject(__mfAxiosError('axios: 请求发送失败 ' + e, config, null));
        return;
      }
      Promise.resolve(promise).then(
        function (raw) {
          var status = raw && raw.statusCode ? raw.statusCode : 200;
          var validate = config.validateStatus;
          var ok = typeof validate === 'function'
            ? validate(status)
            : status >= 200 && status < 300;
          var response = {
            data: __mfParseResponseData(raw || {}, config.responseType || defaults.responseType),
            status: status,
            statusText: raw && raw.statusMessage ? raw.statusMessage : '',
            headers: (raw && raw.headers) || {},
            config: config,
            request: {},
          };
          if (!ok) {
            reject(__mfAxiosError('Request failed with status code ' + status, config, response));
            return;
          }
          resolve(response);
        },
        function (error) {
          reject(__mfAxiosError('axios: ' + (error && error.message ? error.message : error), config, null));
        }
      );
    });
  }

  function request(configOrUrl, maybeConfig) {
    var config;
    if (typeof configOrUrl === 'string') {
      config = __mfMergeConfig(maybeConfig || {}, { url: configOrUrl });
    } else {
      config = configOrUrl || {};
    }
    var merged = __mfMergeConfig(defaults, config);
    merged.method = String(merged.method || 'get').toLowerCase();

    var chain = Promise.resolve(merged);
    for (var i = 0; i < requestInterceptors.length; i++) {
      chain = chain.then(requestInterceptors[i].onFulfilled, requestInterceptors[i].onRejected);
    }
    chain = chain.then(dispatch);
    for (var j = 0; j < responseInterceptors.length; j++) {
      chain = chain.then(responseInterceptors[j].onFulfilled, responseInterceptors[j].onRejected);
    }
    return chain;
  }

  function createInstanceAdapter(configOrUrl, maybeConfig) {
    return request(configOrUrl, maybeConfig);
  }

  var methods = ['get', 'delete', 'head', 'options', 'post', 'put', 'patch'];
  for (var m = 0; m < methods.length; m++) {
    (function (method) {
      createInstanceAdapter[method] = function (url, dataOrConfig, maybeConfig) {
        if (method === 'post' || method === 'put' || method === 'patch') {
          return request(
            __mfMergeConfig(maybeConfig || {}, {
              url: url,
              method: method,
              data: dataOrConfig,
            })
          );
        }
        return request(__mfMergeConfig(dataOrConfig || {}, { url: url, method: method }));
      };
    })(methods[m]);
  }

  createInstanceAdapter.request = request;
  createInstanceAdapter.defaults = defaults;
  createInstanceAdapter.interceptors = {
    request: {
      use: function (onFulfilled, onRejected) {
        requestInterceptors.push({ onFulfilled: onFulfilled, onRejected: onRejected });
        return requestInterceptors.length - 1;
      },
      eject: function (id) {
        requestInterceptors[id] = { onFulfilled: null, onRejected: null };
      },
    },
    response: {
      use: function (onFulfilled, onRejected) {
        responseInterceptors.push({ onFulfilled: onFulfilled, onRejected: onRejected });
        return responseInterceptors.length - 1;
      },
      eject: function (id) {
        responseInterceptors[id] = { onFulfilled: null, onRejected: null };
      },
    },
  };
  createInstanceAdapter.create = function (config) {
    return __mfCreateAxios(__mfMergeConfig(defaults, config || {}));
  };
  createInstanceAdapter.all = function (promises) {
    return Promise.all(promises);
  };
  createInstanceAdapter.spread = function (callback) {
    return function (values) {
      return callback.apply(null, values);
    };
  };
  createInstanceAdapter.isAxiosError = function (value) {
    return !!(value && value.isAxiosError);
  };
  createInstanceAdapter.CancelToken = function (executor) {
    var self = this;
    this.promise = new Promise(function (resolve) {
      self._resolve = resolve;
    });
    if (typeof executor === 'function') executor(function () {});
  };
  createInstanceAdapter.CancelToken.source = function () {
    var token = new createInstanceAdapter.CancelToken(function () {});
    return { token: token, cancel: function () {} };
  };
  createInstanceAdapter.isCancel = function () {
    return false;
  };
  createInstanceAdapter.AxiosError = function (message, config, response) {
    return __mfAxiosError(message, config, response);
  };
  // MusicFree 运行时把 `default` 指向自身，兼容 `require('axios').default`
  createInstanceAdapter.default = createInstanceAdapter;
  createInstanceAdapter.axios = createInstanceAdapter;

  return createInstanceAdapter;
}

__mfRegisterModule('axios', __mfCreateAxios());

/* ------------------------------------------------------------------ *
 * fetch 垫片（部分插件用原生 fetch）
 * ------------------------------------------------------------------ */

if (typeof __mfGlobal.fetch !== 'function') {
  __mfGlobal.fetch = function (url, options) {
    var opts = options || {};
    var headers = opts.headers || {};
    if (typeof headers.forEach === 'function' && !Array.isArray(headers)) {
      var collected = {};
      headers.forEach(function (value, key) {
        collected[key] = value;
      });
      headers = collected;
    }
    var requestOptions = {
      method: String(opts.method || 'GET').toUpperCase(),
      headers: __mfNormalizeHeaders(headers),
      timeout: 15000,
    };
    if (opts.body !== undefined && opts.body !== null) {
      requestOptions.body = opts.body;
    }
    return Promise.resolve(cerumusic.request(String(url), requestOptions)).then(function (raw) {
      var status = raw && raw.statusCode ? raw.statusCode : 200;
      var bodyText = raw && typeof raw.body === 'string' ? raw.body : '';
      var responseHeaders = __mfNormalizeHeaders(raw && raw.headers);
      return {
        ok: status >= 200 && status < 300,
        status: status,
        statusText: raw && raw.statusMessage ? raw.statusMessage : '',
        url: String(url),
        headers: {
          get: function (name) {
            var value = responseHeaders[String(name).toLowerCase()];
            return value === undefined ? null : value;
          },
          has: function (name) {
            return responseHeaders[String(name).toLowerCase()] !== undefined;
          },
        },
        text: function () {
          return Promise.resolve(bodyText);
        },
        json: function () {
          return Promise.resolve(JSON.parse(bodyText));
        },
        arrayBuffer: function () {
          return Promise.resolve(__mfBase64ToBytes(raw && raw.bodyBase64 ? raw.bodyBase64 : ''));
        },
      };
    });
  };
}

__mfExposeRequire();
