import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'app_spacing.dart';
import 'app_typography.dart';

class AppTheme {
  AppTheme._();

  /// 按「当前主题色」缓存：主题色没变时复用同一份 ThemeData，避免每次 build
  /// 都重建整套组件主题。
  static final Map<String, ThemeData> _cache = {};

  /// 深色主题里用的「亮一档」主题色（与 ThemeColors.lightWithPrimary 的
  /// primaryLight 同一算法）。
  static Color _lightVariant(Color primary) =>
      Color.lerp(primary, Colors.white, 0.2)!;

  /// 主题色上的文字色：白色，和 ThemeColors.textOnPrimary 一致。
  static const Color _onPrimary = Color(0xFFFFFFFF);

  static ThemeData light(
    Color primary, {
    Color? textPrimary,
    Color? textSecondary,
  }) => _cache.putIfAbsent(
    'light|${primary.toARGB32()}|${textPrimary?.toARGB32()}|'
    '${textSecondary?.toARGB32()}',
    () => _buildLight(
      primary,
      textPrimary: textPrimary,
      textSecondary: textSecondary,
    ),
  );

  static ThemeData dark(
    Color primary, {
    Color? textPrimary,
    Color? textSecondary,
  }) => _cache.putIfAbsent(
    'dark|${primary.toARGB32()}|${textPrimary?.toARGB32()}|'
    '${textSecondary?.toARGB32()}',
    () => _buildDark(
      primary,
      _lightVariant(primary),
      textPrimary: textPrimary,
      textSecondary: textSecondary,
    ),
  );

  /// 浅色 Material 主题：所有写死的 Spotify 绿都换成 [primary]。
  /// 没显式写 style 的 FilledButton / OutlinedButton / Switch / Slider /
  /// Checkbox / TabBar 等控件，都是从这里的 colorScheme 取色，因此会自动跟随
  /// 「外观设置 → 主题色」。
  static ThemeData _buildLight(
    Color primary, {
    Color? textPrimary,
    Color? textSecondary,
  }) => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    // 全局关闭点击水波纹。
    //
    // 水波纹是纯装饰：每次点击都要在 Material 上新建一个动画层并重绘整块区域，
    // 长列表里滚动 + 点击叠加时很容易看到掉帧。按下反馈由按钮/列表行自己的
    // 颜色变化承担（见 song_list_item 等处的 highlightColor），不影响可点性判断。
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    colorScheme: ColorScheme.light(
      primary: primary,
      onPrimary: _onPrimary,
      secondary: primary,
      onSecondary: _onPrimary,
      surface: Color(0xFFFFFFFF),
      onSurface: Color(0xFF1A1A1A),
      error: AppColors.error,
      onError: _onPrimary,
    ),
    scaffoldBackgroundColor: const Color(0xFFF5F5F5),
    appBarTheme: const AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: Color(0xFFF5F5F5),
      foregroundColor: Color(0xFF1A1A1A),
      centerTitle: true,
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: const Color(0xFFFFFFFF),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: Color(0xFFF5F5F5),
      selectedItemColor: primary,
      unselectedItemColor: Color(0xFF999999),
      type: BottomNavigationBarType.fixed,
      elevation: 0,
      selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: const Color(0xFFF5F5F5),
      indicatorColor: primary.withValues(alpha: 0.12),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: primary,
        foregroundColor: _onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: primary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: const Color(0xFFFFFFFF),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide(color: primary, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      hintStyle: const TextStyle(color: Color(0xFF999999)),
    ),
    dividerTheme: const DividerThemeData(
      color: Color(0xFFE5E5E5),
      thickness: 1,
      space: 1,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: primary,
      inactiveTrackColor: Color(0xFFE0E0E0),
      thumbColor: primary,
      overlayColor: primary.withValues(alpha: 0.12),
      trackHeight: 3,
    ),
    iconTheme: const IconThemeData(color: Color(0xFF666666), size: 24),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primary,
      foregroundColor: _onPrimary,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: const Color(0xFFF0F0F0),
      selectedColor: primary.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      side: BorderSide.none,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primary,
      linearTrackColor: Color(0xFFE0E0E0),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return _onPrimary;
        }
        return const Color(0xFF999999);
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return primary;
        }
        return const Color(0xFFE0E0E0);
      }),
    ),
    textTheme: TextTheme(
      displayLarge: AppTypography.displayLarge.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      displayMedium: AppTypography.displayMedium.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      headlineLarge: AppTypography.headlineLarge.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      headlineMedium: AppTypography.headlineMedium.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      titleLarge: AppTypography.titleLarge.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      titleMedium: AppTypography.titleMedium.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      titleSmall: AppTypography.titleSmall.copyWith(
        color: textSecondary ?? const Color(0xFF666666),
      ),
      bodyLarge: AppTypography.bodyLarge.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      bodyMedium: AppTypography.bodyMedium.copyWith(
        color: textSecondary ?? const Color(0xFF666666),
      ),
      bodySmall: AppTypography.bodySmall.copyWith(
        color: textSecondary ?? const Color(0xFF666666),
      ),
      labelLarge: AppTypography.labelLarge.copyWith(
        color: textPrimary ?? const Color(0xFF1A1A1A),
      ),
      labelMedium: AppTypography.labelMedium.copyWith(
        color: textSecondary ?? const Color(0xFF666666),
      ),
      labelSmall: AppTypography.labelSmall.copyWith(
        color: textSecondary ?? const Color(0xFF666666),
      ),
    ),
  );

  /// 深色 Material 主题（同上，主题色全部来自 [primary]）。
  static ThemeData _buildDark(
    Color primary,
    Color primaryLight, {
    Color? textPrimary,
    Color? textSecondary,
  }) => ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    // 全局关闭点击水波纹。
    //
    // 水波纹是纯装饰：每次点击都要在 Material 上新建一个动画层并重绘整块区域，
    // 长列表里滚动 + 点击叠加时很容易看到掉帧。按下反馈由按钮/列表行自己的
    // 颜色变化承担（见 song_list_item 等处的 highlightColor），不影响可点性判断。
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    colorScheme: ColorScheme.dark(
      primary: primaryLight,
      onPrimary: _onPrimary,
      secondary: primaryLight,
      onSecondary: _onPrimary,
      surface: AppColors.darkSurface,
      onSurface: AppColors.darkTextPrimary,
      error: AppColors.error,
      onError: _onPrimary,
    ),
    scaffoldBackgroundColor: AppColors.darkBackground,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      backgroundColor: AppColors.darkBackground.withValues(alpha: 0.95),
      foregroundColor: AppColors.darkTextPrimary,
      centerTitle: true,
      titleTextStyle: AppTypography.headlineMedium.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
    ),
    cardTheme: CardThemeData(
      elevation: 0,
      color: AppColors.darkSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
    ),
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: AppColors.darkSurface,
      selectedItemColor: primaryLight,
      unselectedItemColor: AppColors.darkTextSecondary,
      type: BottomNavigationBarType.fixed,
      elevation: 0,
      selectedLabelStyle: TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      unselectedLabelStyle: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w400,
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      elevation: 0,
      backgroundColor: AppColors.darkSurface,
      indicatorColor: primaryLight.withValues(alpha: 0.15),
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        elevation: 0,
        backgroundColor: primaryLight,
        foregroundColor: _onPrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: primaryLight),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.darkSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        borderSide: BorderSide(color: primaryLight, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      hintStyle: const TextStyle(color: AppColors.darkTextSecondary),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: primaryLight,
      foregroundColor: _onPrimary,
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.xl),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: AppColors.darkSurface,
      selectedColor: primaryLight.withValues(alpha: 0.2),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      side: BorderSide.none,
    ),
    dividerTheme: const DividerThemeData(
      color: AppColors.darkDivider,
      thickness: 1,
      space: 1,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: primaryLight,
      inactiveTrackColor: AppColors.darkDivider,
      thumbColor: primaryLight,
      overlayColor: primaryLight.withValues(alpha: 0.15),
      trackHeight: 3,
    ),
    textTheme: TextTheme(
      displayLarge: AppTypography.displayLarge.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      displayMedium: AppTypography.displayMedium.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      headlineLarge: AppTypography.headlineLarge.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      headlineMedium: AppTypography.headlineMedium.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      titleLarge: AppTypography.titleLarge.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      titleMedium: AppTypography.titleMedium.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      titleSmall: AppTypography.titleSmall.      copyWith(
        color: textSecondary ?? AppColors.darkTextSecondary,
      ),
      bodyLarge: AppTypography.bodyLarge.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      bodyMedium: AppTypography.bodyMedium.      copyWith(
        color: textSecondary ?? AppColors.darkTextSecondary,
      ),
      bodySmall: AppTypography.bodySmall.      copyWith(
        color: textSecondary ?? AppColors.darkTextSecondary,
      ),
      labelLarge: AppTypography.labelLarge.      copyWith(
        color: textPrimary ?? AppColors.darkTextPrimary,
      ),
      labelMedium: AppTypography.labelMedium.      copyWith(
        color: textSecondary ?? AppColors.darkTextSecondary,
      ),
      labelSmall: AppTypography.labelSmall.      copyWith(
        color: textSecondary ?? AppColors.darkTextSecondary,
      ),
    ),
    iconTheme: const IconThemeData(
      color: AppColors.darkTextSecondary,
      size: 24,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: primaryLight,
      linearTrackColor: AppColors.darkDivider,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return _onPrimary;
        }
        return AppColors.darkTextSecondary;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return primaryLight;
        }
        return AppColors.darkDivider;
      }),
    ),
  );
}
