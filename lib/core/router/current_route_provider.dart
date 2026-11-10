import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../constants/app_routes.dart';

/// 当前真正显示的页面位置（含 `push()` 推入的页面）。
///
/// 不能用 `routerDelegate.currentConfiguration.uri`：它只反映 `go()` /
/// `goBranch()` 级别的位置，不含任何 `push()` 推入的页面（go_router 里
/// 这些是 `ImperativeRouteMatch`）。这里遍历匹配栈取栈顶，和
/// `playback_source_navigation.dart` 里判断来源页的做法一致。
Uri currentPageUri(GoRouter router) {
  final stack = <Uri>[];
  void walk(Iterable<RouteMatchBase> matches) {
    for (final match in matches) {
      if (match is ShellRouteMatch) {
        walk(match.matches);
      } else if (match is ImperativeRouteMatch) {
        stack.add(match.matches.uri);
        walk(match.matches.matches);
      } else if (match is RouteMatch) {
        stack.add(Uri.parse(match.matchedLocation));
      }
    }
  }

  final configuration = router.routerDelegate.currentConfiguration;
  walk(configuration.matches);
  if (stack.isEmpty) return configuration.uri;
  return stack.last;
}

/// 当前页面路径，由 `AppShell` 在路由变化时写入。
///
/// 其它页面通过它判断「当前是否处在一个需要隐藏迷你播放器的页面」，
/// 以及据此算自己的底部留白（见 [miniPlayerHiddenProvider]）。
final currentRoutePathProvider = StateProvider<String>((ref) => '');

/// 这些页面底部有自己的内容（列表 / 分页条 / 满屏内容），进入时隐藏迷你
/// 播放器，让页面一直铺到底部。
const miniPlayerHiddenRoutes = <String>{
  AppRoutes.settings,
  AppRoutes.download,
  AppRoutes.pluginManagement,
  AppRoutes.recentlyPlayed,
  AppRoutes.recognize,
  AppRoutes.backgroundEditor,
  AppRoutes.blurBackground,
};

/// 当前页面是否要求隐藏迷你播放器。
final miniPlayerHiddenProvider = Provider<bool>((ref) {
  final path = ref.watch(currentRoutePathProvider);
  return miniPlayerHiddenRoutes.contains(path);
});
