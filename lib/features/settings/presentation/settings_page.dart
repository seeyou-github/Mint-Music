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
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/app_font_manager.dart';
import '../../../core/theme/app_typography.dart';
import '../../../core/theme/background_gradient.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import 'backup_restore_content.dart';
import '../../blacklist/presentation/blacklist_settings_content.dart';
import '../../../shared/services/app_image_cache.dart';
import '../../../shared/services/cache_paths.dart';
import '../../../shared/widgets/hsv_color_picker.dart';
import '../application/font_providers.dart';
import '../application/settings_providers.dart';
import 'background_editor_page.dart';
import '../data/settings_service.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../player/application/desktop_lyric_controller.dart';
import '../../player/application/desktop_lyric_sync.dart';
import '../../player/domain/models/desktop_lyric_settings.dart';

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

/// 旧版「导出配置」只带均衡器四项（enabled / currentPreset / gains /
/// customPresets），这里把它们映射成 `settings.json` 里的键名。
///
/// 新版导出的文件里直接就是这些键（外加低音 / 环绕 / 平衡 / 音效总开关），
/// 这条路径只用于兼容旧文件。
Map<String, dynamic> _legacyEqConfigToSettings(Map<String, dynamic> data) {
  final settings = <String, dynamic>{};
  final enabled = data['enabled'];
  if (enabled is bool) settings['equalizer_enabled'] = enabled;
  final preset = data['currentPreset'];
  if (preset is String) settings['eq_preset'] = preset;
  final gains = data['gains'];
  if (gains is List) {
    settings['eq_bands'] = jsonEncode([
      for (final value in gains)
        if (value is num) value.toDouble(),
    ]);
  }
  final customPresets = data['customPresets'];
  if (customPresets is List) {
    settings['eq_custom_presets'] = jsonEncode(customPresets);
  }
  return settings;
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
  playback,
  storage,
  blacklist,
  backupRestore,
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});

  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage>
    with SingleTickerProviderStateMixin {
  SettingsCategory _activeCategory = SettingsCategory.appearance;

  // ------------------------------------------------------------ 左右滑动切换分类
  //
  // Android 上跟主页（发现页）/ 本地页同一套「双页跟手」：拖动时把整块内容
  // 连同「下一屏」一起平移，只做一层 Transform（GPU 变换），不重建滚动视图
  // 之外的东西；松手后要么滑到位切换分类，要么回弹。

  /// 手指位移达到这么多屏宽就算一次切换（不够再看甩动速度）。
  static const double _kCategorySwitchDragRatio = 0.18;

  /// 内容当前的横向位移（像素）。
  final ValueNotifier<double> _categoryOffsetX = ValueNotifier<double>(0);

  /// 拖动过程中显示在「下一屏」的分类。
  ///
  /// [_dragTargetCategoryActive] 为 false 表示没在拖动，或者已经滑到第一个 /
  /// 最后一个分类（越界只能回弹）。
  bool _dragTargetCategoryActive = false;
  SettingsCategory? _dragTargetCategory;
  int _dragDir = 0;

  /// 位移动画驱动（时长每次按需设置）。
  late final AnimationController _categoryAnim = AnimationController(
    vsync: this,
  );

  /// 当前正在跑的位移动画；为 null 表示没有动画在跑。
  Animation<double>? _categoryTween;

  /// 本次拖动累计的横向位移。
  double _categorySwipeDx = 0;

  void _onCategoryTick() {
    final animation = _categoryTween;
    if (animation != null) _categoryOffsetX.value = animation.value;
  }

  /// 把内容位移动画到 [to]（像素）。
  Future<void> _animateCategoryOffset(double to, int milliseconds) {
    final from = _categoryOffsetX.value;
    _categoryAnim.stop();
    if (from == to) {
      _categoryTween = null;
      return Future<void>.value();
    }
    _categoryAnim.duration = Duration(milliseconds: milliseconds);
    _categoryTween = Tween<double>(begin: from, end: to).animate(
      CurvedAnimation(parent: _categoryAnim, curve: Curves.easeOutCubic),
    );
    return _categoryAnim.forward(from: 0).then((_) {
      _categoryTween = null;
      _categoryOffsetX.value = to;
    });
  }

  /// 手指位移 → 内容位移（1:1 跟手，最多一屏）。
  ///
  /// 必须与手指严格同步：下一屏是按「当前位移 ± 整屏宽」算位置的，一旦做加速
  /// 两页之间就会露出缝。分类是有限序列（不循环），第一个还往右拖、最后一个
  /// 还往左拖时直接不动，避免拖出一片空白。
  double _categoryContentOffset(double dx) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return dx;
    final clamped = dx.clamp(-width, width).toDouble();
    final dir = clamped < 0 ? 1 : (clamped > 0 ? -1 : 0);
    if (dir != 0) {
      final values = SettingsCategory.values;
      final index = values.indexOf(_activeCategory);
      final target = index < 0 ? -1 : index + dir;
      if (target < 0 || target >= values.length) return 0;
    }
    return clamped;
  }

  void _onCategorySwipeStart(DragStartDetails details) {
    _categoryAnim.stop();
    _categoryTween = null;
    _categorySwipeDx = 0;
    _categoryOffsetX.value = 0;
    if (_dragTargetCategoryActive || _dragDir != 0) {
      setState(() {
        _dragTargetCategoryActive = false;
        _dragTargetCategory = null;
        _dragDir = 0;
      });
    }
  }

  void _onCategorySwipeUpdate(DragUpdateDetails details) {
    _categorySwipeDx += details.delta.dx;
    final offset = _categoryContentOffset(_categorySwipeDx);
    _categoryOffsetX.value = offset;
    _syncCategoryDragTarget(offset);
  }

  /// 根据当前位移确定「下一屏」是哪个分类（到头 / 到第一个就没有下一屏）。
  ///
  /// 只在方向或目标变化时 `setState` 一次，拖动过程中不反复重建内容。
  void _syncCategoryDragTarget(double offset) {
    final dir = offset < 0 ? 1 : (offset > 0 ? -1 : 0);
    final values = SettingsCategory.values;
    final index = values.indexOf(_activeCategory);
    var active = false;
    SettingsCategory? target;
    if (dir != 0 && index >= 0) {
      final next = index + dir;
      if (next >= 0 && next < values.length) {
        active = true;
        target = values[next];
      }
    }
    if (active == _dragTargetCategoryActive &&
        target == _dragTargetCategory &&
        dir == _dragDir) {
      return;
    }
    setState(() {
      _dragTargetCategoryActive = active;
      _dragTargetCategory = target;
      _dragDir = dir;
    });
  }

  /// 左右滑动结束：位移够就翻页，不够看甩动速度；都不够就弹回原位。
  void _onCategorySwipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final dx = _categorySwipeDx;
    _categorySwipeDx = 0;
    final width = MediaQuery.sizeOf(context).width;
    final bool swipeLeft;
    if (dx.abs() >= width * _kCategorySwitchDragRatio) {
      swipeLeft = dx < 0;
    } else if (velocity.abs() >= 260) {
      swipeLeft = velocity < 0;
    } else {
      unawaited(_settleCategoryDrag(-1, 0));
      return;
    }
    final values = SettingsCategory.values;
    final index = values.indexOf(_activeCategory);
    final next = index < 0 ? -1 : index + (swipeLeft ? 1 : -1);
    if (next < 0 || next >= values.length) {
      // 已经是第一个 / 最后一个分类：没有可切换的，弹回原位。
      unawaited(_settleCategoryDrag(-1, 0));
      return;
    }
    unawaited(_settleCategoryDrag(next, swipeLeft ? 1 : -1));
  }

  /// 收尾：两页一起滑到位后切换分类，或者回弹。
  ///
  /// [target] 是目标分类的下标，-1 表示没有可切换的目标。切换时传
  /// `animate: false`——位移已经自己走完，再插一次「从侧边 28% 进场」会闪。
  Future<void> _settleCategoryDrag(int target, int dir) async {
    final width = MediaQuery.sizeOf(context).width;
    final values = SettingsCategory.values;
    if (target >= 0 && target < values.length) {
      await _animateCategoryOffset(dir > 0 ? -width : width, 220);
      if (!mounted) return;
      _selectCategory(values[target], animate: false);
      _categoryOffsetX.value = 0;
      return;
    }
    await _animateCategoryOffset(0, 200);
    if (!mounted) return;
    if (_dragTargetCategoryActive || _dragDir != 0) {
      setState(() {
        _dragTargetCategoryActive = false;
        _dragTargetCategory = null;
        _dragDir = 0;
      });
    }
  }

  /// 切换分类（点顶部标签，或左右滑动收尾）。
  ///
  /// [animate] 为 true 时新分类从切换方向的另一侧 28% 屏宽处滑入；
  /// 左右滑动切换传 false —— 两页已经跟着手指一起平移到位了。
  void _selectCategory(SettingsCategory cat, {bool animate = true}) {
    if (_activeCategory == cat) return;
    final values = SettingsCategory.values;
    final from = values.indexOf(_activeCategory);
    final to = values.indexOf(cat);
    if (animate && Platform.isAndroid && from >= 0 && to >= 0 && from != to) {
      final width = MediaQuery.sizeOf(context).width;
      _categoryOffsetX.value = to > from ? width * 0.28 : -width * 0.28;
      unawaited(_animateCategoryOffset(0, 200));
    }
    setState(() {
      _activeCategory = cat;
      // 切换完成后收掉「下一屏」的预览。
      _dragTargetCategoryActive = false;
      _dragTargetCategory = null;
      _dragDir = 0;
    });
    _scrollToActiveTab();
  }

  /// 水平滚动控制器：用于点击标签时将选中项自动居中
  final ScrollController _tabScrollController = ScrollController();

  /// 每个标签按钮的 GlobalKey，用于测量位置
  final List<GlobalKey> _tabKeys = List.generate(
    SettingsCategory.values.length,
    (_) => GlobalKey(),
  );

  static const _categoryConfig = {
    SettingsCategory.appearance: (icon: Icons.palette, label: '外观设置'),
    SettingsCategory.playback: (icon: Icons.play_circle, label: '播放设置'),
    SettingsCategory.storage: (icon: Icons.storage, label: '缓存设置'),
    SettingsCategory.blacklist: (icon: Icons.block, label: '黑名单设置'),
    SettingsCategory.backupRestore: (
      icon: Icons.backup_outlined,
      label: '备份还原',
    ),
  };

  @override
  void initState() {
    super.initState();
    _categoryAnim.addListener(_onCategoryTick);
  }

  @override
  void dispose() {
    _tabScrollController.dispose();
    _categoryAnim.dispose();
    _categoryOffsetX.dispose();
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
      final viewportWidth = _tabScrollController.position.viewportDimension;
      final currentScroll = _tabScrollController.offset;

      // 计算需要滚动的距离，使按钮居中
      final targetOffset = currentScroll + buttonCenter - viewportWidth / 2;
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
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(colors),
            _buildCategoryTabs(colors),
            Expanded(
              child: GestureDetector(
                // Android：左右滑动切换分类。纵向滚动、横向的分类标签行都是
                // 更深的手势识别器，会自己赢下手势，不受影响。
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: Platform.isAndroid
                    ? _onCategorySwipeStart
                    : null,
                onHorizontalDragUpdate: Platform.isAndroid
                    ? _onCategorySwipeUpdate
                    : null,
                onHorizontalDragEnd: Platform.isAndroid
                    ? _onCategorySwipeEnd
                    : null,
                child: ClipRect(
                  // 两页一起平移：当前页从 0 滑到 ±整屏时，另一个分类从另一侧
                  // 同步滑进来，拖动过程中就能看到对面的内容（同 PageView）。
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (_dragTargetCategoryActive &&
                          _dragDir != 0 &&
                          _dragTargetCategory != null)
                        AnimatedBuilder(
                          animation: _categoryOffsetX,
                          builder: (context, child) => Transform.translate(
                            offset: Offset(
                              _categoryOffsetX.value +
                                  _dragDir * MediaQuery.sizeOf(context).width,
                              0,
                            ),
                            child: child,
                          ),
                          // 下一屏只是预览：用独立的滚动位置，
                          // 两个滚动视图不能同时挂到 PrimaryScrollController。
                          child: _buildContentPage(
                            colors,
                            _dragTargetCategory!,
                            primary: false,
                          ),
                        ),
                      AnimatedBuilder(
                        animation: _categoryOffsetX,
                        builder: (context, child) => Transform.translate(
                          offset: Offset(_categoryOffsetX.value, 0),
                          child: child,
                        ),
                        child: _buildContentPage(
                          colors,
                          _activeCategory,
                          primary: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
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
          // Android 靠系统返回手势 / 返回键，顶部不放返回箭头。
          if (!Platform.isAndroid && context.canPop()) ...[
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
                    onTap: () => _selectCategory(cat),
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

  /// 构建某个分类的整页内容。
  ///
  /// 只构建当前分类（外加拖动时露出的下一屏），不会把五个分类的重型
  /// provider（插件、目录扫描等）全都在首帧拉起来。
  ///
  /// [primary] 为当前分类：它可以走 `PrimaryScrollController`；拖动中露出的
  /// 下一屏传 false，两页才不会抢同一个 controller 报错。
  Widget _buildContentPage(
    ThemeColors colors,
    SettingsCategory cat, {
    required bool primary,
  }) {
    return SingleChildScrollView(
      primary: primary ? null : false,
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.md,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.xxxl,
      ),
      child: _buildContentForCategory(cat),
    );
  }

  Widget _buildContentForCategory(SettingsCategory cat) {
    switch (cat) {
      case SettingsCategory.appearance:
        return const _AppearanceContent();
      case SettingsCategory.playback:
        return const _PlaybackContent();
      case SettingsCategory.storage:
        return const _StorageContent();
      case SettingsCategory.blacklist:
        return const BlacklistSettingsContent();
      case SettingsCategory.backupRestore:
        return const BackupRestoreContent();
    }
  }
}

class SettingGroup extends StatelessWidget {
  final String title;
  final String? subtitle;
  final ThemeColors colors;
  final List<Widget> children;
  const SettingGroup({
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
      decoration: floatingSurfaceDecoration(colors, radius: 12),
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
              // 说明文字统一用第二字体颜色（外观设置里可调），
              // textHint 在浅色主题下太淡、几乎看不清。
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          ...children,
        ],
      ),
    );
  }
}

class SettingRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget trailing;
  final ThemeColors colors;
  final VoidCallback? onTap;
  const SettingRow({
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
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
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

class SettingDivider extends StatelessWidget {
  final ThemeColors colors;
  const SettingDivider({required this.colors});
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
    useRootNavigator: true,
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

/// 渐变预览用：先滤掉末尾的 `@n` 方向标记，再解析颜色。
List<Color> _gradientPreviewColors(List<String> tokens) =>
    gradientColorTokens(tokens).map(_parseHexColor).toList(growable: false);

/// 渐变预览用：`@n` 标记 → 具体方向（random 按颜色解析）。
GradientDirection _gradientPreviewDirection(
  List<String> tokens,
  List<Color> colors,
) {
  final direction = gradientDirectionFromTokens(tokens);
  return direction == GradientDirection.random
      ? randomDirectionFor(colors)
      : direction;
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

/// 浅色模式「背景渐变」的内置组合（颜色列表 + 名称）。
///
/// 第一项就是默认选中的那一套（见 [defaultLightBackgroundGradient]），
/// 必须保持一致；其余是常用的浅色三段组合。
const List<(List<String>, String)> _lightGradientPresets = [
  (['#B6B6B6', '#A7A7A7', '#979797'], '中灰'),
  (['#C7C3BC', '#B5B0A7', '#A39D92'], '暖灰'),
  (['#CDD1C4', '#BFC5B4', '#B1B9A4'], '浅绿'),
  (['#C4CDD4', '#AFBCC5', '#9AABB6'], '雾蓝'),
  (['#CECBDC', '#B9B5CE', '#A49FC0'], '淡紫'),
  (['#C5B5CE', '#B39DBF', '#A185B0'], '藕紫'),
];

/// 深色模式「背景渐变」的内置组合（颜色列表 + 名称）。
///
/// 同样第一项是默认值（[defaultDarkBackgroundGradient]）。
const List<(List<String>, String)> _darkGradientPresets = [
  (['#2F2F36', '#1D1D21', '#0B0B0C'], '深空灰'),
  (['#373737', '#242424', '#111111'], '中性灰'),
  (['#343939', '#222525', '#101111'], '青灰'),
  (['#3F4349', '#2C2F33', '#191B1D'], '蓝灰'),
  (['#4A4854', '#34333B', '#1E1E22'], '紫灰'),
  (['#3F4550', '#30343D', '#21242A'], '深蓝'),
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
              ? [BoxShadow(color: color.withValues(alpha: 0.4), blurRadius: 8)]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 24)
            : null,
      ),
    );
  }
}

/// 一个个渐变色卡：圆形/圆角预览 + 名称，选中时描边用主题色。
///
/// 内置渐变都是 3 个颜色、没有方向标记（按「上下」画）；用户自定义的渐变
/// 同样 3 个颜色，末尾多一个 `@n` 方向标记，按保存的方向画。
class _GradientSwatch extends StatelessWidget {
  const _GradientSwatch({
    required this.colors,
    required this.width,
    required this.hexes,
    required this.label,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final ThemeColors colors;

  /// 色卡宽度：由调用方按「一行 6 个」算出来，窄屏 / 平板都不换行。
  final double width;
  final List<String> hexes;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final preview = _gradientPreviewColors(hexes);
    final direction = _gradientPreviewDirection(hexes, preview);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: width,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: selected ? colors.primary : colors.divider,
                width: selected ? 2 : 0.5,
              ),
              gradient: LinearGradient(
                begin: direction.begin,
                end: direction.end,
                colors: preview.length == 1
                    ? [preview.first, preview.first]
                    : preview,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: selected ? colors.primary : colors.textHint,
            ),
          ),
        ],
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
        // 桌面歌词的设置放在外观设置的最底部。
        _buildDesktopLyricGroup(context, ref, colors),
      ],
    );
  }

  Widget _buildThemeGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final themeMode = ref.watch(themeModeProvider);
    final themeName = _themeModeLabel(themeMode);
    final primaryHex = ref.watch(themePrimaryColorProvider);

    // 字体颜色 / 第二字体颜色 / 背景颜色都按浅色、深色各保存一套；
    // 界面只显示当前实际生效模式的那一套，跟随系统时随亮暗自动切换。
    final isLight = ref.watch(isLightThemeActiveProvider);
    final modeLabel = isLight ? '浅色模式' : '深色模式';

    Widget buildColorRow({
      required IconData icon,
      required String title,
      required Color emptyColor,
      required String resetValue,
      required StateProvider<String> currentProvider,
      required StateProvider<List<String>> customProvider,
      required Future<void> Function(SettingsService svc, String hex)
      persistCurrent,
      required Future<void> Function(SettingsService svc, List<String> colors)
      persistCustom,
      List<(String, String)> presets = _presetColors,
    }) {
      final hex = ref.watch(currentProvider);
      return SettingRow(
        icon: icon,
        title: title,
        trailing: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: hex.isEmpty ? emptyColor : _parseHexColor(hex),
            border: Border.all(color: colors.divider, width: 1.5),
          ),
        ),
        colors: colors,
        onTap: () => _showPalettePicker(
          context,
          colors,
          title: '选择$title',
          currentProvider: currentProvider,
          customProvider: customProvider,
          persistCurrent: persistCurrent,
          persistCustom: persistCustom,
          showReset: true,
          emptyInitialColor: emptyColor,
          resetValue: resetValue,
          presets: presets,
        ),
      );
    }

    // 「主界面跟随封面变色」开关（仅深色主题）。
    final coverBackground = ref.watch(coverBackgroundEnabledProvider);

    /// 背景渐变行：右侧是当前渐变的预览条，点开可以配置 1~3 个颜色。
    Widget buildBackgroundGradientRow() {
      final hexes = ref.watch(
        isLight
            ? lightThemeBackgroundColorsProvider
            : darkThemeBackgroundColorsProvider,
      );
      final preview = hexes.isEmpty
          ? <Color>[
              isLight
                  ? ThemeColors.light.background
                  : ThemeColors.dark.background,
            ]
          : _gradientPreviewColors(hexes);
      final direction = _gradientPreviewDirection(hexes, preview);
      return SettingRow(
        icon: Icons.gradient,
        title: '背景渐变（$modeLabel）',
        trailing: Container(
          width: 44,
          height: 26,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: colors.divider, width: 1),
            gradient: LinearGradient(
              begin: direction.begin,
              end: direction.end,
              colors: preview.length == 1 ? [preview[0], preview[0]] : preview,
            ),
          ),
        ),
        colors: colors,
        onTap: () =>
            _showBackgroundGradientPicker(context, colors, isLight: isLight),
      );
    }

    // 选中的应用字体（右侧显示名称）
    final selectedFont = ref.watch(appFontSelectedProvider);
    final fontName = _appFontDisplayName(selectedFont);
    return SettingGroup(
      title: '基础外观',
      colors: colors,
      children: [
        SettingRow(
          icon: Icons.palette,
          title: '应用主题',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(themeName),
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
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
        SettingDivider(colors: colors),
        SettingRow(
          icon: Icons.color_lens,
          title: '主题色',
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
        SettingDivider(colors: colors),
        buildBackgroundGradientRow(),
        SettingDivider(colors: colors),
        // 仅深色主题生效：浅色主题下背景必须够亮，跟封面色会看不清文字。
        SettingRow(
          icon: Icons.auto_awesome,
          title: '主界面跟随封面变色',
          trailing: Switch(
            // 浅色主题下这个开关不生效：直接禁用（自动灰掉），也不显示为开启。
            value: isLight ? false : coverBackground,
            onChanged: isLight
                ? null
                : (v) => _persistBool(
                    context,
                    coverBackgroundEnabledProvider,
                    v,
                    (s) => s.setCoverBackground(v),
                  ),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        SettingDivider(colors: colors),
        buildColorRow(
          icon: Icons.text_fields,
          title: '字体颜色（$modeLabel）',
          emptyColor: isLight
              ? ThemeColors.light.textPrimary
              : ThemeColors.dark.textPrimary,
          resetValue: isLight ? defaultLightFontColor : defaultThemeFontColor,
          currentProvider: isLight
              ? lightThemeFontColorProvider
              : darkThemeFontColorProvider,
          customProvider: isLight
              ? customFontColorsLightProvider
              : customFontColorsDarkProvider,
          persistCurrent: (s, hex) => isLight
              ? s.setThemeFontColorLight(hex)
              : s.setThemeFontColorDark(hex),
          persistCustom: (s, list) => isLight
              ? s.setCustomFontColorsLight(list)
              : s.setCustomFontColorsDark(list),
        ),
        SettingDivider(colors: colors),
        buildColorRow(
          icon: Icons.text_fields_outlined,
          title: '第二字体颜色（$modeLabel）',
          emptyColor: isLight
              ? ThemeColors.light.textSecondary
              : ThemeColors.dark.textSecondary,
          resetValue: isLight ? defaultLightSecondaryFontColor : '',
          currentProvider: isLight
              ? lightThemeSecondaryFontColorProvider
              : darkThemeSecondaryFontColorProvider,
          customProvider: isLight
              ? customSecondaryFontColorsLightProvider
              : customSecondaryFontColorsDarkProvider,
          persistCurrent: (s, hex) => isLight
              ? s.setThemeSecondaryFontColorLight(hex)
              : s.setThemeSecondaryFontColorDark(hex),
          persistCustom: (s, list) => isLight
              ? s.setCustomSecondaryFontColorsLight(list)
              : s.setCustomSecondaryFontColorsDark(list),
        ),
        SettingDivider(colors: colors),
        SettingRow(
          icon: Icons.font_download_outlined,
          title: '应用字体',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                context.tr(fontName),
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
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

  /// 背景渐变设置面板。
  ///
  /// 内置渐变排在最前——第一个就是软件默认背景；用户「新增颜色」保存的自定义
  /// 渐变紧跟在所有内置之后，长按可以编辑或删除。点任意一个渐变立即生效。
  void _showBackgroundGradientPicker(
    BuildContext context,
    ThemeColors colors, {
    required bool isLight,
  }) {
    final container = ProviderScope.containerOf(context);
    final provider = isLight
        ? lightThemeBackgroundColorsProvider
        : darkThemeBackgroundColorsProvider;
    final customProvider = isLight
        ? customBackgroundGradientsLightProvider
        : customBackgroundGradientsDarkProvider;
    final presets = isLight ? _lightGradientPresets : _darkGradientPresets;

    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      sheetAnimationStyle: _settingsSheetAnimationStyle,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => Consumer(
        builder: (_, ref, __) {
          final picked = ref.watch(provider);
          final customs = ref.watch(customProvider);

          /// 当前生效的渐变是否就是 [gradient]。
          bool isPicked(List<String> gradient) {
            if (picked.length != gradient.length) return false;
            for (var i = 0; i < gradient.length; i++) {
              if (picked[i].toUpperCase() != gradient[i].toUpperCase()) {
                return false;
              }
            }
            return true;
          }

          void apply(List<String> gradient) {
            ref.read(provider.notifier).state = gradient;
            unawaited(
              _doPersist(
                container,
                (s) => isLight
                    ? s.setThemeBackgroundColorsLight(gradient)
                    : s.setThemeBackgroundColorsDark(gradient),
              ),
            );
            Navigator.pop(sheetContext);
          }

          void removeCustom(int index, List<List<String>> from) {
            final next = List<List<String>>.from(from)..removeAt(index);
            ref.read(customProvider.notifier).state = next;
            unawaited(
              _doPersist(
                container,
                (s) => isLight
                    ? s.setCustomBackgroundGradientsLight(next)
                    : s.setCustomBackgroundGradientsDark(next),
              ),
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
                      sheetContext.tr('背景渐变'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    Text(
                      sheetContext.tr('内置渐变'),
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    // 一行放 6 个（内置渐变正好 6 个），宽度按可用宽度算，
                    // 窄屏也不会挤成两行。
                    LayoutBuilder(
                      builder: (context, constraints) {
                        const gap = 8.0;
                        final width = ((constraints.maxWidth - gap * 5) / 6)
                            .clamp(46.0, 72.0);
                        return Wrap(
                          spacing: gap,
                          runSpacing: 12,
                          children: [
                            for (final preset in presets)
                              _GradientSwatch(
                                colors: colors,
                                width: width,
                                hexes: preset.$1,
                                label: sheetContext.tr(preset.$2),
                                selected: isPicked(preset.$1),
                                onTap: () => apply(preset.$1),
                              ),
                            // 自定义渐变排在内置渐变之后。
                            for (var i = 0; i < customs.length; i++)
                              _GradientSwatch(
                                colors: colors,
                                width: width,
                                hexes: customs[i],
                                label: sheetContext.tr('自定义'),
                                selected: isPicked(customs[i]),
                                onTap: () => apply(customs[i]),
                                onLongPress: () => _showCustomGradientActions(
                                  sheetContext,
                                  colors,
                                  customs[i],
                                  onEdit: () => _openBackgroundEditor(
                                    context,
                                    isLight: isLight,
                                    editing: customs[i],
                                    editingIndex: i,
                                  ),
                                  onDelete: () => removeCustom(i, customs),
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                    if (customs.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        sheetContext.tr('长按自定义颜色可编辑或删除'),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    OutlinedButton.icon(
                      onPressed: () =>
                          _openBackgroundEditor(context, isLight: isLight),
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

  /// 打开全屏的背景编辑页（新增 / 编辑自定义渐变）。
  ///
  /// 全屏而不是弹窗：要放下「实时预览 + 色板 + 两个滑条」。先把这层「背景
  /// 渐变」面板收掉，保存后回到设置页，列表里已经能看到新渐变。
  void _openBackgroundEditor(
    BuildContext context, {
    required bool isLight,
    List<String>? editing,
    int? editingIndex,
  }) {
    final navigator = Navigator.of(context, rootNavigator: true);
    navigator.pop();
    unawaited(
      navigator.push<bool>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => BackgroundEditorPage(
            isLight: isLight,
            editing: editing,
            editingIndex: editingIndex,
          ),
        ),
      ),
    );
  }

  /// 长按自定义渐变：编辑 / 删除。
  void _showCustomGradientActions(
    BuildContext context,
    ThemeColors colors,
    List<String> gradient, {
    required VoidCallback onEdit,
    required VoidCallback onDelete,
  }) {
    final preview = _gradientPreviewColors(gradient);
    final direction = _gradientPreviewDirection(gradient, preview);
    showModalBottomSheet<void>(
      useRootNavigator: true,
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
                    width: 44,
                    height: 26,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: colors.divider, width: 1),
                      gradient: LinearGradient(
                        begin: direction.begin,
                        end: direction.end,
                        colors: preview,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    actionContext.tr('自定义渐变'),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            SettingDivider(colors: colors),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: colors.textSecondary),
              title: Text(
                actionContext.tr('编辑渐变'),
                style: TextStyle(color: colors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(actionContext);
                onEdit();
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colors.textSecondary),
              title: Text(
                actionContext.tr('删除渐变'),
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

  /// 主题色 / 字体颜色 / 第二字体颜色 / 背景颜色的通用选择面板。
  ///
  /// 内置颜色与用户新增的自定义颜色一起显示；长按自定义颜色可以编辑或删除。
  /// [showReset] 为 true 时第一个圆圈表示恢复主题默认色（字体颜色 / 背景颜色用）。
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

    /// 「恢复默认」时写入的值（为空表示恢复主题默认色）。
    String resetValue = '',

    /// 面板里展示的内置颜色，默认是主题色 / 文字颜色用的高饱和色。
    List<(String, String)> presets = _presetColors,
  }) {
    final container = ProviderScope.containerOf(context);
    showModalBottomSheet<void>(
      useRootNavigator: true,
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
          final allColors = _mergeColors(presets, custom);
          // 「恢复默认」写入的是显式默认色，因此不能只看 empty。
          final resetUpper = resetValue.toUpperCase();
          final resetSelected = resetUpper.isEmpty
              ? currentHex.isEmpty
              : currentHex.toUpperCase() == resetUpper;

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
              resetValue: resetValue,
              presets: presets,
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
                            onTap: () => apply(resetValue),
                            child: Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: colors.surfaceVariant,
                                border: resetSelected
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
                            // 默认色由「恢复默认」圆圈表示，色点不重复勾选。
                            selected:
                                item.$1.toUpperCase() ==
                                    currentHex.toUpperCase() &&
                                !(resetSelected &&
                                    resetUpper.isNotEmpty &&
                                    item.$1.toUpperCase() == resetUpper),
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
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                    ],
                    if (custom.isNotEmpty) ...[
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        sheetContext.tr('长按自定义颜色可编辑或删除'),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
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
      useRootNavigator: true,
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
            SettingDivider(colors: colors),
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
              leading: Icon(Icons.delete_outline, color: colors.textSecondary),
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
      useRootNavigator: true,
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

  /// 应用字体的展示名（内置字体显示中文名，导入的字体显示族名）。
  static String _appFontDisplayName(String? family) {
    if (family == null || family.isEmpty) {
      // 没有选择过 = 用默认字体（内置的思源宋体）。
      return AppFontManager.bundledFonts
          .firstWhere(
            (f) => f.family == AppTypography.defaultFontFamily,
            orElse: () => AppFontManager.bundledFonts.first,
          )
          .label;
    }
    for (final font in AppFontManager.bundledFonts) {
      if (font.family == family) return font.label;
    }
    if (family == AppFontManager.systemFontFamily) return '系统默认字体';
    return family;
  }

  /// 应用字体：导入字体文件（可多选）并选择其中之一。
  Future<void> _showAppFontSheet(
    BuildContext context,
    ThemeColors colors,
  ) async {
    await showModalBottomSheet(
      useRootNavigator: true,
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
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    // 内置字体（随安装包提供，无需导入）
                    ...AppFontManager.bundledFonts.map((font) {
                      final isDefaultFont =
                          font.family == AppTypography.defaultFontFamily;
                      return _buildFontOption(
                        sheetContext,
                        colors,
                        title: context.tr(font.label),
                        subtitle: isDefaultFont
                            ? context.tr('内置字体（默认）')
                            : context.tr('内置字体'),
                        isSelected:
                            (selected == null && isDefaultFont) ||
                            selected == font.family,
                        onTap: () async {
                          await notifier.select(font.family);
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                      );
                    }),
                    // 系统默认字体（未注册到引擎，用平台默认字体渲染）
                    _buildFontOption(
                      sheetContext,
                      colors,
                      title: context.tr('系统默认字体'),
                      subtitle: context.tr('使用系统字体'),
                      isSelected: selected == AppFontManager.systemFontFamily,
                      onTap: () async {
                        await notifier.select(AppFontManager.systemFontFamily);
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
                            allowedExtensions:
                                AppFontManager.supportedExtensions,
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
                            _showSettingsMessage(sheetContext, '没有可导入的字体文件');
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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(context.tr(message))));
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
        style: TextStyle(fontSize: 11, color: colors.textSecondary),
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

  Widget _buildDesktopLyricGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final s = ref.watch(desktopLyricSettingsProvider);

    void update(DesktopLyricSettings Function(DesktopLyricSettings) fn) =>
        updateDesktopLyricSettings(ref.read, fn);

    return SettingGroup(
      title: '桌面歌词',
      colors: colors,
      children: [
        _SettingSlider(
          icon: Icons.format_size,
          title: '字体大小',
          value: s.fontSize,
          min: 12,
          max: 80,
          divisions: 34,
          valueLabel: '${s.fontSize.round()}',
          colors: colors,
          onChanged: (v) => update((cur) => cur.copyWith(fontSize: v)),
        ),
        SettingDivider(colors: colors),
        SettingRow(
          icon: Icons.colorize,
          title: '已播放颜色',
          trailing: _colorSwatch(s.playedColor, colors),
          colors: colors,
          onTap: () => _showDesktopLyricColorPicker(
            context,
            colors,
            '已播放颜色',
            _lyricColorPresets,
            s.playedColor,
            (v) => update((cur) => cur.copyWith(playedColor: v)),
            customHex: s.customColors,
            onCustomChanged: (list) =>
                update((cur) => cur.copyWith(customColors: list)),
          ),
        ),
        SettingDivider(colors: colors),
        SettingRow(
          icon: Icons.text_fields,
          title: '未播放颜色',
          trailing: _colorSwatch(s.unplayColor, colors),
          colors: colors,
          onTap: () => _showDesktopLyricColorPicker(
            context,
            colors,
            '未播放颜色',
            _lyricColorPresets,
            s.unplayColor,
            (v) => update((cur) => cur.copyWith(unplayColor: v)),
            customHex: s.customColors,
            onCustomChanged: (list) =>
                update((cur) => cur.copyWith(customColors: list)),
          ),
        ),
        SettingDivider(colors: colors),
        SettingRow(
          icon: Icons.border_color,
          title: '描边颜色',
          trailing: _colorSwatch(s.strokeColor, colors),
          colors: colors,
          onTap: () => _showDesktopLyricColorPicker(
            context,
            colors,
            '描边颜色',
            _strokeColorPresets,
            s.strokeColor,
            (v) => update((cur) => cur.copyWith(strokeColor: v)),
            customHex: s.customColors,
            onCustomChanged: (list) =>
                update((cur) => cur.copyWith(customColors: list)),
            // 可以做半透明描边，取色面板同样开放透明度。
            allowAlpha: true,
          ),
        ),
        SettingDivider(colors: colors),
        _SettingSlider(
          icon: Icons.line_weight,
          title: '描边宽度',
          subtitle: '按字体大小的比例，设为 0 则不描边',
          value: s.strokeWidth,
          min: 0,
          max: 0.2,
          divisions: 20,
          valueLabel: '${(s.strokeWidth * 100).round()}%',
          colors: colors,
          onChanged: (v) => update((cur) => cur.copyWith(strokeWidth: v)),
        ),
      ],
    );
  }
}

// ==================== Desktop Lyric ====================

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
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
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

/// 桌面歌词文字描边颜色预设。
///
/// 「无描边」用全透明色表示，原生侧检测到 alpha=0 就整层跳过绘制。
const _strokeColorPresets = <(String, int)>[
  ('无描边', 0x00000000),
  ('白色', 0xFFFFFFFF),
  ('浅灰', 0xFFD1D5DB),
  ('黑色', 0xFF000000),
  ('深蓝', 0xFF1E3A8A),
  ('薄荷绿', 0xFF07C556),
  ('半透明白', 0x99FFFFFF),
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

/// ARGB 整数 -> `#AARRGGBB`（桌面歌词自定义色板的统一存储格式）。
String _desktopLyricArgbHex(int argb) =>
    '#${argb.toUnsigned(32).toRadixString(16).toUpperCase().padLeft(8, '0')}';

/// 解析 `#AARRGGBB` / `#RRGGBB`，非法值返回 null。
int? _desktopLyricParseHex(String hex) {
  var code = hex.trim().replaceFirst('#', '').toUpperCase();
  if (code.length == 6) code = 'FF$code';
  if (code.length != 8) return null;
  return int.tryParse(code, radix: 16);
}

/// 长按自定义色：编辑 / 删除（与主题色「新增颜色」的交互一致）。
void _showDesktopLyricCustomActions(
  BuildContext context,
  ThemeColors colors,
  String hex, {
  required void Function() onEdit,
  required void Function() onDelete,
}) {
  showModalBottomSheet<void>(
    useRootNavigator: true,
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
                    color: Color(_desktopLyricParseHex(hex) ?? 0xFF000000),
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
          SettingDivider(colors: colors),
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
            leading: Icon(Icons.delete_outline, color: colors.error),
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

/// 桌面歌词颜色选择：内置预设 + 用户新增的自定义颜色。
///
/// 交互与「主题色」的新增颜色一致：HSV 取色面板新增、长按自定义色编辑/删除，
/// 自定义色板保存在 [DesktopLyricSettings.customColors] 里随设置一起持久化。
/// [allowAlpha] 为 true 时取色面板多一条透明度滑条（描边颜色需要）。
void _showDesktopLyricColorPicker(
  BuildContext context,
  ThemeColors colors,
  String title,
  List<(String, int)> presets,
  int currentArgb,
  ValueChanged<int> onSelected, {
  required List<String> customHex,
  required ValueChanged<List<String>> onCustomChanged,
  bool allowAlpha = false,
}) {
  final seen = <int>{};
  final items = <(String, int)>[];
  for (final item in presets) {
    if (seen.add(item.$2)) items.add(item);
  }
  final customSet = <int>{};
  for (final hex in customHex) {
    final argb = _desktopLyricParseHex(hex);
    if (argb != null) customSet.add(argb);
    if (argb != null && seen.add(argb)) items.add(('自定义', argb));
  }

  void reopen(List<String> nextCustom, int nextCurrent) {
    if (!context.mounted) return;
    _showDesktopLyricColorPicker(
      context,
      colors,
      title,
      presets,
      nextCurrent,
      onSelected,
      customHex: nextCustom,
      onCustomChanged: onCustomChanged,
      allowAlpha: allowAlpha,
    );
  }

  void openEditor({String? editingHex}) {
    final initial = Color(
      editingHex == null
          ? currentArgb
          : (_desktopLyricParseHex(editingHex) ?? currentArgb),
    );
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      sheetAnimationStyle: _settingsSheetAnimationStyle,
      backgroundColor: colors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (editorContext) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: HsvColorPicker(
              initialColor: initial,
              showAlpha: allowAlpha,
              onCancel: () => Navigator.pop(editorContext),
              onSave: (color) {
                Navigator.pop(editorContext);
                final argb = color.toARGB32();
                final hex = _desktopLyricArgbHex(argb);
                onSelected(argb);
                final next = _upsertCustomColor(customHex, hex, editingHex);
                onCustomChanged(next);
                reopen(next, argb);
              },
            ),
          ),
        ),
      ),
    );
  }

  showModalBottomSheet(
    useRootNavigator: true,
    context: context,
    sheetAnimationStyle: _settingsSheetAnimationStyle,
    backgroundColor: colors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => SafeArea(
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
              spacing: 16,
              runSpacing: 16,
              children: items.map((item) {
                final isSelected = item.$2 == currentArgb;
                final color = Color(item.$2);
                final isCustom = customSet.contains(item.$2);
                return GestureDetector(
                  onTap: () {
                    onSelected(item.$2);
                    Navigator.pop(sheetContext);
                  },
                  onLongPress: isCustom
                      ? () => _showDesktopLyricCustomActions(
                          sheetContext,
                          colors,
                          _desktopLyricArgbHex(item.$2),
                          onEdit: () {
                            Navigator.pop(sheetContext);
                            openEditor(
                              editingHex: _desktopLyricArgbHex(item.$2),
                            );
                          },
                          onDelete: () {
                            final next = customHex
                                .where(
                                  (h) => _desktopLyricParseHex(h) != item.$2,
                                )
                                .toList();
                            onCustomChanged(next);
                            Navigator.pop(sheetContext);
                            reopen(next, currentArgb);
                          },
                        )
                      : null,
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
                                : Border.all(color: colors.divider, width: 1.5),
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
                          sheetContext.tr(item.$1),
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
            if (customHex.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                sheetContext.tr('长按自定义颜色可编辑或删除'),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(sheetContext);
                openEditor();
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
        // Windows 音频输出走 media_kit/libmpv，没有可插入的 AudioEffect 链路，
        // 这两个分组只会保存设置而不会生效，直接隐藏。
        if (!Platform.isWindows) ...[
          _buildEqualizerGroup(context, ref, colors),
          _buildAudioEffectGroup(context, ref, colors),
        ],
      ],
    );
  }

  Widget _buildPlaybackGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final markPlayedStatus = ref.watch(markPlayedStatusProvider);
    final hideVipExclusive = ref.watch(hideVipExclusiveSongsProvider);
    final downloadTimeout = ref.watch(playbackDownloadTimeoutProvider);
    return SettingGroup(
      title: '播放设置',
      colors: colors,
      children: [
        SettingRow(
          icon: Icons.playlist_add_check,
          title: '标记歌曲播放状态',
          trailing: Switch(
            value: markPlayedStatus,
            onChanged: (v) => _persistBool(
              context,
              markPlayedStatusProvider,
              v,
              (s) => s.setMarkPlayedStatus(v),
            ),
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        SettingDivider(colors: colors),
        SettingRow(
          icon: Icons.workspace_premium_outlined,
          title: '隐藏B站会员专属歌曲',
          trailing: Switch(
            value: hideVipExclusive,
            onChanged: (v) {
              _persistBool(
                context,
                hideVipExclusiveSongsProvider,
                v,
                (s) => s.setHideVipExclusiveSongs(v),
              );
              // 音源管理器解析插件列表时过滤；收藏详情页监听 provider 立即重算。
              ref.read(musicSourceManagerProvider).hideVipExclusiveSongs = v;
            },
            activeTrackColor: colors.primary.withValues(alpha: 0.3),
            activeThumbColor: colors.primary,
          ),
          colors: colors,
        ),
        SettingDivider(colors: colors),
        SettingRow(
          icon: Icons.timer_outlined,
          title: '播放下载超时',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$downloadTimeout 秒',
                style: TextStyle(fontSize: 13, color: colors.textSecondary),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
            ],
          ),
          colors: colors,
          onTap: () => _showBottomPicker(
            context,
            colors,
            '播放下载超时',
            const ['5', '10', '15', '20', '25', '30', '35', '40', '50', '60'],
            '$downloadTimeout',
            (v) {
              final seconds = int.tryParse(v) ?? 10;
              _persistInt(
                context,
                playbackDownloadTimeoutProvider,
                seconds,
                (s) => s.setPlaybackDownloadTimeout(seconds),
              );
            },
          ),
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
    return SettingGroup(
      title: '音频均衡器',
      colors: colors,
      children: [
        SettingRow(
          icon: Icons.tune,
          title: '均衡器',
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
          SettingDivider(colors: colors),
          SettingRow(
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
          SettingDivider(colors: colors),
          ...List.generate(10, (i) {
            final freq = kEqFrequencies[i];
            final freqLabel = freq >= 1000 ? '${freq ~/ 1000}k' : '$freq';
            return Column(
              children: [
                SettingRow(
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
                if (i < 9) SettingDivider(colors: colors),
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
        title: Text(
          context.tr('保存为新预设'),
          style: TextStyle(color: colors.textPrimary),
        ),
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
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              Navigator.pop(ctx);
              _saveNewPreset(context, name);
            },
            child: Text(
              context.tr('保存'),
              style: TextStyle(color: colors.primary),
            ),
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
      SnackBar(
        content: Text(context.tr('预设保存成功')),
        backgroundColor: Colors.green,
      ),
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
            child: Text(
              context.tr('删除'),
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  /// 导出「音频均衡器 + 高级音效处理」的配置。
  ///
  /// 数据源就是 `settings.json`（[SettingsService.exportAudioEffectConfig]）：
  /// 文件里的 `settings` 那一段就是 settings.json 里对应的键，导入时原样写
  /// 回去。不再像旧版那样只导出均衡器四项、也不另存一份「音效专用」配置。
  Future<void> _exportEqConfig(BuildContext context, ThemeColors colors) async {
    try {
      final container = ProviderScope.containerOf(context);
      final svc = await container.read(settingsServiceProvider.future);
      final data = jsonEncode({
        'version': 2,
        // 均衡器 + 高级音效的全部键，值就是 settings.json 里的原始形态。
        'settings': svc.exportAudioEffectConfig(),
      });
      final dir = await AppPaths.settingsDirectory();
      await File('${dir.path}/mintmusic_eq_config.json').writeAsString(data);
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('均衡器配置已导出')),
            backgroundColor: colors.primary,
          ),
        );
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('导出失败: $e')),
            backgroundColor: Colors.red,
          ),
        );
    }
  }

  /// 导入「音频均衡器 + 高级音效处理」的配置。
  ///
  /// 写回 `settings.json`（[SettingsService.importAudioEffectConfig]），然后
  /// 按文件内容把界面上的开关 / 滑条刷新一遍，不需要重启应用。
  /// 两种文件都认：新版（`settings` 段）和旧版（只有均衡器四项）。
  Future<void> _importEqConfig(BuildContext context, ThemeColors colors) async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );
      if (result == null || result.files.isEmpty) return;
      final decoded = jsonDecode(
        await File(result.files.single.path!).readAsString(),
      );
      if (decoded is! Map) throw const FormatException('配置文件格式不正确');
      final data = decoded.map((key, value) => MapEntry('$key', value));
      if (!context.mounted) return;

      final container = ProviderScope.containerOf(context);
      final svc = await container.read(settingsServiceProvider.future);
      final settings = data['settings'];
      if (settings is Map) {
        await svc.importAudioEffectConfig(
          settings.map((key, value) => MapEntry('$key', value)),
        );
      } else {
        await svc.importAudioEffectConfig(_legacyEqConfigToSettings(data));
      }

      // 配置已经写进 settings.json：重新按文件内容加载一遍设置，
      // 让界面上的开关 / 滑条与文件一致（也顺带把音效重新应用到播放器）。
      container.invalidate(settingsInitProvider);
      await container.read(settingsInitProvider.future);
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('均衡器配置导入成功')),
            backgroundColor: colors.primary,
          ),
        );
    } catch (e) {
      if (context.mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('导入失败: $e')),
            backgroundColor: Colors.red,
          ),
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
    return SettingGroup(
      title: '高级音效处理',
      colors: colors,
      children: [
        SettingRow(
          icon: Icons.graphic_eq,
          title: '音效增强',
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
          SettingDivider(colors: colors),
          SettingRow(
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
            SettingDivider(colors: colors),
            SettingRow(
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
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.tune,
              title: '低音预设',
              subtitle: '选择低音增强预设',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    context.tr(
                      bassPresetLabels[bassBoostPreset] ?? bassBoostPreset,
                    ),
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
          SettingDivider(colors: colors),
          SettingRow(
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
            SettingDivider(colors: colors),
            SettingRow(
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
          SettingDivider(colors: colors),
          SettingRow(
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
            SettingDivider(colors: colors),
            SettingRow(
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

  /// 缓存目录：路径 + 选择 / 打开目录 + 最大缓存大小（只限音频缓存）+ 清除缓存。
  Widget _buildCacheGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeColors colors,
  ) {
    final cacheDir = ref.watch(cacheDirProvider);
    final cacheDirSize = ref.watch(cacheDirSizeProvider);
    final maxMb = ref.watch(maxCacheSizeMbProvider);
    final maxLabel = _formatCacheLimit(maxMb);

    return SettingGroup(
      title: '缓存目录',
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
                      final previousRoot = await CachePaths.currentRootPath();
                      container.read(cacheDirProvider.notifier).state = result;
                      // 让后续的封面 / 图片缓存真正写入新目录。
                      CachePaths.configure(result);
                      // 旧目录里的本地歌曲封面不再使用：新目录会重新提取，
                      // 旧文件留着只会占空间。
                      await CachePaths.deleteLocalSongsImageCacheAt(
                        previousRoot,
                        keepRoot: result,
                      );
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
            // 用户主动改上限，绕过节流立即生效。
            unawaited(CachePaths.enforceLimit(force: true));
            _persistInt(
              context,
              maxCacheSizeMbProvider,
              mb,
              (s) => s.setMaxCacheSizeMb(mb),
            );
          },
        ),
        Text(
          context.tr('仅限制音频缓存；图片缓存最多保留 2000 张，30 天未使用自动清理。'),
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

    return SettingGroup(
      title: '下载目录',
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
              border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
            ),
            child: sizeAsync.when(
              data: (s) =>
                  Text(s, style: TextStyle(fontSize: 11, color: badgeColor)),
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
    final colors = ref_watch_colors(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('重置目录设置'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定要重置为默认目录吗？这将清除当前的自定义目录设置。'),
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
              final previousRoot = await CachePaths.currentRootPath();
              CachePaths.configure(appCacheDir.path);
              // 旧目录里的本地歌曲封面不再使用（新目录重新提取）。
              await CachePaths.deleteLocalSongsImageCacheAt(
                previousRoot,
                keepRoot: appCacheDir.path,
              );
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
                    backgroundColor: colors.primary,
                  ),
                );
            },
            child: Text(
              context.tr('确定重置'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
  }

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
      container.invalidate(cacheDirSizeProvider);
      container.invalidate(downloadDirSizeProvider);
    } catch (_) {}
  }
}
