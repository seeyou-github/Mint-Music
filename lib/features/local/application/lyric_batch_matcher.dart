import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../shared/utils/song_match_score.dart';
import '../../player/application/lyric_resolver.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/services/lyric_parser.dart';
import '../../player/domain/services/lyric_text_formatter.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/domain/plugin_types.dart';

/// 一首歌的批量匹配结果。
class LyricBatchMatchResult {
  const LyricBatchMatchResult({
    required this.localSong,
    required this.matchedSong,
    required this.sourceName,
    required this.wordByWord,
    required this.lyricText,
  });

  /// 本地歌曲（曲库索引里的那行，含 filePath）。
  final Song localSong;

  /// 在线候选（完全匹配的那条搜索结果）。
  final Song matchedSong;

  /// 数据源显示名（网易 / QQ / 酷狗 / 酷我）。
  final String sourceName;

  /// 是否逐字歌词（false = 所有源都没有逐字，退回的非逐字歌词）。
  final bool wordByWord;

  /// 已按现有写入规则转好的歌词文本（逐字 = 增强 LRC，翻译已并入）。
  final String lyricText;
}

/// 匹配进度事件：[done] / [total] 驱动进度条；[result] 非空表示刚匹配成功
/// 一首（失败的歌 result 为 null，只推进计数，不进成功列表）。
class LyricBatchMatchUpdate {
  const LyricBatchMatchUpdate({
    required this.done,
    required this.total,
    this.result,
  });

  final int done;
  final int total;
  final LyricBatchMatchResult? result;
}

/// 批量歌词匹配流水线。
///
/// 针对每一首待匹配的歌（进页时已筛过：五字段齐备、缺歌词或缺逐字）：
/// 1. 第一轮 = 网易 + QQ 两个数据源**并发**搜索（每源 limit 10），候选按
///    「歌名 / 歌手 / 专辑 / 年份 / 时长」五字段**严格相等**判定（归一化后
///    完全一致，不允许包含；时长 ±2 秒内）；完全匹配的候选立刻走
///    [LyricResolver.resolve]——它内部就是「数据源歌词接口 + 播放详情页
///    用的单独 TTML 词库接口」（amll-ttml-db，仅 wy/tx）并发取词，
///    逐字优先、等翻译轨。
/// 2. 第一轮没有任何源给出逐字歌词 → 第二轮并发酷狗 + 酷我（同规则）。
/// 3. 两轮之后：有逐字 → 成功（逐字）；只有非逐字 → 成功（非逐字）；
///    连完全匹配的候选都没有 / 全无歌词 → 本首失败（成功列表不显示）。
///
/// 歌曲之间逐首串行（单首内源并发），避免打爆数据源触发风控。
class LyricBatchMatcher {
  LyricBatchMatcher({
    required LyricResolver resolver,
    required MusicSourceManager manager,
    required List<SourceEntry> sources,
  }) : _resolver = resolver,
       _manager = manager,
       _sources = sources;

  /// 取词（resolve 内部含 TTML 词库）。
  final LyricResolver _resolver;

  /// 搜索（各数据源的插件搜索接口）。
  final MusicSourceManager _manager;

  /// 参与匹配的数据源（按平台 id 去重后的 wy / tx / kg / kw，见
  /// [resolveLyricMatchSources]）。
  final List<SourceEntry> _sources;

  bool _running = false;
  bool _stopped = false;

  /// 第一轮参与的两个平台（有单独 TTML 词库）。
  static const List<String> _firstRoundBaseIds = ['wy', 'tx'];

  /// 用户点击停止：当前这首歌会跑完（abort 不了底层请求），后续歌曲不再开始。
  void stop() => _stopped = true;

  /// 跑完 [songs]，逐首产出进度 / 结果事件（失败的歌 result 为 null）。
  Stream<LyricBatchMatchUpdate> run(List<Song> songs) async* {
    if (_running) return;
    _running = true;
    _stopped = false;
    try {
      var done = 0;
      for (final song in songs) {
        if (_stopped) break;
        LyricBatchMatchResult? result;
        try {
          result = await _matchOne(song);
        } catch (e) {
          debugPrint('[LyricBatchMatcher] ${song.title} 匹配异常: $e');
        }
        done++;
        yield LyricBatchMatchUpdate(
          done: done,
          total: songs.length,
          result: result,
        );
        // 歌曲之间留一点间隔，别连续打同一个域名。
        if (!_stopped) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
    } finally {
      _running = false;
    }
  }

  // ------------------------------------------------------------ 单首匹配

  Future<LyricBatchMatchResult?> _matchOne(Song song) async {
    final local = LocalSongMatchFields.fromSong(song);
    final firstRound = _sources
        .where((entry) => _firstRoundBaseIds.contains(entry.baseId))
        .toList();
    final secondRound = _sources
        .where((entry) => !_firstRoundBaseIds.contains(entry.baseId))
        .toList();

    LyricBatchMatchResult? nonWordFallback;
    for (final round in [firstRound, secondRound]) {
      if (round.isEmpty) continue;
      // 单轮内各数据源并发搜索 + 并发取词（wy/tx 的 resolve 内部还各带
      // 一个单独 TTML 词库请求）。
      final matched = await Future.wait(
        round.map((entry) => _findStrictMatchOnSource(local, entry)),
      );
      final wordFutures = <Future<LyricBatchMatchResult?>>[];
      for (final candidate in matched) {
        if (candidate == null) continue;
        wordFutures.add(_resolveCandidate(song, candidate));
      }
      final wordResults = (await Future.wait(
        wordFutures,
      )).whereType<LyricBatchMatchResult>().toList();
      final wordHit = wordResults
          .where((result) => result.wordByWord)
          .firstOrNull;
      if (wordHit != null) return wordHit;
      // 逐字的没拿到：非逐字的按源顺序记第一个作兜底。
      nonWordFallback ??= wordResults.firstOrNull;
      if (_stopped) break;
    }
    return nonWordFallback;
  }

  /// 单源搜索 + 严格五字段判定，返回第一条完全匹配的候选（没有 → null）。
  Future<_SourceCandidate?> _findStrictMatchOnSource(
    LocalSongMatchFields local,
    SourceEntry entry,
  ) async {
    try {
      final keyword = [
        local.title,
        local.artist,
      ].where((part) => part.trim().isNotEmpty).join(' ');
      if (keyword.isEmpty) return null;
      final results = await _manager.search(
        keyword,
        sourceId: entry.sourceId,
        limit: 10,
      );
      for (final candidate in results) {
        if (_strictMatches(candidate, local)) {
          return _SourceCandidate(entry, candidate);
        }
      }
    } catch (e) {
      debugPrint('[LyricBatchMatcher] ${entry.name} 搜索失败: $e');
    }
    return null;
  }

  /// 五字段**完全匹配**：归一化后完全相等（不允许包含），时长 ±2 秒内。
  bool _strictMatches(Song candidate, LocalSongMatchFields local) {
    if (normalizeForMatch(candidate.title) != normalizeForMatch(local.title)) {
      return false;
    }
    if (normalizeForMatch(candidate.artist) !=
        normalizeForMatch(local.artist)) {
      return false;
    }
    if (normalizeForMatch(candidate.album) != normalizeForMatch(local.album)) {
      return false;
    }
    if (local.year <= 0 || candidate.year != local.year) return false;
    if (local.durationSeconds <= 0 ||
        candidate.duration <= 0 ||
        (candidate.duration - local.durationSeconds).abs() > 2) {
      return false;
    }
    return true;
  }

  /// 取词（数据源歌词接口 + wy/tx 的单独 TTML 词库在 resolve 内部并发），
  /// 按现有写入规则转文本（逐字 = 增强 LRC，翻译并入），并判定逐字 / 非逐字。
  Future<LyricBatchMatchResult?> _resolveCandidate(
    Song localSong,
    _SourceCandidate candidate,
  ) async {
    try {
      final result = await _resolver.resolve(candidate.song);
      if (result == null) return null;
      final text = LyricTextFormatter.fromResult(result);
      if (text.trim().isEmpty) return null;
      return LyricBatchMatchResult(
        localSong: localSong,
        matchedSong: candidate.song,
        sourceName: candidate.entry.name,
        wordByWord: isEnhancedLrcFormat(text),
        lyricText: text,
      );
    } catch (e) {
      debugPrint('[LyricBatchMatcher] 取词失败（${candidate.entry.name}）: $e');
      return null;
    }
  }
}

/// 一个参与匹配的数据源。
class SourceEntry {
  const SourceEntry({
    required this.baseId,
    required this.sourceId,
    required this.name,
  });

  /// 平台 id（wy / tx / kg / kw）。
  final String baseId;

  /// 完整音源 id（`平台@插件id`），搜索用它。
  final String sourceId;

  /// 显示名（网易 / QQ / 酷狗 / 酷我）。
  final String name;
}

class _SourceCandidate {
  const _SourceCandidate(this.entry, this.song);
  final SourceEntry entry;
  final Song song;
}

/// 从可搜索音源列表解析参与批量匹配的数据源：只认四个平台
///（wy / tx / kg / kw），每个平台取第一个音源，结果按 wy → tx → kg → kw 排。
List<SourceEntry> resolveLyricMatchSources(List<SourceInfo> sources) {
  const order = ['wy', 'tx', 'kg', 'kw'];
  const names = {'wy': '网易', 'tx': 'QQ', 'kg': '酷狗', 'kw': '酷我'};
  final result = <SourceEntry>[];
  for (final baseId in order) {
    for (final source in sources) {
      if (!source.id.startsWith('$baseId@')) continue;
      result.add(
        SourceEntry(
          baseId: baseId,
          sourceId: source.id,
          name: names[baseId] ?? baseId,
        ),
      );
      break;
    }
  }
  return result;
}
