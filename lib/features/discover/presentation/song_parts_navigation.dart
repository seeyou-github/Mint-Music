import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../player/domain/models/song.dart';
import '../domain/models/search_collection.dart';

/// 多 P 视频（视频选集）在歌曲列表里被点击时，直接打开专辑页列出全部分 P。
///
/// 返回 false 表示这首歌不是多 P（或缺少插件原始数据 / 已是本地文件），
/// 调用方继续按正常逻辑播放。
bool openSongPartsIfNeeded(BuildContext context, Song song) {
  if (song.partsCount <= 1) return false;
  if (song.source == null ||
      song.source == 'local' ||
      (song.filePath?.isNotEmpty ?? false)) {
    return false;
  }
  final extra = song.lx?['extra'];
  final raw = extra is Map ? extra['musicItem'] : null;
  if (raw is! Map) return false;
  // 用「歌曲原本归属」的音源：播放过的歌 source 已被换成播放源（可能只有
  // musicUrl），拿它去查分P专辑必然失败。
  final source = song.metadataSourceId;
  if (source == null || source.isEmpty) return false;

  final rawMap = raw.map((key, value) => MapEntry('$key', value));
  final id = '${rawMap['bvid'] ?? rawMap['aid'] ?? song.id}';
  if (id.isEmpty) return false;
  final title = '${rawMap['title'] ?? rawMap['name'] ?? song.title}';

  context.push(
    '${AppRoutes.collectionDetail}?type=album&id=${Uri.encodeComponent(id)}',
    extra: SearchCollection(
      id: id,
      title: title,
      type: CollectionType.album,
      source: source,
      coverUrl: song.coverUrl,
      artist: song.artist,
      worksNum: song.partsCount,
      date: rawMap['date'] is String ? rawMap['date'] as String : null,
      raw: rawMap,
    ),
  );
  return true;
}
