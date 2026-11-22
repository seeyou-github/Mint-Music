import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/library/application/playlist_providers.dart';
import '../../features/player/domain/models/song.dart';
import 'song_row_hover.dart';

/// 歌曲行「时长左侧」的收藏红心。
///
/// * 已收藏画实心红心，点一下取消收藏（[FavoriteSongs.favoriteIdOf]
///   会按文件路径认出本地歌曲，取消时要用它返回的 id，而不是本行 id）；
/// * 未收藏画空心红心，点一下直接收藏；
/// * [alwaysShow] 为 true 时不管有没有悬停都常驻显示（浏览类列表用：一眼能
///   看出哪些已收藏，也能直接在行内收藏）；为 false 时只在悬停时出现空心，
///   已收藏的实心是否常驻由 [showWhenFavorited] 决定。
///
/// 收藏 / 取消收藏都直接改 provider，不弹任何提示。
class SongFavoriteHeart extends ConsumerWidget {
  const SongFavoriteHeart({
    super.key,
    required this.song,
    this.showWhenFavorited = true,
    this.alwaysShow = false,
  });

  final Song song;
  final bool showWhenFavorited;
  final bool alwaysShow;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hovered = SongRowHover.isHovered(context);
    final favoriteId = ref.watch(
      favoriteSongsProvider.select((favorites) => favorites.favoriteIdOf(song)),
    );
    final favorited = favoriteId != null;
    final visible =
        alwaysShow || (favorited ? (hovered || showWhenFavorited) : hovered);
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
          // 常驻的空心调淡一些，避免整列都是抢眼的红色。
          color: favorited
              ? Colors.red
              : Colors.red.withValues(alpha: hovered ? 1.0 : 0.6),
        ),
      ),
    );
  }
}
