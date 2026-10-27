class Leaderboard {
  final String id;
  final String name;
  final String? coverUrl;
  final String? playCount;
  final String? updateFrequency;
  final String source;

  const Leaderboard({
    required this.id,
    required this.name,
    this.coverUrl,
    this.playCount,
    this.updateFrequency,
    this.source = 'wy',
  });
}

class PlaylistTag {
  final String id;
  final String name;
  final String source;

  const PlaylistTag({required this.id, required this.name, this.source = 'wy'});

  /// 置顶分类的 id 前缀。
  ///
  /// 带此前缀的分类会排在「热门」分类**之前**显示——插件可以借此把自己的
  /// 推荐分类放到分类栏最前面（例如网易云插件的「推荐」歌单）。
  static const String pinnedIdPrefix = '__pinned__';

  /// 是否是置顶分类。
  bool get isPinned => id.startsWith(pinnedIdPrefix);
}

class PlaylistTagGroup {
  final String name;
  final List<PlaylistTag> tags;

  const PlaylistTagGroup({required this.name, required this.tags});
}
