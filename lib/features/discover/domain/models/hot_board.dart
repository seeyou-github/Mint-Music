import '../../../player/domain/models/song.dart';

/// 「热榜」分类里的一个榜单。
///
/// **只有 `id` / `name` / `source` / `coverUrl` 会被保存**（见
/// [toConfigJson]）；`songs` 每次进入「热榜」时从插件实时拉取，只留在内存里
/// （见 `HotBoardsNotifier.refreshSongs`），不写 settings.json、也不进数据库。
class HotBoard {
  const HotBoard({
    required this.id,
    required this.name,
    required this.source,
    this.coverUrl,
    this.songs = const [],
    this.songsLoading = false,
    this.songsError,
  });

  /// 榜单 id（插件来源的 id 可能带 `/`、`?`，只用作播放来源标记）。
  final String id;
  final String name;
  final String source;
  final String? coverUrl;

  /// 榜单前 10 首歌：**只在内存里**，进程存活期间复用，退出即丢。
  final List<Song> songs;

  /// 正在从插件拉取这个榜单的歌曲（卡片上显示转圈）。
  final bool songsLoading;

  /// 上一次拉取失败的原因（卡片上显示「点击重试」）。
  final String? songsError;

  /// 只保留「配置」：音源、榜单 id / 名称 / 封面。
  ///
  /// 歌曲不落盘：它们随时能从网络重取，存下来只会让每次改设置都把整份
  /// settings.json 重写一遍。
  Map<String, dynamic> toConfigJson() => {
    'id': id,
    'name': name,
    'source': source,
    if (coverUrl != null && coverUrl!.isNotEmpty) 'coverUrl': coverUrl,
  };

  factory HotBoard.fromConfigJson(Map<String, dynamic> json) => HotBoard(
    id: '${json['id'] ?? ''}',
    name: '${json['name'] ?? ''}',
    source: '${json['source'] ?? ''}',
    coverUrl: json['coverUrl'] as String?,
  );

  /// 兼容旧数据（老设置键 / 老备份里的 `hotboards.json` 带着 `songs`）。
  factory HotBoard.fromJson(Map<String, dynamic> json) {
    final rawSongs = json['songs'];
    return HotBoard(
      id: '${json['id'] ?? ''}',
      name: '${json['name'] ?? ''}',
      source: '${json['source'] ?? ''}',
      coverUrl: json['coverUrl'] as String?,
      songs: rawSongs is List
          ? [
              for (final item in rawSongs)
                if (item is Map) Song.fromJson(Map<String, dynamic>.from(item)),
            ]
          : const [],
    );
  }

  /// 只把 `songs` 换掉（配置不变），用于把实时拉到的歌曲合进内存。
  HotBoard withSongs(List<Song> songs, {String? error}) => HotBoard(
    id: id,
    name: name,
    source: source,
    coverUrl: coverUrl,
    songs: songs,
    songsError: error,
  );

  /// 标记成「正在拉取歌曲」。
  HotBoard withLoading() => HotBoard(
    id: id,
    name: name,
    source: source,
    coverUrl: coverUrl,
    songs: songs,
    songsLoading: true,
  );
}
