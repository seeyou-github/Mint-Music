import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../shared/services/config_image_store.dart';
import '../data/custom_sheet_store.dart';
import '../domain/models/custom_sheet.dart';

export '../data/custom_sheet_store.dart' show CustomSheetStore;
export '../domain/models/custom_sheet.dart';

/// 自定义歌单封面的缓存目录：`AppData/config/custom_sheet_covers`。
const ConfigImageStore customSheetCoverStore = ConfigImageStore(
  'custom_sheet_covers',
);

final customSheetStoreProvider = Provider<CustomSheetStore>(
  (ref) => CustomSheetStore(),
);

/// 自定义歌单数据（分类 + 歌单）。
///
/// 与电台一样「同步可读、启动后异步补齐」：界面需要立刻画出分类栏与卡片。
final customSheetProvider =
    NotifierProvider<CustomSheetNotifier, CustomSheetData>(
      CustomSheetNotifier.new,
    );

class CustomSheetNotifier extends Notifier<CustomSheetData> {
  bool _loaded = false;

  @override
  CustomSheetData build() {
    if (!_loaded) unawaited(_load());
    return const CustomSheetData();
  }

  Future<void> _load() async {
    final data = await ref.read(customSheetStoreProvider).load();
    _loaded = true;
    try {
      state = data;
    } catch (_) {}
  }

  Future<void> _persist() async {
    await ref.read(customSheetStoreProvider).save(state);
  }

  // ---------------------------------------------------------------- 分类

  Future<CustomSheetCategory> addCategory(String name) async {
    final trimmed = name.trim();
    final now = DateTime.now();
    final category = CustomSheetCategory(
      id: 'sheet_cat_${now.millisecondsSinceEpoch}',
      name: trimmed,
    );
    state = CustomSheetData(
      categories: [...state.categories, category],
      sheets: state.sheets,
    );
    await _persist();
    return category;
  }

  /// 改名。
  Future<void> renameCategory(String id, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    state = CustomSheetData(
      categories: [
        for (final category in state.categories)
          if (category.id == id) category.copyWith(name: trimmed) else category,
      ],
      sheets: state.sheets,
    );
    await _persist();
  }

  /// 删除分类：里面的歌单变成「未分类」，不跟着删。
  Future<void> removeCategory(String id) async {
    state = CustomSheetData(
      categories: [
        for (final category in state.categories)
          if (category.id != id) category,
      ],
      sheets: [
        for (final sheet in state.sheets)
          if (sheet.categoryId == id) sheet.copyWith(categoryId: '') else sheet,
      ],
    );
    await _persist();
  }

  // ---------------------------------------------------------------- 歌单

  /// 新增 / 更新歌单（封面会先缓存到本地）。
  Future<CustomSheet> saveSheet(CustomSheet sheet) async {
    var saved = sheet;
    final cached = await customSheetCoverStore.cache(sheet.coverUrl);
    if (cached != null) {
      saved = sheet.copyWith(coverPath: cached);
      // 换了封面：删掉旧文件，避免堆垃圾。
      final old = sheet.coverPath?.trim() ?? '';
      if (old.isNotEmpty && old != cached) {
        await customSheetCoverStore.remove(old);
      }
    }
    final index = state.sheets.indexWhere((item) => item.id == saved.id);
    final sheets = [...state.sheets];
    if (index >= 0) {
      sheets[index] = saved.copyWith(
        updateTime: DateTime.now().millisecondsSinceEpoch,
      );
    } else {
      sheets.add(
        saved.copyWith(updateTime: DateTime.now().millisecondsSinceEpoch),
      );
    }
    state = CustomSheetData(categories: state.categories, sheets: sheets);
    await _persist();
    return index >= 0 ? sheets[index] : saved;
  }

  Future<void> removeSheet(String id) async {
    CustomSheet? removed;
    final sheets = <CustomSheet>[];
    for (final sheet in state.sheets) {
      if (sheet.id == id) {
        removed = sheet;
      } else {
        sheets.add(sheet);
      }
    }
    if (removed == null) return;
    state = CustomSheetData(categories: state.categories, sheets: sheets);
    await _persist();
    await customSheetCoverStore.remove(removed.coverPath);
  }

  /// 生成一个空歌单（新增界面用）。
  CustomSheet draft({required String sourceId, String categoryId = ''}) {
    final now = DateTime.now();
    return CustomSheet(
      id: 'sheet_${now.millisecondsSinceEpoch}',
      sourceId: sourceId,
      categoryId: categoryId,
      name: '',
      keyword: '',
      updateTime: now.millisecondsSinceEpoch,
    );
  }
}

/// 当前音源下、某个分类里的自定义歌单（[categoryId] 为空表示「全部」）。
final customSheetsOfSourceProvider =
    Provider.family<List<CustomSheet>, ({String sourceId, String categoryId})>((
      ref,
      args,
    ) {
      final data = ref.watch(customSheetProvider);
      if (args.categoryId.isEmpty) {
        return data.sheetsOfSource(args.sourceId);
      }
      return data.sheetsOfCategory(args.sourceId, args.categoryId);
    });
