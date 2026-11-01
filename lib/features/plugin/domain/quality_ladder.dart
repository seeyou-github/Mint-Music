import 'plugin_types.dart';

/// 音质档位从低到高的标准顺序。
///
/// 只用于「比较两档谁高」和「找不到时往上/往下挪一格」，不用于展示。
/// 插件没声明过的 key 一律排在最后（rank 0 视为未知）。
const List<String> musicQualityOrder = [
  '64k',
  '128k',
  '192k',
  '320k',
  'flac',
  'flac24bit',
  'hires',
  'atmos',
  'master',
];

/// 音质高低排名（越大越高）；未知音质返回 0。
///
/// 别名会先归一化（`high` → `320k`、`lossless` → `flac` 等）。
int musicQualityRankOf(String quality) {
  final key = musicQualityKey(quality);
  final index = musicQualityOrder.indexOf(key);
  return index < 0 ? 0 : index + 1;
}

/// [actual] 是否比 [requested] 低（服务器降级）。
///
/// 任一档无法识别时返回 false——宁可当作「没降级」，也不要误报。
bool isQualityDowngrade(String requested, String actual) {
  final requestedRank = musicQualityRankOf(requested);
  final actualRank = musicQualityRankOf(actual);
  if (requestedRank == 0 || actualRank == 0) return false;
  return actualRank < requestedRank;
}

/// 把任意一组音质整理成「去重 + 由低到高」的阶梯。
///
/// 未知档位（插件自造的 key）保持原顺序排在最后，避免被静默丢掉。
List<String> sortedQualityLadder(Iterable<String> qualities) {
  final seen = <String>{};
  final known = <String>[];
  final unknown = <String>[];
  for (final raw in qualities) {
    final value = raw.trim();
    if (value.isEmpty) continue;
    final key = musicQualityKey(value);
    if (!seen.add(key)) continue;
    if (musicQualityRankOf(value) > 0) {
      known.add(value);
    } else {
      unknown.add(value);
    }
  }
  known.sort(
    (a, b) => musicQualityRankOf(a).compareTo(musicQualityRankOf(b)),
  );
  return [...known, ...unknown];
}

/// 阶梯上比 [current] 低一档的音质（取「最接近的更低档」）；没有则返回 null。
String? qualityStepDown(String current, List<String> ladder) {
  final rank = musicQualityRankOf(current);
  if (rank == 0) return null;
  String? best;
  var bestRank = 0;
  for (final item in ladder) {
    final itemRank = musicQualityRankOf(item);
    if (itemRank == 0 || itemRank >= rank) continue;
    if (itemRank > bestRank) {
      best = item;
      bestRank = itemRank;
    }
  }
  return best;
}

/// 阶梯上比 [current] 高一档的音质（取「最接近的更高档」）；没有则返回 null。
///
/// 请求的档位不在阶梯里也能用：例如请求 `flac24bit`、音源只声明了
/// `128k/320k` 时，降级拿不到，升级会给出 `128k`（最接近的高档）。
String? qualityStepUp(String current, List<String> ladder) {
  final rank = musicQualityRankOf(current);
  if (rank == 0) return null;
  String? best;
  var bestRank = 1 << 30;
  for (final item in ladder) {
    final itemRank = musicQualityRankOf(item);
    if (itemRank == 0 || itemRank <= rank) continue;
    if (itemRank < bestRank) {
      best = item;
      bestRank = itemRank;
    }
  }
  return best;
}
