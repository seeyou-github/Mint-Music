import 'package:flutter/foundation.dart';

/// 播放详情页（全屏播放页）是否已打开。
///
/// 左侧栏的封面按钮需要「打开 / 关闭」切换播放详情页。仅靠
/// `GoRouter.routerDelegate.currentConfiguration.uri.path` 判断在
/// StatefulShellRoute 下不够可靠（根级路由压栈时配置里的 uri 可能仍是
/// 分支内的地址），这里由播放详情页自身登记状态，判断更准确。
class FullPlayerVisibility extends ChangeNotifier {
  FullPlayerVisibility._();

  static final FullPlayerVisibility instance = FullPlayerVisibility._();

  bool _visible = false;

  /// 播放详情页当前是否已打开。
  bool get visible => _visible;

  /// 由播放详情页在打开 / 关闭时调用。
  void setVisible(bool value) {
    if (_visible == value) return;
    _visible = value;
    notifyListeners();
  }
}
