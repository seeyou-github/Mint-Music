import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_preferences.dart';
import '../../../../shared/services/config_image_store.dart';
import '../domain/models/radio_station.dart';
import 'radio_cover_cache.dart';

/// 电台（分类 + 电台配置）的本地存储。
class RadioStore {
  static const String _key = 'radio_v1';

  /// 封面在设置里只存文件名（见 [ConfigImageStore.storedValue]）。
  static const ConfigImageStore _covers = ConfigImageStore(
    RadioCoverCache.directoryName,
  );

  Future<RadioData> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return const RadioData();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const RadioData();
      final data = RadioData.fromJson(Map<String, dynamic>.from(decoded));
      return _resolveCovers(data);
    } catch (e) {
      debugPrint('[RadioStore] 读取电台失败: $e');
      return const RadioData();
    }
  }

  Future<void> save(RadioData data) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_storedJson(data.toJson())));
    } catch (e) {
      debugPrint('[RadioStore] 保存电台失败: $e');
    }
  }

  /// 把存下的封面文件名还原成当前目录的绝对路径（搬目录 / 换设备还原后）。
  Future<RadioData> _resolveCovers(RadioData data) async {
    var changed = false;

    Future<RadioStation> fix(RadioStation station) async {
      final path = station.coverPath?.trim() ?? '';
      final resolvedPath = await _covers.resolveCoverPath(path);
      final resolvedUrl = await _covers.resolveCoverUrl(station.coverUrl);
      if (resolvedPath == station.coverPath && resolvedUrl == station.coverUrl) {
        return station;
      }
      changed = true;
      return station.copyWith(
        coverPath: resolvedPath,
        clearCoverPath: resolvedPath == null,
        coverUrl: resolvedUrl,
      );
    }

    final stations = <RadioStation>[
      for (final station in data.stations) await fix(station),
    ];
    final random = data.randomStation == null
        ? null
        : await fix(data.randomStation!);
    if (!changed) return data;
    // 修正结果写回磁盘：下次启动 / 备份就不用再按旧路径找。
    final resolved = data.copyWith(
      stations: stations,
      randomStation: random,
      clearRandomStation: random == null,
    );
    await save(resolved);
    return resolved;
  }

  Map<String, dynamic> _storedJson(Map<String, dynamic> json) {
    final result = Map<String, dynamic>.from(json);
    final stations = json['stations'];
    if (stations is List) {
      result['stations'] = [
        for (final item in stations)
          item is Map
              ? _storedStation(Map<String, dynamic>.from(item))
              : item,
      ];
    }
    final random = json['randomStation'];
    if (random is Map) {
      result['randomStation'] = _storedStation(
        Map<String, dynamic>.from(random),
      );
    }
    return result;
  }

  Map<String, dynamic> _storedStation(Map<String, dynamic> json) {
    final result = Map<String, dynamic>.from(json);
    final coverPath = _covers.storedValue(json['coverPath']?.toString());
    result['coverPath'] = coverPath.isEmpty ? null : coverPath;
    result['coverUrl'] = _covers.storedValue(json['coverUrl']?.toString());
    return result;
  }
}
