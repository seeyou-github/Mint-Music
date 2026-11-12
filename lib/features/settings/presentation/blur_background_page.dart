import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/app_page_background.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/builtin_blur_backgrounds.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../application/appearance_providers.dart';
import '../application/settings_providers.dart';
import '../data/settings_service.dart';
import 'settings_page.dart';

/// 「设置 → 外观设置 → 背景颜色模式 = 高斯模糊」时显示的背景图设置页。
///
/// 安装包内置 4 张图（默认用 1.jpg），用户也可以再上传多张；点缩略图切换
/// 当前背景，内置图不可删除。主界面把选中的图高斯模糊后铺满，模糊程度 /
/// 亮度 / 亮图自动压暗实时预览。图片会**复制进设置目录**
/// （`config/setting`），备份还原时跟着走，设置里只存文件名，换设备 / 换安装
/// 目录也能对应上。
class BlurBackgroundPage extends ConsumerStatefulWidget {
  const BlurBackgroundPage({super.key});

  @override
  ConsumerState<BlurBackgroundPage> createState() => _BlurBackgroundPageState();
}

class _BlurBackgroundPageState extends ConsumerState<BlurBackgroundPage> {
  /// 正在挑图（防止连点弹出两个文件选择器）。
  bool _picking = false;

  /// 设置目录的绝对路径：缩略图要把「文件名」拼成可读路径。
  String? _dirPath;

  /// 设置目录里背景图的文件名前缀：`background_blur_<时间戳>.jpg` …
  ///
  /// 老版本用的是固定名 `background_blur.jpg`，同样以这个前缀开头。
  static const String _fileStem = 'background_blur';

  @override
  void initState() {
    super.initState();
    unawaited(_loadDirectory());
  }

  Future<void> _loadDirectory() async {
    try {
      final dir = await AppPaths.blurBackgroundDirectory();
      if (!mounted) return;
      setState(() => _dirPath = dir.path);
      await _pruneMissing(dir);
    } catch (e) {
      debugPrint('[BlurBackground] 读取设置目录失败: $e');
    }
  }

  /// 去掉列表里已经被外部删掉的文件，并保证选中项仍然有效。
  Future<void> _pruneMissing(Directory dir) async {
    final names = ref.read(blurBackgroundImageNamesProvider);
    if (names.isEmpty) return;
    final legacyDir = await AppPaths.settingsDirectory();
    final existing = <String>[];
    var moved = false;
    for (final name in names) {
      final file = File(p.join(dir.path, name));
      if (await file.exists()) {
        existing.add(name);
        continue;
      }
      // 旧版本 / 从旧备份还原回来的图片还放在设置目录根下：顺手搬进来。
      final legacy = File(p.join(legacyDir.path, name));
      if (!await legacy.exists()) continue;
      try {
        await legacy.rename(file.path);
        existing.add(name);
        moved = true;
      } catch (_) {
        try {
          await legacy.copy(file.path);
          await legacy.delete();
          existing.add(name);
          moved = true;
        } catch (_) {}
      }
    }
    // 文件从旧路径搬走了：让预览按新路径重新解析（旧 FileImage key 会失效）。
    if (moved) ref.invalidate(blurBackgroundImagePathProvider);
    if (existing.length == names.length) return;
    ref.read(blurBackgroundImageNamesProvider.notifier).state = existing;
    await _persist((svc) => svc.setBlurBackgroundImages(existing));
    final selected = ref.read(blurBackgroundImageNameProvider).trim();
    if (selected.isEmpty || !existing.contains(selected)) {
      await _selectImage(existing.isEmpty ? '' : existing.first);
    }
  }

  Future<void> _pickImage() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.image);
      final sourcePath = picked?.files.single.path;
      if (sourcePath == null) return;
      final dir = await AppPaths.blurBackgroundDirectory();
      final ext = p.extension(sourcePath).toLowerCase();
      // 文件名带时间戳，**不能**沿用固定名：Flutter 的图片缓存是按
      // `FileImage(路径)` 做 key 的，同名覆盖文件后组件拿到的还是上一张
      // 的解码结果（甚至更早那张），表现为「选了 C 却显示 A」。
      final name =
          '${_fileStem}_${DateTime.now().microsecondsSinceEpoch}'
          '${ext.isEmpty ? '.png' : ext}';
      final target = File(p.join(dir.path, name));
      await File(sourcePath).copy(target.path);
      if (!mounted) return;

      final names = [...ref.read(blurBackgroundImageNamesProvider), name];
      ref.read(blurBackgroundImageNamesProvider.notifier).state = names;
      await _persist((svc) => svc.setBlurBackgroundImages(names));
      // 新加进来的图片默认选中并使用。
      await _selectImage(name);
    } catch (e) {
      debugPrint('[BlurBackground] 选择背景图失败: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('选择图片失败：$e')),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _picking = false);
    }
  }

  /// 切换当前背景图（点缩略图）。
  Future<void> _selectImage(String name) async {
    if (ref.read(blurBackgroundImageNameProvider) == name) return;
    ref.read(blurBackgroundImageNameProvider.notifier).state = name;
    ref.invalidate(blurBackgroundImagePathProvider);
    // 主色也要重算：它按路径缓存，这里显式失效一次，避免「图换了、控件
    // 底色还是上一张」的时序问题。
    ref.invalidate(blurBackgroundTintProvider);
    await _persist((svc) => svc.setBlurBackgroundImage(name));
  }

  /// 删除一张背景图；删的是当前选中的那张时，自动切到剩下的第一张。
  ///
  /// 内置图片不允许删除（下次启动也会被补回来），这里再兜一层。
  Future<void> _deleteImage(String name) async {
    if (builtinBlurBackgroundNames.contains(name)) return;
    final names = [...ref.read(blurBackgroundImageNamesProvider)]..remove(name);
    ref.read(blurBackgroundImageNamesProvider.notifier).state = names;
    await _persist((svc) => svc.setBlurBackgroundImages(names));

    final selected = ref.read(blurBackgroundImageNameProvider).trim();
    if (selected == name) {
      await _selectImage(names.isEmpty ? '' : names.first);
    }

    final dir = _dirPath;
    if (dir == null) return;
    final path = p.join(dir, name);
    try {
      await File(path).delete();
    } catch (_) {}
    await _evict([path]);
  }

  /// 把已经删掉的旧图的解码结果从图片缓存里踢出去。
  ///
  /// 换图后文件名变了、缓存 key 也就不一样，旧的那张不会再被用到；不清的话
  /// 内存里会一直挂着几张 1080 宽的位图（而且越换越多）。
  Future<void> _evict(Iterable<String> paths) async {
    for (final path in paths) {
      try {
        await FileImage(File(path)).evict();
      } catch (_) {}
    }
  }

  Future<void> _persist(Future<void> Function(SettingsService svc) save) async {
    try {
      final svc = await ref.read(settingsServiceProvider.future);
      await save(svc);
    } catch (e) {
      debugPrint('[BlurBackground] 保存设置失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final imagePath = ref.watch(blurBackgroundImagePathProvider).valueOrNull;
    final imageNames = ref.watch(blurBackgroundImageNamesProvider);
    final selectedName = ref.watch(blurBackgroundImageNameProvider);
    final sigma = ref.watch(blurBackgroundSigmaProvider);
    final brightness = ref.watch(blurBackgroundBrightnessProvider);
    // 饱和度滑条已经移到「外观设置 → 背景颜色」里（渐变模式也生效），
    // 这里只读它的值来画预览。
    final saturation = ref.watch(backgroundSaturationProvider);
    final autoDarkenStrength = ref.watch(blurBackgroundAutoDarkenProvider);
    // 预览用用户图自己的平均亮度算自动压暗，和主界面同一套公式。
    final tint = ref.watch(blurBackgroundTintProvider).valueOrNull;
    final tintColor = tint?.color;
    final autoDarken = tintColor == null
        ? 0.0
        : blurAutoDarkenAlpha(
            luminance: tintColor.computeLuminance(),
            strength: autoDarkenStrength,
          );
    // 黑白 / 暗图上饱和度调整会自动减弱，预览与主界面保持一致。
    final effectiveSaturation = effectiveBlurSaturation(
      saturation,
      tint?.colorfulness ?? 1,
    );
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
                    _buildPreview(
                      colors,
                      imagePath,
                      sigma,
                      brightness,
                      effectiveSaturation,
                      autoDarken,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    _buildImagePicker(colors, imageNames, selectedName),
                    SettingGroup(
                      title: '效果',
                      colors: colors,
                      children: [
                        _BlurSlider(
                          icon: Icons.blur_on,
                          title: '模糊程度',
                          value: sigma.clamp(0, 60),
                          min: 0,
                          max: 60,
                          divisions: 60,
                          valueLabel: '${sigma.round()}',
                          colors: colors,
                          onChanged: (v) {
                            ref
                                    .read(blurBackgroundSigmaProvider.notifier)
                                    .state =
                                v;
                          },
                          onChangeEnd: (v) => unawaited(
                            _persist((s) => s.setBlurBackgroundSigma(v)),
                          ),
                        ),
                        SettingDivider(colors: colors),
                        _BlurSlider(
                          icon: Icons.brightness_6_outlined,
                          title: '亮度',
                          value: brightness.clamp(0.2, 1.4),
                          min: 0.2,
                          max: 1.4,
                          divisions: 24,
                          valueLabel: '${(brightness * 100).round()}%',
                          colors: colors,
                          onChanged: (v) {
                            ref
                                    .read(
                                      blurBackgroundBrightnessProvider.notifier,
                                    )
                                    .state =
                                v;
                          },
                          onChangeEnd: (v) => unawaited(
                            _persist((s) => s.setBlurBackgroundBrightness(v)),
                          ),
                        ),
                        SettingDivider(colors: colors),
                        _BlurSlider(
                          icon: Icons.contrast,
                          title: '亮图自动压暗',
                          value: autoDarkenStrength.clamp(0, 2),
                          min: 0,
                          max: 2,
                          divisions: 20,
                          valueLabel: '${(autoDarkenStrength * 100).round()}%',
                          colors: colors,
                          onChanged: (v) {
                            ref
                                    .read(
                                      blurBackgroundAutoDarkenProvider.notifier,
                                    )
                                    .state =
                                v;
                          },
                          onChangeEnd: (v) => unawaited(
                            _persist((s) => s.setBlurBackgroundAutoDarken(v)),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 背景图管理：已上传的图片缩略图 + 「新增」按钮。
  ///
  /// 点缩略图切换当前背景，缩略图右上角的红色按钮删除该图。
  Widget _buildImagePicker(
    ThemeColors colors,
    List<String> names,
    String selectedName,
  ) {
    final dir = _dirPath;
    return SettingGroup(
      title: '背景图',
      subtitle:
          '点击图片切换背景；前 4 张是内置图（不可删除），右上角按钮只删除自己添加的图',
      colors: colors,
      children: [
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            for (final name in names)
              _BlurImageTile(
                path: dir == null ? null : p.join(dir, name),
                selected: name == selectedName,
                deletable: !builtinBlurBackgroundNames.contains(name),
                colors: colors,
                onTap: () => unawaited(_selectImage(name)),
                onDelete: () => unawaited(_deleteImage(name)),
              ),
            _AddImageTile(
              colors: colors,
              picking: _picking,
              onTap: _picking ? null : () => unawaited(_pickImage()),
            ),
          ],
        ),
      ],
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
            onPressed: () => context.pop(),
            icon: Icon(Icons.close, color: colors.textPrimary),
            tooltip: context.tr('完成'),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            context.tr('高斯模糊背景图'),
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

  /// 预览：和主界面同一套处理（饱和度 + 模糊 + 亮度），所见即所得。
  Widget _buildPreview(
    ThemeColors colors,
    String? imagePath,
    double sigma,
    double brightness,
    double saturation,
    double autoDarken,
  ) {
    final blurSigma = sigma.clamp(0.0, 60.0);
    final scale = blurSigma <= 0.5 ? 1.0 : 1.0 + blurSigma / 120;
    final normalized = brightness.clamp(0.2, 1.4);
    final darken = normalized < 1 ? (1 - normalized) : 0.0;
    final whiten = normalized > 1 ? (normalized - 1) * 0.6 : 0.0;
    final sat = saturation.clamp(0.0, 2.0);

    return AspectRatio(
      // 16:9 的高度再压 30%（16 / (9 * 0.7)），预览不占太多竖向空间。
      aspectRatio: 160 / 63,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        child: Stack(
          fit: StackFit.expand,
          children: [
            const ColoredBox(color: Color(0xFF101012)),
            if (imagePath != null)
              ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: blurSigma,
                  sigmaY: blurSigma,
                ),
                child: Transform.scale(
                  scale: scale,
                  child: ColorFiltered(
                    colorFilter: ColorFilter.matrix(blurSaturationMatrix(sat)),
                    child: Image.file(
                      File(imagePath),
                      fit: BoxFit.cover,
                      cacheWidth: 1080,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              )
            else
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.image_outlined,
                      size: 34,
                      color: colors.textHint,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(
                      context.tr('还没有选择背景图'),
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            if (darken > 0)
              ColoredBox(color: Colors.black.withValues(alpha: darken)),
            if (whiten > 0)
              ColoredBox(color: Colors.white.withValues(alpha: whiten)),
            if (autoDarken > 0)
              ColoredBox(color: Colors.black.withValues(alpha: autoDarken)),
          ],
        ),
      ),
    );
  }
}

/// 一张已上传背景图的缩略图：点它切换背景，右上角红点删除。
class _BlurImageTile extends StatelessWidget {
  const _BlurImageTile({
    required this.path,
    required this.selected,
    this.deletable = true,
    required this.colors,
    required this.onTap,
    required this.onDelete,
  });

  static const double _size = 88;

  final String? path;
  final bool selected;
  final bool deletable;
  final ThemeColors colors;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: _size,
        height: _size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: colors.surfaceVariant),
                  if (path != null)
                    Image.file(
                      File(path!),
                      fit: BoxFit.cover,
                      cacheWidth: 220,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => Icon(
                        Icons.broken_image_outlined,
                        size: 22,
                        color: colors.textHint,
                      ),
                    ),
                ],
              ),
            ),
            // 选中状态：主题色描边；未选中用普通分隔线。
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: selected ? colors.primary : colors.divider,
                    width: selected ? 2 : 1,
                  ),
                ),
              ),
            ),
            if (deletable)
              Positioned(
                top: 4,
                right: 4,
                child: GestureDetector(
                  onTap: onDelete,
                  child: Container(
                    width: 22,
                    height: 22,
                    decoration: const BoxDecoration(
                      color: Color(0xFFE5484D),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「新增」按钮：与缩略图同尺寸的空心方块。
class _AddImageTile extends StatelessWidget {
  const _AddImageTile({
    required this.colors,
    required this.picking,
    required this.onTap,
  });

  final ThemeColors colors;
  final bool picking;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Container(
        width: _BlurImageTile._size,
        height: _BlurImageTile._size,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: colors.divider),
        ),
        child: picking
            ? const Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.add, size: 24, color: colors.textSecondary),
                  const SizedBox(height: 4),
                  Text(
                    context.tr('新增'),
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                ],
              ),
      ),
    );
  }
}

/// 设置页风格的滑条（设置页里那个是私有的，这里单独放一份）。
class _BlurSlider extends StatelessWidget {
  const _BlurSlider({
    required this.icon,
    required this.title,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.valueLabel,
    required this.colors,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final IconData icon;
  final String title;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String valueLabel;
  final ThemeColors colors;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

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
                child: Text(
                  context.tr(title),
                  style: TextStyle(fontSize: 14, color: colors.textPrimary),
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
            onChangeEnd: onChangeEnd,
            activeColor: colors.primary,
            inactiveColor: colors.divider,
          ),
        ],
      ),
    );
  }
}
