import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../features/blacklist/application/blacklist_providers.dart';
import '../../features/discover/presentation/song_parts_navigation.dart';
import '../../features/player/application/play_progress_providers.dart';
import '../../features/player/domain/models/song.dart';
import '../../features/settings/application/settings_providers.dart';
import '../../shared/services/app_image_cache.dart';
import '../../features/plugin/application/music_source_manager.dart';
import '../../features/plugin/domain/plugin_types.dart';
import '../../features/plugin/application/plugin_providers.dart';
import 'source_name_tag.dart';
import 'song_action_sheet.dart';

class SongListItem extends ConsumerWidget {
  static const double itemExtent = 60;

  final Song song;
  final int? index;
  final bool showIndex;
  final bool showCover;
  final bool showQuality;

  /// 是否在歌曲名下方显示音源名称。
  ///
  /// 默认关闭：各处的歌曲列表（歌单、榜单、我的收藏、收藏的歌单、搜索结果、
  /// 搜索的歌单、下载列表）都不再显示音源名。
  final bool showSource;
  final bool showDuration;
  final bool showMenuButton;

  /// 是否在时长左侧显示「已听 / 已听 N%」标签。
  ///
  /// 只在搜索、歌单、专辑 / 作者、榜单等浏览类列表里打开；
  /// 下载管理等列表不需要这个标记。
  final bool showPlayedTag;
  final VoidCallback? onTap;
  final VoidCallback? onPlayTap;
  final VoidCallback? onMenuTap;
  final bool isPlaying;
  final List<String>? supportedQualities;

  /// 是否处于批量选择模式。为 true 时序号列变成勾选框、整行点击切换选中，
  /// 并隐藏「更多」按钮（避免与选择手势冲突）。
  final bool selectionMode;

  /// 当前歌曲是否被选中（仅在 [selectionMode] 下生效）。
  final bool selected;

  /// 选中状态切换回调（整行点击或勾选框点击都会走这里）。
  final ValueChanged<Song>? onSelectionToggle;

  /// 长按回调：页面通常在这里进入批量选择模式并选中该曲。
  final VoidCallback? onLongPress;

  /// 自定义右侧区域。
  ///
  /// 非空时替代「时长 / 更多按钮」，用于下载管理等需要自己放置操作按钮的列表。
  final Widget? trailing;

  /// 右侧附加标记（例如作者更新页的「新增」），显示在「已听 / 时长 / 更多」之前。
  final Widget? trailingBadge;

  /// 行下方的附加内容（进度条、状态提示等）。
  final Widget? footer;

  const SongListItem({
    super.key,
    required this.song,
    this.index,
    this.showIndex = true,
    this.showCover = true,
    this.showQuality = true,
    this.showSource = false,
    this.showDuration = true,
    this.showMenuButton = true,
    this.showPlayedTag = false,
    this.onTap,
    this.onPlayTap,
    this.onMenuTap,
    this.isPlaying = false,
    this.supportedQualities,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionToggle,
    this.onLongPress,
    this.trailing,
    this.trailingBadge,
    this.footer,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    // All scrolling song lists already enable Sliver repaint boundaries.
    // Adding another boundary per row increases layer count and GPU
    // composition work without isolating any additional repaint.
    return _buildItem(colors, context, ref);
  }

  Widget _buildItem(ThemeColors colors, BuildContext context, WidgetRef ref) {
    // 竖屏或窄窗口下右侧空间紧张，把「已听」标签挪到时长下方。
    final narrow =
        MediaQuery.orientationOf(context) == Orientation.portrait ||
        MediaQuery.sizeOf(context).width < 520;
    final blocked = ref.watch(blacklistProvider).isBlocked(song);
    final effectiveTap = selectionMode
        ? () => onSelectionToggle?.call(song)
        : blocked
        ? () => _showBlockedHint(context)
        : () {
            // 分 P 歌曲：点击直接进专辑页列出全部分 P，不直接播放第一 P。
            if (openSongPartsIfNeeded(context, song)) return;
            if (onTap != null) {
              onTap!();
              return;
            }
            _defaultOnTap(context);
          };
    return InkWell(
      onTap: effectiveTap,
      onLongPress: onLongPress,
      child: Container(
        color: selected
            ? colors.primary.withValues(alpha: 0.08)
            : Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (showIndex)
                    selectionMode
                        ? _buildCheckbox(colors)
                        : _buildIndex(colors),
                  if (showCover) ...[
                    const SizedBox(width: AppSpacing.sm),
                    _buildCover(colors, ref),
                  ],
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: _buildSongInfo(colors, context, ref, blocked),
                  ),
                  if (trailing != null)
                    trailing!
                  else
                    _buildTrailing(colors, context, ref, narrow: narrow),
                ],
              ),
              if (footer != null) ...[
                const SizedBox(height: AppSpacing.xs),
                footer!,
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 多选模式下的勾选框。
  ///
  /// 用 [IgnorePointer] 包住，让它只负责展示：整行的点击统一由外层 InkWell
  /// 处理，避免「点勾选框触发两次切换导致状态不变」。
  Widget _buildCheckbox(ThemeColors colors) {
    return SizedBox(
      width: 36,
      child: IgnorePointer(
        child: Checkbox(
          value: selected,
          onChanged: (_) {},
          activeColor: colors.primary,
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    );
  }

  Widget _buildIndex(ThemeColors colors) {
    return SizedBox(
      // 三位数序号不再折行；四位数仍会折行。
      width: 36,
      child: isPlaying
          ? Icon(Icons.play_arrow, size: 18, color: colors.primary)
          : Text(
              index != null ? '${index! + 1}' : '',
              style: TextStyle(
                fontSize: 13,
                color: colors.textHint,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
            ),
    );
  }

  Widget _buildCover(ThemeColors colors, WidgetRef ref) {
    final coverUrl = song.coverUrl;
    final hasCoverUrl = coverUrl != null && coverUrl.isNotEmpty;
    if ((song.source == null || song.source == 'local') && !hasCoverUrl) {
      return _buildCoverPlaceholder(colors);
    }

    return _SongCover(
      song: song,
      initialUrl: coverUrl,
      colors: colors,
      sourceManager: ref.read(musicSourceManagerProvider),
    );
  }

  Widget _buildCoverPlaceholder(ThemeColors colors) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(Icons.music_note, size: 20, color: colors.primary),
    );
  }

  Widget _buildSongInfo(
    ThemeColors colors,
    BuildContext context,
    WidgetRef ref,
    bool blocked,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          song.title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w500,
            // 黑名单里的歌名颜色更浅，一眼能看出这首放不了。
            color: blocked
                ? colors.textPrimary.withValues(alpha: 0.45)
                : (isPlaying ? colors.primary : colors.textPrimary),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            if (blocked) _buildBlacklistTag(colors, context),
            if (showQuality) _buildQualityTag(colors, context),
            if (showSource && song.source != null)
              _buildSourceTag(colors, context, ref),
            Expanded(
              child: Text(
                song.artist,
                style: TextStyle(fontSize: 12, color: colors.textHint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 黑名单标签（与音质 / 音源标签同一行）。
  Widget _buildBlacklistTag(ThemeColors colors, BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: colors.error.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        context.tr('黑名单'),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: colors.error,
        ),
      ),
    );
  }

  /// 点到黑名单歌曲时给个提示，避免看起来像「点了没反应」。
  void _showBlockedHint(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('这首歌在黑名单里，已跳过播放')),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildQualityTag(ThemeColors colors, BuildContext context) {
    final quality = _getHighestQuality();
    if (quality == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: _getQualityColor(quality).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        context.tr(quality),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _getQualityColor(quality),
        ),
      ),
    );
  }

  Widget _buildSourceTag(
    ThemeColors colors,
    BuildContext context,
    WidgetRef ref,
  ) {
    // 插件搜索出来的歌，song.source 只记平台 id（播放 / 歌词仍按平台处理），
    // 真正用的是哪个插件记在 preferredSource 里。只读 source 会把「用元力KW
    // 搜出来的歌」全部标成「酷我音乐」，看起来像根本没走插件。
    // 收藏时绑定的优先插件同理，这里统一优先显示它（见 [Song.displaySource]）。
    final displaySource = song.displaySource ?? song.source!;
    // 名称最长 10 个字，超出省略（与详情页头部的音源标签一致）。
    final sourceName = SourceNameTag.shorten(
      _getSourceName(displaySource, ref),
    );
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: _getSourceColor(displaySource).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        context.tr(sourceName),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: _getSourceColor(displaySource),
        ),
      ),
    );
  }

  /// 右侧「已听标签 / 时长 / 更多」区域。
  ///
  /// 窄屏时标签换到时长下方并右对齐：时长与歌名同一行、标签与歌手同一行。
  Widget _buildTrailing(
    ThemeColors colors,
    BuildContext context,
    WidgetRef ref, {
    required bool narrow,
  }) {
    final playedTag = showPlayedTag && !selectionMode
        ? _buildPlayedTag(colors, context, ref, compact: !narrow)
        : null;
    final vipTag = _buildVipTag(colors, compact: !narrow);
    final partsTag = _buildPartsTag(colors, compact: !narrow);
    final duration = showDuration && !selectionMode
        ? _buildDuration(colors, padded: !narrow)
        : null;
    final menu = showMenuButton && !selectionMode
        ? _buildMenuButton(colors, context)
        : null;

    if (narrow && playedTag != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ?trailingBadge,
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (duration != null || partsTag != null) ...[
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [?partsTag, ?duration],
                ),
                const SizedBox(height: 2),
              ],
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [playedTag, ?vipTag],
              ),
            ],
          ),
          ?menu,
        ],
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ?trailingBadge,
        ?playedTag,
        ?vipTag,
        ?partsTag,
        ?duration,
        ?menu,
      ],
    );
  }

  /// 「已听 / 已听 N%」标签：进度不足 1% 或开关关闭时不显示。
  Widget? _buildPlayedTag(
    ThemeColors colors,
    BuildContext context,
    WidgetRef ref, {
    bool compact = true,
  }) {
    if (!ref.watch(markPlayedStatusProvider)) return null;
    // select 只在本行这首歌曲的进度变化时重建，列表其它行不受影响。
    final ratio = ref.watch(
      playedProgressProvider.select((map) => map[song.id]),
    );
    final label = playedProgressLabel(ratio);
    if (label == null) return null;
    final done = (ratio ?? 0) >= 0.999;
    return Padding(
      padding: EdgeInsets.only(left: compact ? AppSpacing.sm : 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: colors.primary.withValues(alpha: done ? 0.16 : 0.10),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          context.tr(label),
          style: TextStyle(
            fontSize: compact ? 10 : 12,
            height: 1.2,
            fontWeight: done ? FontWeight.w600 : FontWeight.w500,
            color: colors.primary,
          ),
        ),
      ),
    );
  }

  /// 「会员」标签：B 站充电专属 / 大会员专享作品，显示在「已听」标签右侧。
  /// 琥珀金配色与「已听」的主题色标签区分开。
  Widget? _buildVipTag(ThemeColors colors, {bool compact = true}) {
    if (!song.isVipExclusive || selectionMode) return null;
    const vipColor = Color(0xFFE6A23C);
    return Padding(
      padding: EdgeInsets.only(left: compact ? AppSpacing.sm : 0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: vipColor.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          '会员',
          style: TextStyle(
            fontSize: compact ? 10 : 12,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: vipColor,
          ),
        ),
      ),
    );
  }

  /// 「分P」标签：视频选集（多分 P）歌曲显示在时长左侧，
  /// 点击整行由 [openSongPartsIfNeeded] 打开专辑页。
  Widget? _buildPartsTag(ThemeColors colors, {bool compact = true}) {
    if (song.partsCount <= 1 || selectionMode) return null;
    return Padding(
      padding: EdgeInsets.only(
        left: compact ? AppSpacing.sm : 0,
        right: compact ? 0 : AppSpacing.sm,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: Text(
          '分P',
          style: TextStyle(
            fontSize: compact ? 10 : 12,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget? _buildDuration(ThemeColors colors, {bool padded = true}) {
    if (song.duration <= 0) return null;
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: padded ? AppSpacing.sm : 0),
      child: Text(
        song.displayDuration,
        style: TextStyle(fontSize: 12, color: colors.textHint),
      ),
    );
  }

  Widget _buildMenuButton(ThemeColors colors, BuildContext context) {
    return IconButton(
      icon: Icon(Icons.more_vert, size: 20, color: colors.textHint),
      onPressed: onMenuTap ?? () => SongActionSheet.show(context, song: song),
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
    );
  }

  void _defaultOnTap(BuildContext context) {
    if (onPlayTap != null) {
      onPlayTap!();
    }
  }

  String? _getHighestQuality() {
    if (supportedQualities != null && supportedQualities!.isNotEmpty) {
      return supportedQualities!.last;
    }
    if (song.bitrate != null) {
      if (song.bitrate! >= 1900000) return 'Hi-Res';
      if (song.bitrate! >= 1000000) return '无损';
      if (song.bitrate! >= 320000) return '320k';
      if (song.bitrate! >= 192000) return '192k';
      if (song.bitrate! >= 128000) return '128k';
    }
    return null;
  }

  Color _getQualityColor(String quality) {
    switch (quality) {
      case 'Hi-Res':
      case '母带':
        return const Color(0xFFFFD700);
      case '无损':
      case 'SQ':
        return const Color(0xFFE5484D);
      case '320k':
      case 'HQ':
        return const Color(0xFF31C27C);
      case '192k':
        return const Color(0xFF2EADFB);
      case '128k':
        return const Color(0xFF888888);
      default:
        return const Color(0xFF888888);
    }
  }

  Color _getSourceColor(String source) {
    switch (SourceInfo.baseIdOf(source)) {
      case 'wy':
        return const Color(0xFFE60026);
      case 'kg':
        return const Color(0xFF2EADFB);
      case 'kw':
        return const Color(0xFFFF8500);
      case 'tx':
        return const Color(0xFF31C27C);
      case 'mg':
        return const Color(0xFFFF7E00);
      case 'local':
        return const Color(0xFF666666);
      default:
        return const Color(0xFF888888);
    }
  }

  String _getSourceName(String source, WidgetRef ref) {
    // 插件音源（平台id@插件id）显示为「平台名-插件名」，裸平台 id 显示平台名。
    final display = ref
        .read(musicSourceManagerProvider)
        .sourceDisplayName(source);
    if (display.isNotEmpty && display != source) return display;
    switch (source) {
      case 'wy':
        return '网易';
      case 'kg':
        return '酷狗';
      case 'kw':
        return '酷我';
      case 'tx':
        return 'QQ';
      case 'mg':
        return '咪咕';
      case 'local':
        return '本地';
      default:
        return source.toUpperCase();
    }
  }
}

class _SongCover extends StatefulWidget {
  final Song song;
  final String? initialUrl;
  final ThemeColors colors;
  final MusicSourceManager sourceManager;

  const _SongCover({
    required this.song,
    required this.initialUrl,
    required this.colors,
    required this.sourceManager,
  });

  @override
  State<_SongCover> createState() => _SongCoverState();
}

class _SongCoverState extends State<_SongCover> {
  String? _url;
  final Set<String> _failedUrls = <String>{};
  bool _fallbackStarted = false;

  @override
  void initState() {
    super.initState();
    _url = widget.initialUrl;
    if (_url == null || _url!.isEmpty) _loadFallback();
  }

  @override
  void didUpdateWidget(covariant _SongCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id ||
        oldWidget.initialUrl != widget.initialUrl) {
      _url = widget.initialUrl;
      _failedUrls.clear();
      _fallbackStarted = false;
      if (_url == null || _url!.isEmpty) _loadFallback();
    }
  }

  Future<void> _loadFallback() async {
    if (_fallbackStarted) return;
    _fallbackStarted = true;
    final fallback = await widget.sourceManager.getPic(
      widget.song,
      excludedUrls: _failedUrls,
    );
    if (!mounted || fallback == null || fallback.isEmpty) return;
    if (_failedUrls.contains(fallback)) return;
    if (fallback == _url) return;
    setState(() => _url = fallback);
  }

  void _handleImageError(String failedUrl) {
    if (_failedUrls.add(failedUrl)) {
      setState(() => _url = null);
      _loadFallback();
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null || url.isEmpty || _failedUrls.contains(url)) {
      return _buildPlaceholder();
    }

    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: widget.colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.sm),
        child: CachedNetworkImage(
          imageUrl: url,
          cacheManager: AppImageCache.manager,
          width: 44,
          height: 44,
          fit: BoxFit.cover,
          memCacheWidth: 132,
          memCacheHeight: 132,
          maxWidthDiskCache: 132,
          maxHeightDiskCache: 132,
          fadeInDuration: Duration.zero,
          fadeOutDuration: Duration.zero,
          filterQuality: FilterQuality.low,
          placeholder: (context, url) => _buildPlaceholder(),
          errorWidget: (context, url, error) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _handleImageError(url);
            });
            return _buildPlaceholder();
          },
        ),
      ),
    );
  }

  Widget _buildPlaceholder() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: widget.colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Icon(Icons.music_note, size: 20, color: widget.colors.primary),
    );
  }
}
