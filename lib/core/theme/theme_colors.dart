import 'package:flutter/material.dart';

class ThemeColors {
  final Color primary;
  final Color primaryLight;
  final Color primaryDark;

  final Color accent;
  final Color accentLight;

  final Color background;
  final Color surface;
  final Color surfaceVariant;

  /// 弹框 / 底部弹层 / 弹出菜单 / SnackBar 的底色，**永远不透明**。
  ///
  /// 高斯模糊模式下 [surface] 是半透明玻璃层（见 `blurGlassSurface`），
  /// 那是给贴在照片上的主界面控件用的。浮层不行：它盖在整片照片上，
  /// 45% 的纹理透上来会把文字糊掉，所以浮层单独用这套实心派生色。
  final Color dialogSurface;
  final Color dialogSurfaceVariant;

  final Color textPrimary;
  final Color textSecondary;
  final Color textHint;
  final Color textOnPrimary;

  final Color error;
  final Color success;
  final Color warning;

  final Color divider;
  final Color disabled;

  final Color miniPlayerBackground;
  final Color miniPlayerProgress;

  final Color coverShadow;
  final Color shadow;

  const ThemeColors({
    required this.primary,
    required this.primaryLight,
    required this.primaryDark,
    required this.accent,
    required this.accentLight,
    required this.background,
    required this.surface,
    required this.surfaceVariant,
    required this.dialogSurface,
    required this.dialogSurfaceVariant,
    required this.textPrimary,
    required this.textSecondary,
    required this.textHint,
    required this.textOnPrimary,
    required this.error,
    required this.success,
    required this.warning,
    required this.divider,
    required this.disabled,
    required this.miniPlayerBackground,
    required this.miniPlayerProgress,
    required this.coverShadow,
    required this.shadow,
  });

  /// 复制并覆盖文字颜色（设置里的「字体颜色」「第二字体颜色」）。
  ///
  /// [textHint] 不再是一份写死的灰：它由「第二文字颜色」派生（混 28% 向面板
  /// 底色），所以占位符、说明文字、空状态图标会跟着用户选的第二文字颜色走。
  /// 原来固定 #999999，浅色主题下压在浅底上对比度只有 2.4:1，基本看不清。
  ThemeColors copyWithTextColors({Color? textPrimary, Color? textSecondary}) {
    final secondary = textSecondary ?? this.textSecondary;
    return ThemeColors(
      primary: primary,
      primaryLight: primaryLight,
      primaryDark: primaryDark,
      accent: accent,
      accentLight: accentLight,
      background: background,
      surface: surface,
      surfaceVariant: surfaceVariant,
      dialogSurface: dialogSurface,
      dialogSurfaceVariant: dialogSurfaceVariant,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: secondary,
      textHint: textSecondary == null
          ? textHint
          : _hintFrom(secondary, dialogSurface),
      textOnPrimary: textOnPrimary,
      error: error,
      success: success,
      warning: warning,
      divider: divider,
      disabled: disabled,
      miniPlayerBackground: miniPlayerBackground,
      miniPlayerProgress: miniPlayerProgress,
      coverShadow: coverShadow,
      shadow: shadow,
    );
  }

  /// 「提示级」文字色：由「第二文字颜色」往面板底色方向混 28%，比正文淡一档
  /// 但仍然看得清；用户改第二文字颜色时自动跟着变。
  static Color _hintFrom(Color secondary, Color surface) =>
      Color.alphaBlend(secondary.withValues(alpha: 0.72), surface);

  /// 复制并覆盖背景颜色（设置里的「背景颜色」）。
  ///
  /// 侧边栏、选项、搜索框、歌单/榜单卡片等控件都用 [surface] /
  /// [surfaceVariant] 着色；如果只替换 [background]，这些控件仍会保持
  /// 固定的灰/白，和自定义背景完全不搭。这里按背景色派生一套同色调、
  /// 略亮的控件颜色：surface 比背景只亮一点点，surfaceVariant 再亮一点点；
  /// 分隔线在浅色下压暗、深色下提亮，保证仍然可见。
  ///
  /// 提亮幅度刻意压得很低：主界面背景是用户自己配的多色渐变（见
  /// `background_gradient.dart`），卡片 / 按钮 / 设置块若还按原来的幅度提亮，
  /// 就会在渐变背景上形成对比强烈的色块。层次感改由 `app_surface.dart`
  /// 的细边框 + 悬浮阴影提供，颜色本身只负责一点点「浮起来」的亮度差。
  ThemeColors copyWithBackground(Color? background) {
    if (background == null) return this;
    // 按「用户选的那个背景色」判断明暗，而不是主题原本的背景色：
    // 深色模式下也可以选浅背景，控件颜色要跟着实际背景走。
    final isLight =
        ThemeData.estimateBrightnessForColor(background) == Brightness.light;
    // 浅色背景不能靠 HSL 提高亮度：浅色预设本身已经很亮，+0.06 就会
    // 被夹到 1.0 直接变成纯白（侧边栏 / 搜索框 / 歌单卡片看起来都没跟
    // 背景色走）。改成按比例混向白色，背景的色调始终保留。
    final surface = isLight
        ? _lighten(background, 0.18)
        : _shiftLightness(background, 0.035);
    final surfaceVariant = isLight
        ? _lighten(background, 0.30)
        : _shiftLightness(background, 0.06);
    return ThemeColors(
      primary: primary,
      primaryLight: primaryLight,
      primaryDark: primaryDark,
      accent: accent,
      accentLight: accentLight,
      background: background,
      surface: surface,
      surfaceVariant: surfaceVariant,
      dialogSurface: surface,
      dialogSurfaceVariant: surfaceVariant,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textHint: textHint,
      textOnPrimary: textOnPrimary,
      error: error,
      success: success,
      warning: warning,
      divider: _shiftLightness(background, isLight ? -0.08 : 0.13),
      disabled: disabled,
      miniPlayerBackground: surface,
      miniPlayerProgress: miniPlayerProgress,
      coverShadow: coverShadow,
      shadow: shadow,
    );
  }

  /// 只替换控件表面色（高斯模糊背景下的半透明玻璃层）。
  ///
  /// 文字颜色、背景代表色、边框色都保持原样：`floatingShadows` /
  /// `estimateBrightnessForColor` 仍按不透明的 [background] 判断明暗，
  /// 边框也不会因为跟着变半透明而消失。[dialogSurface] 同样不动 ——
  /// 浮层要的就是实心，玻璃只给主界面控件。
  ThemeColors copyWithSurface({Color? surface, Color? surfaceVariant}) {
    final newSurface = surface ?? this.surface;
    return ThemeColors(
      primary: primary,
      primaryLight: primaryLight,
      primaryDark: primaryDark,
      accent: accent,
      accentLight: accentLight,
      background: background,
      surface: newSurface,
      surfaceVariant: surfaceVariant ?? this.surfaceVariant,
      dialogSurface: dialogSurface,
      dialogSurfaceVariant: dialogSurfaceVariant,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
      textHint: textHint,
      textOnPrimary: textOnPrimary,
      error: error,
      success: success,
      warning: warning,
      divider: divider,
      disabled: disabled,
      miniPlayerBackground: newSurface,
      miniPlayerProgress: miniPlayerProgress,
      coverShadow: coverShadow,
      shadow: shadow,
    );
  }

  static Color _shiftLightness(Color color, double delta) {
    final hsl = HSLColor.fromColor(color);
    return hsl.withLightness((hsl.lightness + delta).clamp(0.0, 1.0)).toColor();
  }

  /// 按比例 [amount] 混向白色（保留原来的色相 / 饱和度）。
  static Color _lighten(Color color, double amount) {
    return Color.lerp(color, const Color(0xFFFFFFFF), amount)!;
  }

  static ThemeColors lightWithPrimary(Color primary) {
    return ThemeColors(
      primary: primary,
      primaryLight: Color.lerp(primary, const Color(0xFFFFFFFF), 0.2)!,
      primaryDark: Color.lerp(primary, const Color(0xFF000000), 0.2)!,
      accent: primary,
      accentLight: Color.lerp(primary, const Color(0xFFFFFFFF), 0.2)!,
      background: const Color(0xFFDCD7C9),
      surface: const Color(0xFFEAE7DF),
      surfaceVariant: const Color(0xFFF3F1EC),
      dialogSurface: const Color(0xFFEAE7DF),
      dialogSurfaceVariant: const Color(0xFFF3F1EC),
      textPrimary: const Color(0xFF000000),
      textSecondary: const Color(0xFF3A3933),
      // 提示级颜色由第二文字颜色派生，不再写死 #999999（浅底上几乎看不见）。
      textHint: _hintFrom(
        const Color(0xFF3A3933),
        const Color(0xFFEAE7DF),
      ),
      textOnPrimary: const Color(0xFFFFFFFF),
      error: const Color(0xFFE91429),
      success: primary,
      warning: const Color(0xFFF59E0B),
      divider: const Color(0xFFCCC5B0),
      disabled: const Color(0xFFE0E0E0),
      miniPlayerBackground: const Color(0xFFEAE7DF),
      miniPlayerProgress: primary,
      coverShadow: const Color(0x1A000000),
      shadow: const Color(0x1A000000),
    );
  }

  static ThemeColors darkWithPrimary(Color primary) {
    return ThemeColors(
      primary: primary,
      primaryLight: Color.lerp(primary, const Color(0xFFFFFFFF), 0.2)!,
      primaryDark: Color.lerp(primary, const Color(0xFF000000), 0.2)!,
      accent: primary,
      accentLight: Color.lerp(primary, const Color(0xFFFFFFFF), 0.2)!,
      background: const Color(0xFF212128),
      surface: const Color(0xFF33333E),
      surfaceVariant: const Color(0xFF3F3F4C),
      dialogSurface: const Color(0xFF33333E),
      dialogSurfaceVariant: const Color(0xFF3F3F4C),
      textPrimary: const Color(0xFFFFFFFF),
      textSecondary: const Color(0xFF9D9D9D),
      textHint: _hintFrom(const Color(0xFF9D9D9D), const Color(0xFF33333E)),
      textOnPrimary: const Color(0xFFFFFFFF),
      error: const Color(0xFFE91429),
      success: primary,
      warning: const Color(0xFFF59E0B),
      divider: const Color(0xFF3F3F4C),
      disabled: const Color(0xFF404040),
      miniPlayerBackground: const Color(0xFF33333E),
      miniPlayerProgress: primary,
      coverShadow: const Color(0x40000000),
      shadow: const Color(0x40000000),
    );
  }

  static const dark = ThemeColors(
    primary: Color(0xFF1DB954),
    primaryLight: Color(0xFF1ED760),
    primaryDark: Color(0xFF158C3F),
    accent: Color(0xFF1DB954),
    accentLight: Color(0xFF1ED760),
    background: Color(0xFF212128),
    surface: Color(0xFF33333E),
    surfaceVariant: Color(0xFF3F3F4C),
    dialogSurface: Color(0xFF33333E),
    dialogSurfaceVariant: Color(0xFF3F3F4C),
    textPrimary: Color(0xFFFFFFFF),
    textSecondary: Color(0xFF9D9D9D),
    textHint: Color(0xFF727272),
    textOnPrimary: Color(0xFFFFFFFF),
    error: Color(0xFFE91429),
    success: Color(0xFF1DB954),
    warning: Color(0xFFF59E0B),
    divider: Color(0xFF3F3F4C),
    disabled: Color(0xFF404040),
    miniPlayerBackground: Color(0xFF33333E),
    miniPlayerProgress: Color(0xFF1DB954),
    coverShadow: Color(0x40000000),
    shadow: Color(0x40000000),
  );

  static const light = ThemeColors(
    primary: Color(0xFF1DB954),
    primaryLight: Color(0xFF1ED760),
    primaryDark: Color(0xFF158C3F),
    accent: Color(0xFF1DB954),
    accentLight: Color(0xFF1ED760),
    background: Color(0xFFDCD7C9),
    surface: Color(0xFFEAE7DF),
    surfaceVariant: Color(0xFFF3F1EC),
    dialogSurface: Color(0xFFEAE7DF),
    dialogSurfaceVariant: Color(0xFFF3F1EC),
    textPrimary: Color(0xFF000000),
    textSecondary: Color(0xFF3A3933),
    textHint: Color(0xFF999999),
    textOnPrimary: Color(0xFFFFFFFF),
    error: Color(0xFFE91429),
    success: Color(0xFF1DB954),
    warning: Color(0xFFF59E0B),
    divider: Color(0xFFCCC5B0),
    disabled: Color(0xFFE0E0E0),
    miniPlayerBackground: Color(0xFFEAE7DF),
    miniPlayerProgress: Color(0xFF1DB954),
    coverShadow: Color(0x1A000000),
    shadow: Color(0x1A000000),
  );
}
