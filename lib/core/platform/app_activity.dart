import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 应用当前是否「在前台并且窗口有焦点」。
///
/// 只有 `AppLifecycleState.resumed` 才算。桌面端的 `inactive` 就是窗口失焦，
/// 移动端的 `inactive` / `paused` / `hidden` 分别对应下拉通知栏、切后台、
/// 最小化（见 `main.dart` 里 `didChangeAppLifecycleState` 的说明）。
///
/// 用处：需要「每帧推进」的视觉效果（歌词滚动、封面逐字动画、跑马灯）据此
/// 停下。这类动画一旦在跑，引擎就会持续 60fps 合成整窗——用户切到别的窗口
/// 之后 CPU 仍然落不下来，正是 mint_music.log 心跳里「后台每分钟 3599 帧」
/// 的来源。
final appActiveProvider = NotifierProvider<AppActivityNotifier, bool>(
  AppActivityNotifier.new,
);

class AppActivityNotifier extends Notifier<bool> {
  @override
  bool build() {
    final listener = AppLifecycleListener(
      onStateChange: (lifecycle) {
        final active = lifecycle == AppLifecycleState.resumed;
        if (state != active) state = active;
      },
    );
    ref.onDispose(listener.dispose);
    // 启动时窗口可能本来就没焦点（例如从命令行带起来），按真实状态初始化，
    // 避免先白转一轮动画。
    return (WidgetsBinding.instance.lifecycleState ??
            AppLifecycleState.resumed) ==
        AppLifecycleState.resumed;
  }
}
