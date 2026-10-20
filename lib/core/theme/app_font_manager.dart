import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 导入到应用的字体。
class AppFont {
  /// 字体族名（与文件名一致，导入后作为 `fontFamily` 使用）。
  final String family;

  /// 存放的文件名（位于应用字体目录下）。
  final String fileName;

  const AppFont({required this.family, required this.fileName});

  Map<String, dynamic> toJson() => {'family': family, 'fileName': fileName};

  factory AppFont.fromJson(Map<String, dynamic> json) {
    return AppFont(
      family: json['family']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? '',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppFont && other.family == family && other.fileName == fileName;

  @override
  int get hashCode => Object.hash(family, fileName);
}

/// 应用字体管理：导入 / 注册 / 选择 / 删除字体文件。
///
/// 字体文件会被复制到应用支持目录下的 `fonts` 子目录，并用 [FontLoader]
/// 注册到 Flutter 引擎，之后在「设置 - 外观设置 - 应用字体」里选择其中一个
/// 作为应用字体（也可以恢复默认字体）。
class AppFontManager {
  AppFontManager._();

  static final AppFontManager instance = AppFontManager._();

  static const String _listKey = 'app_font_list';
  static const String _selectedKey = 'app_font_selected';

  /// 支持导入的字体文件后缀。
  static const List<String> supportedExtensions = ['ttf', 'otf', 'ttc'];

  /// 随安装包内置的字体（无需导入即可使用）。
  ///
  /// - `SourceHanSerif`：思源宋体
  /// - `FZLantingHei`：方正兰亭黑
  ///
  /// [asset] 是相对 `flutter_assets` 的资源路径，Windows 端桌面歌词需要
  /// 用它把字体注册进原生侧。
  static const List<({String family, String label, String asset})>
      bundledFonts = [
    (
      family: 'SourceHanSerif',
      label: '思源宋体',
      asset: 'assets/fonts/SourceHanSerif.otf'
    ),
    (
      family: 'FZLantingHei',
      label: '方正兰亭黑',
      asset: 'assets/fonts/FZLantingHei.ttf'
    ),
  ];

  final List<AppFont> _fonts = [];
  String? _selectedFamily;
  bool _loaded = false;

  /// 已导入的字体列表。
  List<AppFont> get fonts => List.unmodifiable(_fonts);

  /// 当前选中的字体族（null = 使用默认字体）。
  String? get selectedFamily => _selectedFamily;

  /// 字体文件的存放目录。
  Future<Directory> fontDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory(p.join(support.path, 'fonts'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// 启动时加载：读出已导入的字体并注册到引擎。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_listKey) ?? const <String>[];
      final dir = await fontDirectory();
      for (final item in raw) {
        try {
          final map = Map<String, dynamic>.from(
            jsonDecode(item) as Map<String, dynamic>,
          );
          final font = AppFont.fromJson(map);
          final file = File(p.join(dir.path, font.fileName));
          if (!await file.exists()) continue;
          await _register(font, file);
          _fonts.add(font);
        } catch (_) {
          // 单个字体损坏时跳过，不影响其它字体。
        }
      }
      final selected = prefs.getString(_selectedKey);
      // 内置字体（思源宋体 / 方正兰亭黑）也可以被选中。
      final isBundled = bundledFonts.any((f) => f.family == selected);
      if (selected != null &&
          (isBundled || _fonts.any((f) => f.family == selected))) {
        _selectedFamily = selected;
      }
    } catch (e) {
      debugPrint('[AppFontManager] 加载字体失败: $e');
    }
  }

  /// 导入字体文件（可多选），返回成功导入的字体。
  Future<List<AppFont>> importFonts(List<String> paths) async {
    final result = <AppFont>[];
    try {
      final dir = await fontDirectory();
      for (final source in paths) {
        try {
          final ext = p.extension(source).replaceFirst('.', '').toLowerCase();
          if (!supportedExtensions.contains(ext)) continue;
          final baseName = p.basenameWithoutExtension(source);
          final fileName = '$baseName.$ext';
          final target = File(p.join(dir.path, fileName));
          final bytes = await File(source).readAsBytes();
          if (bytes.isEmpty) continue;
          await target.writeAsBytes(bytes, flush: true);
          final font = AppFont(family: baseName, fileName: fileName);
          await _register(font, target);
          _fonts.removeWhere((f) => f.family == font.family);
          _fonts.add(font);
          result.add(font);
        } catch (e) {
          debugPrint('[AppFontManager] 导入字体失败 ($source): $e');
        }
      }
      if (result.isNotEmpty) {
        await _persistList();
      }
    } catch (e) {
      debugPrint('[AppFontManager] 导入字体失败: $e');
    }
    return result;
  }

  /// 选择应用字体（null = 恢复默认字体）。
  ///
  /// [family] 可以是导入字体的族名，也可以是内置字体（见 [bundledFonts]）的族名。
  Future<void> select(String? family) async {
    _selectedFamily = (family == null || family.isEmpty) ? null : family;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_selectedFamily == null) {
        await prefs.remove(_selectedKey);
      } else {
        await prefs.setString(_selectedKey, _selectedFamily!);
      }
    } catch (e) {
      debugPrint('[AppFontManager] 保存字体选择失败: $e');
    }
  }

  /// 删除导入的字体。
  Future<void> remove(AppFont font) async {
    try {
      final dir = await fontDirectory();
      final file = File(p.join(dir.path, font.fileName));
      if (await file.exists()) {
        await file.delete();
      }
      _fonts.removeWhere((f) => f.family == font.family);
      if (_selectedFamily == font.family) {
        _selectedFamily = null;
        final prefs = await SharedPreferences.getInstance();
        await prefs.remove(_selectedKey);
      }
      await _persistList();
    } catch (e) {
      debugPrint('[AppFontManager] 删除字体失败: $e');
    }
  }

  Future<void> _persistList() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _listKey,
        _fonts.map((f) => jsonEncode(f.toJson())).toList(),
      );
    } catch (e) {
      debugPrint('[AppFontManager] 保存字体列表失败: $e');
    }
  }

  /// 字体文件在磁盘上的完整路径。
  Future<String> pathOf(AppFont font) async {
    final dir = await fontDirectory();
    return p.join(dir.path, font.fileName);
  }

  /// 把字体文件注册到 Flutter 引擎。
  Future<void> _register(AppFont font, File file) async {
    try {
      final bytes = await file.readAsBytes();
      final loader = FontLoader(font.family)
        ..addFont(
          Future<ByteData>.value(
            ByteData.sublistView(bytes),
          ),
        );
      await loader.load();
    } catch (e) {
      debugPrint('[AppFontManager] 注册字体失败 (${font.family}): $e');
    }
  }
}
