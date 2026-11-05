import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/current_route_provider.dart';
import 'playback_controller.dart';

/// 迷你播放器当前是否真的显示在屏幕上。
///
/// 两个条件同时成立才算可见：
/// * 有歌在播（没歌时 `MiniPlayer` 返回的是空占位，底部其实是空的）；
/// * 当前页面没有要求隐藏播放栏（设置 / 插件管理 / 下载 / 听歌识曲 / 最近播放）。
///
/// 页面底部留白、分页条、批量操作栏都按它算偏移，避免出现「播放栏已经
/// 藏起来了，底部还空着一大截」。
final miniPlayerVisibleProvider = Provider<bool>((ref) {
  final hasSong = ref.watch(
    playbackControllerProvider.select((s) => s.currentSong != null),
  );
  if (!hasSong) return false;
  return !ref.watch(miniPlayerHiddenProvider);
});
