import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../player/domain/models/song.dart';

/// 「编辑标签 - 在线搜索」里的匹配界面组件。
///
/// 原来这里是独立的「匹配歌曲信息」整页（match_song_page.dart），现在搬进
/// 编辑标签的在线搜索页，复用同一套候选卡片 + 三行对比布局。

/// 横向候选列表（桌面端允许鼠标 / 触摸板拖动），默认选中第一个。
class MatchCandidateStrip extends StatelessWidget {
  const MatchCandidateStrip({
    super.key,
    required this.colors,
    required this.results,
    required this.selectedIndex,
    required this.onSelect,
  });

  final ThemeColors colors;
  final List<Song> results;
  final int selectedIndex;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: ScrollConfiguration(
        behavior: const _DragScrollBehavior(),
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          itemCount: results.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, index) => _CandidateCard(
            song: results[index],
            selected: index == selectedIndex,
            colors: colors,
            onTap: () => onSelect(index),
          ),
        ),
      ),
    );
  }
}

/// 候选卡片：封面 + 歌名 + 歌手。
class _CandidateCard extends StatelessWidget {
  const _CandidateCard({
    required this.song,
    required this.selected,
    required this.colors,
    required this.onTap,
  });

  final Song song;
  final bool selected;
  final ThemeColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 210,
        padding: const EdgeInsets.all(AppSpacing.xs),
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.12)
              : colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? colors.primary : colors.divider,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: MusicCoverImage(
                url: song.coverUrl,
                songId: song.id,
                width: 56,
                height: 56,
                errorWidget: Container(
                  width: 56,
                  height: 56,
                  color: colors.surfaceVariant,
                  child: Icon(
                    Icons.music_note,
                    size: 20,
                    color: colors.textHint,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    song.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected ? colors.primary : colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
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

/// 三行对比：封面 / 歌曲信息 / 歌词。
///
/// 每一行左「原歌曲」右「匹配结果」，点哪张就选中哪张（绿框 + 红色「已选择」）。
class MatchCompareView extends StatelessWidget {
  const MatchCompareView({
    super.key,
    required this.colors,
    required this.original,
    required this.candidate,
    required this.originalYear,
    required this.candidateYear,
    required this.originalLyric,
    required this.candidateLyric,
    required this.loadingCandidateLyric,
    required this.useCover,
    required this.useInfo,
    required this.useLyric,
    required this.onUseCover,
    required this.onUseInfo,
    required this.onUseLyric,
  });

  final ThemeColors colors;
  final Song original;
  final Song candidate;
  final int? originalYear;
  final int? candidateYear;
  final String? originalLyric;
  final String? candidateLyric;
  final bool loadingCandidateLyric;
  final bool useCover;
  final bool useInfo;
  final bool useLyric;
  final ValueChanged<bool> onUseCover;
  final ValueChanged<bool> onUseInfo;
  final ValueChanged<bool> onUseLyric;

  @override
  Widget build(BuildContext context) {
    final sideBySide = MediaQuery.sizeOf(context).width >= 760;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildRow(
          context,
          sideBySide: sideBySide,
          useCandidate: useCover,
          onSelect: onUseCover,
          originalChild: _CoverPreview(colors: colors, song: original),
          candidateChild: _CoverPreview(colors: colors, song: candidate),
        ),
        const SizedBox(height: AppSpacing.md),
        _buildRow(
          context,
          sideBySide: sideBySide,
          useCandidate: useInfo,
          onSelect: onUseInfo,
          originalChild: _InfoPreview(
            colors: colors,
            song: original,
            year: originalYear,
          ),
          candidateChild: _InfoPreview(
            colors: colors,
            song: candidate,
            year: candidateYear,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        _buildRow(
          context,
          sideBySide: sideBySide,
          useCandidate: useLyric,
          onSelect: onUseLyric,
          originalChild: _LyricPreview(
            colors: colors,
            text: originalLyric,
            loading: false,
            emptyText: context.tr('原歌曲没有歌词'),
          ),
          candidateChild: _LyricPreview(
            colors: colors,
            text: candidateLyric,
            loading: loadingCandidateLyric,
            emptyText: context.tr('匹配结果没有歌词'),
          ),
        ),
      ],
    );
  }

  Widget _buildRow(
    BuildContext context, {
    required bool sideBySide,
    required bool useCandidate,
    required ValueChanged<bool> onSelect,
    required Widget originalChild,
    required Widget candidateChild,
  }) {
    final originalBox = _SideBox(
      colors: colors,
      title: context.tr('原歌曲'),
      selected: !useCandidate,
      onTap: () => onSelect(false),
      child: originalChild,
    );
    final candidateBox = _SideBox(
      colors: colors,
      title: context.tr('匹配结果'),
      selected: useCandidate,
      onTap: () => onSelect(true),
      child: candidateChild,
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

/// 对比里的一侧（可点击选中）。
class _SideBox extends StatelessWidget {
  const _SideBox({
    required this.colors,
    required this.title,
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final ThemeColors colors;
  final String title;
  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? colors.primary.withValues(alpha: 0.10)
          : colors.surfaceVariant.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(AppRadius.md),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
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
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color: colors.error.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                        border: Border.all(
                          color: colors.error.withValues(alpha: 0.75),
                        ),
                      ),
                      child: Text(
                        context.tr('已选择'),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: colors.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              SizedBox(width: double.infinity, child: child),
            ],
          ),
        ),
      ),
    );
  }
}

/// 封面预览。
class _CoverPreview extends StatelessWidget {
  const _CoverPreview({required this.colors, required this.song});

  final ThemeColors colors;
  final Song song;

  static const double _size = 132;

  @override
  Widget build(BuildContext context) {
    final hasRemote = (song.coverUrl ?? '').isNotEmpty;
    if (!hasRemote && !song.hasCover) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: _size,
          height: _size,
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(Icons.music_note, size: 32, color: colors.textHint),
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
          width: _size,
          height: _size,
          fit: BoxFit.cover,
          errorWidget: Container(
            width: _size,
            height: _size,
            color: colors.surfaceVariant,
            child: Icon(Icons.music_note, size: 32, color: colors.textHint),
          ),
        ),
      ),
    );
  }
}

/// 歌曲信息预览（歌曲 / 歌手 / 专辑 / 年份）。
class _InfoPreview extends StatelessWidget {
  const _InfoPreview({required this.colors, required this.song, this.year});

  final ThemeColors colors;
  final Song song;
  final int? year;

  @override
  Widget build(BuildContext context) {
    Widget field(String label, String value, {bool strong = false}) {
      final labelStyle = TextStyle(
        fontSize: 12,
        fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
        color: strong ? colors.textPrimary : colors.textHint,
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
                value.isEmpty ? '-' : value,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
                  color: strong ? colors.textPrimary : colors.textSecondary,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field(context.tr('歌曲'), song.title, strong: true),
        field(context.tr('歌手'), song.artist),
        field(context.tr('专辑'), song.album),
        field(context.tr('年份'), (year ?? song.year)?.toString() ?? ''),
      ],
    );
  }
}

/// 歌词预览（固定高度，可滚动）。
class _LyricPreview extends StatelessWidget {
  const _LyricPreview({
    required this.colors,
    required this.text,
    required this.loading,
    required this.emptyText,
  });

  final ThemeColors colors;
  final String? text;
  final bool loading;
  final String emptyText;

  static const double _height = 150;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const SizedBox(
        height: _height,
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
    return SizedBox(
      width: double.infinity,
      height: _height,
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(right: 6),
        child: content,
      ),
    );
  }
}

/// 桌面端允许用鼠标 / 触摸板拖动横向列表（Material 默认只接受触摸）。
class _DragScrollBehavior extends MaterialScrollBehavior {
  const _DragScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };
}
