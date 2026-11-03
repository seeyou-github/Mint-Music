import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/play_progress_store.dart';

/// 进度存储（「已听 N%」标签与「接着上次继续播放」共用同一份数据）。
final playProgressStoreProvider = Provider<PlayProgressStore>(
  (ref) => PlayProgressStore(),
);

/// 已播放进度：songId → 0~1 的比例。
///
/// 只保存「最多听到哪里」（最远进度），所以拖动进度条往回拖不会把已听进度降下去；
/// 完整听完一遍后固定为 1（界面上显示「已听」）。
///
/// 这份数据同时用于「接着上次继续播放」：[PlayedProgressNotifier.resumePositionFor]
/// 按它算出续播位置——用户关心的是「这首歌最远听到哪」，不是每次的最后位置。
final playedProgressProvider =
    StateNotifierProvider<PlayedProgressNotifier, Map<String, double>>((ref) {
      return PlayedProgressNotifier(ref.watch(playProgressStoreProvider));
    });

class PlayedProgressNotifier extends StateNotifier<Map<String, double>> {
  PlayedProgressNotifier(this._store) : super(const {}) {
    unawaited(_restore());
  }

  final PlayProgressStore _store;

  final Completer<void> _ready = Completer<void>();

  /// 历史进度从数据库读完之后完成；启动时恢复会话（定位进度条）要等它。
  Future<void> get ready => _ready.future;

  Future<void> _restore() async {
    try {
      final stored = await _store.loadAll();
      if (!mounted) return;
      final merged = <String, double>{
        for (final entry in stored.entries) entry.key: entry.value.ratio,
      };
      // 加载期间可能已经记录了新进度，取两者较大的。
      for (final entry in state.entries) {
        final current = merged[entry.key] ?? 0;
        if (entry.value > current) merged[entry.key] = entry.value;
      }
      state = merged;
    } catch (e) {
      debugPrint('[PlayProgress] 恢复已播放进度失败: $e');
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  /// 记录一次播放位置。
  void record({
    required String songId,
    required int positionMs,
    required int durationMs,
  }) {
    if (songId.isEmpty || durationMs <= 0 || positionMs <= 0) return;
    var ratio = positionMs / durationMs;
    if (!ratio.isFinite) return;
    ratio = ratio.clamp(0.0, 1.0);

    final current = state[songId] ?? 0;
    // 已经有记录、且这次进度不比它大（重复播放 / 往回拖进度条）就不保存。
    if (ratio <= current) return;

    state = {...state, songId: ratio};
    // 恢复数据库之前产生的进度也要落盘：upsert 按 songId 覆盖，
    // 恢复时再取「内存 / 数据库」里较大的那个，不会互相覆盖。
    _store.enqueue(
      songId,
      PlayedProgress(
        ratio: ratio,
        positionMs: positionMs,
        durationMs: durationMs,
      ),
    );
  }

  /// 该歌曲「接着上次继续播放」的位置：按最远进度（[record] 记的 ratio）
  /// 折算成时间，用于点播 / 重启后继续听。
  ///
  /// 下列情况返回 [Duration.zero]（从头播）：
  /// - 没有记录；
  /// - 已经听完整首（ratio >= 100%，由调用方决定是否从 0 开始）；
  /// - 几乎没有进展（不足 3 秒）——恢复没有意义；
  /// - 已经非常接近结尾（>= 98%）——直接跳过去只会立刻播完。
  Duration resumePositionFor(String songId, {int durationMs = 0}) {
    if (songId.isEmpty || durationMs <= 0) return Duration.zero;
    final ratio = state[songId];
    if (ratio == null || ratio <= 0) return Duration.zero;
    // 听完 / 接近听完 → 从 0 开始。
    if (ratio >= 0.98) return Duration.zero;
    final position = Duration(
      milliseconds: (ratio * durationMs).round(),
    );
    if (position < const Duration(seconds: 3)) return Duration.zero;
    return position;
  }

  /// 清空全部播放进度。
  Future<void> clearAll() async {
    state = const {};
    await _store.clear();
  }
}

/// 「已听 / 已听 N%」标签的文案；进度不足 1% 时返回 null（不显示标签）。
String? playedProgressLabel(double? ratio) {
  // 不足 1% 不显示（记录时也是按 1% 粒度才落库）。
  if (ratio == null || ratio < 0.01) return null;
  if (ratio >= 0.999) return '已听';
  final percent = (ratio * 100).floor().clamp(1, 99).toInt();
  return '已听$percent%';
}
