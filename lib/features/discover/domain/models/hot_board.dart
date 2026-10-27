import '../../../player/domain/models/song.dart';

/// 「热榜」分类里展示的内容：用户从当前音源榜单里挑的一个榜单的前 10 首歌。
class HotBoard {
  const HotBoard({
    required this.id,
    required this.name,
    required this.source,
    this.coverUrl,
    this.songs = const [],
  });

  /// 榜单 id（插件来源的 id 可能带 `/`、`?`，只用作播放来源标记）。
  final String id;
  final String name;
  final String source;
  final String? coverUrl;

  /// 榜单前 10 首歌。
  final List<Song> songs;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source': source,
    'coverUrl': coverUrl,
    'songs': [for (final song in songs) song.toPersistJson()],
  };

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
}
