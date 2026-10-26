import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';

/// 列表底部的分页条：上一页 / 页码 / 下一页。
///
/// 页码只给「能点到」的窗口（首尾 + 当前页附近），中间用省略号，避免页数多了
/// 以后挤成一片。当前页高亮，加载中时禁用点击。
class PageBar extends ConsumerWidget {
  const PageBar({
    super.key,
    required this.currentPage,
    required this.pageCount,
    required this.onChanged,
    this.loading = false,
    this.padding,
  });

  final int currentPage;
  final int pageCount;
  final ValueChanged<int> onChanged;
  final bool loading;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final pages = _windowPages(currentPage, pageCount);
    return Padding(
      padding:
          padding ??
          const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          _buildStepButton(
            colors,
            label: context.tr('上一页'),
            icon: Icons.chevron_left,
            enabled: currentPage > 1 && !loading,
            onTap: () => onChanged(currentPage - 1),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final page in pages) ...[
                    if (page == null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.xs,
                        ),
                        child: Text(
                          '…',
                          style: TextStyle(color: colors.textHint),
                        ),
                      )
                    else
                      _buildPageButton(
                        colors,
                        page: page,
                        selected: page == currentPage,
                        enabled: !loading,
                      ),
                    const SizedBox(width: AppSpacing.xs),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildStepButton(
            colors,
            label: loading ? context.tr('加载中') : context.tr('下一页'),
            icon: Icons.chevron_right,
            iconAfter: true,
            enabled: currentPage < pageCount && !loading,
            onTap: () => onChanged(currentPage + 1),
          ),
        ],
      ),
    );
  }

  Widget _buildStepButton(
    ThemeColors colors, {
    required String label,
    required IconData icon,
    required bool enabled,
    required VoidCallback onTap,
    bool iconAfter = false,
  }) {
    final color = enabled ? colors.textSecondary : colors.textHint;
    final children = <Widget>[
      if (!iconAfter) Icon(icon, size: 16, color: color),
      Flexible(
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: color),
        ),
      ),
      if (iconAfter) Icon(icon, size: 16, color: color),
    ];
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: enabled
                ? colors.divider
                : colors.divider.withValues(alpha: 0.4),
          ),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: children),
      ),
    );
  }

  Widget _buildPageButton(
    ThemeColors colors, {
    required int page,
    required bool selected,
    required bool enabled,
  }) {
    final active = selected;
    return GestureDetector(
      onTap: enabled && !selected ? () => onChanged(page) : null,
      child: Container(
        constraints: const BoxConstraints(minWidth: 30),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: active ? colors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: active ? colors.primary : colors.divider),
        ),
        child: Text(
          '$page',
          style: TextStyle(
            fontSize: 12,
            fontWeight: active ? FontWeight.w600 : FontWeight.normal,
            color: active ? colors.textOnPrimary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 首尾 + 当前页附近的页码窗口，中间用 null 表示省略号。
  static List<int?> _windowPages(int current, int count) {
    if (count <= 7) {
      return [for (var i = 1; i <= count; i++) i];
    }
    final keep = <int>{1, count, current, current - 1, current + 1};
    final sorted = keep.where((p) => p >= 1 && p <= count).toList()..sort();
    final result = <int?>[];
    for (var i = 0; i < sorted.length; i++) {
      if (i > 0 && sorted[i] - sorted[i - 1] > 1) result.add(null);
      result.add(sorted[i]);
    }
    return result;
  }
}
