import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/platform/download_paths.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_font_manager.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/services/app_image_cache.dart';
import '../../../shared/services/cache_paths.dart';
import '../../../shared/widgets/hsv_color_picker.dart';
import '../application/font_providers.dart';
import '../application/settings_providers.dart';
import '../data/settings_service.dart';
import '../../player/application/desktop_lyric_controller.dart';
import '../../player/application/desktop_lyric_sync.dart';
import '../../player/domain/models/desktop_lyric_settings.dart';
import '../../player/presentation/widgets/amll_lyric_player.dart';

const _settingsSheetAnimationStyle = AnimationStyle(
  duration: Duration(milliseconds: 220),
  reverseDuration: Duration(milliseconds: 180),
);

void _persistBool(
  BuildContext context,
  StateProvider<bool> provider,
  bool value,
  Future<void> Function(SettingsService svc) saveFn,
) {
  final container = ProviderScope.containerOf(context);
  container.read(provider.notifier).state = value;
  unawaited(_doPersist(container, saveFn));
}

void _persistString(
  BuildContext context,
  StateProvider<String> provider,
  String value,
  Future<void> Function(SettingsService svc) saveFn,
) {
  final container = ProviderScope.containerOf(context);
  container.read(provider.notifier).state = value;
  unawaited(_doPersist(container, saveFn));
}

void _persistDouble(
  BuildContext context,
  StateProvider<double> provider,
  double value,
  Future<void> Function(SettingsService svc) saveFn,
) {
  final container = ProviderScope.containerOf(context);
  container.read(provider.notifier).state = value;
  unawaited(_doPersist(container, saveFn));
}

void _persistInt(
  BuildContext context,
  StateProvider<int> provider,
  int value,
  Future<void> Function(SettingsService svc) saveFn,
) {
  final container = ProviderScope.containerOf(context);
  container.read(provider.notifier).state = value;
  unawaited(_doPersist(container, saveFn));
}

Future<void> _doPersist(
  ProviderContainer container,
  Future<void> Function(SettingsService svc) saveFn,
) async {
  try {
    final svc = await container.read(settingsServiceProvider.future);
    await saveFn(svc);
  } catch (_) {}
}

enum SettingsCategory {
  appearance,
  desktopLyric,
  playback,
  storage,
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  SettingsCategory _activeCategory = SettingsCategory.appearance;

  /// 水平滚动控制器：用于点击标签时将选中项自动居中
  final ScrollController _tabScrollController = ScrollController();

  /// 每个标签按钮的 GlobalKey，用于测量位置
  final List<GlobalKey> _tabKeys =
      List.generate(SettingsCategory.values.length, (_) => GlobalKey());

  static const _categoryConfig = {
    SettingsCategory.appearance: (icon: Icons.palette, label: '外观设置'),
    SettingsCategory.desktopLyric: (icon: Icons.lyrics, label: '桌面歌词'),
    SettingsCategory.playback: (icon: Icons.play_circle, label: '播放设置'),
    SettingsCategory.storage: (icon: Icons.storage, label: '缓存设置'),
  };

  @override
  void dispose() {
    _tabScrollController.dispose();
    super.dispose();
  }

  /// 点击标签后，将选中项平滑滚动到可视区域中央
  void _scrollToActiveTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_tabScrollController.hasClients) return;

      final index = SettingsCategory.values.indexOf(_activeCategory);
      if (index < 0 || index >= _tabKeys.length) return;

      final key = _tabKeys[index];
      final context = key.currentContext;
      if (context == null) return;

      // 获取标签按钮的位置信息
      final box = context.findRenderObject() as RenderBox?;
      if (box == null) return;

      final buttonCenter = box.localToGlobal(Offset(box.size.width / 2, 0)).dx;
      final viewportWidth =
          _tabScrollController.position.viewportDimension;
      final currentScroll = _tabScrollController.offset;

      // 计算需要滚动的距离，使按钮居中
      final targetOffset =
          currentScroll + buttonCenter - viewportWidth / 2;
      final clampedOffset = targetOffset.clamp(
        _tabScrollController.position.minScrollExtent,
        _tabScrollController.position.maxScrollExtent,
      );

      _tabScrollController.animateTo(
        clampedOffset,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(colors),
            _buildCategoryTabs(colors),
            Expanded(child: _buildContent(colors)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    final isTablet = ResponsiveLayout.isTablet(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ResponsiveLayout.horizontalPadding(context),
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          if (context.canPop()) ...[
            IconButton(
              icon: Icon(Icons.arrow_back, color: colors.textPrimary),
              onPressed: () => context.pop(),
              visualDensity: VisualDensity.compact,
              tooltip: context.tr('返回'),
            ),
            const SizedBox(width: AppSpacing.xs),
          ],
          Text(
            context.tr('设置'),
            style: TextStyle(
              fontSize: isTablet ? 26 : 22,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryTabs(ThemeColors colors) {
    return SizedBox(
      height: 48,
      child: Stack(
        children: [
          // 标签列表（可横向滚动）
          ListView(
            controller: _tabScrollController,
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            children: SettingsCategory.values.asMap().entries.map((entry) {
              final index = entry.key;
              final cat = entry.value;
              final config = _categoryConfig[cat]!;
              final isActive = _activeCategory == cat;
              return Padding(
                key: _tabKeys[index],
                padding: const EdgeInsets.only(right: AppSpacing.sm),
                child: Material(
                  color: isActive ? colors.primary : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      setState(() {
                        _activeCategory = cat;
                      });
                      _scrollToActiveTab();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: isActive ? colors.primary : colors.divider,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            config.icon,
                            size: 16,
                            color: isActive
                                ? Colors.white
                                : colors.textSecondary,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            context.tr(config.label),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: isActive
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                              color: isActive
                                  ? Colors.white
                                  : colors.textSecondary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

        ],
      ),
    );
  }


  Widget _buildContent(ThemeColors colors) {
    // Only build the active category to avoid constructing all categories
    // (and their heavy providers like plugins, directory scanning, etc.) on
    // first render, which causes a noticeable delay when navigating here.
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.md,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.xxxl,
      ),
      child: _buildContentForCategory(_activeCategory),
    );
  }

  Widget _buildContentForCategory(SettingsCategory cat) {
    switch (cat) {
      case SettingsCategory.appearance:
        return const _AppearanceContent();
      case SettingsCategory.desktopLyric:
        return const _DesktopLyricContent();
      case SettingsCategory.playback:
        return const _PlaybackContent();
      case SettingsCategory.storage:
        return const _StorageContent();
    }
  }

}

class _SettingGroup extends StatelessWidget {
  final String title;
  final String? subtitle;
  final ThemeColors colors;
  final List<Widget> children;
  const _SettingGroup({
    required this.title,
    this.subtitle,
    required this.colors,
    required this.children,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.tr(title),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              context.tr(subtitle!),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

class _SettingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final ThemeColors colors;
  final VoidCallback? onTap;
  const _SettingRow({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.trailing,
    required this.colors,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.textSecondary),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr(title),
                    style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  ),
                  if (subtitle != null)
                    Text(
                      context.tr(subtitle!),
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                ],
              ),
            ),
            trailing,
          ],
        ),
      ),
    );
  }
}

class _SettingDivider extends StatelessWidget {
  final ThemeColors colors;
  const _SettingDivider({required this.colors});
  @override
  Widget build(BuildContext context) => Divider(
    height: 1,
    indent: 32,
    color: colors.divider.withValues(alpha: 0.5),
  );
}

void _showBottomPicker(
  BuildContext context,
  ThemeColors colors,
  String title,
  List<String> options,
  String current,
  ValueChanged<String> onSelected,
) {
  showModalBottomSheet(
    context: context,
    sheetAnimationStyle: _settingsSheetAnimationStyle,
    backgroundColor: colors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      final maxHeight = MediaQuery.of(context).size.height * 0.6;
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: colors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.tr(title),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                ...options.map(
                  (o) => ListTile(
                    title: Text(
                      context.tr(o),
                      style: TextStyle(
                        fontSize: 15,
                        color: o == current
                            ? colors.primary
                            : colors.textPrimary,
                        fontWeight: o == current
                            ? FontWeight.w500
                            : FontWeight.normal,
                      ),
                    ),
                    trailing: o == current
                        ? Icon(Icons.check, size: 20, color: colors.primary)
                        : null,
                    onTap: () {
                      onSelected(o);
                      Navigator.pop(context);
                    },
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      );
    },
  );
}

Color _parseHexColor(String hex) {
  try {
    final code = hex.replaceFirst('#', '');
    return Color(int.parse('FF$code', radix: 16));
  } catch (_) {
    return const Color(0xFF73BCFC);
  }
}

/// 外观设置里「主题色 / 字体颜色 / 第二字体颜色」的内置颜色。
const List<(String, String)> _presetColors = [
  ('#1DB954', 'Spotify 绿'),
  ('#6366F1', '靛蓝'),
  ('#3B82F6', '天蓝'),
  ('#EC4899', '粉红'),
  ('#F59E0B', '琥珀'),
  ('#EF4444', '红色'),
  ('#8B5CF6', '紫色'),
  ('#14B8A6', '青绿'),
  ('#F97316', '橙色'),
  ('#06B6D4', '蓝绿'),
];

/// 合并内置颜色与用户自定义颜色（按色值去重，内置颜色优先）。
List<(String, String)> _mergeColors(
  List<(String, String)> presets,
  List<String> custom,
) {
  final seen = <String>{};
  final merged = <(String, String)>[];
  for (final item in presets) {
    if (seen.add(item.$1.toUpperCase())) merged.add(item);
  }
  for (final hex in custom) {
    if (seen.add(hex.toUpperCase())) merged.add((hex, '自定义'));
  }
  return merged;
}

/// 在自定义颜色列表里新增或替换颜色。
///
/// [replacing] 不为空时替换该颜色（编辑场景），否则追加（新增场景）。
List<String> _upsertCustomColor(
  List<String> current,
  String hex,
  String? replacing,
) {
  final target = hex.toUpperCase();
  final replaceTarget = replacing?.toUpperCase();
  final next = <String>[];
  var inserted = false;
  for (final item in current) {
    final upper = item.toUpperCase();
    if (replaceTarget != null && upper == replaceTarget) {
      if (!inserted) {
        next.add(hex);
        inserted = true;
      }
      continue;
    }
    if (upper == target) continue;
    next.add(item);
  }
  if (!inserted && !next.any((item) => item.toUpperCase() == target)) {
    next.add(hex);
  }
  return next;
}

/// 颜色选择面板里的一个圆形色块。
class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.hex,
    required this.selected,
    required this.colors,
    required this.onTap,
    this.onLongPress,
  });

  final String hex;
  final bool selected;
  final ThemeColors colors;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final color = _parseHexColor(hex);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: selected
              ? Border.all(color: colors.textPrimary, width: 3)
              : null,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: color.withValues(alpha: 0.4),
                    blurRadius: 8,
                  ),
                ]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 24)
            : null,
      ),
    );
  }
}

/// 主题模式对应的显示名（选择主题弹窗的选项文案）。
String _themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.dark => '深色主题',
  ThemeMode.system => '跟随系统',
  ThemeMode.light => '浅色主题',
};

/// 选择主题弹窗的选项文案对应的主题模式。
ThemeMode _themeModeFromLabel(String label) => switch (label) {
  '深色主题' => ThemeMode.dark,
  '跟随系统' => ThemeMode.system,
  _ => ThemeMode.light,
};

// ==================== Appearance ====================

class _AppearanceContent extends ConsumerWidget {
  const _AppearanceContent();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildThemeGroup(context, ref, colors),
        _buildBackgroundModeGroup(context, ref, colors),
      ],
    );
  }

  Widget _buildThemeGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final themeMode = ref.watch(themeModeProvider);
    final platformBrightness = ref.watch(platformBrightnessProvider);
    final themeName = _themeModeLabel(themeMode);
    // 跟随系统时把实际生效的亮/暗显示出来（CeruMusic 里只通过开关状态间接体现）
    final themeSubtitle = themeMode == ThemeMode.system
        ? '跟随系统，当前为${isThemeModeLight(themeMode, platformBrightness) ? '浅色' : '深色'}'
        : '选择应用的主题颜色';
    final primaryHex = ref.watch(themePrimaryColorProvider);
    final fontColorHex = ref.watch(themeFontColorProvider);
    final secondaryFontColorHex = ref.watch(themeSecondaryFontColorProvider);
    // 已导入 / 选中的应用字体
    final importedFonts = ref.watch(appFontsProvider);
    final selectedFont = ref.watch(appFontSelectedProvider);
    final fontName = selectedFont ?? '默认字体';
    final fontSubtitle =
        '内置 ${AppFontManager.bundledFonts.length} 个字体'
        '${importedFonts.isEmpty ? '' : '，已导入 ${importedFonts.length} 个'}，'
        '当前使用：$fontName';
    return _SettingGroup(
      title: '基础外观',
      subtitle: '主题和外观配置',
      colors: colors,
      children: [
        _SettingRow(
          icon: Icons.palette,
          title: '应用主题',
          subtitle: themeSubtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(themeName),
                style: TextStyle(fontSize: 13, color: colors.textHint),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
            ],
          ),
          colors: colors,
          onTap: () => _showBottomPicker(
            context,
            colors,
            '选择主题',
            const ['浅色主题', '深色主题', '跟随系统'],
            themeName,
            (v) {
              final container = ProviderScope.containerOf(context);
              final mode = _themeModeFromLabel(v);
              container.read(themeModeProvider.notifier).state = mode;
              unawaited(
                _doPersist(
                  container,
                  (s) => s.setThemeMode(themeModeToPref(mode)),
                ),
              );
            },
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.color_lens,
          title: '主题色',
          subtitle:
              '当前: ${_presetColors.firstWhere((c) => c.$1 == primaryHex, orElse: () => (primaryHex, '自定义')).$2}',
          trailing: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _parseHexColor(primaryHex),
              border: Border.all(color: colors.divider, width: 1.5),
            ),
          ),
          colors: colors,
          onTap: () => _showPalettePicker(
            context,
            colors,
            title: '选择主题色',
            currentProvider: themePrimaryColorProvider,
            customProvider: customThemeColorsProvider,
            persistCurrent: (s, hex) => s.setThemePrimaryColor(hex),
            persistCustom: (s, list) => s.setCustomThemeColors(list),
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.text_fields,
          title: '字体颜色',
          subtitle: fontColorHex.isEmpty
              ? '主文字颜色（当前使用主题默认色）'
              : '主文字颜色：$fontColorHex',
          trailing: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: fontColorHex.isEmpty
                  ? colors.textPrimary
                  : _parseHexColor(fontColorHex),
              border: Border.all(color: colors.divider, width: 1.5),
            ),
          ),
          colors: colors,
          onTap: () => _showPalettePicker(
            context,
            colors,
            title: '选择字体颜色',
            currentProvider: themeFontColorProvider,
            customProvider: customFontColorsProvider,
            persistCurrent: (s, hex) => s.setThemeFontColor(hex),
            persistCustom: (s, list) => s.setCustomFontColors(list),
            showReset: true,
            emptyInitialColor: colors.textPrimary,
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.text_fields_outlined,
          title: '第二字体颜色',
          subtitle: secondaryFontColorHex.isEmpty
              ? '次级文字颜色（当前使用主题默认色）'
              : '次级文字颜色：$secondaryFontColorHex',
          trailing: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: secondaryFontColorHex.isEmpty
                  ? colors.textSecondary
                  : _parseHexColor(secondaryFontColorHex),
              border: Border.all(color: colors.divider, width: 1.5),
            ),
          ),
          colors: colors,
          onTap: () => _showPalettePicker(
            context,
            colors,
            title: '选择第二字体颜色',
            currentProvider: themeSecondaryFontColorProvider,
            customProvider: customSecondaryFontColorsProvider,
            persistCurrent: (s, hex) => s.setThemeSecondaryFontColor(hex),
            persistCustom: (s, list) => s.setCustomSecondaryFontColors(list),
            showReset: true,
            emptyInitialColor: colors.textSecondary,
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.font_download_outlined,
          title: '应用字体',
          subtitle: fontSubtitle,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(fontName),
                style: TextStyle(fontSize: 13, color: colors.textHint),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
            ],
          ),
          colors: colors,
          onTap: () => _showAppFontSheet(context, colors),
        ),
      ],
    );
  }

  /// 主题色 / 字体颜色 / 第二字体颜色的通用选择面板。
  ///
  /// 内置颜色与用户新增的自定义颜色一起显示；长按自定义颜色可以编辑或删除。
  /// [showReset] 为 true 时第一个圆圈表示恢复主题默认色（字体颜色用）。
  void _showPalettePicker(
    BuildContext context,
    ThemeColors colors, {
    required String title,
    required StateProvider<String> currentProvider,
    required StateProvider<List<String>> customProvider,
    required Future<void> Function(SettingsService svc, String hex)
        persistCurrent,
    required Future<void> Function(SettingsService svc, List<String> colors)
        persistCustom,
    bool showReset = false,
    Color? emptyInitialColor,
  }) {
    final container = ProviderScope.containerOf(context);
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: _settingsSheetAnimationStyle,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => Consumer(
        builder: (_, ref, __) {
          final currentHex = ref.watch(currentProvider);
          final custom = ref.watch(customProvider);
          final customUpper = custom.map((e) => e.toUpperCase()).toSet();
          final allColors = _mergeColors(_presetColors, custom);

          void apply(String hex) {
            ref.read(currentProvider.notifier).state = hex;
            unawaited(_doPersist(container, (s) => persistCurrent(s, hex)));
            Navigator.pop(sheetContext);
          }

          // 保存 / 编辑颜色后重新打开颜色列表，让新增的颜色立即可见。
          void reopenPalette() {
            if (!context.mounted) return;
            _showPalettePicker(
              context,
              colors,
              title: title,
              currentProvider: currentProvider,
              customProvider: customProvider,
              persistCurrent: persistCurrent,
              persistCustom: persistCustom,
              showReset: showReset,
              emptyInitialColor: emptyInitialColor,
            );
          }

          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      sheetContext.tr(title),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        if (showReset)
                          GestureDetector(
                            onTap: () => apply(''),
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.surfaceVariant,
                                border: currentHex.isEmpty
                                    ? Border.all(
                                        color: colors.textPrimary,
                                        width: 3,
                                      )
                                    : Border.all(
                                        color: colors.divider,
                                        width: 1,
                                      ),
                              ),
                              child: Icon(
                                Icons.restart_alt,
                                size: 22,
                                color: colors.textSecondary,
                              ),
                            ),
                          ),
                        for (final item in allColors)
                          _ColorDot(
                            hex: item.$1,
                            selected: item.$1.toUpperCase() ==
                                currentHex.toUpperCase(),
                            colors: colors,
                            onTap: () => apply(item.$1),
                            onLongPress:
                                customUpper.contains(item.$1.toUpperCase())
                                ? () => _showCustomColorActions(
                                    sheetContext,
                                    colors,
                                    item.$1,
                                    onEdit: () {
                                      Navigator.pop(sheetContext);
                                      _openColorEditor(
                                        context,
                                        colors,
                                        title: title,
                                        initial: _parseHexColor(item.$1),
                                        editingHex: item.$1,
                                        currentProvider: currentProvider,
                                        customProvider: customProvider,
                                        persistCurrent: persistCurrent,
                                        persistCustom: persistCustom,
                                        onSaved: reopenPalette,
                                      );
                                    },
                                    onDelete: () {
                                      final next = ref
                                          .read(customProvider)
                                          .where(
                                            (value) =>
                                                value.toUpperCase() !=
                                                item.$1.toUpperCase(),
                                          )
                                          .toList();
                                      ref.read(customProvider.notifier).state =
                                          next;
                                      unawaited(
                                        _doPersist(
                                          container,
                                          (s) => persistCustom(s, next),
                                        ),
                                      );
                                    },
                                  )
                                : null,
                          ),
                      ],
                    ),
                    if (showReset) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        sheetContext.tr('第一个圆圈表示恢复主题默认色'),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textHint,
                        ),
                      ),
                    ],
                    if (custom.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        sheetContext.tr('长按自定义颜色可编辑或删除'),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textHint,
                        ),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.md),
                    // 新增自定义颜色
                    OutlinedButton.icon(
                      onPressed: () {
                        final initial = currentHex.isEmpty
                            ? (emptyInitialColor ?? colors.textPrimary)
                            : _parseHexColor(currentHex);
                        Navigator.pop(sheetContext);
                        _openColorEditor(
                          context,
                          colors,
                          title: title,
                          initial: initial,
                          editingHex: null,
                          currentProvider: currentProvider,
                          customProvider: customProvider,
                          persistCurrent: persistCurrent,
                          persistCustom: persistCustom,
                          onSaved: reopenPalette,
                        );
                      },
                      icon: const Icon(Icons.colorize, size: 18),
                      label: Text(sheetContext.tr('新增颜色')),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 打开 HSV 取色面板：保存后应用颜色，并同步到自定义颜色列表。
  void _openColorEditor(
    BuildContext context,
    ThemeColors colors, {
    required String title,
    required Color initial,
    required String? editingHex,
    required StateProvider<String> currentProvider,
    required StateProvider<List<String>> customProvider,
    required Future<void> Function(SettingsService svc, String hex)
        persistCurrent,
    required Future<void> Function(SettingsService svc, List<String> colors)
        persistCustom,
    VoidCallback? onSaved,
  }) {
    final container = ProviderScope.containerOf(context);
    _showHsvColorPicker(
      context,
      colors,
      title: title,
      initial: initial,
      onSave: (hex) {
        container.read(currentProvider.notifier).state = hex;
        unawaited(_doPersist(container, (s) => persistCurrent(s, hex)));
        final next = _upsertCustomColor(
          container.read(customProvider),
          hex,
          editingHex,
        );
        container.read(customProvider.notifier).state = next;
        unawaited(_doPersist(container, (s) => persistCustom(s, next)));
        onSaved?.call();
      },
    );
  }

  /// 长按自定义颜色：编辑 / 删除。
  void _showCustomColorActions(
    BuildContext context,
    ThemeColors colors,
    String hex, {
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: _settingsSheetAnimationStyle,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (actionContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Row(
                children: [
                  Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _parseHexColor(hex),
                      border: Border.all(color: colors.divider, width: 1),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    '${actionContext.tr('自定义颜色')} $hex',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            _SettingDivider(colors: colors),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: colors.textSecondary),
              title: Text(
                actionContext.tr('编辑颜色'),
                style: TextStyle(color: colors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(actionContext);
                onEdit();
              },
            ),
            ListTile(
              leading: Icon(
                Icons.delete_outline,
                color: colors.textSecondary,
              ),
              title: Text(
                actionContext.tr('删除颜色'),
                style: TextStyle(color: colors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(actionContext);
                onDelete();
              },
            ),
            const SizedBox(height: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  /// HSV 取色面板：选择颜色后可以「保存」或「取消」。
  void _showHsvColorPicker(
    BuildContext context,
    ThemeColors colors, {
    required String title,
    required Color initial,
    required ValueChanged<String> onSave,
  }) {
    showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: _settingsSheetAnimationStyle,
      backgroundColor: colors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sheetContext.tr(title),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                HsvColorPicker(
                  initialColor: initial,
                  onCancel: () => Navigator.pop(sheetContext),
                  onSave: (color) {
                    // 先关闭取色面板，再应用颜色（保存后会重新打开颜色列表）。
                    final hex = _toHexString(color);
                    Navigator.pop(sheetContext);
                    onSave(hex);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 颜色转 #RRGGBB 字符串。
  String _toHexString(Color color) {
    final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
    final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
    final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
    return '#${r.toUpperCase()}${g.toUpperCase()}${b.toUpperCase()}';
  }

  /// 应用字体：导入字体文件（可多选）并选择其中之一。
  Future<void> _showAppFontSheet(
    BuildContext context,
    ThemeColors colors,
  ) async {
    await showModalBottomSheet(
      context: context,
      sheetAnimationStyle: _settingsSheetAnimationStyle,
      backgroundColor: colors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      // 弹层内容用 Consumer 包裹：导入 / 删除字体后列表能自动刷新。
      builder: (sheetContext) => Consumer(
        builder: (context, sheetRef, _) {
          final notifier = sheetRef.read(appFontsProvider.notifier);
          final fonts = sheetRef.watch(appFontsProvider);
          final selected = sheetRef.watch(appFontSelectedProvider);
          return SafeArea(
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: colors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      context.tr('应用字体'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      context.tr('导入字体文件（可多选），选择其中之一作为应用字体'),
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // 内置字体（随安装包提供，无需导入）
                    ...AppFontManager.bundledFonts.map((font) {
                      return _buildFontOption(
                        sheetContext,
                        colors,
                        title: context.tr(font.label),
                        subtitle: context.tr('内置字体'),
                        isSelected: selected == font.family,
                        onTap: () async {
                          await notifier.select(font.family);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                      );
                    }),
                    // 默认字体
                    _buildFontOption(
                      sheetContext,
                      colors,
                      title: context.tr('默认字体'),
                      subtitle: context.tr('使用系统默认字体'),
                      isSelected: selected == null,
                      onTap: () async {
                        await notifier.select(null);
                        if (sheetContext.mounted) Navigator.pop(sheetContext);
                      },
                    ),
                    ...fonts.map((font) {
                      return _buildFontOption(
                        sheetContext,
                        colors,
                        title: font.family,
                        subtitle: font.fileName,
                        isSelected: selected == font.family,
                        onTap: () async {
                          await notifier.select(font.family);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        onDelete: fonts.length > 1 || selected != font.family
                            ? () async {
                                await notifier.remove(font);
                              }
                            : null,
                      );
                    }),
                    const SizedBox(height: AppSpacing.sm),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: () async {
                          final result = await FilePicker.platform.pickFiles(
                            type: FileType.custom,
                            allowedExtensions: AppFontManager.supportedExtensions,
                            allowMultiple: true,
                          );
                          if (result == null) return;
                          final paths = result.files
                              .map((f) => f.path)
                              .whereType<String>()
                              .toList();
                          if (paths.isEmpty) return;
                          final count = await notifier.importFonts(paths);
                          if (!sheetContext.mounted) return;
                          if (count > 0) {
                            _showSettingsMessage(
                              sheetContext,
                              '已导入 $count 个字体文件',
                            );
                          } else {
                            _showSettingsMessage(
                              sheetContext,
                              '没有可导入的字体文件',
                            );
                          }
                        },
                        icon: const Icon(Icons.file_upload_outlined, size: 18),
                        label: Text(context.tr('导入字体文件')),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 顶部提示条。
  void _showSettingsMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr(message))),
    );
  }

  Widget _buildFontOption(
    BuildContext context,
    ThemeColors colors, {
    required String title,
    required String subtitle,
    required bool isSelected,
    required VoidCallback onTap,
    VoidCallback? onDelete,
  }) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      onTap: onTap,
      leading: Icon(
        isSelected ? Icons.radio_button_checked : Icons.radio_button_off,
        color: isSelected ? colors.primary : colors.textHint,
      ),
      title: Text(
        title,
        style: TextStyle(fontSize: 14, color: colors.textPrimary),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11, color: colors.textHint),
      ),
      trailing: onDelete == null
          ? null
          : IconButton(
              onPressed: onDelete,
              icon: Icon(Icons.delete_outline, size: 18, color: colors.error),
              tooltip: context.tr('删除'),
            ),
    );
  }

  /// 播放详情页背景（原「全屏播放背景」）。
  Widget _buildBackgroundModeGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final bgMode = ref.watch(fullScreenBackgroundModeProvider);
    final modeLabels = {
      FullScreenBackgroundMode.theme: '跟随主题',
      FullScreenBackgroundMode.cover: '封面模糊',
      FullScreenBackgroundMode.dark: '纯黑背景',
    };
    final currentLabel = modeLabels[bgMode] ?? '纯黑背景';
    return _SettingGroup(
      title: '播放详情页背景',
      subtitle: '播放详情页（歌词页 / 播放页）的背景模式',
      colors: colors,
      children: [
        _SettingRow(
          icon: Icons.wallpaper,
          title: '背景模式',
          subtitle: '当前: $currentLabel',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(currentLabel),
                style: TextStyle(fontSize: 13, color: colors.textHint),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
            ],
          ),
          colors: colors,
          onTap: () => _showBottomPicker(
            context,
            colors,
            '背景模式',
            ['跟随主题', '封面模糊', '纯黑背景'],
            currentLabel,
            (v) {
              final map = {
                '跟随主题': FullScreenBackgroundMode.theme,
                '封面模糊': FullScreenBackgroundMode.cover,
                '纯黑背景': FullScreenBackgroundMode.dark,
              };
              final container = ProviderScope.containerOf(context);
              container.read(fullScreenBackgroundModeProvider.notifier).state =
                  map[v] ?? FullScreenBackgroundMode.dark;
              unawaited(
                _doPersist(
                  container,
                  (s) => s.setFullScreenBgMode(
                    v == '纯黑背景'
                        ? 'dark'
                        : (v == '跟随主题' ? 'theme' : 'cover'),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ==================== Desktop Lyric ====================

class _DesktopLyricContent extends ConsumerWidget {
  const _DesktopLyricContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDesktopLyricGroup(context, ref, colors),
      ],
    );
  }

  Widget _buildDesktopLyricGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final s = ref.watch(desktopLyricSettingsProvider);
    final status = ref.watch(desktopLyricSyncProvider);
    final needPermission = status.supported && !status.permissionGranted;

    void update(DesktopLyricSettings Function(DesktopLyricSettings) fn) =>
        updateDesktopLyricSettings(ref.read, fn);

    final alignXLabel = switch (s.textAlignX) {
      DesktopLyricTextAlignX.left => '左对齐',
      DesktopLyricTextAlignX.center => '居中',
      DesktopLyricTextAlignX.right => '右对齐',
    };
    final alignYLabel = switch (s.textAlignY) {
      DesktopLyricTextAlignY.top => '顶部',
      DesktopLyricTextAlignY.center => '居中',
      DesktopLyricTextAlignY.bottom => '底部',
    };

    return _SettingGroup(
      title: '桌面歌词',
      subtitle: Platform.isWindows
          ? '独立的桌面歌词窗口（始终置顶），应用最小化后仍显示在桌面上，可拖动'
          : '悬浮在页面之上的歌词窗，可拖动位置，锁定后点击穿透',
      colors: colors,
      children: [
        _SettingRow(
          icon: Icons.lyrics,
          title: '启用桌面歌词',
          subtitle: needPermission
              ? '需要「在其他应用上层显示」权限，开启时会跳转到授权页'
              : (Platform.isWindows
                  ? '开启后弹出独立的桌面歌词窗口（始终置顶），可拖动，锁定后点击穿透'
                  : '开启后歌词窗悬浮在其它应用之上，可拖动，锁定后点击穿透'),
          trailing: Switch(
            // 未拿到悬浮窗权限时保持关闭:授权成功后才自动置为开启。
            value: s.enable,
            onChanged: (v) {
              final sync = ref.read(desktopLyricSyncProvider.notifier);
              if (v) {
                unawaited(sync.enableDesktopLyric());
              } else {
                unawaited(sync.disableDesktopLyric());
              }
            },
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: s.isLock ? Icons.lock : Icons.lock_open,
          title: '锁定歌词窗',
          subtitle: '锁定后不再响应触摸，可穿透点击下层内容',
          trailing: Switch(
            value: s.isLock,
            onChanged: (v) => update((cur) => cur.copyWith(isLock: v)),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.short_text,
          title: '单行显示',
          subtitle: '只显示当前行，文字超长时横向滚动',
          trailing: Switch(
            value: s.isSingleLine,
            onChanged: (v) => update((cur) => cur.copyWith(isSingleLine: v)),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.animation,
          title: '歌词切换动画',
          subtitle: '切换歌词时的淡入淡出效果',
          trailing: Switch(
            value: s.showToggleAnima,
            onChanged: (v) => update((cur) => cur.copyWith(showToggleAnima: v)),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        _SettingDivider(colors: colors),
        _SettingSlider(
          icon: Icons.width_normal,
          title: '窗口宽度',
          subtitle: '歌词窗宽度占屏幕宽度的比例',
          value: s.widthPercent.toDouble(),
          min: 10,
          max: 100,
          divisions: 18,
          valueLabel: '${s.widthPercent}%',
          colors: colors,
          onChanged: (v) =>
              update((cur) => cur.copyWith(widthPercent: v.round())),
        ),
        _SettingDivider(colors: colors),
        _SettingSlider(
          icon: Icons.format_list_numbered,
          title: '显示行数',
          subtitle: '最多同时显示的行数（单行模式下无效）',
          value: s.maxLineNum.toDouble(),
          min: 1,
          max: 8,
          divisions: 7,
          valueLabel: '${s.maxLineNum} 行',
          colors: colors,
          onChanged: (v) => update((cur) => cur.copyWith(maxLineNum: v.round())),
        ),
        _SettingDivider(colors: colors),
        _SettingSlider(
          icon: Icons.format_size,
          title: '字体大小',
          value: s.fontSize,
          min: 12,
          max: 40,
          divisions: 28,
          valueLabel: '${s.fontSize.round()}',
          colors: colors,
          onChanged: (v) => update((cur) => cur.copyWith(fontSize: v)),
        ),
        _SettingDivider(colors: colors),
        _SettingSlider(
          icon: Icons.opacity,
          title: '不透明度',
          value: s.opacityPercent.toDouble(),
          min: 10,
          max: 100,
          divisions: 18,
          valueLabel: '${s.opacityPercent}%',
          colors: colors,
          onChanged: (v) =>
              update((cur) => cur.copyWith(opacityPercent: v.round())),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.format_align_left,
          title: '水平对齐',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(alignXLabel),
                style: TextStyle(fontSize: 13, color: colors.textHint),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
            ],
          ),
          colors: colors,
          onTap: () => _showBottomPicker(
            context,
            colors,
            '水平对齐',
            ['左对齐', '居中', '右对齐'],
            alignXLabel,
            (v) => update(
              (cur) => cur.copyWith(
                textAlignX: v == '居中'
                    ? DesktopLyricTextAlignX.center
                    : (v == '右对齐'
                          ? DesktopLyricTextAlignX.right
                          : DesktopLyricTextAlignX.left),
              ),
            ),
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.vertical_align_top,
          title: '垂直对齐',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(alignYLabel),
                style: TextStyle(fontSize: 13, color: colors.textHint),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
            ],
          ),
          colors: colors,
          onTap: () => _showBottomPicker(
            context,
            colors,
            '垂直对齐',
            ['顶部', '居中', '底部'],
            alignYLabel,
            (v) => update(
              (cur) => cur.copyWith(
                textAlignY: v == '居中'
                    ? DesktopLyricTextAlignY.center
                    : (v == '底部'
                          ? DesktopLyricTextAlignY.bottom
                          : DesktopLyricTextAlignY.top),
              ),
            ),
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.colorize,
          title: '已播放颜色',
          subtitle: '当前歌词行的颜色',
          trailing: _colorSwatch(s.playedColor, colors),
          colors: colors,
          onTap: () => _showDesktopLyricColorPicker(
            context,
            colors,
            '已播放颜色',
            _lyricColorPresets,
            s.playedColor,
            (v) => update((cur) => cur.copyWith(playedColor: v)),
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.text_fields,
          title: '未播放颜色',
          subtitle: '非当前歌词行的颜色',
          trailing: _colorSwatch(s.unplayColor, colors),
          colors: colors,
          onTap: () => _showDesktopLyricColorPicker(
            context,
            colors,
            '未播放颜色',
            _lyricColorPresets,
            s.unplayColor,
            (v) => update((cur) => cur.copyWith(unplayColor: v)),
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.blur_on,
          title: '阴影颜色',
          subtitle: '歌词描边阴影，增强在浅色背景上的可读性',
          trailing: _colorSwatch(s.shadowColor, colors),
          colors: colors,
          onTap: () => _showDesktopLyricColorPicker(
            context,
            colors,
            '阴影颜色',
            _shadowColorPresets,
            s.shadowColor,
            (v) => update((cur) => cur.copyWith(shadowColor: v)),
          ),
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.my_location,
          title: '重置歌词窗位置',
          subtitle: '将歌词窗恢复到默认的左上角位置',
          trailing: Icon(Icons.refresh, size: 18, color: colors.textHint),
          colors: colors,
          onTap: () => update(
            (cur) => cur.copyWith(
              positionX: DesktopLyricSettings.defaults.positionX,
              positionY: DesktopLyricSettings.defaults.positionY,
            ),
          ),
        ),
      ],
    );
  }
}

/// 带标题、数值与滑块的设置行（滑块独占一行，避免与右侧文字挤在一起）。
class _SettingSlider extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final double value;
  final double min;
  final double max;
  final int? divisions;
  final String valueLabel;
  final ValueChanged<double> onChanged;
  final ThemeColors colors;

  const _SettingSlider({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.min,
    required this.max,
    this.divisions,
    required this.valueLabel,
    required this.onChanged,
    required this.colors,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: colors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.tr(title),
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                    ),
                    if (subtitle != null)
                      Text(
                        context.tr(subtitle!),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                  ],
                ),
              ),
              Text(
                valueLabel,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.primary,
                ),
              ),
            ],
          ),
          Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
            activeColor: colors.primary,
            inactiveColor: colors.divider,
          ),
        ],
      ),
    );
  }
}

/// 桌面歌词可用的歌词颜色预设。
const _lyricColorPresets = <(String, int)>[
  ('经典绿', 0xFF07C556),
  ('薄荷绿', 0xFF1DB954),
  ('天蓝', 0xFF3B82F6),
  ('靛蓝', 0xFF6366F1),
  ('粉红', 0xFFEC4899),
  ('红色', 0xFFEF4444),
  ('琥珀', 0xFFF59E0B),
  ('紫色', 0xFF8B5CF6),
  ('白色', 0xFFFFFFFF),
  ('浅灰', 0xFFBDBDBD),
];

/// 桌面歌词可用的阴影颜色预设（含透明度）。
const _shadowColorPresets = <(String, int)>[
  ('无阴影', 0x00000000),
  ('淡阴影', 0x66000000),
  ('标准阴影', 0x99000000),
  ('浓阴影', 0xCC000000),
  ('白色描边', 0x99FFFFFF),
  ('主题蓝', 0x993B82F6),
];

Widget _colorSwatch(int argb, ThemeColors colors) {
  final color = Color(argb);
  final isInvisible = (argb & 0xFF000000) == 0;
  return Container(
    width: 24,
    height: 24,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: isInvisible ? colors.surfaceVariant : color,
      border: Border.all(color: colors.divider, width: 1.5),
    ),
    child: isInvisible
        ? Icon(Icons.block, size: 14, color: colors.textHint)
        : null,
  );
}

void _showDesktopLyricColorPicker(
  BuildContext context,
  ThemeColors colors,
  String title,
  List<(String, int)> presets,
  int currentArgb,
  ValueChanged<int> onSelected,
) {
  showModalBottomSheet(
    context: context,
    sheetAnimationStyle: _settingsSheetAnimationStyle,
    backgroundColor: colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              context.tr(title),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: presets.map((item) {
                final isSelected = item.$2 == currentArgb;
                final color = Color(item.$2);
                return GestureDetector(
                  onTap: () {
                    onSelected(item.$2);
                    Navigator.pop(context);
                  },
                  child: SizedBox(
                    width: 64,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: color,
                            border: isSelected
                                ? Border.all(
                                    color: colors.textPrimary,
                                    width: 3,
                                  )
                                : Border.all(
                                    color: colors.divider,
                                    width: 1.5,
                                  ),
                          ),
                          child: isSelected
                              ? Icon(
                                  Icons.check,
                                  color: color.computeLuminance() > 0.5
                                      ? Colors.black
                                      : Colors.white,
                                  size: 22,
                                )
                              : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          context.tr(item.$1),
                          style: TextStyle(
                            fontSize: 11,
                            color: isSelected
                                ? colors.primary
                                : colors.textHint,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    ),
  );
}

// ==================== Playback ====================

class _PlaybackContent extends ConsumerWidget {
  const _PlaybackContent();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildPlaybackGroup(context, ref, colors),
        _buildEqualizerGroup(context, ref, colors),
        _buildAudioEffectGroup(context, ref, colors),
      ],
    );
  }

  Widget _buildPlaybackGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final autoQualityDowngrade = ref.watch(autoQualityDowngradeProvider);
    final autoSwitchSource = ref.watch(autoSwitchSourceProvider);
    return _SettingGroup(
      title: '播放设置',
      subtitle: '播放行为和音频输出配置',
      colors: colors,
      children: [
        _SettingRow(
          icon: Icons.trending_down,
          title: '音质自动降级',
          subtitle: '当前音质失败时依次尝试更低音质',
          trailing: Switch(
            value: autoQualityDowngrade,
            onChanged: (v) => _persistBool(
              context,
              autoQualityDowngradeProvider,
              v,
              (s) => s.setAutoQualityDowngrade(v),
            ),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.swap_horiz,
          title: '当前音源播放失败自动切换音源',
          subtitle: '关闭后播放失败将停止，不切换音源、不自动播放下一首',
          trailing: Switch(
            value: autoSwitchSource,
            onChanged: (v) => _persistBool(
              context,
              autoSwitchSourceProvider,
              v,
              (s) => s.setAutoSwitchSource(v),
            ),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
      ],
    );
  }

  Widget _buildEqualizerGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final equalizerEnabled = ref.watch(equalizerEnabledProvider);
    final eqPreset = ref.watch(equalizerPresetProvider);
    final eqBands = ref.watch(equalizerBandsProvider);
    final customPresets = ref.watch(equalizerCustomPresetsProvider);
    final allPresetNames = <String>[
      ...kBuiltInPresets.map((p) => p.name),
      ...customPresets.map((p) => p['name'] as String),
    ];
    final isCustom = customPresets.any((p) => p['name'] == eqPreset);
    return _SettingGroup(
      title: '音频均衡器',
      subtitle: '调节音频频段增益 (Professional EQ)',
      colors: colors,
      children: [
        _SettingRow(
          icon: Icons.tune,
          title: '均衡器',
          subtitle: equalizerEnabled ? '开启' : '关闭',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: equalizerEnabled,
                onChanged: (v) {
                  final container = ProviderScope.containerOf(context);
                  container.read(equalizerEnabledProvider.notifier).state = v;
                  unawaited(
                    _doPersist(container, (s) => s.setEqualizerEnabled(v)),
                  );
                },
                activeTrackColor: colors.primary.withValues(alpha: 0.3),
                activeThumbColor: colors.primary,
              ),
              TextButton(
                onPressed: () => _resetEqualizer(context),
                child: Text(
                  context.tr('重置'),
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
            ],
          ),
          colors: colors,
        ),
        // 均衡器关闭时隐藏详细设置（预设、频段滑条、导入导出等）
        if (equalizerEnabled) ...[
          _SettingDivider(colors: colors),
          _SettingRow(
            icon: Icons.graphic_eq,
            title: '均衡器预设',
          subtitle: '选择预设均衡器方案',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(eqPreset),
                style: TextStyle(fontSize: 13, color: colors.textHint),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
            ],
          ),
          colors: colors,
          onTap: () => _showBottomPicker(
            context,
            colors,
            '均衡器预设',
            allPresetNames,
            eqPreset,
            (v) => _applyEqPreset(context, v),
          ),
        ),
        _SettingDivider(colors: colors),
        ...List.generate(10, (i) {
          final freq = kEqFrequencies[i];
          final freqLabel = freq >= 1000 ? '${freq ~/ 1000}k' : '$freq';
          return Column(
            children: [
              _SettingRow(
                icon: Icons.equalizer,
                title: '$freqLabel Hz',
                subtitle: '${eqBands[i].toStringAsFixed(1)}dB',
                trailing: SizedBox(
                  width: 120,
                  child: Slider(
                    value: eqBands[i],
                    min: -12,
                    max: 12,
                    divisions: 240,
                    activeColor: colors.primary,
                    onChanged: equalizerEnabled
                        ? (v) {
                            final container = ProviderScope.containerOf(
                              context,
                            );
                            final nb = List<double>.from(eqBands);
                            nb[i] = v;
                            container
                                    .read(equalizerBandsProvider.notifier)
                                    .state =
                                nb;
                            unawaited(
                              _doPersist(
                                container,
                                (s) => s.setEqualizerBands(jsonEncode(nb)),
                              ),
                            );
                          }
                        : null,
                  ),
                ),
                colors: colors,
              ),
              if (i < 9) _SettingDivider(colors: colors),
            ],
          );
        }),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => _showSavePresetDialog(context, colors),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.primary,
                  side: BorderSide(color: colors.primary),
                ),
                child: Text(context.tr('保存预设')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _exportEqConfig(context, colors),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  side: BorderSide(color: colors.divider),
                ),
                child: Text(context.tr('导出配置')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _importEqConfig(context, colors),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  side: BorderSide(color: colors.divider),
                ),
                child: Text(context.tr('导入配置')),
              ),
            ),
          ],
        ),
        if (isCustom) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      _saveCurrentToPreset(context, eqPreset, eqBands),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: colors.primary,
                    side: BorderSide(color: colors.primary),
                  ),
                  child: Text(context.tr('保存到当前预设')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      _deletePreset(context, eqPreset, customPresets),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red,
                    side: const BorderSide(color: Colors.red),
                  ),
                  child: Text(context.tr('删除预设')),
                ),
              ),
            ],
          ),
          ],
        ],
      ],
    );
  }

  void _applyEqPreset(BuildContext context, String presetName) {
    final container = ProviderScope.containerOf(context);
    for (final p in kBuiltInPresets) {
      if (p.name == presetName) {
        container.read(equalizerBandsProvider.notifier).state =
            List<double>.from(p.gains);
        container.read(equalizerPresetProvider.notifier).state = presetName;
        unawaited(
          _doPersist(container, (s) async {
            await s.setEqualizerPreset(presetName);
            await s.setEqualizerBands(jsonEncode(p.gains));
          }),
        );
        return;
      }
    }
    final customPresets = container.read(equalizerCustomPresetsProvider);
    for (final p in customPresets) {
      if (p['name'] == presetName) {
        final gains = (p['gains'] as List)
            .map((value) => (value as num).toDouble())
            .toList();
        container.read(equalizerBandsProvider.notifier).state =
            List<double>.from(gains);
        container.read(equalizerPresetProvider.notifier).state = presetName;
        unawaited(
          _doPersist(container, (s) async {
            await s.setEqualizerPreset(presetName);
            await s.setEqualizerBands(jsonEncode(gains));
          }),
        );
        return;
      }
    }
  }

  void _resetEqualizer(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    final presetName = container.read(equalizerPresetProvider);
    for (final p in kBuiltInPresets) {
      if (p.name == presetName) {
        container.read(equalizerBandsProvider.notifier).state =
            List<double>.from(p.gains);
        unawaited(
          _doPersist(
            container,
            (s) => s.setEqualizerBands(jsonEncode(p.gains)),
          ),
        );
        return;
      }
    }
    final customPresets = container.read(equalizerCustomPresetsProvider);
    for (final p in customPresets) {
      if (p['name'] == presetName && p['originalGains'] != null) {
        final original = (p['originalGains'] as List)
            .map((value) => (value as num).toDouble())
            .toList();
        container.read(equalizerBandsProvider.notifier).state =
            List<double>.from(original);
        unawaited(
          _doPersist(
            container,
            (s) => s.setEqualizerBands(jsonEncode(original)),
          ),
        );
        return;
      }
    }
    container.read(equalizerBandsProvider.notifier).state = List.filled(
      10,
      0.0,
    );
    unawaited(
      _doPersist(
        container,
        (s) => s.setEqualizerBands(jsonEncode(List.filled(10, 0.0))),
      ),
    );
  }

  void _showSavePresetDialog(BuildContext context, ThemeColors colors) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(context.tr('保存为新预设'), style: TextStyle(color: colors.textPrimary)),
        content: TextField(
          controller: controller,
          decoration: InputDecoration(
            hintText: context.tr('输入预设名称'),
            hintStyle: TextStyle(color: colors.textHint),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: colors.divider),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: colors.primary),
            ),
          ),
          style: TextStyle(color: colors.textPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              _saveNewPreset(context, name);
            },
            child: Text(context.tr('保存'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  void _saveNewPreset(BuildContext context, String name) {
    final container = ProviderScope.containerOf(context);
    if (kBuiltInPresets.any((p) => p.name == name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('"$name" 是内置预设名称')),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final customPresets = List<Map<String, dynamic>>.from(
      container.read(equalizerCustomPresetsProvider),
    );
    if (customPresets.any((p) => p['name'] == name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('预设 "$name" 已存在')),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }
    final currentGains = List<double>.from(
      container.read(equalizerBandsProvider),
    );
    customPresets.add({
      'name': name,
      'gains': currentGains,
      'originalGains': List<double>.from(currentGains),
    });
    container.read(equalizerCustomPresetsProvider.notifier).state =
        customPresets;
    container.read(equalizerPresetProvider.notifier).state = name;
    unawaited(
      _doPersist(container, (s) async {
        await s.setEqualizerCustomPresets(jsonEncode(customPresets));
        await s.setEqualizerPreset(name);
      }),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('预设保存成功')), backgroundColor: Colors.green),
    );
  }

  void _saveCurrentToPreset(
    BuildContext context,
    String presetName,
    List<double> currentBands,
  ) {
    final container = ProviderScope.containerOf(context);
    final customPresets = List<Map<String, dynamic>>.from(
      container.read(equalizerCustomPresetsProvider),
    );
    for (int i = 0; i < customPresets.length; i++) {
      if (customPresets[i]['name'] == presetName) {
        customPresets[i]['gains'] = List<double>.from(currentBands);
        break;
      }
    }
    container.read(equalizerCustomPresetsProvider.notifier).state =
        customPresets;
    unawaited(
      _doPersist(
        container,
        (s) => s.setEqualizerCustomPresets(jsonEncode(customPresets)),
      ),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('已保存当前值到预设 "$presetName"')),
        backgroundColor: Colors.green,
      ),
    );
  }

  void _deletePreset(
    BuildContext context,
    String presetName,
    List<Map<String, dynamic>> customPresets,
  ) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('删除预设')),
        content: Text(context.tr('确定要删除预设 "$presetName" 吗？')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('取消')),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              final container = ProviderScope.containerOf(context);
              final updated = List<Map<String, dynamic>>.from(customPresets)
                ..removeWhere((p) => p['name'] == presetName);
              container.read(equalizerCustomPresetsProvider.notifier).state =
                  updated;
              container.read(equalizerPresetProvider.notifier).state =
                  'Flat(原声)';
              container.read(equalizerBandsProvider.notifier).state =
                  List.filled(10, 0.0);
              unawaited(
                _doPersist(container, (s) async {
                  await s.setEqualizerCustomPresets(jsonEncode(updated));
                  await s.setEqualizerPreset('Flat(原声)');
                  await s.setEqualizerBands(jsonEncode(List.filled(10, 0.0)));
                }),
              );
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(context.tr('预设 "$presetName" 已删除')),
                  backgroundColor: Colors.green,
                ),
              );
            },
            child: Text(context.tr('删除'), style: const TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _exportEqConfig(BuildContext context, ThemeColors colors) async {
    try {
      final container = ProviderScope.containerOf(context);
      final data = jsonEncode({
        'presets': kBuiltInPresets.map((p) => p.toJson()).toList(),
        'customPresets': container.read(equalizerCustomPresetsProvider),
        'currentPreset': container.read(equalizerPresetProvider),
        'gains': container.read(equalizerBandsProvider),
        'enabled': container.read(equalizerEnabledProvider),
      });
      final dir = await AppPaths.configDirectory();
      await File('${dir.path}/mintmusic_eq_config.json').writeAsString(data);
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('均衡器配置已导出')), backgroundColor: colors.primary),
        );
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('导出失败: $e')), backgroundColor: Colors.red),
        );
    }
  }

  Future<void> _importEqConfig(BuildContext context, ThemeColors colors) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final data =
          jsonDecode(await File(result.files.single.path!).readAsString())
              as Map<String, dynamic>;
      if (!context.mounted) return;
      final container = ProviderScope.containerOf(context);
      if (data['customPresets'] != null) {
        final custom = (data['customPresets'] as List)
            .cast<Map<String, dynamic>>();
        container.read(equalizerCustomPresetsProvider.notifier).state = custom;
        unawaited(
          _doPersist(
            container,
            (s) => s.setEqualizerCustomPresets(jsonEncode(custom)),
          ),
        );
      }
      if (data['enabled'] != null) {
        container.read(equalizerEnabledProvider.notifier).state =
            data['enabled'] as bool;
        unawaited(
          _doPersist(
            container,
            (s) => s.setEqualizerEnabled(data['enabled'] as bool),
          ),
        );
      }
      if (data['gains'] != null) {
        final gains = (data['gains'] as List)
            .map((value) => (value as num).toDouble())
            .toList();
        container.read(equalizerBandsProvider.notifier).state = gains;
        unawaited(
          _doPersist(container, (s) => s.setEqualizerBands(jsonEncode(gains))),
        );
      }
      if (data['currentPreset'] != null) {
        container.read(equalizerPresetProvider.notifier).state =
            data['currentPreset'] as String;
        unawaited(
          _doPersist(
            container,
            (s) => s.setEqualizerPreset(data['currentPreset'] as String),
          ),
        );
      }
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('均衡器配置导入成功')), backgroundColor: colors.primary),
        );
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('导入失败: $e')), backgroundColor: Colors.red),
        );
    }
  }

  Widget _buildAudioEffectGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final audioEffect = ref.watch(audioEffectEnabledProvider);
    final bassBoostEnabled = ref.watch(bassBoostEnabledProvider);
    final bassBoostGain = ref.watch(bassBoostGainProvider);
    final bassBoostPreset = ref.watch(bassBoostPresetProvider);
    final surroundEnabled = ref.watch(surroundEnabledProvider);
    final surroundMode = ref.watch(surroundModeProvider);
    final balanceEnabled = ref.watch(balanceEnabledProvider);
    final balanceValue = ref.watch(balanceValueProvider);
    final surroundLabels = {'small': '小房间', 'medium': '中厅堂', 'large': '大教堂'};
    final bassPresetLabels = {'light': '轻度', 'medium': '中度', 'heavy': '重度'};
    return _SettingGroup(
      title: '高级音效处理',
      subtitle: '低音增强、环绕音效、声道平衡',
      colors: colors,
      children: [
        _SettingRow(
          icon: Icons.graphic_eq,
          title: '音效增强',
          subtitle: '启用高级音效处理',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Switch(
                value: audioEffect,
                onChanged: (v) => _persistBool(
                  context,
                  audioEffectEnabledProvider,
                  v,
                  (s) => s.setAudioEffectEnabled(v),
                ),
                activeTrackColor: colors.primary.withValues(alpha: 0.3),
                activeThumbColor: colors.primary,
              ),
              TextButton(
                onPressed: () => _resetAudioEffects(context),
                child: Text(
                  context.tr('重置全部'),
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
            ],
          ),
          colors: colors,
        ),
        // 音效增强关闭时隐藏低音增强 / 环绕音效 / 声道平衡等子项
        if (audioEffect) ...[
          _SettingDivider(colors: colors),
          _SettingRow(
            icon: Icons.speaker,
            title: '低音增强 (Bass Boost)',
          subtitle: bassBoostEnabled
              ? '增益 ${bassBoostGain.toInt()}dB · ${bassPresetLabels[bassBoostPreset] ?? bassBoostPreset}'
              : '关闭',
          trailing: Switch(
            value: bassBoostEnabled,
            onChanged: (v) => _persistBool(
              context,
              bassBoostEnabledProvider,
              v,
              (s) => s.setBassBoostEnabled(v),
            ),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        if (bassBoostEnabled) ...[
          _SettingDivider(colors: colors),
          _SettingRow(
            icon: Icons.speaker,
            title: '低频增益',
            subtitle: '${bassBoostGain.toInt()}dB',
            trailing: SizedBox(
              width: 120,
              child: Slider(
                value: bassBoostGain,
                min: -12,
                max: 12,
                divisions: 48,
                activeColor: colors.primary,
                onChanged: (v) => _persistDouble(
                  context,
                  bassBoostGainProvider,
                  v,
                  (s) => s.setBassBoostGain(v),
                ),
              ),
            ),
            colors: colors,
          ),
          _SettingDivider(colors: colors),
          _SettingRow(
            icon: Icons.tune,
            title: '低音预设',
            subtitle: '选择低音增强预设',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.tr(bassPresetLabels[bassBoostPreset] ?? bassBoostPreset),
                  style: TextStyle(fontSize: 13, color: colors.textHint),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: colors.textHint),
              ],
            ),
            colors: colors,
            onTap: () => _showBottomPicker(
              context,
              colors,
              '低音预设',
              ['轻度', '中度', '重度'],
              bassPresetLabels[bassBoostPreset] ?? '中度',
              (v) {
                final map = {'轻度': 'light', '中度': 'medium', '重度': 'heavy'};
                final gainMap = {'light': 3.0, 'medium': 6.0, 'heavy': 9.0};
                _persistString(
                  context,
                  bassBoostPresetProvider,
                  map[v] ?? 'medium',
                  (s) => s.setBassBoostPreset(map[v] ?? 'medium'),
                );
                _persistDouble(
                  context,
                  bassBoostGainProvider,
                  gainMap[map[v]] ?? 6.0,
                  (s) => s.setBassBoostGain(gainMap[map[v]] ?? 6.0),
                );
              },
            ),
          ),
        ],
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.surround_sound,
          title: '环绕音效 (Surround)',
          subtitle: surroundEnabled
              ? surroundLabels[surroundMode] ?? surroundMode
              : '关闭',
          trailing: Switch(
            value: surroundEnabled,
            onChanged: (v) => _persistBool(
              context,
              surroundEnabledProvider,
              v,
              (s) => s.setSurroundEnabled(v),
            ),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        if (surroundEnabled) ...[
          _SettingDivider(colors: colors),
          _SettingRow(
            icon: Icons.surround_sound,
            title: '环境模拟',
            subtitle: '模拟 5.1/7.1 虚拟声场与环境混响',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.tr(surroundLabels[surroundMode] ?? surroundMode),
                  style: TextStyle(fontSize: 13, color: colors.textHint),
                ),
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 18, color: colors.textHint),
              ],
            ),
            colors: colors,
            onTap: () => _showBottomPicker(
              context,
              colors,
              '环绕模式',
              ['小房间', '中厅堂', '大教堂'],
              surroundLabels[surroundMode] ?? '小房间',
              (v) {
                final modeMap = {
                  '小房间': 'small',
                  '中厅堂': 'medium',
                  '大教堂': 'large',
                };
                _persistString(
                  context,
                  surroundModeProvider,
                  modeMap[v] ?? 'small',
                  (s) => s.setSurroundMode(modeMap[v] ?? 'small'),
                );
              },
            ),
          ),
        ],
        _SettingDivider(colors: colors),
        _SettingRow(
          icon: Icons.balance,
          title: '声道平衡 (Balance)',
          subtitle: balanceEnabled
              ? (balanceValue == 0
                    ? '居中'
                    : balanceValue < 0
                    ? '左 ${((-balanceValue) * 100).toInt()}%'
                    : '右 ${(balanceValue * 100).toInt()}%')
              : '关闭',
          trailing: Switch(
            value: balanceEnabled,
            onChanged: (v) => _persistBool(
              context,
              balanceEnabledProvider,
              v,
              (s) => s.setBalanceEnabled(v),
            ),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        if (balanceEnabled) ...[
          _SettingDivider(colors: colors),
          _SettingRow(
            icon: Icons.balance,
            title: '平衡调节',
            subtitle: balanceValue == 0
                ? '居中'
                : balanceValue < 0
                ? '左 ${((-balanceValue) * 100).toInt()}%'
                : '右 ${(balanceValue * 100).toInt()}%',
            trailing: SizedBox(
              width: 120,
              child: Slider(
                value: balanceValue,
                min: -1,
                max: 1,
                divisions: 40,
                activeColor: colors.primary,
                onChanged: (v) => _persistDouble(
                  context,
                  balanceValueProvider,
                  v,
                  (s) => s.setBalanceValue(v),
                ),
              ),
            ),
            colors: colors,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.volume_up,
                  size: 20,
                  color: colors.textSecondary.withValues(
                    alpha: 1 - balanceValue.clamp(0, 1),
                  ),
                ),
                const SizedBox(width: 24),
                Text(
                  '😐',
                  style: TextStyle(fontSize: 20, color: colors.textPrimary),
                ),
                const SizedBox(width: 24),
                Icon(
                  Icons.volume_up,
                  size: 20,
                  color: colors.textSecondary.withValues(
                    alpha: 1 + balanceValue.clamp(-1, 0),
                  ),
                ),
              ],
            ),
          ),
          Center(
            child: TextButton(
              onPressed: () => _persistDouble(
                context,
                balanceValueProvider,
                0.0,
                (s) => s.setBalanceValue(0.0),
              ),
              child: Text(
                context.tr('居中校准'),
                style: TextStyle(fontSize: 12, color: colors.primary),
              ),
            ),
          ),
          ],
        ],
      ],
    );
  }

  void _resetAudioEffects(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    container.read(bassBoostEnabledProvider.notifier).state = false;
    container.read(bassBoostGainProvider.notifier).state = 6.0;
    container.read(bassBoostPresetProvider.notifier).state = 'medium';
    container.read(surroundEnabledProvider.notifier).state = false;
    container.read(surroundModeProvider.notifier).state = 'small';
    container.read(balanceEnabledProvider.notifier).state = false;
    container.read(balanceValueProvider.notifier).state = 0.0;
    unawaited(
      _doPersist(container, (s) async {
        await s.setBassBoostEnabled(false);
        await s.setBassBoostGain(6.0);
        await s.setBassBoostPreset('medium');
        await s.setSurroundEnabled(false);
        await s.setSurroundMode('small');
        await s.setBalanceEnabled(false);
        await s.setBalanceValue(0.0);
      }),
    );
  }
}

// ==================== Storage ====================

class _StorageContent extends ConsumerWidget {
  const _StorageContent();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildCacheGroup(context, ref, colors),
        _buildDownloadGroup(context, ref, colors),
      ],
    );
  }

  /// 缓存目录：路径 + 选择 / 打开目录 + 最大缓存大小 + 清除缓存。
  Widget _buildCacheGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final cacheDir = ref.watch(cacheDirProvider);
    final cacheDirSize = ref.watch(cacheDirSizeProvider);
    final maxMb = ref.watch(maxCacheSizeMbProvider);
    final maxLabel = _formatCacheLimit(maxMb);

    return _SettingGroup(
      title: '缓存目录',
      subtitle: '用于存储歌曲缓存文件，提高播放速度',
      colors: colors,
      children: [
        _buildPathField(
          context,
          colors,
          path: cacheDir.isEmpty ? context.tr('未设置') : cacheDir,
          sizeAsync: cacheDirSize,
          badgeColor: colors.primary,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  try {
                    final result = await FilePicker.platform.getDirectoryPath();
                    if (result != null && context.mounted) {
                      final container = ProviderScope.containerOf(context);
                      container.read(cacheDirProvider.notifier).state = result;
                      // 让后续的封面 / 图片缓存真正写入新目录。
                      CachePaths.configure(result);
                      await AppImageCache.configure();
                      unawaited(CachePaths.enforceLimit());
                      container.invalidate(cacheDirSizeProvider);
                      unawaited(
                        _doPersist(container, (s) => s.setCacheDir(result)),
                      );
                    }
                  } catch (_) {}
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.primary,
                  side: BorderSide(color: colors.primary),
                ),
                child: Text(context.tr('选择目录')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _openDirectory(cacheDir),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  side: BorderSide(color: colors.divider),
                ),
                child: Text(context.tr('打开目录')),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: Text(
                context.tr('最大缓存大小'),
                style: TextStyle(fontSize: 14, color: colors.textPrimary),
              ),
            ),
            Text(
              maxLabel,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: colors.primary,
              ),
            ),
          ],
        ),
        Slider(
          value: maxMb.toDouble().clamp(100.0, 10240.0).toDouble(),
          min: 100,
          max: 10240,
          divisions: 101,
          activeColor: colors.primary,
          inactiveColor: colors.divider,
          onChanged: (v) {
            final mb = ((v / 100).round() * 100).clamp(100, 10240).toInt();
            final container = ProviderScope.containerOf(context);
            container.read(maxCacheSizeMbProvider.notifier).state = mb;
          },
          onChangeEnd: (v) {
            final mb = ((v / 100).round() * 100).clamp(100, 10240).toInt();
            CachePaths.maxBytes = mb * 1024 * 1024;
            unawaited(CachePaths.enforceLimit());
            _persistInt(
              context,
              maxCacheSizeMbProvider,
              mb,
              (s) => s.setMaxCacheSizeMb(mb),
            );
          },
        ),
        Text(
          context.tr('缓存超过上限时会自动清理最旧的缓存文件'),
          style: TextStyle(fontSize: 12, color: colors.textHint),
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => _showClearCacheDialog(context, colors),
            style: ElevatedButton.styleFrom(
              backgroundColor: colors.surface,
              foregroundColor: colors.textPrimary,
              side: BorderSide(color: colors.divider),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text(context.tr('清除本地缓存')),
          ),
        ),
      ],
    );
  }

  /// 下载目录：路径 + 选择 / 打开目录 + 重置为默认。
  Widget _buildDownloadGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final downloadDir = ref.watch(downloadDirProvider);
    final downloadDirSize = ref.watch(downloadDirSizeProvider);

    return _SettingGroup(
      title: '下载目录',
      subtitle: '用于存储下载的音乐文件',
      colors: colors,
      children: [
        _buildPathField(
          context,
          colors,
          path: downloadDir,
          sizeAsync: downloadDirSize,
          badgeColor: Colors.green,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () async {
                  try {
                    final result = await FilePicker.platform.getDirectoryPath();
                    if (result != null && context.mounted) {
                      final container = ProviderScope.containerOf(context);
                      container.read(downloadDirProvider.notifier).state =
                          result;
                      unawaited(
                        _doPersist(container, (s) => s.setDownloadDir(result)),
                      );
                    }
                  } catch (_) {}
                },
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.primary,
                  side: BorderSide(color: colors.primary),
                ),
                child: Text(context.tr('选择目录')),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton(
                onPressed: () => _openDirectory(downloadDir),
                style: OutlinedButton.styleFrom(
                  foregroundColor: colors.textSecondary,
                  side: BorderSide(color: colors.divider),
                ),
                child: Text(context.tr('打开目录')),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: () => _resetDirectories(context),
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.textSecondary,
              side: BorderSide(color: colors.divider),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text(context.tr('重置为默认')),
          ),
        ),
      ],
    );
  }

  /// 目录路径输入框（右侧显示目录占用大小）。
  Widget _buildPathField(
    BuildContext context,
    ThemeColors colors, {
    required String path,
    required AsyncValue<String> sizeAsync,
    required Color badgeColor,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.divider.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              path,
              style: TextStyle(fontSize: 13, color: colors.textPrimary),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: badgeColor.withValues(alpha: 0.3),
              ),
            ),
            child: sizeAsync.when(
              data: (s) => Text(
                s,
                style: TextStyle(fontSize: 11, color: badgeColor),
              ),
              loading: () => Text(
                '...',
                style: TextStyle(fontSize: 11, color: colors.textHint),
              ),
              error: (e, st) => Text(
                '0 B',
                style: TextStyle(fontSize: 11, color: colors.textHint),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openDirectory(String path) {
    if (path.isEmpty) return;
    try {
      Process.run('explorer', [path]);
    } catch (_) {}
  }

  void _resetDirectories(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors_surface(context).surface,
        title: Text(
          context.tr('重置目录设置'),
          style: TextStyle(color: text_primary(context)),
        ),
        content: Text(
          context.tr('确定要重置为默认目录吗？这将清除当前的自定义目录设置。'),
          style: TextStyle(color: text_secondary(context)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: text_hint(context)),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              final container = ProviderScope.containerOf(context);
              final defaultDownload = await defaultDownloadDir();
              // 默认缓存目录使用应用缓存目录，不再指向系统临时目录。
              final appCacheDir = await AppPaths.cacheRootDirectory();
              container.read(downloadDirProvider.notifier).state =
                  defaultDownload;
              container.read(cacheDirProvider.notifier).state =
                  appCacheDir.path;
              CachePaths.configure(appCacheDir.path);
              await AppImageCache.configure();
              container.invalidate(cacheDirSizeProvider);
              unawaited(
                _doPersist(container, (s) async {
                  await s.setDownloadDir(defaultDownload);
                  await s.setCacheDir(appCacheDir.path);
                }),
              );
              if (context.mounted)
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.tr('已重置为默认目录')),
                    backgroundColor: Theme.of(context).primaryColor,
                  ),
                );
            },
            child: Text(
              context.tr('确定重置'),
              style: TextStyle(color: Theme.of(context).primaryColor),
            ),
          ),
        ],
      ),
    );
  }

  ThemeColors colors_surface(BuildContext context) => ref_watch_colors(context);
  Color text_primary(BuildContext context) =>
      ref_watch_colors(context).textPrimary;
  Color text_secondary(BuildContext context) =>
      ref_watch_colors(context).textSecondary;
  Color text_hint(BuildContext context) => ref_watch_colors(context).textHint;
  ThemeColors ref_watch_colors(BuildContext context) =>
      ProviderScope.containerOf(context).read(themeColorsProvider);

  String _formatCacheLimit(int mb) {
    if (mb >= 1024) {
      final gb = mb / 1024;
      final text = gb == gb.roundToDouble()
          ? gb.toStringAsFixed(0)
          : gb.toStringAsFixed(1);
      return '$text GB';
    }
    return '$mb MB';
  }

  void _showClearCacheDialog(BuildContext context, ThemeColors colors) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('清除缓存'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定要清除所有缓存吗？已缓存的封面等临时文件会被删除。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _clearCache(context);
            },
            child: Text(
              context.tr('确定'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
  }

  void _clearCache(BuildContext context) async {
    try {
      final container = ProviderScope.containerOf(context);
      final svc = await container.read(settingsServiceProvider.future);
      await svc.clearCache();
      container.read(cacheSizeProvider.notifier).state = '0 MB';
      container.invalidate(cacheDirSizeProvider);
      container.invalidate(downloadDirSizeProvider);
    } catch (_) {}
  }
}
