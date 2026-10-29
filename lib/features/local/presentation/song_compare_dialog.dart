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
/// 左边是原歌曲，右边是网络下载回来的候选，按「封面 / 歌曲信息 / 歌词」分成
/// 三行两列。**直接点某个卡片即选中那一侧**（选中的卡片是绿框，右上角带红色
/// 「已选择」标签），不再用中间的箭头按钮切换。
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
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
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

  /// 候选歌曲的发行年份。
  ///
  /// 插件搜索里有的直接给，没有的（酷狗 / 酷我等）按专辑 id 现查一次。
  int? _candidateYear;
  bool _loadingCandidateYear = false;

  /// 每一项是否采用下载版本：封面 / 歌曲信息 / 歌词。
  bool _useCandidateCover = true;
  bool _useCandidateInfo = true;
  bool _useCandidateLyric = true;

  @override
  void initState() {
    super.initState();
    _fetchCandidateLyric();
    _loadOriginalMetadata();
    _resolveCandidateYear();
  }

  /// 拉取下载版本的歌词。
  ///
  /// 用 getLyricResult 而不是 getLyric：插件把逐字歌词
  /// 放在 crlyric 里，getLyric 只会给整行时间轴的 lrc，逐字歌词就丢了。
  Future<void> _fetchCandidateLyric() async {
    try {
      final manager = ref.read(musicSourceManagerProvider);
      final result = await manager.getLyricResult(widget.candidate);
      final wordLyric = result?.crlyric?.trim() ?? '';
      final plainLyric = result?.lrc?.trim() ?? '';
      final lyric = wordLyric.isNotEmpty
          ? result!.crlyric
          : (plainLyric.isNotEmpty ? result!.lrc : null);
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

  /// 补查候选歌曲的发行年份（搜索没给年份时按专辑查一次）。
  Future<void> _resolveCandidateYear() async {
    final candidate = widget.candidate;
    if (candidate.year != null && candidate.year! > 0) {
      _candidateYear = candidate.year;
      return;
    }
    if (mounted) setState(() => _loadingCandidateYear = true);
    int? year;
    try {
      year = await ref
          .read(musicSourceManagerProvider)
          .resolveSongYear(candidate);
    } catch (_) {
      year = null;
    }
    if (!mounted) return;
    setState(() {
      _candidateYear = year;
      _loadingCandidateYear = false;
    });
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
    final hasCandidateLyric =
        candidateLyric != null && candidateLyric.isNotEmpty;
    final originalLyric = _originalLyricText;

    final candidateYear = _candidateYear ?? candidate.year;
    final year = _useCandidateInfo
        ? (candidateYear ?? original.year ?? _originalYear)
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
      original: _CoverBox(song: original, size: 132),
      candidate: _CoverBox(song: candidate, size: 132),
      useCandidate: _useCandidateCover,
      sideBySide: sideBySide,
      onSelect: (useCandidate) =>
          setState(() => _useCandidateCover = useCandidate),
    );

    final infoRow = _CompareRow(
      original: _InfoBox(
        song: original,
        year: _originalYearText,
        loading: _loadingOriginal,
      ),
      candidate: _InfoBox(
        song: candidate,
        year: _candidateYear ?? candidate.year,
        yearLoading: _loadingCandidateYear && _candidateYear == null,
      ),
      useCandidate: _useCandidateInfo,
      sideBySide: sideBySide,
      onSelect: (useCandidate) =>
          setState(() => _useCandidateInfo = useCandidate),
    );

    final lyricRow = _CompareRow(
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
      onSelect: (useCandidate) =>
          setState(() => _useCandidateLyric = useCandidate),
    );

    return Material(
      color: colors.surface,
      borderRadius: BorderRadius.circular(AppRadius.lg),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.md,
                AppSpacing.xs,
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
            // 顶部提示：告诉用户要手动挑，而不是自动合并。
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  context.tr('请手动选择要使用的信息：'),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: colors.error,
                  ),
                ),
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    coverRow,
                    const SizedBox(height: AppSpacing.md),
                    infoRow,
                    const SizedBox(height: AppSpacing.md),
                    lyricRow,
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
      ),
    );
  }
}

/// 对比中的一行（封面 / 歌曲信息 / 歌词）。
///
/// 一行里左右各一张卡片，**点哪张就选中哪张**（不需要中间的箭头按钮）：
/// 选中的卡片是绿框 + 右上角红色「已选择」。
class _CompareRow extends StatelessWidget {
  const _CompareRow({
    required this.original,
    required this.candidate,
    required this.useCandidate,
    required this.sideBySide,
    required this.onSelect,
  });

  final Widget original;
  final Widget candidate;
  final bool useCandidate;
  final bool sideBySide;

  /// 选中某一侧：true = 下载的歌曲，false = 原歌曲。
  final ValueChanged<bool> onSelect;

  @override
  Widget build(BuildContext context) {
    final originalBox = _SideBox(
      title: context.tr('原歌曲'),
      selected: !useCandidate,
      onTap: () => onSelect(false),
      child: original,
    );
    final candidateBox = _SideBox(
      title: context.tr('下载的歌曲'),
      selected: useCandidate,
      onTap: () => onSelect(true),
      child: candidate,
    );

    if (!sideBySide) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          originalBox,
          const SizedBox(height: AppSpacing.sm),
          candidateBox,
        ],
      );
    }
    // IntrinsicHeight：同一行的两张卡片高度对齐（图片 / 信息 / 歌词都一样）。
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: originalBox),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: candidateBox),
        ],
      ),
    );
  }
}

/// 对比中的一侧：可点击的卡片。
///
/// 选中态：主题色描边 + 右上角红色「已选择」标签。
class _SideBox extends ConsumerWidget {
  const _SideBox({
    required this.title,
    required this.child,
    required this.selected,
    required this.onTap,
  });

  final String title;
  final Widget child;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    return Material(
      color: selected
          ? colors.primary.withValues(alpha: 0.10)
          : colors.surfaceVariant.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(
              color: selected ? colors.primary : colors.divider,
              width: selected ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected ? colors.primary : colors.textHint,
                      ),
                    ),
                  ),
                  if (selected) ...[
                    const SizedBox(width: AppSpacing.xs),
                    _SelectedBadge(color: colors.error),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              // 撑满整行宽度：歌词框与上方歌曲信息框一样宽，滚动条也紧贴右边。
              SizedBox(width: double.infinity, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 选中卡片右上角的红色「已选择」标签。
class _SelectedBadge extends StatelessWidget {
  const _SelectedBadge({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.75)),
      ),
      child: Text(
        context.tr('已选择'),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
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
/// 排版固定为「歌曲 / 歌手 / 专辑 / 年份」，标签右对齐，冒号对齐。
class _InfoBox extends ConsumerWidget {
  const _InfoBox({
    required this.song,
    required this.year,
    this.loading = false,
    this.yearLoading = false,
  });

  final Song song;
  final int? year;
  final bool loading;

  /// 年份还在补查（显示「…」而不是「-」）。
  final bool yearLoading;

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
        field(context.tr('歌曲'), song.title, strong: true),
        field(context.tr('歌手'), song.artist),
        field(context.tr('专辑'), song.album),
        field(context.tr('年份'), yearLoading ? '…' : (year?.toString() ?? '-')),
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
        height: _lyricBoxHeight,
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
            style: TextStyle(
              fontSize: 12,
              color: colors.textSecondary,
              height: 1.5,
            ),
          );
    // 固定高度：左右两张歌词卡片高度一致（外层用 IntrinsicHeight 对齐）。
    return SizedBox(
      width: double.infinity,
      height: _lyricBoxHeight,
      child: SingleChildScrollView(
        // 右侧留一点位置，滚动条不会压住歌词。
        padding: const EdgeInsets.only(right: 6),
        child: content,
      ),
    );
  }

  static const double _lyricBoxHeight = 150;
}
