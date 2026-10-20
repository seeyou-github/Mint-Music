import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'webview_availability.dart';

/// 全局 AMLL 歌词引擎开关（单例）
///
/// 使用 [ChangeNotifier] 而非 Riverpod 的 [StateProvider]，
/// 避免在特定路由/作用域下 Provider 值不同步的问题。
///
/// [LyricPage] 和设置页通过 [addListener] / [ListenableBuilder] 共享同一实例，
/// 保证开关值的实时同步。
class AmllToggleService extends ChangeNotifier {
  // ---- 单例 ----
  static final AmllToggleService _instance = AmllToggleService._();
  factory AmllToggleService() => _instance;
  AmllToggleService._();

  static const String _prefsKey = 'amll_lyric_enabled';

  bool _enabled = true;
  SharedPreferences? _prefs;

  /// 当前是否启用了 AMLL 歌词引擎
  bool get enabled => _enabled;

  /// 当前平台是否支持 AMLL 歌词引擎。
  ///
  /// AMLL 依赖 WebView 渲染歌词。Windows 需要 Microsoft Edge WebView2 运行时，
  /// 没装运行时 WebView 无法创建，歌词层就显示不出来（此时统一使用原生歌词
  /// 渲染，桌面歌词窗口也是原生渲染，所以不受影响）。
  static bool get isPlatformSupported => WebViewAvailability.isAvailable;

  /// 是否真正生效的 AMLL 开关（受平台支持情况约束）。
  bool get isActive => _enabled && isPlatformSupported;

  /// 设置开关值（立即通知监听者）
  set enabled(bool value) {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
  }

  /// 从 SharedPreferences 初始化（用于启动时）
  Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _prefs = prefs;
      _enabled = prefs.getBool(_prefsKey) ?? true;
      notifyListeners();
      debugPrint('[AmllToggle] loaded: $_enabled');
    } catch (e) {
      debugPrint('[AmllToggle] load error: $e');
    }
  }

  /// 持久化到 SharedPreferences
  Future<void> saveToPrefs() async {
    try {
      final prefs = _prefs ??= await SharedPreferences.getInstance();
      await prefs.setBool(_prefsKey, _enabled);
      debugPrint('[AmllToggle] saved: $_enabled');
    } catch (e) {
      debugPrint('[AmllToggle] save error: $e');
    }
  }

  /// 切换并持久化（方便外部调用）
  Future<void> setAndPersist(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    notifyListeners();
    await saveToPrefs();
  }
}
