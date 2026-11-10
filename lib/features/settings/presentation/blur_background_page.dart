import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../../../app/app_page_background.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/platform/app_paths.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../application/appearance_providers.dart';
import '../application/settings_providers.dart';
import '../data/settings_service.dart';
import 'settings_page.dart';

/// 「设置 → 外观设置 → 背景颜色模式 = 高斯模糊」时显示的背景图设置页。
///
/// 用户可以选一张图，主界面把它高斯模糊后铺满；模糊程度 / 亮度两个滑条实时
/// 预览。图片会**复制进设置目录**（`config/setting`），备份还原时跟着走，
/// 设置里只存文件名，换设备 / 换安装目录也能对应上。
class BlurBackgroundPage extends ConsumerStatefulWidget {
  const BlurBackgroundPage({super.key});

  @override
  ConsumerState<BlurBackgroundPage> createState() => _BlurBackgroundPageState();
}

class _BlurBackgroundPageState extends ConsumerState<BlurBackgroundPage> {
  /// 正在挑图（防止连点弹出两个文件选择器）。
  bool _picking = false;

  /// 设置目录里背景图的文件名前缀：`background_blur.png` / `.jpg` …
  static const String _fileStem = 'background_blur';

  Future<void> _pickImage() async {
    if (_picking) return;
    setState(() => _picking = true);
    try {
      final picked = await FilePicker.platform.pickFiles(type: FileType.image);
      final sourcePath = picked?.files.single.path;
      if (sourcePath == null) return;
      final dir = await AppPaths.settingsDirectory();
      final ext = p.extension(sourcePath).toLowerCase();
      final name = '$_fileStem${ext.isEmpty ? '.png' : ext}';
      final target = File(p.join(dir.path, name));
      // 先删掉以前选的（扩展名可能不同），再写新图：配置目录里只留当前这张。
      await _deleteStoredImages(keep: name);
      await File(sourcePath).copy(target.path);

      if (!mounted) return;
      ref.read(blurBackgroundImageNameProvider.notifier).state = name;
      ref.invalidate(blurBackgroundImagePathProvider);
      // 文件名可能没变（只是换了一张同扩展名的图），路径相同不会触发重新
      // 取色，这里显式让「照片主色」也重算一遍。
      ref.invalidate(blurBackgroundTintProvider);
      await _persist((svc) => svc.setBlurBackgroundImage(name));
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

  Future<void> _removeImage() async {
    await _deleteStoredImages(keep: '');
    if (!mounted) return;
    ref.read(blurBackgroundImageNameProvider.notifier).state = '';
    ref.invalidate(blurBackgroundImagePathProvider);
    ref.invalidate(blurBackgroundTintProvider);
    await _persist((svc) => svc.setBlurBackgroundImage(''));
  }

  /// 删掉设置目录里所有 `background_blur.*`，[keep] 指定的那个除外。
  Future<void> _deleteStoredImages({required String keep}) async {
    try {
      final dir = await AppPaths.settingsDirectory();
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (!name.startsWith('$_fileStem.')) continue;
        if (name == keep) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[BlurBackground] 清理旧背景图失败: $e');
    }
  }

  Future<void> _persist(
    Future<void> Function(SettingsService svc) save,
  ) async {
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
    final sigma = ref.watch(blurBackgroundSigmaProvider);
    final brightness = ref.watch(blurBackgroundBrightnessProvider);
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
                    _buildPreview(colors, imagePath, sigma, brightness),
                    const SizedBox(height: AppSpacing.lg),
                    SettingGroup(
                      title: '背景图',
                      colors: colors,
                      children: [
                        SettingRow(
                          icon: Icons.image_outlined,
                          title: imagePath == null ? '选择图片' : '更换图片',
                          subtitle: '图片会复制到设置目录，备份还原时一起带走',
                          trailing: _picking
                              ? const SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.folder_open,
                                  size: 18,
                                  color: colors.textSecondary,
                                ),
                          colors: colors,
                          onTap: _picking ? null : () => unawaited(_pickImage()),
                        ),
                        if (imagePath != null) ...[
                          SettingDivider(colors: colors),
                          SettingRow(
                            icon: Icons.delete_outline,
                            title: '移除图片',
                            trailing: const SizedBox.shrink(),
                            colors: colors,
                            onTap: () => unawaited(_removeImage()),
                          ),
                        ],
                      ],
                    ),
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
                                .state = v;
                          },
                          onChangeEnd: (v) =>
                              unawaited(_persist((s) => s.setBlurBackgroundSigma(v))),
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
                                .read(blurBackgroundBrightnessProvider.notifier)
                                .state = v;
                          },
                          onChangeEnd: (v) => unawaited(
                            _persist((s) => s.setBlurBackgroundBrightness(v)),
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

  /// 预览：和主界面同一套处理（模糊 + 亮度），所见即所得。
  Widget _buildPreview(
    ThemeColors colors,
    String? imagePath,
    double sigma,
    double brightness,
  ) {
    final blurSigma = sigma.clamp(0.0, 60.0);
    final scale = blurSigma <= 0.5 ? 1.0 : 1.0 + blurSigma / 120;
    final normalized = brightness.clamp(0.2, 1.4);
    final darken = normalized < 1 ? (1 - normalized) : 0.0;
    final whiten = normalized > 1 ? (normalized - 1) * 0.6 : 0.0;

    return AspectRatio(
      aspectRatio: 16 / 9,
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
                  child: Image.file(
                    File(imagePath),
                    fit: BoxFit.cover,
                    cacheWidth: 1080,
                    gaplessPlayback: true,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
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
