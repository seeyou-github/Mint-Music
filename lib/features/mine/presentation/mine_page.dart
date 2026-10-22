import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../settings/application/settings_providers.dart';

/// 「我的」一级页面。
///
/// 设置、下载、最近播放、听歌识曲都收在这里作为二级页面入口，
/// 一级导航只保留发现 / 歌单 / 本地 / 我的。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final isTablet = ResponsiveLayout.isTablet(context);
    final hPadding = ResponsiveLayout.horizontalPadding(context);

    final versionAsync = ref.watch(appVersionProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            hPadding,
            AppSpacing.md,
            hPadding,
            AppSpacing.miniPlayerHeight + AppSpacing.xxxl,
          ),
          children: [
            Row(
              // 版本号在右上角，与标题顶部对齐。
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    context.tr('我的'),
                    style: TextStyle(
                      fontSize: isTablet ? 26 : 22,
                      fontWeight: FontWeight.bold,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                // 应用版本号放在标题栏右侧
                versionAsync.when(
                  data: (version) => Text(
                    'v$version',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: colors.primary,
                    ),
                  ),
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            // 每个入口单独一组（组与组之间留间距）
            _buildEntryGroup(context, colors, [
              _MineEntry(
                icon: Icons.history,
                title: '最近播放',
                route: AppRoutes.recentlyPlayed,
              ),
            ]),
            const SizedBox(height: AppSpacing.md),
            _buildEntryGroup(context, colors, [
              _MineEntry(
                icon: Icons.extension_outlined,
                title: '插件管理',
                route: AppRoutes.pluginManagement,
              ),
            ]),
            const SizedBox(height: AppSpacing.md),
            _buildEntryGroup(context, colors, [
              _MineEntry(
                icon: Icons.settings_outlined,
                title: '设置',
                route: AppRoutes.settings,
              ),
            ]),
            const SizedBox(height: AppSpacing.md),
            _buildEntryGroup(context, colors, [
              _MineEntry(
                icon: Icons.download_outlined,
                title: '下载',
                route: AppRoutes.download,
              ),
            ]),
            // 听歌识曲的音频指纹模块依赖 WebView 运行时，Windows 端不可用，隐藏入口。
            if (!Platform.isWindows) ...[
              const SizedBox(height: AppSpacing.md),
              _buildEntryGroup(context, colors, [
                _MineEntry(
                  icon: Icons.mic_none,
                  title: '听歌识曲',
                  route: AppRoutes.recognize,
                ),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  /// 一组入口（组内用分割线隔开，组与组之间由调用方留间距）。
  Widget _buildEntryGroup(
    BuildContext context,
    ThemeColors colors,
    List<_MineEntry> entries,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
      ),
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            _buildEntryTile(context, colors, entries[i]),
            if (i != entries.length - 1)
              Divider(
                height: 1,
                indent: 56,
                color: colors.divider.withValues(alpha: 0.5),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildEntryTile(
    BuildContext context,
    ThemeColors colors,
    _MineEntry entry,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.lg),
      onTap: () => context.push(entry.route),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Icon(entry.icon, size: 20, color: colors.primary),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              // 只有标题：Row 默认垂直居中，图标 / 文字 / 箭头对齐。
              child: Text(
                context.tr(entry.title),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: colors.textPrimary,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 20, color: colors.textHint),
          ],
        ),
      ),
    );
  }
}

class _MineEntry {
  const _MineEntry({
    required this.icon,
    required this.title,
    required this.route,
  });

  final IconData icon;
  final String title;
  final String route;
}
