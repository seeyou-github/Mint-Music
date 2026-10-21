import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/app_paths.dart';

/// 应用设置的持久化入口。
///
/// **Windows**：设置写在应用自己的 `AppData\config\settings.json` 里，
/// 而不是系统漫游目录（这样应用产生的文件全部集中在 `AppData` 下）。
/// 首次启动时会把旧的 `shared_preferences.json` 迁移过来。
///
/// **其它平台**：仍然使用 shared_preferences（行为不变）。
///
/// 对外 API 与 `SharedPreferences` 保持一致，调用方只需要换 import。
class AppPreferences {
  AppPreferences._(this._values, this._file, this._delegate);

  /// 设置文件名（Windows）。
  static const String _fileName = 'settings.json';

  /// 旧版 shared_preferences 的文件名（迁移来源）。
  static const String _legacyFileName = 'shared_preferences.json';

  /// shared_preferences 旧 API 使用的键前缀。
  static const String _legacyKeyPrefix = 'flutter.';

  static AppPreferences? _instance;

  /// 正在进行的初始化（避免启动时多处同时调用导致重复加载）。
  static Future<AppPreferences>? _pending;

  /// 获取单例（首次调用会读取磁盘）。
  static Future<AppPreferences> getInstance() async {
    final cached = _instance;
    if (cached != null) return cached;
    final pending = _pending;
    if (pending != null) return pending;
    final future = _load();
    _pending = future;
    try {
      final created = await future;
      _instance = created;
      return created;
    } finally {
      _pending = null;
    }
  }

  final Map<String, Object> _values;

  /// Windows 上保存设置的文件；其它平台为 null。
  final File? _file;

  /// 其它平台使用的 shared_preferences 实例；Windows 上为 null。
  final SharedPreferences? _delegate;

  bool get _usesDelegate => _delegate != null;

  static Future<AppPreferences> _load() async {
    if (!Platform.isWindows) {
      final prefs = await SharedPreferences.getInstance();
      return AppPreferences._(<String, Object>{}, null, prefs);
    }

    final dir = await AppPaths.configDirectory();
    final file = File(p.join(dir.path, _fileName));
    final values = <String, Object>{};

    if (await file.exists()) {
      try {
        final raw = await file.readAsString();
        if (raw.trim().isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            decoded.forEach((key, value) {
              values['$key'] = value;
            });
          }
        }
      } catch (e) {
        // 设置文件损坏时退回空设置，避免整个应用启动失败。
        print('[AppPreferences] 读取设置失败: $e');
      }
    } else {
      // 首次运行：从旧的 shared_preferences.json 迁移。
      await _migrateLegacy(values);
    }

    return AppPreferences._(values, file, null);
  }

  /// 把旧版 shared_preferences.json 的内容迁移过来（只迁移一次）。
  static Future<void> _migrateLegacy(Map<String, Object> values) async {
    late final File legacy;
    try {
      final support = await getApplicationSupportDirectory();
      legacy = File(p.join(support.path, _legacyFileName));
    } catch (_) {
      return;
    }
    if (!await legacy.exists()) return;

    try {
      final raw = await legacy.readAsString();
      if (raw.trim().isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        final name = '$key';
        values[name] = name.startsWith(_legacyKeyPrefix)
            ? name.substring(_legacyKeyPrefix.length)
            : name;
      });
      print('[AppPreferences] 已从旧的 shared_preferences.json 迁移设置');
    } catch (e) {
      print('[AppPreferences] 迁移旧设置失败: $e');
    }
  }

  // ---------------------------------------------------------------- 读取

  bool? getBool(String key) {
    if (_usesDelegate) return _delegate!.getBool(key);
    final value = _values[key];
    return value is bool ? value : null;
  }

  int? getInt(String key) {
    if (_usesDelegate) return _delegate!.getInt(key);
    final value = _values[key];
    return value is int ? value : null;
  }

  double? getDouble(String key) {
    if (_usesDelegate) return _delegate!.getDouble(key);
    final value = _values[key];
    return value is double ? value : (value is int ? value.toDouble() : null);
  }

  String? getString(String key) {
    if (_usesDelegate) return _delegate!.getString(key);
    final value = _values[key];
    return value is String ? value : null;
  }

  List<String>? getStringList(String key) {
    if (_usesDelegate) return _delegate!.getStringList(key);
    final value = _values[key];
    if (value is List) {
      return value.map((item) => '$item').toList();
    }
    return null;
  }

  bool containsKey(String key) {
    if (_usesDelegate) return _delegate!.containsKey(key);
    return _values.containsKey(key);
  }

  Set<String> getKeys() {
    if (_usesDelegate) return _delegate!.getKeys();
    return _values.keys.toSet();
  }

  // ---------------------------------------------------------------- 写入

  Future<bool> setBool(String key, bool value) async {
    if (_usesDelegate) return _delegate!.setBool(key, value);
    _values[key] = value;
    return _flush();
  }

  Future<bool> setInt(String key, int value) async {
    if (_usesDelegate) return _delegate!.setInt(key, value);
    _values[key] = value;
    return _flush();
  }

  Future<bool> setDouble(String key, double value) async {
    if (_usesDelegate) return _delegate!.setDouble(key, value);
    _values[key] = value;
    return _flush();
  }

  Future<bool> setString(String key, String value) async {
    if (_usesDelegate) return _delegate!.setString(key, value);
    _values[key] = value;
    return _flush();
  }

  Future<bool> setStringList(String key, List<String> value) async {
    if (_usesDelegate) return _delegate!.setStringList(key, value);
    _values[key] = List<String>.from(value);
    return _flush();
  }

  Future<bool> remove(String key) async {
    if (_usesDelegate) return _delegate!.remove(key);
    _values.remove(key);
    return _flush();
  }

  Future<bool> clear() async {
    if (_usesDelegate) return _delegate!.clear();
    _values.clear();
    return _flush();
  }

  /// 把内存中的设置写回磁盘（先写临时文件再替换，避免写坏文件）。
  Future<bool> _flush() async {
    final file = _file;
    if (file == null) return true;
    try {
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(_values), flush: true);
      if (await file.exists()) {
        await file.delete();
      }
      await temp.rename(file.path);
      return true;
    } catch (e) {
      print('[AppPreferences] 写入设置失败: $e');
      return false;
    }
  }
}
