/// 内置音源（网易云 / 酷狗 / 酷我 / QQ / 咪咕）的用户可见状态。
///
/// 内置音源无法真正从程序里删除，这里把用户在插件管理页做的操作记成两份
/// id 集合：
///
/// * [disabled]：用户关掉了开关，音源只是不出现在音源选择器与搜索里；
/// * [removed]：用户点了「卸载」，音源从列表里消失，可通过「恢复内置音源」
///   一键找回。
///
/// 两者都不会影响已经存在歌曲的播放（收藏/歌单里已有的网易歌曲仍可解析）。
class BuiltInSourceStates {
  const BuiltInSourceStates({
    this.disabled = const <String>{},
    this.removed = const <String>{},
  });

  /// 被关闭的内置音源 id。
  final Set<String> disabled;

  /// 被「卸载」的内置音源 id。
  final Set<String> removed;

  /// 是否出现在音源选择器 / 搜索中。
  bool isAvailable(String sourceId) {
    return !disabled.contains(sourceId) && !removed.contains(sourceId);
  }

  bool isRemoved(String sourceId) => removed.contains(sourceId);

  bool isDisabled(String sourceId) => disabled.contains(sourceId);

  BuiltInSourceStates copyWith({
    Set<String>? disabled,
    Set<String>? removed,
  }) {
    return BuiltInSourceStates(
      disabled: disabled ?? this.disabled,
      removed: removed ?? this.removed,
    );
  }
}
