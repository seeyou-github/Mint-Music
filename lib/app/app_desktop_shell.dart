import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/router/app_router.dart';
import '../core/theme/theme_provider.dart';
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
    final route = appNavItems[index].route;
    // 已经停留在该一级页面时不做跳转，避免重置当前页面的滚动位置。
    if (appRouter.routerDelegate.currentConfiguration.uri.path == route) return;
    setState(() => _activeIndex = index);
    // 一级页面之间切换（停留在二级页面时会一并返回一级页面）。
    appRouter.go(route);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final showSidebar = ResponsiveLayout.shouldShowSidebar(context);

    // 保持树结构稳定（Row + Expanded 始终存在），
    // 这样窗口在阈值附近缩放时 Router/Navigator 不会被重建，页面状态得以保留。
    return Material(
      color: colors.background,
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
