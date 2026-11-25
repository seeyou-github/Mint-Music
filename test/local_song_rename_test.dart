import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/local/domain/services/local_song_rename_service.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/utils/local_song_id.dart';
import 'package:path/path.dart' as p;

void main() {
  group('文件名工具', () {
    test('baseNameOf / extensionOf', () {
      expect(
        LocalSongRenameService.baseNameOf(r'D:\Music\tabi ASMR - 01.webm'),
        'tabi ASMR - 01',
      );
      expect(
        LocalSongRenameService.extensionOf(r'D:\Music\tabi ASMR - 01.webm'),
        '.webm',
      );
      // 名字里有点：只切最后一个
      expect(LocalSongRenameService.baseNameOf('/music/a.b.c.flac'), 'a.b.c');
      expect(LocalSongRenameService.extensionOf('/music/a.b.c.FLAC'), '.flac');
      // 没有扩展名
      expect(LocalSongRenameService.baseNameOf('/music/song'), 'song');
      expect(LocalSongRenameService.extensionOf('/music/song'), '');
    });

    test('renamedPath 保留目录与扩展名', () {
      expect(
        LocalSongRenameService.renamedPath(r'D:\Music\a.mp3', '新名字'),
        p.join(r'D:\Music', '新名字.mp3'),
      );
      expect(
        LocalSongRenameService.renamedPath('/music/a.weba', 'b'),
        p.join('/music', 'b.weba'),
      );
    });

    test('validate：合法 / 非法', () {
      expect(LocalSongRenameService.validate('正常名字'), isNull);
      expect(LocalSongRenameService.validate('a.b-c_d 123'), isNull);
      expect(LocalSongRenameService.validate(''), isNotNull);
      expect(LocalSongRenameService.validate('   '), isNotNull);
      expect(LocalSongRenameService.validate('a/b'), isNotNull);
      expect(LocalSongRenameService.validate('a:b'), isNotNull);
      expect(LocalSongRenameService.validate('a?b'), isNotNull);
      expect(LocalSongRenameService.validate('结尾点.'), isNotNull);
      expect(LocalSongRenameService.validate('结尾空格 '), isNotNull);
      expect(LocalSongRenameService.validate('CON'), isNotNull);
      expect(LocalSongRenameService.validate('nul'), isNotNull);
      expect(LocalSongRenameService.validate('a' * 181), isNotNull);
    });
  });

  group('renameFile', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('song_rename_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Song songFor(String path) => Song(
      id: localSongIdForPath(path),
      title: '内部标签的标题',
      artist: '歌手',
      album: '专辑',
      duration: 100,
      source: 'local',
      filePath: path,
      sourceUrl: path,
      coverKey: localCoverKeyForPath(path),
    );

    test('改名：文件真的换名，id / 路径 / 封面 key / sourceUrl 一起换，标签不动', () async {
      final oldPath = p.join(tempDir.path, 'old name.mp3');
      File(oldPath).writeAsBytesSync([1, 2, 3, 4]);
      final song = songFor(oldPath);

      final renamed = await LocalSongRenameService.renameFile(song, '新 名字');

      final newPath = p.join(tempDir.path, '新 名字.mp3');
      expect(File(newPath).existsSync(), isTrue);
      expect(File(oldPath).existsSync(), isFalse);
      expect(renamed.filePath, newPath);
      expect(renamed.id, localSongIdForPath(newPath));
      expect(renamed.id, isNot(song.id));
      expect(renamed.coverKey, localCoverKeyForPath(newPath));
      expect(renamed.sourceUrl, newPath);
      // 标签（标题 / 歌手 / 专辑）不属于文件名，不能跟着改。
      expect(renamed.title, '内部标签的标题');
      expect(renamed.artist, '歌手');
      expect(renamed.album, '专辑');
      // 扩展名保持原样
      expect(p.extension(renamed.filePath!), '.mp3');
    });

    test('名字没变时原样返回（不碰文件）', () async {
      final path = p.join(tempDir.path, 'same.mp3');
      File(path).writeAsBytesSync([1]);
      final song = songFor(path);
      final renamed = await LocalSongRenameService.renameFile(song, 'same');
      expect(identical(renamed, song), isTrue);
      expect(File(path).existsSync(), isTrue);
    });

    test('只改大小写也能改（Windows 大小写不敏感的文件系统）', () async {
      final oldPath = p.join(tempDir.path, 'Case Name.mp3');
      File(oldPath).writeAsBytesSync([7]);
      final song = songFor(oldPath);

      final renamed = await LocalSongRenameService.renameFile(song, 'case name');

      final newPath = p.join(tempDir.path, 'case name.mp3');
      expect(Directory(tempDir.path).listSync().whereType<File>(), hasLength(1));
      expect(File(newPath).existsSync(), isTrue);
      expect(renamed.filePath, newPath);
      expect(renamed.id, localSongIdForPath(newPath));
    });

    test('目标文件名已存在 → 报错且不动原文件', () async {
      final from = p.join(tempDir.path, 'a.mp3');
      final to = p.join(tempDir.path, 'b.mp3');
      File(from).writeAsBytesSync([1]);
      File(to).writeAsBytesSync([2]);

      await expectLater(
        LocalSongRenameService.renameFile(songFor(from), 'b'),
        throwsA(isA<LocalSongRenameException>()),
      );
      expect(File(from).existsSync(), isTrue);
      expect(File(to).readAsBytesSync(), [2]);
    });

    test('非法名字 → 报错（不合法字符 / 空）', () async {
      final path = p.join(tempDir.path, 'c.mp3');
      File(path).writeAsBytesSync([1]);
      await expectLater(
        LocalSongRenameService.renameFile(songFor(path), 'a/b'),
        throwsA(isA<LocalSongRenameException>()),
      );
      await expectLater(
        LocalSongRenameService.renameFile(songFor(path), '  '),
        throwsA(isA<LocalSongRenameException>()),
      );
      expect(File(path).existsSync(), isTrue);
    });

    test('文件不存在 → 报错', () async {
      final path = p.join(tempDir.path, 'missing.mp3');
      await expectLater(
        LocalSongRenameService.renameFile(songFor(path), 'x'),
        throwsA(isA<LocalSongRenameException>()),
      );
    });

    test('没有 filePath → 报错', () async {
      final song = Song(
        id: 'abc',
        title: 't',
        artist: 'a',
        album: '',
        duration: 0,
        source: 'local',
      );
      await expectLater(
        LocalSongRenameService.renameFile(song, 'x'),
        throwsA(isA<LocalSongRenameException>()),
      );
    });

    test('sourceUrl 不是文件路径时保持原样', () async {
      final oldPath = p.join(tempDir.path, 'd.mp3');
      File(oldPath).writeAsBytesSync([1]);
      final song = songFor(oldPath).copyWith(sourceUrl: r'D:\other\place.mp3');
      final renamed = await LocalSongRenameService.renameFile(song, 'e');
      expect(renamed.sourceUrl, r'D:\other\place.mp3');
    });
  });
}
