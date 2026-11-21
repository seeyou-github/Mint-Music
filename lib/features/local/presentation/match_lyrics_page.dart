import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../player/application/lyric_controller.dart';
import '../../player/application/lyric_resolver.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/services/embedded_lyrics_writer.dart';
import '../../plugin/application/plugin_providers.dart';
import '../application/lyric_batch_matcher.dart';
import '../application/local_providers.dart';
import '../../library/domain/models/recently_played.dart';
import '../domain/local_song_filter.dart';

/// 匹配歌词页：从匹配歌曲页进入，针对「没有歌词 / 没有逐字歌词」且
/// 歌名 / 歌手 / 专辑 / 年份 / 时长齐备的歌，在网易 / QQ / 酷狗 / 酷我
/// 四个数据源上做五字段完全匹配并取词（逐字优先，带翻译），写回歌曲文件。
///
/// 按「开始匹配」后的要求：页面**只显示匹配成功的歌曲**（实时追加），
/// 失败的歌只推进计数不进列表。点击歌曲行播放该歌。
class MatchLyricsPage extends ConsumerStatefulWidget {
  const MatchLyricsPage({
    super.key,
    required this.songs,
    required this.lyricStatus,
  });

  /// 进入时快速匹配页当前的列表快照（候选范围）。
  final List<Song> songs;

  /// 快速匹配页算好的歌词状态（hasLyric / hasWordLyric）。
  final Map<String, LyricPresence> lyricStatus;

  @override
  ConsumerState<MatchLyricsPage> createState() => _MatchLyricsPageState();
}

class _MatchLyricsPageState extends ConsumerState<MatchLyricsPage> {
  LyricBatchMatcher? _matcher;
  bool _running = false;
  int _done = 0;
  int _total = 0;

  /// 匹配成功的歌（新完成的插在最前面）。
  final List<_MatchedEntry> _matched = [];

  /// 待匹配队列（进页时筛好，不再变化）。
  late final List<Song> _candidates = _buildCandidates();

  List<Song> _buildCandidates() {
    return widget.songs
        .where((song) {
          final status = widget.lyricStatus[song.id];
          final hasLyric = status?.hasLyric ?? false;
          final hasWord = status?.hasWordLyric ?? false;
          // 已有逐字歌词的不需要再匹配；只有整行歌词（缺逐字）或没歌词的才进队列。
          if (hasLyric && hasWord) return false;
          // 五字段完全匹配的前提：歌名 / 歌手 / 专辑 / 年份 / 时长都齐备。
          return song.title.trim().isNotEmpty &&
              song.artist.trim().isNotEmpty &&
              song.album.trim().isNotEmpty &&
              (song.year ?? 0) > 0 &&
              song.duration > 0;
        })
        .toList(growable: false);
  }

  @override
  void dispose() {
    // 离开页面即停止任务（当前这首歌会跑完）。
    _matcher?.stop();
    super.dispose();
  }

  Future<void> _start() async {
    if (_running || _candidates.isEmpty) return;
    final sources = resolveLyricMatchSources(
      ref.read(searchSupportedSourcesProvider),
    );
    if (sources.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('请先在插件管理里启用网易 / QQ / 酷狗 / 酷我数据源')),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }
    final matcher = LyricBatchMatcher(
      resolver: ref.read(lyricResolverProvider),
      manager: ref.read(musicSourceManagerProvider),
      sources: sources,
    );
    setState(() {
      _matcher = matcher;
      _running = true;
      _done = 0;
      _total = _candidates.length;
    });
    try {
      await for (final update in matcher.run(_candidates)) {
        if (!mounted) return;
        final result = update.result;
        if (result != null) await _onMatched(result);
        setState(() => _done = update.done);
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  /// 匹配成功：把歌词写进歌曲文件（与搜索歌词弹框的「保存到歌曲文件」同一
  /// 条写入链路），然后进成功列表。
  Future<void> _onMatched(LyricBatchMatchResult result) async {
    var written = false;
    final path = result.localSong.filePath;
    if (path != null && path.isNotEmpty) {
      written = await EmbeddedLyricsWriter.write(path, result.lyricText);
    }
    if (written) await _syncLocalLyric(result.localSong);
    if (!mounted) return;
    setState(() {
      // 写入失败也进列表（带「写入失败」徽标与重试入口），避免静默丢失。
      _matched.insert(
        0,
        _MatchedEntry(
          song: result.localSong,
          matchedSong: result.matchedSong,
          sourceName: result.sourceName,
          wordByWord: result.wordByWord,
          lyricText: result.lyricText,
          written: written,
        ),
      );
    });
  }

  /// 写文件成功后把索引里残留的歌词清掉（本地歌曲的歌词只认歌曲文件），
  /// 并让歌词控件按文件重新解析（与搜索歌词弹框同一套同步逻辑）。
  Future<void> _syncLocalLyric(Song song) async {
    try {
      final indexed =
          ref.read(localMusicRepositoryProvider).getSongById(song.id) ?? song;
      final hasStale = (indexed.lrc ?? '').trim().isNotEmpty;
      if (hasStale) {
        await ref
            .read(localMusicNotifierProvider.notifier)
            .upsertSong(indexed.copyWith(clearLrc: true), forceOverwrite: true);
      }
      await ref
          .read(lyricControllerProvider.notifier)
          .onLyricsWritten(
            hasStale ? indexed.copyWith(clearLrc: true) : indexed,
          );
    } catch (_) {}
  }

  /// 写入失败的单首重试。
  Future<void> _retryWrite(int index) async {
    final entry = _matched[index];
    final path = entry.song.filePath;
    if (path == null || path.isEmpty) return;
    final ok = await EmbeddedLyricsWriter.write(path, entry.lyricText);
    if (!ok || !mounted) return;
    await _syncLocalLyric(entry.song);
    if (!mounted) return;
    setState(() => _matched[index] = entry.copyWith(written: true));
  }

  /// 点击歌曲行：播放这首（队列 = 当前成功列表）。
  void _playSong(int index) {
    final songs = _matched.map((entry) => entry.song).toList();
    if (songs.isEmpty) return;
    PlaybackContext.instance.set(PlaybackSourceType.local);
    ref
        .read(playbackControllerProvider.notifier)
        .setQueue(
          songs,
          startIndex: index >= 0 && index < songs.length ? index : 0,
        );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(colors),
            if (_running || _done > 0) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: LinearProgressIndicator(
                  value: _total > 0 ? (_done / _total).clamp(0.0, 1.0) : null,
                  minHeight: 3,
                  color: colors.primary,
                  backgroundColor: colors.surfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.xs),
            Expanded(child: _buildBody(colors)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        4,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.tr('匹配歌词'),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          Text(
            context.tr('成功 ${_matched.length} / 待匹配 ${_candidates.length}'),
            style: TextStyle(fontSize: 13, color: colors.textHint),
          ),
          IconButton(
            tooltip: context.tr('关闭'),
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close, size: 22, color: colors.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeColors colors) {
    if (_candidates.isEmpty) {
      return Center(
        child: Text(
          context.tr('没有需要匹配的歌词（都有逐字歌词，或歌曲信息不齐）'),
          style: TextStyle(color: colors.textHint, fontSize: 14),
        ),
      );
    }
    if (_matched.isEmpty && !_running) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr('待匹配 ${_candidates.length} 首'),
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: _start,
              icon: const Icon(Icons.auto_fix_high, size: 18),
              label: Text(context.tr('开始匹配')),
            ),
          ],
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              if (!_running)
                FilledButton.icon(
                  onPressed: _matched.length < _candidates.length
                      ? _start
                      : null,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: Text(
                    context.tr(
                      _matched.length >= _candidates.length ? '已完成' : '继续匹配',
                    ),
                  ),
                ),
              if (_running)
                Text(
                  context.tr('匹配中 $_done/$_total …'),
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
              const Spacer(),
              if (_running)
                TextButton.icon(
                  onPressed: _matcher?.stop,
                  icon: const Icon(Icons.stop, size: 16),
                  label: Text(context.tr('停止')),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            itemCount: _matched.length,
            itemBuilder: (context, index) =>
                _buildMatchedRow(colors, index, _matched[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildMatchedRow(ThemeColors colors, int index, _MatchedEntry entry) {
    final song = entry.song;
    final statusText = entry.written
        ? (entry.wordByWord
              ? context.tr('逐字 + 翻译 · ${entry.sourceName}')
              : context.tr('非逐字 · ${entry.sourceName}'))
        : context.tr('写入失败（点右侧重试）');
    final statusColor = entry.written ? colors.primary : colors.error;
    return InkWell(
      onTap: () => _playSong(index),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colors.divider.withValues(alpha: 0.4)),
          ),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 44,
                height: 44,
                child: MusicCoverImage(
                  // 显示本地歌曲文件内置封面（从音频文件 / MediaStore 取），
                  // 不用在线候选的封面。
                  songId: song.id,
                  filePath: song.filePath,
                  fit: BoxFit.cover,
                  errorWidget: Icon(
                    Icons.music_note,
                    size: 18,
                    color: colors.textHint,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${song.artist} · ${song.album}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              song.displayDuration,
              style: TextStyle(fontSize: 11, color: colors.textHint),
            ),
            const SizedBox(width: AppSpacing.md),
            if (!entry.written)
              IconButton(
                tooltip: context.tr('重试写入'),
                onPressed: () => unawaited(_retryWrite(index)),
                icon: Icon(Icons.refresh, size: 18, color: colors.primary),
              ),
            Text(
              statusText,
              style: TextStyle(fontSize: 11, color: statusColor),
            ),
          ],
        ),
      ),
    );
  }
}

/// 成功列表的一行。
class _MatchedEntry {
  const _MatchedEntry({
    required this.song,
    required this.matchedSong,
    required this.sourceName,
    required this.wordByWord,
    required this.lyricText,
    required this.written,
  });

  final Song song;
  final Song matchedSong;
  final String sourceName;
  final bool wordByWord;
  final String lyricText;
  final bool written;

  _MatchedEntry copyWith({bool? written}) => _MatchedEntry(
    song: song,
    matchedSong: matchedSong,
    sourceName: sourceName,
    wordByWord: wordByWord,
    lyricText: lyricText,
    written: written ?? this.written,
  );
}
