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
/// 布局规则（整组居中、间距固定，各平台一致，和 Android 的分页条一样）：
/// - 所有页码都能放下 → 只显示页码按钮，**不显示「第 N 页」下拉**；
/// - 放不下时 → 首页 + 当前页前后各一页 + 末页，跨页用省略号，
///   右侧紧跟「第 N 页」下拉（下拉紧挨着最后一个页码按钮）；
/// - **不铺满整行、不放「上一页 / 下一页」按钮**：页码少（2 页）时铺满会把
///   两个页码顶到屏幕两端，看起来像坏了一条横贯全屏的空线；翻页直接点页码，
///   跨页由「第 N 页」下拉直达。
///
/// [docked] 为 true 时表示分页条**常驻在内容区底部**（不是列表项），
/// 会给自身补一段下内边距避开 Android 的迷你播放器，避免被播放栏盖住。
///
/// 「第 N 页」下拉只列出**目前能确定的页码**：知道总页数时就是全部页码；
/// 数据源不给总数时只列已经翻到过的页（猜不出来的一律不列）。选一个直达
/// （Windows 上支持滚轮滚动和按住鼠标拖动，另有常驻滚动条可拖）。
///
/// 末页未知时页码行是 `1 2 3 4 5 … 20 …`：20 是已知的最后一页，最后的
/// 省略号可以点，点它继续取下一页。总共只有 1 页时整个分页条不显示。
class PageBar extends ConsumerStatefulWidget {
  const PageBar({
    super.key,
    required this.currentPage,
    required this.pageCount,
    required this.onChanged,
    this.loading = false,
    this.padding,
    this.docked = false,
    this.lastPageKnown = true,
  });

  final int currentPage;
  final int pageCount;
  final ValueChanged<int> onChanged;
  final bool loading;
  final EdgeInsetsGeometry? padding;

  /// 常驻底部：自动让开迷你播放器。
  final bool docked;

  /// 是否确定「最后一页」是第几页。
  ///
  /// 数据源不给总条数、又还没翻到末尾时为 false：这时 [pageCount] 里那个
  /// 尾页是「再多留一页」的入口，并不是真的最后一页。界面上不把它写成页码：
  /// 页码行末尾先显示已知的最后一页，再跟一个可点的省略号
  /// （`1 2 3 4 5 … 20 …`），点省略号去取下一页；「第 N 页」下拉里也只列
  /// 已经知道的页码，不会出现猜出来的页。
  final bool lastPageKnown;

  @override
  ConsumerState<PageBar> createState() => _PageBarState();
}

class _PageBarState extends ConsumerState<PageBar> {
  /// 页码按钮：最小宽度 + 左右内边距 + 间距（真实宽度按文字量出来）。
  static const double _buttonMinWidth = 28;
  static const double _buttonHeight = 36;
  static const double _buttonPadding = 6;
  static const double _elementGap = 2;

  static const double _menuItemHeight = 44;

  /// 页码下拉一次最多显示几行，超出部分滚动。
  static const int _maxMenuRows = 9;

  static const TextStyle _numberStyle = TextStyle(fontSize: 12);

  /// 页码下拉菜单的滚动控制器（Scrollbar 拖动需要）。
  final ScrollController _menuScrollController = ScrollController();

  int get _count => widget.pageCount < 1 ? 1 : widget.pageCount;
  int get _current => widget.currentPage.clamp(1, _count);

  /// 目前能确定存在的页数。
  ///
  /// [PageBar.lastPageKnown] 为 false 时，[pageCount] 的最后一页只是「多留一页」
  /// 的入口（还没取过），所以要减掉；当前页兜底算作已知，避免加载中的瞬时
  /// 状态把页码从页码行里挤掉。下拉框只列到这一页为止。
  int get _knownCount =>
      widget.lastPageKnown ? _count : math.max(_current, _count - 1);

  /// 末页未知、且后面还有没取过的页：页码行末尾那格是「…」入口，点它取下一页。
  bool get _hasMorePage => !widget.lastPageKnown && _knownCount < _count;

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

  /// 分页条与底部迷你播放器之间的让位高度。
  ///
  /// 用 `miniPlayerReservedHeight`（播放器高度 + 它与导航栏之间那 5px 间隙）
  /// 再额外加一点间距，分页条才不会和播放栏贴在一起。
  /// 不能用 `batchBarBottomInset`：那个是给自带 8px 下外边距的批量操作栏算的，
  /// 分页条没有那段外边距，直接套会往播放栏里陷 8px。
  double _miniPlayerInset(bool visible) {
    if (!visible) return 0;
    final reserved = ResponsiveLayout.miniPlayerReservedHeight(context);
    if (reserved <= 0) return 0;
    return reserved + AppSpacing.sm;
  }

  @override
  Widget build(BuildContext context) {
    final miniPlayerVisible = ref.watch(miniPlayerVisibleProvider);
    // 只有 1 页：页码、上一页/下一页、下拉都没什么可翻的，分页条本身不显示。
    // 但常驻底部的位置不能空着——迷你播放器浮在页面之上，留一段空白让
    // 列表最后一行能滚到播放栏上方（分页条不出现时就没有别的让位手段了）。
    if (_count <= 1) {
      if (!widget.docked) return const SizedBox.shrink();
      return SizedBox(height: _miniPlayerInset(miniPlayerVisible));
    }
    final colors = ref.watch(themeColorsProvider);

    // 常驻底部时让开迷你播放器（没歌在播、或当前页面隐藏了播放栏时不用让）。
    final bottomInset = widget.docked
        ? _miniPlayerInset(miniPlayerVisible)
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
            final budget = constraints.maxWidth;

            // 1) 先试「所有页码都显示」：放得下就不需要下拉。
            //    末页未知时不把猜出来的那一页写成页码，末尾换成「…」入口。
            final allPages = <int?>[
              for (var page = 1; page <= _knownCount; page++) page,
              if (_hasMorePage) null,
            ];
            var showDropdown = false;
            List<int?> pages;
            if (_pagesWidth(context, allPages) <= budget) {
              pages = allPages;
            } else {
              // 2) 放不下才出现省略号 + 下拉。当前页前后各留一页（9 10 11），
              //    再缩就只能去掉相邻页了，所以半径最小为 1。
              //    页码窗口按「已知页数」算，末页未知时末尾再补一个「…」入口，
              //    看起来就是 `1 2 3 4 5 … 20 …`：末尾那个 20 是已知的最后一页，
              //    它后面的省略号表示「20 之后还有，但不知道第几页」。
              showDropdown = true;
              final dropdownWidth = _dropdownWidth(context);
              var radius = 5;
              pages = _withMoreEntry(
                _windowPages(_current, _knownCount, radius),
              );
              while (radius > 1 &&
                  _pagesWidth(context, pages) + _elementGap + dropdownWidth >
                      budget) {
                radius--;
                pages = _withMoreEntry(
                  _windowPages(_current, _knownCount, radius),
                );
              }
            }

            // 末尾那一格如果是「末页未知」留下的省略号，就做成可点的入口：
            // 点它取下一页（取到之后已知页数 +1，下拉里才会多出这一页）。
            final moreIndex =
                _hasMorePage && pages.isNotEmpty && pages.last == null
                ? pages.length - 1
                : -1;

            final pageChildren = <Widget>[
              for (var i = 0; i < pages.length; i++)
                pages[i] == null
                    ? (i == moreIndex
                          ? _buildMoreButton(colors)
                          : _buildEllipsis(context, colors))
                    : _buildPageButton(context, colors, pages[i]!),
              if (showDropdown) ...[
                const SizedBox(width: AppSpacing.xs),
                _buildDropdown(colors),
              ],
            ];

            // 整组居中、间距固定（不铺满整行，也不放「上一页 / 下一页」）：
            // 页码少的时候（比如只有 2 页）铺满会把两个页码顶到屏幕两端，
            // 中间空出一条横贯全屏的空白，看着像坏了。
            final contentWidth =
                _pagesWidth(context, pages) +
                (showDropdown ? AppSpacing.xs + _dropdownWidth(context) : 0) +
                (pageChildren.length - 1) * AppSpacing.sm;
            // 极端窄屏（超大字号 / 极小屏）放不下时退化成可横滚，避免溢出条纹。
            if (contentWidth > constraints.maxWidth) {
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: pageChildren,
                ),
              );
            }
            return Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: AppSpacing.sm,
              children: pageChildren,
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

  /// 页码行末尾的「…」入口：末页未知时点它去取下一页。
  ///
  /// 它不写成具体页码（那一页还没取过，纯属猜测），但必须可点，
  /// 否则「不知道总页数」的列表就再也翻不到后面了。
  Widget _buildMoreButton(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _elementGap / 2),
      child: Semantics(
        button: true,
        label: context.tr('下一页'),
        child: SizedBox(
          height: _buttonHeight,
          child: OutlinedButton(
            onPressed: widget.loading ? null : () => _go(_count),
            style: _buttonStyle(colors),
            child: const ExcludeSemantics(child: Text('…')),
          ),
        ),
      ),
    );
  }

  /// 「第 N 页」下拉：列出已知页码，选一个直达。
  ///
  /// 只列 [_knownCount]：不知道总页数时就是「已经翻到过」的页，猜出来的页
  /// 不列；知道总页数时 [_knownCount] 等于总页数，等于列出全部页码。
  ///
  /// 列表可滚动：滚轮直接滚（Windows）、按住鼠标 / 触屏也能拖，
  /// 另有常驻滚动条可拖动快跳。
  Widget _buildDropdown(ThemeColors colors) {
    final rows = _knownCount;
    final menuHeight =
        math.min(rows, _maxMenuRows) * _menuItemHeight + AppSpacing.xs * 2;
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
                  itemCount: rows,
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

  /// 末尾「…」入口按按钮算宽度（它比纯文本的省略号宽一圈边框和内边距）。
  double _moreButtonWidth(BuildContext context) {
    final text = _textWidth(context, '…', _numberStyle);
    return math.max(_buttonMinWidth, text + _buttonPadding * 2) + _elementGap;
  }

  /// 页码行总宽度：中间省略号按纯文本算，末尾的「…」入口按按钮算。
  double _pagesWidth(BuildContext context, List<int?> pages) {
    final moreIndex = _hasMorePage && pages.isNotEmpty && pages.last == null
        ? pages.length - 1
        : -1;
    var total = 0.0;
    for (var i = 0; i < pages.length; i++) {
      final page = pages[i];
      if (page != null) {
        total += _pageButtonWidth(context, page);
      } else if (i == moreIndex) {
        total += _moreButtonWidth(context);
      } else {
        total += _ellipsisWidth(context);
      }
    }
    return total;
  }

  /// 末页未知时，页码行末尾再补一个省略号入口（点它取下一页）。
  ///
  /// 补在「已知的最后一页」之后，所以末页未知时页码行看起来是
  /// `1 2 3 4 5 … 20 …`：20 是已经确定存在的最后一页，最后的省略号表示
  /// 「20 之后还有，只是还不知道第几页」。
  List<int?> _withMoreEntry(List<int?> pages) =>
      _hasMorePage ? [...pages, null] : pages;

  /// 页码窗口：首页 + 末页 + 当前页 ± [radius]。页数少到窗口能盖住就全显；
  /// 缺两页以上用省略号（null），只缺一页直接补齐。
  ///
  /// [count] 传「已知页数」：末页未知时不含那个还没取过的猜测页，
  /// 猜出来的页码由 [_withMoreEntry] 用省略号代替。
  static List<int?> _windowPages(int current, int count, int radius) {
    if (count <= radius * 2 + 1) {
      return [for (var page = 1; page <= count; page++) page];
    }
    final keep = <int>{1, count};
    for (var page = current - radius; page <= current + radius; page++) {
      if (page >= 1 && page <= count) keep.add(page);
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

/// 分页条的「贴底页脚」：放进 `CustomScrollView` 的最后一个 sliver。
///
/// 列表内容不足一屏时，把分页条压到视口最底部（而不是紧跟在最后一行下面、
/// 下面留一大片空白）；内容超过一屏时它仍然紧跟在内容之后，正常随列表滚动。
///
/// 之所以用 `SliverFillRemaining(hasScrollBody: false)` + `Align(bottomCenter)`：
/// 前者保证这一格至少占满「剩下的视口高度」，后者把分页条放在那一格的底部，
/// 于是短列表时贴底、长列表时跟在内容后面，两种情况下位置都对。
class PageBarFooterSliver extends StatelessWidget {
  const PageBarFooterSliver({super.key, required this.child});

  /// 分页条本体（可以带一行加载中 / 加载失败提示）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SliverFillRemaining(
      hasScrollBody: false,
      child: Align(alignment: Alignment.bottomCenter, child: child),
    );
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
