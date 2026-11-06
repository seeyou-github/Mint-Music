import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform/app_paths.dart';

/// 应用设置的持久化入口。
///
/// **所有平台**都写在应用自己的「配置目录」下的 `settings.json`：
///
/// * Windows：`AppData\config\setting\settings.json`；
/// * Android / iOS：`<应用数据目录>/settings.json`（Android 即
///   `/data/data/<包名>/AppData/config/setting/settings.json`）。
///
/// 以前 Android 走 shared_preferences（`/data/data/<包名>/shared_prefs/
/// FlutterSharedPreferences.xml`），问题有两个：
///
/// * 它不在配置目录里——备份只打包 `files/` 和插件目录，于是设置（含 WebDAV
///   账号、插件凭据）根本没进备份包，换设备还原后要重新填；
/// * 卸载重装 / 清数据时和插件、收藏的存活范围不一致。
///
/// 改成和 Windows 一样的文件后，备份只要打包配置目录就什么都有了。
/// 升级后第一次启动会把 shared_preferences 里的键整体搬进 `settings.json`，
/// 搬完之后旧文件就没用了，启动流程结束时由 `LegacySharedPrefs` 删掉。
///
/// 对外 API 与 `SharedPreferences` 保持一致，调用方只需要换 import。
class AppPreferences {
  AppPreferences._(this._values, this._file);

  /// 设置文件名。
  static const String _fileName = 'settings.json';

  /// 旧版 shared_preferences 的文件名（Windows 迁移来源）。
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

  /// 已经初始化过的实例（还没初始化时为 null）。
  ///
  /// 少数「必须当场给出结果」的场景（例如切换音源时判断某个音源有没有热榜）
  /// 需要同步读设置：应用启动时已经 [getInstance] 过，这里直接给出内存里那份。
  static AppPreferences? get maybeInstance => _instance;

  final Map<String, Object> _values;

  /// 保存设置的文件。
  final File? _file;

  static Future<AppPreferences> _load() async {
    final dir = await AppPaths.settingsDirectory();
    final file = File(p.join(dir.path, _fileName));
    final values = await _readFileValues(file);

    // 还没有 settings.json：从旧的数据来源迁移一次。
    if (values.isEmpty && !await file.exists()) {
      if (Platform.isWindows) {
        await _migrateLegacyWindowsFile(values);
      } else {
        values.addAll(await _readSharedPreferences());
      }
      // 写盘失败也不要紧：文件不存在时下次启动会再迁一次（旧数据没删）。
      if (values.isNotEmpty) {
        await _writeFile(file, values);
      }
    }

    return AppPreferences._(values, file);
  }

  /// 从磁盘读取设置（主文件损坏 / 缺失时回退到 .bak 备份）。
  static Future<Map<String, Object>> _readFileValues(File file) async {
    File? target;
    if (await file.exists()) {
      target = file;
    } else {
      // 上次写入恰好中断在「旧文件已改名 .bak、新文件还没改名进来」之间：
      // 备份就是最后一次完整的设置。
      final bak = File('${file.path}.bak');
      if (await bak.exists()) {
        target = bak;
        print('[AppPreferences] 设置文件缺失，从 .bak 备份恢复');
      }
    }
    if (target == null) return <String, Object>{};

    try {
      final raw = await target.readAsString();
      if (raw.trim().isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          return decoded.map((key, value) => MapEntry('$key', value));
        }
      }
    } catch (e) {
      // 设置文件损坏时退回空设置，避免整个应用启动失败。
      print('[AppPreferences] 读取设置失败: $e');
    }
    return <String, Object>{};
  }

  /// 重新从磁盘读取设置到当前实例（还原备份后调用）。
  ///
  /// 不重载的话，还原完成后任何一次设置写入都会用**还原前**的内存值把
  /// 整个 settings.json 覆盖回去，等于还原白做。
  Future<void> reload() async {
    final file = _file;
    if (file == null) return;
    final fresh = await _readFileValues(file);
    if (fresh.isEmpty && !await file.exists()) return;
    _values
      ..clear()
      ..addAll(fresh);
  }

  /// 把旧版 shared_preferences.json 的内容迁移过来（只迁移一次）。
  static Future<void> _migrateLegacyWindowsFile(
    Map<String, Object> values,
  ) async {
    // 直接拼旧目录的路径，不调用 path_provider：否则为了读旧文件又会在
    // 系统漫游目录里创建出一个空文件夹。
    final legacyDir = AppPaths.legacySupportDirectoryPath;
    if (legacyDir == null) return;
    final legacy = File(p.join(legacyDir, _legacyFileName));
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

  /// 读取 shared_preferences 里的全部键（Android / iOS 的旧存储位置）。
  ///
  /// 键前缀由插件自己处理，这里拿到的已经是去掉 `flutter.` 之后的键名，
  /// 可以直接写进 settings.json。
  static Future<Map<String, Object>> _readSharedPreferences() async {
    final values = <String, Object>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      for (final key in prefs.getKeys()) {
        final value = prefs.get(key);
        if (value is List) {
          values[key] = [for (final item in value) '$item'];
        } else if (value is bool ||
            value is int ||
            value is double ||
            value is String) {
          values[key] = value as Object;
        }
      }
      if (values.isNotEmpty) {
        print('[AppPreferences] 已从 shared_preferences 迁移 ${values.length} 项设置');
      }
    } catch (e) {
      print('[AppPreferences] 读取 shared_preferences 失败: $e');
    }
    return values;
  }

  // ---------------------------------------------------------------- 读取

  bool? getBool(String key) {
    final value = _values[key];
    return value is bool ? value : null;
  }

  int? getInt(String key) {
    final value = _values[key];
    return value is int ? value : null;
  }

  double? getDouble(String key) {
    final value = _values[key];
    return value is double ? value : (value is int ? value.toDouble() : null);
  }

  String? getString(String key) {
    final value = _values[key];
    return value is String ? value : null;
  }

  List<String>? getStringList(String key) {
    final value = _values[key];
    if (value is List) {
      return value.map((item) => '$item').toList();
    }
    return null;
  }

  bool containsKey(String key) => _values.containsKey(key);

  Set<String> getKeys() => _values.keys.toSet();

  // ---------------------------------------------------------------- 写入

  Future<bool> setBool(String key, bool value) {
    _values[key] = value;
    return _flush();
  }

  Future<bool> setInt(String key, int value) {
    _values[key] = value;
    return _flush();
  }

  Future<bool> setDouble(String key, double value) {
    _values[key] = value;
    return _flush();
  }

  Future<bool> setString(String key, String value) {
    _values[key] = value;
    return _flush();
  }

  Future<bool> setStringList(String key, List<String> value) {
    _values[key] = List<String>.from(value);
    return _flush();
  }

  Future<bool> remove(String key) {
    _values.remove(key);
    return _flush();
  }

  Future<bool> clear() {
    _values.clear();
    return _flush();
  }

  /// 把内存中的设置写回磁盘。
  Future<bool> _flush() {
    final file = _file;
    if (file == null) return Future.value(true);
    // 任何设置变更都通知一次（节流交给 AutoBackup：它只做防抖，不会立刻读文件）。
    // 插件、热榜、电台、扫描目录、字体等最终都写 settings.json，挂在这里就能
    // 一次性覆盖所有触发源。
    onWrite?.call();
    return _writeFile(file, _values);
  }

  /// 设置写盘时的回调（启动流程注入「自动同步」的备份调度器）。
  static void Function()? onWrite;

  /// 原子写：写 `.tmp` → 旧文件改名 `.bak` → `.tmp` 改名进来。
  ///
  /// 任何时刻磁盘上都保留一份完整可读的文件（旧版是「delete 旧文件再
  /// rename」，两步之间崩溃 / 掉电会连一份完整的设置都不剩）；`.bak` 同时
  /// 留作损坏时回退。
  static Future<bool> _writeFile(File file, Map<String, Object> values) async {
    try {
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(values), flush: true);
      final bak = File('${file.path}.bak');
      if (await file.exists()) {
        if (await bak.exists()) {
          await bak.delete();
        }
        await file.rename(bak.path);
      }
      await temp.rename(file.path);
      return true;
    } catch (e) {
      print('[AppPreferences] 写入设置失败: $e');
      return false;
    }
  }
}
