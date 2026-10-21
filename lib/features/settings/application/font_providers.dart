import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_font_manager.dart';
import '../../../core/theme/app_typography.dart';

/// 已导入的字体列表。
final appFontsProvider =
    StateNotifierProvider<AppFontsNotifier, List<AppFont>>((ref) {
  return AppFontsNotifier(ref);
});

/// 当前选中的字体族名（null = 使用默认字体）。
final appFontSelectedProvider = StateProvider<String?>((ref) => null);

/// 字体列表与选择的管理。
class AppFontsNotifier extends StateNotifier<List<AppFont>> {
  AppFontsNotifier(this._ref) : super(const <AppFont>[]) {
    unawaited(_load());
  }

  final Ref _ref;
  final AppFontManager _manager = AppFontManager.instance;

  Future<void> _load() async {
    await _manager.load();
    if (!mounted) return;
    state = _manager.fonts;
    // 恢复上次选择的字体。
    final selected = _manager.selectedFamily;
    _ref.read(appFontSelectedProvider.notifier).state = selected;
    _applyFontFamily(selected);
  }

  /// 导入字体文件（可多选），返回成功导入的数量。
  Future<int> importFonts(List<String> paths) async {
    final added = await _manager.importFonts(paths);
    if (!mounted) return 0;
    state = _manager.fonts;
    return added.length;
  }

  /// 选择应用字体（null = 恢复默认字体）。
  ///
  /// [family] 可以是导入字体的族名，也可以是内置字体（思源宋体 / 方正兰亭黑）的族名。
  Future<void> select(String? family) async {
    await _manager.select(family);
    if (!mounted) return;
    state = _manager.fonts;
    _ref.read(appFontSelectedProvider.notifier).state =
        (family == null || family.isEmpty) ? null : family;
    _applyFontFamily(family);
  }

  /// 删除导入的字体。
  Future<void> remove(AppFont font) async {
    await _manager.remove(font);
    if (!mounted) return;
    state = _manager.fonts;
  }

  /// 把选中的字体应用到全局排版。
  static void _applyFontFamily(String? family) {
    AppTypography.fontFamily =
        (family == null || family.isEmpty)
            ? AppTypography.defaultFontFamily
            : family;
  }
}
