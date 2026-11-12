import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

/// 歌曲行的鼠标悬浮状态（桌面端 / Web）。
///
/// 两种列表都能用同一份 hover 视觉：
/// * 歌单详情页等列表行本身是 InkWell，悬浮底色由 InkWell 画，这里只传
///   [hoverColor] 为空、负责把 hovered 状态传给后代；
/// * 本地歌曲列表是纯 GestureDetector，没有 InkWell，传
///   `Theme.of(context).hoverColor` 让本组件补上同款悬浮底色。
///
/// hovered 用 [InheritedNotifier] 向下传：鼠标进出一行时只重建订阅了它的
/// 小部件（收藏红心），整行不重绘。触屏平台没有悬停，hovered 恒为 false。
class SongRowHover extends StatefulWidget {
  const SongRowHover({super.key, required this.child, this.hoverColor});

  final Widget child;

  /// 悬浮时铺在行底下的颜色；为空表示由列表行自己的 InkWell 负责。
  final Color? hoverColor;

  /// Android / iOS 是触屏，没有鼠标悬浮；桌面端与 Web 才启用。
  static bool get supported => switch (defaultTargetPlatform) {
    TargetPlatform.android || TargetPlatform.iOS => false,
    _ => true,
  };

  /// 当前行是否正被鼠标悬停。
  ///
  /// 后代调用会订阅变化，鼠标进出时该后代单独重建。
  static bool isHovered(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<_SongRowHoverScope>()
          ?.notifier
          ?.value ??
      false;

  @override
  State<SongRowHover> createState() => _SongRowHoverState();
}

class _SongRowHoverState extends State<SongRowHover> {
  final ValueNotifier<bool> _hovered = ValueNotifier<bool>(false);

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final supported = SongRowHover.supported;
    return MouseRegion(
      onEnter: supported ? (_) => _hovered.value = true : null,
      onExit: supported ? (_) => _hovered.value = false : null,
      child: _SongRowHoverScope(
        notifier: _hovered,
        child: ValueListenableBuilder<bool>(
          valueListenable: _hovered,
          // child 是外面传进来的整行，缓存住：hover 只换底色，不重建行内容。
          child: widget.child,
          builder: (context, hovered, child) => Container(
            color: hovered && supported && widget.hoverColor != null
                ? widget.hoverColor
                : null,
            child: child,
          ),
        ),
      ),
    );
  }
}

class _SongRowHoverScope extends InheritedNotifier<ValueNotifier<bool>> {
  const _SongRowHoverScope({required super.notifier, required super.child});
}
