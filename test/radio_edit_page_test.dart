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
}
