import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';
import 'package:mintmusic/features/discover/application/discover_providers.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';
import 'package:mintmusic/features/radio/application/radio_providers.dart';
import 'package:mintmusic/features/radio/presentation/radio_edit_page.dart';

class _FakeRadioStore extends RadioStore {
  _FakeRadioStore(this.initial);

  final RadioData initial;
  RadioData? saved;

  @override
  Future<RadioData> load() async => initial;

  @override
  Future<void> save(RadioData data) async => saved = data;
}

void main() {
  testWidgets('新增电台页可删除自定义分类，分类内电台保留', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final station = RadioStation(
      id: 'radio_1',
      name: '深夜电台',
      coverUrl: 'https://example.com/a.jpg',
      categoryId: 'cat_1',
      keywords: const ['晚安'],
      createTime: DateTime(2026, 1, 1),
      updateTime: DateTime(2026, 1, 1),
    );
    final store = _FakeRadioStore(
      RadioData(
        categories: const [RadioCategory(id: 'cat_1', name: '测试')],
        stations: [station],
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          radioStoreProvider.overrideWithValue(store),
          themeColorsProvider.overrideWithValue(ThemeColors.light),
          discoverSupportedSourcesProvider.overrideWithValue(
            const <SourceInfo>[],
          ),
        ],
        child: L10n(
          locale: AppLocale.zhCn,
          child: const MaterialApp(
            home: RadioEditPage(initialCategoryId: 'cat_1'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试'), findsOneWidget);
    final deleteBadge = find.byIcon(Icons.close_rounded);
    expect(deleteBadge, findsOneWidget);

    await tester.tap(deleteBadge);
    await tester.pumpAndSettle();
    expect(find.textContaining('电台本身不会删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    expect(find.text('测试'), findsNothing);
    expect(find.text('全部'), findsOneWidget);
    expect(store.saved, isNotNull);
    expect(store.saved!.categories, isEmpty);
    expect(store.saved!.stations.single.categoryId, RadioCategory.allId);
  });

  testWidgets('只有缓存副本（coverUrl 为空）时编辑页显示自定义封面', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // 不用真实图片文件：编辑页只判断「用哪个路径当封面」，路径本身指向哪儿
    // 由 Image.file 的 errorBuilder 兜底，测试里不必解码图片。
    final coverPath =
        '${Directory.systemTemp.path}${Platform.pathSeparator}radio_cover.png';

    // 同步 / 旧数据里常见：封面文件在，但 coverUrl 是空的。
    final station = RadioStation(
      id: 'radio_2',
      name: '华语经典',
      coverUrl: '',
      coverPath: coverPath,
      keywords: const ['华语 经典'],
      createTime: DateTime(2026, 1, 1),
      updateTime: DateTime(2026, 1, 1),
    );
    final store = _FakeRadioStore(RadioData(stations: [station]));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          radioStoreProvider.overrideWithValue(store),
          themeColorsProvider.overrideWithValue(ThemeColors.light),
          discoverSupportedSourcesProvider.overrideWithValue(
            const <SourceInfo>[],
          ),
        ],
        child: L10n(
          locale: AppLocale.zhCn,
          child: MaterialApp(home: RadioEditPage(station: station)),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final images = tester.widgetList<Image>(find.byType(Image));
    expect(
      images.any(
        (image) =>
            image.image is FileImage &&
            (image.image as FileImage).file.path == coverPath,
      ),
      isTrue,
      reason: '编辑页应预览 coverPath 指向的自定义封面，而不是默认电台封面',
    );
  });
}
