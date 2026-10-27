import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/discover/domain/models/hot_board.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

void main() {
  group('热榜数据', () {
    final songs = [
      const Song(
        id: 's1',
        title: '晴天',
        artist: '周杰伦',
        album: '叶惠美',
        duration: 269000,
        coverUrl: 'https://example.com/1.jpg',
        source: 'wy',
        lrc: '[00:00.00]歌词',
        sourceHeaders: {'Referer': 'https://example.com'},
      ),
      const Song(
        id: 's2',
        title: '七里香',
        artist: '周杰伦',
        album: '七里香',
        duration: 299000,
        coverUrl: 'https://example.com/2.jpg',
        source: 'wy',
      ),
    ];
    final board = HotBoard(
      id: 'rank_1',
      name: '飙升榜',
      source: 'wy',
      coverUrl: 'https://example.com/cover.jpg',
      songs: songs,
    );

    test('序列化往返保留榜单与歌曲', () {
      final round = HotBoard.fromJson(board.toJson());
      expect(round.id, 'rank_1');
      expect(round.name, '飙升榜');
      expect(round.source, 'wy');
      expect(round.coverUrl, 'https://example.com/cover.jpg');
      expect(round.songs.length, 2);
      expect(round.songs.first.id, 's1');
      expect(round.songs.first.title, '晴天');
      expect(round.songs.first.coverUrl, 'https://example.com/1.jpg');
    });

    test('持久化时不带歌词与请求头', () {
      final json = board.toJson();
      final first = (json['songs'] as List).first as Map<String, dynamic>;
      expect(first.containsKey('lrc'), isFalse);
      expect(first.containsKey('sourceHeaders'), isFalse);
    });

    test('歌曲字段异常时跳过而不是整份失败', () {
      final round = HotBoard.fromJson({
        'id': 'rank_2',
        'name': '新歌榜',
        'source': 'tx',
        'songs': [
          'not a map',
          {'id': 's3', 'title': '稻香', 'artist': '周杰伦', 'album': '魔杰座'},
        ],
      });
      expect(round.songs.length, 1);
      expect(round.songs.single.id, 's3');
      expect(round.coverUrl, isNull);
    });
  });
}
