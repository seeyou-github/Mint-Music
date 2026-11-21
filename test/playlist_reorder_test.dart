import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/library/application/playlist_providers.dart';
import 'package:mintmusic/features/library/data/playlist_repository.dart';
import 'package:mintmusic/features/library/domain/models/playlist.dart';

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository(this.items);

  final List<Playlist> items;
  List<String>? savedOrder;

  @override
  Future<List<Playlist>> loadPlaylists() async => items;

  @override
  Future<void> reorderPlaylists(List<String> orderedIds) async {
    savedOrder = orderedIds;
  }
}

Playlist _playlist(String id) => Playlist(
  id: id,
  name: id,
  createTime: DateTime(2024, 1, 1),
  updateTime: DateTime(2024, 1, 1),
);

void main() {
  test('reorderPlaylists 立即换位、固定收藏在最前并落库', () async {
    final repo = _FakePlaylistRepository([
      _playlist('__favorites__'),
      _playlist('a'),
      _playlist('b'),
      _playlist('c'),
    ]);
    final container = ProviderContainer(
      overrides: [playlistRepositoryProvider.overrideWithValue(repo)],
    );
    addTearDown(container.dispose);

    await container.read(playlistsProvider.future);
    container.read(playlistsProvider.notifier).reorderPlaylists([
      'c',
      'a',
      'b',
    ]);

    expect(
      container.read(playlistsProvider).valueOrNull!.map((p) => p.id).toList(),
      ['__favorites__', 'c', 'a', 'b'],
    );

    await pumpEventQueue();
    expect(repo.savedOrder, ['c', 'a', 'b']);
  });
}
