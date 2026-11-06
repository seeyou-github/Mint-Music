import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/l10n/l10n.dart';
import '../core/platform/window_chrome.dart';
import '../core/theme/theme_provider.dart';

/// Windows 上自绘的标题栏（最顶上的窗口栏）。
///
/// 系统标题栏已经由 [WindowChrome.enableCustomTitleBar] 去掉——Windows 10 不支持
/// `DWMWA_CAPTION_COLOR`，系统标题栏只能是纯黑或纯白，改不了颜色。去掉之后由这条
/// 自绘的栏顶上，背景色直接用设置里「外观设置 → 背景颜色」对应的
/// `themeColors.background`，改设置立刻跟着变。
///
/// 左侧留空（品牌和标题由下面的侧边栏负责，避免重复），只负责：
/// 拖动窗口、双击最大化 / 还原、右侧三个窗口按钮。
class WindowsTitleBar extends ConsumerStatefulWidget {
  const WindowsTitleBar({super.key});

  /// 标题栏高度（和 Windows 自带的 ~23dp 接近，配合 12px 图标看着不挤）。
  static const double height = 32;

  @override
  ConsumerState<WindowsTitleBar> createState() => _WindowsTitleBarState();
}

class _WindowsTitleBarState extends ConsumerState<WindowsTitleBar>
    with WidgetsBindingObserver {
  bool _maximized = false;

  /// 上一次在标题栏按下的时间，用来自己识别双击。
  ///
  /// 不能交给系统：拖动是 Dart 侧主动发 `WM_NCLBUTTONDOWN` 起的，系统不会替我们
  /// 把两次点击合成双击，所以双击最大化要自己判断。
  DateTime? _lastPointerDown;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _maximized = WindowChrome.isMaximized;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    // 最大化 / 还原 / 拖到屏幕边缘吸附后窗口尺寸会变，跟着刷新按钮图标。
    final maximized = WindowChrome.isMaximized;
    if (maximized != _maximized && mounted) {
      setState(() => _maximized = maximized);
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    // 只把左键当成拖动 / 双击：中键、右键留给页面里的其它处理。
    if (event.buttons != kPrimaryButton) return;
    final now = DateTime.now();
    final last = _lastPointerDown;
    _lastPointerDown = now;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 450)) {
      // 双击：最大化 / 还原。第一次点击已经走过一次拖动流程（没移动就原地结束），
      // 这一次不再起拖动。
      _lastPointerDown = null;
      WindowChrome.toggleMaximize();
      return;
    }
    WindowChrome.startDrag();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    // 用 provider 而不是 Theme.of：标题栏在 MaterialApp.builder 里，位于
    // Navigator 之外，这里不再依赖 Theme / Material 祖先。
    final isLight = ref.watch(isLightThemeActiveProvider);

    return Container(
      height: WindowsTitleBar.height,
      color: colors.background,
      child: Row(
        children: [
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _handlePointerDown,
              // 拖动区整块都可以拖，不显示手型光标（和系统标题栏一致）。
              child: const SizedBox.expand(),
            ),
          ),
          _CaptionButton(
            icon: Icons.remove,
            iconSize: 14,
            tooltip: context.tr('最小化'),
            colors: colors,
            isLight: isLight,
            onPressed: WindowChrome.minimize,
          ),
          _CaptionButton(
            icon: _maximized ? Icons.filter_none : Icons.crop_square,
            iconSize: 12,
            tooltip: context.tr(_maximized ? '向下还原' : '最大化'),
            colors: colors,
            isLight: isLight,
            onPressed: WindowChrome.toggleMaximize,
          ),
          _CaptionButton(
            icon: Icons.close,
            iconSize: 15,
            tooltip: context.tr('关闭'),
            colors: colors,
            isLight: isLight,
            isClose: true,
            onPressed: WindowChrome.close,
          ),
        ],
      ),
    );
  }
}

/// 标题栏右侧的最小化 / 最大化 / 关闭按钮。
///
/// 没有 Material 祖先（标题栏在 Navigator 之外），所以用 [MouseRegion] +
/// [GestureDetector] 自己做悬停底色，而不是 InkWell。
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.iconSize,
    required this.tooltip,
    required this.colors,
    required this.isLight,
    required this.onPressed,
    this.isClose = false,
  });

  final IconData icon;
  final double iconSize;
  final String tooltip;
  final ThemeColors colors;
  final bool isLight;
  final bool isClose;
  final VoidCallback onPressed;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // 关闭按钮悬停变红（Windows 的通用反馈），其它两个用一层很淡的底色。
    final hoverColor = widget.isClose
        ? const Color(0xFFE81123)
        : (widget.isLight
              ? Colors.black.withValues(alpha: 0.06)
              : Colors.white.withValues(alpha: 0.08));
    final iconColor = _hovered && widget.isClose
        ? Colors.white
        : widget.colors.textSecondary;

    // 标题栏在 Navigator / Overlay 之外，用不了 Tooltip（需要 Overlay 祖先），
    // 这里只留无障碍标签。
    return Semantics(
      button: true,
      label: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: Container(
            width: 46,
            height: WindowsTitleBar.height,
            color: _hovered ? hoverColor : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: widget.iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}
