import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/l10n/han_converter.dart';
import '../../../core/l10n/l10n.dart';
import '../../settings/application/settings_providers.dart';
import '../domain/models/song.dart';
import '../domain/models/lyric_line.dart';
import '../domain/models/playback_state.dart';
import '../domain/services/lyric_cache.dart';
import '../domain/services/lyric_parser.dart';
import '../domain/services/lyric_text_formatter.dart';
import '../domain/services/embedded_lyrics_extractor.dart';
import '../domain/services/ttml_db_service.dart';
import '../domain/services/ttml_parser.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/application/plugin_providers.dart';
import 'lyric_resolver.dart';
import 'playback_controller.dart';

class LyricState {
  final List<LyricLine> lines;
  final bool isLoading;
  final String? error;
  final String? currentSongId;
  final String? currentSongSource;
  final bool hasYrc;

  /// 逐字歌词的英文格式名（YRC / QRC / KRC / LRCX / MRC / TTML / ELRC）。
  /// 普通 LRC 或尚未加载时为 null。
  final String? lyricFormat;

  const LyricState({
    this.lines = const [],
    this.isLoading = false,
    this.error,
    this.currentSongId,
    this.currentSongSource,
    this.hasYrc = false,
    this.lyricFormat,
  });

  LyricState copyWith({
    List<LyricLine>? lines,
    bool? isLoading,
    String? error,
    String? currentSongId,
    String? currentSongSource,
    bool? hasYrc,
    String? lyricFormat,
  }) {
    return LyricState(
      lines: lines ?? this.lines,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      currentSongId: currentSongId ?? this.currentSongId,
      currentSongSource: currentSongSource ?? this.currentSongSource,
      hasYrc: hasYrc ?? this.hasYrc,
      lyricFormat: lyricFormat ?? this.lyricFormat,
    );
  }
}

/// 把一份歌词解析成可直接显示的行（优先逐字歌词，合并翻译 / 音译）。
///
/// 「搜索歌词」预览、手动指定歌词、播放页共用这套规则，保证预览看到的和
/// 用上去的、以及写进文件的完全一致。
Future<List<LyricLine>> buildLyricLinesFrom(LyricResult result) async {
  var lines = await parseBestLyricTextInIsolate(result);
  if (lines.isEmpty) return const <LyricLine>[];

  final tlyric = result.tlyric;
  if (tlyric != null && tlyric.isNotEmpty) {
    lines = mergeTranslation(lines, tlyric);
    lines = stripTranslationFromWords(lines);
  }
  lines = extractAdLibWords(lines);
  final rlyric = result.rlyric;
  if (rlyric != null && rlyric.isNotEmpty) {
    lines = mergeRomanLyric(lines, rlyric);
  }
  return sanitizeLyricLines(lines);
}

/// 这份歌词的逐字格式名；普通 LRC 返回 null。
String? lyricFormatOfResult(LyricResult result, {String? source}) {
  for (final text in [result.crlyric, result.lrc]) {
    if (text == null || text.trim().isEmpty) continue;
    final format = detectWordLyricFormat(text, source: source);
    if (format != null) return format;
  }
  return null;
}

class LyricController extends StateNotifier<LyricState> {
  /// 统一取词入口（TTML 词库 + 音源歌词），与搜索预览 / 编辑标签页 / 下载共用。
  final LyricResolver _resolver;
  int _requestId = 0;
  static const Duration _lyricFetchTimeout = Duration(seconds: 10);

  /// 当前歌词语言。由 [applyLyricLocale] 设置(初始值来自
  /// effectiveLyricLocaleProvider),繁体时对歌词做简->繁转换。
  AppLocale _locale = AppLocale.zhCn;

  /// 最近一次解析出的简体原始歌词行,切换语言时据此重建,
  /// 避免繁体状态下无法还原回简体。
  List<LyricLine>? _rawLines;

  /// 已经确认「这首歌唱不到词」的 key（音源 + 歌曲 id）。
  ///
  /// 以前判断「已经加载过」要求 `state.lines.isNotEmpty`，没有歌词的歌永远
  /// 不满足，于是每次触发都重新走一遍完整流程（插件取词 + 那时候还有的跨源
  /// 搜索）。现在把「确认没词」也记下来，同一首歌不再重复发请求；用户手动
  /// 指定歌词或切换音源后清空。
  String? _noLyricKey;

  static String _attemptKeyOf(String sourceKey, String songId) =>
      '$sourceKey\u0000$songId';

  LyricController(
    MusicSourceManager musicSourceManager,
    TtmlDbService ttmlDbService,
  ) : _resolver = LyricResolver(musicSourceManager, ttmlDbService),
      super(const LyricState());

  /// 歌词语言变化时调用:只重跑转换,不重新拉取/解析歌词。
  void applyLyricLocale(AppLocale locale) {
    if (locale == _locale) return;
    _locale = locale;
    final raw = _rawLines;
    if (raw == null || state.currentSongId == null) return;
    state = state.copyWith(lines: _convertLines(raw));
  }

  /// 繁体语言下对歌词行做简->繁转换;简体时原样返回。
  List<LyricLine> _convertLines(List<LyricLine> lines) {
    if (_locale != AppLocale.zhTw) return lines;
    return lines.map(_convertLine).toList(growable: false);
  }

  LyricLine _convertLine(LyricLine line) {
    // 整句先转换一次(词组语境准确,如 后->後、干->乾),再按各
    // word 的字符数切片回填,逐字时间轴保持不变。
    final convertedPlain = HanConverter.s2t(line.plainText);
    return line.copyWith(
      words: _convertWordsBySlice(line.words, convertedPlain),
      translatedLyric: line.translatedLyric == null
          ? null
          : HanConverter.s2t(line.translatedLyric!),
      adLibText: line.adLibText == null
          ? null
          : HanConverter.s2t(line.adLibText!),
    );
  }

  List<LyricWord> _convertWordsBySlice(
    List<LyricWord> words,
    String convertedPlain,
  ) {
    final totalLen = words.fold<int>(0, (sum, w) => sum + w.word.length);
    // 罕见情况下(非常用字符)转换前后长度可能不一致,退化为逐词转换。
    if (totalLen != convertedPlain.length) {
      return [
        for (final w in words) w.copyWith(word: HanConverter.s2t(w.word)),
      ];
    }
    final result = <LyricWord>[];
    var offset = 0;
    for (final w in words) {
      final len = w.word.length;
      result.add(
        w.copyWith(word: convertedPlain.substring(offset, offset + len)),
      );
      offset += len;
    }
    return result;
  }

  /// 取音源 id 里的平台部分。
  ///
  /// `平台id@插件id` → `平台id`；没有插件后缀时原样返回。
  static String? _baseSourceOf(String? source) {
    if (source == null || source.isEmpty) return null;
    final index = source.indexOf('@');
    if (index <= 0 || index >= source.length - 1) return source;
    return source.substring(0, index);
  }

  Future<void> loadLyrics(Song? song) async {
    if (song == null) {
      debugPrint('[LyricController] song is null, clearing lyrics');
      state = const LyricState();
      return;
    }

    if (kDebugMode) {
      debugPrint(
        '[LyricController] loadLyrics called for song: ${song.title}, id: ${song.id}, source: ${song.lyricSourceId}',
      );
    }

    // 歌词按「音源 + 歌曲」归属：同一首歌换了音源（插件变体）也要重新取词，
    // 不能沿用上一个音源的歌词。
    final sourceKey = song.lyricSourceId;

    final attemptKey = _attemptKeyOf(sourceKey, song.id);

    if (state.currentSongId == song.id &&
        state.currentSongSource == sourceKey) {
      if (state.lines.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('[LyricController] Same song and lyrics already loaded');
        }
        return;
      }
      // 同一首歌正在取词：歌词页 + 详情页可能同时触发，别再发一轮请求。
      if (state.isLoading) {
        return;
      }
      // 已经确认这首歌唱不到词，不再重复请求。
      if (_noLyricKey == attemptKey) {
        return;
      }
    }

    final requestId = ++_requestId;
    state = LyricState(
      // 换歌时先清空上一首歌的歌词：新歌歌词还在加载时继续显示上一首的词，
      // 会让人以为歌词没换。
      lines: const [],
      isLoading: true,
      currentSongId: song.id,
      currentSongSource: sourceKey,
      hasYrc: false,
    );

    try {
      // 用户手动删除了这首歌的歌词关联：不再自动匹配（重启后也一样），
      // 等用户在「搜索歌词」里重新指定。
      if (await LyricCache.isDeleted(song)) {
        if (requestId != _requestId) return;
        _rawLines = null;
        state = LyricState(
          error: tr('暂无歌词'),
          currentSongId: song.id,
          currentSongSource: sourceKey,
        );
        return;
      }

      String? lrc = song.lrc;
      String? crlyric;
      String? tlyric;
      String? rlyric;
      String? ttmlText;

      // 歌曲的音源可能是插件变体（`平台id@插件id`）。TTML 词库只按平台
      // 提供，逐字格式也按平台辅助判断。
      final baseSource = _baseSourceOf(song.lyricSourceId) ?? '';

      // Step 0: 本地缓存。歌词来自网络，命中缓存就不用再请求，切歌时歌词
      // 立刻出现。
      //
      // 本地歌曲例外：歌词就在歌曲文件里，每次播放都按文件重新读取；
      // 缓存只在文件里确实没有歌词时，作为「搜索歌词」手动指定的兜底
      // （见下面 Step 2.5）。
      final cached = song.isLocal ? null : await LyricCache.read(song);
      if (requestId != _requestId) return;

      if (cached != null) {
        // 缓存命中：直接用缓存里的歌词，不再请求网络。
        if (cached.lrc?.isNotEmpty ?? false) lrc = cached.lrc;
        crlyric = cached.crlyric;
        tlyric = cached.tlyric;
        rlyric = cached.rlyric;
        ttmlText = cached.ttml;
      } else if (!song.isLocal) {
        final sourceSupportsWordLyric =
            baseSource == 'tx' ||
            baseSource == 'wy' ||
            baseSource == 'kw' ||
            baseSource == 'kg';
        final needOnlineLyric =
            (lrc == null || lrc.isEmpty) || sourceSupportsWordLyric;

        // 竞速取词：TTML 词库与音源歌词真并发，谁先给出逐字就用谁
        // （见 LyricResolver.fetchRawRacing）。播放页优先「马上出词」，
        // 音源逐字先到就直接上屏，词库里迟到的翻译轨由 onTtmlLate 补；
        // 搜索预览 / 编辑标签页「在线搜索」走 resolveRacing，会等翻译轨
        // 齐了再返回（同一套选词规则，最终内容一致）。
        final raw = await _resolver.fetchRawRacing(
          song,
          includeOnline:
              needOnlineLyric && sourceKey.isNotEmpty && sourceKey != 'local',
          // 音源先给出逐字歌词时，TTML 那份迟到的翻译轨不能丢：QQ 的歌词
          // 接口根本不返回翻译，翻译只有 TTML 词库里才有（见 _applyLateTtml）。
          onTtmlLate: (ttml) =>
              _applyLateTtml(song: song, requestId: requestId, ttmlText: ttml),
        );
        if (requestId != _requestId) return;
        ttmlText = raw.ttmlText;

        final online = raw.online;
        if (online != null) {
          if (online.crlyric?.trim().isNotEmpty ?? false) {
            crlyric = online.crlyric;
          }
          if ((lrc == null || lrc.isEmpty) &&
              (online.lrc?.trim().isNotEmpty ?? false)) {
            lrc = online.lrc;
          }
          tlyric = online.tlyric;
          rlyric = online.rlyric;
        }
      }
      if (requestId != _requestId) return;

      // 拿到歌词后写入缓存，下次播放直接命中（命中缓存时不用重复写）。
      // 本地歌曲不写缓存：歌词以文件为准，每次播放重新读取。
      if (cached == null && !song.isLocal) {
        unawaited(
          LyricCache.write(
            song,
            lrc: lrc,
            crlyric: crlyric,
            tlyric: tlyric,
            rlyric: rlyric,
            ttml: ttmlText,
          ),
        );
      }

      // Step 2: 本地歌曲只认歌曲文件里的内嵌歌词。
      //
      // 索引 / 播放队列里的 `song.lrc` 一律不作数：它不落盘（`toPersistJson`
      // 会剔掉），却会在本次运行里被旧的写入路径塞进去，读取时压过文件，
      // 造成「文件换了歌词、界面还是旧的」。只有文件里确实没词时，才用它做
      // 兜底（写不进文件的格式，编辑时留在内存里的那一份）。
      if (song.isLocal) {
        final path = song.filePath ?? '';
        if (path.isNotEmpty) {
          try {
            final embedded = await EmbeddedLyricsExtractor.extract(
              path,
            ).timeout(_lyricFetchTimeout);
            if (embedded != null && embedded.trim().isNotEmpty) {
              // 文件里有词：文件说了算，整份替换（歌词格式可能也变了）。
              // 写入文件的双语歌词是「原文行 + 同时间戳译文行」，这里拆回
              // 原文与翻译两份，译文回到翻译位置显示，而不是当另一行滚上去。
              final split = LyricTextFormatter.splitTranslation(embedded);
              lrc = split.lyric;
              crlyric = null;
              tlyric = split.translation;
              rlyric = null;
              ttmlText = null;
            }
          } catch (_) {
            // 读失败就保持原样，走下面的兜底。
          }
        }
      }

      // Step 2.5: 本地歌曲文件里没有歌词时，回退到「搜索歌词」手动指定的
      // 缓存歌词（自动匹配的结果不写缓存，所以缓存里只有用户手动给的）。
      if (song.isLocal && (lrc == null || lrc.isEmpty)) {
        final manual = await LyricCache.read(song);
        if (requestId != _requestId) return;
        if (manual != null) {
          lrc = manual.lrc;
          crlyric = manual.crlyric;
          tlyric = manual.tlyric;
          rlyric = manual.rlyric;
        }
      }

      // Step 3: 统一选词 —— TTML 词库与音源歌词合成一份（逐字优先，翻译跟随
      // 音源），再按显示用的规则解析成行。播放页、搜索预览、编辑标签页、
      // 下载写标签共用这一套，几处看到 / 写进文件的是同一份歌词。
      final result = pickBestLyric(
        ttmlText: ttmlText,
        online: LyricResult(
          lrc: lrc,
          crlyric: crlyric,
          tlyric: tlyric,
          rlyric: rlyric,
        ),
      );

      if (result == null) {
        // 只认当前音源自己的歌词接口：拿不到就明确提示，并提供「搜索歌词」
        // 入口让用户手动指定，不再自动去别的平台找同一首歌。
        _noLyricKey = attemptKey;
        state = LyricState(
          error: tr('无法获取歌词'),
          currentSongId: song.id,
          currentSongSource: sourceKey,
        );
        return;
      }

      final parsedLines = await buildLyricLinesFrom(result);
      if (requestId != _requestId) return;

      if (parsedLines.isEmpty) {
        // 拿到了文本但一行时间轴都解析不出来：网易云给纯音乐返回的常常不是
        // 歌词，而是「作曲 : Fenty」「风格：嘻哈说唱」这类曲目信息。
        //
        // 这属于「这首没词」，不是「解析失败」：
        // * 记进 [_noLyricKey]，同一首歌不再每次触发都重新联网（以前这里不
        //   记，切回歌词页 / 重播就又发一轮请求）；
        // * 提示用「暂无歌词」，和音源直接没有歌词时保持一致。
        _noLyricKey = attemptKey;
        state = LyricState(
          error: tr('暂无歌词'),
          currentSongId: song.id,
          currentSongSource: sourceKey,
        );
        return;
      }

      final hasYrc = parsedLines.any((line) => line.isYrc);

      _rawLines = parsedLines;
      state = LyricState(
        lines: _convertLines(parsedLines),
        currentSongId: song.id,
        currentSongSource: sourceKey,
        hasYrc: hasYrc,
        lyricFormat: hasYrc
            ? lyricFormatOfResult(result, source: baseSource)
            : null,
      );
    } catch (e, stack) {
      debugPrint('[LyricController] Error loading lyrics: $e');
      debugPrint('[LyricController] Stack: $stack');
      if (requestId != _requestId) return;
      state = LyricState(
        error: tr('加载歌词失败: $e'),
        currentSongId: song.id,
        currentSongSource: sourceKey,
      );
    }
  }

  /// 迟到的 TTML：歌词主体已经用音源的逐字歌词显示了，这里只把它自带的
  /// 翻译轨补到现有行上。
  ///
  /// 为什么需要：QQ 的 `fcg_query_lyric_new` 对所有歌都返回空的 `trans`
  /// 字段（实测），QQ 音源的 QRC 永远没有翻译；中文翻译只存在于 AMLL TTML
  /// 词库的 `<span ttm:role="x-translation">` 里。竞速规则会让先到的 QRC
  /// 直接上屏、TTML 被放弃，于是播放页就一直没有翻译。
  ///
  /// 这里不动歌词主体（行数、逐字时间轴都保持音源那份，避免界面跳变），
  /// 只把 TTML 的译文按时间戳合并进来；同时把 TTML 原文补进歌词缓存，
  /// 下次播放命中缓存时会直接用带翻译的 TTML。
  Future<void> _applyLateTtml({
    required Song song,
    required int requestId,
    required String ttmlText,
  }) async {
    if (requestId != _requestId) return;

    final ttmlLines = await parseTtmlInIsolate(ttmlText);
    if (requestId != _requestId) return;
    if (ttmlLines.isEmpty) return;

    final base = _rawLines;
    if (base == null || base.isEmpty) return;

    // 已经有翻译（音源自己给的，或用户手动指定的那份）就不再覆盖。
    final hasTranslation = base.any(
      (line) => (line.translatedLyric ?? '').trim().isNotEmpty,
    );
    if (hasTranslation) {
      unawaited(LyricCache.writeTtml(song, ttmlText));
      return;
    }

    final transLrc = ttmlTranslationLrc(ttmlLines);
    if (transLrc.isEmpty) return;

    final merged = mergeTranslation(base, transLrc);
    var changed = false;
    for (var i = 0; i < merged.length; i++) {
      if ((merged[i].translatedLyric ?? '') !=
          (base[i].translatedLyric ?? '')) {
        changed = true;
        break;
      }
    }
    if (!changed) return;

    _rawLines = merged;
    state = LyricState(
      lines: _convertLines(merged),
      currentSongId: state.currentSongId,
      currentSongSource: state.currentSongSource,
      hasYrc: state.hasYrc,
      lyricFormat: state.lyricFormat,
    );
    // 把 TTML 原文记进缓存：下次播放命中缓存后 pickBestLyric 会选它，
    // 翻译直接就在里面，不用再等一次。
    unawaited(LyricCache.writeTtml(song, ttmlText));
  }

  /// 手动指定歌词（「搜索歌词」里选中并确认的那一份）。
  ///
  /// 立即替换当前显示，并写入歌词缓存：下次播放这首歌会先命中缓存，
  /// 不会被自动匹配的歌词覆盖。缓存按 [Song.lyricSourceId] 归属，只对
  /// 当前正在使用的音源生效。
  Future<void> applyManualLyric(
    Song song,
    LyricResult result, {
    String? source,
  }) async {
    // 让进行中的自动取词 / 迟到 TTML 补翻译全部失效：用户手动指定的这份
    // 歌词说了算，别被几百毫秒后才回来的网络结果改掉。
    ++_requestId;
    final lines = await buildLyricLinesFrom(result);
    if (lines.isEmpty) return;
    final hasYrc = lines.any((line) => line.isYrc);
    _rawLines = lines;
    // 用户手动指定过歌词：之前「确认没词」的标记作废。
    _noLyricKey = null;
    state = LyricState(
      lines: _convertLines(lines),
      currentSongId: song.id,
      currentSongSource: song.lyricSourceId,
      hasYrc: hasYrc,
      lyricFormat: hasYrc
          ? lyricFormatOfResult(
              result,
              source: _baseSourceOf(source ?? song.lyricSourceId),
            )
          : null,
    );
    await LyricCache.clearDeleted(song);
    await LyricCache.write(
      song,
      lrc: result.lrc,
      crlyric: result.crlyric,
      tlyric: result.tlyric,
      rlyric: result.rlyric,
    );
  }

  /// 编辑标签把歌词写进歌曲文件后调用：刷新（本地歌曲则清掉）歌词缓存。
  ///
  /// 歌词缓存按音源 + 歌曲归属，播放时缓存优先于 `song.lrc` 和文件内嵌
  /// 歌词——不刷新的话，之前匹配来的整行歌词会一直盖住刚写入的逐字歌词。
  /// 正在播放这首歌时立即重新解析，不用等下次切歌才生效。
  Future<void> onLyricsWritten(Song song) async {
    final lrc = song.lrc?.trim() ?? '';
    if (song.isLocal) {
      // 本地歌曲不缓存歌词：文件里已经是新内容，删掉旧缓存（可能是手动
      // 指定的那一份），下次播放直接按文件读取。
      await LyricCache.remove(song);
      await LyricCache.clearDeleted(song);
    } else if (lrc.isEmpty) {
      await LyricCache.remove(song);
    } else {
      // 用户手动给了新歌词：解除「不再自动匹配」的标记。
      await LyricCache.clearDeleted(song);
      // 逐字歌词放 crlyric，普通歌词放 lrc，与网络歌词的缓存结构一致。
      if (detectWordLyricFormat(lrc) != null) {
        await LyricCache.write(song, crlyric: lrc);
      } else {
        await LyricCache.write(song, lrc: lrc);
      }
    }
    if (state.currentSongId != song.id) return;
    if (state.currentSongSource != null &&
        state.currentSongSource != song.lyricSourceId) {
      return;
    }
    // 作废进行中的加载，避免旧结果回来后覆盖新歌词。
    _requestId++;
    _noLyricKey = null;
    _rawLines = null;
    state = const LyricState();
    await loadLyrics(song);
  }

  /// 删除这首歌当前音源下的歌词关联（歌词缓存 + 自动匹配）。
  ///
  /// 清空正在显示的歌词，并记下「不再自动匹配」的标记：之后用同一个音源
  /// 播放这首歌会一直显示暂无歌词，直到用户在「搜索歌词」里重新指定一份；
  /// 换其它音源播放不受影响。
  Future<void> deleteLyricAssociation(Song song) async {
    // 让正在进行的歌词加载作废，避免它回来后把清空的状态覆盖掉。
    _requestId++;
    _rawLines = null;
    _noLyricKey = null;
    await LyricCache.remove(song);
    await LyricCache.markDeleted(song);
    if (state.currentSongId == song.id &&
        (state.currentSongSource == null ||
            state.currentSongSource == song.lyricSourceId)) {
      state = LyricState(
        error: tr('暂无歌词'),
        currentSongId: song.id,
        currentSongSource: song.lyricSourceId,
      );
    }
  }

  void clear() {
    state = const LyricState();
  }
}

final lyricControllerProvider = StateNotifierProvider<LyricController, LyricState>((
  ref,
) {
  final musicSourceManager = ref.watch(musicSourceManagerProvider);
  final ttmlDbService = ref.watch(ttmlDbServiceProvider);
  final controller = LyricController(musicSourceManager, ttmlDbService);
  controller.applyLyricLocale(ref.read(effectiveLyricLocaleProvider));

  ref.listen<PlaybackState>(playbackControllerProvider, (previous, next) {
    final previousSong = previous?.currentSong;
    final nextSong = next.currentSong;
    // 同一首歌换了音源（插件变体）时 id 不变，但歌词要按新音源重取。
    if (nextSong?.id != previousSong?.id ||
        nextSong?.lyricSourceId != previousSong?.lyricSourceId) {
      if (kDebugMode) {
        debugPrint(
          '[LyricController] Song changed from ${previousSong?.title} to ${nextSong?.title}',
        );
      }
      Future.microtask(() => controller.loadLyrics(nextSong));
    }
  });

  // 歌词语言(跟随界面/简体/繁体)变化时只重跑繁简转换。
  ref.listen<AppLocale>(effectiveLyricLocaleProvider, (previous, next) {
    controller.applyLyricLocale(next);
  });

  return controller;
});
