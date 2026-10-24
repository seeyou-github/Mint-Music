import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/theme/theme_colors.dart';

double _lightness(Color color) => HSLColor.fromColor(color).lightness;

void main() {
  group('ThemeColors.copyWithBackground', () {
    test('不传背景色时保持原样', () {
      final base = ThemeColors.darkWithPrimary(const Color(0xFF6366F1));
      expect(identical(base.copyWithBackground(null), base), isTrue);
    });

    test('深色背景：控件颜色比背景更亮，且逐级递增', () {
      const background = Color(0xFF121212);
      final colors = ThemeColors.darkWithPrimary(
        const Color(0xFF6366F1),
      ).copyWithBackground(background);

      expect(colors.background, background);
      expect(_lightness(colors.surface), greaterThan(_lightness(background)));
      expect(
        _lightness(colors.surfaceVariant),
        greaterThan(_lightness(colors.surface)),
      );
      // 深色背景上分隔线要提亮才看得见。
      expect(_lightness(colors.divider), greaterThan(_lightness(background)));
    });

    test('浅色背景：控件颜色比背景更亮，分隔线压暗', () {
      const background = Color(0xFFE8E8EC);
      final colors = ThemeColors.lightWithPrimary(
        const Color(0xFF6366F1),
      ).copyWithBackground(background);

      expect(colors.background, background);
      expect(_lightness(colors.surface), greaterThan(_lightness(background)));
      expect(
        _lightness(colors.surfaceVariant),
        greaterThan(_lightness(colors.surface)),
      );
      expect(_lightness(colors.divider), lessThan(_lightness(background)));
    });

    test('派生颜色保留背景色的色相', () {
      const background = Color(0xFF1B2430); // 偏蓝的深色
      final colors = ThemeColors.darkWithPrimary(
        const Color(0xFF6366F1),
      ).copyWithBackground(background);

      final hue = HSLColor.fromColor(background).hue;
      expect(HSLColor.fromColor(colors.surface).hue, closeTo(hue, 1));
      expect(HSLColor.fromColor(colors.surfaceVariant).hue, closeTo(hue, 1));
    });

    test('很亮的浅色背景不会派生为纯白（保留背景色调）', () {
      const background = Color(0xFFDCD7C9);
      final colors = ThemeColors.lightWithPrimary(
        const Color(0xFF1DB954),
      ).copyWithBackground(background);

      expect(colors.surface, isNot(const Color(0xFFFFFFFF)));
      expect(colors.surfaceVariant, isNot(const Color(0xFFFFFFFF)));
      // 暖米色背景 R > G > B 的通道关系在派生后仍然保持。
      for (final color in [colors.surface, colors.surfaceVariant]) {
        expect(color.r, greaterThan(color.g));
        expect(color.g, greaterThan(color.b));
      }
    });

    test('小播放条背景跟随控件颜色', () {
      const background = Color(0xFF121212);
      final colors = ThemeColors.darkWithPrimary(
        const Color(0xFF6366F1),
      ).copyWithBackground(background);
      expect(colors.miniPlayerBackground, colors.surface);
    });
  });
}
