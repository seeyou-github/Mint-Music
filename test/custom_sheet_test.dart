import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/custom_sheet/domain/models/custom_sheet.dart';

void main() {
  group('CustomSheet', () {
    test('路由 id 前缀往返', () {
      const sheet = CustomSheet(
        id: 'sheet_1',
        sourceId: 'bilibili@abc',
        name: '钢琴',
        keyword: '钢琴曲',
      );
      expect(sheet.playlistId, 'custom:sheet_1');
      expect(CustomSheet.isCustomPlaylistId(sheet.playlistId), isTrue);
      expect(CustomSheet.idOf(sheet.playlistId), 'sheet_1');
      // 不是自定义歌单的 id 原样返回，不影响插件歌单。
      expect(CustomSheet.isCustomPlaylistId('digest-8__123'), isFalse);
      expect(CustomSheet.idOf('digest-8__123'), 'digest-8__123');
    });

    test('封面优先用缓存路径', () {
      const remote = CustomSheet(
        id: 'a',
        sourceId: 's',
        name: 'n',
        keyword: 'k',
        coverUrl: 'https://example.com/a.jpg',
      );
      expect(remote.displayCover, 'https://example.com/a.jpg');
      expect(
        remote.copyWith(coverPath: '/tmp/a.jpg').displayCover,
        '/tmp/a.jpg',
      );
    });
  });

  group('CustomSheetData', () {
    final data = CustomSheetData(
      categories: const [
        CustomSheetCategory(id: 'c1', name: '流行'),
        CustomSheetCategory(id: 'c2', name: '纯音乐'),
      ],
      sheets: const [
        CustomSheet(
          id: 's1',
          sourceId: 'bilibili@abc',
          name: '周杰伦',
          keyword: '周杰伦',
          categoryId: 'c1',
        ),
        CustomSheet(
          id: 's2',
          sourceId: 'bilibili@abc',
          name: '未分类',
          keyword: '白噪音',
        ),
        CustomSheet(
          id: 's3',
          sourceId: 'other@x',
          name: '别的音源',
          keyword: '钢琴',
        ),
      ],
    );

    test('按音源过滤', () {
      expect(
        data.sheetsOfSource('bilibili@abc').map((s) => s.id),
        ['s1', 's2'],
      );
      expect(data.sheetsOfSource('other@x').map((s) => s.id), ['s3']);
    });

    test('按音源 + 分类过滤', () {
      expect(
        data.sheetsOfCategory('bilibili@abc', 'c1').map((s) => s.id),
        ['s1'],
      );
      expect(
        data.sheetsOfCategory('bilibili@abc', '').map((s) => s.id),
        ['s2'],
      );
    });

    test('序列化往返', () {
      final round = CustomSheetData.fromJson(data.toJson());
      expect(round.categories.map((c) => c.name), ['流行', '纯音乐']);
      expect(round.sheets.length, 3);
      expect(round.sheetById('s2')?.categoryId, '');
      expect(round.sheetsOfSource('bilibili@abc').length, 2);
    });

    test('分类改名不影响歌单归属', () {
      final renamed = CustomSheetData(
        categories: [
          for (final category in data.categories)
            if (category.id == 'c1') category.copyWith(name: '华语') else category,
        ],
        sheets: data.sheets,
      );
      expect(renamed.categoryById('c1')?.name, '华语');
      expect(renamed.sheetsOfCategory('bilibili@abc', 'c1').single.id, 's1');
    });

    test('删除分类后歌单回到未分类', () {
      final sheets = [
        for (final sheet in data.sheets)
          if (sheet.categoryId == 'c1') sheet.copyWith(categoryId: '') else sheet,
      ];
      final after = CustomSheetData(
        categories: [
          for (final category in data.categories)
            if (category.id != 'c1') category,
        ],
        sheets: sheets,
      );
      expect(after.categoryById('c1'), isNull);
      expect(after.sheetsOfCategory('bilibili@abc', '').map((s) => s.id), [
        's1',
        's2',
      ]);
    });
  });
}
