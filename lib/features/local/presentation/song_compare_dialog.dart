import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../player/domain/models/song.dart';
import '../data/local_metadata_reader.dart';

/// 弹出「歌曲信息对比」全屏弹窗。
///
/// 左边是原歌曲，右边是网络下载回来的候选；中间每个项目旁边有一个箭头
/// 按钮，点一下就在「原歌曲 / 下载的歌曲」之间切换（箭头指向当前采用的
/// 那一侧：横向是「从右到左」，纵向是「从下到上」）。
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

  /// 原歌曲文件里内嵌的歌词与年份（本地扫描时没有读出来，这里现读）。
  String? _originalLyric;
  int? _originalYear;
  bool _loadingOriginal = true;

  /// 每一项是否采用下载版本：封面 / 歌曲信息 / 歌词。
  bool _useCandidateCover = true;
  bool _useCandidateInfo = true;
  bool _useCandidateLyric = true;

  @override
  void initState() {
    super.initState();
    _fetchCandidateLyric();
    _loadOriginalMetadata();
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

  /// 读取原歌曲文件里的标签：年份与内嵌歌词。
  ///
  /// 本地扫描时只取了标题 / 歌手 / 专辑，文件里写了年份或歌词时这里能补上。
  Future<void> _loadOriginalMetadata() async {
    final path = widget.original.filePath;
    if (path == null || path.isEmpty) {
      if (mounted) setState(() => _loadingOriginal = false);
      return;
    }
    try {
      final metadata = await LocalMetadataReader.read(path);
      if (!mounted) return;
      setState(() {
        _originalLyric = metadata.lyrics;
        _originalYear = metadata.year;
        _loadingOriginal = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingOriginal = false);
    }
  }

  /// 原歌曲的歌词：优先用歌曲自带的，没有再用文件里内嵌的。
  String? get _originalLyricText {
    final lrc = widget.original.lrc;
    if (lrc != null && lrc.trim().isNotEmpty) return lrc;
    final embedded = _originalLyric;
    if (embedded != null && embedded.trim().isNotEmpty) return embedded;
    return null;
  }

  /// 原歌曲的年份：歌曲里的没有就用文件标签里的。
  int? get _originalYearText {
    return widget.original.year ?? _originalYear;
  }

  /// 合并后的歌曲。
  ///
  /// 注意：不写入「流派」——下载歌曲与对比页面都不往本地文件里写流派。
  Song _merged() {
    final original = widget.original;
    final candidate = widget.candidate;
    final candidateLyric = _candidateLyric;
    final hasCandidateLyric = candidateLyric != null && candidateLyric.isNotEmpty;
    final originalLyric = _originalLyricText;

    final year = _useCandidateInfo
        ? (candidate.year ?? original.year ?? _originalYear)
        : (original.year ?? _originalYear);

    return original.copyWith(
      title: _useCandidateInfo ? candidate.title : original.title,
      artist: _useCandidateInfo ? candidate.artist : original.artist,
      album: _useCandidateInfo ? candidate.album : original.album,
      year: year,
      coverUrl: _useCandidateCover ? candidate.coverUrl : original.coverUrl,
      hasCover: _useCandidateCover
          ? candidate.coverUrl != null || candidate.hasCover
          : original.hasCover,
      lrc: _useCandidateLyric && hasCandidateLyric
          ? candidateLyric
          : originalLyric,
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
      onToggle: () => setState(() => _useCandidateCover = !_useCandidateCover),
    );

    final infoRow = _CompareRow(
      label: context.tr('歌曲信息'),
      original: _InfoBox(
        song: original,
        year: _originalYearText,
        loading: _loadingOriginal,
      ),
      candidate: _InfoBox(song: candidate, year: candidate.year),
      useCandidate: _useCandidateInfo,
      sideBySide: sideBySide,
      onToggle: () => setState(() => _useCandidateInfo = !_useCandidateInfo),
    );

    final lyricRow = _CompareRow(
      label: context.tr('歌词'),
      original: _LyricBox(
        text: _originalLyricText,
        loading: _loadingOriginal,
        emptyText: context.tr('原歌曲没有歌词'),
      ),
      candidate: _LyricBox(
        text: _candidateLyric,
        loading: _loadingLyric,
        emptyText: context.tr('下载的歌曲没有歌词'),
      ),
      useCandidate: _useCandidateLyric,
      sideBySide: sideBySide,
      onToggle: () => setState(() => _useCandidateLyric = !_useCandidateLyric),
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
    required this.onToggle,
  });

  final String label;
  final Widget original;
  final Widget candidate;
  final bool useCandidate;
  final bool sideBySide;
  final VoidCallback onToggle;

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

    // 中间只有一个箭头按钮：点一下在「原歌曲 / 下载的歌曲」之间切换。
    // 箭头指向当前采用的那一侧（横向从右到左、纵向从下到上）。
    final arrow = _ArrowToggleButton(
      sideBySide: sideBySide,
      useCandidate: useCandidate,
      onPressed: onToggle,
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(child: originalBox),
              arrow,
              Expanded(child: candidateBox),
            ],
          )
        else
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              originalBox,
              Center(child: arrow),
              candidateBox,
            ],
          ),
      ],
    );
  }
}

/// 中间的箭头切换按钮。
class _ArrowToggleButton extends ConsumerWidget {
  const _ArrowToggleButton({
    required this.sideBySide,
    required this.useCandidate,
    required this.onPressed,
  });

  final bool sideBySide;
  final bool useCandidate;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    // 当前采用下载版本 → 箭头指向左边（原歌曲那一侧），表示「值来自右边」。
    final icon = sideBySide
        ? (useCandidate ? Icons.arrow_left : Icons.arrow_right)
        : (useCandidate ? Icons.arrow_upward : Icons.arrow_downward);
    final message = useCandidate
        ? context.tr('当前使用下载的版本，点击改用原歌曲')
        : context.tr('当前使用原歌曲，点击改用下载的版本');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Tooltip(
        message: message,
        child: Material(
          color: useCandidate
              ? colors.primary.withValues(alpha: 0.16)
              : colors.surfaceVariant,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 46,
              height: 46,
              child: Icon(
                icon,
                size: 28,
                color: useCandidate ? colors.primary : colors.textSecondary,
              ),
            ),
          ),
        ),
      ),
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
          // 撑满整行宽度：歌词框与上方歌曲信息框一样宽，滚动条也紧贴右边。
          SizedBox(width: double.infinity, child: child),
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
      return Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: size,
          height: size,
          child: Container(
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(Icons.music_note, size: 32, color: colors.textHint),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: ClipRRect(
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
      ),
    );
  }
}

/// 歌曲信息预览。
///
/// 排版固定为「歌曲名 / 歌手 / 专辑 / 年份」，标签右对齐，冒号对齐。
class _InfoBox extends ConsumerWidget {
  const _InfoBox({
    required this.song,
    required this.year,
    this.loading = false,
  });

  final Song song;
  final int? year;
  final bool loading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);

    Widget field(String label, String value, {bool strong = false}) {
      final labelStyle = TextStyle(
        fontSize: 12,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
        color: strong ? colors.textPrimary : colors.textHint,
      );
      final valueStyle = TextStyle(
        fontSize: 12,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
        color: strong ? colors.textPrimary : colors.textSecondary,
      );
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 38,
              child: Text(label, textAlign: TextAlign.right, style: labelStyle),
            ),
            Text('：', style: labelStyle),
            Expanded(
              child: Text(
                value,
                style: valueStyle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    if (loading) {
      return const SizedBox(
        height: 76,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field(context.tr('歌曲名'), song.title, strong: true),
        field(context.tr('歌手'), song.artist),
        field(context.tr('专辑'), song.album),
        field(context.tr('年份'), year?.toString() ?? '-'),
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
    return SizedBox(
      width: double.infinity,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 160),
        child: SingleChildScrollView(
          // 右侧留一点位置，滚动条不会压住歌词。
          padding: const EdgeInsets.only(right: 6),
          child: content,
        ),
      ),
    );
  }
}
