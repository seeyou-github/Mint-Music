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
/// 比特率档位按实际千比特比较，所以插件报出的非标准档位（如酷我的
/// `100k`）也能和标准档位一起排序；无损档位统一排在所有比特率之上。
int musicQualityRankOf(String quality) {
  final key = musicQualityKey(quality);
  final index = musicQualityOrder.indexOf(key);
  final bitrate = _bitrateQualityPattern.firstMatch(key);
  if (bitrate != null) return int.parse(bitrate.group(1)!);
  return index < 0 ? 0 : 10000 + index;
}

final RegExp _bitrateQualityPattern = RegExp(r'^(\d{2,4})\s*k$');

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
  known.sort((a, b) => musicQualityRankOf(a).compareTo(musicQualityRankOf(b)));
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

/// 服务器是否明确表示「这个音质拿不到」。
///
/// 只有这类错误才允许自动换档（例如插件报「不支持 flac 音质」）。
/// 401/403/429、超时、5xx、CDN 连不上等都不算：换一个音质只会多打一次
/// 请求，还会把真正的错误盖掉。
bool isQualityUnavailableError(String message) {
  final text = message.trim();
  if (text.isEmpty) return false;
  return _qualityUnavailablePatterns.any((pattern) => pattern.hasMatch(text));
}

final List<RegExp> _qualityUnavailablePatterns = [
  RegExp(r'不支持.{0,16}音质'),
  RegExp(r'音质.{0,8}(?:不支持|不存在|不可用)'),
  RegExp(r'(?:没有|无)该?音质'),
  RegExp(r'音质不匹配'),
  // 实测遇到的一类文案：`没有 128k mp3 版本`、`音质切到对应档位`。
  RegExp(r'(?:没有|无)[^。；;！!\n]{0,20}?版本'),
  RegExp(r'音质[^。；;！!\n]{0,8}(?:切|改|换|调)'),
  RegExp(
    r'(?:只|仅)(?:能|可)?(?:给|提供|支持|有)(?:出|到|了)?'
    r'[^。；;！!\n]{0,6}\d{2,4}\s*k',
  ),
  RegExp(r'最高[^。；;！!\n]{0,12}?\d{2,4}\s*k'),
  RegExp(r'unsupported\s+quality', caseSensitive: false),
  RegExp(
    r'quality.{0,20}(?:not\s+supported?|unsupported|unavailable|not\s+available)',
    caseSensitive: false,
  ),
  RegExp(r'no\s+such\s+quality', caseSensitive: false),
];

/// 插件错误里提到的数字比特率档位（`100k`、`128K`…）。
///
/// 前后都不能粘字母数字，避免把 `128kbps`、`48kHz` 里的数字当成音质。
final RegExp _bitrateTokenPattern = RegExp(
  r'(?:^|[^0-9a-zA-Z])(\d{2,4})\s*k(?![0-9a-zA-Z])',
  caseSensitive: false,
);

/// 「只给得出 / 最高给到」后面的档位才是真正能用的，`没有 128k` 里的不算。
final RegExp _availableQualityPattern = RegExp(
  r'(?:只(?:能|可)?(?:给|提供|支持|有)(?:出|到|了)?|'
  r'最高(?:只)?(?:给|提供|支持)?(?:出|到)?|仅有|只有)'
  r'[^0-9a-zA-Z\n]{0,12}?(\d{2,4})\s*k',
  caseSensitive: false,
);

/// 从「这个音质拿不到」的错误里找出插件实际能给的更低档位。
///
/// 例如酷我会把内部各渠道的结果汇总成：`没有 128k mp3 版本，所有接口
/// 最高只给到 100k aac`。这种错误换播放源解决不了——同一首歌在别的源上
/// 还要重新搜索——按插件自己提到的 `100k` 重试同一个源即可。
///
/// 只接受比 [requested] 低的档位；没提到、或提到的都不比它低时返回 null。
String? qualityFallbackFromError(String message, String requested) {
  if (!isQualityUnavailableError(message)) return null;
  final requestedRank = musicQualityRankOf(requested);
  if (requestedRank <= 0) return null;

  String? best;
  var bestRank = 0;
  void consider(String match) {
    final rank = musicQualityRankOf(match);
    if (rank <= 0 || rank >= requestedRank || rank <= bestRank) return;
    best = match;
    bestRank = rank;
  }

  // 优先看「只给 / 最高」这类措辞：`没有 128k mp3 版本` 里的 128k 不能拿来重试。
  var phraseMatched = false;
  for (final match in _availableQualityPattern.allMatches(message)) {
    phraseMatched = true;
    consider('${match.group(1)}k');
  }
  // 提到了「能给的档位」却都不比请求低：不要再退回「没有」里的档位。
  if (best != null || phraseMatched) return best;

  // 没有这类措辞时，退回扫描错误里的全部比特率档位。
  for (final match in _bitrateTokenPattern.allMatches(message)) {
    consider('${match.group(1)}k');
  }
  return best;
}

/// 这个错误再请求一次也不会变（鉴权 / 限流 / 明确的 4xx）。
///
/// 上层用它跳过「同一个音源立刻重试一次」；5xx、超时、网络错误仍然允许
/// 重试一次，但不会再自动换音质。
bool isNonRetryableResolveError(String message) {
  if (isQualityUnavailableError(message)) return true;
  if (_authOrRateLimitPattern.hasMatch(message)) return true;
  final match = RegExp(
    r'(?:code|http)\s*([45]\d\d)',
    caseSensitive: false,
  ).firstMatch(message);
  if (match == null) return false;
  final status = int.tryParse(match.group(1)!) ?? 0;
  return status >= 400 && status < 500 && status != 408;
}

final RegExp _authOrRateLimitPattern = RegExp(
  r'\b(?:401|403|429)\b|未授权|认证用户|无权限|权限不足|拒绝访问|'
  r'限流|请求过于频繁|频率过高|访问频率|额度|配额|封禁|封\s*IP',
  caseSensitive: false,
);

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
