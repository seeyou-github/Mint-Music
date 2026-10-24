import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../features/plugin/application/plugin_providers.dart';
import '../../features/plugin/domain/plugin_types.dart';
import 'source_icon.dart';

/// 音源名称标签（详情页头部 / 歌曲列表通用）。
///
/// 名称最长 [maxNameLength] 个字，超出截断省略；[onTap] 非空时可以点击
/// （用于切换详情页绑定音源，右侧带切换图标提示）。
class SourceNameTag extends StatelessWidget {
  const SourceNameTag({
    super.key,
    required this.label,
    required this.colors,
    this.onTap,
    this.fontSize = 11,
  });

  /// 名称最长显示多少个字，超出部分省略。
  static const int maxNameLength = 10;

  final String label;
  final ThemeColors colors;
  final VoidCallback? onTap;

  final double fontSize;

  /// 名称超过 10 个字时截断加省略号。
  static String shorten(String name) {
    final trimmed = name.trim();
    return trimmed.length > maxNameLength
        ? '${trimmed.substring(0, maxNameLength)}…'
        : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final clickable = onTap != null;
    final tag = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: clickable ? 0.14 : 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(
          color: colors.primary.withValues(alpha: clickable ? 0.45 : 0.22),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq, size: 12, color: colors.primary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              shorten(label),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w600,
                color: colors.primary,
              ),
            ),
          ),
          if (clickable) ...[
            const SizedBox(width: 2),
            Icon(Icons.swap_horiz, size: 12, color: colors.primary),
          ],
        ],
      ),
    );
    if (!clickable) return tag;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: tag,
    );
  }
}

/// 弹出「用户已安装的音源插件」列表让用户选择，返回选中的音源 id；
/// 取消返回 null。
///
/// 只列用户安装的插件音源（内置音源不参与绑定切换），且只列能解析播放
/// 地址的（绑定后无法解析地址的音源没有意义）。
Future<String?> showPluginSourcePicker(
  BuildContext context,
  WidgetRef ref, {
  String? currentSourceId,
}) async {
  final manager = ref.read(musicSourceManagerProvider);
  final sources = manager.playbackPluginSources();
  if (sources.isEmpty) return null;

  final colors = ref.read(themeColorsProvider);
  return showModalBottomSheet<String>(
    context: context,
    backgroundColor: colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.lg,
              AppSpacing.xs,
            ),
            child: Text(
              ctx.tr('切换绑定音源'),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              ctx.tr('选择后当前歌单内的歌曲将优先使用该音源播放'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final source in sources)
                  ListTile(
                    dense: true,
                    leading: SourceIcon(
                      sourceId: SourceInfo.baseIdOf(source.id),
                      size: 22,
                      label: source.name,
                    ),
                    title: Text(
                      SourceNameTag.shorten(source.name),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        color: source.id == currentSourceId
                            ? colors.primary
                            : colors.textPrimary,
                        fontWeight: source.id == currentSourceId
                            ? FontWeight.w600
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: source.id == currentSourceId
                        ? Icon(Icons.check, size: 18, color: colors.primary)
                        : null,
                    onTap: () => Navigator.of(ctx).pop(source.id),
                  ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}
