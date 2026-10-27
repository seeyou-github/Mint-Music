import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/platform/file_manager_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_font_manager.dart';
import '../../core/theme/theme_provider.dart';
import '../../core/constants/app_routes.dart';
import '../../core/l10n/l10n.dart';
import '../../features/discover/application/search_providers.dart';
import '../../features/library/application/playlist_providers.dart';
import '../../features/library/domain/models/playlist.dart';
import '../../features/library/domain/models/recently_played.dart';
import '../../features/blacklist/application/blacklist_providers.dart';
import '../../features/player/application/playback_context.dart';
import '../../features/player/application/playback_controller.dart';
import '../../features/player/domain/models/song.dart';
import '../../features/player/presentation/playback_source_navigation.dart';
import '../../features/radio/application/radio_session.dart';
import '../../features/download/application/download_providers.dart';
import '../../features/settings/application/font_providers.dart';
import '../../features/settings/application/settings_providers.dart';
import '../../features/settings/data/settings_service.dart';
import '../../features/plugin/application/plugin_providers.dart';

const _sheetAnimationStyle = AnimationStyle(
  duration: Duration(milliseconds: 220),
  reverseDuration: Duration(milliseconds: 180),
);

String _estimateSize(String qualityId, int durationSec) {
  if (durationSec <= 0) return '';
  final kbps = <String, int>{
    '128k': 128,
    '192k': 192,
    '320k': 320,
    'flac': 1000,
    'flac24bit': 2000,
    'hires': 3000,
    'atmos': 500,
    'master': 3000,
  };
  final bitrate = kbps[qualityId] ?? 320;
  final sizeBytes = bitrate * 1000 ~/ 8 * durationSec;
  if (sizeBytes < 1024 * 1024)
    return '${(sizeBytes / 1024).toStringAsFixed(1)}KB';
  return '${(sizeBytes / (1024 * 1024)).toStringAsFixed(2)}MB';
}

/// 弹层最大高度占屏高的比例：横屏时可用高度很小，限制后内容可滚动，
/// 既不会出现黄黑斜条，也不会让弹层顶满全屏。
const double _sheetMaxHeightRatio = 0.85;

/// 通用可滚动底部弹层容器：拖拽条与标题固定在顶部，内容区超出时滚动。
///
/// 修复横屏/小屏下的 "BOTTOM OVERFLOWED BY xxx PIXELS"：
/// Flutter 在 `isScrollControlled == false` 时会把弹层高度限制为
/// 9/16 屏高（见 SDK 中 `_defaultScrollControlDisabledMaxHeightRatio`），
/// 而这些弹层用的是 `Column(mainAxisSize: min)` + 固定子项，
/// 高度一变就会溢出成黄黑斜条。
class _ScrollableSheet extends StatelessWidget {
  final String? title;

  /// 标题下方的内容，超出时自动滚动。
  final List<Widget> children;

  const _ScrollableSheet({required this.children, this.title});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * _sheetMaxHeightRatio,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              if (title != null) ...[
                const SizedBox(height: 16),
                Text(
                  title!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [...children, const SizedBox(height: 16)],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SongActionSheet extends ConsumerStatefulWidget {
  final Song song;
  final List<Song>? playlistSongs;
  final bool showDownload;
  final bool showEditTag;
  final bool showAccurateMatch;
  final VoidCallback? onAccurateMatch;
  final bool showDelete;
  final VoidCallback? onDelete;

  /// 是否显示「移除」（用于从当前歌单 / 收藏集合中移除歌曲）。
  final bool showRemove;
  final VoidCallback? onRemove;
  final bool compactMode;

  /// 首个主操作是否用「下一首播放」取代「播放」。
  ///
  /// - `false`（默认）：显示「播放」，行为由 [playlistSongs] 决定
  ///   （传入列表 = 整张列表依次播放，否则仅播放当前这一首）。
  /// - `true`：显示「下一首播放」，把当前歌曲插到播放队列中「正在播放的那首」
  ///   之后，**不会**替换播放队列（队列为空时才会直接开始播放它）。
  ///
  /// 语义对齐 MusicFree 的 `TrackPlayer.addNext`。
  final bool showPlayNextInsteadOfPlay;

  const SongActionSheet({
    super.key,
    required this.song,
    this.playlistSongs,
    this.showDownload = true,
    this.showEditTag = false,
    this.showAccurateMatch = false,
    this.onAccurateMatch,
    this.showDelete = false,
    this.onDelete,
    this.showRemove = false,
    this.onRemove,
    this.compactMode = false,
    this.showPlayNextInsteadOfPlay = false,
  });

  static Future<void> show(
    BuildContext context, {
    required Song song,
    List<Song>? playlistSongs,
    bool showDownload = true,
    bool showEditTag = false,
    bool showAccurateMatch = false,
    VoidCallback? onAccurateMatch,
    bool showDelete = false,
    VoidCallback? onDelete,
    bool showRemove = false,
    VoidCallback? onRemove,
    bool showPlayNextInsteadOfPlay = false,
  }) {
    return showModalBottomSheet(
      context: context,
      // 用根导航器弹出，避免被 AppShell 中悬浮的迷你播放器遮挡
      useRootNavigator: true,
      sheetAnimationStyle: _sheetAnimationStyle,
      backgroundColor: Colors.transparent,
      builder: (context) => SongActionSheet(
        song: song,
        playlistSongs: playlistSongs,
        showDownload: showDownload,
        showEditTag: showEditTag,
        showAccurateMatch: showAccurateMatch,
        onAccurateMatch: onAccurateMatch,
        showDelete: showDelete,
        onDelete: onDelete,
        showRemove: showRemove,
        onRemove: onRemove,
        showPlayNextInsteadOfPlay: showPlayNextInsteadOfPlay,
      ),
    );
  }

  /// Shows a compact player menu with only 4 options:
  /// 添加到歌单, 下载, 分享, 倍速
  static Future<void> showPlayerMenu(
    BuildContext context, {
    required Song song,
  }) {
    return showModalBottomSheet(
      context: context,
      // 用根导航器弹出，避免被迷你播放器遮挡
      useRootNavigator: true,
      sheetAnimationStyle: _sheetAnimationStyle,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          SongActionSheet(song: song, showDownload: true, compactMode: true),
    );
  }

  /// 弹出播放速度选择（播放页的「倍速」按钮也复用这里）。
  static Future<void> showSpeedPicker(BuildContext context, WidgetRef ref) {
    return _SongActionSheetState.showSpeedPicker(context, ref);
  }

  /// 选择下载音质。
  ///
  /// 播放页顶部的下载按钮直接调用这个（不经过 ActionSheet）。
  static void showDownloadQualityPicker(BuildContext context, Song song) {
    final sourceId = song.source ?? 'wy';
    final manager = ProviderScope.containerOf(
      context,
    ).read(musicSourceManagerProvider);
    final qualities = manager.getSupportedQualitiesForSourceId(sourceId);

    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: _sheetAnimationStyle,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).padding.bottom),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(ctx).size.height * 0.9,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    ctx.tr('选择下载音质'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ...qualities.map((q) => _buildQualityItem(ctx, q, song)),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _buildQualityItem(BuildContext ctx, String q, Song song) {
    return InkWell(
      // startDownload 内部会关闭这个弹层，这里不要再 pop 一次。
      onTap: () {
        startDownload(ctx, song, q);
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    getQualityDisplayName(q),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${ctx.tr(kQualityDescription[q] ?? '')}  ${_estimateSize(q, song.duration)}',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.download_outlined,
              color: Colors.white.withValues(alpha: 0.4),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  /// 开始下载（静态版，供播放页的下载按钮复用）。
  static Future<void> startDownload(
    BuildContext context,
    Song song,
    String quality,
  ) async {
    // 先拿到 messenger：下面会关闭当前弹层，context 随即失效。
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    try {
      final repo = ProviderScope.containerOf(
        context,
      ).read(downloadRepositoryProvider);
      await repo.addTask(song: song, quality: quality);
      // onTaskStarted 回调会显示 "开始下载 xxx" 通知
    } catch (e) {
      final err = e.toString();
      if (err.contains('UNSUPPORTED_QUALITY')) {
        final q = err.split(':').last;
        messenger.showSnackBar(
          SnackBar(
            content: Text(context.tr('音质 $q 不受当前音源支持，请选择其他音质')),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.orange,
            action: SnackBarAction(
              label: context.tr('重新选择'),
              textColor: Colors.white,
              onPressed: () =>
                  SongActionSheet.showDownloadQualityPicker(context, song),
            ),
          ),
        );
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(context.tr('下载失败: $e')),
          duration: const Duration(seconds: 2),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  ConsumerState<SongActionSheet> createState() => _SongActionSheetState();
}

class _SongActionSheetState extends ConsumerState<SongActionSheet> {
  bool _isFavorited = false;

  @override
  void initState() {
    super.initState();
    _checkFavorited();
  }

  void _checkFavorited() {
    final playlistsAsync = ref.read(playlistsProvider);
    setState(() {
      _isFavorited = playlistsAsync.when(
        data: (playlists) {
          final favorites = playlists
              .where((p) => p.id == '__favorites__')
              .firstOrNull;
          if (favorites == null) return false;
          return favorites.songs.any((s) => s.id == widget.song.id);
        },
        loading: () => false,
        error: (_, __) => false,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final themeColors = ref.watch(themeColorsProvider);
    final playlistsAsync = ref.watch(playlistsProvider);
    final blacklist = ref.watch(blacklistProvider);
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    // Compact mode (player menu) uses always-dark colors matching the play queue window.
    // Full mode (song context menu) uses the theme-provided colors.
    final colors = widget.compactMode
        ? ThemeColors.darkWithPrimary(AppColors.primary)
        : themeColors;

    return Container(
      decoration: BoxDecoration(
        // Compact mode (player menu) uses always-dark surface matching the play queue.
        // Full mode (song context menu) uses the themed surface (white in light theme).
        color: widget.compactMode ? AppColors.surface : colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomPadding + 16),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: AppSpacing.md),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.divider,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                // 顶部固定四行：歌曲 / 歌手 / 专辑（+ 播放页的「来源」）。
                _buildMetaRows(colors, includeSource: widget.compactMode),
                const SizedBox(height: AppSpacing.sm),
                Divider(
                  height: 1,
                  color: widget.compactMode
                      ? AppColors.divider
                      : colors.divider,
                ),
                // --- Compact mode (player menu: 4 options matching play queue style) ---
                if (widget.compactMode) ...[
                  _buildActionItem(
                    colors: colors,
                    icon: Icons.add_to_photos,
                    label: context.tr('添加到歌单'),
                    onTap: () => _showAddToPlaylist(colors, playlistsAsync),
                    skipPop: true,
                  ),
                  // 「下载」「启用桌面歌词」「定时」已经挪到播放页的图标按钮上了。
                  // Android 端的倍速也挪到播放页，这里不再重复。
                  if (!Platform.isAndroid) _buildSpeedItem(colors),
                  _buildLyricSettingsItem(colors),
                  ..._buildBlacklistItems(colors, blacklist),
                ],
                // --- Full mode (song context menu) ---
                if (!widget.compactMode) ...[
                  if (widget.showPlayNextInsteadOfPlay)
                    _buildActionItem(
                      colors: colors,
                      icon: Icons.playlist_play,
                      label: context.tr('下一首播放'),
                      onTap: _playNext,
                    ),
                  _buildActionItem(
                    colors: colors,
                    icon: Icons.playlist_add,
                    label: context.tr('加入播放列表'),
                    onTap: _appendToQueue,
                  ),
                  if (widget.showDownload)
                    _buildActionItem(
                      colors: colors,
                      icon: Icons.download_outlined,
                      label: context.tr('下载'),
                      onTap: _download,
                      skipPop: true,
                    ),
                  _buildActionItem(
                    colors: colors,
                    icon: Icons.add_to_photos,
                    label: context.tr('添加到歌单'),
                    onTap: () => _showAddToPlaylist(colors, playlistsAsync),
                    skipPop: true,
                  ),
                  _buildFavoriteItem(colors),
                  ..._buildBlacklistItems(colors, blacklist),
                  if (widget.showRemove && widget.onRemove != null)
                    _buildActionItem(
                      colors: colors,
                      icon: Icons.remove_circle_outline,
                      label: context.tr('移除'),
                      onTap: widget.onRemove!,
                      iconColor: colors.error,
                      labelColor: colors.error,
                    ),
                  if (widget.showDelete && widget.onDelete != null)
                    _buildActionItem(
                      colors: colors,
                      icon: Icons.delete_outline,
                      label: context.tr('删除'),
                      onTap: widget.onDelete!,
                      iconColor: colors.error,
                      labelColor: colors.error,
                    ),
                  if (widget.showAccurateMatch)
                    _buildActionItem(
                      colors: colors,
                      icon: Icons.search,
                      label: context.tr('精准匹配'),
                      onTap: widget.onAccurateMatch ?? () {},
                    ),
                  if (widget.showEditTag)
                    _buildActionItem(
                      colors: colors,
                      icon: Icons.edit,
                      label: context.tr('编辑标签'),
                      onTap: () => context.push(
                        '${AppRoutes.tagEditor}?songId=${widget.song.id}',
                      ),
                    ),
                  // Windows：用系统文件管理器打开歌曲所在的目录
                  if (Platform.isWindows &&
                      (widget.song.filePath ?? '').isNotEmpty)
                    _buildActionItem(
                      colors: colors,
                      icon: Icons.folder_open_outlined,
                      label: context.tr('打开歌曲所在文件夹'),
                      onTap: () async {
                        // 注意：这个菜单项（_buildActionItem）在调用 onTap 之前
                        // 已经自己 Navigator.pop 过一次弹层了，这里**不能再 pop**：
                        // 再 pop 一次会把下面的页面路由（本地页）也弹掉，表现为
                        // 「右侧界面所有控件看不见」。
                        // 先把 messenger 和文案取出来：后面是异步的，等 Explorer
                        // 打开后再用 context 会失效。
                        final messenger = ScaffoldMessenger.of(context);
                        final errorText = context.tr('无法打开所在文件夹');
                        final path = widget.song.filePath ?? '';
                        // 打开这首歌实际所在的目录并选中文件，而不是固定打开
                        // 下载目录：本地扫描目录里的歌曲并不在下载目录下。
                        final opened =
                            await FileManagerService.revealFileOrOpenFolder(
                              path,
                            );
                        if (opened) return;
                        messenger.showSnackBar(
                          SnackBar(content: Text(errorText)),
                        );
                      },
                    ),
                ],
                const SizedBox(height: AppSpacing.lg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 歌曲 / 歌手 / 专辑（播放页「更多」再加一行「来源」），全部可点击。
  ///
  /// 歌曲名、歌手名直接搜索；专辑能拿到 id 时打开专辑详情，否则按专辑名到
  /// 「专辑」分类里搜索，专辑名缺失时不显示专辑行；来源可打开对应的歌单 /
  /// 榜单 / 专辑 / 作者页。
  Widget _buildMetaRows(ThemeColors colors, {bool includeSource = false}) {
    final song = widget.song;
    final album = _albumName;
    final sourceRow = includeSource ? _buildSourceRow(colors) : null;
    return Column(
      children: [
        _buildMetaRow(
          colors,
          label: context.tr('歌曲'),
          value: song.title,
          onTap: () => _searchFor(song.title),
        ),
        if (song.artist.trim().isNotEmpty)
          _buildMetaRow(
            colors,
            label: context.tr('歌手'),
            value: song.artist,
            onTap: _searchArtist,
          ),
        if (album != null)
          _buildMetaRow(
            colors,
            label: context.tr('专辑'),
            value: '《$album》',
            onTap: _openAlbum,
          ),
        ?sourceRow,
      ],
    );
  }

  Widget _buildMetaRow(
    ThemeColors colors, {
    required String label,
    required String value,
    VoidCallback? onTap,
    bool showChevron = false,
    Color? valueColor,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              Icons.format_list_bulleted,
              size: 20,
              color: colors.textSecondary,
            ),
            const SizedBox(width: AppSpacing.md),
            Text(
              '$label：',
              style: TextStyle(fontSize: 15, color: colors.textSecondary),
            ),
            Expanded(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 15,
                  color: valueColor ?? colors.textPrimary,
                ),
              ),
            ),
            if (showChevron)
              Icon(Icons.chevron_right, size: 18, color: colors.textHint),
          ],
        ),
      ),
    );
  }

  /// 可展示、可搜索的专辑名：空值与本地歌曲的「未知专辑」占位都算拿不到。
  String? get _albumName {
    final album = widget.song.album.trim();
    if (album.isEmpty || album == '未知专辑') return null;
    return album;
  }

  /// 「来源」行（播放页「更多」顶部）：显示当前播放来源，
  /// 歌单（含我的收藏）/ 榜单 / 专辑 / 作者可点击打开来源页。
  Widget? _buildSourceRow(ThemeColors colors) {
    final ctx = PlaybackContext.instance;
    final type = ctx.type;
    if (type == PlaybackSourceType.unknown) return null;
    // 电台的歌也是随机从歌单里取的，来源显示成「歌单」；电台一次可能跨多个
    // 歌单，所以按歌曲查它自己来自哪个歌单，查到才可跳转。
    final radioPlaylist = type == PlaybackSourceType.radio
        ? ref.watch(radioSessionProvider)?.songPlaylists[widget.song.id]
        : null;
    final clickable = type == PlaybackSourceType.radio
        ? radioPlaylist != null
        : canOpenPlaybackSource(type) && (ctx.id ?? '').isNotEmpty;
    return _buildMetaRow(
      colors,
      label: context.tr('来源'),
      value: _sourceLabel(type, ctx.id),
      onTap: clickable ? _openSource : null,
      showChevron: clickable,
      valueColor: clickable ? colors.primary : colors.textHint,
    );
  }

  String _sourceLabel(PlaybackSourceType type, String? id) {
    if (type == PlaybackSourceType.playlist && id == '__favorites__') {
      return context.tr('我的收藏');
    }
    return switch (type) {
      PlaybackSourceType.search => context.tr('搜索-歌曲分类'),
      PlaybackSourceType.playlist => context.tr('歌单'),
      PlaybackSourceType.rank => context.tr('榜单'),
      PlaybackSourceType.album => context.tr('专辑'),
      PlaybackSourceType.artist => context.tr('作者'),
      PlaybackSourceType.local => context.tr('本地'),
      PlaybackSourceType.radio => context.tr('歌单'),
      PlaybackSourceType.unknown => '',
    };
  }

  /// 关闭菜单后打开来源页：先关掉播放详情页，再跳转到对应页面。
  void _openSource() {
    final context = this.context;
    final container = ProviderScope.containerOf(context, listen: false);
    // 跳转过程中菜单 / 播放页都会被关闭，先把来源快照下来。
    final ctx = PlaybackContext.instance;
    final type = ctx.type;

    // 电台：跳到当前歌曲绑定的那个歌单。
    if (type == PlaybackSourceType.radio) {
      final playlist = ref
          .read(radioSessionProvider)
          ?.songPlaylists[widget.song.id];
      if (playlist == null) return;
      Navigator.pop(context);
      unawaited(
        openPlaybackSource(
          container,
          type: PlaybackSourceType.playlist,
          id: playlist.id,
          name: playlist.title,
          song: widget.song,
        ),
      );
      return;
    }

    final id = ctx.id;
    final name = ctx.name;
    final meta = ctx.sourceMeta;
    if (!canOpenPlaybackSource(type) || id == null || id.isEmpty) return;
    Navigator.pop(context);
    unawaited(
      openPlaybackSource(
        container,
        type: type,
        id: id,
        name: name,
        sourceMeta: meta,
        song: widget.song,
      ),
    );
  }

  void _searchArtist() => _searchFor(widget.song.artist);

  /// 点歌曲名 / 歌手名：关掉菜单和播放页，打开搜索页并自动搜索。
  void _searchFor(String query) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final context = this.context;
    final container = ProviderScope.containerOf(context, listen: false);
    Navigator.pop(context);
    unawaited(openSearchForQuery(container, trimmed));
  }

  /// 点专辑：能拿到专辑 id 就直接打开专辑详情页（播放的是这张专辑时用来源
  /// 里记的 id，内置源歌曲从插件元数据里取），否则按专辑名到「专辑」分类搜。
  void _openAlbum() {
    final album = _albumName;
    if (album == null) return;
    final context = this.context;
    final container = ProviderScope.containerOf(context, listen: false);
    final albumId = _albumIdOf(widget.song);
    Navigator.pop(context);
    if (albumId != null) {
      unawaited(
        openPlaybackSource(
          container,
          type: PlaybackSourceType.album,
          id: albumId,
          name: album,
          song: widget.song,
          // 已经停在这张专辑页时不要再把它关掉。
          toggle: false,
        ),
      );
      return;
    }
    unawaited(openSearchForQuery(container, album, tab: SearchTab.albums));
  }

  /// 歌曲数据里能拿到的专辑 id；拿不到返回 null。
  String? _albumIdOf(Song song) {
    final lx = song.lx;
    if (lx != null) {
      for (final key in const ['albumId', 'albumid']) {
        final id = (lx[key] ?? '').toString().trim();
        if (id.isNotEmpty) return id;
      }
      for (final key in const ['album', 'al']) {
        final value = lx[key];
        if (value is Map) {
          final id = (value['id'] ?? '').toString().trim();
          if (id.isNotEmpty) return id;
        }
      }
    }
    // 正在播放的这首歌就来自这张专辑的详情页：直接用播放来源里记的 id。
    final playback = PlaybackContext.instance;
    if (playback.type == PlaybackSourceType.album &&
        (playback.name ?? '').trim() == song.album.trim()) {
      final id = (playback.id ?? '').trim();
      if (id.isNotEmpty) return id;
    }
    return null;
  }

  Widget _buildActionItem({
    required ThemeColors colors,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool skipPop = false,
    Color? iconColor,
    Color? labelColor,
  }) {
    return InkWell(
      onTap: () {
        if (!skipPop) Navigator.pop(context);
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(icon, size: 22, color: iconColor ?? colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                color: labelColor ?? colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 黑名单菜单项（播放页「更多」里在「歌词设置」下方）。
  ///
  /// * 没被拉黑 → 「添加到黑名单」/「歌曲添加到黑名单」+「歌手添加到黑名单」
  /// * 被歌曲黑名单拉黑 → 「从黑名单移除」（歌手也在黑名单里时顺带加入白名单）
  /// * 只被歌手黑名单拉黑 → 「将此歌曲移出黑名单」（加白名单）
  /// * 歌手在黑名单里 → 额外的「将此歌手移出黑名单」（解禁该歌手全部歌曲）
  List<Widget> _buildBlacklistItems(
    ThemeColors colors,
    BlacklistData blacklist,
  ) {
    final song = widget.song;
    final notifier = ref.read(blacklistProvider.notifier);
    final songListed = blacklist.isSongListed(song);
    final artistListed = blacklist.isArtistListed(song.artist);
    final blocked = blacklist.isBlocked(song);
    final items = <Widget>[];

    if (!blocked) {
      items.add(
        _buildActionItem(
          colors: colors,
          icon: Icons.block,
          label: context.tr(widget.compactMode ? '歌曲添加到黑名单' : '添加到黑名单'),
          onTap: () => unawaited(notifier.addSong(song)),
          iconColor: colors.error,
        ),
      );
    } else if (songListed) {
      items.add(
        _buildActionItem(
          colors: colors,
          icon: Icons.remove_circle_outline,
          label: context.tr('从黑名单移除'),
          onTap: () => unawaited(notifier.removeSong(song)),
        ),
      );
    } else {
      // 只是被歌手黑名单拦住：把这首歌加进白名单，歌手本身仍保持拉黑。
      items.add(
        _buildActionItem(
          colors: colors,
          icon: Icons.lock_open_outlined,
          label: context.tr('将此歌曲移出黑名单'),
          onTap: () => unawaited(notifier.addToWhitelist(song)),
        ),
      );
    }

    if (artistListed) {
      items.add(
        _buildActionItem(
          colors: colors,
          icon: Icons.person_off_outlined,
          label: context.tr('将此歌手移出黑名单'),
          onTap: () => unawaited(notifier.removeArtist(song.artist)),
        ),
      );
    } else if (widget.compactMode) {
      items.add(
        _buildActionItem(
          colors: colors,
          icon: Icons.person_off,
          label: context.tr('歌手添加到黑名单'),
          onTap: () => unawaited(notifier.addArtist(song.artist)),
        ),
      );
    }

    return items;
  }

  Widget _buildFavoriteItem(ThemeColors colors) {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        _toggleFavorite();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(
              _isFavorited ? Icons.favorite : Icons.favorite_border,
              size: 22,
              color: _isFavorited ? Colors.red : colors.textSecondary,
            ),
            const SizedBox(width: AppSpacing.md),
            Text(
              context.tr(_isFavorited ? '已收藏' : '收藏'),
              style: TextStyle(
                fontSize: 15,
                color: _isFavorited ? Colors.red : colors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSpeedItem(ThemeColors colors) {
    return InkWell(
      onTap: () {
        Navigator.pop(context);
        _showSpeedPicker();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(Icons.speed, size: 22, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Text(
              context.tr('倍速'),
              style: TextStyle(fontSize: 15, color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  void _showSpeedPicker() {
    unawaited(SongActionSheet.showSpeedPicker(context, ref));
  }

  /// 弹出播放速度选择（播放页的「倍速」按钮也复用这里）。
  static Future<void> showSpeedPicker(
    BuildContext context,
    WidgetRef ref,
  ) async {
    final currentSpeed = ref.read(playbackSpeedProvider);
    const speeds = ['0.5x', '0.75x', '1.0x', '1.25x', '1.5x', '2.0x'];
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: _sheetAnimationStyle,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _ScrollableSheet(
        title: ctx.tr('播放速度'),
        children: [
          ...speeds.map((label) {
            final speed = double.parse(label.replaceAll('x', ''));
            final isSelected = currentSpeed == speed;
            return ListTile(
              leading: Icon(
                isSelected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: isSelected ? AppColors.primary : AppColors.textSecondary,
              ),
              title: Text(
                label,
                style: TextStyle(
                  color: isSelected ? AppColors.primary : AppColors.textPrimary,
                ),
              ),
              onTap: () {
                ref.read(playbackSpeedProvider.notifier).state = speed;
                unawaited(_persistSpeed(ref, speed));
                ref.read(audioHandlerProvider).setSpeed(speed);
                Navigator.pop(ctx);
              },
            );
          }),
        ],
      ),
    );
  }

  static Future<void> _persistSpeed(WidgetRef ref, double speed) async {
    try {
      final svc = await ref.read(settingsServiceProvider.future);
      await svc.setPlaybackSpeed(speed);
    } catch (_) {}
  }

  Widget _buildLyricSettingsItem(ThemeColors colors) {
    return InkWell(
      onTap: () {
        // 注意：不要在这里 Navigator.pop(context)！
        // 如果先关闭 SongActionSheet，_SongActionSheetState（ConsumerState）会被 dispose，
        // 后续 _persist* 方法中任何基于 widget ref / context 的操作都会失效，
        // 偏好设置写入会静默失败。
        // 改为在当前 ActionSheet 之上再叠加一层歌词设置 BottomSheet。
        _showLyricSettings();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Icon(Icons.lyrics, size: 22, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Text(
              context.tr('歌词设置'),
              style: TextStyle(fontSize: 15, color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  /// 「启用桌面歌词」开关（播放页更多菜单）。
  ///
  /// 设置页不再提供这个开关，改由播放页随手开关。
  /// 「歌词设置」弹层。
  ///
  /// 原来这里的显示翻译 / 罗马音 / 模糊 / 缩放 / 居中 / Apple Music 风格
  /// 等开关都已移除（行为固定），字体相关三项直接放在这一层。
  void _showLyricSettings() {
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: _sheetAnimationStyle,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        // 使用 ProviderScope 读取/写入设置
        final container = ProviderScope.containerOf(ctx);
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom,
          ),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              // 在 StatefulBuilder 内部读取，选择器关闭后能刷新显示值。
              final family = container.read(lyricFontFamilyProvider);
              final rate = container.read(lyricFontRateProvider);
              final weight = container.read(lyricFontWeightProvider);
              return _ScrollableSheet(
                title: context.tr('歌词设置'),
                children: [
                  // 选择字体
                  _fontSettingRow(
                    context,
                    container,
                    context.tr('选择字体'),
                    _lyricFontLabel(family),
                    () {
                      _showFontFamilyPicker(context, container).then((_) {
                        setSheetState(() {});
                      });
                    },
                  ),
                  const Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: AppColors.divider,
                  ),
                  // 字体大小
                  _fontSettingRow(
                    context,
                    container,
                    context.tr('字体大小'),
                    '${(rate * 100).toInt()}%',
                    () {
                      _showFontRatePicker(context, container).then((_) {
                        setSheetState(() {});
                      });
                    },
                  ),
                  const Divider(
                    height: 1,
                    indent: 16,
                    endIndent: 16,
                    color: AppColors.divider,
                  ),
                  // 字重
                  _fontSettingRow(
                    context,
                    container,
                    context.tr('字重'),
                    '$weight',
                    () {
                      _showFontWeightPicker(context, container).then((_) {
                        setSheetState(() {});
                      });
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  /// 歌词字体的显示名。
  String _lyricFontLabel(String family) {
    const map = {'': '系统默认', 'lyricfont': '阿里巴巴圆润体'};
    final label = map[family];
    if (label != null) return label;
    for (final font in AppFontManager.bundledFonts) {
      if (font.family == family) return font.label;
    }
    return family;
  }

  Widget _fontSettingRow(
    BuildContext ctx,
    ProviderContainer c,
    String title,
    String value,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 13, color: AppColors.textHint),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.chevron_right,
              size: 18,
              color: AppColors.textHint,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showFontFamilyPicker(
    BuildContext ctx,
    ProviderContainer container,
  ) {
    final fonts = ['系统默认', '阿里巴巴圆润体'];
    final current = container.read(lyricFontFamilyProvider);
    final map = {'': '系统默认', 'lyricfont': '阿里巴巴圆润体'};
    final revMap = {'系统默认': '', '阿里巴巴圆润体': 'lyricfont'};
    // 「设置 - 外观设置 - 应用字体」里导入的字体也出现在字体列表中。
    final importedFonts = container.read(appFontsProvider);
    for (final font in importedFonts) {
      if (map.containsKey(font.family)) continue;
      fonts.add(font.family);
      map[font.family] = font.family;
      revMap[font.family] = font.family;
    }
    // 随安装包内置的字体（思源宋体 / 方正兰亭黑）。
    for (final font in AppFontManager.bundledFonts) {
      if (map.containsKey(font.family)) continue;
      fonts.add(font.label);
      map[font.family] = font.label;
      revMap[font.label] = font.family;
    }
    final currentLabel = map[current] ?? '系统默认';

    return showModalBottomSheet(
      context: ctx,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx2) => _ScrollableSheet(
        title: ctx2.tr('选择字体'),
        children: [
          ...fonts.map(
            (f) => ListTile(
              title: Text(
                ctx2.tr(f),
                style: TextStyle(
                  color: f == currentLabel
                      ? AppColors.primary
                      : AppColors.textPrimary,
                ),
              ),
              trailing: f == currentLabel
                  ? const Icon(Icons.check, size: 18, color: AppColors.primary)
                  : null,
              onTap: () async {
                final val = revMap[f]!;
                container.read(lyricFontFamilyProvider.notifier).state = val;
                await _persistStringSetting(
                  container,
                  lyricFontFamilyProvider,
                  val,
                  (s) => s.setLyricFontFamily(val),
                );
                if (ctx2.mounted) Navigator.pop(ctx2);
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showFontRatePicker(
    BuildContext ctx,
    ProviderContainer container,
  ) {
    return showModalBottomSheet(
      context: ctx,
      sheetAnimationStyle: _sheetAnimationStyle,
      backgroundColor: Colors.transparent,
      builder: (ctx2) {
        return Container(
          decoration: const BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: StatefulBuilder(
            builder: (context, setState) {
              final c2 = ProviderScope.containerOf(context);
              final rate = c2.read(lyricFontRateProvider);
              return _ScrollableSheet(
                title: context.tr('字体大小'),
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: [
                        Text(
                          '${(rate * 100).toInt()}%',
                          style: const TextStyle(
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Expanded(
                          child: Slider(
                            value: rate,
                            min: 0.5,
                            max: 2.0,
                            divisions: 15,
                            activeColor: AppColors.primary,
                            onChanged: (v) {
                              // 拖动过程中只改内存，不落盘：
                              // onChanged 每帧触发，逐次重写整个设置文件太浪费。
                              c2.read(lyricFontRateProvider.notifier).state = v;
                              setState(() {});
                            },
                            onChangeEnd: (v) async {
                              await _persistDoubleSetting(
                                container,
                                lyricFontRateProvider,
                                v,
                                (s) => s.setLyricFontRate(v),
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showFontWeightPicker(
    BuildContext ctx,
    ProviderContainer container,
  ) {
    final weights = ['400 正常', '500 中等', '600 半粗', '700 粗', '800 特粗', '900 黑'];

    return showModalBottomSheet(
      context: ctx,
      sheetAnimationStyle: _sheetAnimationStyle,
      backgroundColor: Colors.transparent,
      builder: (ctx2) => Container(
        decoration: const BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          child: StatefulBuilder(
            builder: (context, setState) {
              final c2 = ProviderScope.containerOf(context);
              final current = c2.read(lyricFontWeightProvider);
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 8),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppColors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.tr('字重'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...weights.map((w) {
                      final v = int.parse(w.split(' ')[0]);
                      return ListTile(
                        title: Text(
                          context.tr(w),
                          style: TextStyle(
                            color: v == current
                                ? AppColors.primary
                                : AppColors.textPrimary,
                          ),
                        ),
                        trailing: v == current
                            ? const Icon(
                                Icons.check,
                                size: 18,
                                color: AppColors.primary,
                              )
                            : null,
                        onTap: () async {
                          container
                                  .read(lyricFontWeightProvider.notifier)
                                  .state =
                              v;
                          await _persistIntSetting(
                            container,
                            lyricFontWeightProvider,
                            v,
                            (s) => s.setLyricFontWeight(v),
                          );
                          if (ctx2.mounted) {
                            setState(() {});
                            Navigator.pop(ctx2);
                          }
                        },
                      );
                    }),
                    const SizedBox(height: 16),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _persistStringSetting(
    ProviderContainer c,
    StateProvider<String> p,
    String v,
    Future<void> Function(SettingsService svc) saveFn,
  ) async {
    c.read(p.notifier).state = v;
    try {
      final svc = await c.read(settingsServiceProvider.future);
      await saveFn(svc);
      debugPrint('[Settings] saved String ${p.name ?? p.runtimeType} = "$v"');
    } catch (e) {
      debugPrint('[Settings] persistString error: $e');
    }
  }

  Future<void> _persistDoubleSetting(
    ProviderContainer c,
    StateProvider<double> p,
    double v,
    Future<void> Function(SettingsService svc) saveFn,
  ) async {
    c.read(p.notifier).state = v;
    try {
      final svc = await c.read(settingsServiceProvider.future);
      await saveFn(svc);
      debugPrint('[Settings] saved Double ${p.name ?? p.runtimeType} = $v');
    } catch (e) {
      debugPrint('[Settings] persistDouble error: $e');
    }
  }

  Future<void> _persistIntSetting(
    ProviderContainer c,
    StateProvider<int> p,
    int v,
    Future<void> Function(SettingsService svc) saveFn,
  ) async {
    c.read(p.notifier).state = v;
    try {
      final svc = await c.read(settingsServiceProvider.future);
      await saveFn(svc);
      debugPrint('[Settings] saved Int ${p.name ?? p.runtimeType} = $v');
    } catch (e) {
      debugPrint('[Settings] persistInt error: $e');
    }
  }

  void _appendToQueue() {
    ref.read(playbackControllerProvider.notifier).appendToQueue([widget.song]);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('已加入播放列表')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  /// 「下一首播放」：把当前歌曲插到播放队列中「正在播放的那一首」之后。
  ///
  /// 播放队列**不会**被替换，也不会立刻切歌；只有队列为空（没有任何正在
  /// 播放的歌曲）时才直接开始播放它。语义对齐 MusicFree 的
  /// `TrackPlayer.addNext`（`add(item, currentIndex + 1)`）。
  Future<void> _playNext() async {
    // 先取好 messenger / 文案：_buildActionItem 会先 pop 掉本弹层，
    // await 之后 context 已失效，不能再用它去找 ScaffoldMessenger。
    final messenger = ScaffoldMessenger.of(context);
    final message = context.tr('已添加到下一首播放');

    final playback = ref.read(playbackControllerProvider);
    final willAutoPlay = playback.queue.isEmpty || playback.currentSong == null;

    await ref.read(playbackControllerProvider.notifier).insertNext([
      widget.song,
    ]);

    // 队列原本为空 → insertNext 直接开始播放了，无需再提示「已添加」。
    if (willAutoPlay) return;
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _toggleFavorite() {
    if (_isFavorited) {
      ref
          .read(playlistsProvider.notifier)
          .removeSongFromPlaylist('__favorites__', widget.song.id);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('已取消收藏')),
          duration: const Duration(seconds: 1),
        ),
      );
    } else {
      ref
          .read(playlistsProvider.notifier)
          .addSongToPlaylist('__favorites__', widget.song);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('已收藏')),
          duration: const Duration(seconds: 1),
        ),
      );
    }
    _checkFavorited();
  }

  void _download() {
    _showQualityDialog();
  }

  void _showQualityDialog() {
    SongActionSheet.showDownloadQualityPicker(context, widget.song);
  }

  void _showAddToPlaylist(
    ThemeColors colors,
    AsyncValue<List<Playlist>> playlistsAsync,
  ) {
    // Save song reference BEFORE any pops (widget becomes invalid after pop).
    final targetSong = widget.song;
    playlistsAsync.when(
      data: (List<Playlist> playlists) {
        // Exclude __favorites__ from the picker (it has its own "收藏" toggle)
        final playlistList = playlists
            .where((p) => p.id != '__favorites__')
            .toList();
        // Save root navigator context BEFORE popping (after pop the widget context becomes invalid).
        final navContext = Navigator.of(context, rootNavigator: true).context;
        // Pop SongActionSheet first
        if (mounted) Navigator.pop(context);
        // navContext remains valid because it's from the root navigator.
        final bottomPadding = MediaQuery.of(navContext).padding.bottom;
        showModalBottomSheet(
          context: navContext,
          sheetAnimationStyle: _sheetAnimationStyle,
          backgroundColor: Colors.transparent,
          builder: (ctx) => Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
            ),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: EdgeInsets.only(bottom: bottomPadding + 16),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: AppSpacing.md),
                      Container(
                        width: 40,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.divider,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        ctx.tr('添加到歌单'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (playlistList.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.xl),
                          child: Text(
                            ctx.tr('暂无歌单'),
                            style: TextStyle(color: AppColors.textHint),
                          ),
                        )
                      else
                        ...playlistList.map<Widget>(
                          (Playlist playlist) => ListTile(
                            leading: Icon(
                              Icons.queue_music,
                              color: AppColors.textSecondary,
                            ),
                            title: Text(
                              playlist.name,
                              style: TextStyle(color: AppColors.textPrimary),
                            ),
                            trailing: Text(
                              ctx.tr('${playlist.songCount}首'),
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.textHint,
                              ),
                            ),
                            onTap: () async {
                              // 转换文案需在 pop 之前捕获（ctx 在 pop 后失效）
                              final addedMsg = ctx.tr('已添加到"${playlist.name}"');
                              final existsMsg = ctx.tr(
                                '歌曲已在歌单"${playlist.name}"中',
                              );
                              final failMsg = ctx.tr('添加到歌单失败');
                              Navigator.pop(ctx);
                              // Save messenger and container BEFORE any async gap.
                              // navContext is the root navigator context which remains valid
                              // across the entire app lifecycle.
                              // ignore: use_build_context_synchronously
                              final messenger = ScaffoldMessenger.of(
                                navContext,
                              );
                              // ignore: use_build_context_synchronously
                              final container = ProviderScope.containerOf(
                                navContext,
                              );
                              final notifier = container.read(
                                playlistsProvider.notifier,
                              );
                              try {
                                final added = await notifier.addSongToPlaylist(
                                  playlist.id,
                                  targetSong,
                                );
                                if (added) {
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(addedMsg),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                } else {
                                  messenger.showSnackBar(
                                    SnackBar(
                                      content: Text(existsMsg),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                }
                              } catch (e) {
                                messenger.showSnackBar(
                                  SnackBar(
                                    content: Text(failMsg),
                                    duration: const Duration(seconds: 2),
                                    backgroundColor: Colors.red,
                                  ),
                                );
                              }
                            },
                          ),
                        ),
                      const SizedBox(height: AppSpacing.lg),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
      loading: () {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.tr('加载歌单中...')),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      },
      error: (_, __) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(context.tr('加载歌单失败')),
              duration: const Duration(seconds: 2),
            ),
          );
        }
      },
    );
  }
}
