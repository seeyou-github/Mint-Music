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

Future<void> _pump(
  WidgetTester tester,
  Song song, {
  required bool alwaysShow,
}) async {
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
            child: SongListItem(
              song: song,
              index: 1,
              maxIndex: 1,
              alwaysShowFavoriteHeart: alwaysShow,
            ),
          ),
        ),
      ),
    ),
  );
  // 等 playlistsProvider 把收藏加载完。
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('常驻红心：已收藏实心、未收藏空心', (tester) async {
    await _pump(tester, _song('fav'), alwaysShow: true);
    expect(find.byIcon(Icons.favorite), findsOneWidget);
    expect(find.byIcon(Icons.favorite_border), findsNothing);

    await _pump(tester, _song('other'), alwaysShow: true);
    expect(find.byIcon(Icons.favorite_border), findsOneWidget);
  });

  testWidgets('关闭常驻红心：没有悬停时不显示', (tester) async {
    await _pump(tester, _song('other'), alwaysShow: false);
    expect(find.byIcon(Icons.favorite_border), findsNothing);
  });
}
