import '../../core/constants/app_routes.dart';
import '../../features/player/domain/models/song.dart';

/// 「编辑标签」页的路由地址。
///
/// 带上文件路径：下载管理里播放的歌不在曲库索引里（下载目录通常不在
/// 「本地音乐」的扫描范围内），编辑标签页要靠这个路径现读标签，否则只会显示
/// 「未找到歌曲信息」。
String tagEditorLocationFor(Song song) {
  final buffer = StringBuffer('${AppRoutes.tagEditor}?songId=${song.id}');
  final path = song.filePath ?? '';
  if (path.isNotEmpty) {
    buffer.write('&path=${Uri.encodeComponent(path)}');
  }
  return buffer.toString();
}
