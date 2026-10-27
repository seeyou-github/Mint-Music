import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/hot_board_store.dart';
import '../domain/models/hot_board.dart';

final hotBoardStoreProvider = Provider<HotBoardStore>((ref) => HotBoardStore());

/// 「热榜」分类当前保存的榜单与歌曲（没有配置时为 null）。
final hotBoardProvider = AsyncNotifierProvider<HotBoardNotifier, HotBoard?>(
  HotBoardNotifier.new,
);

class HotBoardNotifier extends AsyncNotifier<HotBoard?> {
  @override
  Future<HotBoard?> build() {
    return ref.read(hotBoardStoreProvider).load();
  }

  Future<void> save(HotBoard board) async {
    state = AsyncData(board);
    await ref.read(hotBoardStoreProvider).save(board);
  }

  Future<void> clear() async {
    state = const AsyncData(null);
    await ref.read(hotBoardStoreProvider).clear();
  }
}
