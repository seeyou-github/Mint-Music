import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/playlist_sync_service.dart';
import '../../../core/backup/playlist_sync_status.dart';
import '../../../core/backup/sync_timeout.dart';
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
    // 整次同步套 1 分钟超时：服务器连上了却不回话时不能一直挂着。
    // 整次同步套 1 分钟超时：服务器连上了却不回话时不能一直挂着；
    // 超时会连带取消底层 HTTP 请求。
    final op = SyncAttempt(1);
    await op.run(() async {
      await ref.read(playlistsProvider.future);
      await PlaylistSyncService.pullAndMerge(
        WebDavService(config, cancelToken: op.cancelToken),
      );
    }());
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

/// 「我的收藏」索引：歌曲列表项据此显示收藏红心。
final favoriteSongsProvider = Provider<FavoriteSongs>((ref) {
  final playlists = ref.watch(playlistsProvider).valueOrNull;
  final favorites = playlists
      ?.where((playlist) => playlist.id == '__favorites__')
      .firstOrNull;
  return FavoriteSongs(favorites?.songs ?? const <Song>[]);
});

/// 「我的收藏」里的歌曲：先按歌曲 id 匹配，本地歌曲再按文件路径兜底。
///
/// 本地歌曲的 id 是扫描时按文件路径算出来的 md5，收藏里存的是收藏那一刻的
/// id。文件改名 / 换存储目录 / 旧版本数据都可能让两边的 id 对不上，只按 id
/// 判断会出现「明明收藏了，本地页面和最近播放里却没有红心」。所以本地歌曲
/// 额外用文件路径认一次：只要还是同一个文件，就算已收藏。
class FavoriteSongs {
  factory FavoriteSongs(List<Song> songs) {
    final ids = <String>{};
    final localPathIds = <String, String>{};
    for (final song in songs) {
      ids.add(song.id);
      if (!song.isLocal) continue;
      final key = localSongPathKey(song.filePath ?? song.sourceUrl);
      if (key != null) localPathIds[key] = song.id;
    }
    return FavoriteSongs._(ids, localPathIds);
  }

  const FavoriteSongs._(this._ids, this._localPathIds);

  final Set<String> _ids;

  /// 归一化后的文件路径 → 收藏里那首歌的 id。
  final Map<String, String> _localPathIds;

  /// 收藏里这首歌的 id：列表项用它判断红心、取消收藏时也用它。
  ///
  /// 没收藏返回 null。
  String? favoriteIdOf(Song song) {
    if (_ids.contains(song.id)) return song.id;
    if (!song.isLocal) return null;
    final key = localSongPathKey(song.filePath ?? song.sourceUrl);
    return key == null ? null : _localPathIds[key];
  }
}

/// 本地歌曲按文件路径比对的键：统一分隔符与大小写（Windows 盘符 / 路径
/// 大小写不敏感，Android 上也无副作用）。
String? localSongPathKey(String? path) {
  final trimmed = path?.trim();
  if (trimmed == null || trimmed.isEmpty) return null;
  return trimmed.replaceAll('\\', '/').toLowerCase();
}

class PlaylistsNotifier extends AsyncNotifier<List<Playlist>> {
  @override
  Future<List<Playlist>> build() async {
    final repo = ref.read(playlistRepositoryProvider);
    return repo.loadPlaylists();
  }

  /// 收藏入库存的歌：清掉会过期的播放地址 / 请求头 / 音质标记。
  ///
  /// **音源绑定保持收藏时的原样**：裸平台 id 保持平台 id，插件源
  /// （`平台id@插件id`）保持插件绑定——不落成「实际解析播放」的插件。
  /// 之后从收藏播放时按优先音源 / 会话手动音源 / 回退链解析，与平台歌曲
  /// 的行为完全一致。
  Song _songForStorage(Song song) {
    // 本地歌曲的 sourceUrl 就是文件路径：清掉后从收藏里再也放不出来。
    if (song.isLocal) return song;
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
    // 收藏保持「收藏时的音源」：裸平台 id 保持平台 id，插件源保持插件绑定。
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
    // 音源保持歌单自己的 source，不落成实际播放的插件。
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

  /// 调整歌单顺序：先同步更新内存状态让弹窗 / 收藏页立即换位，再落库。
  ///
  /// 「我的收藏」始终固定在最前，[orderedIds] 里即使带了它也会被跳过。
  void reorderPlaylists(List<String> orderedIds) {
    final current = state.valueOrNull;
    if (current == null) return;
    final byId = {for (final playlist in current) playlist.id: playlist};
    final favorites = [
      for (final playlist in current)
        if (playlist.id == '__favorites__') playlist,
    ];
    // 先把「我的收藏」从待排列表里摘掉，最后再固定放回最前，
    // 否则它会同时出现在开头和末尾。
    byId.remove('__favorites__');
    final ordered = <Playlist>[
      ...favorites,
      for (final id in orderedIds)
        if (id != '__favorites__' && byId[id] != null) byId.remove(id)!,
      ...byId.values,
    ];
    state = AsyncData(ordered);
    unawaited(_persistPlaylistOrder(orderedIds));
  }

  Future<void> _persistPlaylistOrder(List<String> orderedIds) async {
    try {
      await ref.read(playlistRepositoryProvider).reorderPlaylists(orderedIds);
    } catch (e) {
      debugPrint('[Playlists] 保存歌单排序失败: $e');
    }
  }

  /// 本地歌单增删改后自动同步（开启了「自动同步」时）。
  ///
  /// 与收藏页顶部同步按钮一致：先拉取远端合并，再把结果推回去。
  /// 5 秒防抖：连续增删改只会在最后一次操作后同步一次。
  void _syncToRemote() {
    final config = ref.read(webDavConfigProvider);
    if (!config.playlistSyncEnabled || !config.isConfigured) return;
    final status = ref.read(playlistSyncStatusProvider.notifier);
    PlaylistSyncService.scheduleSync(
      config,
      // 真正开始同步时才显示提示（前面的 5 秒是防抖等待，还没发请求）。
      onStart: status.start,
      onFinish: (ok, error) {
        if (ok) {
          // 远端可能有本机没有的歌单 / 歌曲，合并后要刷新界面。
          try {
            ref.invalidateSelf();
          } catch (_) {
            // notifier 已销毁（页面关了）时忽略。
          }
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
    // 批量加歌走一个事务：逐首加的话每首都要查一遍歌单，几百首会很慢。
    await repo.addSongsToPlaylist(playlistId, [
      for (final song in songs) _songForStorage(song),
    ]);
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
