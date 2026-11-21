import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../../../core/storage/app_preferences.dart';
import '../../../../shared/services/config_image_store.dart';
import '../domain/models/custom_sheet.dart';

/// 自定义歌单封面的缓存目录：`AppData/config/custom_sheet_covers`。
const String customSheetCoverFolder = 'custom_sheet_covers';

/// 自定义歌单（分类 + 歌单）的本地存储。
class CustomSheetStore {
  static const String _key = 'custom_sheets_v1';

  /// 封面在设置里只存文件名（见 [ConfigImageStore.storedValue]）。
  static const ConfigImageStore _covers = ConfigImageStore(
    customSheetCoverFolder,
  );

  Future<CustomSheetData> load() async {
    try {
      final prefs = await AppPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null || raw.trim().isEmpty) return const CustomSheetData();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const CustomSheetData();
      final data = CustomSheetData.fromJson(
        Map<String, dynamic>.from(decoded),
      );
      return _resolveCovers(data);
    } catch (e) {
      debugPrint('[CustomSheetStore] 读取自定义歌单失败: $e');
      return const CustomSheetData();
    }
  }

  Future<void> save(CustomSheetData data) async {
    try {
      final prefs = await AppPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(_storedJson(data.toJson())));
    } catch (e) {
      debugPrint('[CustomSheetStore] 保存自定义歌单失败: $e');
    }
  }

  /// 把存下的封面文件名还原成当前目录的绝对路径（搬目录 / 换设备还原后）。
  Future<CustomSheetData> _resolveCovers(CustomSheetData data) async {
    var changed = false;
    final sheets = <CustomSheet>[];
    for (final sheet in data.sheets) {
      final resolvedPath = await _covers.resolveCoverPath(sheet.coverPath);
      final resolvedUrl = await _covers.resolveCoverUrl(sheet.coverUrl);
      if (resolvedPath == sheet.coverPath && resolvedUrl == sheet.coverUrl) {
        sheets.add(sheet);
        continue;
      }
      changed = true;
      sheets.add(
        sheet.copyWith(
          coverPath: resolvedPath,
          clearCoverPath: resolvedPath == null,
          coverUrl: resolvedUrl,
        ),
      );
    }
    if (!changed) return data;
    // 修正结果写回磁盘：下次启动 / 备份就不用再按旧路径找。
    final resolved = CustomSheetData(
      categories: data.categories,
      sheets: sheets,
    );
    await save(resolved);
    return resolved;
  }

  Map<String, dynamic> _storedJson(Map<String, dynamic> json) {
    final result = Map<String, dynamic>.from(json);
    final sheets = json['sheets'];
    if (sheets is List) {
      result['sheets'] = [
        for (final item in sheets)
          item is Map ? _storedSheet(Map<String, dynamic>.from(item)) : item,
      ];
    }
    return result;
  }

  Map<String, dynamic> _storedSheet(Map<String, dynamic> json) {
    final result = Map<String, dynamic>.from(json);
    final coverPath = _covers.storedValue(json['coverPath']?.toString());
    result['coverPath'] = coverPath.isEmpty ? null : coverPath;
    result['coverUrl'] = _covers.storedValue(json['coverUrl']?.toString());
    return result;
  }
}
