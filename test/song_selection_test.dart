import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/widgets/song_selection.dart';

Song _song(String id, String title) =>
    Song(id: id, title: title, artist: 'artist', album: 'album', duration: 100);

void main() {
  group('SongSelectionController', () {
    late SongSelectionController controller;
    final songs = [_song('a', 'A'), _song('b', 'B'), _song('c', 'C')];

    setUp(() => controller = SongSelectionController());

    test('长按进入多选模式并选中该首', () {
      expect(controller.isActive, isFalse);

      controller.enter('b');

      expect(controller.isActive, isTrue);
      expect(controller.count, 1);
      expect(controller.isSelected('b'), isTrue);
    });

    test('已在选择模式时再次长按是切换选中态', () {
      controller.enter('b');
      controller.toggle('b');
      expect(controller.count, 0);
      controller.toggle('b');
      expect(controller.count, 1);
    });

    test('全选 / 取消全选是二态', () {
      controller.enter();
      controller.toggleAll(songs);
      expect(controller.count, 3);
      expect(controller.isAllSelected(3), isTrue);

      controller.toggleAll(songs);
      expect(controller.count, 0);
      expect(controller.isAllSelected(3), isFalse);
    });

    test('空列表时 isAllSelected 恒为 false', () {
      expect(controller.isAllSelected(0), isFalse);
      controller.toggleAll(const []);
      expect(controller.isAllSelected(0), isFalse);
    });

    test('退出多选模式会清空选择', () {
      controller.enter('a');
      controller.exit();
      expect(controller.isActive, isFalse);
      expect(controller.count, 0);
    });

    test('已选歌曲按列表顺序返回', () {
      controller.enter('c');
      controller.toggle('a');

      final selected = controller.selectedSongs(songs);
      expect(selected.map((s) => s.id).toList(), ['a', 'c']);
    });

    test('列表数据源变化后不会出现幽灵选中', () {
      controller.enter('a');
      controller.toggle('b');

      final reduced = [_song('a', 'A')];
      expect(controller.selectedSongs(reduced).map((s) => s.id).toList(), [
        'a',
      ]);
    });

    test('选择变化会通知监听者', () {
      var notified = 0;
      controller.addListener(() => notified++);
      controller.enter('a');
      controller.toggle('a');
      controller.exit();
      expect(notified, greaterThanOrEqualTo(3));
    });
  });
}
