import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';

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
            Text(
              context.tr('我的'),
              style: TextStyle(
                fontSize: isTablet ? 26 : 22,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            _buildProfileCard(context, colors),
            const SizedBox(height: AppSpacing.lg),
            _buildEntryCard(context, colors),
          ],
        ),
      ),
    );
  }

  Widget _buildProfileCard(BuildContext context, ThemeColors colors) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: Image.asset(
              'assets/images/MintMusicLogo.png',
              width: 56,
              height: 56,
              fit: BoxFit.cover,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('薄荷音乐'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.tr('发现、收藏并播放你喜欢的音乐'),
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEntryCard(BuildContext context, ThemeColors colors) {
    final entries = <_MineEntry>[
      _MineEntry(
        icon: Icons.extension_outlined,
        title: '插件管理',
        subtitle: '插件的安装、启用与更新',
        route: AppRoutes.pluginManagement,
      ),
      _MineEntry(
        icon: Icons.settings_outlined,
        title: '设置',
        subtitle: '外观、播放与存储管理',
        route: AppRoutes.settings,
      ),
      _MineEntry(
        icon: Icons.download_outlined,
        title: '下载',
        subtitle: '下载管理与下载记录',
        route: AppRoutes.download,
      ),
      _MineEntry(
        icon: Icons.history,
        title: '最近播放',
        subtitle: '查看最近听过的歌曲',
        route: AppRoutes.recentlyPlayed,
      ),
      _MineEntry(
        icon: Icons.mic_none,
        title: '听歌识曲',
        subtitle: '识别周围正在播放的音乐',
        route: AppRoutes.recognize,
      ),
    ];

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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr(entry.title),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.tr(entry.subtitle),
                    style: TextStyle(fontSize: 12, color: colors.textHint),
                  ),
                ],
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
    required this.subtitle,
    required this.route,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final String route;
}
