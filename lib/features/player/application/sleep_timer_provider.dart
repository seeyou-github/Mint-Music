import 'dart:async';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'playback_controller.dart';

/// 定时关闭（睡眠定时）状态。
///
/// 参考 Sollin-Music 的实现：
/// - 设定结束时间戳 endAt，每秒用定时器刷新剩余时间 remaining；
/// - 到点后回调 onFire 暂停播放，并清空定时状态。
class SleepTimerState {
  const SleepTimerState({
    this.active = false,
    this.remaining = Duration.zero,
    this.endAt,
  });

  /// 是否已设定定时关闭。
  final bool active;

  /// 距离自动暂停的剩余时间（每秒刷新）。
  final Duration remaining;

  /// 预计暂停播放的时间戳。
  final DateTime? endAt;

  SleepTimerState copyWith({
    bool? active,
    Duration? remaining,
    DateTime? endAt,
  }) {
    return SleepTimerState(
      active: active ?? this.active,
      remaining: remaining ?? this.remaining,
      endAt: endAt ?? this.endAt,
    );
  }

  static const idle = SleepTimerState();
}

class SleepTimerController extends StateNotifier<SleepTimerState> {
  SleepTimerController({required Future<void> Function() onFire})
    : _onFire = onFire,
      super(SleepTimerState.idle) {
    // 前后台切换时开关秒级 tick（见 [_syncUiTicker]）。
    // onShow/onHide 触发在 hidden↔inactive 之间，真正回到 resumed 触发的是
    // onResume；只监听 onShow 会让回到前台时 tick 起不来（剩余时间冻结）。
    // onPause 补上部分 ROM 只发 paused 不发 hidden 的情况。
    _lifecycleListener = AppLifecycleListener(
      onShow: _syncUiTicker,
      onHide: _syncUiTicker,
      onResume: _syncUiTicker,
      onPause: _syncUiTicker,
    );
  }

  final Future<void> Function() _onFire;

  /// 到点触发的单次 Timer：后台（屏幕熄灭）期间**没有**周期性心跳，
  /// 整夜挂着定时关闭也不会每秒唤醒 isolate。
  Timer? _fireTimer;

  /// 剩余时间的秒级刷新，只在 App 可见时运行（UI 看不见时纯属浪费）。
  Timer? _ticker;

  AppLifecycleListener? _lifecycleListener;

  /// 启动定时关闭。duration 必须大于零，再次调用会重置并覆盖旧定时。
  void start(Duration duration) {
    if (duration <= Duration.zero) return;
    _ticker?.cancel();
    _ticker = null;
    _fireTimer?.cancel();
    final endAt = DateTime.now().add(duration);
    state = SleepTimerState(active: true, remaining: duration, endAt: endAt);
    _fireTimer = Timer(duration, _fire);
    _syncUiTicker();
  }

  void _fire() {
    _ticker?.cancel();
    _ticker = null;
    _fireTimer?.cancel();
    _fireTimer = null;
    state = SleepTimerState.idle;
    _onFire();
  }

  /// 剩余时间的刷新只在 App 前台时才有意义：后台把秒级 tick 停掉，
  /// 回到前台（onResume，lifecycleState 已是 resumed）重新开起来；
  /// 下一次 tick 自然把剩余时间追上。
  void _syncUiTicker() {
    _ticker?.cancel();
    _ticker = null;
    final visible =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    if (!state.active || !visible) return;
    final endAt = state.endAt;
    if (endAt == null) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      final remaining = endAt.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        _fire();
      } else {
        state = state.copyWith(remaining: remaining);
      }
    });
  }

  /// 取消定时关闭。
  void cancel() {
    _ticker?.cancel();
    _ticker = null;
    _fireTimer?.cancel();
    _fireTimer = null;
    if (state.active) {
      state = SleepTimerState.idle;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _fireTimer?.cancel();
    _lifecycleListener?.dispose();
    super.dispose();
  }
}

final sleepTimerProvider =
    StateNotifierProvider<SleepTimerController, SleepTimerState>((ref) {
      return SleepTimerController(
        onFire: () async {
          // 到点暂停播放（若已暂停则为空操作）。
          await ref.read(playbackControllerProvider.notifier).pause();
          debugPrint('[SleepTimer] 定时时间到，已暂停播放');
        },
      );
    });

/// 将剩余时长格式化为 "m:ss" 或 "h:mm:ss"（如 29:59 / 1:02:03）。
String formatSleepTimerRemaining(Duration duration) {
  final totalSec = duration.inSeconds;
  if (totalSec <= 0) return '0:00';
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  if (h > 0) {
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
  return '$m:${s.toString().padLeft(2, '0')}';
}
