import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/local/application/local_providers.dart';
import 'package:mintmusic/features/local/data/local_music_repository.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';

class _FakeRepo extends LocalMusicRepository {
  _FakeRepo(List<String> dirs) : _dirs = List.of(dirs);

  final List<String> _dirs;

  @override
  Future<void> init() async {}

  @override
  Future<bool> checkPermission() async => false;

  @override
  List<String> getScannedDirectories() => List.unmodifiable(_dirs);

  @override
  List<Song> getLocalSongs() => const <Song>[];

  @override
  Future<void> setDirectories(List<String> dirs) async {
    _dirs
      ..clear()
      ..addAll(dirs.where((d) => d.isNotEmpty));
  }

  @override
  Future<void> reorderDirectories(List<String> dirs) async {
    _dirs
      ..clear()
      ..addAll(dirs.where((d) => d.isNotEmpty));
  }
}

void main() {
  // 本地页目录栏、「全部 + 各目录」的滑动顺序都取自 scannedDirectoriesProvider，
  // 在设置弹框里拖完顺序后必须立刻按新顺序读出来。
  test('reorder is visible through scannedDirectoriesProvider', () async {
    final fake = _FakeRepo(['D:\\A', 'D:\\B', 'D:\\C']);
    final container = ProviderContainer(
      overrides: [localMusicRepositoryProvider.overrideWithValue(fake)],
    );
    addTearDown(container.dispose);

    expect(await container.read(scannedDirectoriesProvider.future), [
      'D:\\A',
      'D:\\B',
      'D:\\C',
    ]);

    await container
        .read(localMusicNotifierProvider.notifier)
        .reorderDirectories(['D:\\C', 'D:\\A', 'D:\\B']);

    expect(await container.read(scannedDirectoriesProvider.future), [
      'D:\\C',
      'D:\\A',
      'D:\\B',
    ]);
  });
}
