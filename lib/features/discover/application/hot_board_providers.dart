import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/hot_board_store.dart';
import '../domain/models/hot_board.dart';
import 'discover_providers.dart';

final hotBoardStoreProvider = Provider<HotBoardStore>((ref) => HotBoardStore());

/// 用户添加的全部热榜（跨音源保存，展示时按当前音源过滤）。
final hotBoardsProvider =
    AsyncNotifierProvider<HotBoardsNotifier, List<HotBoard>>(
      HotBoardsNotifier.new,
    );

/// 当前音源的热榜：主页切换音源时，热榜内容跟着切换。
final currentHotBoardsProvider = Provider<AsyncValue<List<HotBoard>>>((ref) {
  final sourceId = ref.watch(discoverSourceIdProvider);
  return ref
      .watch(hotBoardsProvider)
      .whenData(
        (boards) => [
          for (final board in boards)
            if (board.source == sourceId) board,
        ],
      );
});

/// 「哪些音源有用户新增的热榜」标志位（音源 id 集合）。
///
/// 与热榜内容分开保存、只含音源 id，所以切换音源时能**同步**判断榜单默认
/// 分类，不必等（也不用解析）整份热榜数据。
final hotBoardSourceIdsProvider =
    NotifierProvider<HotBoardSourceIdsNotifier, Set<String>>(
      HotBoardSourceIdsNotifier.new,
    );

class HotBoardSourceIdsNotifier extends Notifier<Set<String>> {
  bool _disposed = false;
  bool _hydrating = false;

  @override
  Set<String> build() {
    ref.onDispose(() => _disposed = true);
    final cached = ref.read(hotBoardStoreProvider).loadSourceIdsSync();
    if (cached != null) return cached;
    // 还没写过标志位（首次启动 / 从老版本升级）：先按已有榜单补一次。
    unawaited(_hydrateFromBoards());
    return const <String>{};
  }

  Future<void> _hydrateFromBoards() async {
    if (_hydrating) return;
    _hydrating = true;
    final store = ref.read(hotBoardStoreProvider);
    try {
      final boards = await ref.read(hotBoardsProvider.future);
      if (_disposed) return;
      // 补写期间标志位已经被写过（新增 / 删除 / 卸载清理）：以它为准。
      if (store.loadSourceIdsSync() != null) return;
      await _write({for (final board in boards) board.source});
    } catch (e) {
      debugPrint('[HotBoardStore] 热榜标志位回填失败: $e');
    } finally {
      _hydrating = false;
    }
  }

  /// 热榜数据变化（新增 / 删除）后维护标志位。
  ///
  /// 只按这次变化涉及的音源增删，不按全部数据重算——否则音源卸载时清掉的
  /// 标志位，会被之后任意一次新增（数据里还留着那个音源的榜单）带回来。
  Future<void> applyBoardsChange(
    List<HotBoard> previous,
    List<HotBoard> next,
  ) async {
    if (_disposed) return;
    final before = {for (final board in previous) board.source};
    final after = {for (final board in next) board.source};
    final added = after.difference(before);
    final removed = before.difference(after);
    // 只是刷新榜单内容 / 调整顺序：标志位不用动。
    if (added.isEmpty && removed.isEmpty) return;
    var ids = {...state, ...added}..removeAll(removed);
    // 热榜数据全删完了：标志位一起清空。
    if (next.isEmpty) ids = <String>{};
    await _write(ids);
  }

  /// 插件被卸载 / 删除：它带来的音源（`平台id@插件id`）标志位一起清掉。
  Future<void> clearPlugin(String pluginId) async {
    if (_disposed) return;
    final suffix = '@$pluginId';
    final ids = {
      for (final id in state)
        if (id != pluginId && !id.endsWith(suffix)) id,
    };
    if (ids.length == state.length) return;
    await _write(ids);
  }

  Future<void> _write(Set<String> ids) async {
    if (_disposed) return;
    state = ids;
    await ref.read(hotBoardStoreProvider).saveSourceIds(ids);
  }
}

class HotBoardsNotifier extends AsyncNotifier<List<HotBoard>> {
  @override
  Future<List<HotBoard>> build() {
    return ref.read(hotBoardStoreProvider).load();
  }

  /// 添加榜单：同一榜单（id + 音源）重复添加时刷新它的歌曲，
  /// 其它榜单原样保留，所以可以连续添加多个。
  Future<void> add(HotBoard board) async {
    final boards = [...await future];
    final index = boards.indexWhere(
      (item) => item.id == board.id && item.source == board.source,
    );
    if (index >= 0) {
      boards[index] = board;
    } else {
      boards.add(board);
    }
    await _update(boards);
  }

  Future<void> remove(HotBoard board) async {
    final boards = [
      for (final item in await future)
        if (item.id != board.id || item.source != board.source) item,
    ];
    await _update(boards);
  }

  /// 调整某个音源内榜单的顺序（拖动排序）；不改变其它音源的位置。
  Future<void> reorderForSource(
    String sourceId,
    int oldIndex,
    int newIndex,
  ) async {
    final all = [...await future];
    final slots = <int>[
      for (var i = 0; i < all.length; i++)
        if (all[i].source == sourceId) i,
    ];
    if (oldIndex < 0 || oldIndex >= slots.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    newIndex = newIndex.clamp(0, slots.length - 1);

    final boards = [for (final index in slots) all[index]];
    final moved = boards.removeAt(oldIndex);
    boards.insert(newIndex, moved);
    for (var i = 0; i < slots.length; i++) {
      all[slots[i]] = boards[i];
    }
    await _update(all);
  }

  Future<void> _update(List<HotBoard> boards) async {
    final previous = state.valueOrNull ?? const <HotBoard>[];
    state = AsyncData(boards);
    await ref.read(hotBoardStoreProvider).save(boards);
    // 标志位跟着数据走：新增 / 删空时同步维护，界面切音源时只看它。
    await ref
        .read(hotBoardSourceIdsProvider.notifier)
        .applyBoardsChange(previous, boards);
  }
}
