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
    state = AsyncData(boards);
    await ref.read(hotBoardStoreProvider).save(boards);
  }
}
