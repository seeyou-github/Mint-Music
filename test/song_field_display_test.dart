import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/utils/song_field_display.dart';
import 'package:mintmusic/shared/utils/song_match_score.dart';

Song _candidate({String album = '叶惠美'}) => Song(
  id: 'kw-1',
  title: '晴天',
  artist: '周杰伦',
  album: album,
  duration: 269,
  year: 2003,
  source: 'kw',
);

void main() {
  group('专辑字段口径', () {
    test('空值 / 老数据的「未知专辑」都算没有专辑', () {
      expect(hasAlbumInfo(null), isFalse);
      expect(hasAlbumInfo(''), isFalse);
      expect(hasAlbumInfo('   '), isFalse);
      expect(hasAlbumInfo('未知专辑'), isFalse);
      expect(hasAlbumInfo(' 未知专辑 '), isFalse);
      expect(hasAlbumInfo('叶惠美'), isTrue);
    });

    test('展示：没有专辑显示 -', () {
      expect(displayAlbum(null), '-');
      expect(displayAlbum(''), '-');
      expect(displayAlbum('未知专辑'), '-');
      expect(displayAlbum(' 叶惠美 '), '叶惠美');
    });

    test('编辑 / 匹配：没有专辑返回空串（不把 - 或占位写进文件）', () {
      expect(albumForEdit(null), '');
      expect(albumForEdit('未知专辑'), '');
      expect(albumForEdit(''), '');
      expect(albumForEdit('叶惠美'), '叶惠美');
    });
  });

  group('无专辑歌曲不参与专辑匹配', () {
    test('旧索引存「未知专辑」：不会被当成精确专辑', () {
      const local = LocalSongMatchFields(
        title: '晴天',
        artist: '周杰伦',
        album: '未知专辑',
        year: 2003,
        durationSeconds: 269,
      );
      // fromSong 会把占位清洗成空串。
      final fromSong = LocalSongMatchFields.fromSong(
        Song(
          id: 'local-1',
          title: '晴天',
          artist: '周杰伦',
          album: '未知专辑',
          duration: 269,
          year: 2003,
          source: 'local',
        ),
      );
      expect(fromSong.album, isEmpty);
      // 只有歌名 + 歌手 + 时长 + 年份命中 → 第 3 档，而不是五字段全中的第 1 档。
      expect(songMatchPriority(_candidate(), fromSong), 3);
      expect(songMatchPriority(_candidate(), local), 3);
    });

    test('候选专辑为空、本地专辑也为空：仍按专辑不匹配处理', () {
      const localNoAlbum = LocalSongMatchFields(
        title: '晴天',
        artist: '周杰伦',
        album: '',
        year: 2003,
        durationSeconds: 269,
      );
      expect(songMatchPriority(_candidate(album: ''), localNoAlbum), 3);
    });
  });
}
