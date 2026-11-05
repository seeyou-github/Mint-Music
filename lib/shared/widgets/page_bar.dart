import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/utils/responsive_layout.dart';
import '../../features/player/application/mini_player_visibility.dart';

/// 列表底部的胶囊分页条，加载中禁用导航。
///
/// 布局规则（按宽度自适应，整行铺满、间距均分）：
/// - 所有页码都能放下 → 只显示页码按钮，**不显示「第 N 页」下拉**；
/// - 放不下时 → 首页 + 当前页前后各一页 + 末页，跨页用省略号，
///   右侧紧跟「第 N 页」下拉（下拉紧挨着最后一个页码按钮）；
/// - 宽屏（>=760）额外在两端加「上一页 / 下一页」。
/// - 整行横向铺满：第一个元素贴列表左边、最后一个贴右边，和上方的
///   歌单 / 歌曲列表左右边缘对齐，中间的空隙均分。
///
/// [docked] 为 true 时表示分页条**常驻在内容区底部**（不是列表项），
/// 会给自身补一段下内边距避开 Android 的迷你播放器，避免被播放栏盖住。
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
    this.docked = false,
  });

  final int currentPage;
  final int pageCount;
  final ValueChanged<int> onChanged;
  final bool loading;
  final EdgeInsetsGeometry? padding;

  /// 常驻底部：自动让开迷你播放器。
  final bool docked;

  @override
  ConsumerState<PageBar> createState() => _PageBarState();
}

class _PageBarState extends ConsumerState<PageBar> {
  /// 页码按钮：最小宽度 + 左右内边距 + 间距（真实宽度按文字量出来）。
  static const double _buttonMinWidth = 28;
  static const double _buttonHeight = 36;
  static const double _buttonPadding = 6;
  static const double _elementGap = 2;

  /// 宽屏的「上一页 / 下一页」估算宽度、与页码区的间距。
  static const double _stepButtonWidth = 78;
  static const double _stepGap = AppSpacing.sm;

  static const double _wideBreakpoint = 760;
  static const double _menuItemHeight = 44;

  /// 页码下拉一次最多显示几行，超出部分滚动。
  static const int _maxMenuRows = 9;

  static const TextStyle _numberStyle = TextStyle(fontSize: 12);

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
    final miniPlayerVisible = ref.watch(miniPlayerVisibleProvider);
    // 只有 1 页：页码、上一页/下一页、下拉都没什么可翻的，分页条本身不显示。
    // 但常驻底部的位置不能空着——迷你播放器浮在页面之上，留一段空白让
    // 列表最后一行能滚到播放栏上方（分页条不出现时就没有别的让位手段了）。
    if (_count <= 1) {
      if (!widget.docked) return const SizedBox.shrink();
      return SizedBox(
        height: ResponsiveLayout.batchBarBottomInset(
          context,
          miniPlayerVisible: miniPlayerVisible,
        ),
      );
    }
    final colors = ref.watch(themeColorsProvider);

    // 常驻底部时让开迷你播放器（没歌在播、或当前页面隐藏了播放栏时不用让）。
    final bottomInset = widget.docked
        ? ResponsiveLayout.batchBarBottomInset(
            context,
            miniPlayerVisible: miniPlayerVisible,
          )
        : 0.0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Padding(
        padding:
            widget.padding ??
            const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= _wideBreakpoint;
            final stepArea = wide ? (_stepButtonWidth + _stepGap) * 2 : 0.0;
            final budget = constraints.maxWidth - stepArea;

            // 1) 先试「所有页码都显示」：放得下就不需要下拉。
            final allPages = <int?>[
              for (var page = 1; page <= _count; page++) page,
            ];
            var showDropdown = false;
            List<int?> pages;
            if (_windowWidth(context, allPages) <= budget) {
              pages = allPages;
            } else {
              // 2) 放不下才出现省略号 + 下拉。当前页前后各留一页（9 10 11），
              //    再缩就只能去掉相邻页了，所以半径最小为 1。
              showDropdown = true;
              final dropdownWidth = _dropdownWidth(context);
              final maxRadius = wide ? 5 : 4;
              var radius = maxRadius;
              pages = _windowPages(_current, _count, radius);
              while (radius > 1 &&
                  _windowWidth(context, pages) + _elementGap + dropdownWidth >
                      budget) {
                radius--;
                pages = _windowPages(_current, _count, radius);
              }
            }

            final pageChildren = <Widget>[
              for (final page in pages)
                page == null
                    ? _buildEllipsis(context, colors)
                    : _buildPageButton(context, colors, page),
              if (showDropdown) ...[
                const SizedBox(width: AppSpacing.xs),
                _buildDropdown(colors),
              ],
            ];

            final children = <Widget>[
              if (wide) ...[
                _buildStepButton(
                  colors,
                  label: widget.loading ? context.tr('加载中') : context.tr('上一页'),
                  icon: Icons.chevron_left,
                  enabled: _current > 1 && !widget.loading,
                  onTap: () => _go(_current - 1),
                ),
                const SizedBox(width: _stepGap),
              ],
              ...pageChildren,
              if (wide) ...[
                const SizedBox(width: _stepGap),
                _buildStepButton(
                  colors,
                  label: widget.loading ? context.tr('加载中') : context.tr('下一页'),
                  icon: Icons.chevron_right,
                  iconAfter: true,
                  enabled: _current < _count && !widget.loading,
                  onTap: () => _go(_current + 1),
                ),
              ],
            ];

            // 铺满整行、间距均分：第一个页码贴左边、「第 N 页」下拉贴右边，
            // 左右边缘和上方的歌单 / 歌曲列表对齐（以前整组居中，比列表窄一截，
            // 看起来像浮在中间）。
            final contentWidth =
                _windowWidth(context, pages) +
                (showDropdown ? AppSpacing.xs + _dropdownWidth(context) : 0) +
                (wide ? (_stepButtonWidth + _stepGap) * 2 : 0);
            // 极端窄屏（超大字号 / 极小屏）放不下时退化成可横滚，避免溢出条纹。
            if (contentWidth > constraints.maxWidth) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(mainAxisSize: MainAxisSize.min, children: children),
              );
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: children,
            );
          },
        ),
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
      minimumSize: const Size(_buttonMinWidth, _buttonHeight),
      padding: const EdgeInsets.symmetric(horizontal: _buttonPadding),
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
    return SizedBox(
      height: _buttonHeight,
      child: OutlinedButton(
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
      ),
    );
  }

  Widget _buildPageButton(BuildContext context, ThemeColors colors, int page) {
    final selected = page == _current;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _elementGap / 2),
      child: MergeSemantics(
        child: Semantics(
          selected: selected,
          label: context.tr('第 $page 页'),
          child: SizedBox(
            height: _buttonHeight,
            child: OutlinedButton(
              onPressed: !widget.loading && !selected ? () => _go(page) : null,
              style: _buttonStyle(colors, selected: selected),
              child: ExcludeSemantics(child: Text('$page')),
            ),
          ),
        ),
      ),
    );
  }

  /// 省略号：宽度与相邻元素一致，不参与点击。
  Widget _buildEllipsis(BuildContext context, ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _elementGap / 2),
      child: ExcludeSemantics(
        child: Text(
          '…',
          maxLines: 1,
          style: TextStyle(fontSize: 12, color: colors.textHint),
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
      // 分页条在列表末尾、紧挨着底部播放栏：向下展开会被屏幕底边挤回去，
      // 结果正好压在播放栏上。按菜单高度整体上移，改成向上展开。
      position: PopupMenuPosition.over,
      offset: Offset(0, -(menuHeight + AppSpacing.md)),
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
        height: _buttonHeight,
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
  Widget _buildMenuRow(BuildContext menuContext, ThemeColors colors, int page) {
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

  // ------------------------------------------------------- 宽度估算

  /// 单行文本在当前字体 / 系统字号缩放下的宽度。
  double _textWidth(BuildContext context, String text, TextStyle style) {
    final base = Theme.of(context).textTheme.bodyMedium ?? const TextStyle();
    final painter = TextPainter(
      text: TextSpan(text: text, style: base.merge(style)),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  double _pageButtonWidth(BuildContext context, int page) {
    final text = _textWidth(context, '$page', _numberStyle);
    return math.max(_buttonMinWidth, text + _buttonPadding * 2) + _elementGap;
  }

  double _ellipsisWidth(BuildContext context) =>
      _textWidth(context, '…', _numberStyle) + _elementGap;

  /// 下拉按钮宽度：「第 N 页」文字 + 箭头 + 左右内边距 + 边框。
  double _dropdownWidth(BuildContext context) {
    final text = _textWidth(
      context,
      context.tr('第 $_current 页'),
      const TextStyle(fontSize: 12),
    );
    return text + 18 + AppSpacing.sm * 2 + 4;
  }

  double _windowWidth(BuildContext context, List<int?> pages) {
    var total = 0.0;
    for (final page in pages) {
      total += page == null
          ? _ellipsisWidth(context)
          : _pageButtonWidth(context, page);
    }
    return total;
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
