import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/features/download/application/download_providers.dart';
import 'package:mintmusic/features/download/data/download_record.dart';
import 'package:mintmusic/features/download/data/download_repository.dart';
import 'package:mintmusic/features/download/domain/models/download_task.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

/// 下载页删掉一首已下载的歌：
/// * 文件要真的没了；
/// * 任务要从列表里消失；
/// * 要通知下载页把「目录扫描结果」里的同一个路径过滤掉，否则同一首歌会
///   以「扫描到的文件」身份立刻重新出现（要点第二次删除才消失）。
void main() {
  late Directory root;
  late Directory downloadDir;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('mint_download_delete_');
    downloadDir = Directory('${root.path}/download_music');
    await downloadDir.create(recursive: true);
    AppPaths.debugRootOverride = root.path;
    await DownloadRecordStore.clear();
  });

  tearDown(() async {
    AppPaths.debugRootOverride = null;
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Future<(DownloadRepository, File)> prepare() async {
    final file = File('${downloadDir.path}/歌手 - 歌曲.mp3');
    await file.writeAsBytes(List<int>.generate(2048, (i) => i % 251));

    final song = Song(
      id: 'wy_1',
      title: '歌曲',
      artist: '歌手',
      album: '专辑',
      duration: 240,
      source: 'wy',
    );
    await DownloadRecordStore.save(
      DownloadTask(
        id: 'task-1',
        song: song,
        url: 'http://example.com/1.mp3',
        quality: '320k',
        filePath: file.path,
        status: DownloadStatus.completed,
        progress: 1,
        createdAt: 1,
      ),
    );

    final repo = DownloadRepository();
    await repo.init(downloadDir: downloadDir.path);
    return (repo, file);
  }

  test('删除已下载任务：文件删掉、任务消失、并通知过滤该路径', () async {
    final (repo, file) = await prepare();
    final removedPaths = <String>[];
    repo.onTasksRemoved = removedPaths.add;

    expect(repo.tasks, hasLength(1));
    // 恢复出来的任务 id 由记录派生（`disk:…`），界面用的也是这个。
    final taskId = repo.tasks.first.id;

    await repo.deleteTask(taskId, deleteFile: true);
    await pumpEventQueue();

    expect(await file.exists(), isFalse, reason: '文件必须真的被删掉');
    expect(repo.tasks, isEmpty, reason: '任务要立刻从列表里消失');
    expect(removedPaths, [file.path], reason: '要把路径交给下载页，过滤掉旧的目录扫描结果');
  });

  test('只清列表不删文件时不触发扫描过滤（文件还在，继续以扫描结果展示）', () async {
    final (repo, file) = await prepare();
    final removedPaths = <String>[];
    repo.onTasksRemoved = removedPaths.add;

    await repo.deleteTask(repo.tasks.first.id);
    await pumpEventQueue();

    expect(await file.exists(), isTrue);
    expect(repo.tasks, isEmpty);
    expect(removedPaths, isEmpty);
  });

  test('列表里的扫描结果会同时过滤「已有任务」和「刚删除」的文件', () {
    DownloadDirSong dirSong(String path) => DownloadDirSong(
      song: Song(
        id: path,
        title: '歌曲',
        artist: '歌手',
        album: '专辑',
        duration: 1,
        source: 'local',
        filePath: path,
      ),
      size: 1,
      modifiedAt: 1,
    );

    const kept = r'C:\Music\keep.mp3';
    const hasTask = r'C:\Music\task.mp3';
    const justDeleted = r'C:\Music\deleted.mp3';

    final result = filterDownloadDirSongs(
      [dirSong(kept), dirSong(hasTask), dirSong(justDeleted)],
      taskPaths: {normalizeDownloadPath(hasTask)},
      removedPaths: {normalizeDownloadPath(justDeleted)},
    );

    expect(result.map((item) => item.song.filePath), [kept]);
  });
}
