import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme_provider.dart';
import '../../features/plugin/domain/plugin_types.dart';
import 'source_icon.dart';

/// 平铺的音源选择器（Windows 桌面端用）。
///
/// 「单个按钮 + 弹出菜单」要多点一次才能看到有哪些音源；这里直接并排铺开，
/// 点哪个就切到哪个（切换后的重新搜索由调用方负责）。选中项加主题色描边。
///
/// 音源多于 [maxVisible] 个时整行可横向滚动。桌面默认不允许鼠标拖动滚动区、
/// 也不显示滚动条，这里显式放开（否则第 5 个以后的音源用鼠标根本点不到）。
class SourceSelectorRow extends ConsumerStatefulWidget {
  const SourceSelectorRow({
    super.key,
    required this.sources,
    required this.selectedId,
    required this.onSelected,
    this.size = 36,
    this.spacing = 8,
    this.maxVisible = 4,
  });

  /// 可选音源（顺序即展示顺序）。
  final List<SourceInfo> sources;

  /// 当前选中的音源 id（带 `@插件id` 的完整 id）。
  final String selectedId;

  /// 点击某个音源时回调它的 id；点已选中的不会重复回调。
  final ValueChanged<String> onSelected;

  /// 每个圆标的直径（含选中描边）。
  final double size;

  /// 圆标之间的间距。
  final double spacing;

  /// 一行最多完整显示几个，超出改为横向滚动。
  final int maxVisible;

  @override
  ConsumerState<SourceSelectorRow> createState() => _SourceSelectorRowState();
}

class _SourceSelectorRowState extends ConsumerState<SourceSelectorRow> {
  final _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.sources.isEmpty) return const SizedBox.shrink();
    final colors = ref.watch(themeColorsProvider);

    final row = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < widget.sources.length; i++) ...[
          if (i > 0) SizedBox(width: widget.spacing),
          _SourceDot(
            key: ValueKey('source_dot_${widget.sources[i].id}'),
            source: widget.sources[i],
            selected: widget.sources[i].id == widget.selectedId,
            size: widget.size,
            accent: colors.primary,
            onTap: widget.onSelected,
          ),
        ],
      ],
    );

    if (widget.sources.length <= widget.maxVisible) return row;

    final width =
        widget.maxVisible * widget.size +
        (widget.maxVisible - 1) * widget.spacing;
    return SizedBox(
      width: width,
      child: ScrollConfiguration(
        behavior: ScrollConfiguration.of(context).copyWith(
          // 桌面默认 dragDevices 不含鼠标：不放开的话多出来的音源没法拖出来。
          dragDevices: {
            PointerDeviceKind.touch,
            PointerDeviceKind.mouse,
            PointerDeviceKind.trackpad,
            PointerDeviceKind.stylus,
          },
          // 滚动条由下面显式创建，避免桌面行为再套一条。
          scrollbars: false,
        ),
        child: Scrollbar(
          controller: _scrollController,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scrollController,
            scrollDirection: Axis.horizontal,
            child: row,
          ),
        ),
      ),
    );
  }
}

/// 单个音源圆标：未选中无描边，选中时主题色描边（内边距固定，切换不跳动）。
class _SourceDot extends StatelessWidget {
  const _SourceDot({
    super.key,
    required this.source,
    required this.selected,
    required this.size,
    required this.accent,
    required this.onTap,
  });

  final SourceInfo source;
  final bool selected;
  final double size;
  final Color accent;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: source.name,
      child: GestureDetector(
        onTap: selected ? null : () => onTap(source.id),
        child: Container(
          width: size,
          height: size,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: selected ? accent : Colors.transparent,
              width: 2,
            ),
          ),
          child: ClipOval(
            child: SourceIcon(
              sourceId: source.id,
              size: size - 8,
              label: source.name,
            ),
          ),
        ),
      ),
    );
  }
}
