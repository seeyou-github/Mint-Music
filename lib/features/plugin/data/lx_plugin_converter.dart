import 'dart:convert';

import '../domain/plugin_types.dart';

class LxPluginConverter {
  /// 平台 id → 展示名。
  ///
  /// 与 `SourceIdMapping.idToName` 保持一致：适配器上报的音源名要能被
  /// 宿主还原成平台 id，否则音源选择器里会出现一堆无法识别的音源。
  static const Map<String, String> _platformNames = {
    'kw': '酷我音乐',
    'wy': '网易云音乐',
    'tx': 'QQ音乐',
    'kg': '酷狗音乐',
    'mg': '咪咕音乐',
    'qsvip': '汽水VIP',
  };

  /// 静态分析时能够识别的平台 id。
  static const Set<String> _knownPlatformIds = {
    'kw',
    'wy',
    'tx',
    'kg',
    'mg',
    'qsvip',
  };

  /// 静态分析完全失败时的兜底平台（落雪脚本几乎都覆盖这几个平台）。
  static const List<String> _fallbackPlatformIds = [
    'kw',
    'wy',
    'tx',
    'kg',
    'mg',
  ];

  /// 静态分析识别不出音质时的默认音质。
  static const List<String> _defaultQualities = ['128k', '320k', 'flac'];

  String convert(String originalCode) {
    final info = _parseScriptInfo(originalCode);
    final pluginInfoJson = jsonEncode(info);
    final inferredSourcesJson = jsonEncode(_inferSources(originalCode));
    final platformNamesJson = jsonEncode(_platformNames);

    return '''
var __lxInitError = null;
var __lxInitDone = false;
var __lxInitReported = false;
var __lxRequestHandler = null;
var __lxUpdateAlertSent = false;
var __lxFallbackTimerIdCounter = 0;
// 插件是否已经上报过 inited 事件（上报后音源列表才是插件自己声明的）。
var __lxInited = false;

var pluginInfo = $pluginInfoJson;
// The original LX source is executed by PluginHost in a separate evaluate()
// call. Keeping it out of this adapter avoids a large string literal and a
// nested new Function compilation inside QuickJS.
var originalPluginCode = '';
// 静态推断出来的音源（脚本里能直接看出来的平台与音质）。
var __lxInferredSources = $inferredSourcesJson;
// 平台 id → 展示名，用于给没有 name 字段的音源补上可读的名字。
var __lxPlatformNames = $platformNamesJson;
var sources = {};
var sourceActions = {};

// 用户为插件填写的凭据（cookie / api key / 卡密），由宿主在执行插件代码前
// 通过全局 `__lxUserVariablesRaw` 预注入；插件用 lx.getUserVariables() 读取。
// 里面是敏感信息，不要写进日志、也不要塞进 rawScript。
var __lxUserVariables = (typeof __lxUserVariablesRaw !== 'undefined' && __lxUserVariablesRaw) || {};

// 插件通过 lx.send('loginStatus', ...) 主动上报的登录态，宿主加载完成后读走。
var __lxLoginStates = {};

function __lxSetUserVariables(values) {
  __lxUserVariables = {};
  if (values && typeof values === 'object') {
    Object.keys(values).forEach(function(key) {
      var value = values[key];
      if (value == null) return;
      __lxUserVariables[key] = String(value);
    });
  }
  // currentScriptInfo 与 getUserVariables() 必须指向同一份数据，
  // 否则老插件在 settings 变更后读到的还是旧凭据。
  try {
    if (typeof mockLx === 'object' && mockLx.currentScriptInfo) {
      mockLx.currentScriptInfo.userVariables = __lxUserVariables;
    }
  } catch(e) {}
}

function __lxRecordLoginState(data) {
  if (!data || typeof data !== 'object') return;
  var sourceId = data.source || data.sourceId;
  var state = data.state || data.status || data.login;
  if (!sourceId || !state) return;
  __lxLoginStates[String(sourceId)] = {
    state: String(state),
    account: data.account || data.nickname || ''
  };
}

function __lxPlatformName(sourceId) {
  if (__lxPlatformNames[sourceId]) return __lxPlatformNames[sourceId];
  return sourceId;
}

// 先用静态推断的音源占位：落雪脚本的音源列表通常在运行时从作者的服务器
// 拉取，服务器不可达时插件不会上报 inited 事件，宿主就会认为「插件没有
// 声明任何音源」。运行时上报的列表仍然会覆盖这里的结果。
(function() {
  Object.keys(__lxInferredSources).forEach(function(sourceId) {
    var qualities = __lxInferredSources[sourceId] || [];
    sources[sourceId] = {
      name: __lxPlatformName(sourceId),
      type: 'music',
      qualitys: qualities,
      qualities: qualities,
      actions: ['musicUrl']
    };
    sourceActions[sourceId] = ['musicUrl'];
  });
})();

// Some LX scripts validate the runtime metadata against their canonical name
// instead of the display name in the file header (for example, YNX-Pro).
function __lxCanonicalScriptName(value) {
  var name = String(value || '').replace(/^\\uFEFF/, '').trim();
  // Keep this ASCII-only so generated code is not affected by source encoding.
  return name.replace(/-pro${r'$'}/i, '');
}

var __lxRuntimeScriptName = __lxCanonicalScriptName(pluginInfo.name);

var EVENT_NAMES = {
  request: 'request',
  inited: 'inited',
  updateAlert: 'updateAlert'
};

function __lxSafeError(error) {
  if (!error) return 'failed';
  return error.message || String(error);
}

function __lxParseBody(value) {
  if (typeof value !== 'string') return value;
  try { return JSON.parse(value); } catch(e) { return value; }
}

function __lxBytesFromString(text) {
  if (typeof __stringToBytes === 'function') return __stringToBytes(String(text || ''));
  var arr = [];
  text = String(text || '');
  for (var i = 0; i < text.length; i++) arr.push(text.charCodeAt(i) & 0xff);
  return arr;
}

function __lxEncodeForm(form) {
  if (!form || typeof form !== 'object') return form;
  var parts = [];
  Object.keys(form).forEach(function(key) {
    var value = form[key];
    if (value == null) value = '';
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(String(value)));
  });
  return parts.join('&');
}

function __lxNormalizeSources(data) {
  var nextSources = data && data.sources ? data.sources : data;
  if (!nextSources || typeof nextSources !== 'object') return;
  // 插件没有上报音源列表（有些脚本 inited 时只发状态信息）：保留静态推断
  // 出来的音源，避免插件变成「没有声明任何音源」。
  if (!Object.keys(nextSources).length) return;
  Object.keys(sources).forEach(function(k) { delete sources[k]; });
  Object.keys(sourceActions).forEach(function(k) { delete sourceActions[k]; });
  Object.keys(nextSources).forEach(function(sourceId) {
    var item = nextSources[sourceId] || {};
    var qualities = item.qualitys || item.qualities || item.types || ['128k', '320k', 'flac'];
    var actions = item.actions || ['musicUrl'];
    var normalized = {
      name: item.name || __lxPlatformName(sourceId),
      type: item.type || 'music',
      qualitys: qualities,
      qualities: qualities,
      actions: actions
    };
    // 协议扩展字段（downloadQualitys / login / credentials）必须原样透传给
    // 宿主，否则宿主读不到「下载音质」和「登录门槛」，界面会退回显示全部档位。
    var downloadQualitys = item.downloadQualitys || item.downloadQualities;
    if (downloadQualitys) normalized.downloadQualitys = downloadQualitys;
    if (item.login && typeof item.login === 'object') normalized.login = item.login;
    if (item.credentials && item.credentials.length) normalized.credentials = item.credentials;
    sources[sourceId] = normalized;
     sourceActions[sourceId] = (actions.slice ? actions.slice() : ['musicUrl'])
       .map(function(action) { return String(action).toLowerCase(); });
  });
}

function __lxEventName(value) {
  return String(value || '').replace(/^lx[._:-]/i, '').toLowerCase();
}

function __lxHasAction(source, action) {
  var actions = sourceActions[source];
  if (!actions && sources[source]) return action === 'musicUrl';
  if (!actions) return false;
  return actions.indexOf(action) !== -1 || actions.indexOf(String(action).toLowerCase()) !== -1;
}

function __lxNormalizeMusicUrlResult(response, payload) {
  var responseKeys = ['url', 'src', 'playUrl', 'play_url', 'location', 'audioUrl', 'audio_url', 'data', 'body', 'result', 'response'];
  var qualityAliases = ${jsonEncode(musicQualityAliases)};
  var qualityTypes = ${jsonEncode(musicQualityTypes)};

  function qualityKey(value) {
    var key = String(value).trim().toLowerCase();
    return Object.prototype.hasOwnProperty.call(qualityAliases, key) ? qualityAliases[key] : key;
  }

  function parseNested(value) {
    while (typeof value === 'string') {
      var text = value.trim();
      if (!text) return text;
      try { value = JSON.parse(text); } catch(e) { return text; }
    }
    return value;
  }

  function findUrl(value) {
    value = parseNested(value);
    if (typeof value === 'string') {
      return /^https?:\\/\\//i.test(value) ? value : '';
    }
    if (!value || typeof value !== 'object') return '';
    for (var i = 0; i < responseKeys.length; i++) {
      var nested = findUrl(value[responseKeys[i]]);
      if (nested) return nested;
    }
    if (Array.isArray(value)) {
      for (var j = 0; j < value.length; j++) {
        var item = findUrl(value[j]);
        if (item) return item;
      }
    }
    var error = value.error != null ? value.error : value.message;
    if (error != null) throw new Error(String(error));
    return '';
  }

  var reportedQuality = '';
  var requestedKey = qualityKey(payload.info.type);
  function validateQuality(value) {
    value = parseNested(value);
    if (!value || typeof value !== 'object') return;
    // format describes a container, not a quality (hires can use flac).
    ['quality', 'level', 'type'].forEach(function(key) {
      var candidate = value[key];
      if (typeof candidate !== 'string' && typeof candidate !== 'number') return;
      var label = String(candidate).trim();
      if (!label) return;
      var normalized = qualityKey(label);
      if (key === 'type' && !/^\\d{2,4}k${r'$'}/.test(normalized) && qualityTypes.indexOf(normalized) === -1) return;
      if (normalized !== requestedKey) {
        throw new Error('音质不匹配：请求 ' + payload.info.type + '，插件返回 ' + label + '，已拒绝替换音质');
      }
      if (!reportedQuality) reportedQuality = label;
    });
    // Do not stop at the first label or URL: every branch must agree.
    responseKeys.forEach(function(key) { validateQuality(value[key]); });
    if (Array.isArray(value)) value.forEach(validateQuality);
  }

  function findHeaders(value) {
    value = parseNested(value);
    var headers = {};
    if (!value || typeof value !== 'object') return headers;
    ['requestHeaders', 'httpHeaders', 'headers'].forEach(function(key) {
      var current = value[key];
      if (current && typeof current === 'object' && !Array.isArray(current)) {
        Object.keys(current).forEach(function(header) {
          if (current[header] != null && String(current[header]).trim()) headers[header] = String(current[header]);
        });
      }
    });
    function merge(nestedValue) {
      var nested = findHeaders(nestedValue);
      Object.keys(nested).forEach(function(header) { headers[header] = nested[header]; });
    }
    ['data', 'body', 'result', 'response'].forEach(function(key) { merge(value[key]); });
    if (Array.isArray(value)) value.forEach(merge);
    return headers;
  }

  var url = findUrl(response);
  if (url) {
    validateQuality(response);
    // An absent label inherits the request, not a verified media bitrate.
    var type = reportedQuality || payload.info.type;
    var normalized = { source: payload.source, action: payload.action, data: { type: type, url: url } };
    var headers = findHeaders(response);
    if (Object.keys(headers).length) normalized.headers = headers;
    return normalized;
  }
  throw new Error('Plugin returned an invalid musicUrl result');
}

function __lxNormalizeSearchResult(response, limit) {
  if (typeof response === 'string') {
    try { response = JSON.parse(response); } catch(e) { return { list: [], total: 0, isEnd: true }; }
  }
  if (!response) return { list: [], total: 0, isEnd: true };
  if (Array.isArray(response)) return { list: response, total: response.length, isEnd: response.length < limit };
  var data = response.data || {};
  var list = response.list || response.lists || data.list || data.lists || data.data || [];
  if (!Array.isArray(list)) list = [];
  var total = response.total || response.totalCount || data.total || list.length;
  return { list: list, total: total, isEnd: response.isEnd === true || list.length < limit };
}

function __lxNormalizeLyricResult(response) {
  if (typeof response === 'string') {
    try { return JSON.parse(response); } catch(e) { return response; }
  }
  if (!response) return null;
  if (response.body && typeof response.body === 'object') return response.body;
  return response;
}

function __lxNormalizePicResult(response) {
  if (typeof response === 'string') return response;
  if (!response) return null;
  var data = response.data || response.body || {};
  return response.url || response.pic || response.img || data.url || data.pic || data.img || null;
}

function __lxRequest(url, options, callback) {
  if (typeof options === 'function') {
    callback = options;
    options = {};
  }
  options = options || {};
  var headers = {};
  var optionHeaders = options.headers || {};
  Object.keys(optionHeaders).forEach(function(key) { headers[key] = optionHeaders[key]; });
  var body = options.body;
  if (options.form) {
    if (!headers['content-type'] && !headers['Content-Type']) headers['content-type'] = 'application/x-www-form-urlencoded;charset=UTF-8';
    body = __lxEncodeForm(options.form);
  } else if (options.formData && body == null) {
    body = options.formData;
  }

  var cancelled = false;
  var requestOptions = {
    method: options.method || 'GET',
    headers: headers,
    body: body,
    timeout: typeof options.timeout === 'number' ? options.timeout : 20000,
    follow_max: typeof options.follow_max === 'number' ? options.follow_max : 5
  };

  // Use the two-argument form of then(). Some Android flutter_js builds expose
  // Promise.then() but do not expose Promise.prototype.catch() as a callable.
  var promise = cerumusic.request(url, requestOptions).then(function(result) {
    try {
      // Keep this response bridge self-contained. A few LX scripts modify
      // shared built-ins while bootstrapping, which can turn a converter
      // helper or Object.prototype method into a non-callable value.
      var statusCode = result && (result.statusCode || result.status)
        ? (result.statusCode || result.status) : 200;
      var headers = result && typeof result.headers === 'object' && result.headers
        ? result.headers : {};
      var bodyText = result && typeof result.body !== 'undefined' ? result.body : result;
      var body = bodyText;
      if (typeof bodyText === 'string') {
        try { body = JSON.parse(bodyText); } catch(e) { body = bodyText; }
      }
      var raw = Array.isArray(result && result.raw) ? result.raw : [];
      if (!raw.length && result && typeof result.bodyBase64 === 'string') {
        var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
        var lookup = {};
        for (var ci = 0; ci < chars.length; ci++) lookup[chars[ci]] = ci;
        var encoded = result.bodyBase64;
        for (var bi = 0; bi < encoded.length; bi += 4) {
          var ba = lookup[encoded[bi]] || 0;
          var bb = lookup[encoded[bi + 1]] || 0;
          var bc = lookup[encoded[bi + 2]] || 0;
          var bd = lookup[encoded[bi + 3]] || 0;
          raw.push((ba << 2) | (bb >> 4));
          if (encoded[bi + 2] !== '=') raw.push(((bb & 15) << 4) | (bc >> 2));
          if (encoded[bi + 3] !== '=') raw.push(((bc & 3) << 6) | bd);
        }
      }
      var resp = {
        statusCode: statusCode,
        statusMessage: result && result.statusMessage ? result.statusMessage : String(statusCode),
        headers: headers,
        bytes: raw.length || 0,
        raw: raw,
        body: body
      };
      if (!cancelled && typeof callback === 'function') callback(null, resp, body);
      return resp;
    } catch (error) {
      if (!cancelled && typeof callback === 'function') {
        callback(error instanceof Error ? error : new Error(String(error)), null, null);
        return null;
      }
      throw error;
    }
  }, function(error) {
    if (!cancelled && typeof callback === 'function') {
      callback(error instanceof Error ? error : new Error(__lxSafeError(error)), null, null);
      return null;
    }
    throw error;
  });

  if (callback) {
    return function() { cancelled = true; };
  }
  return promise;
}

  var mockLx = {
  EVENT_NAMES: EVENT_NAMES,
  request: __lxRequest,
  send: function(eventName, data) {
    var normalizedEvent = __lxEventName(eventName);
    if (normalizedEvent === 'inited' || normalizedEvent === 'initialized') {
      // Keep the lifecycle side effect synchronous, but return the Promise
      // required by the mobile LX contract for callers that await or chain it.
      if (__lxInitReported) return Promise.resolve();
      __lxInitReported = true;
      __lxInited = true;
      __lxNormalizeSources(data);
      return Promise.resolve();
    }
    if (normalizedEvent === 'updatealert' || normalizedEvent === 'update') {
      if (!__lxUpdateAlertSent) {
        __lxUpdateAlertSent = true;
        try {
          console.log('[LX Adapter] updateAlert received, data type=' + typeof data + ', data=' + JSON.stringify(data));
          cerumusic.NoticeCenter('update', data);
          console.log('[LX Adapter] updateAlert NoticeCenter sent successfully');
        } catch(e) {
          console.log('[LX Adapter] updateAlert error: ' + e);
        }
      }
      return Promise.resolve();
    }
    // 登录态上报：插件在登录成功 / 失效时主动推，宿主加载后会读走。
    if (normalizedEvent === 'loginstatus' || normalizedEvent === 'login') {
      __lxRecordLoginState(data);
      return Promise.resolve();
    }
    return Promise.reject(new Error('The event is not supported: ' + eventName));
  },
  on: function(eventName, handler) {
    var normalizedEvent = __lxEventName(eventName);
    if ((normalizedEvent === 'request' || normalizedEvent === 'req') && typeof handler === 'function') {
      __lxRequestHandler = handler;
      // Older LX-compatible hosts look up requestHandler as a global. Keep
      // that alias in sync while the converter uses its private reference.
      try {
        var runtimeGlobal = Function('return this')();
        runtimeGlobal.requestHandler = handler;
      } catch(e) {}
      return Promise.resolve();
    }
    return Promise.reject(new Error('The event is not supported: ' + eventName));
  },
  utils: {
    crypto: {
      aesEncrypt: function(buffer, mode, key, iv) { return cerumusic.utils.crypto.aesEncrypt(buffer, mode, key, iv); },
      rsaEncrypt: function(buffer, key) { return cerumusic.utils.crypto.rsaEncrypt(buffer, key); },
      randomBytes: function(size) { return cerumusic.utils.crypto.randomBytes(size); },
      md5: function(value) { return __md5Hash(String(value)); }
    },
    buffer: {
      from: function(value, encodingOrOffset, length) { return Buffer.from(value, encodingOrOffset, length); },
      bufToString: function(buf, format) { return cerumusic.utils.buffer.bufToString(buf, format); }
    },
    zlib: {
      inflate: function(buf) { return cerumusic.utils.zlib.inflate(buf); },
      deflate: function(data) { return cerumusic.utils.zlib.deflate(data); }
    }
  },
  currentScriptInfo: {
    name: __lxRuntimeScriptName,
    version: pluginInfo.version,
    author: pluginInfo.author,
    description: pluginInfo.description || '',
    homepage: pluginInfo.homepage || '',
    rawScript: originalPluginCode,
    // 用户凭据：与 lx.getUserVariables() 同一份，老写法读这里也能拿到。
    userVariables: __lxUserVariables
  },
  // 用户为插件填写的凭据（cookie / api key / 卡密）。没填时返回空对象，
  // 插件侧 `vars.MUSIC_U || ''` 可安全使用。
  getUserVariables: function() { return __lxUserVariables || {}; },
  // Match the API contract used by CeruMusic and LX Music desktop plugins.
  version: '2.0.0',
  apiVersion: '2.0.0',
  env: 'mobile'
};

var lx = mockLx;
try {
  var __realGlobal = Function('return this')();
  __realGlobal.lx = mockLx;
  __realGlobal.window = __realGlobal;
  __realGlobal.self = __realGlobal;
  __realGlobal.globalThis = __realGlobal;
} catch(e) {}

function __lxEnsureReady(action) {
  if (!__lxInitDone) throw new Error('LX 音源尚未完成初始化');
  // A number of legacy scripts register request before a non-critical
  // background check throws. CeruMusic keeps those handlers usable; only a
  // missing handler means the script cannot serve requests.
  if (__lxInitError && !__lxRequestHandler) {
    throw new Error('LX 音源初始化失败: ' + __lxInitError);
  }
  if (!__lxRequestHandler) throw new Error('LX 音源未注册 request 事件');
  if (action && action.source && action.action && !__lxHasAction(action.source, action.action)) {
    throw new Error('LX 音源不支持 ' + action.source + '/' + action.action);
  }
}

function __lxCallRequest(payload) {
  __lxEnsureReady(payload);
  return Promise.resolve(__lxRequestHandler(payload));
}

function musicUrl(source, musicInfo, quality) {
  var payload = { source: source, action: 'musicUrl', info: { type: quality || '320k', musicInfo: musicInfo || {} } };
  return __lxCallRequest(payload).then(function(result) { return __lxNormalizeMusicUrlResult(result, payload); });
}

function search(source, keyword, page, limit) {
  limit = limit || 30;
  var payload = { source: source, action: 'musicSearch', info: { keyword: keyword, page: page || 1, limit: limit, pagesize: limit } };
  if (!__lxHasAction(source, 'musicSearch')) return Promise.resolve({ list: [], total: 0, isEnd: true });
  return __lxCallRequest(payload).then(function(result) { return __lxNormalizeSearchResult(result, limit); }, function() {
    return { list: [], total: 0, isEnd: true };
  });
}

// 主动查询登录态：只有插件在 actions 里声明了 loginStatus 才会真正发请求，
// 其余情况返回 unknown（宿主据此不显示登录徽标，也不会置灰任何音质）。
function requestLoginStatus(source) {
  if (!__lxHasAction(source, 'loginStatus')) {
    return Promise.resolve({ state: 'unknown' });
  }
  return __lxCallRequest({ source: source, action: 'loginStatus', info: {} })
    .then(function(result) {
      if (result && typeof result === 'object') return result;
      return { state: result == null ? 'unknown' : String(result) };
    }, function(error) {
      // 超时 / 插件抛错：返回 unknown，不影响播放。
      return { state: 'unknown', message: __lxSafeError(error) };
    });
}

function getPic(source, musicInfo) {
  var action = __lxHasAction(source, 'musicPic') ? 'musicPic' : (__lxHasAction(source, 'pic') ? 'pic' : null);
  if (!action) return Promise.resolve(null);
  return __lxCallRequest({ source: source, action: action, info: { musicInfo: musicInfo || {} } }).then(__lxNormalizePicResult, function() { return null; });
}

function getLyricResult(source, musicInfo) {
  var action = __lxHasAction(source, 'lyric') ? 'lyric' : (__lxHasAction(source, 'musicLyric') ? 'musicLyric' : null);
  if (!action) return Promise.resolve(null);
  return __lxCallRequest({ source: source, action: action, info: { musicInfo: musicInfo || {} } }).then(__lxNormalizeLyricResult, function() { return null; });
}

function getLyric(source, musicInfo) {
  return getLyricResult(source, musicInfo).then(function(result) {
    if (!result) return null;
    if (typeof result === 'string') return result;
    return result.crlyric || result.lxlyric || result.yrc || result.qrc || result.krc || result.mrc || result.lrcx || result.lyric || result.lrc || null;
  });
}

function initializePluginEnvironment() {
  try {
    // Keep the plugin in a small sandbox. Some Android flutter_js builds expose
    // timer names as non-callable host values on the real global object.
    var __runtimeGlobal = {};
    try { __runtimeGlobal = Function('return this')(); } catch(e) {}
    // Reuse the host's Dart-backed timer bridge. The native flutter_js timer
    // entrypoint is unsafe on some Android/Windows builds and must never be
    // called for a converted LX plugin.
    var __mintSetTimeout = typeof __mintSafeSetTimeout === 'function'
      ? __mintSafeSetTimeout : null;
    var __mintClearTimeout = typeof __mintSafeClearTimeout === 'function'
      ? __mintSafeClearTimeout : null;
    var __mintSetInterval = typeof __mintSafeSetInterval === 'function'
      ? __mintSafeSetInterval : null;
    var __mintClearInterval = typeof __mintSafeClearInterval === 'function'
      ? __mintSafeClearInterval : null;
    var __nativeSetTimeout = __runtimeGlobal && typeof __runtimeGlobal.setTimeout === 'function'
      ? __runtimeGlobal.setTimeout : null;
    var __nativeClearTimeout = __runtimeGlobal && typeof __runtimeGlobal.clearTimeout === 'function'
      ? __runtimeGlobal.clearTimeout : null;
    var __nativeSetInterval = __runtimeGlobal && typeof __runtimeGlobal.setInterval === 'function'
      ? __runtimeGlobal.setInterval : null;
    var __nativeClearInterval = __runtimeGlobal && typeof __runtimeGlobal.clearInterval === 'function'
      ? __runtimeGlobal.clearInterval : null;

    var __lxSetTimeout = function(callback, delay) {
      if (__mintSetTimeout) {
        try { return __mintSetTimeout.apply(null, arguments); } catch(e) {}
      }
      if (__nativeSetTimeout) {
        try { return __nativeSetTimeout.call(__runtimeGlobal, callback, delay); } catch(e) {}
      }
      // There is no asynchronous timer primitive in some flutter_js Android
      // builds. Do not invoke a timeout callback synchronously: that would
      // reject network requests before the Dart HTTP bridge can respond.
      var timerId = ++__lxFallbackTimerIdCounter;
      return timerId;
    };
    var __lxClearTimeout = function(timerId) {
      if (__mintClearTimeout) {
        try { __mintClearTimeout(timerId); return; } catch(e) {}
      }
      if (__nativeClearTimeout) {
        try { __nativeClearTimeout.call(__runtimeGlobal, timerId); } catch(e) {}
      }
    };
    var __lxSetInterval = function(callback, delay) {
      if (__mintSetInterval) {
        try { return __mintSetInterval.apply(null, arguments); } catch(e) {}
      }
      if (__nativeSetInterval) {
        try { return __nativeSetInterval.call(__runtimeGlobal, callback, delay); } catch(e) {}
      }
      var timerId = ++__lxFallbackTimerIdCounter;
      return timerId;
    };
    var __lxClearInterval = function(timerId) {
      if (__mintClearInterval) {
        try { __mintClearInterval(timerId); return; } catch(e) {}
      }
      if (__nativeClearInterval) {
        try { __nativeClearInterval.call(__runtimeGlobal, timerId); } catch(e) {}
      }
    };
    // The original script is evaluated by the host after this environment is
    // ready. Expose the same globals that the former Function wrapper passed
    // as parameters, without compiling the large source as a nested function.
    __runtimeGlobal = Function('return this')();
    __runtimeGlobal.lx = mockLx;
    __runtimeGlobal.setTimeout = __lxSetTimeout;
    __runtimeGlobal.clearTimeout = __lxClearTimeout;
    __runtimeGlobal.setInterval = __lxSetInterval;
    __runtimeGlobal.clearInterval = __lxClearInterval;
    __runtimeGlobal.Buffer = Buffer;
    __runtimeGlobal.process = { env: { NODE_ENV: 'production' } };
    // require：宿主在加载落雪插件前会注入 MusicFree 兼容运行时（含 crypto-js /
    // axios 等模块注册表），此时全局 require 已经是可用实现，不能再覆盖成空实现；
    // 没有运行时（旧路径 / 单独评估适配器）才退回空模块，插件把缺失依赖当可选能力。
    if (typeof __runtimeGlobal.require !== 'function') {
      __runtimeGlobal.require = function() { return {}; };
    }
  } catch(error) {
    __lxInitError = __lxSafeError(error);
    __lxInitDone = true;
    console.log('[LX] 初始化失败: ' + __lxInitError);
  }
}

function __lxFinalizePluginInitialization() {
  __lxInitDone = true;
}

initializePluginEnvironment();

module.exports = {
  pluginInfo: pluginInfo,
  sources: sources,
  sourceActions: sourceActions,
  musicUrl: musicUrl,
  search: search,
  getPic: getPic,
  getLyric: getLyric,
  getLyricResult: getLyricResult,
  // 供宿主主动查询登录态（插件没声明 loginStatus action 时返回 unknown）。
  requestLoginStatus: requestLoginStatus,
  // 宿主注入用户凭据（cookie / api key）；插件通过 lx.getUserVariables() 读取。
  setUserVariables: __lxSetUserVariables,
  // 插件是否已经上报过 inited 事件（宿主据此判断还要不要再等音源列表）。
  isInited: function() { return __lxInited; }
};
''';
  }

  /// 静态分析落雪脚本，推断它支持的平台与音质。
  ///
  /// 落雪脚本的音源列表有三种来源：
  /// 1. 运行时通过 `inited` 事件上报（最常见，内容来自作者的服务器）；
  /// 2. 直接写在脚本里的音源列表字面量（`kw|128k&wy|320k` 这种格式）；
  /// 3. 请求处理里的分支判断（`case 'kw':`、`source === 'kw'`）。
  ///
  /// 第一种依赖作者的服务器，服务器不可达时插件就不会再上报 inited 事件，
  /// 宿主只能得出「插件没有声明任何音源」的结论，插件既无法测试也无法
  /// 出现在音源选择器里。这里对源码做一次静态分析，把能识别出来的平台
  /// 与音质先写进适配器；运行时上报的列表仍然会覆盖推断结果。
  Map<String, List<String>> _inferSources(String code) {
    final decoded = _mergeConcatenations(_decodeStringLiterals(code));

    final ids = <String>{};
    final qualities = <String, List<String>>{};

    // 1) 音源列表字面量：'kw|128k&wy|320k&...'
    for (final match in RegExp(r"'([^'\n]*)'").allMatches(decoded)) {
      final text = match.group(1) ?? '';
      if (!text.contains('|')) continue;
      final parsed = <String, List<String>>{};
      var known = 0;
      for (final group in text.split('&')) {
        final parts = group.split('|');
        if (parts.length < 2) continue;
        final id = parts.first.trim();
        if (!_looksLikeSourceId(id)) continue;
        final list = parts
            .skip(1)
            .map((q) => q.trim())
            .where((q) => q.isNotEmpty)
            .toList();
        // 音质必须是可识别的格式，否则多半是被拆散的字符串碎片。
        if (!list.every(_looksLikeQuality)) continue;
        parsed[id] = list;
        if (_knownPlatformIds.contains(id)) known++;
      }
      // 至少命中一个已知平台才认为是音源列表，避免把普通字符串误判。
      if (known == 0) continue;
      parsed.forEach((id, list) {
        ids.add(id);
        qualities.putIfAbsent(id, () => list);
      });
    }

    // 2) 分支判断：case 'kw': / source === 'kw'
    for (final match in RegExp(r"case\s*'([^'\n]*)'").allMatches(decoded)) {
      final id = match.group(1) ?? '';
      if (_knownPlatformIds.contains(id)) ids.add(id);
    }
    for (final match in RegExp(
      r"source\s*===?\s*'([^'\n]*)'",
    ).allMatches(decoded)) {
      final id = match.group(1) ?? '';
      if (_knownPlatformIds.contains(id)) ids.add(id);
    }

    // 落雪脚本的音源列表通常给所有平台标相同的音质（例如整张列表都是
    // 128k），只要识别出来的音质一致就统一套用到所有平台，避免出现
    // 「一部分平台只有 128k、另一部分却有 flac」的不一致结果。
    final listed = qualities.values.toList();
    final unified =
        listed.length >= 2 &&
        listed.every(
          (q) =>
              q.length == listed.first.length &&
              List<String>.from(q).join() == listed.first.join(),
        );

    // 完全识别不出来时退回常见平台，保证插件仍然可以被测试与选择。
    if (ids.isEmpty) {
      for (final id in _fallbackPlatformIds) {
        ids.add(id);
      }
    }

    final result = <String, List<String>>{};
    for (final id in ids) {
      final list = qualities[id];
      if (list != null && list.isNotEmpty) {
        result[id] = list;
      } else if (unified) {
        result[id] = List<String>.from(listed.first);
      } else {
        result[id] = List<String>.from(_defaultQualities);
      }
    }
    return result;
  }

  /// 音质字符串是否合法（128k / 320k / flac / hires …）。
  static bool _looksLikeQuality(String value) {
    if (RegExp(r'^\d{2,4}k$').hasMatch(value)) return true;
    return const [
      'flac',
      'flac24bit',
      'hires',
      'atmos',
      'master',
      'ape',
      'wav',
      'sq',
      'dsd',
    ].contains(value.toLowerCase());
  }

  /// 平台 id 是否像一个音源标识（短小的字母 / 数字组合）。
  static bool _looksLikeSourceId(String value) {
    return RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,15}$').hasMatch(value);
  }

  /// 把源码里的字符串字面量解码成真实内容（处理 \xNN / \uNNNN 等转义）。
  ///
  /// 混淆过的落雪脚本会把平台 id 写成 `'\\x6b\\x77'` 这种转义形式，
  /// 不解码就没法静态识别出音源。
  String _decodeStringLiterals(String code) {
    final pattern = RegExp(
      r"'((?:[^'\\\n]|\\.)*)'|\x22((?:[^\x22\\\n]|\\.)*)\x22",
    );
    return code.replaceAllMapped(pattern, (match) {
      final single = match.group(1);
      final raw = single ?? match.group(2) ?? '';
      final quote = single != null ? "'" : '"';
      final decoded = _decodeJsEscapes(raw);
      // 解码后的内容里可能带引号，转义回去避免破坏后续的正则匹配。
      return '$quote${decoded.replaceAll("'", r"\'")}$quote';
    });
  }

  /// 合并用 `+` 连接的相邻字符串字面量。
  ///
  /// 音源列表常被拆成 `'kw|128k&wy' + '|128k&mg|1' + ...` 这样拼接起来，
  /// 合并之后才能看出完整的音源列表。
  String _mergeConcatenations(String code) {
    var result = code;
    for (var i = 0; i < 8; i++) {
      final next = result.replaceAllMapped(
        RegExp(r"'([^']*)'\s*\+\s*'([^']*)'"),
        (match) => "'${match.group(1)}${match.group(2)}'",
      );
      if (next == result) break;
      result = next;
    }
    return result;
  }

  /// 解码 JS 字符串转义序列。
  String _decodeJsEscapes(String raw) {
    final buffer = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final ch = raw[i];
      if (ch != r'\' || i + 1 >= raw.length) {
        buffer.write(ch);
        continue;
      }
      final next = raw[++i];
      if (next == 'x' && i + 2 < raw.length) {
        final code = int.tryParse(raw.substring(i + 1, i + 3), radix: 16);
        if (code != null) {
          buffer.writeCharCode(code);
          i += 2;
          continue;
        }
      } else if (next == 'u') {
        if (i + 1 < raw.length && raw[i + 1] == '{') {
          final end = raw.indexOf('}', i);
          if (end > i + 2) {
            final code = int.tryParse(raw.substring(i + 2, end), radix: 16);
            if (code != null) {
              buffer.writeCharCode(code);
              i = end;
              continue;
            }
          }
        } else if (i + 4 < raw.length) {
          final code = int.tryParse(raw.substring(i + 1, i + 5), radix: 16);
          if (code != null) {
            buffer.writeCharCode(code);
            i += 4;
            continue;
          }
        }
      } else if (next == 'n') {
        buffer.write('\n');
        continue;
      } else if (next == 'r') {
        buffer.write('\r');
        continue;
      } else if (next == 't') {
        buffer.write('\t');
        continue;
      } else if (next == 'b') {
        buffer.write('\b');
        continue;
      } else if (next == 'f') {
        buffer.write('\f');
        continue;
      } else if (next == 'v') {
        buffer.write('\v');
        continue;
      } else if (next == '0') {
        buffer.write('\0');
        continue;
      }
      buffer.write(next);
    }
    return buffer.toString();
  }

  Map<String, String> _parseScriptInfo(String code) {
    final comment = RegExp(r'^/\*[\s\S]+?\*/').firstMatch(code)?.group(0) ?? '';
    final values = <String, String>{
      'name': '',
      'version': '',
      'author': '',
      'description': '',
      'homepage': '',
    };

    final matcher = RegExp(r'^\s?\*\s?@(\w+)\s(.+)$');
    for (final rawLine in comment.split(RegExp(r'\r?\n'))) {
      final match = matcher.firstMatch(rawLine);
      if (match == null) continue;
      final key = match.group(1);
      if (key == null || !values.containsKey(key)) continue;
      values[key] = match.group(2)?.trim() ?? '';
    }

    values['name'] = _limit(
      values['name']!.isEmpty ? 'LX 音源' : values['name']!,
      24,
    );
    values['version'] = _limit(
      values['version']!.isEmpty ? '1.0.0' : values['version']!,
      36,
    );
    values['author'] = _limit(
      values['author']!.isEmpty ? 'Unknown' : values['author']!,
      56,
    );
    values['description'] = _limit(values['description']!, 36);
    values['homepage'] = _limit(values['homepage']!, 1024);
    return values;
  }

  String _limit(String value, int maxLength) {
    return value.length > maxLength
        ? '${value.substring(0, maxLength)}...'
        : value;
  }
}
