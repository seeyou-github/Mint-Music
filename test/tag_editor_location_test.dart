import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/constants/app_routes.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/utils/local_song_id.dart';
import 'package:mintmusic/shared/utils/tag_editor_location.dart';

/// 下载管理里播放的歌不在曲库索引里，编辑标签页只能靠路径现读：
/// 跳转地址必须把文件路径一起带过去。
void main() {
  Song song({String id = 'wy_123', String? filePath}) => Song(
    id: id,
    title: '测试歌曲',
    artist: '测试歌手',
    album: '测试专辑',
    duration: 200,
    source: 'local',
    filePath: filePath,
  );

  test('带上文件路径，且路径能原样取回来', () {
    const path = r'D:\Program\2_Portable\music_mintmusic\AppData\download_music\A B - 测试.mp3';
    final location = tagEditorLocationFor(song(filePath: path));

    final uri = Uri.parse(location);
    expect(uri.path, AppRoutes.tagEditor);
    expect(uri.queryParameters['songId'], 'wy_123');
    expect(
      uri.queryParameters['path'],
      path,
      reason: '空格 / 中文 / 反斜杠都要能完整还原',
    );
  });

  test('没有文件路径时只带 songId', () {
    final location = tagEditorLocationFor(song());
    expect(location, contains('songId=wy_123'));
    expect(location, isNot(contains('path=')));
  });

  test('本地歌曲 id 只跟路径有关，反斜杠与正斜杠算出同一个 id', () {
    expect(
      localSongIdForPath(r'D:\Music\a.mp3'),
      localSongIdForPath('D:/Music/a.mp3'),
    );
    expect(localCoverKeyForPath(r'D:\Music\a.mp3'), isNot(localSongIdForPath(r'D:\Music\a.mp3')));
  });
}
