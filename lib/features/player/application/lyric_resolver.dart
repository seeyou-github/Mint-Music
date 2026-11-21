import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../plugin/application/music_source_manager.dart';
import '../../plugin/application/plugin_providers.dart';
import '../domain/models/lyric_line.dart';
import '../domain/models/song.dart';
import '../domain/services/lyric_parser.dart';
import '../domain/services/ttml_db_service.dart';

/// 一次取词的原始结果：TTML 词库原文 + 音源接口返回的那一份。
///
/// 分开保留是因为播放页要把它们写进歌词缓存（下次播放不必再联网），
/// 选哪一份显示由 [pickBestLyric] 统一决定。
class LyricRaw {
  const LyricRaw({this.ttmlText, this.online});

  final String? ttmlText;
  final LyricResult? online;
}

/// 两个歌词来源的竞速规则（纯逻辑，便于单测）。
///
/// 播放页要尽快出词，不能为了等词库一直空着：
/// * 音源先给出逐字歌词 → 立刻用它，词库后到也不再替换（都是逐字，效果一样）；
/// * 音源先给出整行歌词 → 继续等词库，用「词库 + 音源翻译」；
/// * 词库先返回 → 等音源把翻译带回来（词库只有原文）；
/// * 任意一边超时 / 失败都按「没拿到」处理，两边都没有就是空结果。
///
/// [onTtmlLate] 只在「音源逐字先到、词库被放弃」时触发：词库那份迟到的
/// TTML 里可能自带翻译轨（QQ 的官方歌词接口根本不返回翻译），丢掉就永远
/// 没有翻译了。回调里把迟到的 TTML 交回去，由调用方决定怎么补。
///
/// [waitTtmlForTranslation] 用于「要一次性拿到最终结果」的入口（搜索预览、
/// 编辑标签页「在线搜索」）：音源虽然给了逐字歌词，但它没有翻译、而词库
/// 可能自带翻译轨时，继续等词库再选。播放页不用这条 —— 它先上屏、再靠
/// [onTtmlLate] 补翻译，不值得为了翻译空等。
Future<LyricRaw> raceLyricSources({
  required Future<String?>? ttmlRequest,
  required Future<LyricResult?>? onlineRequest,
  FutureOr<void> Function(String ttmlText)? onTtmlLate,
  bool waitTtmlForTranslation = false,
}) async {
  if (ttmlRequest == null) {
    LyricResult? online;
    if (onlineRequest != null) {
      try {
        online = await onlineRequest;
      } catch (_) {
        online = null;
      }
    }
    return LyricRaw(online: online);
  }

  if (onlineRequest == null) {
    String? ttmlText;
    try {
      ttmlText = await ttmlRequest;
    } catch (_) {
      ttmlText = null;
    }
    return LyricRaw(ttmlText: ttmlText);
  }

  String? ttmlText;
  LyricResult? online;
  final ttmlDone = Completer<void>();
  final onlineDone = Completer<void>();

  unawaited(() async {
    try {
      ttmlText = await ttmlRequest;
    } catch (_) {
      ttmlText = null;
    }
    ttmlDone.complete();
  }());

  unawaited(() async {
    try {
      online = await onlineRequest;
    } catch (_) {
      online = null;
    }
    onlineDone.complete();
  }());

  await Future.any([ttmlDone.future, onlineDone.future]);

  if (onlineDone.isCompleted) {
    if (isWordLevelLyric(online?.crlyric)) {
      // 音源逐字且自带翻译：这份已经完整，词库不用再等也无需补。
      final hasTranslation =
          (online?.tlyric?.trim().isNotEmpty ?? false) ||
          (online?.rlyric?.trim().isNotEmpty ?? false);
      if (hasTranslation) {
        return LyricRaw(online: online);
      }
      // 音源逐字但没有翻译（QQ 的 fcg 接口永远返回空 trans）：
      // 一次性拿结果的入口等词库的翻译轨。
      if (waitTtmlForTranslation) {
        await ttmlDone.future;
        return LyricRaw(ttmlText: ttmlText, online: online);
      }
      // 词库被放弃，但它的翻译轨不能丢：等它回来交给回调补上（QQ 官方
      // 歌词接口不返回翻译，翻译只在 TTML 词库里）。
      if (onTtmlLate != null) {
        unawaited(() async {
          String? late;
          try {
            late = await ttmlRequest;
          } catch (_) {
            late = null;
          }
          final text = late?.trim() ?? '';
          if (text.isEmpty) return;
          try {
            await onTtmlLate(text);
          } catch (_) {}
        }());
      }
      return LyricRaw(online: online);
    }
    await ttmlDone.future;
    return LyricRaw(ttmlText: ttmlText, online: online);
  }

  await onlineDone.future;
  return LyricRaw(ttmlText: ttmlText, online: online);
}

/// 歌词的唯一入口：TTML 词库 + 音源接口。
///
/// 播放页、搜索歌词预览、编辑标签页「在线搜索」、下载写标签都从这里取词，
/// 保证同一首歌在几个场景拿到的是同一份歌词（同样的逐字格式、同样的翻译），
/// 而不是像以前那样各调各的接口、各挑各的字段。
///
/// 本地歌曲不走这里：歌词以歌曲文件里的内嵌歌词为准。
class LyricResolver {
  LyricResolver(this._musicSourceManager, this._ttmlDbService);

  final MusicSourceManager _musicSourceManager;
  final TtmlDbService _ttmlDbService;

  /// TTML 词库超时：它是第三方服务，慢了就先用手上已有的歌词。
  static const Duration _ttmlTimeout = Duration(seconds: 5);

  /// 音源歌词超时。
  static const Duration _onlineTimeout = Duration(seconds: 8);

  /// 取一首歌的原始歌词；两边都拿不到时字段为空。
  ///
  /// TTML 词库（网易 / QQ 才有）与音源接口并发请求，谁先回来都不影响结果。
  /// [includeOnline] 为 false 时不请求音源（歌曲自带歌词且音源不提供逐字歌词
  /// 时没必要多打一次网络）。
  Future<LyricRaw> fetchRaw(Song song, {bool includeOnline = true}) async {
    final sourceId = song.lyricSourceId;
    if (sourceId.isEmpty) return const LyricRaw();

    final baseSource = MusicSourceManager.splitSourceId(sourceId).$1;

    Future<String?>? ttmlFuture;
    if (baseSource == 'wy' || baseSource == 'tx') {
      final cleanId = song.id.replaceAll('wy_', '').replaceAll('tx_', '');
      ttmlFuture = _ttmlDbService
          .fetchTtmlText(baseSource, cleanId)
          .timeout(_ttmlTimeout);
    }

    Future<LyricResult?>? onlineFuture;
    if (includeOnline) {
      onlineFuture = _musicSourceManager
          .getLyricResult(song)
          .timeout(_onlineTimeout);
    }

    String? ttmlText;
    if (ttmlFuture != null) {
      try {
        ttmlText = await ttmlFuture;
      } catch (_) {
        ttmlText = null;
      }
    }

    LyricResult? online;
    if (onlineFuture != null) {
      try {
        online = await onlineFuture;
      } catch (_) {
        online = null;
      }
    }

    return LyricRaw(ttmlText: ttmlText, online: online);
  }

  /// 竞速取词：两个接口真并发，谁先给出逐字歌词就用谁。
  ///
  /// 播放详情页、搜索歌词预览、编辑标签页「在线搜索」共用这一条路径，
  /// 三处拿到的歌词（格式、翻译、写进文件的内容）完全一致。
  ///
  /// 规则：
  /// * 音源先返回逐字歌词 → 立刻用它，词库后到也不再替换（都是逐字，效果一样）；
  /// * 音源先返回整行歌词 → 继续等词库，词库给了逐字歌词就用「词库原文 + 音源
  ///   翻译」，词库超时 / 没有 / 也只是一整行就用音源那份；
  /// * 词库先返回 → 等音源把翻译带回来，再用「词库 + 音源翻译」；
  /// * 两边都没有结果 → 返回空，由调用方提示「无法获取歌词」（不会重试）。
  ///
  /// 注意翻译始终来自音源：TTML 词库只有原文，所以词库先到也必须等音源。
  /// [onTtmlLate]：音源先给出逐字歌词、TTML 不再参与选词时，迟到的 TTML 仍
  /// 会通过它交回来（里面可能有翻译轨）。只有播放页用得上，其它入口传 null。
  ///
  /// [waitTtmlForTranslation]：音源逐字但没有翻译时，是否继续等词库的翻译轨
  /// （搜索预览、编辑标签页「在线搜索」用；播放页靠 [onTtmlLate] 后台补）。
  Future<LyricRaw> fetchRawRacing(
    Song song, {
    bool includeOnline = true,
    FutureOr<void> Function(String ttmlText)? onTtmlLate,
    bool waitTtmlForTranslation = false,
  }) async {
    final sourceId = song.lyricSourceId;
    if (sourceId.isEmpty) return const LyricRaw();

    final baseSource = MusicSourceManager.splitSourceId(sourceId).$1;

    Future<String?>? ttmlRequest;
    if (baseSource == 'wy' || baseSource == 'tx') {
      final cleanId = song.id.replaceAll('wy_', '').replaceAll('tx_', '');
      ttmlRequest = _ttmlDbService
          .fetchTtmlText(baseSource, cleanId)
          .timeout(_ttmlTimeout);
    }

    Future<LyricResult?>? onlineRequest;
    if (includeOnline) {
      onlineRequest = _musicSourceManager
          .getLyricResult(song)
          .timeout(_onlineTimeout);
    }

    return raceLyricSources(
      ttmlRequest: ttmlRequest,
      onlineRequest: onlineRequest,
      onTtmlLate: onTtmlLate,
      waitTtmlForTranslation: waitTtmlForTranslation,
    );
  }

  /// 取一首歌「最终该显示 / 该写进文件」的那一份歌词；两边都没有返回 null。
  ///
  /// 等两边都回来再按「逐字优先」选一份：下载写标签用这条，后台任务不怕慢，
  /// 结果也不会因为网络快慢而在两次下载之间变来变去。
  Future<LyricResult?> resolve(Song song) async {
    final raw = await fetchRaw(song);
    return pickBestLyric(ttmlText: raw.ttmlText, online: raw.online);
  }

  /// 竞速版 [resolve]：搜索预览、编辑标签页「在线搜索」用这条。
  ///
  /// 音源逐字**且带翻译**时立刻返回；音源逐字但没有翻译时继续等词库的
  /// 翻译轨（QQ 的歌词接口不返回翻译，翻译只在 TTML 词库的
  /// `<span ttm:role="x-translation">` 里）。这两个入口要的是「一次性拿到
  /// 最终那份、并且写进文件」，等几百毫秒换取翻译是值得的。
  Future<LyricResult?> resolveRacing(Song song) async {
    final raw = await fetchRawRacing(song, waitTtmlForTranslation: true);
    return pickBestLyric(ttmlText: raw.ttmlText, online: raw.online);
  }
}

final lyricResolverProvider = Provider<LyricResolver>((ref) {
  return LyricResolver(
    ref.watch(musicSourceManagerProvider),
    ref.watch(ttmlDbServiceProvider),
  );
});
