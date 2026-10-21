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
import '../domain/services/embedded_lyrics_extractor.dart';
import '../domain/services/ttml_db_service.dart';
import '../domain/services/ttml_parser.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/application/plugin_providers.dart';
import 'playback_controller.dart';

class LyricState {
  final List<LyricLine> lines;
  final bool isLoading;
  final String? error;
  final String? currentSongId;
  final String? currentSongSource;
  final bool hasYrc;

  const LyricState({
    this.lines = const [],
    this.isLoading = false,
    this.error,
    this.currentSongId,
    this.currentSongSource,
    this.hasYrc = false,
  });

  LyricState copyWith({
    List<LyricLine>? lines,
    bool? isLoading,
    String? error,
    String? currentSongId,
    String? currentSongSource,
    bool? hasYrc,
  }) {
    return LyricState(
      lines: lines ?? this.lines,
      isLoading: isLoading ?? this.isLoading,
      error: error,
      currentSongId: currentSongId ?? this.currentSongId,
      currentSongSource: currentSongSource ?? this.currentSongSource,
      hasYrc: hasYrc ?? this.hasYrc,
    );
  }
}

class LyricController extends StateNotifier<LyricState> {
  final MusicSourceManager _musicSourceManager;
  final TtmlDbService _ttmlDbService;
  int _requestId = 0;
  static const Duration _lyricFetchTimeout = Duration(seconds: 10);

  /// 当前歌词语言。由 [applyLyricLocale] 设置(初始值来自
  /// effectiveLyricLocaleProvider),繁体时对歌词做简->繁转换。
  AppLocale _locale = AppLocale.zhCn;

  /// 最近一次解析出的简体原始歌词行,切换语言时据此重建,
  /// 避免繁体状态下无法还原回简体。
  List<LyricLine>? _rawLines;

  LyricController(this._musicSourceManager, this._ttmlDbService)
    : super(const LyricState());

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
      adLibText: line.adLibText == null ? null : HanConverter.s2t(line.adLibText!),
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
        for (final w in words)
          w.copyWith(word: HanConverter.s2t(w.word)),
      ];
    }
    final result = <LyricWord>[];
    var offset = 0;
    for (final w in words) {
      final len = w.word.length;
      result.add(w.copyWith(word: convertedPlain.substring(offset, offset + len)));
      offset += len;
    }
    return result;
  }

  Future<void> loadLyrics(Song? song) async {
    if (song == null) {
      debugPrint('[LyricController] song is null, clearing lyrics');
      state = const LyricState();
      return;
    }

    debugPrint(
      '[LyricController] loadLyrics called for song: ${song.title}, id: ${song.id}, source: ${song.source}',
    );

    if (state.currentSongId == song.id &&
        state.currentSongSource == song.source &&
        state.lines.isNotEmpty) {
      debugPrint('[LyricController] Same song and lyrics already loaded');
      return;
    }

    final requestId = ++_requestId;
    state = LyricState(
      // 换歌时先清空上一首歌的歌词：新歌歌词还在加载时继续显示上一首的词，
      // 会让人以为歌词没换。
      lines: const [],
      isLoading: true,
      currentSongId: song.id,
      currentSongSource: song.source,
      hasYrc: false,
    );

    try {
      String? lrc = song.lrc;
      String? crlyric;
      String? tlyric;
      String? rlyric;
      String? ttmlText;
      List<LyricLine>? ttmlLines;

      // Step 0: 本地缓存。歌词来自网络，命中缓存就不用再请求，切歌时歌词
      // 立刻出现。
      final cached = await LyricCache.read(song);
      if (requestId != _requestId) return;

      if (cached != null) {
        // 缓存命中：直接用缓存里的歌词，不再请求网络。
        if (cached.lrc?.isNotEmpty ?? false) lrc = cached.lrc;
        crlyric = cached.crlyric;
        tlyric = cached.tlyric;
        rlyric = cached.rlyric;
        ttmlText = cached.ttml;
        if (ttmlText != null) {
          final lines = parseTtml(ttmlText);
          ttmlLines = lines.isEmpty ? null : lines;
        }
      } else {
        // Step 1 / 2 并行：TTML 词库与在线歌词各是一次网络请求，串行等待会
        // 让歌词出现得很慢（切歌时尤其明显），这里让两个请求同时发出。
        final sourceSupportsWordLyric =
            song.source == 'tx' ||
            song.source == 'wy' ||
            song.source == 'kw' ||
            song.source == 'kg';
        final needOnlineLyric =
            (lrc == null || lrc.isEmpty) || sourceSupportsWordLyric;

        Future<String?>? ttmlTextFuture;
        Future<List<LyricLine>?>? ttmlFuture;
        if (song.source == 'wy' || song.source == 'tx') {
          final cleanId = song.id.replaceAll('wy_', '').replaceAll('tx_', '');
          ttmlTextFuture = _ttmlDbService
              .fetchTtmlText(song.source!, cleanId)
              .timeout(_lyricFetchTimeout);
          ttmlFuture = ttmlTextFuture.then((text) {
            if (text == null) return null;
            final lines = parseTtml(text);
            return lines.isEmpty ? null : lines;
          });
        }

        Future<LyricResult?>? onlineFuture;
        if (needOnlineLyric && song.source != null && song.source != 'local') {
          onlineFuture = _musicSourceManager
              .getLyricResult(song)
              .timeout(_lyricFetchTimeout);
        }

        // Step 1: TTML 词库（wy / tx）
        if (ttmlFuture != null) {
          try {
            ttmlLines = await ttmlFuture;
          } catch (_) {
            ttmlLines = null;
          }
          if (requestId != _requestId) return;
        }

        // Step 2: 在线歌词（普通 LRC / 逐字歌词 / 翻译 / 音译）
        if (onlineFuture != null) {
          LyricResult? result;
          try {
            result = await onlineFuture;
          } catch (_) {
            result = null;
          }
          if (requestId != _requestId) return;
          if (result != null) {
            if (result.crlyric?.trim().isNotEmpty ?? false) {
              crlyric = result.crlyric;
            }
            if ((lrc == null || lrc.isEmpty) &&
                (result.lrc?.trim().isNotEmpty ?? false)) {
              lrc = result.lrc;
            }
            tlyric = result.tlyric;
            rlyric = result.rlyric;
          }
        }

        if (ttmlTextFuture != null) {
          try {
            ttmlText = await ttmlTextFuture;
          } catch (_) {
            ttmlText = null;
          }
        }
      }
      if (requestId != _requestId) return;

      // 拿到歌词后写入缓存，下次播放直接命中（命中缓存时不用重复写）。
      if (cached == null) {
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

      if (song.isLocal && (lrc == null || lrc.isEmpty)) {
        try {
          lrc = await EmbeddedLyricsExtractor.extract(
            song.filePath!,
          ).timeout(_lyricFetchTimeout);
        } catch (_) {
          lrc = null;
        }
      }

      // Step 3: TTML path — use TTML lines as base, merge tlyric/rlyric
      if (ttmlLines != null && ttmlLines.isNotEmpty) {
        final ttmlHasYrc = ttmlLines.any((line) => line.isYrc);
        final onlineHasYrc =
            crlyric != null &&
            crlyric.isNotEmpty &&
            parseLyricAuto(crlyric).any((line) => line.isYrc);

        if (!onlineHasYrc || ttmlHasYrc) {
          debugPrint(
            '[LyricController] DEBUG TTML BEFORE tlyric: tlyric=${tlyric != null ? "${tlyric.length}chars" : "null"}',
          );
          ttmlLines = sanitizeLyricLines(ttmlLines);

          if (tlyric != null && tlyric.isNotEmpty) {
            ttmlLines = mergeTranslation(ttmlLines, tlyric);
            ttmlLines = stripTranslationFromWords(ttmlLines);
          }
          ttmlLines = extractAdLibWords(ttmlLines);
          if (rlyric != null && rlyric.isNotEmpty) {
            ttmlLines = mergeRomanLyric(ttmlLines, rlyric);
          }

          final hasYrc = ttmlLines.any((line) => line.isYrc);

          _rawLines = ttmlLines;
          state = LyricState(
            lines: _convertLines(ttmlLines),
            currentSongId: song.id,
            hasYrc: hasYrc,
          );
          return;
        }

        debugPrint(
          '[LyricController] Prefer online word lyric over non-word TTML',
        );
      }

      if (requestId != _requestId) return;

      if ((lrc == null || lrc.isEmpty) &&
          (crlyric == null || crlyric.isEmpty)) {
        state = LyricState(error: tr('暂无歌词'), currentSongId: song.id);
        return;
      }

      List<LyricLine> parsedLines;

      final lyricCandidates = <String>[
        if (crlyric != null && crlyric.isNotEmpty) crlyric,
        if (lrc != null && lrc.isNotEmpty) lrc,
      ];

      if (lyricCandidates.isNotEmpty) {
        parsedLines = [];
        for (final candidate in lyricCandidates) {
          final parsed = parseLyricAuto(candidate);
          debugPrint(
            '[LyricController] candidate(${candidate.length}chars) => ${parsed.length} lines, hasYrc=${parsed.any((l) => l.isYrc)}',
          );
          if (parsed.isEmpty) continue;

          final candidateHasYrc = parsed.any((line) => line.isYrc);
          if (candidateHasYrc || parsedLines.isEmpty) {
            parsedLines = parsed;
          }
          if (candidateHasYrc) break;
        }
        debugPrint(
          '[LyricController] final parsedLines=${parsedLines.length} hasYrc=${parsedLines.any((l) => l.isYrc)}',
        );

        if (tlyric != null && tlyric.isNotEmpty) {
          parsedLines = mergeTranslation(parsedLines, tlyric);
          parsedLines = stripTranslationFromWords(parsedLines);
        }
        parsedLines = extractAdLibWords(parsedLines);
        if (rlyric != null && rlyric.isNotEmpty) {
          parsedLines = mergeRomanLyric(parsedLines, rlyric);
        }
      } else {
        parsedLines = [];
      }

      if (requestId != _requestId) return;

      if (parsedLines.isEmpty) {
        state = LyricState(error: tr('歌词解析失败'), currentSongId: song.id);
        return;
      }

      parsedLines = sanitizeLyricLines(parsedLines);

      final hasYrc = parsedLines.any((line) => line.isYrc);

      _rawLines = parsedLines;
      state = LyricState(
        lines: _convertLines(parsedLines),
        currentSongId: song.id,
        hasYrc: hasYrc,
      );
    } catch (e, stack) {
      debugPrint('[LyricController] Error loading lyrics: $e');
      debugPrint('[LyricController] Stack: $stack');
      if (requestId != _requestId) return;
      state = LyricState(error: tr('加载歌词失败: $e'), currentSongId: song.id);
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
    if (next.currentSong?.id != previous?.currentSong?.id) {
      debugPrint(
        '[LyricController] Song changed from ${previous?.currentSong?.title} to ${next.currentSong?.title}',
      );
      Future.microtask(() => controller.loadLyrics(next.currentSong));
    }
  });

  // 歌词语言(跟随界面/简体/繁体)变化时只重跑繁简转换。
  ref.listen<AppLocale>(effectiveLyricLocaleProvider, (previous, next) {
    controller.applyLyricLocale(next);
  });

  return controller;
});
