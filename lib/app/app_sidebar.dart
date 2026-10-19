import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/constants/app_routes.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/utils/responsive_layout.dart';

/// 一级导航项配置，侧边栏与移动端底部导航共用同一份数据。
class AppNavItem {
  const AppNavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String route;
}

const List<AppNavItem> appNavItems = [
  AppNavItem(
    icon: Icons.explore_outlined,
    activeIcon: Icons.explore,
    label: '发现',
    route: AppRoutes.discover,
  ),
  AppNavItem(
    icon: Icons.library_music_outlined,
    activeIcon: Icons.library_music,
    label: '歌单',
    route: AppRoutes.library,
  ),
  AppNavItem(
    icon: Icons.folder_outlined,
    activeIcon: Icons.folder,
    label: '本地',
    route: AppRoutes.local,
  ),
  AppNavItem(
    icon: Icons.download_outlined,
    activeIcon: Icons.download,
    label: '下载',
    route: AppRoutes.download,
  ),
  AppNavItem(
    icon: Icons.settings_outlined,
    activeIcon: Icons.settings,
    label: '设置',
    route: AppRoutes.settings,
  ),
];

/// 桌面/平板左侧固定导航栏。
///
/// 由 [AppDesktopShell] 渲染在路由内容之外，因此歌单详情、榜单详情、
/// 搜索、播放页等二级页面只会占用右侧内容区，不会遮挡导航栏。
class AppSidebar extends ConsumerWidget {
  const AppSidebar({
    super.key,
    required this.currentIndex,
    required this.onSelect,
  });

  /// 当前高亮的一级导航下标。
  final int currentIndex;

  /// 点击导航项回调，参数为 [appNavItems] 中的下标。
  final ValueChanged<int> onSelect;

  /// 根据当前路由地址推导应高亮的一级导航下标。
  ///
  /// 二级页面（歌单详情、搜索、播放页等）返回 null，表示保持上一次高亮，
  /// 这样从一级页面进入二级页面时导航栏不会跳动，返回后仍是原来的分区。
  static int? indexForLocation(String path) {
    if (path.isEmpty) return null;
    for (var i = 0; i < appNavItems.length; i++) {
      final route = appNavItems[i].route;
      if (path == route || path.startsWith('$route/')) return i;
    }
    return null;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isExpanded = ResponsiveLayout.isLandscape(context);

    return Container(
      width: isExpanded
          ? ResponsiveLayout.sidebarWidth
          : ResponsiveLayout.sidebarCollapsedWidth,
      decoration: BoxDecoration(
        color: isDark
            ? colors.surface.withValues(alpha: 0.95)
            : colors.surface.withValues(alpha: 0.98),
        border: Border(
          right: BorderSide(
            color: colors.divider.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Logo / App title
            if (isExpanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.asset(
                        'assets/images/MintMusicLogo.png',
                        width: 32,
                        height: 32,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      context.tr('薄荷音乐'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: colors.textPrimary,
                      ),
                    ),
                  ],
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 24),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.asset(
                    'assets/images/MintMusicLogo.png',
                    width: 36,
                    height: 36,
                    fit: BoxFit.cover,
                  ),
                ),
              ),

            // Navigation items
            Expanded(
              child: ListView.builder(
                padding: EdgeInsets.symmetric(
                  horizontal: isExpanded ? 8 : 6,
                  vertical: 4,
                ),
                itemCount: appNavItems.length,
                itemBuilder: (context, index) {
                  final item = appNavItems[index];
                  return _SidebarNavItem(
                    item: item,
                    isActive: index == currentIndex,
                    isExpanded: isExpanded,
                    colors: colors,
                    onTap: () => onSelect(index),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Sidebar navigation item widget.
class _SidebarNavItem extends StatelessWidget {
  const _SidebarNavItem({
    required this.item,
    required this.isActive,
    required this.isExpanded,
    required this.colors,
    required this.onTap,
  });

  final AppNavItem item;
  final bool isActive;
  final bool isExpanded;
  final ThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 2),
      child: Material(
        color: isActive
            ? colors.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(
              horizontal: isExpanded ? 16 : 0,
              vertical: 12,
            ),
            child: Row(
              mainAxisAlignment:
                  isExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Icon(
                  isActive ? item.activeIcon : item.icon,
                  size: 22,
                  color: isActive ? colors.primary : colors.textSecondary,
                ),
                if (isExpanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      context.tr(item.label),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                        color: isActive ? colors.primary : colors.textSecondary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
