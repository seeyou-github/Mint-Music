import 'package:flutter/material.dart';

/// 单行文字超出可用宽度时横向来回滚动（对应 lx-music 的 LyricTextView）。
///
/// 文字能完整显示时不做任何动画，并保持 [textAlign] 对齐；
/// 只有真正溢出时才滚动，避免短标题也在「抖动」。
class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.textAlign = TextAlign.left,
    this.duration = const Duration(seconds: 7),
    this.animate = true,
    this.allowScroll = true,
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  /// 一次来回滚动的时间。
  final Duration duration;

  /// 是否允许滚动（默认允许）。
  ///
  /// 传 false 时退化成普通单行文字：超长部分用省略号（`…`）截断，完全不建
  /// 动画控制器、也不做排版测量。
  ///
  /// 典型用途：Windows 侧边栏曲名——用户习惯「省略号」而不是来回滚动。
  final bool allowScroll;

  /// 是否允许滚动（默认允许）。
  ///
  /// 调用方在「不需要动」的时候传 false（典型：播放器暂停时）。滚动是一个
  /// **永不停止**的动画：只要开了，引擎就会一直按 60fps 出帧、一直合成整窗，
  /// 空闲时 CPU 永远落不到 0。侧栏播放器是全局常驻的，曲名一超长就会变成
  /// 「暂停了还在 60fps 跑」——这是「暂停后 CPU 仍 20%」的主要来源之一。
  final bool animate;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _overflow = 0;

  /// 测量缓存：文字 / 样式 / 可用宽度没变时不重复排版。
  ///
  /// 父级 widget 随播放进度高频重建时（例如侧边栏 200ms 一次），build 里的
  /// TextPainter.layout 是纯重复开销（整段文字重新 shaping），按入参缓存后
  /// 只在这些输入真正变化时才测一次。
  String? _lastText;
  TextStyle? _lastStyle;
  double? _lastMaxWidth;
  double _lastOverflow = 0;

  /// 窗口是否在前台（有焦点）。见 [initState] 里的说明。
  bool _appFocused = true;
  AppLifecycleListener? _lifecycle;

  double _measure(String text, TextStyle style, double maxWidth) {
    if (text == _lastText && style == _lastStyle && maxWidth == _lastMaxWidth) {
      return _lastOverflow;
    }
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    final overflow = painter.width - maxWidth;
    _lastText = text;
    _lastStyle = style;
    _lastMaxWidth = maxWidth;
    _lastOverflow = overflow;
    return overflow;
  }

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    // 启动时如果窗口本来就没焦点（例如从命令行带起来），别先白转一轮。
    _appFocused =
        (WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed) ==
        AppLifecycleState.resumed;
    // 窗口失焦 / 最小化时停掉滚动。
    //
    // 实测（mint_music.log 的心跳）：应用在后台（窗口失焦、最小化）时仍是
    // 每分钟 3599 帧 —— 也就是 60fps 一直在跑。跑马灯正是那个「永远在要下一
    // 帧」的源头：只要它在动，引擎就会持续合成整窗，CPU 永远落不到空闲。
    // 用户切到别的窗口干活时，这里完全没有必要继续花这份 CPU。
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        final focused = state == AppLifecycleState.resumed;
        if (focused == _appFocused) return;
        if (mounted) setState(() => _appFocused = focused);
      },
    );
  }

  @override
  void didUpdateWidget(covariant MarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.duration != widget.duration) {
      _controller.duration = widget.duration;
    }
    if (oldWidget.text != widget.text && _controller.isAnimating) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 不滚动：交给 Text 自己省略，不量宽、不建动画。
    if (!widget.allowScroll) {
      return Text(
        widget.text,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
        textAlign: widget.textAlign,
        style: widget.style,
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflow = _measure(
          widget.text,
          widget.style,
          constraints.maxWidth,
        );
        _overflow = overflow > 0 ? overflow : 0;
        // animate=false（暂停）或窗口不在前台时即使溢出也不滚动：不再占着
        // 每帧的渲染。
        final shouldAnimate = _overflow > 0 && widget.animate && _appFocused;
        if (shouldAnimate != _controller.isAnimating) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            if (shouldAnimate) {
              _controller.repeat(reverse: true);
            } else {
              _controller.stop();
              _controller.value = 0;
            }
          });
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) => Transform.translate(
              offset: Offset(-_controller.value * _overflow, 0),
              child: child,
            ),
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.visible,
              textAlign: shouldAnimate ? TextAlign.left : widget.textAlign,
              style: widget.style,
            ),
          ),
        );
      },
    );
  }
}
