import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';

/// 列表底部的胶囊分页条，加载中禁用导航。
///
/// [totalKnown] 为 false 时，[pageCount] 仅代表已加载可达页及下一页入口，
/// 不展示总页数、尾页按钮或任意跳页。调用方在加载结束时改为 true。
/// 已知总页数（接口返回了总数）时额外提供「尾页」一键直达。
class PageBar extends ConsumerStatefulWidget {
  const PageBar({
    super.key,
    required this.currentPage,
    required this.pageCount,
    required this.onChanged,
    this.loading = false,
    this.padding,
    this.totalKnown = true,
  });

  final int currentPage;
  final int pageCount;
  final ValueChanged<int> onChanged;
  final bool loading;
  final EdgeInsetsGeometry? padding;
  final bool totalKnown;

  @override
  ConsumerState<PageBar> createState() => _PageBarState();
}

class _PageBarState extends ConsumerState<PageBar> {
  late final TextEditingController _jumpController;

  int get _count => widget.pageCount < 1 ? 1 : widget.pageCount;
  int get _current => widget.currentPage.clamp(1, _count);
  bool get _showJump => widget.totalKnown && _count > 20;

  int? get _jumpTarget {
    if (!_showJump || widget.loading) return null;
    final text = _jumpController.text.trim();
    if (!RegExp(r'^[0-9]+$').hasMatch(text)) return null;
    final page = int.tryParse(text);
    if (page == null || page < 1 || page > _count || page == _current) {
      return null;
    }
    return page;
  }

  @override
  void initState() {
    super.initState();
    _jumpController = TextEditingController(text: '$_current');
  }

  @override
  void didUpdateWidget(covariant PageBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentPage != widget.currentPage ||
        oldWidget.totalKnown != widget.totalKnown) {
      _jumpController.text = '$_current';
    }
  }

  @override
  void dispose() {
    _jumpController.dispose();
    super.dispose();
  }

  void _submitJump() {
    final target = _jumpTarget;
    if (target != null) widget.onChanged(target);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final pages = _windowPages(_current, _count, widget.totalKnown);
    final pageButtons = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
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
      ),
    );
    final previous = _buildStepButton(
      colors,
      label: context.tr('上一页'),
      icon: Icons.chevron_left,
      enabled: _current > 1 && !widget.loading,
      onTap: () => widget.onChanged(_current - 1),
    );
    final next = _buildStepButton(
      colors,
      label: widget.loading ? context.tr('加载中') : context.tr('下一页'),
      icon: Icons.chevron_right,
      iconAfter: true,
      enabled: _current < _count && !widget.loading,
      onTap: () => widget.onChanged(_current + 1),
    );
    // 总页数已知时提供「尾页」直达；未知总数时 pageCount 只到已加载范围，
    // 点尾页会误导，所以整个按钮都不出现。
    final showLast = widget.totalKnown && _count > 1;
    final last = _buildStepButton(
      colors,
      label: context.tr('尾页'),
      icon: Icons.keyboard_double_arrow_right,
      iconAfter: true,
      enabled: showLast && _current < _count && !widget.loading,
      onTap: () => widget.onChanged(_count),
    );
    final total = Text(
      context.tr('共 $_count 页'),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: colors.textSecondary),
    );
    const gap = SizedBox(width: AppSpacing.sm);

    return Padding(
      padding:
          widget.padding ??
          const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 窄屏上页码单独横滚，跳页框始终紧挨下一页左侧。
          if (constraints.maxWidth < 760) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(child: pageButtons),
                    if (widget.totalKnown) ...[
                      gap,
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * 0.35,
                        ),
                        child: total,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(child: previous),
                    gap,
                    if (_showJump)
                      Flexible(flex: 2, child: _buildJumpInput(colors))
                    else
                      const Spacer(),
                    gap,
                    Flexible(child: next),
                    if (showLast) ...[gap, Flexible(child: last)],
                  ],
                ),
              ],
            );
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              previous,
              gap,
              Flexible(child: pageButtons),
              if (widget.totalKnown) ...[gap, Flexible(child: total)],
              if (_showJump) ...[
                gap,
                SizedBox(width: 136, child: _buildJumpInput(colors)),
              ],
              gap,
              next,
              if (showLast) ...[gap, last],
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
              ? () => widget.onChanged(page)
              : null,
          style: _buttonStyle(colors, selected: selected),
          child: ExcludeSemantics(child: Text('$page')),
        ),
      ),
    );
  }

  Widget _buildJumpInput(ThemeColors colors) {
    final border = OutlineInputBorder(
      borderRadius: BorderRadius.circular(AppRadius.full),
      borderSide: BorderSide(color: colors.divider),
    );
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _jumpController,
            enabled: !widget.loading,
            keyboardType: TextInputType.number,
            textInputAction: TextInputAction.go,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: colors.textPrimary),
            cursorColor: colors.primary,
            decoration: InputDecoration(
              labelText: context.tr('页码'),
              hintText: '1–$_count',
              labelStyle: TextStyle(color: colors.textSecondary),
              hintStyle: TextStyle(color: colors.textHint),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 10,
              ),
              border: border,
              enabledBorder: border,
              disabledBorder: border,
              focusedBorder: border.copyWith(
                borderSide: BorderSide(color: colors.primary),
              ),
            ),
            onChanged: (_) => setState(() {}),
            onSubmitted: (_) => _submitJump(),
          ),
        ),
        const SizedBox(width: AppSpacing.xs),
        OutlinedButton(
          onPressed: _jumpTarget == null ? null : _submitJump,
          style: _buttonStyle(colors),
          child: Text(context.tr('确定')),
        ),
      ],
    );
  }

  /// null 表示真正的跨页省略；仅缺一页时直接补齐，避免无意义省略号。
  static List<int?> _windowPages(int current, int count, bool totalKnown) {
    final keep = <int>{1};
    if (totalKnown && count <= 10) {
      return [for (var page = 1; page <= count; page++) page];
    }
    if (current <= 5) {
      keep.addAll([for (var page = 1; page <= 8; page++) page]);
    } else if (totalKnown && current >= count - 4) {
      keep.addAll([for (var page = count - 7; page <= count; page++) page]);
    } else {
      keep.addAll([
        for (var page = current - 3; page <= current + 3; page++) page,
      ]);
    }
    if (totalKnown) keep.add(count);
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
