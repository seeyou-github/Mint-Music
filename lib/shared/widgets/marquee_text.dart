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
  });

  final String text;
  final TextStyle style;
  final TextAlign textAlign;

  /// 一次来回滚动的时间。
  final Duration duration;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  double _overflow = 0;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
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
    _controller.dispose();
    super.dispose();
  }

  double _measure(double maxWidth) {
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: widget.style),
      maxLines: 1,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);
    return painter.width - maxWidth;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final overflow = _measure(constraints.maxWidth);
        _overflow = overflow > 0 ? overflow : 0;
        final shouldAnimate = _overflow > 0;
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
