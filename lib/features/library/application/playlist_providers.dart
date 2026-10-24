import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/playlist_sync_service.dart';
import '../../../core/backup/playlist_sync_status.dart';
import '../../../core/backup/webdav_service.dart';
import '../../settings/application/settings_providers.dart';
import '../data/playlist_repository.dart';
import '../domain/models/playlist.dart';
import '../utils/favorite_playlist.dart';
import '../../player/domain/models/song.dart';

final playlistRepositoryProvider = Provider<PlaylistRepository>((ref) {
  return PlaylistRepository();
});

/// 立即同步一次歌单（拉取远端 + 合并 + 回推），并把过程写到全局同步状态，
/// 让窗口底部显示「正在同步 / 同步完成 / 同步失败」。
///
/// 返回失败原因；成功返回 null。
Future<String?> syncPlaylistsNow(WidgetRef ref) async {
  final config = ref.read(webDavConfigProvider);
  final status = ref.read(playlistSyncStatusProvider.notifier);
  if (!config.isConfigured) {
    const message = '未配置 WebDAV：请先在「设置 → 备份还原」中填写 WebDAV 地址';
    status.fail(message);
    return message;
  }
  status.start();
  try {
    // 先确保本地歌单已就绪（首次启动会创建「我的收藏」），避免用空数据覆盖远端。
    await ref.read(playlistsProvider.future);
    await PlaylistSyncService.pullAndMerge(WebDavService(config));
    ref.invalidate(playlistsProvider);
    status.succeed();
    return null;
  } catch (e) {
    final message = describeWebDavError(e);
    status.fail(message);
    return message;
  }
}

final playlistsProvider =
    AsyncNotifierProvider<PlaylistsNotifier, List<Playlist>>(
      PlaylistsNotifier.new,
    );

class PlaylistsNotifier extends AsyncNotifier<List<Playlist>> {
  @override
  Future<List<Playlist>> build() async {
    final repo = ref.read(playlistRepositoryProvider);
    return repo.loadPlaylists();
  }

  /// 收藏入库存的歌：清掉会过期的播放地址 / 请求头 / 音质标记。
  ///
  /// **音源绑定保持收藏时的原样**：内置源（平台 id）就绑内置源，插件源
  /// （`平台id@插件id`）保持插件绑定——不落成「实际解析播放」的用户插件。
  /// 之后从收藏播放时按优先音源 / 会话手动音源 / 回退链解析，与内置源
  /// 歌曲的行为完全一致。
  Song _songForStorage(Song song) {
    if (song.sourceUrl == null &&
        song.sourceHeaders == null &&
        song.sourceQuality == null) {
      return song;
    }
    return song.copyWith(
      clearSourceUrl: true,
      clearSourceHeaders: true,
      clearSourceQuality: true,
    );
  }

  Future<void> createPlaylist(String name, {String description = ''}) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.createPlaylist(name, description: description);
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> createPlaylistWithSongs(
    String name,
    List<Map<String, dynamic>> songsData, {
    String description = '',
    String? source,
    String? coverImgUrl,
  }) async {
    final repo = ref.read(playlistRepositoryProvider);
    // 收藏保持「收藏时的音源」：内置源绑内置源，插件源保持插件绑定。
    // 专辑 / 作者描述标记里的音源同步为传入的音源（相同则原样）。
    await repo.createPlaylistWithSongs(
      name,
      songsData,
      description: upgradeFavoriteMarkerSource(description, source),
      source: source,
      coverImgUrl: coverImgUrl,
    );
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> createPlaylistFromModel(Playlist playlist) async {
    final repo = ref.read(playlistRepositoryProvider);
    // 音源保持歌单自己的 source（内置源绑内置源），不落成实际播放的插件。
    await repo.savePlaylist(playlist);
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> updatePlaylist(Playlist playlist) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.updatePlaylist(playlist);
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<void> deletePlaylist(String id) async {
    final repo = ref.read(playlistRepositoryProvider);
    await repo.deletePlaylist(id);
    ref.invalidateSelf();
    _syncToRemote();
  }

  /// 把本地歌单推送到 WebDAV 远端（开启了「歌单实时同步」时）。
  /// 5 秒防抖：连续增删改只会在最后一次操作后同步一次。
  void _syncToRemote() {
    final config = ref.read(webDavConfigProvider);
    if (!config.playlistSyncEnabled || !config.isConfigured) return;
    final status = ref.read(playlistSyncStatusProvider.notifier);
    PlaylistSyncService.schedulePush(
      WebDavService(config),
      // 真正开始推送时才显示提示（前面的 5 秒是防抖等待，还没发请求）。
      onStart: status.start,
      onFinish: (ok, error) {
        if (ok) {
          status.succeed();
        } else {
          status.fail(describeWebDavError(error ?? '未知错误'));
        }
      },
    );
  }

  /// Returns true if the song was actually added (not a duplicate).
  Future<bool> addSongToPlaylist(String playlistId, Song song) async {
    final repo = ref.read(playlistRepositoryProvider);
    try {
      final added = await repo.addSongToPlaylist(
        playlistId,
        _songForStorage(song),
      );
      ref.invalidateSelf();
      if (added) _syncToRemote();
      return added;
    } catch (e) {
      // ignore: avoid_print
      print('addSongToPlaylist error: $e');
      ref.invalidateSelf();
      rethrow;
    }
  }

  Future<void> removeSongFromPlaylist(String playlistId, String songId) async {
    // 先同步更新内存状态：Dismissible 的 onDismissed 要求被滑出的条目
    // 在当帧就从列表中移除，否则触发 "A dismissed Dismissible widget is
    // still part of the tree" 断言 → debug 模式闪红屏。
    // 磁盘持久化随后异步完成，成功后 invalidateSelf 从磁盘重读保持一致；
    // 失败时 finally 中 invalidateSelf 回滚为磁盘真实状态。
    final current = state.valueOrNull;
    if (current != null) {
      state = AsyncData(
        current
            .map(
              (p) => p.id == playlistId
                  ? p.copyWith(
                      songs: p.songs.where((s) => s.id != songId).toList(),
                    )
                  : p,
            )
            .toList(),
      );
    }
    final repo = ref.read(playlistRepositoryProvider);
    try {
      await repo.removeSongFromPlaylist(playlistId, songId);
    } catch (e) {
      // ignore: avoid_print
      print('removeSongFromPlaylist error: $e');
    } finally {
      ref.invalidateSelf();
      _syncToRemote();
    }
  }

  Future<void> addSongsToPlaylist(String playlistId, List<Song> songs) async {
    final repo = ref.read(playlistRepositoryProvider);
    for (final song in songs) {
      await repo.addSongToPlaylist(playlistId, _songForStorage(song));
    }
    ref.invalidateSelf();
    _syncToRemote();
  }

  Future<String> exportPlaylist(Playlist playlist) async {
    final repo = ref.read(playlistRepositoryProvider);
    return repo.exportPlaylist(playlist);
  }

  Future<Playlist> importPlaylist(String jsonString) async {
    final repo = ref.read(playlistRepositoryProvider);
    final playlist = await repo.importPlaylist(jsonString);
    ref.invalidateSelf();
    _syncToRemote();
    return playlist;
  }
}
