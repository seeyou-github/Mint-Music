import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/theme/system_brightness_sync.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';

/// 注意两点：
/// 1. 每个用例必须传不同的 [key] —— ProviderScope 的 container 在 initState
///    里按 overrides 创建，复用同一个 element 时不会跟随新的 override 重建。
/// 2. 所有调用必须提供同样数量的 override，否则 Riverpod 会因 override
///    数量变化而断言失败。
Widget _colorsProbe(
  Key key, {
  ThemeMode mode = ThemeMode.light,
  Brightness brightness = Brightness.light,
}) {
  return ProviderScope(
    key: key,
    overrides: [
      themeModeProvider.overrideWith((ref) => mode),
      platformBrightnessProvider.overrideWith((ref) => brightness),
    ],
    child: MaterialApp(
      home: Consumer(
        builder: (context, ref, _) {
          final colors = ref.watch(themeColorsProvider);
          return Text('bg:${colors.background.toARGB32()}');
        },
      ),
    ),
  );
}

String _probeText(WidgetTester tester) =>
    (tester.widget<Text>(find.byType(Text)).data)!;

void main() {
  group('主题模式持久化映射', () {
    test('light / dark / system 往返一致', () {
      for (final mode in ThemeMode.values) {
        expect(themeModeFromPref(themeModeToPref(mode)), mode);
      }
    });

    test('持久化值', () {
      expect(themeModeToPref(ThemeMode.light), 'light');
      expect(themeModeToPref(ThemeMode.dark), 'dark');
      expect(themeModeToPref(ThemeMode.system), 'system');
    });

    test('未知或空值回落为跟随系统（兼容旧版本数据）', () {
      expect(themeModeFromPref(null), ThemeMode.system);
      expect(themeModeFromPref(''), ThemeMode.system);
      expect(themeModeFromPref('nonsense'), ThemeMode.system);
      // 显式保存的浅色仍然生效
      expect(themeModeFromPref('light'), ThemeMode.light);
    });
  });

  group('isThemeModeLight', () {
    test('浅色/深色与系统偏好无关', () {
      expect(isThemeModeLight(ThemeMode.light, Brightness.dark), isTrue);
      expect(isThemeModeLight(ThemeMode.dark, Brightness.light), isFalse);
    });

    test('跟随系统按系统偏好展开', () {
      expect(isThemeModeLight(ThemeMode.system, Brightness.light), isTrue);
      expect(isThemeModeLight(ThemeMode.system, Brightness.dark), isFalse);
    });
  });

  testWidgets('跟随系统时实际主题随系统亮度变化', (tester) async {
    await tester.pumpWidget(
      _colorsProbe(
        const Key('system-light'),
        mode: ThemeMode.system,
        brightness: Brightness.light,
      ),
    );
    final systemLight = _probeText(tester);

    await tester.pumpWidget(
      _colorsProbe(
        const Key('system-dark'),
        mode: ThemeMode.system,
        brightness: Brightness.dark,
      ),
    );
    final systemDark = _probeText(tester);

    await tester.pumpWidget(
      _colorsProbe(const Key('forced-dark'), mode: ThemeMode.dark),
    );
    final forcedDark = _probeText(tester);

    await tester.pumpWidget(
      _colorsProbe(const Key('forced-light'), mode: ThemeMode.light),
    );
    final forcedLight = _probeText(tester);

    // 跟随系统 + 系统深色 == 强制深色
    expect(systemDark, forcedDark);
    // 跟随系统 + 系统浅色 == 强制浅色
    expect(systemLight, forcedLight);
    // 两者确实不同，说明「跟随系统」真的会随系统展开
    expect(systemDark, isNot(systemLight));
  });

  testWidgets('系统亮度变化会实时同步到 provider', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SystemBrightnessSync(child: SizedBox.shrink()),
        ),
      ),
    );

    final container = ProviderScope.containerOf(
      tester.element(find.byType(SystemBrightnessSync)),
    );

    // 模拟系统切到深色并派发变化事件
    tester.view.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    tester.binding.handlePlatformBrightnessChanged();
    await tester.pump();
    expect(container.read(platformBrightnessProvider), Brightness.dark);

    // 再切回浅色
    tester.view.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    tester.binding.handlePlatformBrightnessChanged();
    await tester.pump();
    expect(container.read(platformBrightnessProvider), Brightness.light);
    tester.view.platformDispatcher.clearPlatformBrightnessTestValue();
  });
}
