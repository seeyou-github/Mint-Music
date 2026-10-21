import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../player/domain/models/song.dart';

/// 弹出「歌曲信息对比」全屏弹窗。
///
/// 左边是原歌曲，右边是网络下载回来的候选；中间每个项目旁边有一个
/// 「←」按钮，点一下就采用**下载版本**的那一项（封面 / 歌曲信息 / 歌词）。
///
/// 宽度够时左右排列，不够时上下排列。
///
/// 返回合并后的歌曲；用户取消时返回 null。
Future<Song?> showSongCompareDialog(
  BuildContext context, {
  required Song original,
  required Song candidate,
}) {
  return showDialog<Song>(
    context: context,
    barrierColor: Colors.black54,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(AppSpacing.md),
      child: _SongCompareDialog(original: original, candidate: candidate),
    ),
  );
}

class _SongCompareDialog extends ConsumerStatefulWidget {
  const _SongCompareDialog({required this.original, required this.candidate});

  final Song original;
  final Song candidate;

  @override
  ConsumerState<_SongCompareDialog> createState() => _SongCompareDialogState();
}

class _SongCompareDialogState extends ConsumerState<_SongCompareDialog> {
  /// 候选（网络下载）版本的歌词。
  String? _candidateLyric;
  bool _loadingLyric = true;

  /// 每一项是否采用下载版本：封面 / 歌曲信息 / 歌词。
  bool _useCandidateCover = true;
  bool _useCandidateInfo = true;
  bool _useCandidateLyric = true;

  @override
  void initState() {
    super.initState();
    _fetchCandidateLyric();
  }

  Future<void> _fetchCandidateLyric() async {
    try {
      final manager = ref.read(musicSourceManagerProvider);
      final lyric = await manager.getLyric(widget.candidate);
      if (!mounted) return;
      setState(() {
        _candidateLyric = lyric;
        _loadingLyric = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _candidateLyric = null;
        _loadingLyric = false;
      });
    }
  }

  /// 合并后的歌曲。
  Song _merged() {
    final original = widget.original;
    final candidate = widget.candidate;
    final candidateLyric = _candidateLyric;
    final hasCandidateLyric = candidateLyric != null && candidateLyric.isNotEmpty;

    return original.copyWith(
      title: _useCandidateInfo ? candidate.title : original.title,
      artist: _useCandidateInfo ? candidate.artist : original.artist,
      album: _useCandidateInfo ? candidate.album : original.album,
      coverUrl: _useCandidateCover ? candidate.coverUrl : original.coverUrl,
      hasCover: _useCandidateCover
          ? candidate.coverUrl != null || candidate.hasCover
          : original.hasCover,
      lrc: _useCandidateLyric && hasCandidateLyric
          ? candidateLyric
          : original.lrc,
    );
  }

  void _apply() {
    Navigator.of(context).pop(_merged());
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final width = MediaQuery.of(context).size.width;
    // 宽度不够时改为上下排列。
    final sideBySide = width >= 720;

    final original = widget.original;
    final candidate = widget.candidate;

    final coverRow = _CompareRow(
      label: context.tr('封面'),
      original: _CoverBox(song: original, size: 132),
      candidate: _CoverBox(song: candidate, size: 132),
      useCandidate: _useCandidateCover,
      sideBySide: sideBySide,
      onUseCandidate: () => setState(() => _useCandidateCover = true),
      onUseOriginal: () => setState(() => _useCandidateCover = false),
    );

    final infoRow = _CompareRow(
      label: context.tr('歌曲信息'),
      original: _InfoBox(song: original),
      candidate: _InfoBox(song: candidate),
      useCandidate: _useCandidateInfo,
      sideBySide: sideBySide,
      onUseCandidate: () => setState(() => _useCandidateInfo = true),
      onUseOriginal: () => setState(() => _useCandidateInfo = false),
    );

    final lyricRow = _CompareRow(
      label: context.tr('歌词'),
      original: _LyricBox(
        text: original.lrc,
        loading: false,
        emptyText: context.tr('原歌曲没有歌词'),
      ),
      candidate: _LyricBox(
        text: _candidateLyric,
        loading: _loadingLyric,
        emptyText: context.tr('下载的歌曲没有歌词'),
      ),
      useCandidate: _useCandidateLyric,
      sideBySide: sideBySide,
      onUseCandidate: () => setState(() => _useCandidateLyric = true),
      onUseOriginal: () => setState(() => _useCandidateLyric = false),
    );

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.tr('歌曲信息对比'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: Icon(Icons.close, color: colors.textHint),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  coverRow,
                  const SizedBox(height: AppSpacing.md),
                  infoRow,
                  const SizedBox(height: AppSpacing.md),
                  lyricRow,
                  const SizedBox(height: AppSpacing.md),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    context.tr('取消'),
                    style: TextStyle(color: colors.textHint),
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilledButton(
                  onPressed: _apply,
                  child: Text(context.tr('应用')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 对比中的一行（封面 / 歌曲信息 / 歌词）。
class _CompareRow extends ConsumerWidget {
  const _CompareRow({
    required this.label,
    required this.original,
    required this.candidate,
    required this.useCandidate,
    required this.sideBySide,
    required this.onUseCandidate,
    required this.onUseOriginal,
  });

  final String label;
  final Widget original;
  final Widget candidate;
  final bool useCandidate;
  final bool sideBySide;
  final VoidCallback onUseCandidate;
  final VoidCallback onUseOriginal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);

    final originalBox = _SideBox(
      title: context.tr('原歌曲'),
      child: original,
      highlighted: !useCandidate,
    );
    final candidateBox = _SideBox(
      title: context.tr('下载的歌曲'),
      child: candidate,
      highlighted: useCandidate,
    );

    // 中间的箭头：点一下就采用「下载的」那一版。
    final arrow = IconButton(
      onPressed: onUseCandidate,
      icon: Icon(
        sideBySide ? Icons.arrow_left : Icons.arrow_upward,
        size: 20,
        color: colors.primary,
      ),
      tooltip: context.tr('使用下载的版本'),
      visualDensity: VisualDensity.compact,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: colors.textHint,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        if (sideBySide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: originalBox),
              Column(
                children: [
                  arrow,
                  IconButton(
                    onPressed: onUseOriginal,
                    icon: Icon(
                      sideBySide ? Icons.arrow_right : Icons.arrow_downward,
                      size: 20,
                      color: colors.textHint,
                    ),
                    tooltip: context.tr('保留原来的版本'),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              Expanded(child: candidateBox),
            ],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              originalBox,
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  arrow,
                  IconButton(
                    onPressed: onUseOriginal,
                    icon: Icon(
                      Icons.arrow_downward,
                      size: 20,
                      color: colors.textHint,
                    ),
                    tooltip: context.tr('保留原来的版本'),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              candidateBox,
            ],
          ),
      ],
    );
  }
}

/// 对比中的一侧。
class _SideBox extends ConsumerWidget {
  const _SideBox({
    required this.title,
    required this.child,
    required this.highlighted,
  });

  final String title;
  final Widget child;
  final bool highlighted;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 2),
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: highlighted
            ? colors.primary.withValues(alpha: 0.08)
            : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: highlighted ? colors.primary : colors.divider,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: highlighted ? colors.primary : colors.textHint,
            ),
          ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

/// 封面预览。
class _CoverBox extends ConsumerWidget {
  const _CoverBox({required this.song, required this.size});

  final Song song;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final hasRemote = song.coverUrl != null && song.coverUrl!.isNotEmpty;
    final hasLocal = song.hasCover;
    if (!hasRemote && !hasLocal) {
      return SizedBox(
        width: size,
        height: size,
        child: Container(
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(Icons.music_note, size: 32, color: colors.textHint),
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: MusicCoverImage(
        url: song.coverUrl,
        songId: song.id,
        mediaStoreId: song.mediaStoreId,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: Container(
          width: size,
          height: size,
          color: colors.surfaceVariant,
          child: Icon(Icons.music_note, size: 32, color: colors.textHint),
        ),
      ),
    );
  }
}

/// 歌曲信息预览。
class _InfoBox extends ConsumerWidget {
  const _InfoBox({required this.song});

  final Song song;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    Widget line(String text, {bool strong = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: strong ? 13 : 12,
          fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
          color: strong ? colors.textPrimary : colors.textSecondary,
        ),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        line(song.title, strong: true),
        line(song.artist),
        line(song.album),
      ],
    );
  }
}

/// 歌词预览（可滚动浏览）。
class _LyricBox extends ConsumerWidget {
  const _LyricBox({
    required this.text,
    required this.loading,
    required this.emptyText,
  });

  final String? text;
  final bool loading;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    if (loading) {
      return const SizedBox(
        height: 100,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final content = (text == null || text!.trim().isEmpty)
        ? Text(
            emptyText,
            style: TextStyle(fontSize: 12, color: colors.textHint),
          )
        : Text(
            text!,
            style: TextStyle(fontSize: 12, color: colors.textSecondary, height: 1.5),
          );
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: SingleChildScrollView(child: content),
    );
  }
}
