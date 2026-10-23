import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/play_progress_store.dart';

/// 已播放进度：songId → 0~1 的比例。
///
/// 只保存「最多听到哪里」，所以拖动进度条往回拖不会把已听进度降下去；
/// 完整听完一遍后固定为 1（界面上显示「已听」）。
final playedProgressProvider =
    StateNotifierProvider<PlayedProgressNotifier, Map<String, double>>((ref) {
      return PlayedProgressNotifier(PlayProgressStore());
    });

class PlayedProgressNotifier extends StateNotifier<Map<String, double>> {
  PlayedProgressNotifier(this._store) : super(const {}) {
    unawaited(_restore());
  }

  final PlayProgressStore _store;

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
    // 只增不减：往回拖进度条 / 重头再听不会把「已听」降级。
    if (ratio <= current) return;
    // 只在「显示出来的百分比」变化时才更新界面 / 写库。
    // 按百分点比较（而不是差值 ≥ 1%）才能和标签文案严格对齐：
    // 播放器那边是按百分点上报的，45.7% → 46% 这种差值不足 1% 的也要记。
    final percent = (ratio * 100).floor();
    if (percent <= (current * 100).floor()) return;

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
