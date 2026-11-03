import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/play_progress_store.dart';

/// 进度存储（「已听 N%」与「上次播放位置」共用一份，避免重复注册写盘任务）。
final playProgressStoreProvider = Provider<PlayProgressStore>(
  (ref) => PlayProgressStore(),
);

/// 已播放进度：songId → 0~1 的比例。
///
/// 只保存「最多听到哪里」，所以拖动进度条往回拖不会把已听进度降下去；
/// 完整听完一遍后固定为 1（界面上显示「已听」）。
final playedProgressProvider =
    StateNotifierProvider<PlayedProgressNotifier, Map<String, double>>((ref) {
      return PlayedProgressNotifier(ref.watch(playProgressStoreProvider));
    });

/// 上次播放位置：songId → 停在哪里。
///
/// 与 [playedProgressProvider] 互补：那边只增不减（给「已听 N%」标签），
/// 这边永远是最新位置（往回拖也会更新），用于「接着上次的进度继续播放」。
final songResumeProvider =
    StateNotifierProvider<SongResumeNotifier, Map<String, Duration>>((ref) {
      return SongResumeNotifier(ref.watch(playProgressStoreProvider));
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

/// 「上次播放位置」：记住每首歌停在哪里，下次从那里继续。
class SongResumeNotifier extends StateNotifier<Map<String, Duration>> {
  SongResumeNotifier(this._store) : super(const {}) {
    unawaited(_restore());
  }

  final PlayProgressStore _store;

  final Completer<void> _ready = Completer<void>();

  /// 历史位置从数据库读完之后完成；启动时恢复会话需要等它。
  Future<void> get ready => _ready.future;

  Future<void> _restore() async {
    try {
      final stored = await _store.loadAllPositions();
      if (!mounted) return;
      final merged = <String, Duration>{
        for (final entry in stored.entries)
          entry.key: Duration(milliseconds: entry.value.positionMs),
      };
      // 加载期间可能已经记录了新位置，取两者较大的。
      for (final entry in state.entries) {
        final current = merged[entry.key] ?? Duration.zero;
        if (entry.value > current) merged[entry.key] = entry.value;
      }
      state = merged;
    } catch (e) {
      debugPrint('[PlayProgress] 恢复上次播放位置失败: $e');
    } finally {
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  /// 记一次「播到哪」。
  ///
  /// - 停在开头（不足 3 秒）：没有恢复的意义，直接删掉记录；
  /// - 停在结尾（距结尾不足 3 秒 / 超过 98%）：视为已听完，删掉记录，
  ///   下次从头播，避免「点一下歌，直接跳到末尾」。
  void record({
    required String songId,
    required int positionMs,
    required int durationMs,
  }) {
    if (songId.isEmpty) return;
    final nearStart = positionMs < 3000;
    final nearEnd =
        durationMs > 0 &&
        (positionMs >= durationMs - 3000 ||
            positionMs / durationMs >= 0.98);
    if (nearStart || nearEnd) {
      if (state.containsKey(songId)) {
        final next = Map<String, Duration>.of(state)..remove(songId);
        state = next;
      }
      _store.enqueuePosition(songId, const SavedPosition(positionMs: 0));
      return;
    }
    final position = Duration(milliseconds: positionMs);
    state = {...state, songId: position};
    _store.enqueuePosition(
      songId,
      SavedPosition(positionMs: positionMs, durationMs: durationMs),
    );
  }

  /// 该歌曲上次停下的位置；不值得恢复（没记录 / 太靠前 / 已接近结尾）时
  /// 返回 [Duration.zero]，调用方按「从头播放」处理。
  Duration resumePositionFor(String songId, {int durationSeconds = 0}) {
    final saved = state[songId];
    if (saved == null) return Duration.zero;
    if (saved < const Duration(seconds: 3)) return Duration.zero;
    if (durationSeconds > 0) {
      final total = Duration(seconds: durationSeconds);
      if (saved >= total - const Duration(seconds: 3)) return Duration.zero;
    }
    return saved;
  }
}
