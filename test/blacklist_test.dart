import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/blacklist/domain/models/blacklist_data.dart';
import 'package:mintmusic/features/blacklist/domain/models/blacklist_entry.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

Song _song(String id, String title, String artist) =>
    Song(id: id, title: title, artist: artist, album: 'album', duration: 1);

void main() {
  final data = BlacklistData(
    songs: const [BlacklistEntry(title: '晴天', artist: '周杰伦')],
    artists: const ['林俊杰'],
    whitelist: const [BlacklistEntry(title: '江南', artist: '林俊杰')],
  );

  group('黑名单匹配', () {
    test('歌曲黑名单按「歌曲名 + 歌手」匹配', () {
      expect(data.isBlocked(_song('1', '晴天', '周杰伦')), isTrue);
      expect(data.isBlocked(_song('2', '晴天', '别人')), isFalse);
      // 归一化：大小写 / 多余空格不影响
      expect(data.isBlocked(_song('3', '  晴天 ', ' 周杰伦 ')), isTrue);
    });

    test('歌手黑名单只匹配歌手，多歌手里任意一位命中即算', () {
      expect(data.isBlocked(_song('4', '曹操', '林俊杰')), isTrue);
      expect(data.isBlocked(_song('5', '曹操', '林俊杰/某人')), isTrue);
      expect(data.isBlocked(_song('6', '曹操', '别人')), isFalse);
    });

    test('白名单只豁免歌手黑名单，不影响歌曲黑名单', () {
      expect(data.isBlocked(_song('7', '江南', '林俊杰')), isFalse);
      expect(
        BlacklistData(
          songs: const [BlacklistEntry(title: '江南', artist: '林俊杰')],
          artists: const ['林俊杰'],
          whitelist: const [BlacklistEntry(title: '江南', artist: '林俊杰')],
        ).isBlocked(_song('8', '江南', '林俊杰')),
        isTrue,
      );
    });

    test('isBlockedByArtistOnly 只认「歌手黑名单」这一种情况', () {
      expect(data.isBlockedByArtistOnly(_song('9', '曹操', '林俊杰')), isTrue);
      expect(data.isBlockedByArtistOnly(_song('10', '晴天', '周杰伦')), isFalse);
      expect(data.isBlockedByArtistOnly(_song('11', '江南', '林俊杰')), isFalse);
    });
  });

  group('序列化', () {
    test('歌曲 / 歌手 / 白名单都能往返', () {
      final round = BlacklistData.fromJson(data.toJson());
      expect(round.songs.single.title, '晴天');
      expect(round.artists.single, '林俊杰');
      expect(round.isBlocked(_song('12', '江南', '林俊杰')), isFalse);
      expect(round.isBlocked(_song('13', '曹操', '林俊杰')), isTrue);
    });
  });
}
