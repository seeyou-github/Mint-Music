import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 本地音频文件的歌曲 id。
///
/// 同一条路径在「本地音乐扫描」「下载目录」「编辑标签」三处必须算出同一个 id：
/// 封面缓存、播放记录、播放进度都按这个 id 归属，算法一旦不同，同一首歌就会
/// 各存一份数据（换个页面封面要重新加载、进度也接不上）。
///
/// 路径先统一成正斜杠再哈希：Windows 上同一条路径可能混用 `\` 和 `/`。
String localSongIdForPath(String filePath) {
  final normalized = filePath.replaceAll('\\', '/');
  return md5.convert(utf8.encode(normalized)).toString().substring(0, 16);
}

/// 本地音频文件的封面缓存 key（与歌曲 id 分开，避免和封面库里的其它 key 撞）。
String localCoverKeyForPath(String filePath) {
  final normalized = filePath.replaceAll('\\', '/');
  return md5
      .convert(utf8.encode('cover_$normalized'))
      .toString()
      .substring(0, 16);
}
