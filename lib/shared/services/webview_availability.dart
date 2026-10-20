import 'dart:io';

/// WebView 可用性检测。
///
/// Windows 上 InAppWebView 依赖 **Microsoft Edge WebView2 运行时**，
/// 没有安装运行时就无法创建 WebView：
///
/// * 听歌识曲的音频指纹（WASM）跑不了；
/// * AMLL（Apple Music 风格）歌词渲染不出来。
///
/// 这里在首次使用时检测一次并缓存结果，界面上据此给出明确提示
/// （而不是笼统的「初始化失败」）。
class WebViewAvailability {
  WebViewAvailability._();

  static bool? _available;

  /// 当前平台是否有可用的 WebView。
  ///
  /// 非 Windows 平台（Android/iOS/macOS/Linux）自带 WebView，直接返回 true。
  static bool get isAvailable => _available ??= _detect();

  /// 缺少 WebView 运行时时的提示文案。
  static const String missingRuntimeHint =
      '需要安装 Microsoft Edge WebView2 运行时';

  /// WebView2 运行时下载地址。
  static const String webView2DownloadUrl =
      'https://developer.microsoft.com/microsoft-edge/webview2/';

  /// 仅供测试：重置缓存的检测结果。
  static void resetForTest() {
    _available = null;
  }

  static bool _detect() {
    if (!Platform.isWindows) return true;
    if (_hasWebView2Files()) return true;
    return _hasWebView2Registry();
  }

  /// 运行时默认安装在 `EdgeWebView\Application\<版本>\msedgewebview2.exe`。
  static bool _hasWebView2Files() {
    final roots = <String>[
      _env('ProgramFiles(x86)') ?? '',
      _env('ProgramFiles') ?? '',
      _env('LocalAppData') ?? '',
    ];
    for (final root in roots) {
      if (root.isEmpty) continue;
      final dir = Directory(
        '$root${Platform.pathSeparator}Microsoft'
        '${Platform.pathSeparator}EdgeWebView'
        '${Platform.pathSeparator}Application',
      );
      if (!dir.existsSync()) continue;
      try {
        for (final version in dir.listSync(followLinks: false)) {
          if (version is! Directory) continue;
          final exe = File(
            '${version.path}${Platform.pathSeparator}msedgewebview2.exe',
          );
          if (exe.existsSync()) return true;
        }
      } catch (_) {}
    }
    return false;
  }

  /// 兜底：查注册表里的 EdgeUpdate 客户端（WebView2 Runtime 的 GUID）。
  static bool _hasWebView2Registry() {
    const guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
    const keys = [
      'HKLM\\SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\',
      'HKLM\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\',
      'HKCU\\SOFTWARE\\Microsoft\\EdgeUpdate\\Clients\\',
    ];
    for (final prefix in keys) {
      try {
        final result = Process.runSync('reg', [
          'query',
          '$prefix$guid',
          '/v',
          'pv',
        ]);
        if (result.exitCode != 0) continue;
        final output = '${result.stdout}'.toLowerCase();
        if (output.contains('pv') && !output.contains('0.0.0.0')) {
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  static String? _env(String name) {
    final value = Platform.environment[name];
    if (value == null || value.isEmpty) return null;
    return value;
  }
}
