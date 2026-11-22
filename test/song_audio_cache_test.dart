import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/core/storage/app_database.dart';
import 'package:mintmusic/features/library/data/song_audio_cache.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:path/path.dart' as p;

Song _song(String id) => Song(
  id: id,
  title: '歌曲 $id',
  artist: '歌手',
  album: '专辑',
  duration: 200,
  source: 'kw',
);

/// MP3 帧同步头（0xFF Ex）+ 填充：足够让扩展名识别成 .mp3。
final List<int> _mp3Bytes = List<int>.filled(16, 0)
  ..[0] = 0xFF
  ..[1] = 0xFB;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;

  setUpAll(() async {
    tempRoot = await Directory.systemTemp.createTemp('song_audio_cache_');
    // 缓存目录 / 临时库都落在 <临时目录>/temp 下，避免写进 Flutter SDK 目录。
    AppPaths.debugRootOverride = tempRoot.path;
  });

  tearDownAll(() async {
    AppPaths.debugRootOverride = null;
    try {
      await tempRoot.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    SongAudioCache.debugDownloader = (url, savePath, headers) async {
      await File(savePath).writeAsBytes(_mp3Bytes);
      return true;
    };
    // 每个用例从「空缓存」开始。
    final db = await AppDatabase.cacheDatabase();
    await db.delete('audio_cache_entries');
    final dir = await SongAudioCache.directory();
    if (await dir.exists()) {
      for (final entity in dir.listSync()) {
        try {
          entity.deleteSync(recursive: true);
        } catch (_) {}
      }
    }
  });

  tearDown(() {
    SongAudioCache.debugDownloader = null;
  });

  test('写入后能查到文件，扩展名按文件头识别，索引只记一条', () async {
    final ok = await SongAudioCache.store(
      _song('a1'),
      url: 'https://cdn.example.com/a1.mp3',
      quality: '320k',
    );
    expect(ok, isTrue);

    final path = await SongAudioCache.findFile('a1');
    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
    expect(path.endsWith('.mp3'), isTrue);

    final entries = await SongAudioCache.entries();
    expect(entries.length, 1);
    expect(entries.single.songId, 'a1');
    expect(entries.single.quality, '320k');
    expect(entries.single.bytes, _mp3Bytes.length);
    expect(p.basename(path), entries.single.fileName);
  });

  test('已有缓存时不重复下载，只刷新使用时间', () async {
    var downloads = 0;
    SongAudioCache.debugDownloader = (url, savePath, headers) async {
      downloads++;
      await File(savePath).writeAsBytes(_mp3Bytes);
      return true;
    };

    await SongAudioCache.store(_song('a2'), url: 'https://x/a2.mp3');
    final first = (await SongAudioCache.entries()).single;

    // 把使用时间改到过去，确认命中会把它刷新回来。
    final db = await AppDatabase.cacheDatabase();
    await db.update(
      'audio_cache_entries',
      {'last_used_at': 1},
      where: 'song_id = ?',
      whereArgs: ['a2'],
    );

    await SongAudioCache.store(_song('a2'), url: 'https://x/a2.mp3');

    expect(downloads, 1, reason: '第二次应直接命中缓存');
    final refreshed = (await SongAudioCache.entries()).single;
    expect(refreshed.lastUsedAt, greaterThan(1));
    expect(refreshed.cachedAt, first.cachedAt);
  });

  test('音质不一致时不算命中，新音质会替换旧文件', () async {
    await SongAudioCache.store(
      _song('a3'),
      url: 'https://x/a3.mp3',
      quality: '128k',
    );
    expect(await SongAudioCache.findFile('a3', quality: '128k'), isNotNull);
    expect(await SongAudioCache.findFile('a3', quality: 'flac'), isNull);

    await SongAudioCache.store(
      _song('a3'),
      url: 'https://x/a3.flac',
      quality: 'flac',
    );

    final entries = await SongAudioCache.entries();
    expect(entries.single.quality, 'flac');
    final dir = await SongAudioCache.directory();
    final files = dir.listSync().whereType<File>().toList(growable: false);
    expect(files.length, 1, reason: '旧音质的文件要删掉，不能变成孤儿文件');
  });

  test('删除歌曲时同时删掉文件与索引', () async {
    await SongAudioCache.store(_song('a4'), url: 'https://x/a4.mp3');
    final path = await SongAudioCache.findFile('a4');
    expect(path, isNotNull);

    await SongAudioCache.remove('a4');

    expect(File(path!).existsSync(), isFalse);
    expect(await SongAudioCache.findFile('a4'), isNull);
    expect(await SongAudioCache.entries(), isEmpty);
  });

  test('文件被外部删掉后，查询会顺手清掉索引', () async {
    await SongAudioCache.store(_song('a5'), url: 'https://x/a5.mp3');
    final path = await SongAudioCache.findFile('a5');
    File(path!).deleteSync();

    expect(await SongAudioCache.findFile('a5'), isNull);
    expect(await SongAudioCache.entries(), isEmpty);
  });

  test('超过 200 首时淘汰最久没有听过的那首', () async {    // 第一首放到「很久以前」，其余 200 首都用当前时间。
    await SongAudioCache.store(_song('oldest'), url: 'https://x/old.mp3');
    final db = await AppDatabase.cacheDatabase();
    await db.update(
      'audio_cache_entries',
      {'last_used_at': 1},
      where: 'song_id = ?',
      whereArgs: ['oldest'],
    );
    for (var i = 0; i < SongAudioCache.maxEntries; i++) {
      final ok = await SongAudioCache.store(
        _song('bulk_$i'),
        url: 'https://x/bulk_$i.mp3',
      );
      expect(ok, isTrue);
    }

    final entries = await SongAudioCache.entries();
    expect(entries.length, SongAudioCache.maxEntries);
    expect(
      entries.any((entry) => entry.songId == 'oldest'),
      isFalse,
      reason: '最久没听过的那首应被淘汰',
    );
    expect(await SongAudioCache.findFile('oldest'), isNull);
  });

  test('真实 HTTP 下载：按文件头命名扩展名并写入索引', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      request.response.headers.contentType = ContentType('audio', 'mpeg');
      request.response.add(_mp3Bytes);
      await request.response.close();
    });
    // 这个用例要走真实下载链路（Dio），不要被上面的替身截住。
    SongAudioCache.debugDownloader = null;
    // flutter_test 默认把 HttpClient 换成「一律 400」的假实现：这里临时
    // 恢复真实实现，才能连本机回环地址。
    final previousOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    try {
      final ok = await SongAudioCache.store(
        _song('http1'),
        url: 'http://127.0.0.1:${server.port}/http1.mp3',
      );
      expect(ok, isTrue);

      final path = await SongAudioCache.findFile('http1');
      expect(path, isNotNull);
      expect(path!.endsWith('.mp3'), isTrue);
      expect(File(path).lengthSync(), _mp3Bytes.length);
    } finally {
      HttpOverrides.global = previousOverrides;
      await server.close(force: true);
    }
  });
}
