import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/download/domain/services/audio_tag_writer.dart';
import 'package:mintmusic/features/local/domain/services/local_song_from_file.dart';
import 'package:mintmusic/shared/utils/local_song_id.dart';

/// 下载管理里播放的歌不在曲库索引里，编辑标签页靠「按路径现读文件标签」
/// 兜底。这里验证兜底构造出来的歌曲对象：字段来自文件、id 与本地扫描一致。
void main() {
  test('按路径读出文件里的标签，id 与本地扫描算法一致', () async {
    final dir = await Directory.systemTemp.createTemp('mint_song_from_file');
    final file = File('${dir.path}${Platform.pathSeparator}未知文件.mp3');
    try {
      await file.writeAsBytes(
        Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
      );
      final written = await AudioTagWriter.write(
        file.path,
        title: '标签里的歌名',
        artist: '标签里的歌手',
        album: '标签里的专辑',
      );
      expect(written, isTrue);

      final song = await buildLocalSongFromFile(file.path);
      expect(song, isNotNull);
      expect(song!.title, '标签里的歌名');
      expect(song.artist, '标签里的歌手');
      expect(song.album, '标签里的专辑');
      expect(song.isLocal, isTrue);
      expect(song.filePath, file.path);
      expect(
        song.id,
        localSongIdForPath(file.path),
        reason: 'id 必须和本地扫描算出来的一样，封面 / 进度才对得上',
      );
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('文件里没有标签时用文件名当歌名', () async {
    final dir = await Directory.systemTemp.createTemp('mint_song_from_file2');
    final file = File('${dir.path}${Platform.pathSeparator}没有标签的歌.mp3');
    try {
      await file.writeAsBytes(
        Uint8List.fromList(List<int>.generate(2048, (i) => i % 251)),
      );
      final song = await buildLocalSongFromFile(file.path);
      expect(song, isNotNull);
      expect(song!.title, '没有标签的歌');
      expect(song.artist, '未知艺术家');
      expect(song.album, '未知专辑');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('文件不存在返回 null（页面会显示「未找到歌曲信息」）', () async {
    expect(await buildLocalSongFromFile(''), isNull);
    expect(
      await buildLocalSongFromFile(
        '${Directory.systemTemp.path}${Platform.pathSeparator}not-exists-xyz.mp3',
      ),
      isNull,
    );
  });
}
