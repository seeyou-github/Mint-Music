import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 拖动播放进度条时的歌词预览位置。
///
/// 拖动过程中只更新歌词视图，不真正 seek 音频；松手后才提交 seek。
/// 为空表示当前没有拖动预览，歌词视图使用真实播放位置。
final seekPreviewPositionProvider = StateProvider.autoDispose<Duration?>(
  (ref) => null,
);
