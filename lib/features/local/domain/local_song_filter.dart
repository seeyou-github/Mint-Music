import '../../player/domain/models/song.dart';
import '../../player/domain/services/lyric_parser.dart';

/// 快速匹配页里可以筛选 / 展示的字段。
enum LocalSongField {
  cover,
  title,
  artist,
  album,
  year,
  genre,
  comment,
  lyric,
  wordLyric,
}

/// 每个字段的筛选状态：不过滤 / 只看有 / 只看没有。
enum FieldFilter { any, has, lacks }

/// 一首歌的歌词状态（内嵌歌词 + 歌词缓存合并后的结果）。
class LyricPresence {
  const LyricPresence({required this.hasLyric, required this.hasWordLyric});

  final bool hasLyric;
  final bool hasWordLyric;

  static const LyricPresence none = LyricPresence(
    hasLyric: false,
    hasWordLyric: false,
  );
}

/// 点一次切换一次：不过滤 → 有 → 无 → 不过滤。
FieldFilter nextFieldFilter(FieldFilter current) {
  return switch (current) {
    FieldFilter.any => FieldFilter.has,
    FieldFilter.has => FieldFilter.lacks,
    FieldFilter.lacks => FieldFilter.any,
  };
}

/// 这首歌的某个字段「有没有值」。
///
/// 「未知艺术家 / 未知专辑 / 未知曲目」是扫描时补的占位文案，按「没有」处理。
bool songHasField(Song song, LocalSongField field, {LyricPresence? lyric}) {
  switch (field) {
    case LocalSongField.cover:
      return (song.coverUrl ?? '').isNotEmpty || song.hasCover;
    case LocalSongField.title:
      return song.title.trim().isNotEmpty && song.title != '未知曲目';
    case LocalSongField.artist:
      return song.artist.trim().isNotEmpty &&
          song.artist != '未知艺术家' &&
          song.artist != '未知歌手';
    case LocalSongField.album:
      return song.album.trim().isNotEmpty && song.album != '未知专辑';
    case LocalSongField.year:
      return (song.year ?? 0) > 0;
    case LocalSongField.genre:
      return (song.genre ?? '').trim().isNotEmpty;
    case LocalSongField.comment:
      return (song.comment ?? '').trim().isNotEmpty;
    case LocalSongField.lyric:
      return lyric?.hasLyric ?? song.hasLyric;
    case LocalSongField.wordLyric:
      return lyric?.hasWordLyric ?? song.hasWordLyric;
  }
}

/// 按目录 + 字段筛选歌曲（顺序保持传入顺序，由调用方自己排序）。
List<Song> filterLocalSongs(
  List<Song> songs, {
  String directory = '',
  Map<LocalSongField, FieldFilter> filters = const {},
  Map<String, LyricPresence> lyricStatus = const {},
}) {
  final result = <Song>[];
  // 目录要按「目录边界」匹配：`D:/Music` 不能把 `D:/Music2/a.mp3` 也算进去。
  final prefix = directory.isEmpty
      ? ''
      : (directory.endsWith('/') || directory.endsWith('\\')
            ? directory
            : '$directory/');
  final altPrefix = prefix.isEmpty
      ? ''
      : (prefix.endsWith('/')
            ? '${prefix.substring(0, prefix.length - 1)}\\'
            : prefix);
  for (final song in songs) {
    if (prefix.isNotEmpty) {
      final path = song.filePath ?? '';
      if (!path.startsWith(prefix) && !path.startsWith(altPrefix)) continue;
    }
    var keep = true;
    for (final entry in filters.entries) {
      if (entry.value == FieldFilter.any) continue;
      final has = songHasField(song, entry.key, lyric: lyricStatus[song.id]);
      if (entry.value == FieldFilter.has ? !has : has) {
        keep = false;
        break;
      }
    }
    if (keep) result.add(song);
  }
  return result;
}

/// 从歌词文本判断是不是逐字歌词（普通 LRC 返回 false）。
bool isWordLyricText(String? text) {
  final value = (text ?? '').trim();
  if (value.isEmpty) return false;
  return detectWordLyricFormat(value) != null;
}

/// 从文件路径 / 文件名里提取搜索词：去掉目录与扩展名，分隔符换成空格。
String filenameKeyword(String path) {
  var name = path;
  final slash = name.lastIndexOf(RegExp(r'[/\\]'));
  if (slash >= 0) name = name.substring(slash + 1);
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  return name
      .replaceAll(RegExp(r'[_\.]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
