import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// 桌面端（Windows/macOS/Linux）的 AFP 音频指纹桥接。
///
/// `webview_flutter` 只实现了 Android/iOS，桌面端调用会抛
/// MissingPluginException，导致「音频指纹模块初始化失败」。这里改用
/// [InAppWebView]（Windows 走 WebView2）承载 `afp.js` + `afp.wasm`：
///
/// * `afp.js` 直接内联进 HTML，保证 `GenerateFP` 落在全局作用域；
/// * `afp.wasm` 以 base64 形式在页面加载完成后注入到 `window.WASM_BINARY`；
/// * 指纹计算通过 JS channel（`FpChannel`）回传。
///
/// 需要由宿主组件（见 `AfpWebViewHost`）创建 WebView 并把控制器交给本类。
class DesktopFingerprintBridge {
  InAppWebViewController? _controller;
  bool _ready = false;
  bool _pageLoaded = false;
  bool _checking = false;
  Completer<bool>? _readyCompleter;
  int _requestId = 0;
  final Map<int, Completer<String?>> _pendingRequests = {};
  String? _wasmBase64;

  /// 缓存的 HTML（内联 afp.js），全局复用。
  static String? _cachedHtml;

  /// 宿主组件创建 WebView 后调用。
  void attach(InAppWebViewController controller) {
    _controller = controller;
    controller.addJavaScriptHandler(
      handlerName: 'FpChannel',
      callback: (args) {
        if (args.isEmpty) return null;
        _onJsMessage(args.first.toString());
        return null;
      },
    );
  }

  /// 页面加载完成后由宿主组件调用：注入 WASM 并等待 GenerateFP 就绪。
  Future<void> onPageLoaded() async {
    final controller = _controller;
    if (controller == null) return;
    try {
      if (_wasmBase64 == null) {
        final wasmData = await rootBundle.load('assets/afp/afp.wasm');
        _wasmBase64 = base64.encode(
          wasmData.buffer.asUint8List(
            wasmData.offsetInBytes,
            wasmData.lengthInBytes,
          ),
        );
      }
      // 分块注入，避免单次执行的 JS 过大被 WebView 拒绝。
      const chunkSize = 60000;
      final base64Data = _wasmBase64!;
      await controller.runJavaScript('window.WASM_BINARY = "";');
      for (var i = 0; i < base64Data.length; i += chunkSize) {
        final end = i + chunkSize;
        final chunk = end < base64Data.length
            ? base64Data.substring(i, end)
            : base64Data.substring(i);
        await controller.runJavaScript(
          'window.WASM_BINARY += "$chunk";',
        );
      }
      _pageLoaded = true;
    } catch (e) {
      debugPrint('[AFP-Desktop] 注入 WASM 失败: $e');
    }
    await _waitForGenerateFp();
  }

  /// 初始化（等待 WebView 就绪）。超时返回 false。
  Future<bool> initialize() async {
    if (_ready) return true;
    final completer = _readyCompleter ??= Completer<bool>();
    if (_pageLoaded && _controller != null) {
      unawaited(_waitForGenerateFp());
    }
    return completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => false,
    );
  }

  Future<void> _waitForGenerateFp() async {
    if (_ready || _checking) return;
    _checking = true;
    final controller = _controller;
    if (controller == null) {
      _checking = false;
      return;
    }
    try {
      for (var i = 0; i < 60; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        try {
          final result = await controller.runJavaScriptReturningResult(
            'typeof GenerateFP === "function" ? "ready" : "not_ready"',
          );
          if (result.toString() == '"ready"') {
            _ready = true;
            debugPrint('[AFP-Desktop] GenerateFP 已就绪');
            final completer = _readyCompleter;
            if (completer != null && !completer.isCompleted) {
              completer.complete(true);
            }
            return;
          }
        } catch (e) {
          debugPrint('[AFP-Desktop] 检查 GenerateFP 失败: $e');
        }
      }
      debugPrint('[AFP-Desktop] GenerateFP 初始化超时');
      final completer = _readyCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(false);
      }
    } finally {
      _checking = false;
    }
  }

  /// 从 8kHz 单声道 PCM 数据生成音频指纹（base64）。
  Future<String?> generateFingerprint(Float32List pcm8k) async {
    if (!_ready) {
      final ok = await initialize();
      if (!ok) return null;
    }
    final controller = _controller;
    if (controller == null) return null;

    try {
      final requestId = ++_requestId;
      final completer = Completer<String?>();
      _pendingRequests[requestId] = completer;

      final pcmBytes = pcm8k.buffer.asUint8List(
        pcm8k.offsetInBytes,
        pcm8k.lengthInBytes,
      );
      final pcmBase64 = base64.encode(pcmBytes);

      await controller.runJavaScript(
        'window.generateFingerprint($requestId, "$pcmBase64");',
      );

      return await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          _pendingRequests.remove(requestId);
          debugPrint('[AFP-Desktop] 指纹生成超时');
          return null;
        },
      );
    } catch (e) {
      debugPrint('[AFP-Desktop] 指纹生成失败: $e');
      return null;
    }
  }

  /// 处理 JS channel 消息。
  void _onJsMessage(String message) {
    try {
      final data = jsonDecode(message) as Map<String, dynamic>;
      final requestId = data['requestId'] as int?;
      if (requestId == null) return;
      final completer = _pendingRequests.remove(requestId);
      if (completer == null) return;

      final error = data['error'] as String?;
      final fingerprint = data['fingerprint'] as String?;
      if (error != null && error.isNotEmpty) {
        debugPrint('[AFP-Desktop] JS 报错: $error');
        completer.complete(null);
      } else if (fingerprint != null) {
        debugPrint('[AFP-Desktop] 指纹生成成功, 长度=${fingerprint.length}');
        completer.complete(fingerprint);
      } else {
        completer.complete(null);
      }
    } catch (e) {
      debugPrint('[AFP-Desktop] 解析 JS 消息失败: $e');
    }
  }

  /// 释放资源（宿主 WebView 组件销毁时调用）。
  void dispose() {
    _controller = null;
    _ready = false;
    _pageLoaded = false;
    _checking = false;
    _pendingRequests.clear();
    final completer = _readyCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    }
    _readyCompleter = null;
  }

  /// 构建承载 afp.js 的 HTML（内联脚本，保证函数在全局作用域）。
  static Future<String> buildHtml() async {
    final cached = _cachedHtml;
    if (cached != null) return cached;

    final afpJs = await rootBundle.loadString('assets/afp/afp.js');
    // 内联脚本里不能出现 </script>，否则会提前结束脚本块。
    final safeJs = afpJs.replaceAll('</script', '<\\/script');
    final html = '''
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body>
<script>
globalThis.b64decode = function (data) {
  return Uint8Array.from(atob(data), function (c) { return c.charCodeAt(0); });
};
globalThis.b64encode = function (data) {
  return btoa(String.fromCharCode.apply(null, data));
};
function fpPost(payload) {
  try {
    if (window.flutter_inappwebview && window.flutter_inappwebview.callHandler) {
      window.flutter_inappwebview.callHandler('FpChannel', JSON.stringify(payload));
    }
  } catch (e) {}
}
</script>
<script>
$safeJs
</script>
<script>
window.generateFingerprint = function (requestId, pcmBase64) {
  try {
    var binaryStr = atob(pcmBase64);
    var bytes = new Uint8Array(binaryStr.length);
    for (var i = 0; i < binaryStr.length; i++) {
      bytes[i] = binaryStr.charCodeAt(i);
    }
    var pcmData = new Float32Array(bytes.buffer);
    if (typeof GenerateFP === 'function') {
      GenerateFP(pcmData).then(function (fp) {
        fpPost({ requestId: requestId, fingerprint: fp, error: null });
      }).catch(function (err) {
        fpPost({ requestId: requestId, fingerprint: null, error: String(err) });
      });
    } else {
      fpPost({ requestId: requestId, fingerprint: null, error: 'GenerateFP not available' });
    }
  } catch (e) {
    fpPost({ requestId: requestId, fingerprint: null, error: String(e) });
  }
};
</script>
</body>
</html>''';
    _cachedHtml = html;
    return html;
  }
}
