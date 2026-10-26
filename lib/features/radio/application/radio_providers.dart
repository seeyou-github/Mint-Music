import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/radio_cover_cache.dart';
import '../data/radio_store.dart';
import '../domain/models/radio_station.dart';

export '../data/radio_store.dart' show RadioStore;
export '../domain/models/radio_station.dart';

final radioStoreProvider = Provider<RadioStore>((ref) => RadioStore());

/// 电台数据（分类 + 电台列表）。
///
/// 与黑名单一样是「同步可读、启动后异步补齐」：界面需要立刻画出分类栏和电台。
final radioProvider = NotifierProvider<RadioNotifier, RadioData>(
  RadioNotifier.new,
);

class RadioNotifier extends Notifier<RadioData> {
  bool _loaded = false;

  @override
  RadioData build() {
    if (!_loaded) unawaited(_load());
    return const RadioData();
  }

  Future<void> _load() async {
    final data = await ref.read(radioStoreProvider).load();
    _loaded = true;
    try {
      state = data;
    } catch (_) {}
  }

  Future<void> _persist() async {
    await ref.read(radioStoreProvider).save(state);
  }

  /// 分类栏用：第一项固定是「全部」。
  List<RadioCategory> get categories => [
    RadioCategory.all,
    ...state.categories,
  ];

  RadioCategory? categoryById(String id) {
    if (id == RadioCategory.allId) return RadioCategory.all;
    for (final category in state.categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  Future<RadioCategory> addCategory(String name) async {
    final now = DateTime.now();
    final category = RadioCategory(
      id: 'cat_${now.millisecondsSinceEpoch}',
      name: name.trim(),
    );
    state = state.copyWithCategories([...state.categories, category]);
    await _persist();
    return category;
  }

  /// 删除分类：该分类下的电台挪回「全部」，不跟着删。
  Future<void> removeCategory(String id) async {
    if (id == RadioCategory.allId) return;
    final categories = state.categories
        .where((e) => e.id != id)
        .toList(growable: false);
    final stations = [
      for (final station in state.stations)
        if (station.categoryId == id)
          station.copyWith(categoryId: RadioCategory.allId)
        else
          station,
    ];
    state = RadioData(categories: categories, stations: stations);
    await _persist();
  }

  /// 新增 / 更新电台（封面会先缓存到本地）。
  Future<RadioStation> saveStation(RadioStation station) async {
    var saved = station;
    final cached = await RadioCoverCache.cache(station.coverUrl);
    if (cached != null) {
      saved = station.copyWith(coverPath: cached);
      // 换了封面：把旧文件删掉，避免堆垃圾。
      final old = station.coverPath?.trim() ?? '';
      if (old.isNotEmpty && old != cached) {
        await RadioCoverCache.remove(old);
      }
    }
    final index = state.stations.indexWhere((e) => e.id == saved.id);
    final stations = [...state.stations];
    if (index >= 0) {
      stations[index] = saved.copyWith(updateTime: DateTime.now());
    } else {
      stations.add(saved);
    }
    state = RadioData(categories: state.categories, stations: stations);
    await _persist();
    return index >= 0 ? stations[index] : saved;
  }

  Future<void> removeStation(String id) async {
    RadioStation? removed;
    final stations = <RadioStation>[];
    for (final station in state.stations) {
      if (station.id == id) {
        removed = station;
      } else {
        stations.add(station);
      }
    }
    if (removed == null) return;
    state = RadioData(categories: state.categories, stations: stations);
    await _persist();
    await RadioCoverCache.remove(removed.coverPath);
  }
}

extension RadioDataX on RadioData {
  RadioData copyWithCategories(List<RadioCategory> categories) =>
      RadioData(categories: categories, stations: stations);
}
