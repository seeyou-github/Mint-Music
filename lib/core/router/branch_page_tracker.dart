import 'package:flutter/widgets.dart';

/// 记录某个 [StatefulShellBranch] 自己的页面栈。
///
/// 分支的页面栈在切走之后仍然保留（发现 / 收藏就靠这个恢复歌单详情）。
/// 「我的」则需要在切走时静默关掉设置、插件管理等二级页面：如果交给
/// `goBranch(..., initialLocation: true)` 去摘页面，Flutter 会给被摘掉的
/// 顶页播一遍关闭转场，切回「我的」时就会看到设置页滑出去。
///
/// 要静默关闭就必须拿到具体的 [Route]，用 `NavigatorState.removeRoute`
/// 移除——它不播放任何动画。页面栈靠这个观察者维护。
class BranchPageTracker extends NavigatorObserver {
  final List<Route<dynamic>> _routes = [];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.add(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _routes.remove(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute == null) {
      if (newRoute != null) _routes.add(newRoute);
      return;
    }
    final index = _routes.indexOf(oldRoute);
    if (newRoute == null) {
      if (index >= 0) _routes.removeAt(index);
      return;
    }
    if (index >= 0) {
      _routes[index] = newRoute;
    } else {
      _routes.add(newRoute);
    }
  }

  /// 静默关掉一级页面之上的所有页面（不播放关闭动画）。
  ///
  /// 分支还没创建过（观察者没有挂到 Navigator 上）时什么也不做。
  void closeSecondaryPages() {
    final nav = navigator;
    if (nav == null || _routes.length <= 1) return;
    for (final route in _routes.skip(1).toList().reversed) {
      if (!route.isActive) continue;
      nav.removeRoute(route);
    }
  }
}
