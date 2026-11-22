import 'dart:io';

import '../../../player/domain/models/song.dart';
import '../../../../shared/utils/local_song_id.dart';
import '../../../../shared/utils/song_field_display.dart';
import '../../data/local_metadata_reader.dart';

/// 按文件路径构造一个「不在曲库索引里」的本地歌曲对象。
///
/// 用在编辑标签页：下载管理里播放的歌，文件在下载目录（通常不在「本地音乐」
/// 的扫描目录里），曲库里查不到这一行，只能现读文件标签。
///
/// id / coverKey 与本地扫描用同一套算法（[localSongIdForPath]）：万一这首歌
/// 其实已经被扫描进曲库，两边算出来是同一个 id，封面缓存和播放记录能对上。
Future<Song?> buildLocalSongFromFile(String filePath) async {
  if (filePath.isEmpty) return null;
  final file = File(filePath);
  bool exists;
  try {
    exists = await file.exists();
  } catch (_) {
    exists = false;
  }
  if (!exists) return null;

  final metadata = await LocalMetadataReader.read(filePath);
  final fileName = filePath.split(RegExp(r'[\\/]')).last;
  final dot = fileName.lastIndexOf('.');
  final baseName = dot > 0 ? fileName.substring(0, dot) : fileName;

  String pick(String? value, String fallback) {
    final text = value?.trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  return Song(
    id: localSongIdForPath(filePath),
    title: pick(metadata.title, baseName),
    artist: pick(metadata.artist, '未知艺术家'),
    // 没有专辑就留空：界面显示 `-`，不参与专辑匹配，也不会把「未知专辑」
    // 当成真实专辑写回文件。
    album: albumForEdit(metadata.album),
    duration: metadata.durationSeconds ?? 0,
    source: 'local',
    filePath: filePath,
    sourceUrl: filePath,
    hasCover: metadata.artwork != null,
    coverKey: localCoverKeyForPath(filePath),
    year: metadata.year,
    genre: metadata.genre,
    comment: metadata.comment,
  );
}
