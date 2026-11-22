import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/library/application/playlist_providers.dart';
import 'package:mintmusic/features/library/data/playlist_repository.dart';
import 'package:mintmusic/features/library/domain/models/playlist.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/shared/widgets/song_list_item.dart';

class _FakePlaylistRepository extends PlaylistRepository {
  _FakePlaylistRepository(this.items);

  final List<Playlist> items;

  @override
  Future<List<Playlist>> loadPlaylists() async => items;
}

Song _song(String id) => Song(
  id: id,
  title: '歌 $id',
  artist: '歌手',
  album: '',
  duration: 200,
  source: 'wy',
);

Future<void> _pump(WidgetTester tester, Song song) async {
  final favorite = _song('fav');
  final repo = _FakePlaylistRepository([
    Playlist(
      id: '__favorites__',
      name: '我的收藏',
      createTime: DateTime(2024, 1, 1),
      updateTime: DateTime(2024, 1, 1),
      songs: [favorite],
    ),
  ]);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [playlistRepositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 480,
            child: SongListItem(song: song, index: 1, maxIndex: 1),
          ),
        ),
      ),
    ),
  );
  // 等 playlistsProvider 把收藏加载完。
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('已收藏的歌：实心红心常驻（不需要悬停）', (tester) async {
    await _pump(tester, _song('fav'));
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });

  testWidgets('未收藏的歌：没有悬停时不显示空心', (tester) async {
    await _pump(tester, _song('other'));
    expect(find.byIcon(Icons.favorite_border), findsNothing);
    expect(find.byIcon(Icons.favorite), findsNothing);
  });
}
