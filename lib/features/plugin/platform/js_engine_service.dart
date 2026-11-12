import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_js/flutter_js.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:pointycastle/export.dart' as pc;

/// Data emitted when a plugin sends a `pluginNotice` with type `update`
/// (i.e. the plugin itself detected an available update via
/// `lx.send('updateAlert', ...)`).

class JsEngineService {
  JavascriptRuntime? _runtime;
  late final Dio _dio;
  HttpClient? _httpClient;
  final Map<int, Timer> _timers = {};
  final Set<int> _activeTimerIds = <int>{};
  final Set<int> _repeatTimerIds = <int>{};

  /// 定时器回调的秒级限流窗口，防止多个定时器叠加成事件风暴。
  DateTime? _timerFireWindowStart;
  int _timerFireCount = 0;
  bool _timerFireThrottled = false;

  bool _initialized = false;
  bool _runtimeFaulted = false;

  /// 插件 HTTP 请求的超时下限（毫秒，0 表示不设下限）。
  ///
  /// 解析播放地址时由 [PluginHost] 临时调高：有些音源的接口很慢（十几秒），
  /// 而插件自己写的 `timeout` 可能只有 8~10 秒，会被判成 HTTP 408 解析失败。
  /// 搜索等其它调用不受影响，仍按插件自己写的超时。
  int _requestTimeoutFloorMs = 0;

  static const String _apiVersion = '1.0.3';
  static const String _environment = 'nodejs';
  static const int _quickJsTimeoutMilliseconds = 5000;
  static const int _maxActiveTimers = 256;
  // 一次性定时器低于一帧没有意义；插件写 setTimeout(fn, 0) 时原来 1ms 的
  // 下限会让主 isolate 每秒执行上千次 JS 求值。
  static const int _minTimerDelayMilliseconds = 16;
  // 周期定时器更危险（setInterval 永不自停），单独设 100ms 下限与数量上限。
  static const int _minRepeatTimerDelayMilliseconds = 100;
  static const int _maxRepeatTimers = 8;
  static const int _maxTimerFiresPerSecond = 120;
  static const int _maxTimerDelayMilliseconds = 24 * 60 * 60 * 1000;

  static int _resultVarSeq = 0;

  /// 插件桥接的调试日志。逐请求的日志在 release 下刷屏且拖慢解析，默认关掉。
  static bool verboseLogging = kDebugMode;

  static void _log(String message) {
    if (verboseLogging) debugPrint(message);
  }

  /// 插件方法结果回调通道：JS 侧 Promise 完成时主动上报，省掉逐次 evaluate。
  static const String _methodResultChannel = 'pluginMethodResult';

  /// 兜底轮询间隔：回调是主路径，这里只在回调丢失时读一次状态。
  static const Duration _methodFallbackInterval = Duration(milliseconds: 400);

  /// 正在等待结果的插件调用（key = 每次调用唯一的 resultVar）。
  final Map<String, Completer<_PluginMethodOutcome>> _pendingMethodCalls = {};

  /// 设置 / 清除插件请求的超时下限。传 zero 表示恢复「按插件自己的 timeout」。
  void setRequestTimeoutFloor(Duration floor) {
    _requestTimeoutFloorMs = floor.inMilliseconds;
  }

  Future<void> init() async {
    if (_initialized) return;

    _httpClient = HttpClient()..badCertificateCallback = (_, _, _) => true;
    _dio = Dio()
      ..httpClientAdapter = IOHttpClientAdapter(
        createHttpClient: () => _httpClient!,
      )
      ..options = BaseOptions(
        // 插件请求可能很慢（第三方脚本解析地址要十几秒），连接 / 接收超时
        // 不能卡得太死；单次请求的 timeout 仍由 _executeHttpRequest 覆盖。
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(seconds: 30),
      );

    // flutter_js 的 QuickJS 默认 JS 栈上限仅 1MB（jsSetMaxStackSize），大型
    // 洛雪插件（如 YNX-Pro/玉宁熙 系列）体积大、混淆深，加载/初始化时容易
    // 超出栈上限抛出 "InternalError: stack overflow"。
    //
    // 注意：不要把这个上限设得过大。QuickJS 只有在 C 栈用量超过该上限时才
    // 抛出可捕获的 JS "stack overflow"，而 evaluate 运行在 Dart 线程上，
    // 线程的原生栈一般只有 1MB 左右（Android 引擎线程更小）。若 JS 上限大于
    // 原生栈（例如 8MB），一旦插件递归较深会先撑爆原生栈导致进程段错误闪退，
    // 而不是抛可捕获的 JS 异常。这里恢复 flutter_js 的默认 1MB：512KB 会让
    // 大型混淆插件在正常解析阶段过早失败。真正的保护由插件加载的分阶段执行、
    // void completion value 和上层超时共同提供；不要盲目提高到 8MB 以上。
    //
    // 另外 getJavascriptRuntime 只在 Android 分支读取 extraArgs['stackSize']，
    // Windows/Linux 分支会忽略该参数，所以 FFI 平台直接构造 QuickJsRuntime2
    // 统一指定安全栈上限；iOS/macOS 走 JavascriptCore，无 JS 栈上限概念。
    if (Platform.isAndroid || Platform.isWindows || Platform.isLinux) {
      _runtime = QuickJsRuntime2(
        stackSize: 1024 * 1024,
        timeout: _quickJsTimeoutMilliseconds,
      );
    } else {
      _runtime = getJavascriptRuntime();
    }
    _runtime!.onMessage('httpRequest', _handleHttpRequest);
    _runtime!.onMessage('pluginNotice', _handlePluginNotice);
    _runtime!.onMessage('pluginLog', _handlePluginLog);
    _runtime!.onMessage('cryptoRequest', _handleCryptoRequest);
    _runtime!.onMessage('lxZlib', _handleZlibRequest);
    _runtime!.onMessage('timerRequest', _handleTimerRequest);
    _runtime!.onMessage('timerCancel', _handleTimerCancel);
    _runtime!.onMessage(_methodResultChannel, _handleMethodResult);

    _initialized = true;
    _runtimeFaulted = false;

    _log('[JsEngine] 初始化完成');
  }

  JavascriptRuntime get runtime {
    if (!_initialized || _runtime == null) {
      throw StateError('JsEngineService not initialized. Call init() first.');
    }
    return _runtime!;
  }

  JsEvalResult evaluate(String code) {
    if (_runtimeFaulted) {
      return JsEvalResult(
        '插件 JS 运行时已被隔离（此前执行超时或被中断）',
        StateError('JavaScript runtime is faulted'),
        isError: true,
      );
    }
    try {
      final result = runtime.evaluate(code);
      if (_isHardExecutionFailure(result)) {
        _markRuntimeFaulted();
      }
      return result;
    } on StackOverflowError catch (e) {
      // flutter_js 把超大插件 JS 对象桥接为 Dart 值（_jsToDart）或释放
      // JS 引用（JSRef.freeRecursive）时可能耗尽 Dart 调用栈。
      // StackOverflowError 是 Error 而非 Exception：若不拦截，它会一路
      // 冒泡到页面 catch 后以原始 "Stack Overflow" 文本展示，用户完全
      // 看不懂。这里统一转为带说明的错误结果，让上层可读地提示用户。
      _markRuntimeFaulted();
      return JsEvalResult('插件脚本过大，JS 引擎栈溢出', e, isError: true);
    }
  }

  bool get isRuntimeHealthy => _initialized && !_runtimeFaulted;

  /// 判断这次执行失败是否「伤到了引擎本身」。
  ///
  /// QuickJS 的执行超时（interrupted / timeout）只是**中断了本次执行**，
  /// 引擎本身还能继续用（插件里一个慢请求或一段重的同步计算就会触发）。
  /// 之前把这类错误也当成硬故障，会把整个插件隔离卸载，后果是用户突然
  /// 失去这个音源：播放页显示成平台音源、下载失败、换源也找不到插件，
  /// 只能重启应用才能恢复。
  ///
  /// 只有内存 / 栈这类真正会破坏引擎的错误才需要隔离。
  bool _isHardExecutionFailure(JsEvalResult result) {
    if (!result.isError) return false;
    final message = result.stringResult.toLowerCase();
    return message.contains('execution limit') ||
        message.contains('out of memory') ||
        message.contains('memory limit');
  }

  void _executePendingJob() {
    if (_runtimeFaulted) return;
    for (var i = 0; i < 10; i++) {
      final hasMore = runtime.executePendingJob();
      if (hasMore == 0) break;
    }
  }

  void executePendingJob() {
    _executePendingJob();
  }

  Map<String, dynamic> _parseArgs(dynamic args) {
    if (args is Map<String, dynamic>) {
      return args;
    }
    if (args is Map) {
      return Map<String, dynamic>.from(args);
    }
    if (args is String) {
      try {
        return jsonDecode(args) as Map<String, dynamic>;
      } catch (e) {
        _log(
          '[JsEngine] _parseArgs jsonDecode失败: $e, input: ${args.length > 200 ? args.substring(0, 200) : args}',
        );
        rethrow;
      }
    }
    _log('[JsEngine] _parseArgs 未知类型: ${args.runtimeType}, value: $args');
    throw ArgumentError('Cannot parse args of type ${args.runtimeType}');
  }

  JsEvalResult injectCeruMusicApi() {
    final apiCode =
        '''
var __pendingRequests = {};
var __pendingCryptoRequests = {};
var __pendingZlibRequests = {};
var __requestIdCounter = 0;
var __cryptoRequestIdCounter = 0;
var __zlibRequestIdCounter = 0;
var __timerIdCounter = 0;
var __mintTimerCallbacks = {};
var __mintActiveTimerCount = 0;

// flutter_js 的部分平台（Windows quickjs_c_bridge.dll、部分 Android .so）
// 暴露了原生 setTimeout/setInterval 宿主函数，但这些函数一旦被调用就会直接
// 段错误崩溃整个进程（不是可捕获的 JS 异常，try/catch 拦不住）。玉宁熙等
// 插件在加载时顶层调用 setTimeout 触发版本检查，正是闪退的根因。
// Timer callbacks are dispatched by Dart's event loop through timerRequest.
// This avoids the unsafe native timer entrypoints exposed by some flutter_js
// builds while preserving the semantics expected by LX/CeruMusic plugins.
var __mintRuntimeGlobal = null;
try { __mintRuntimeGlobal = Function('return this')(); } catch(e) {}
var __mintScheduleTimer = function(callback, delay, repeat, callbackArgs) {
  if (typeof callback !== 'function') throw new TypeError('callback must be a function');
  if (__mintActiveTimerCount >= 256) {
    if (typeof console !== 'undefined' && console.error) console.error('Too many active timers');
    return 0;
  }
  var timerId = ++__timerIdCounter;
  __mintTimerCallbacks[timerId] = {
    callback: callback,
    repeat: !!repeat,
    args: callbackArgs || []
  };
  __mintActiveTimerCount++;
  try {
    sendMessage('timerRequest', JSON.stringify({
      timerId: timerId,
      delay: Number(delay) || 0,
      repeat: !!repeat
    }));
  } catch(e) {
    delete __mintTimerCallbacks[timerId];
    __mintActiveTimerCount--;
    throw e;
  }
  return timerId;
};
var __mintCancelTimer = function(timerId) {
  if (__mintTimerCallbacks[timerId]) {
    delete __mintTimerCallbacks[timerId];
    if (__mintActiveTimerCount > 0) __mintActiveTimerCount--;
  }
  try { sendMessage('timerCancel', JSON.stringify({ timerId: Number(timerId) || 0 })); } catch(e) {}
};
var __mintFireTimer = function(timerId) {
  var entry = __mintTimerCallbacks[timerId];
  if (!entry || typeof entry.callback !== 'function') return false;
  if (!entry.repeat) {
    delete __mintTimerCallbacks[timerId];
    if (__mintActiveTimerCount > 0) __mintActiveTimerCount--;
  }
  try {
    entry.callback.apply(null, entry.args || []);
  } catch(e) {
    try { console.error('[MintMusic timer] ' + ((e && e.stack) || e)); } catch(_) {}
  }
  return true;
};
var __mintSafeSetTimeout = function(callback, delay) {
  return __mintScheduleTimer(
    callback,
    delay,
    false,
    Array.prototype.slice.call(arguments, 2)
  );
};
var __mintSafeClearTimeout = function(timerId) { __mintCancelTimer(timerId); };
var __mintSafeSetInterval = function(callback, delay) {
  return __mintScheduleTimer(
    callback,
    delay,
    true,
    Array.prototype.slice.call(arguments, 2)
  );
};
var __mintSafeClearInterval = function(timerId) { __mintCancelTimer(timerId); };
try {
  if (__mintRuntimeGlobal) {
    __mintRuntimeGlobal.setTimeout = __mintSafeSetTimeout;
    __mintRuntimeGlobal.clearTimeout = __mintSafeClearTimeout;
    __mintRuntimeGlobal.setInterval = __mintSafeSetInterval;
    __mintRuntimeGlobal.clearInterval = __mintSafeClearInterval;
  }
} catch(e) {}
var setTimeout = __mintSafeSetTimeout;
var clearTimeout = __mintSafeClearTimeout;
var setInterval = __mintSafeSetInterval;
var clearInterval = __mintSafeClearInterval;

if (typeof Buffer === 'undefined') {
  function __makeBuffer(arr) {
    if (!Array.isArray(arr)) arr = [];
    arr.toString = function(encoding) {
      if (encoding === 'base64') return __bytesToBase64(arr);
      if (encoding === 'hex') return __bytesToHex(arr);
      return __bytesToString(arr);
    };
    return arr;
  }
  var Buffer = {
    alloc: function(size) {
      var arr = [];
      for (var i = 0; i < size; i++) arr.push(0);
      return __makeBuffer(arr);
    },
    from: function(data, encoding) {
      if (typeof data === 'string') {
        if (encoding === 'base64') {
          return __makeBuffer(__base64ToBytes(data));
        }
        if (encoding === 'hex') {
          return __makeBuffer(__hexToBytes(data));
        }
        return __makeBuffer(__stringToBytes(data));
      }
      if (Array.isArray(data)) return __makeBuffer(data.slice());
      return __makeBuffer([]);
    },
    isBuffer: function(obj) {
      return Array.isArray(obj);
    },
    concat: function(list) {
      var result = [];
      for (var i = 0; i < list.length; i++) {
        if (Array.isArray(list[i])) {
          result = result.concat(list[i]);
        }
      }
      return __makeBuffer(result);
    },
    prototype: {
      toString: function(encoding) {
        return __bytesToString(this);
      }
    }
  };
}

function __wrapBytes(arr) {
  if (typeof __makeBuffer === 'function') return __makeBuffer(arr);
  return Array.isArray(arr) ? arr : [];
}

if (typeof console === 'undefined') {
  var console = {
    log: function() { try { sendMessage('pluginLog', JSON.stringify({ level: 'log', message: Array.prototype.slice.call(arguments).join(' ') })); } catch(e) {} },
    warn: function() { try { sendMessage('pluginLog', JSON.stringify({ level: 'warn', message: Array.prototype.slice.call(arguments).join(' ') })); } catch(e) {} },
    error: function() { try { sendMessage('pluginLog', JSON.stringify({ level: 'error', message: Array.prototype.slice.call(arguments).join(' ') })); } catch(e) {} },
    info: function() { try { sendMessage('pluginLog', JSON.stringify({ level: 'info', message: Array.prototype.slice.call(arguments).join(' ') })); } catch(e) {} }
  };
}

var cerumusic = {
  env: '$_environment',
  version: '$_apiVersion',
  utils: {
    buffer: {
      from: function(data, encoding) {
        return Buffer.from(data, encoding);
      },
      bufToString: function(buffer, encoding) {
        return Buffer.from(buffer).toString(encoding);
      }
    },
    crypto: {
      aesEncrypt: function(data, mode, key, iv) {
        return __aesEncrypt(data, mode, key, iv);
      },
      md5: function(str) {
        return __md5Hash(str);
      },
      randomBytes: function(size) {
        return __randomBytes(size);
      },
      rsaEncrypt: function(data, key) {
        return __rsaEncrypt(data, key);
      }
    },
    zlib: {
      inflate: function(buf) {
        return __zlibRequest('inflate', buf);
      },
      inflateRaw: function(buf) {
        return __zlibRequest('inflateRaw', buf);
      },
      deflate: function(data) {
        return __zlibRequest('deflate', data);
      }
    },
    charset: {
      /** GBK/GB18030 字节 → 字符串（酷我逐字歌词是 GBK 编码的）。 */
      decode: function(buf, encoding) {
        var enc = String(encoding || 'gbk').toLowerCase();
        return __zlibRequest('charset:' + enc, buf).then(function(bytes) {
          return __bytesToString(bytes);
        });
      }
    }
  },
  request: function(url, options, callback) {
    if (typeof options === 'function') {
      callback = options;
      options = { method: 'GET' };
    }
    options = options || { method: 'GET' };

    var requestId = ++__requestIdCounter;

    var promise = new Promise(function(resolve, reject) {
      __pendingRequests[requestId] = { resolve: resolve, reject: reject };

      try {
        var payload = JSON.stringify({
          requestId: requestId,
          url: url,
          options: options
        });
        sendMessage('httpRequest', payload);
      } catch(e) {
        delete __pendingRequests[requestId];
        reject(e);
      }
    });

    if (typeof callback === 'function') {
      promise.then(function(result) {
        callback.call(this, null, result);
      }, function(err) {
        callback.call(this, err, null);
      });
      return undefined;
    }

    return promise;
  },
  NoticeCenter: function(type, data) {
    try {
      var payload = JSON.stringify({ type: type, data: data });
      console.log('[CeruMusic] NoticeCenter type=' + type + ', payload_len=' + payload.length);
      sendMessage('pluginNotice', payload);
      console.log('[CeruMusic] NoticeCenter sendMessage done');
    } catch(e) {
      console.log('[CeruMusic] NoticeCenter error: ' + e);
    }
  }
};

function __resolveHttpRequest(requestId, success, resultJson) {
  var pending = __pendingRequests[requestId];
  if (pending) {
    delete __pendingRequests[requestId];
    if (success) {
      try {
        pending.resolve(JSON.parse(resultJson));
      } catch(e) {
        pending.resolve(resultJson);
      }
    } else {
      pending.reject(new Error(resultJson));
    }
  }
}

function __resolveCryptoRequest(requestId, result) {
  var pending = __pendingCryptoRequests[requestId];
  if (pending) {
    delete __pendingCryptoRequests[requestId];
    pending.resolve(result);
  }
}

function __resolveZlibRequest(requestId, success, result) {
  var pending = __pendingZlibRequests[requestId];
  if (pending) {
    delete __pendingZlibRequests[requestId];
    if (success) pending.resolve(__wrapBytes(__base64ToBytes(result)));
    else pending.reject(new Error(result));
  }
}

function __stringToBytes(str) {
  var arr = [];
  for (var i = 0; i < str.length; i++) {
    var code = str.charCodeAt(i);
    if (code < 0x80) {
      arr.push(code);
    } else if (code < 0x800) {
      arr.push(0xC0 | (code >> 6));
      arr.push(0x80 | (code & 0x3F));
    } else if (code < 0xD800 || code >= 0xE000) {
      arr.push(0xE0 | (code >> 12));
      arr.push(0x80 | ((code >> 6) & 0x3F));
      arr.push(0x80 | (code & 0x3F));
    } else {
      i++;
      code = 0x10000 + (((code & 0x3FF) << 10) | (str.charCodeAt(i) & 0x3FF));
      arr.push(0xF0 | (code >> 18));
      arr.push(0x80 | ((code >> 12) & 0x3F));
      arr.push(0x80 | ((code >> 6) & 0x3F));
      arr.push(0x80 | (code & 0x3F));
    }
  }
  return arr;
}

function __bytesToString(bytes) {
  if (!Array.isArray(bytes)) return String(bytes);
  var result = '';
  var i = 0;
  while (i < bytes.length) {
    var byte1 = bytes[i++] & 0xFF;
    if (byte1 < 0x80) {
      result += String.fromCharCode(byte1);
    } else if (byte1 < 0xE0) {
      var byte2 = bytes[i++] & 0x3F;
      result += String.fromCharCode(((byte1 & 0x1F) << 6) | byte2);
    } else if (byte1 < 0xF0) {
      var byte2 = bytes[i++] & 0x3F;
      var byte3 = bytes[i++] & 0x3F;
      result += String.fromCharCode(((byte1 & 0x0F) << 12) | (byte2 << 6) | byte3);
    } else {
      var byte2 = bytes[i++] & 0x3F;
      var byte3 = bytes[i++] & 0x3F;
      var byte4 = bytes[i++] & 0x3F;
      var code = ((byte1 & 0x07) << 18) | (byte2 << 12) | (byte3 << 6) | byte4;
      code -= 0x10000;
      result += String.fromCharCode(0xD800 + (code >> 10), 0xDC00 + (code & 0x3FF));
    }
  }
  return result;
}

function __base64ToBytes(base64) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var lookup = {};
  for (var i = 0; i < chars.length; i++) lookup[chars[i]] = i;
  var bytes = [];
  var len = base64.length;
  for (var i = 0; i < len; i += 4) {
    var a = lookup[base64[i]] || 0;
    var b = lookup[base64[i+1]] || 0;
    var c = lookup[base64[i+2]] || 0;
    var d = lookup[base64[i+3]] || 0;
    bytes.push((a << 2) | (b >> 4));
    if (base64[i+2] !== '=') bytes.push(((b & 0xF) << 4) | (c >> 2));
    if (base64[i+3] !== '=') bytes.push(((c & 0x3) << 6) | d);
  }
  return bytes;
}

function __bytesToBase64(bytes) {
  var chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var result = '';
  for (var i = 0; i < bytes.length; i += 3) {
    var a = bytes[i] & 0xFF;
    var b = i + 1 < bytes.length ? bytes[i+1] & 0xFF : 0;
    var c = i + 2 < bytes.length ? bytes[i+2] & 0xFF : 0;
    result += chars[a >> 2];
    result += chars[((a & 0x3) << 4) | (b >> 4)];
    result += i + 1 < bytes.length ? chars[((b & 0xF) << 2) | (c >> 6)] : '=';
    result += i + 2 < bytes.length ? chars[c & 0x3F] : '=';
  }
  return result;
}

function __hexToBytes(hex) {
  var bytes = [];
  for (var i = 0; i < hex.length; i += 2) {
    bytes.push(parseInt(hex.substr(i, 2), 16));
  }
  return bytes;
}

function __bytesToHex(bytes) {
  return bytes.map(function(b) {
    return (b & 0xFF).toString(16).padStart(2, '0');
  }).join('');
}

function __valueToBytes(value) {
  if (value == null) return [];
  if (Array.isArray(value)) return value;
  if (typeof Buffer !== 'undefined' && Buffer.isBuffer && Buffer.isBuffer(value)) {
    return Array.prototype.slice.call(value);
  }
  if (typeof value === 'string') return __stringToBytes(value);
  if (typeof value === 'number') return __stringToBytes(String(value));
  try {
    return __stringToBytes(JSON.stringify(value));
  } catch(e) {
    return __stringToBytes(String(value));
  }
}

function __md5Hash(str) {
  function rotateLeft(lValue, iShiftBits) { return (lValue << iShiftBits) | (lValue >>> (32 - iShiftBits)); }
  function addUnsigned(lX, lY) {
    var lX4, lY4, lX8, lY8, lResult;
    lX8 = (lX & 0x80000000); lY8 = (lY & 0x80000000);
    lX4 = (lX & 0x40000000); lY4 = (lY & 0x40000000);
    lResult = (lX & 0x3fffffff) + (lY & 0x3fffffff);
    if (lX4 & lY4) return (lResult ^ 0x80000000 ^ lX8 ^ lY8);
    if (lX4 | lY4) {
      if (lResult & 0x40000000) return (lResult ^ 0xc0000000 ^ lX8 ^ lY8);
      return (lResult ^ 0x40000000 ^ lX8 ^ lY8);
    }
    return (lResult ^ lX8 ^ lY8);
  }
  function f(x, y, z) { return (x & y) | ((~x) & z); }
  function g(x, y, z) { return (x & z) | (y & (~z)); }
  function h(x, y, z) { return (x ^ y ^ z); }
  function i(x, y, z) { return (y ^ (x | (~z))); }
  function ff(a, b, c, d, x, s, ac) { a = addUnsigned(a, addUnsigned(addUnsigned(f(b, c, d), x), ac)); return addUnsigned(rotateLeft(a, s), b); }
  function gg(a, b, c, d, x, s, ac) { a = addUnsigned(a, addUnsigned(addUnsigned(g(b, c, d), x), ac)); return addUnsigned(rotateLeft(a, s), b); }
  function hh(a, b, c, d, x, s, ac) { a = addUnsigned(a, addUnsigned(addUnsigned(h(b, c, d), x), ac)); return addUnsigned(rotateLeft(a, s), b); }
  function ii(a, b, c, d, x, s, ac) { a = addUnsigned(a, addUnsigned(addUnsigned(i(b, c, d), x), ac)); return addUnsigned(rotateLeft(a, s), b); }
  function convertToWordArray(input) {
    var lWordCount;
    var lMessageLength = input.length;
    var lNumberOfWordsTemp1 = lMessageLength + 8;
    var lNumberOfWordsTemp2 = (lNumberOfWordsTemp1 - (lNumberOfWordsTemp1 % 64)) / 64;
    var lNumberOfWords = (lNumberOfWordsTemp2 + 1) * 16;
    var lWordArray = new Array(lNumberOfWords - 1);
    var lBytePosition = 0;
    var lByteCount = 0;
    while (lByteCount < lMessageLength) {
      lWordCount = (lByteCount - (lByteCount % 4)) / 4;
      lBytePosition = (lByteCount % 4) * 8;
      lWordArray[lWordCount] = (lWordArray[lWordCount] | (input.charCodeAt(lByteCount) << lBytePosition));
      lByteCount++;
    }
    lWordCount = (lByteCount - (lByteCount % 4)) / 4;
    lBytePosition = (lByteCount % 4) * 8;
    lWordArray[lWordCount] = lWordArray[lWordCount] | (0x80 << lBytePosition);
    lWordArray[lNumberOfWords - 2] = lMessageLength << 3;
    lWordArray[lNumberOfWords - 1] = lMessageLength >>> 29;
    return lWordArray;
  }
  function wordToHex(lValue) {
    var wordToHexValue = '', wordToHexValueTemp = '', lByte, lCount;
    for (lCount = 0; lCount <= 3; lCount++) {
      lByte = (lValue >>> (lCount * 8)) & 255;
      wordToHexValueTemp = '0' + lByte.toString(16);
      wordToHexValue = wordToHexValue + wordToHexValueTemp.substr(wordToHexValueTemp.length - 2, 2);
    }
    return wordToHexValue;
  }
  function utf8Encode(input) {
    input = String(input).replace(/\\r\\n/g, '\\n');
    var output = '';
    for (var n = 0; n < input.length; n++) {
      var c = input.charCodeAt(n);
      if (c < 128) output += String.fromCharCode(c);
      else if ((c > 127) && (c < 2048)) {
        output += String.fromCharCode((c >> 6) | 192);
        output += String.fromCharCode((c & 63) | 128);
      } else {
        output += String.fromCharCode((c >> 12) | 224);
        output += String.fromCharCode(((c >> 6) & 63) | 128);
        output += String.fromCharCode((c & 63) | 128);
      }
    }
    return output;
  }
  var x = [];
  var k, AA, BB, CC, DD, a, b, c, d;
  var S11 = 7, S12 = 12, S13 = 17, S14 = 22;
  var S21 = 5, S22 = 9, S23 = 14, S24 = 20;
  var S31 = 4, S32 = 11, S33 = 16, S34 = 23;
  var S41 = 6, S42 = 10, S43 = 15, S44 = 21;
  str = utf8Encode(str);
  x = convertToWordArray(str);
  a = 0x67452301; b = 0xefcdab89; c = 0x98badcfe; d = 0x10325476;
  for (k = 0; k < x.length; k += 16) {
    AA = a; BB = b; CC = c; DD = d;
    a = ff(a, b, c, d, x[k + 0], S11, 0xd76aa478); d = ff(d, a, b, c, x[k + 1], S12, 0xe8c7b756);
    c = ff(c, d, a, b, x[k + 2], S13, 0x242070db); b = ff(b, c, d, a, x[k + 3], S14, 0xc1bdceee);
    a = ff(a, b, c, d, x[k + 4], S11, 0xf57c0faf); d = ff(d, a, b, c, x[k + 5], S12, 0x4787c62a);
    c = ff(c, d, a, b, x[k + 6], S13, 0xa8304613); b = ff(b, c, d, a, x[k + 7], S14, 0xfd469501);
    a = ff(a, b, c, d, x[k + 8], S11, 0x698098d8); d = ff(d, a, b, c, x[k + 9], S12, 0x8b44f7af);
    c = ff(c, d, a, b, x[k + 10], S13, 0xffff5bb1); b = ff(b, c, d, a, x[k + 11], S14, 0x895cd7be);
    a = ff(a, b, c, d, x[k + 12], S11, 0x6b901122); d = ff(d, a, b, c, x[k + 13], S12, 0xfd987193);
    c = ff(c, d, a, b, x[k + 14], S13, 0xa679438e); b = ff(b, c, d, a, x[k + 15], S14, 0x49b40821);
    a = gg(a, b, c, d, x[k + 1], S21, 0xf61e2562); d = gg(d, a, b, c, x[k + 6], S22, 0xc040b340);
    c = gg(c, d, a, b, x[k + 11], S23, 0x265e5a51); b = gg(b, c, d, a, x[k + 0], S24, 0xe9b6c7aa);
    a = gg(a, b, c, d, x[k + 5], S21, 0xd62f105d); d = gg(d, a, b, c, x[k + 10], S22, 0x02441453);
    c = gg(c, d, a, b, x[k + 15], S23, 0xd8a1e681); b = gg(b, c, d, a, x[k + 4], S24, 0xe7d3fbc8);
    a = gg(a, b, c, d, x[k + 9], S21, 0x21e1cde6); d = gg(d, a, b, c, x[k + 14], S22, 0xc33707d6);
    c = gg(c, d, a, b, x[k + 3], S23, 0xf4d50d87); b = gg(b, c, d, a, x[k + 8], S24, 0x455a14ed);
    a = gg(a, b, c, d, x[k + 13], S21, 0xa9e3e905); d = gg(d, a, b, c, x[k + 2], S22, 0xfcefa3f8);
    c = gg(c, d, a, b, x[k + 7], S23, 0x676f02d9); b = gg(b, c, d, a, x[k + 12], S24, 0x8d2a4c8a);
    a = hh(a, b, c, d, x[k + 5], S31, 0xfffa3942); d = hh(d, a, b, c, x[k + 8], S32, 0x8771f681);
    c = hh(c, d, a, b, x[k + 11], S33, 0x6d9d6122); b = hh(b, c, d, a, x[k + 14], S34, 0xfde5380c);
    a = hh(a, b, c, d, x[k + 1], S31, 0xa4beea44); d = hh(d, a, b, c, x[k + 4], S32, 0x4bdecfa9);
    c = hh(c, d, a, b, x[k + 7], S33, 0xf6bb4b60); b = hh(b, c, d, a, x[k + 10], S34, 0xbebfbc70);
    a = hh(a, b, c, d, x[k + 13], S31, 0x289b7ec6); d = hh(d, a, b, c, x[k + 0], S32, 0xeaa127fa);
    c = hh(c, d, a, b, x[k + 3], S33, 0xd4ef3085); b = hh(b, c, d, a, x[k + 6], S34, 0x04881d05);
    a = hh(a, b, c, d, x[k + 9], S31, 0xd9d4d039); d = hh(d, a, b, c, x[k + 12], S32, 0xe6db99e5);
    c = hh(c, d, a, b, x[k + 15], S33, 0x1fa27cf8); b = hh(b, c, d, a, x[k + 2], S34, 0xc4ac5665);
    a = ii(a, b, c, d, x[k + 0], S41, 0xf4292244); d = ii(d, a, b, c, x[k + 7], S42, 0x432aff97);
    c = ii(c, d, a, b, x[k + 14], S43, 0xab9423a7); b = ii(b, c, d, a, x[k + 5], S44, 0xfc93a039);
    a = ii(a, b, c, d, x[k + 12], S41, 0x655b59c3); d = ii(d, a, b, c, x[k + 3], S42, 0x8f0ccc92);
    c = ii(c, d, a, b, x[k + 10], S43, 0xffeff47d); b = ii(b, c, d, a, x[k + 1], S44, 0x85845dd1);
    a = ii(a, b, c, d, x[k + 8], S41, 0x6fa87e4f); d = ii(d, a, b, c, x[k + 15], S42, 0xfe2ce6e0);
    c = ii(c, d, a, b, x[k + 6], S43, 0xa3014314); b = ii(b, c, d, a, x[k + 13], S44, 0x4e0811a1);
    a = ii(a, b, c, d, x[k + 4], S41, 0xf7537e82); d = ii(d, a, b, c, x[k + 11], S42, 0xbd3af235);
    c = ii(c, d, a, b, x[k + 2], S43, 0x2ad7d2bb); b = ii(b, c, d, a, x[k + 9], S44, 0xeb86d391);
    a = addUnsigned(a, AA); b = addUnsigned(b, BB); c = addUnsigned(c, CC); d = addUnsigned(d, DD);
  }
  return (wordToHex(a) + wordToHex(b) + wordToHex(c) + wordToHex(d)).toLowerCase();
}

function __aesEncrypt(data, mode, key, iv) {
  var requestId = ++__cryptoRequestIdCounter;
  var dataBytes = __valueToBytes(data);
  var keyBytes = __valueToBytes(key);
  var ivBytes = iv ? __valueToBytes(iv) : [];

  return new Promise(function(resolve) {
    __pendingCryptoRequests[requestId] = {
      resolve: function(result) {
        resolve(__wrapBytes(__base64ToBytes(result)));
      }
    };
    sendMessage('cryptoRequest', JSON.stringify({
      requestId: requestId,
      algorithm: 'aesEncrypt',
      mode: mode,
      data: __bytesToBase64(dataBytes),
      key: __bytesToBase64(keyBytes),
      iv: __bytesToBase64(ivBytes)
    }));
  });
}

function __randomBytes(size) {
  var arr = [];
  for (var i = 0; i < size; i++) {
    arr.push(Math.floor(Math.random() * 256));
  }
  return __wrapBytes(arr);
}

function __rsaEncrypt(data, key) {
  var requestId = ++__cryptoRequestIdCounter;
  var dataBytes = __valueToBytes(data);

  return new Promise(function(resolve) {
    __pendingCryptoRequests[requestId] = {
      resolve: function(result) {
        resolve(__wrapBytes(__base64ToBytes(result)));
      }
    };
    sendMessage('cryptoRequest', JSON.stringify({
      requestId: requestId,
      algorithm: 'rsaEncrypt',
      data: __bytesToBase64(dataBytes),
      key: key
    }));
  });
}

function __zlibRequest(action, data) {
  var requestId = ++__zlibRequestIdCounter;
  var dataBytes = __valueToBytes(data);

  return new Promise(function(resolve, reject) {
    __pendingZlibRequests[requestId] = { resolve: resolve, reject: reject };
    try {
      sendMessage('lxZlib', JSON.stringify({
        requestId: requestId,
        action: action,
        data: __bytesToBase64(dataBytes)
      }));
    } catch(e) {
      delete __pendingZlibRequests[requestId];
      reject(e);
    }
  });
}
''';

    // Install the bridge exactly once. Returning the evaluation result lets the
    // host report an initialization error without evaluating this large API
    // block a second time.
    return evaluate(apiCode);
  }

  /// MusicFree 兼容运行时的资源目录。
  static const String _pluginModulesAssetDir = 'assets/plugin_modules';

  /// MusicFree 兼容运行时本体（require 注册表 / axios 适配层 / 浏览器垫片）。
  static const String _musicFreeRuntimeAsset =
      '$_pluginModulesAssetDir/musicfree_runtime.js';

  /// 插件 `require()` 名称 → 内置资源文件。
  ///
  /// 只收录 MusicFree 生态里常见的纯前端依赖；未收录的模块由运行时返回空
  /// 对象（与 MusicFree 官方运行时一致，插件通常把这类依赖当可选能力）。
  static const Map<String, String> _pluginModuleAssets = {
    'crypto-js': '$_pluginModulesAssetDir/crypto-js.js',
    'dayjs': '$_pluginModulesAssetDir/dayjs.js',
    'he': '$_pluginModulesAssetDir/he.js',
    'qs': '$_pluginModulesAssetDir/qs.js',
    'big-integer': '$_pluginModulesAssetDir/big-integer.js',
    'cheerio': '$_pluginModulesAssetDir/cheerio.js',
  };

  final Set<String> _loadedPluginModules = <String>{};
  bool _musicFreeRuntimeInjected = false;

  /// 已注入的 MusicFree 模块名（供宿主日志与测试断言使用）。
  Set<String> get loadedPluginModules => Set.unmodifiable(_loadedPluginModules);

  /// 注入失败的模块名（用于诊断；注入失败不会中断插件加载）。
  final Set<String> _failedPluginModules = <String>{};

  /// 注入 MusicFree 依赖时失败的模块名。
  Set<String> get failedPluginModules => Set.unmodifiable(_failedPluginModules);

  /// 确保 MusicFree 兼容运行时与 [moduleNames] 指定的模块已注入当前 JS 运行时。
  ///
  /// 每个运行时实例只注入一次：运行时状态（模块注册表、插件缓存的实例）必须
  /// 在同一运行时内共享，切换插件时不会重复求值这些大体积脚本。
  ///
  /// 单个依赖注入失败（例如极端体积的打包产物在该 JS 引擎上解析失败）不会中断
  /// 加载：运行时的 `require()` 会对缺失模块返回空对象，插件仍能加载与搜索，
  /// 只有真正用到该依赖的功能会报错。这样可避免「一个可选依赖拖垮整个插件」。
  /// 运行时本体注入失败才会抛异常。
  Future<void> ensurePluginModules(Iterable<String> moduleNames) async {
    if (!_musicFreeRuntimeInjected) {
      final runtimeCode = await rootBundle.loadString(_musicFreeRuntimeAsset);
      final result = evaluate('$runtimeCode\n;void 0;');
      if (result.isError) {
        throw Exception('MusicFree 运行时注入失败: ${result.stringResult}');
      }
      _musicFreeRuntimeInjected = true;
    }

    for (final rawName in moduleNames) {
      final name = _normalizeModuleName(rawName);
      if (name.isEmpty || _loadedPluginModules.contains(name)) continue;
      // axios 由运行时自带实现（基于 cerumusic.request 桥），不需要注入外部脚本。
      if (name == 'axios') {
        _loadedPluginModules.add(name);
        continue;
      }
      final assetPath = _pluginModuleAssets[name];
      if (assetPath == null) continue;

      final source = await rootBundle.loadString(assetPath);
      final wrapped =
          '(function() {\n'
          '  var module = { exports: {} };\n'
          '  var exports = module.exports;\n'
          '$source\n'
          '  __mfRegisterModule(${jsonEncode(name)}, module.exports);\n'
          '})();\n'
          ';void 0;';
      final result = evaluate(wrapped);
      if (result.isError) {
        _log('[JsEngine] 注入 MusicFree 模块 $name 失败: ${result.stringResult}');
        _failedPluginModules.add(name);
        _loadedPluginModules.add(name);
        continue;
      }
      _loadedPluginModules.add(name);
      _log('[JsEngine] 已注入 MusicFree 模块: $name');
    }
  }

  String _normalizeModuleName(String name) {
    var normalized = name.trim();
    if (normalized.startsWith('node:')) {
      normalized = normalized.substring('node:'.length);
    }
    return normalized;
  }

  /// 解析插件源码中出现过的 `require('xxx')` 调用。
  ///
  /// MusicFree 插件是打包后的 CommonJS（webpack/rollup），依赖声明集中在文件
  /// 顶部，正则可覆盖；动态拼接的 `require(变量)` 无法静态识别，由运行时的
  /// 空模块兜底。
  static Set<String> detectRequiredModules(String pluginCode) {
    final modules = <String>{};
    final pattern = RegExp(
      r'''require\(\s*['"]([^'"]+)['"]\s*\)''',
      multiLine: true,
    );
    for (final match in pattern.allMatches(pluginCode)) {
      final name = match.group(1);
      if (name == null || name.isEmpty) continue;
      modules.add(name);
    }
    return modules;
  }

  /// 判断插件代码是否由 MusicFree 适配器生成（即 MusicFree 格式插件）。
  static bool isMusicFreeAdapterCode(String code) =>
      code.contains('__mintMusicFreeAdapter');

  void _handleHttpRequest(dynamic args) {
    try {
      _log('[JsEngine] _handleHttpRequest 收到参数类型: ${args.runtimeType}');
      final data = _parseArgs(args);
      final requestId = data['requestId'];
      final url = data['url'] as String;
      final options = data['options'] is Map
          ? Map<String, dynamic>.from(data['options'] as Map)
          : <String, dynamic>{};

      final int reqId;
      if (requestId is int) {
        reqId = requestId;
      } else if (requestId is String) {
        reqId = int.tryParse(requestId) ?? 0;
      } else {
        reqId = 0;
      }

      _log('[JsEngine] HTTP请求: $url (requestId: $reqId)');
      _executeHttpRequest(reqId, url, options).catchError((error, stackTrace) {
        _log('[JsEngine] _executeHttpRequest异步错误: $error');
        _log('[JsEngine] StackTrace: $stackTrace');
        try {
          final errorJson = jsonEncode({
            'body': jsonEncode({
              'error': 'AsyncError',
              'message': error.toString(),
            }),
            'statusCode': 500,
            'headers': <String, String>{},
          });
          return _resolveRequest(reqId, true, errorJson);
        } catch (_) {}
      });
    } catch (e, stackTrace) {
      _log('[JsEngine] Error handling HTTP request: $e');
      _log('[JsEngine] StackTrace: $stackTrace');
    }
  }

  void _handleCryptoRequest(dynamic args) {
    try {
      final data = _parseArgs(args);
      final requestId = data['requestId'];
      final algorithm = data['algorithm'] as String;

      final int reqId;
      if (requestId is int) {
        reqId = requestId;
      } else if (requestId is String) {
        reqId = int.tryParse(requestId) ?? 0;
      } else {
        reqId = 0;
      }

      _executeCryptoRequest(reqId, algorithm, data);
    } catch (e) {
      _log('[JsEngine] Error handling crypto request: $e');
    }
  }

  void _handleZlibRequest(dynamic args) {
    try {
      final data = _parseArgs(args);
      final requestId = data['requestId'];
      final action = data['action'] as String? ?? 'inflate';

      final int reqId;
      if (requestId is int) {
        reqId = requestId;
      } else if (requestId is String) {
        reqId = int.tryParse(requestId) ?? 0;
      } else {
        reqId = 0;
      }

      _executeZlibRequest(reqId, action, data['data']?.toString() ?? '');
    } catch (e) {
      _log('[JsEngine] Error handling zlib request: $e');
    }
  }

  Future<void> _executeCryptoRequest(
    int requestId,
    String algorithm,
    Map<String, dynamic> data,
  ) async {
    try {
      dynamic result;

      switch (algorithm) {
        case 'md5':
          final input = data['data'] as String;
          final bytes = utf8.encode(input);
          final digest = md5.convert(bytes);
          result = digest.toString();
          break;

        case 'aesEncrypt':
          final mode = data['mode'] as String? ?? 'aes-128-cbc';
          final keyBytes = _decodeBase64Bytes(data['key']?.toString());
          final ivBytes = _decodeBase64Bytes(data['iv']?.toString());
          final plainBytes = _decodeBase64Bytes(data['data']?.toString());

          result = base64Encode(
            _aesEncryptBytes(plainBytes, mode, keyBytes, ivBytes),
          );
          break;

        case 'rsaEncrypt':
          final plainBytes = _decodeBase64Bytes(data['data']?.toString());
          final publicKey = data['key']?.toString() ?? '';
          result = base64Encode(_rsaEncryptNoPadding(plainBytes, publicKey));
          break;

        default:
          result = data['data'];
      }

      final resultStr = result is String ? result : jsonEncode(result);
      _resolveCryptoResult(requestId, resultStr);
    } catch (e) {
      _log('[JsEngine] Crypto request error: $e');
      _resolveCryptoResult(requestId, data['data']?.toString() ?? '');
    }
  }

  List<int> _aesEncryptBytes(
    List<int> plainBytes,
    String mode,
    List<int> keyBytes,
    List<int> ivBytes,
  ) {
    final normalizedKey = _normalizeAesKey(keyBytes);
    final normalizedIv = _normalizeAesIv(ivBytes);
    final keyParam = pc.KeyParameter(Uint8List.fromList(normalizedKey));
    final lowerMode = mode.toLowerCase();
    final useEcb = lowerMode.contains('ecb');
    final blockCipher = useEcb
        ? pc.ECBBlockCipher(pc.AESEngine())
        : pc.CBCBlockCipher(pc.AESEngine());
    final cipher = pc.PaddedBlockCipherImpl(pc.PKCS7Padding(), blockCipher);
    final pc.CipherParameters cipherParams = useEcb
        ? keyParam
        : pc.ParametersWithIV<pc.KeyParameter>(
            keyParam,
            Uint8List.fromList(normalizedIv),
          );

    cipher.init(
      true,
      pc.PaddedBlockCipherParameters<pc.CipherParameters, pc.CipherParameters>(
        cipherParams,
        null,
      ),
    );

    return cipher.process(Uint8List.fromList(plainBytes));
  }

  List<int> _rsaEncryptNoPadding(List<int> plainBytes, String publicKeyPem) {
    if (publicKeyPem.trim().isEmpty) return plainBytes;
    try {
      final publicKey = _parseRsaPublicKey(publicKeyPem);
      final modulus = publicKey.modulus!;
      final exponent = publicKey.exponent!;
      final keyLength = (modulus.bitLength + 7) >> 3;
      final padded = Uint8List(keyLength);
      final input = plainBytes.length > keyLength
          ? plainBytes.sublist(plainBytes.length - keyLength)
          : plainBytes;
      padded.setRange(keyLength - input.length, keyLength, input);

      final encrypted = _bytesToBigInt(padded).modPow(exponent, modulus);
      return _bigIntToBytes(encrypted, keyLength);
    } catch (e) {
      _log('[JsEngine] RSA encrypt fallback: $e');
      return plainBytes;
    }
  }

  pc.RSAPublicKey _parseRsaPublicKey(String publicKeyPem) {
    final body = publicKeyPem
        .replaceAll(RegExp(r'-----BEGIN [^-]+-----'), '')
        .replaceAll(RegExp(r'-----END [^-]+-----'), '')
        .replaceAll(RegExp(r'\s+'), '');
    final der = base64Decode(body);
    final reader = _DerReader(der);
    final top = reader.readSequence();

    if (top.peekTag() == 0x02) {
      final modulus = top.readInteger();
      final exponent = top.readInteger();
      return pc.RSAPublicKey(modulus, exponent);
    }

    top.readSequence();
    final bitString = top.readBitString();
    final rsa = _DerReader(bitString).readSequence();
    final modulus = rsa.readInteger();
    final exponent = rsa.readInteger();
    return pc.RSAPublicKey(modulus, exponent);
  }

  List<int> _normalizeAesKey(List<int> keyBytes) {
    final targetLength = keyBytes.length <= 16
        ? 16
        : keyBytes.length <= 24
        ? 24
        : 32;
    final normalized = Uint8List(targetLength);
    normalized.setRange(
      0,
      keyBytes.length > targetLength ? targetLength : keyBytes.length,
      keyBytes,
    );
    return normalized;
  }

  List<int> _normalizeAesIv(List<int> ivBytes) {
    final normalized = Uint8List(16);
    normalized.setRange(0, ivBytes.length > 16 ? 16 : ivBytes.length, ivBytes);
    return normalized;
  }

  List<int> _decodeBase64Bytes(String? value) {
    if (value == null || value.isEmpty) return const [];
    try {
      return base64Decode(value);
    } catch (_) {
      return utf8.encode(value);
    }
  }

  /// GBK/GB18030 字节 → 字符串。
  ///
  /// 用 `gbk_bytes` 而不是 `gbk`：后者在 gbk_codec 0.4.0 里按单字节查表，
  /// 双字节汉字会被原样输出成字节码（等同 Latin-1），导致歌词乱码。
  static String decodeGbkBytes(List<int> bytes) => gbk_bytes.decode(bytes);

  BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) + BigInt.from(byte & 0xff);
    }
    return result;
  }

  List<int> _bigIntToBytes(BigInt value, int length) {
    final bytes = Uint8List(length);
    var current = value;
    for (var i = length - 1; i >= 0; i--) {
      bytes[i] = (current & BigInt.from(0xff)).toInt();
      current = current >> 8;
    }
    return bytes;
  }

  Future<void> _executeZlibRequest(
    int requestId,
    String action,
    String base64Data,
  ) async {
    try {
      final input = _decodeBase64Bytes(base64Data);
      List<int> output;
      if (action == 'deflate') {
        output = ZLibEncoder().encode(input);
      } else if (action == 'inflateRaw') {
        // 裸 deflate（没有 zlib 头）：酷我 newlyric 这类接口用的就是它
        output = ZLibDecoder().decodeBytes(input, raw: true);
      } else if (action.startsWith('charset:')) {
        // 字符集解码：插件拿不到 GBK 文本时借这里转成 UTF-8 字节。
        // 必须用 gbk_bytes（按双字节解码）；gbk_codec 的 gbk.decode 是逐字节
        // 查表，遇到 GBK 双字节汉字只会原样输出字节码（等同 Latin-1），
        // 酷我逐字歌词会因此整段乱码。
        final text = decodeGbkBytes(input);
        output = utf8.encode(text);
      } else {
        output = ZLibDecoder().decodeBytes(input);
      }
      _resolveZlibResult(requestId, true, base64Encode(output));
    } catch (e) {
      _log('[JsEngine] Zlib request error: $e');
      _resolveZlibResult(requestId, false, e.toString());
    }
  }

  void _resolveCryptoResult(int requestId, String result) {
    try {
      final escaped = result
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll('\n', '\\n')
          .replaceAll('\r', '\\r');
      evaluate("__resolveCryptoRequest($requestId, '$escaped')");
      _executePendingJob();
    } catch (e) {
      _log('[JsEngine] Error resolving crypto request $requestId: $e');
    }
  }

  void _resolveZlibResult(int requestId, bool success, String result) {
    try {
      final escaped = result
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll('\n', '\\n')
          .replaceAll('\r', '\\r');
      evaluate("__resolveZlibRequest($requestId, $success, '$escaped')");
      _executePendingJob();
    } catch (e) {
      _log('[JsEngine] Error resolving zlib request $requestId: $e');
    }
  }

  Future<void> _executeHttpRequest(
    int requestId,
    String url,
    Map<String, dynamic> options,
  ) async {
    try {
      final method = (options['method'] as String?)?.toUpperCase() ?? 'GET';
      final headers = <String, String>{};
      if (options['headers'] is Map) {
        (options['headers'] as Map).forEach((k, v) {
          headers[k.toString()] = v.toString();
        });
      }

      // 插件没显式传 timeout 时的默认值。
      // 有些音源（例如网易的第三方 VIP 脚本）解析地址要十几秒，10 秒会直接
      // 判成 HTTP 408 超时、歌放不了；这里放宽到 30 秒。
      final requested = (options['timeout'] as int?) ?? 30000;
      // 解析播放地址期间会临时抬高下限（见 PluginHost.getMusicUrlResult）：
      // 插件里写死的 8~10 秒超时对慢接口不够用。
      final timeout = _requestTimeoutFloorMs > requested
          ? _requestTimeoutFloorMs
          : requested;

      Object? bodyData = options['body'];
      if (options['bodyBase64'] is String && bodyData == null) {
        // 二进制请求体（axios 里 Uint8Array / ArrayBuffer 形式的 data）。
        try {
          bodyData = base64Decode(options['bodyBase64'] as String);
        } catch (e) {
          _log('[JsEngine] bodyBase64 解码失败: $e');
        }
      }
      if (options['form'] is Map && bodyData == null) {
        final form = Map<String, dynamic>.from(options['form'] as Map);
        bodyData = Uri(
          queryParameters: form.map(
            (key, value) => MapEntry(key, value?.toString() ?? ''),
          ),
        ).query;
        headers.putIfAbsent(
          'Content-Type',
          () => 'application/x-www-form-urlencoded;charset=UTF-8',
        );
      }
      if (bodyData is Map || (bodyData is List && bodyData is! Uint8List)) {
        final contentType = headers.entries
            .firstWhere(
              (entry) => entry.key.toLowerCase() == 'content-type',
              orElse: () => const MapEntry('', ''),
            )
            .value
            .toLowerCase();
        bodyData = contentType.contains('application/x-www-form-urlencoded')
            ? Uri(
                queryParameters: Map<String, dynamic>.from(
                  bodyData as Map,
                ).map((key, value) => MapEntry(key, value?.toString() ?? '')),
              ).query
            : jsonEncode(bodyData);
      }

      _log('[JsEngine] 发起HTTP请求: $method $url');

      final response = await _dio.request(
        url,
        options: Options(
          method: method,
          headers: headers.isNotEmpty ? headers : null,
          responseType: ResponseType.bytes,
          followRedirects: options['follow_redirects'] != false,
          maxRedirects:
              (options['follow_max'] as int?) ??
              (options['maxRedirects'] as int?) ??
              5,
          receiveDataWhenStatusError: true,
          validateStatus: (_) => true,
          sendTimeout: Duration(milliseconds: timeout),
          receiveTimeout: Duration(milliseconds: timeout),
        ),
        data: bodyData,
      );

      final bodyBytes = response.data is List<int>
          ? List<int>.from(response.data as List<int>)
          : utf8.encode(response.data?.toString() ?? '');

      // —— 大二进制响应不再往 JS 引擎里搬 ——
      //
      // 过去这里无条件把整个响应体 utf8 解码 + base64 + jsonEncode，再通过
      // evaluate() 拼进 JS 源码里。体积一大就会在主 isolate 上做几次全量拷贝
      // 和一次巨型字符串解析：实测一个「302 到音频」的取地址接口被跟随之后，
      // 3.6MB 音频变成 11MB 的 resultJson，播放按钮转圈期间整个窗口明显卡死。
      //
      // 现在：文本体按阈值解码（大二进制跳过）；base64 只给较小的体。
      // 取地址类插件真正需要的只是响应头（Location），音频 / 视频这类
      // 大二进制对 JS 侧没有意义，直接省略体，只报长度与类型。
      final contentType =
          (response.headers.value('content-type') ?? '').toLowerCase();
      final looksText =
          contentType.isEmpty ||
          contentType.contains('json') ||
          contentType.contains('xml') ||
          contentType.contains('javascript') ||
          contentType.startsWith('text/');
      const int maxTextBytes = 4 * 1024 * 1024;
      const int maxUnknownTypeTextBytes = 512 * 1024;
      const int maxBase64Bytes = 2 * 1024 * 1024;

      // 文本体：类型明确是文本时放宽到 4MB；类型不明时只在小体积上尝试
      // （不少接口把 JSON 标成 octet-stream）。严格 UTF-8 解码失败即视为二进制。
      String? bodyText;
      final textBudget = looksText ? maxTextBytes : maxUnknownTypeTextBytes;
      if (bodyBytes.isNotEmpty && bodyBytes.length <= textBudget) {
        try {
          bodyText = utf8.decode(bodyBytes);
        } catch (_) {
          bodyText = null;
        }
      }
      final includeBase64 =
          bodyBytes.isNotEmpty && bodyBytes.length <= maxBase64Bytes;

      final responseBody = bodyText == null
          ? null
          : _parseResponseBody(bodyText);
      final resultJson = jsonEncode({
        'body': bodyText == null
            ? ''
            : (responseBody is String
                  ? responseBody
                  : jsonEncode(responseBody)),
        'statusCode': response.statusCode ?? 200,
        'headers': response.headers.map.map(
          (k, v) => MapEntry(k, v.join(', ')),
        ),
        'bodyBase64': includeBase64 ? base64Encode(bodyBytes) : '',
        // 体被省略时告诉插件原因（只报长度和类型），插件应回退到
        // 「只读 headers」的路径，而不是把空 body 当成「接口返回空」。
        'bodyBytes': bodyBytes.length,
        'bodyOmitted': !includeBase64 && bodyText == null,
        'contentType': contentType,
      });

      if (!includeBase64 && bodyText == null && bodyBytes.isNotEmpty) {
        _log(
          '[JsEngine] 大二进制响应已省略体: ${bodyBytes.length} 字节 '
          '(${contentType.isEmpty ? '未知类型' : contentType}) $url',
        );
      }
      _log('[JsEngine] HTTP请求成功: ${response.statusCode} $url');
      await _resolveRequest(requestId, true, resultJson);
    } catch (e) {
      final isTimeout =
          e is DioException &&
          (e.type == DioExceptionType.connectionTimeout ||
              e.type == DioExceptionType.receiveTimeout);
      final resultJson = jsonEncode({
        'body': jsonEncode({
          'error': isTimeout ? 'TimeoutError' : 'RequestError',
          'message': e.toString(),
        }),
        'statusCode': isTimeout ? 408 : 500,
        'headers': <String, String>{},
      });
      _log('[JsEngine] HTTP请求失败: $url - $e');
      await _resolveRequest(requestId, true, resultJson);
    }
  }

  dynamic _parseResponseBody(dynamic data) {
    if (data == null) return null;
    if (data is String) {
      try {
        return jsonDecode(data);
      } catch (_) {
        return data;
      }
    }
    return data;
  }

  /// 超过该字符数的响应体改走分块传输（约两个分块即触发）。
  static const int _httpChunkThresholdChars = 256 * 1024;

  /// 分块传输时每次 evaluate 写入 JS 的最大字符数。QuickJS 编译字面量的
  /// 成本随长度超线性增长，把 MB 级响应切成百 KB 级小块，单次编译峰值
  /// 大幅下降，块与块之间还能让出主线程。
  static const int _httpChunkChars = 128 * 1024;

  Future<void> _resolveRequest(
    int requestId,
    bool success,
    String resultJson,
  ) async {
    try {
      _log(
        '[JsEngine] _resolveRequest: requestId=$requestId, success=$success, resultJson长度=${resultJson.length}',
      );
      if (resultJson.length > _httpChunkThresholdChars) {
        await _resolveRequestChunked(requestId, success, resultJson);
      } else {
        final escapedJson = _escapeForJsString(resultJson);
        final jsCode =
            "__resolveHttpRequest($requestId, $success, '$escapedJson')";
        _log('[JsEngine] 执行JS代码长度: ${jsCode.length}');
        final evalResult = evaluate(jsCode);
        _log('[JsEngine] evaluate结果: ${evalResult.stringResult}');
        _executePendingJob();
        _log('[JsEngine] 已解析请求 $requestId, _executePendingJob()已调用');
      }
    } catch (e, stackTrace) {
      _log('[JsEngine] Error resolving request $requestId: $e');
      _log('[JsEngine] StackTrace: $stackTrace');
      try {
        // 分块中途失败的话清掉半成品，避免 JS 侧残留无用数据。
        evaluate('if (typeof __httpChunks !== "undefined") { __httpChunks[$requestId] = void 0; }');
        final errorJson = jsonEncode({
          'body': jsonEncode({
            'error': 'ResolveError',
            'message': e.toString(),
          }),
          'statusCode': 500,
          'headers': <String, String>{},
        });
        final escapedErrorJson = _escapeForJsString(errorJson);
        evaluate("__resolveHttpRequest($requestId, true, '$escapedErrorJson')");
        _executePendingJob();
      } catch (_) {}
    }
  }

  /// 大响应分块传输：先把块数组建在 `globalThis.__httpChunks` 上，逐块
  /// evaluate 写入，最后在 JS 侧 join 成完整串再交给 `__resolveHttpRequest`。
  ///
  /// 正确性依据：[_escapeForJsString] 是逐字符替换（`\`、`'`、换行等各自
  /// 独立映射为固定序列），把原始响应体在任意位置切块后逐块转义，拼接结果
  /// 与整体转义完全一致，所以可以放心按原始长度切块。
  Future<void> _resolveRequestChunked(
    int requestId,
    bool success,
    String resultJson,
  ) async {
    _log(
      '[JsEngine] 大响应分块传输: requestId=$requestId, '
      '长度=${resultJson.length}, 块大小=$_httpChunkChars',
    );
    evaluate('(__httpChunks = __httpChunks || {})[$requestId] = [];');
    for (
      var offset = 0;
      offset < resultJson.length;
      offset += _httpChunkChars
    ) {
      final end = math.min(offset + _httpChunkChars, resultJson.length);
      final escaped = _escapeForJsString(resultJson.substring(offset, end));
      evaluate("(__httpChunks[$requestId]).push('$escaped');");
      // 块与块之间让出一次事件循环，主线程不至于被连续的大编译占满。
      await Future<void>.delayed(Duration.zero);
    }
    final evalResult = evaluate(
      '__resolveHttpRequest('
      '$requestId, $success, (__httpChunks[$requestId] || []).join("")); '
      '__httpChunks[$requestId] = void 0;',
    );
    _log('[JsEngine] 分块解析完成: ${evalResult.stringResult}');
    _executePendingJob();
  }

  String _escapeForJsString(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t')
        .replaceAll('\$', '\\\$');
  }

  /// Broadcast stream of plugin notices (e.g. update alerts).
  final _pluginNoticeController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of plugin notices emitted by loaded plugins.
  Stream<Map<String, dynamic>> get pluginNoticeStream =>
      _pluginNoticeController.stream;

  void _handlePluginNotice(dynamic args) {
    try {
      final data = _parseArgs(args);
      final type = data['type']?.toString() ?? '';
      final noticeData = data['data'];
      _log('[PluginNotice] type=$type, data=$noticeData');
      // Propagate update notices so the UI layer can react.
      if (type == 'update' && noticeData != null) {
        _log('[PluginNotice] Emitting update notice to stream');
        _pluginNoticeController.add(data);
      }
    } catch (e) {
      _log('[JsEngine] Error handling plugin notice: $e');
    }
  }

  void _handlePluginLog(dynamic args) {
    try {
      final data = _parseArgs(args);
      _log('[PluginLog] [${data['level']}] ${data['message']}');
    } catch (e) {
      _log('[JsEngine] Plugin log: $args');
    }
  }

  /// JS 侧 Promise 完成时的回调入口。
  void _handleMethodResult(dynamic args) {
    try {
      final data = _parseArgs(args);
      final key = data['key']?.toString() ?? '';
      if (key.isEmpty) return;
      final completer = _pendingMethodCalls[key];
      if (completer == null || completer.isCompleted) return;
      completer.complete(
        _PluginMethodOutcome(
          status: data['status']?.toString() ?? 'resolved',
          value: data['value']?.toString() ?? 'null',
        ),
      );
    } catch (e) {
      _log('[JsEngine] 插件方法回调解析失败: $e');
    }
  }

  Future<String?> callPluginMethod(
    String methodExpression, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    // 并发调用时毫秒时间戳可能重复，追加自增序号保证结果变量唯一，
    // 避免并行调用互相覆盖结果状态。
    final resultVar =
        '__pmr_${DateTime.now().millisecondsSinceEpoch}_${_resultVarSeq++}';

    final wrappedCode =
        '''
var $resultVar = { __status: 'pending', __value: null };
(function() {
  function __notify(status, value) {
    if ($resultVar.__status !== 'pending') return;
    $resultVar.__status = status;
    $resultVar.__value = value;
    try {
      sendMessage('$_methodResultChannel', JSON.stringify({ key: '$resultVar', status: status, value: value }));
    } catch(e) {}
  }
  try {
    var __promise = $methodExpression;
    if (__promise && typeof __promise === 'object' && typeof __promise.then === 'function') {
      __promise.then(function(result) {
        var __value;
        try {
          __value = JSON.stringify(result);
        } catch(e) {
          __value = result != null ? String(result) : 'null';
        }
        __notify('resolved', __value);
      }, function(error) {
        __notify('rejected', (error && error.message) ? error.message : String(error));
      });
    } else {
      var __value2;
      try {
        __value2 = __promise != null ? JSON.stringify(__promise) : 'null';
      } catch(e) {
        __value2 = __promise != null ? String(__promise) : 'null';
      }
      __notify('resolved', __value2);
    }
  } catch(e) {
    __notify('rejected', (e && e.message) ? e.message : String(e));
  }
})();
''';

    final completer = Completer<_PluginMethodOutcome>();
    _pendingMethodCalls[resultVar] = completer;
    try {
      final wrappedEvalResult = evaluate(wrappedCode);
      if (wrappedEvalResult.isError) {
        // 方法表达式同步执行即失败（例如插件脚本递归过深触发 Dart 栈溢出），
        // 直接抛错而不是空转轮询到超时。
        _log(
          '[JsEngine] callPluginMethod 初始化失败: ${wrappedEvalResult.stringResult}',
        );
        throw Exception(wrappedEvalResult.stringResult);
      }
      // 同步返回 / 已 resolve 的 Promise 的 then 回调要等 job 队列被推动，
      // 先推一次，多数调用在这里就能拿到结果。
      _executePendingJob();

      final deadline = DateTime.now().add(timeout);
      // 轮询只用来推 QuickJS 的 job 队列：25ms 起会在插件 Promise 迟迟不
      // 返回时持续占用主 isolate，放宽到 50ms 起、上限仍是 200ms。
      var pollDelay = const Duration(milliseconds: 50);
      var nextFallbackCheck = DateTime.now().add(_methodFallbackInterval);
      while (true) {
        try {
          final outcome = await completer.future.timeout(pollDelay);
          return _mapMethodOutcome(outcome);
        } on TimeoutException {
          // 回调还没来，继续兜底。
        }

        // 回调是主路径，这里只负责把 QuickJS 的 job 队列推起来（插件的
        // then 回调、定时器回调都靠它执行），不再每次都 evaluate 读状态。
        if (!completer.isCompleted) _executePendingJob();

        if (DateTime.now().isAfter(deadline)) {
          _log('[JsEngine] callPluginMethod: 超时 ($timeout)');
          throw TimeoutException('Plugin method timed out after $timeout');
        }

        // 兜底：回调消息万一没投递到，低频读一次状态。
        if (!completer.isCompleted &&
            DateTime.now().isAfter(nextFallbackCheck)) {
          nextFallbackCheck = DateTime.now().add(_methodFallbackInterval);
          final outcome = _readMethodStatus(resultVar);
          if (outcome != null) return _mapMethodOutcome(outcome);
        }

        final nextMs = (pollDelay.inMilliseconds * 1.5).round();
        pollDelay = Duration(milliseconds: nextMs > 200 ? 200 : nextMs);
      }
    } catch (e) {
      _log('[JsEngine] Error calling plugin method: $e');
      rethrow;
    } finally {
      _pendingMethodCalls.remove(resultVar);
      try {
        evaluate('$resultVar = null');
      } catch (_) {}
    }
  }

  /// 兜底读取 JS 里的结果状态；还在 pending 时返回 null。
  _PluginMethodOutcome? _readMethodStatus(String resultVar) {
    final statusResult = evaluate('$resultVar.__status');
    if (statusResult.isError) {
      throw Exception('插件 JS 运行时不可用: ${statusResult.stringResult}');
    }
    final status = statusResult.stringResult;
    if (status != 'resolved' && status != 'rejected') return null;

    final valueResult = evaluate('$resultVar.__value');
    if (valueResult.isError) {
      throw Exception('插件结果读取失败: ${valueResult.stringResult}');
    }
    return _PluginMethodOutcome(
      status: status,
      value: valueResult.stringResult,
    );
  }

  String? _mapMethodOutcome(_PluginMethodOutcome outcome) {
    final value = outcome.value;
    if (outcome.status == 'rejected') {
      _log('[JsEngine] callPluginMethod: Promise被拒绝: $value');
      if (value.isNotEmpty && value != 'null') {
        throw Exception(value);
      }
      return null;
    }

    if (value == 'null' || value == 'undefined' || value.isEmpty) {
      return null;
    }

    // JSON.stringify 过的字符串会带着一层引号：剥掉交给上层的是原始字符串。
    if (value.startsWith('"') && value.endsWith('"')) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is String) return decoded;
        if (decoded is List || decoded is Map) return jsonEncode(decoded);
      } catch (_) {}
    }
    return value;
  }

  void _handleTimerRequest(dynamic args) {
    try {
      final data = _parseArgs(args);
      final timerId = _readTimerId(data['timerId']);
      if (timerId == null || timerId <= 0) return;

      final repeat =
          data['repeat'] == true || data['repeat']?.toString() == 'true';
      final requestedDelay = data['delay'] is num
          ? (data['delay'] as num).round()
          : int.tryParse(data['delay']?.toString() ?? '') ?? 0;
      final minDelay = repeat
          ? _minRepeatTimerDelayMilliseconds
          : _minTimerDelayMilliseconds;
      final delay = requestedDelay
          .clamp(minDelay, _maxTimerDelayMilliseconds)
          .toInt();

      _timers.remove(timerId)?.cancel();
      _activeTimerIds.remove(timerId);
      _repeatTimerIds.remove(timerId);
      if (_activeTimerIds.length >= _maxActiveTimers) {
        _log('[JsEngine] 忽略定时器 $timerId: 已达到 $_maxActiveTimers 个上限');
        return;
      }
      // setInterval 永不自停，单独限量，避免插件开一堆心跳把主线程占满。
      if (repeat && _repeatTimerIds.length >= _maxRepeatTimers) {
        _log('[JsEngine] 忽略周期定时器 $timerId: 已达到 $_maxRepeatTimers 个上限');
        return;
      }

      _activeTimerIds.add(timerId);
      if (repeat) _repeatTimerIds.add(timerId);
      final duration = Duration(milliseconds: delay);
      final timer = repeat
          ? Timer.periodic(duration, (_) => _fireTimer(timerId, repeat: true))
          : Timer(duration, () => _fireTimer(timerId, repeat: false));
      _timers[timerId] = timer;
    } catch (e) {
      _log('[JsEngine] 定时器创建失败: $e');
    }
  }

  void _handleTimerCancel(dynamic args) {
    try {
      final data = _parseArgs(args);
      final timerId = _readTimerId(data['timerId']);
      if (timerId == null) return;
      _timers.remove(timerId)?.cancel();
      _activeTimerIds.remove(timerId);
      _repeatTimerIds.remove(timerId);
    } catch (e) {
      _log('[JsEngine] 定时器取消失败: $e');
    }
  }

  int? _readTimerId(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  void _fireTimer(int timerId, {required bool repeat}) {
    if (!_activeTimerIds.contains(timerId) || _runtimeFaulted) return;
    if (!repeat) {
      _timers.remove(timerId);
      _activeTimerIds.remove(timerId);
      _repeatTimerIds.remove(timerId);
    }
    // 秒级熔断：即使插件开了多个短间隔定时器，也不让回调把主 isolate 打满。
    final now = DateTime.now();
    final windowStart = _timerFireWindowStart;
    if (windowStart == null ||
        now.difference(windowStart) >= const Duration(seconds: 1)) {
      _timerFireWindowStart = now;
      _timerFireCount = 0;
      _timerFireThrottled = false;
    }
    if (++_timerFireCount > _maxTimerFiresPerSecond) {
      if (!_timerFireThrottled) {
        _timerFireThrottled = true;
        _log('[JsEngine] 定时器回调过密，已限流');
      }
      return;
    }
    try {
      final result = evaluate('__mintFireTimer($timerId)');
      if (result.isError) {
        _log('[JsEngine] 定时器回调失败: ${result.stringResult}');
      }
      _executePendingJob();
    } catch (e) {
      _log('[JsEngine] 定时器回调异常: $e');
    }
  }

  void _markRuntimeFaulted() {
    if (_runtimeFaulted) return;
    _runtimeFaulted = true;
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _activeTimerIds.clear();
  }

  void dispose() {
    for (final timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    _activeTimerIds.clear();
    _repeatTimerIds.clear();
    _pluginNoticeController.close();
    // Dio / HttpClient 持有连接池和 socket，插件反复安装、卸载、重载会重建
    // 所有 engine，不关会在进程里累积文件句柄。
    if (_initialized) _dio.close(force: true);
    _httpClient?.close(force: true);
    _httpClient = null;
    _runtime?.dispose();
    _runtime = null;
    _initialized = false;
    _runtimeFaulted = false;
  }
}

/// 插件方法 Promise 的结果：`status` 为 resolved / rejected，`value` 是 JSON 文本。
class _PluginMethodOutcome {
  const _PluginMethodOutcome({required this.status, required this.value});

  final String status;
  final String value;
}

class _DerReader {
  _DerReader(List<int> bytes) : _bytes = Uint8List.fromList(bytes);

  final Uint8List _bytes;
  int _offset = 0;

  int peekTag() {
    if (_offset >= _bytes.length) return -1;
    return _bytes[_offset];
  }

  _DerReader readSequence() {
    _expectTag(0x30);
    final length = _readLength();
    return _DerReader(_readBytes(length));
  }

  BigInt readInteger() {
    _expectTag(0x02);
    final length = _readLength();
    return _bytesToBigInt(_readBytes(length));
  }

  List<int> readBitString() {
    _expectTag(0x03);
    final length = _readLength();
    final bytes = _readBytes(length);
    if (bytes.isEmpty) return const [];
    return bytes.sublist(1);
  }

  void _expectTag(int tag) {
    if (_offset >= _bytes.length || _bytes[_offset] != tag) {
      final actual = _offset >= _bytes.length ? -1 : _bytes[_offset];
      throw FormatException('Unexpected DER tag: $actual, expected: $tag');
    }
    _offset++;
  }

  int _readLength() {
    if (_offset >= _bytes.length) {
      throw const FormatException('Invalid DER length');
    }
    final first = _bytes[_offset++];
    if ((first & 0x80) == 0) return first;
    final count = first & 0x7f;
    var length = 0;
    for (var i = 0; i < count; i++) {
      if (_offset >= _bytes.length) {
        throw const FormatException('Invalid DER long length');
      }
      length = (length << 8) | _bytes[_offset++];
    }
    return length;
  }

  List<int> _readBytes(int length) {
    if (_offset + length > _bytes.length) {
      throw const FormatException('DER length exceeds buffer');
    }
    final result = _bytes.sublist(_offset, _offset + length);
    _offset += length;
    return result;
  }

  BigInt _bytesToBigInt(List<int> bytes) {
    var result = BigInt.zero;
    for (final byte in bytes) {
      result = (result << 8) + BigInt.from(byte & 0xff);
    }
    return result;
  }
}
