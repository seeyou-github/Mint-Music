import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/domain/models/song.dart';
import '../data/hot_board_store.dart';
import '../domain/models/hot_board.dart';
import 'discover_providers.dart';

final hotBoardStoreProvider = Provider<HotBoardStore>((ref) => HotBoardStore());

/// 用户添加的全部热榜**配置**（跨音源保存，展示时按当前音源过滤）。
///
/// state 里带 `songs`，但那是内存缓存：落盘只写配置，歌曲每次进「热榜」时
/// 用 [HotBoardsNotifier.refreshSongs] 重新拉。
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

/// 「哪些音源有用户新增的热榜」标志位（音源 id 集合），**同步**可读。
///
/// 榜单默认分类只看它，所以切换音源时立刻就能判断，不必等热榜数据。
/// 现在配置本身就在 settings.json 里、体积很小（只有音源 / 名称 / 封面），
/// 直接从配置算即可，不再单独存一份标志位。
final hotBoardSourceIdsProvider = Provider<Set<String>>((ref) {
  final boards = ref.watch(hotBoardsProvider).valueOrNull;
  if (boards != null) {
    return {
      for (final board in boards)
        if (board.source.isNotEmpty) board.source,
    };
  }
  return ref.read(hotBoardStoreProvider).loadSourceIdsSync();
});

class HotBoardsNotifier extends AsyncNotifier<List<HotBoard>> {
  /// 热榜里每个榜单最多保存 / 展示多少首歌。
  static const int maxSongs = 10;

  @override
  Future<List<HotBoard>> build() {
    return ref.read(hotBoardStoreProvider).load();
  }

  /// 添加榜单：同一榜单（id + 音源）重复添加时覆盖配置，其它榜单原样保留。
  ///
  /// 只保存配置（音源 / 名称 / 封面）。歌曲不落盘，调用方需要的话用
  /// [refreshBoard] 立刻取一次（加完就能在卡片上看到前十首）。
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

  /// 插件被卸载 / 删除：它带来的榜单配置一起删掉（settings.json 里不再保留）。
  ///
  /// 榜单 `source` 是 `平台id@插件id`（例如 `wy@1a19ca50dfa`），插件卸载后
  /// 这个音源不可能再出现，留着只会让热榜列表里多出一堆打不开的榜单。
  /// 用户重装插件后需要重新添加榜单。
  Future<void> removeForPlugin(String pluginId) async {
    final suffix = '@$pluginId';
    final boards = [...await future];
    final kept = [
      for (final board in boards)
        if (board.source != pluginId && !board.source.endsWith(suffix)) board,
    ];
    if (kept.length == boards.length) return;
    await _update(kept);
  }

  /// 重新拉取某个音源下**所有**榜单的歌曲（每次进入「热榜」都会调用）。
  ///
  /// 只改内存里的 state，不写 settings.json、也不进数据库。
  Future<void> refreshSongs(String sourceId) async {
    final boards = [...await future];
    final targets = [
      for (final board in boards)
        if (board.source == sourceId) board,
    ];
    if (targets.isEmpty) return;
    // 先统一标成「加载中」：卡片各自转圈，而不是一片空白。
    state = AsyncData([
      for (final board in boards)
        board.source == sourceId ? board.withLoading() : board,
    ]);
    await Future.wait([for (final board in targets) _loadSongs(board)]);
  }

  /// 重新拉取单个榜单的歌曲（卡片上的「点击重试」）。
  Future<void> refreshBoard(HotBoard board) async {
    _patch(board, (item) => item.withLoading());
    await _loadSongs(board);
  }

  /// 从插件取这个榜单的前 [maxSongs] 首歌，合进内存里的 state。
  Future<void> _loadSongs(HotBoard board) async {
    var songs = const <Song>[];
    String? error;
    try {
      final page = await ref
          .read(discoverRepositoryProvider)
          .getLeaderboardDetail(board.id, sourceId: board.source);
      songs = (page?.songs ?? const <Song>[])
          .take(maxSongs)
          .toList(growable: false);
      if (songs.isEmpty) error = 'empty';
    } catch (e) {
      error = e.toString().replaceFirst('Exception: ', '');
    }
    _patch(board, (item) => item.withSongs(songs, error: error));
  }

  /// 把某个榜单（按 id + 音源定位）换成 [update] 的结果。
  ///
  /// 拉取过程中用户可能已经删掉这个榜单 / 换了音源，找不到就丢弃这次结果。
  void _patch(HotBoard target, HotBoard Function(HotBoard board) update) {
    final current = state.valueOrNull;
    if (current == null) return;
    final index = current.indexWhere(
      (item) => item.id == target.id && item.source == target.source,
    );
    if (index < 0) return;
    final next = [...current];
    next[index] = update(current[index]);
    state = AsyncData(next);
  }

  Future<void> _update(List<HotBoard> boards) async {
    state = AsyncData(boards);
    await ref.read(hotBoardStoreProvider).save(boards);
  }
}
