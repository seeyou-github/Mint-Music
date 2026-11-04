import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';

/// 列表底部的胶囊分页条，加载中禁用导航。
///
/// - 窄屏（<760）：页码按钮 + 「第 N 页」下拉。页码窗口按宽度自适应：
///   首页 + 当前页附近的页码 + 末页，跨页用省略号；宽度不够时缩到只剩
///   首页 / 当前页 / 末页 + 下拉。
/// - 宽屏（>=760）：上一页 + 页码按钮 + 下一页 + 「第 N 页」下拉。
///
/// 「第 N 页」下拉列出全部页码，选一个直达（Windows 上支持滚轮滚动和
/// 按住鼠标拖动，另有常驻滚动条可拖）。总共只有 1 页时整个分页条不显示。
class PageBar extends ConsumerStatefulWidget {
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
  ConsumerState<PageBar> createState() => _PageBarState();
}

class _PageBarState extends ConsumerState<PageBar> {
  /// 页码按钮 / 省略号 / 步进按钮 / 下拉按钮的估算宽度（算窗口大小时用）。
  static const double _pageButtonWidth = 36;
  static const double _ellipsisWidth = 24;
  static const double _stepButtonWidth = 84;
  static const double _dropdownWidth = 100;
  static const double _elementGap = 4;
  static const double _wideBreakpoint = 760;
  static const double _menuItemHeight = 44;

  /// 页码下拉一次最多显示几行，超出部分滚动。
  static const int _maxMenuRows = 9;

  /// 页码下拉菜单的滚动控制器（Scrollbar 拖动需要）。
  final ScrollController _menuScrollController = ScrollController();

  int get _count => widget.pageCount < 1 ? 1 : widget.pageCount;
  int get _current => widget.currentPage.clamp(1, _count);

  @override
  void dispose() {
    _menuScrollController.dispose();
    super.dispose();
  }

  void _go(int page) {
    if (widget.loading || page < 1 || page > _count || page == _current) return;
    widget.onChanged(page);
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    // 只有 1 页：页码、上一页/下一页、下拉都没什么可翻的，整个分页条不显示。
    if (_count <= 1) return const SizedBox.shrink();
    final colors = ref.watch(themeColorsProvider);
    return Padding(
      padding:
          widget.padding ??
          const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= _wideBreakpoint;
          final radius = _fitRadius(constraints.maxWidth, wide: wide);
          final pages = _windowPages(_current, _count, radius);
          final pageButtons = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final page in pages)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: page == null
                      ? ExcludeSemantics(
                          child: Text(
                            '…',
                            style: TextStyle(color: colors.textHint),
                          ),
                        )
                      : _buildPageButton(colors, page),
                ),
            ],
          );
          final dropdown = _buildDropdown(colors);
          if (!wide) {
            // 窄屏：页码一行 + 右侧下拉（窗口按宽度算好，极端情况页码区可滚）。
            return Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: pageButtons,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                dropdown,
              ],
            );
          }
          final previous = _buildStepButton(
            colors,
            label: widget.loading ? context.tr('加载中') : context.tr('上一页'),
            icon: Icons.chevron_left,
            enabled: _current > 1 && !widget.loading,
            onTap: () => _go(_current - 1),
          );
          final next = _buildStepButton(
            colors,
            label: widget.loading ? context.tr('加载中') : context.tr('下一页'),
            icon: Icons.chevron_right,
            iconAfter: true,
            enabled: _current < _count && !widget.loading,
            onTap: () => _go(_current + 1),
          );
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              previous,
              const SizedBox(width: AppSpacing.sm),
              Flexible(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: pageButtons,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              next,
              const SizedBox(width: AppSpacing.sm),
              dropdown,
            ],
          );
        },
      ),
    );
  }

  ButtonStyle _buttonStyle(ThemeColors colors, {bool selected = false}) {
    return OutlinedButton.styleFrom(
      foregroundColor: selected ? colors.textOnPrimary : colors.textSecondary,
      disabledForegroundColor: selected
          ? colors.textOnPrimary
          : colors.textHint,
      backgroundColor: selected ? colors.primary : Colors.transparent,
      side: BorderSide(color: selected ? colors.primary : colors.divider),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      minimumSize: const Size(32, 40),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
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
    return OutlinedButton(
      onPressed: enabled ? onTap : null,
      style: _buttonStyle(colors),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!iconAfter) Icon(icon, size: 16),
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          if (iconAfter) Icon(icon, size: 16),
        ],
      ),
    );
  }

  Widget _buildPageButton(ThemeColors colors, int page) {
    final selected = page == _current;
    return MergeSemantics(
      child: Semantics(
        selected: selected,
        label: context.tr('第 $page 页'),
        child: OutlinedButton(
          onPressed: !widget.loading && !selected
              ? () => _go(page)
              : null,
          style: _buttonStyle(colors, selected: selected),
          child: ExcludeSemantics(child: Text('$page')),
        ),
      ),
    );
  }

  /// 「第 N 页」下拉：点开列出全部页码，选一个直达。
  ///
  /// 列表可滚动：滚轮直接滚（Windows）、按住鼠标 / 触屏也能拖，
  /// 另有常驻滚动条可拖动快跳。
  Widget _buildDropdown(ThemeColors colors) {
    final menuHeight =
        math.min(_count, _maxMenuRows) * _menuItemHeight + AppSpacing.xs * 2;
    return PopupMenuButton<int>(
      enabled: !widget.loading,
      tooltip: context.tr('跳转到指定页'),
      color: colors.surface,
      elevation: 8,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      onSelected: _go,
      itemBuilder: (_) => [
        PopupMenuItem<int>(
          enabled: false,
          padding: EdgeInsets.zero,
          child: SizedBox(
            width: 148,
            height: menuHeight,
            child: Scrollbar(
              controller: _menuScrollController,
              thumbVisibility: true,
              child: ScrollConfiguration(
                behavior: const _MouseDragScrollBehavior(),
                child: ListView.builder(
                  controller: _menuScrollController,
                  padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  itemCount: _count,
                  itemBuilder: (menuContext, index) =>
                      _buildMenuRow(menuContext, colors, index + 1),
                ),
              ),
            ),
          ),
        ),
      ],
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        decoration: BoxDecoration(
          border: Border.all(color: colors.divider),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr('第 $_current 页'),
              style: TextStyle(
                fontSize: 12,
                color: widget.loading ? colors.textHint : colors.textSecondary,
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 18, color: colors.textHint),
          ],
        ),
      ),
    );
  }

  /// 下拉里的一行页码。[menuContext] 在弹层内部，用于带值关闭弹层。
  Widget _buildMenuRow(
    BuildContext menuContext,
    ThemeColors colors,
    int page,
  ) {
    final selected = page == _current;
    return InkWell(
      onTap: () => Navigator.of(menuContext).pop(page),
      child: SizedBox(
        height: _menuItemHeight,
        child: Row(
          children: [
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                context.tr('第 $page 页'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  color: selected ? colors.primary : colors.textPrimary,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
            if (selected) Icon(Icons.check, size: 16, color: colors.primary),
            const SizedBox(width: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  /// 按可用宽度估当前页两侧最多保留几页：从最大半径往下试，放不下就缩，
  /// 最窄只剩首页 / 当前页 / 末页（+ 省略号）。
  int _fitRadius(double available, {required bool wide}) {
    var reserved = _dropdownWidth + _elementGap;
    if (wide) reserved += (_stepButtonWidth + _elementGap) * 2;
    final budget = available - reserved;
    final maxRadius = wide ? 5 : 3;
    for (var radius = maxRadius; radius >= 0; radius--) {
      final width = _windowPages(_current, _count, radius).fold<double>(
        0,
        (sum, page) =>
            sum +
            (page == null ? _ellipsisWidth : _pageButtonWidth) +
            _elementGap,
      );
      if (width <= budget) return radius;
    }
    return 0;
  }

  /// 页码窗口：首页 + 末页 + 当前页 ± [radius]。页数少到窗口能盖住就全显；
  /// 缺两页以上用省略号（null），只缺一页直接补齐。
  static List<int?> _windowPages(int current, int count, int radius) {
    if (count <= radius * 2 + 1) {
      return [for (var page = 1; page <= count; page++) page];
    }
    final keep = <int>{1, count};
    for (var page = current - radius; page <= current + radius; page++) {
      keep.add(page);
    }
    final sorted = keep.where((page) => page >= 1 && page <= count).toList()
      ..sort();
    final result = <int?>[];
    for (var i = 0; i < sorted.length; i++) {
      if (i > 0) {
        final gap = sorted[i] - sorted[i - 1];
        if (gap == 2) {
          result.add(sorted[i] - 1);
        } else if (gap > 2) {
          result.add(null);
        }
      }
      result.add(sorted[i]);
    }
    return result;
  }
}

/// 页码下拉列表允许鼠标 / 触控板按住拖动滚动（Windows 上默认只有滚轮）。
class _MouseDragScrollBehavior extends MaterialScrollBehavior {
  const _MouseDragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };
}
