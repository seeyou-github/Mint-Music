import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/app_page_background.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/background_derivation.dart';
import '../../../core/theme/background_gradient.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/hsv_color_picker.dart';
import '../../player/domain/services/cover_color_extractor.dart';
import '../application/settings_providers.dart';

/// 「设置 → 外观设置 → 背景渐变 → 新增颜色」的全屏编辑页。
///
/// 只让用户选**一个基色**（手动滑色板，或从图片取主色），三段背景由
/// [deriveBackgroundGradient] 自动派生，与播放详情页 / 歌词页背景是同一套
/// 算法。滑条调整体亮度 / 渐变幅度（0%~1000%）/ 饱和度，方向可选 8 个固定
/// 方向或「随机」；改完在页面里直接看到「整块界面」的效果（背景 + 卡片 +
/// 底栏），点保存才真正写入设置。
class BackgroundEditorPage extends ConsumerStatefulWidget {
  const BackgroundEditorPage({
    super.key,
    required this.isLight,
    this.editing,
    this.editingIndex,
  });

  /// 编辑浅色模式那一套（false = 深色模式）。
  final bool isLight;

  /// 编辑已有的自定义渐变时传入（旧的三色渐变也走这里）。
  final List<String>? editing;

  /// 在自定义列表里的下标；为 null 表示新增。
  final int? editingIndex;

  @override
  ConsumerState<BackgroundEditorPage> createState() =>
      _BackgroundEditorPageState();
}

class _BackgroundEditorPageState extends ConsumerState<BackgroundEditorPage> {
  /// 基色（唯一需要用户决定的颜色）。
  late Color _base;

  /// 整体亮度偏移：-1 ~ 1。
  double _brightness = 0;

  /// 渐变幅度：0（纯色）~ 10（落差 ×10，即 0%~1000%）。
  double _spread = 1;

  /// 饱和度倍率：1 = 保持原色，0 = 灰，2 = 加倍。
  double _saturation = 1;

  /// 渐变方向（默认上下；也有「随机」，见 [GradientDirection]）。
  GradientDirection _direction = GradientDirection.topToBottom;

  /// 正在从图片取色。
  bool _extracting = false;

  @override
  void initState() {
    super.initState();
    _base = _initialBaseColor();
    _direction = gradientDirectionFromTokens(widget.editing ?? const []);
  }

  Color _initialBaseColor() {
    final editing = widget.editing;
    if (editing != null && editing.isNotEmpty) {
      // 列表末尾可能带 `@n` 方向标记，取中间那一段颜色当基色时要先滤掉它；
      // 旧的三色渐变没法反推基色，取中间那段（观感最接近）。
      final colors = gradientColorTokens(editing);
      if (colors.isNotEmpty) return _parseHex(colors[colors.length ~/ 2]);
    }
    // 新增：以当前生效背景的最上面一段为起点，改起来有参照。
    final current = ref.read(
      widget.isLight
          ? lightThemeBackgroundColorsProvider
          : darkThemeBackgroundColorsProvider,
    );
    final colors = gradientColorTokens(current);
    if (colors.isNotEmpty) return _parseHex(colors.first);
    return _parseHex(
      widget.isLight ? defaultLightBackgroundColor : defaultDarkBackgroundColor,
    );
  }

  /// 编辑器里手选 / 图片取到的颜色一律不做任何限制（protect = 1），
  /// 只按「亮度 / 渐变幅度 / 饱和度」三个滑条微调。
  List<Color> get _derived => deriveBackgroundGradient(
    _base,
    isLight: widget.isLight,
    brightness: _brightness,
    spread: _spread,
    protect: 1,
    saturationScale: _saturation,
  );

  /// 预览实际使用的方向：`random` 按派生出的颜色解析成一个固定方向。
  GradientDirection get _effectiveDirection =>
      _direction == GradientDirection.random
      ? randomDirectionFor(_derived)
      : _direction;

  Future<void> _pickFromImage() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = picked?.files.single.path;
    if (path == null) return;
    if (!mounted) return;
    setState(() => _extracting = true);
    try {
      // 先缩到 512 再取色：直接解 4K 图在手机上会把内存顶上去。
      final result = await CoverColorExtractor.extract(
        ResizeImage(FileImage(File(path)), width: 512, allowUpscaling: false),
      );
      if (!mounted) return;
      setState(() {
        // 图片取到的颜色同样不做任何限制，滑条回默认值让用户自己微调。
        _base = result.dominantColor;
        _brightness = 0;
        _spread = 1;
        _saturation = 1;
      });
    } finally {
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _save() async {
    // 颜色后面跟一个 `@n` 方向标记，和自定义渐变列表一起存（旧数据没有它，
    // 按「上下」处理）。
    final hexes = [
      for (final color in _derived) _toHex(color),
      gradientDirectionToken(_direction),
    ];
    final customProvider = widget.isLight
        ? customBackgroundGradientsLightProvider
        : customBackgroundGradientsDarkProvider;
    final currentProvider = widget.isLight
        ? lightThemeBackgroundColorsProvider
        : darkThemeBackgroundColorsProvider;

    final list = List<List<String>>.from(ref.read(customProvider));
    final index = widget.editingIndex;
    if (index != null && index >= 0 && index < list.length) {
      list[index] = hexes;
    } else {
      list.add(hexes);
    }
    ref.read(customProvider.notifier).state = list;
    ref.read(currentProvider.notifier).state = hexes;

    final service = await ref.read(settingsServiceProvider.future);
    try {
      if (widget.isLight) {
        await service.setCustomBackgroundGradientsLight(list);
        await service.setThemeBackgroundColorsLight(hexes);
      } else {
        await service.setCustomBackgroundGradientsDark(list);
        await service.setThemeBackgroundColorsDark(hexes);
      }
    } catch (_) {
      // 写盘失败也不拦着用户：内存里的设置已经生效，下次启动最多回到旧值。
    }
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final baseColors = ref.watch(baseThemeColorsProvider);
    // 深色主题 + 已开启「跟随封面变色」时，主界面背景由封面决定，这里的
    // 保存结果要等开关关掉才看得到，先说清楚免得用户以为没生效。
    final coverFollow =
        !widget.isLight && ref.watch(coverBackgroundEnabledProvider);
    final derived = _derived;
    // 预览卡片 / 底栏的底色用「真实派生出来的那套」算，所见即所得。
    final preview = baseColors.copyWithBackground(derived[1]);
    final horizontal = ResponsiveLayout.horizontalPadding(context);

    return AppPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              _buildHeader(colors),
              Expanded(
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    horizontal,
                    AppSpacing.sm,
                    horizontal,
                    AppSpacing.xl,
                  ),
                  children: [
                    _buildPreview(colors, preview, derived),
                    if (coverFollow) ...[
                      const SizedBox(height: AppSpacing.sm),
                      Text(
                        context.tr('已开启「主界面跟随封面变色」，这条渐变要关掉开关后才会显示'),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                    ],
                    const SizedBox(height: AppSpacing.lg),
                    _sectionTitle(colors, '基色'),
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: colors.divider, width: 0.5),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Center(
                            child: HsvColorArea(
                              color: _base,
                              maxSize: 220,
                              onChanged: (color) =>
                                  setState(() => _base = color),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Row(
                            children: [
                              Icon(
                                Icons.colorize,
                                size: 16,
                                color: colors.textHint,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _toHex(_base),
                                style: TextStyle(
                                  fontSize: 13,
                                  color: colors.textSecondary,
                                ),
                              ),
                              const Spacer(),
                              TextButton.icon(
                                onPressed: _extracting ? null : _pickFromImage,
                                icon: _extracting
                                    ? const SizedBox(
                                        width: 14,
                                        height: 14,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : const Icon(Icons.image, size: 18),
                                label: Text(context.tr('从图片取色')),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _sectionTitle(colors, '渐变方向'),
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: colors.divider, width: 0.5),
                      ),
                      child: _buildDirectionPicker(colors),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _sectionTitle(colors, '微调'),
                    const SizedBox(height: AppSpacing.sm),
                    Container(
                      padding: const EdgeInsets.fromLTRB(
                        AppSpacing.md,
                        AppSpacing.sm,
                        AppSpacing.md,
                        AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: colors.surface,
                        borderRadius: BorderRadius.circular(AppRadius.lg),
                        border: Border.all(color: colors.divider, width: 0.5),
                      ),
                      child: Column(
                        children: [
                          _buildSlider(
                            colors,
                            label: '亮度',
                            value: _brightness,
                            min: -1,
                            max: 1,
                            display: '${(_brightness * 100).round()}%',
                            onChanged: (value) =>
                                setState(() => _brightness = value),
                          ),
                          _buildSlider(
                            colors,
                            label: '渐变幅度',
                            value: _spread,
                            min: 0,
                            max: 10,
                            display: '${(_spread * 100).round()}%',
                            onChanged: (value) =>
                                setState(() => _spread = value),
                          ),
                          _buildSlider(
                            colors,
                            label: '饱和度',
                            value: _saturation,
                            min: 0,
                            max: 2,
                            display: '${(_saturation * 100).round()}%',
                            onChanged: (value) =>
                                setState(() => _saturation = value),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      context.tr('背景色会同时决定卡片、分隔线等控件的底色'),
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                  ],
                ),
              ),
              _buildSaveBar(colors),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.sm,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.pop(context),
            icon: Icon(Icons.close, color: colors.textPrimary),
            tooltip: context.tr('取消'),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            context.tr(widget.editing == null ? '新增颜色' : '编辑颜色'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  /// 渐变方向选择：8 个固定方向 + 「随机」。
  ///
  /// 「随机」不存具体角度，只存 random 标记；实际方向由渐变的颜色哈希决定 ——
  /// 不同渐变方向各不相同，同一个渐变每次启动又保持同一个方向（不会闪）。
  Widget _buildDirectionPicker(ThemeColors colors) {
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final direction in GradientDirection.values)
          _buildDirectionChip(colors, direction),
      ],
    );
  }

  Widget _buildDirectionChip(ThemeColors colors, GradientDirection direction) {
    final selected = _direction == direction;
    final foreground = selected ? colors.primary : colors.textSecondary;
    return GestureDetector(
      onTap: () => setState(() => _direction = direction),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: selected ? colors.primary : colors.divider,
            width: selected ? 1.2 : 0.5,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_directionIcon(direction), size: 14, color: foreground),
            const SizedBox(width: AppSpacing.xs),
            Text(
              context.tr(direction.label),
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                color: foreground,
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _directionIcon(GradientDirection direction) => switch (direction) {
    GradientDirection.topToBottom => Icons.arrow_downward,
    GradientDirection.bottomToTop => Icons.arrow_upward,
    GradientDirection.leftToRight => Icons.arrow_forward,
    GradientDirection.rightToLeft => Icons.arrow_back,
    GradientDirection.diagonalDownRight => Icons.south_east,
    GradientDirection.diagonalDownLeft => Icons.south_west,
    GradientDirection.diagonalUpRight => Icons.north_east,
    GradientDirection.diagonalUpLeft => Icons.north_west,
    GradientDirection.random => Icons.shuffle,
  };

  /// 迷你可视化：一整块渐变 + 两张卡片 + 底部一条播放栏。
  ///
  /// 只预览一条渐变色是不够的 —— 背景还会派生 surface / divider，卡片是不是
  /// 还看得清、边界在不在，只有把控件画上去才看得出来。
  Widget _buildPreview(
    ThemeColors colors,
    ThemeColors preview,
    List<Color> derived,
  ) {
    return Container(
      height: 216,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(color: colors.divider, width: 0.5),
        gradient: LinearGradient(
          begin: _effectiveDirection.begin,
          end: _effectiveDirection.end,
          colors: derived,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶部标题占位条
          Container(
            width: 96,
            height: 14,
            decoration: BoxDecoration(
              color: preview.textPrimary.withValues(alpha: 0.75),
              borderRadius: BorderRadius.circular(4),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _previewCard(preview, height: 46),
          const SizedBox(height: AppSpacing.sm),
          _previewCard(preview, height: 46),
          const Spacer(),
          // 迷你播放栏
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            decoration: BoxDecoration(
              color: preview.surface,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: preview.divider.withValues(alpha: 0.6),
                width: 0.5,
              ),
            ),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: preview.surfaceVariant,
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Container(
                  width: 72,
                  height: 8,
                  decoration: BoxDecoration(
                    color: preview.textPrimary.withValues(alpha: 0.5),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const Spacer(),
                Icon(Icons.play_arrow, size: 18, color: preview.textSecondary),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _previewCard(ThemeColors preview, {required double height}) {
    return Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
      decoration: BoxDecoration(
        color: preview.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: preview.divider.withValues(alpha: 0.6),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: preview.surfaceVariant,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 84,
                height: 8,
                decoration: BoxDecoration(
                  color: preview.textPrimary.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                width: 56,
                height: 6,
                decoration: BoxDecoration(
                  color: preview.textSecondary.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeColors colors, String title) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 14,
          decoration: BoxDecoration(
            color: colors.primary,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Text(
          context.tr(title),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildSlider(
    ThemeColors colors, {
    required String label,
    required double value,
    required double min,
    required double max,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            context.tr(label),
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ),
        Expanded(
          child: Slider(value: value, min: min, max: max, onChanged: onChanged),
        ),
        SizedBox(
          width: 48,
          child: Text(
            display,
            textAlign: TextAlign.end,
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
        ),
      ],
    );
  }

  Widget _buildSaveBar(ThemeColors colors) {
    return SafeArea(
      top: false,
      minimum: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.sm,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.md,
      ),
      child: SizedBox(
        width: double.infinity,
        height: 46,
        child: FilledButton(
          onPressed: _save,
          style: FilledButton.styleFrom(
            backgroundColor: colors.primary,
            foregroundColor: colors.textOnPrimary,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
          ),
          child: Text(
            context.tr('保存'),
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

/// `#RRGGBB` → Color。
Color _parseHex(String hex) {
  final value = hex.replaceAll('#', '');
  if (value.length != 6) return Colors.transparent;
  final parsed = int.tryParse(value, radix: 16);
  if (parsed == null) return Colors.transparent;
  return Color(0xFF000000 | parsed);
}

/// Color → `#RRGGBB`。
String _toHex(Color color) {
  final r = (color.r * 255).round().toRadixString(16).padLeft(2, '0');
  final g = (color.g * 255).round().toRadixString(16).padLeft(2, '0');
  final b = (color.b * 255).round().toRadixString(16).padLeft(2, '0');
  return '#${r.toUpperCase()}${g.toUpperCase()}${b.toUpperCase()}';
}
