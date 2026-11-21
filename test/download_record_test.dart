import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/features/download/data/download_record.dart';
import 'package:mintmusic/features/download/domain/models/download_task.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

/// 下载记录（`AppData\temp\db` 里的 `download_entries`）的完整生命周期：
/// 写入 → 查询 → 文件被删 → 标记不存在 → 删除记录。
///
/// 用临时目录当 `AppData`，不碰真实数据。
void main() {
  late Directory root;
  late Directory downloadDir;

  DownloadTask makeTask(
    Song song,
    String filePath, {
    String quality = '320k',
  }) {
    return DownloadTask(
      id: 'task-${song.id}',
      song: song,
      url: 'http://example.com/${song.id}.mp3',
      quality: quality,
      filePath: filePath,
      status: DownloadStatus.completed,
      progress: 1,
      createdAt: 1000,
    );
  }

  Song makeSong(String id, {String title = '歌曲', String artist = '歌手'}) {
    return Song(
      id: id,
      title: title,
      artist: artist,
      album: '专辑',
      duration: 240,
      source: 'wy',
      coverUrl: 'http://example.com/$id.jpg',
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mint_download_record_');
    downloadDir = Directory('${root.path}/download_music');
    await downloadDir.create(recursive: true);
    AppPaths.debugRootOverride = root.path;
    // 数据库是进程内单例，多个用例共用同一个文件：每个用例先清空。
    await DownloadRecordStore.clear();
  });

  tearDown(() async {
    AppPaths.debugRootOverride = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> writeAudio(String name, int bytes) async {
    final file = File('${downloadDir.path}/$name');
    await file.writeAsBytes(List<int>.generate(bytes, (i) => i % 251));
    return file;
  }

  test('写入后能按歌曲查到：路径、大小、文件存在、歌曲信息都在', () async {
    final file = await writeAudio('歌手 - 歌曲.mp3', 4096);
    await DownloadRecordStore.save(
      makeTask(makeSong('wy_1'), file.path),
    );

    final records = await DownloadRecordStore.findBySong('wy_1');
    expect(records, hasLength(1));
    final record = records.first;
    expect(record.filePath, file.path);
    // 大小取的是真实文件长度，不是下载过程中的字节数。
    expect(record.fileSize, 4096);
    expect(record.fileExists, isTrue);
    expect(record.quality, '320k');
    // 基本信息（重启后下载列表靠它复原）。
    expect(record.song.title, '歌曲');
    expect(record.song.artist, '歌手');
    expect(record.song.duration, 240);

    // 查得到可播文件。
    expect(await DownloadRecordStore.findPlayableFile('wy_1'), file.path);
  });

  test('文件被删掉：标记为不存在，且不再算「可播放的本地文件」', () async {
    final file = await writeAudio('歌手 - 歌曲.mp3', 1024);
    await DownloadRecordStore.save(makeTask(makeSong('wy_2'), file.path));
    await file.delete();

    // 记录还说「存在」，但实际文件没了：查询时自动纠正并返回 null。
    expect(await DownloadRecordStore.findPlayableFile('wy_2'), isNull);
    final records = await DownloadRecordStore.findBySong('wy_2');
    expect(records.single.fileExists, isFalse);
    // 下载列表里这条显示为「文件不存在」。
    final task = records.single.toTask();
    expect(task.status, DownloadStatus.fileMissing);
  });

  test('已标记不存在的记录不会再被尝试（即使文件又出现了）', () async {
    final file = await writeAudio('a.mp3', 512);
    await DownloadRecordStore.save(makeTask(makeSong('wy_3'), file.path));
    await DownloadRecordStore.markMissing('wy_3', file.path);
    expect(await DownloadRecordStore.findPlayableFile('wy_3'), isNull);
  });

  test('同一首歌不同音质两条记录，取最近更新的一条', () async {
    final mp3 = await writeAudio('a.mp3', 100);
    final flac = await writeAudio('a.flac', 200);
    await DownloadRecordStore.save(
      makeTask(makeSong('wy_4'), mp3.path, quality: '320k'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await DownloadRecordStore.save(
      makeTask(makeSong('wy_4'), flac.path, quality: 'flac'),
    );

    final records = await DownloadRecordStore.findBySong('wy_4');
    expect(records, hasLength(2));
    expect(records.first.filePath, flac.path);
    expect(await DownloadRecordStore.findPlayableFile('wy_4'), flac.path);
  });

  test('删除单条记录 / 清空整表', () async {
    final a = await writeAudio('a.mp3', 100);
    final b = await writeAudio('b.mp3', 100);
    await DownloadRecordStore.save(makeTask(makeSong('wy_5'), a.path));
    await DownloadRecordStore.save(makeTask(makeSong('wy_6'), b.path));
    expect(await DownloadRecordStore.all(), hasLength(2));

    await DownloadRecordStore.deleteByPath(a.path);
    expect(await DownloadRecordStore.findBySong('wy_5'), isEmpty);
    expect(await DownloadRecordStore.findBySong('wy_6'), hasLength(1));

    await DownloadRecordStore.clear();
    expect(await DownloadRecordStore.all(), isEmpty);
  });

  test('重新下载覆盖同一条记录（同一歌曲 + 同一路径）', () async {
    final file = await writeAudio('a.mp3', 100);
    await DownloadRecordStore.save(makeTask(makeSong('wy_7'), file.path));
    await file.writeAsBytes(List<int>.generate(300, (i) => i % 251));
    await DownloadRecordStore.save(makeTask(makeSong('wy_7'), file.path));

    final records = await DownloadRecordStore.findBySong('wy_7');
    expect(records, hasLength(1));
    expect(records.single.fileSize, 300);
  });
}
