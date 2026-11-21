import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/library/application/playlist_providers.dart';
import '../../features/player/domain/models/song.dart';
import 'song_row_hover.dart';

/// 歌曲行「时长左侧」的收藏红心。
///
/// * 鼠标悬停在这一行时一定出现：未收藏画空心红心，点一下直接收藏；
/// * 已收藏画实心红心，点一下取消收藏（[FavoriteSongs.favoriteIdOf]
///   会按文件路径认出本地歌曲，取消时要用它返回的 id，而不是本行 id）；
/// * [showWhenFavorited] 控制「鼠标没悬停时」要不要常驻显示已收藏的实心红心，
///   收藏的第三方歌单 / 专辑 / 作者传 false，只保留悬停入口。
///
/// 收藏 / 取消收藏都直接改 provider，不弹任何提示。
class SongFavoriteHeart extends ConsumerWidget {
  const SongFavoriteHeart({
    super.key,
    required this.song,
    this.showWhenFavorited = true,
  });

  final Song song;
  final bool showWhenFavorited;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hovered = SongRowHover.isHovered(context);
    final favoriteId = ref.watch(
      favoriteSongsProvider.select((favorites) => favorites.favoriteIdOf(song)),
    );
    final favorited = favoriteId != null;
    // 未收藏只在 hover 时出现空心；已收藏默认常驻实心（或在指定列表里只随
    // hover 出现）。
    final visible = favorited ? (hovered || showWhenFavorited) : hovered;
    if (!visible) return const SizedBox.shrink();

    final notifier = ref.read(playlistsProvider.notifier);
    return GestureDetector(
      // 吃掉点击，避免冒泡成整行的「播放」手势。
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (favorited) {
          unawaited(
            notifier.removeSongFromPlaylist('__favorites__', favoriteId),
          );
        } else {
          unawaited(notifier.addSongToPlaylist('__favorites__', song));
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Icon(
          favorited ? Icons.favorite : Icons.favorite_border,
          size: 14,
          color: Colors.red,
        ),
      ),
    );
  }
}
