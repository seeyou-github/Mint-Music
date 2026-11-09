import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/router/app_router.dart';
import '../core/router/navigation_shell_provider.dart';
import '../core/utils/responsive_layout.dart';
import 'app_sidebar.dart';

/// 桌面/平板下的根布局：左侧固定导航栏 + 右侧路由内容区。
///
/// 该组件放在 `MaterialApp.router` 的 builder 中（Router 之上），
/// 因此所有二级页面（歌单详情、榜单详情、搜索、播放页、设置子页面等）
/// 都只会占据右侧内容区，不会盖住左侧导航栏。
///
/// 手机 / 窄窗口下不显示侧边栏，仅保留原来的底部导航。
class AppDesktopShell extends ConsumerStatefulWidget {
  const AppDesktopShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppDesktopShell> createState() => _AppDesktopShellState();
}

class _AppDesktopShellState extends ConsumerState<AppDesktopShell> {
  /// 二级页面没有独立的一级导航归属，保持进入前的高亮。
  int _activeIndex = 0;

  @override
  void initState() {
    super.initState();
    _activeIndex = _resolveIndex() ?? 0;
    appRouter.routerDelegate.addListener(_handleLocationChanged);
  }

  @override
  void dispose() {
    appRouter.routerDelegate.removeListener(_handleLocationChanged);
    super.dispose();
  }

  int? _resolveIndex() {
    final configuration = appRouter.routerDelegate.currentConfiguration;
    if (configuration.matches.isEmpty) return null;
    return AppSidebar.indexForLocation(configuration.uri.path);
  }

  /// 内容区上是否盖着 `push()` 出来的页面（播放详情页、设置、插件管理…）。
  ///
  /// 这些页面挂在根 navigator 上，会把整个右侧内容区盖住；而 `goBranch`
  /// 只切换 shell 内部的分支，**不会**关掉它们 —— 切完新分类还压在这些
  /// 页面底下，用户看到的就是「点侧栏没反应」。
  bool _hasRootPushedPage() {
    for (final match in appRouter.routerDelegate.currentConfiguration.matches) {
      if (match is ImperativeRouteMatch) return true;
    }
    return false;
  }

  void _handleLocationChanged() {
    final index = _resolveIndex();
    if (index == null || index == _activeIndex) return;
    // 首帧构建时 Router 会解析初始路由并通知监听者，
    // 此时直接 setState 会落在 build 阶段，统一推迟到帧结束再更新高亮。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final current = _resolveIndex();
      if (current != null && current != _activeIndex) {
        setState(() => _activeIndex = current);
      }
    });
  }

  void _handleSelect(int index) {
    // 先关掉盖在内容区上的弹层（底部弹层 / 对话框）：它们挂在根 navigator
    // 上、不属于任何分类分支，不关的话分类切了也被它们盖着，看起来就是
    // 「点了侧栏没反应」——安装插件时点侧栏就是这个现象（高亮变了、页面没变）。
    // 只处理 [PopupRoute]，普通页面（PageRoute）交给下面的 go / goBranch。
    appRouter.routerDelegate.navigatorKey.currentState?.popUntil(
      (route) => route is! PopupRoute,
    );

    final route = appNavItems[index].route;
    final shell = ref.read(navigationShellProvider);

    // 1) 有 push 到根 navigator 的页面（播放页 / 设置 / 插件管理…）时，
    //    直接用 `go` 把栈重置到目标分类 —— 它同时关掉这些页面。
    //    用 goBranch 的话新分类会留在它们底下，表现为「点了没反应」，
    //    高亮还会被紧接着的路由通知改回去。
    if (_hasRootPushedPage() || shell == null) {
      setState(() => _activeIndex = index);
      appRouter.go(route);
      return;
    }

    // 2) 连续点击同一个分类：回到该分类的第一级界面。
    if (index == _activeIndex) {
      shell.goBranch(index, initialLocation: true);
      _ensureBranchSwitched(route);
      return;
    }

    // 3) 普通切换：保留各分支自己的页面栈（切回来时恢复之前打开的二级页）。
    setState(() => _activeIndex = index);
    shell.goBranch(index, initialLocation: false);
    _ensureBranchSwitched(route);
  }

  /// 兜底：`goBranch` 偶尔不生效（导航壳实例被重建后，旧实例切不动分支），
  /// 下一帧发现还停在原路径就改用 `go` 强切，保证点侧栏一定有反馈。
  void _ensureBranchSwitched(String route) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final path = appRouter.routerDelegate.currentConfiguration.uri.path;
      if (path == route || path.startsWith('$route/')) return;
      appRouter.go(route);
    });
  }

  @override
  Widget build(BuildContext context) {
    final showSidebar = ResponsiveLayout.shouldShowSidebar(context);

    // 保持树结构稳定（Row + Expanded 始终存在），
    // 这样窗口在阈值附近缩放时 Router/Navigator 不会被重建，页面状态得以保留。
    return Material(
      color: Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showSidebar)
            AppSidebar(currentIndex: _activeIndex, onSelect: _handleSelect)
          else
            const SizedBox.shrink(),
          Expanded(child: widget.child),
        ],
      ),
    );
  }
}
