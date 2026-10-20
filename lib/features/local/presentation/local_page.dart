import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:file_picker/file_picker.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../core/utils/scroll_locate.dart';
import '../../../core/constants/app_routes.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_selection.dart';
import '../application/local_providers.dart';
import '../data/local_music_repository.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../library/application/playlist_providers.dart';
import '../../plugin/application/plugin_providers.dart';

class LocalPage extends ConsumerStatefulWidget {
  const LocalPage({super.key});

  @override
  ConsumerState<LocalPage> createState() => _LocalPageState();
}

/// 文件夹栏的滚动行为：桌面端允许用鼠标拖动横向列表。
///
/// Material 默认的 [MaterialScrollBehavior] 只接受触摸 / 触控笔拖动，
/// 桌面端鼠标无法拖动，这里把鼠标与触摸板也加进来。
class _LocalFolderScrollBehavior extends MaterialScrollBehavior {
  const _LocalFolderScrollBehavior();

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

class _LocalPageState extends ConsumerState<LocalPage> {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  /// 当前选中的扫描文件夹（null = 全部）。
  String? _selectedFolder;

  /// 批量选择控制器（长按歌曲进入多选模式）。
  final _selection = SongSelectionController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionAndScan();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _selection.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionAndScan() async {
    final repo = ref.read(localMusicRepositoryProvider);
    final hasPermission = await repo.checkPermission();
    if (!hasPermission) {
      if (mounted) _showPermissionDialog();
      return;
    }

    final songs = repo.getLocalSongs();
    if (songs.isEmpty) {
      await ref.read(localMusicNotifierProvider.notifier).scanAll();
    }
  }

  void _showPermissionDialog() {
    final colors = ref.read(themeColorsProvider);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(context.tr('需要存储权限'), style: TextStyle(color: colors.textPrimary)),
        content: Text(
          context.tr('为了扫描本地音乐，薄荷音乐需要访问您设备上的音频文件。请授予权限后继续。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final granted = await ref.read(localMusicNotifierProvider.notifier).requestPermissionAndScan();
              if (!granted && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('权限被拒绝，无法扫描本地音乐')), duration: const Duration(seconds: 3)),
                );
              }
            },
            child: Text(context.tr('授权'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  void _locateCurrentSong() {
    final playbackState = ref.read(playbackControllerProvider);
    final currentSong = playbackState.currentSong;
    if (currentSong == null) return;

    final songs = ref.read(filteredLocalSongsProvider);
    final index = songs.indexWhere((s) => s.id == currentSong.id);
    if (index == -1) return;

    unawaited(
      scrollToItemIndex(
        _scrollController,
        index: index,
        // 行高 + 分隔间距
        itemExtent: _LocalSongItem.itemExtent + _LocalSongItem.separatorExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final allSongs = ref.watch(filteredLocalSongsProvider);
    final songsAsync = ref.watch(localMusicNotifierProvider);
    final scanProgress = ref.watch(scanProgressProvider);
    final scannedDirs = ref.watch(scannedDirectoriesProvider).valueOrNull ??
        const <String>[];

    // 选中的文件夹被移除后回到「全部」
    if (_selectedFolder != null && !scannedDirs.contains(_selectedFolder)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _selectedFolder = null);
      });
    }

    // 按当前选中的文件夹过滤（顶部文件夹栏切换）。
    final songs = _selectedFolder == null
        ? allSongs
        : allSongs
            .where((s) => _isInFolder(s, _selectedFolder!))
            .toList();

    // 在 build 中直接计算按钮可见性，避免滚动事件初值问题导致按钮永远不显示。
    // 仅当正在播放本地歌曲且该歌曲在当前筛选列表中时显示。
    final currentSong = ref.watch(playbackControllerProvider.select((s) => s.currentSong));
    final showLocateBtn = currentSong != null &&
        currentSong.source == 'local' &&
        songs.indexWhere((s) => s.id == currentSong.id) >= 0;

    // 选择状态变化只影响「选择栏 + 列表勾选态 + 底部操作栏」，
    // 用 ListenableBuilder 收窄重建范围。
    return ListenableBuilder(
      listenable: _selection,
      builder: (context, _) {
        final selecting = _selection.isActive;
        return PopScope(
          // 多选模式下先拦截返回键用于退出选择，而不是直接离开页面。
          canPop: !selecting,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _selection.exit();
          },
          child: Scaffold(
            backgroundColor: colors.background,
            body: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  Column(
                    children: [
                      _buildHeader(colors, songs, scanProgress),
                      if (selecting)
                        // 多选模式：用选择栏替换常规控制区
                        // （对应 CeruMusic 中列表列头被整行替换的设计）。
                        SongSelectionBar(
                          colors: colors,
                          controller: _selection,
                          songs: songs,
                        )
                      else ...[
                        _buildFolderBar(colors, songs, scanProgress),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                      Expanded(
                        child: songsAsync.when(
                          data: (_) => _buildSongList(colors, songs, showLocateBtn),
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (e, _) =>
                              _buildErrorState(colors, e.toString()),
                        ),
                      ),
                    ],
                  ),
                  if (selecting)
                    Positioned(
                      left: 0,
                      right: 0,
                      // 宽屏（左侧导航栏）布局下内容区没有迷你播放器，
                      // 批量操作栏直接贴底；窄屏才需要避开迷你播放器。
                      bottom: ResponsiveLayout.hasBottomMiniPlayer(context)
                          ? AppSpacing.miniPlayerHeight
                          : 0,
                      child: SongBatchActionBar(
                        colors: colors,
                        controller: _selection,
                        onPlayNext: () => _batchPlayNext(songs),
                        onAddToQueue: () => _batchAddToQueue(songs),
                        onAddToPlaylist: () => _batchAddToPlaylist(songs),
                        onFavorite: () => _batchFavorite(songs),
                        onRemove: () => _confirmDeleteSelected(songs),
                        removeLabel: '删除',
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  /// 顶部：标题 + 搜索框 + 选择目录 / 扫描 / 更多操作三个图标按钮。
  Widget _buildHeader(
    ThemeColors colors,
    List<Song> songs,
    ScanProgress scanProgress,
  ) {
    final isTablet = ResponsiveLayout.isTablet(context);
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ResponsiveLayout.horizontalPadding(context),
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 24,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            context.tr('本地音乐'),
            style: TextStyle(
              fontSize: isTablet ? 26 : 22,
              fontWeight: FontWeight.bold,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          // 搜索框：与发现页保持一致的最大 / 最小宽度
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: 140,
                  maxWidth: isTablet ? 420 : 300,
                ),
                child: _buildSearchBar(colors),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildHeaderIconButton(
            colors,
            Icons.folder_open,
            context.tr('选择目录'),
            () => _showDirModal(colors),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildHeaderIconButton(
            colors,
            Icons.refresh,
            context.tr('扫描本地音乐'),
            () => _scanLibrary(),
            active: scanProgress.running,
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildHeaderIconButton(
            colors,
            Icons.more_horiz,
            context.tr('更多操作'),
            () => _showMoreActions(colors, songs),
          ),
        ],
      ),
    );
  }

  /// 顶部图标按钮（统一风格：圆角方块 + 居中图标）。
  Widget _buildHeaderIconButton(
    ThemeColors colors,
    IconData icon,
    String tooltip,
    VoidCallback onTap, {
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(
            icon,
            size: 20,
            color: active ? colors.primary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 第二行：已添加的文件夹列表。
  ///
  /// 超出窗口宽度时可鼠标拖动 / 触摸左右滑动，点击某个文件夹即只看该文件夹
  /// 内的歌曲。
  Widget _buildFolderBar(
    ThemeColors colors,
    List<Song> songs,
    ScanProgress scanProgress,
  ) {
    final dirs = ref.watch(scannedDirectoriesProvider).valueOrNull ??
        const <String>[];
    if (dirs.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: MediaQuery.withClampedTextScaling(
        // 限制文本缩放，避免大字体时文件夹名称被裁切。
        maxScaleFactor: 1.2,
        child: Row(
          children: [
            Expanded(
              child: ScrollConfiguration(
                // 桌面端允许用鼠标拖动横向列表
                behavior: const _LocalFolderScrollBehavior(),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: EdgeInsets.symmetric(
                    horizontal: ResponsiveLayout.horizontalPadding(context),
                    vertical: AppSpacing.xs,
                  ),
                  itemCount: dirs.length + 1,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: AppSpacing.sm),
                  itemBuilder: (context, index) {
                    if (index == 0) {
                      return _buildFolderChip(
                        colors,
                        context.tr('全部'),
                        isSelected: _selectedFolder == null,
                        onTap: () => _selectFolder(null),
                      );
                    }
                    final dir = dirs[index - 1];
                    return _buildFolderChip(
                      colors,
                      _folderName(dir),
                      isSelected: _selectedFolder == dir,
                      onTap: () => _selectFolder(dir),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (scanProgress.running) ...[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${scanProgress.processed}/${scanProgress.total}',
                style: TextStyle(fontSize: 11, color: colors.textHint),
              ),
              const SizedBox(width: AppSpacing.sm),
            ],
            Padding(
              padding: EdgeInsets.only(
                right: ResponsiveLayout.horizontalPadding(context),
              ),
              child: Text(
                context.tr('${songs.length} 首'),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文件夹标签：仅显示文件夹名称，选中态用主色高亮。
  Widget _buildFolderChip(
    ThemeColors colors,
    String name, {
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected ? colors.primary : colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: isSelected ? colors.primary : colors.divider,
          ),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 180),
          child: Text(
            name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: isSelected ? colors.textOnPrimary : colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// 切换选中的文件夹（null = 全部）。
  void _selectFolder(String? dir) {
    if (_selectedFolder == dir) return;
    setState(() => _selectedFolder = dir);
  }

  /// 文件夹显示名（取最后一级目录名）。
  String _folderName(String dir) {
    final normalized = dir.replaceAll('\\', '/').replaceAll(RegExp(r'/+$'), '');
    final index = normalized.lastIndexOf('/');
    if (index < 0 || index == normalized.length - 1) return normalized;
    return normalized.substring(index + 1);
  }

  /// 歌曲是否位于指定文件夹内。
  bool _isInFolder(Song song, String folder) {
    final filePath = (song.filePath ?? '').replaceAll('\\', '/').toLowerCase();
    var dir = folder.replaceAll('\\', '/').toLowerCase();
    if (dir.isEmpty) return false;
    if (!dir.endsWith('/')) dir = '$dir/';
    return filePath.startsWith(dir);
  }

  Widget _buildSearchBar(ThemeColors colors) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 18, color: colors.textHint),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                ref.read(localSearchQueryProvider.notifier).state = value;
              },
              decoration: InputDecoration(
                hintText: context.tr('搜索本地歌曲/歌手/专辑'),
                border: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.zero,
                hintStyle: TextStyle(color: colors.textHint, fontSize: 14),
              ),
              style: TextStyle(color: colors.textPrimary, fontSize: 14),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
                ref.read(localSearchQueryProvider.notifier).state = '';
              },
              child: Icon(Icons.close, size: 18, color: colors.textHint),
            ),
        ],
      ),
    );
  }

  Widget _buildSongList(ThemeColors colors, List<Song> songs, bool showLocateBtn) {
    if (songs.isEmpty) {
      return _buildEmptyState(colors);
    }

    final selecting = _selection.isActive;
    return Stack(
      children: [
        ListView.separated(
          controller: _scrollController,
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            // 底部多留出空间，避免最后一项被悬浮的迷你播放器遮挡；
            // 多选模式下还要再避开底部批量操作栏。
            bottom: AppSpacing.xxxl +
                AppSpacing.huge +
                (selecting ? SongBatchActionBar.height : 0),
          ),
          itemCount: songs.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: _LocalSongItem.separatorExtent),
          itemBuilder: (context, index) {
            final song = songs[index];
            return _LocalSongItem(
              key: ValueKey(song.id),
              song: song,
              index: index,
              onPlay: _playSong,
              onContextMenu: _showSongContextMenu,
              selectionMode: selecting,
              selected: _selection.isSelected(song.id),
              onSelectionToggle: (s) => _selection.toggle(s.id),
              onLongPress: () => _enterSelection(song),
            );
          },
        ),
        // 定位当前播放歌曲的悬浮按钮（右下角，避开底部迷你播放器）
        if (showLocateBtn && !selecting)
          Positioned(
            right: AppSpacing.lg,
            bottom: AppSpacing.miniPlayerHeight + AppSpacing.xxl,
            child: GestureDetector(
              onTap: _locateCurrentSong,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: colors.surface,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: colors.shadow,
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(Icons.my_location, size: 18, color: colors.primary),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildEmptyState(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(Icons.library_music, size: 40, color: colors.primary.withValues(alpha: 0.5)),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            context.tr('暂无本地音乐'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500, color: colors.textPrimary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            context.tr('点击下方按钮扫描设备音乐'),
            style: TextStyle(fontSize: 13, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.lg),
          GestureDetector(
            onTap: () async {
              final granted = await ref.read(localMusicNotifierProvider.notifier).requestPermissionAndScan();
              if (!granted && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(context.tr('权限被拒绝，无法扫描本地音乐')), duration: const Duration(seconds: 3)),
                );
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Text(
                context.tr('扫描本地音乐'),
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: colors.textOnPrimary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(ThemeColors colors, String error) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: colors.textHint),
          const SizedBox(height: AppSpacing.md),
          Text(context.tr('加载失败'), style: TextStyle(color: colors.textHint)),
          const SizedBox(height: AppSpacing.xs),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
            child: Text(
              error,
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextButton(
            onPressed: () => ref.read(localMusicNotifierProvider.notifier).refresh(),
            child: Text(context.tr('重试'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  void _playSong(Song song) {
    final songs = ref.read(filteredLocalSongsProvider);
    final index = songs.indexWhere((s) => s.id == song.id);
    final controller = ref.read(playbackControllerProvider.notifier);
    controller.setQueue(songs, startIndex: index >= 0 ? index : 0);
  }

  void _playAll(List<Song> songs) {
    if (songs.isEmpty) return;
    final controller = ref.read(playbackControllerProvider.notifier);
    controller.setQueue(songs);
  }

  void _addAllToPlaylist(List<Song> songs) {
    if (songs.isEmpty) return;
    final controller = ref.read(playbackControllerProvider.notifier);
    controller.appendToQueue(songs);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('已将 ${songs.length} 首加入播放列表')), duration: const Duration(seconds: 2)),
    );
  }

  Future<void> _scanLibrary() async {
    await ref.read(localMusicNotifierProvider.notifier).requestPermissionAndScan();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('扫描完成')), duration: const Duration(seconds: 2)),
      );
    }
  }

  // ---------------------------------------------------------------- 批量选择

  /// 长按歌曲进入批量选择模式，并选中该首（CeruMusic 里由菜单项进入，
  /// 本项目按需要在长按处进入）。
  void _enterSelection(Song song) {
    if (_selection.isActive) {
      _selection.toggle(song.id);
    } else {
      _selection.enter(song.id);
    }
  }

  List<Song> _selectedSongs(List<Song> source) =>
      _selection.selectedSongs(source);

  void _batchPlayNext(List<Song> songs) {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    ref.read(playbackControllerProvider.notifier).insertNext(selected);
    _showMessage('已将 ${selected.length} 首插入到下一首播放');
  }

  void _batchAddToQueue(List<Song> songs) {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    ref.read(playbackControllerProvider.notifier).appendToQueue(selected);
    _showMessage('已将 ${selected.length} 首加入播放列表');
  }

  void _batchAddToPlaylist(List<Song> songs) {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    final colors = ref.read(themeColorsProvider);
    unawaited(showAddSongsToPlaylistSheet(context, ref, colors, selected));
  }

  Future<void> _batchFavorite(List<Song> songs) async {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    await ref
        .read(playlistsProvider.notifier)
        .addSongsToPlaylist('__favorites__', selected);
    if (mounted) _showMessage('已收藏 ${selected.length} 首');
  }

  Future<void> _confirmDeleteSelected(List<Song> songs) async {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('删除歌曲'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定要删除选中的 ${selected.length} 首歌曲吗？\n此操作将从本地音乐库移除这些歌曲。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              context.tr('删除'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final removed = await ref
        .read(localMusicNotifierProvider.notifier)
        .deleteSongs(selected);
    if (!mounted) return;
    _selection.exit();
    _showMessage('已删除 $removed 首歌曲');
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr(message)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showSongContextMenu(ThemeColors colors, Song song) {
    final songs = ref.read(filteredLocalSongsProvider);
    showModalBottomSheet(
      context: context,
      // 用根导航器弹出，避免弹窗被 AppShell 中悬浮的迷你播放器遮挡
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (context) => SongActionSheet(
        song: song,
        playlistSongs: songs,
        showDownload: false,
        showEditTag: true,
        showAccurateMatch: true,
        onAccurateMatch: () => _showAccurateMatch(colors, song),
        showDelete: true,
        onDelete: () => _confirmDeleteSong(song),
      ),
    );
  }

  Future<void> _confirmDeleteSong(Song song) async {
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(context.tr('删除歌曲'), style: TextStyle(color: colors.textPrimary)),
        content: Text(
          context.tr('确定要删除「${song.title}」吗？\n此操作将从本地音乐库移除该歌曲。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(context.tr('删除'), style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final ok = await ref
        .read(localMusicNotifierProvider.notifier)
        .deleteSong(song);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? context.tr('已删除「${song.title}」') : context.tr('删除失败')),
        duration: const Duration(seconds: 2),
        backgroundColor: ok ? null : Colors.red,
      ),
    );
  }

  Widget _contextMenuItem(ThemeColors colors, IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.md),
        child: Row(
          children: [
            Icon(icon, size: 22, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
            Text(
              label,
              style: TextStyle(fontSize: 15, color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }

  void _showMoreActions(ThemeColors colors, List<Song> songs) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomPadding + 72),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      context.tr('更多操作'),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.textPrimary),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _contextMenuItem(colors, Icons.play_arrow, context.tr('播放全部'), () {
                      Navigator.pop(context);
                      _playAll(songs);
                    }),
                    _contextMenuItem(colors, Icons.playlist_add, context.tr('添加全部到播放列表'), () {
                      Navigator.pop(context);
                      _addAllToPlaylist(songs);
                    }),
                    _contextMenuItem(colors, Icons.delete_outline, context.tr('清空所有'), () {
                      Navigator.pop(context);
                      _confirmClearIndex(colors);
                    }),
                    _contextMenuItem(colors, Icons.auto_fix_high, context.tr('批量匹配封面和歌词'), () {
                      Navigator.pop(context);
                      _startBatchMatch(colors, songs);
                    }),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _confirmClearIndex(ThemeColors colors) {
    showDialog(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(context.tr('确认清空'), style: TextStyle(color: colors.textPrimary)),
        content: Text(context.tr('将清空所有本地音乐索引，此操作不可恢复。'), style: TextStyle(color: colors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(context.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              ref.read(localMusicNotifierProvider.notifier).clearIndex();
            },
            child: Text(context.tr('确认'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
  }

  void _startBatchMatch(ThemeColors colors, List<Song> songs) {
    // 筛选缺少封面或歌词的歌曲
    final needMatch = songs.where((s) {
      final noCover = s.coverUrl == null || s.coverUrl!.isEmpty;
      final noLyric = s.lrc == null || s.lrc!.isEmpty;
      return noCover || noLyric;
    }).toList();

    if (needMatch.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('所有歌曲已有封面和歌词')), duration: const Duration(seconds: 2)),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(context.tr('开始匹配 ${needMatch.length} 首歌曲的封面和歌词...')), duration: const Duration(seconds: 2)),
    );

    _doBatchMatch(colors, needMatch, 0, 0);
  }

  Future<void> _doBatchMatch(ThemeColors colors, List<Song> songs, int index, int matched) async {
    if (index >= songs.length) {
      ref.read(batchMatchProgressProvider.notifier).state = BatchMatchProgress(
        processed: songs.length,
        total: songs.length,
        matched: matched,
        running: false,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('批量匹配完成，成功匹配 $matched 首')), duration: const Duration(seconds: 3)),
        );
      }
      return;
    }

    ref.read(batchMatchProgressProvider.notifier).state = BatchMatchProgress(
      processed: index,
      total: songs.length,
      matched: matched,
      running: true,
    );

    final song = songs[index];
    try {
      final manager = ref.read(musicSourceManagerProvider);

      // 构建搜索关键词
      final title = song.title.trim();
      final artist = song.artist.trim();
      final searchQuery = (title.isEmpty || title == '未知曲目')
          ? (artist.isNotEmpty && artist != '未知艺术家' ? artist : '')
          : (artist.isEmpty || artist == '未知艺术家' ? title : '$title $artist');

      if (searchQuery.isEmpty) {
        _doBatchMatch(colors, songs, index + 1, matched);
        return;
      }

      // 并行搜索五大音源
      final aggregated = await manager.aggregateSearch(
        searchQuery,
        sourceIds: const ['wy', 'kg', 'tx', 'kw', 'mg'],
        limit: 5,
      );

      if (aggregated.isEmpty) {
        _doBatchMatch(colors, songs, index + 1, matched);
        return;
      }

      // 收集所有候选结果并评分排序
      final candidates = <MapEntry<Song, String>>[];
      for (final entry in aggregated.entries) {
        for (final searchSong in entry.value) {
          candidates.add(MapEntry(searchSong.copyWith(source: entry.key), entry.key));
        }
      }
      candidates.sort((a, b) =>
          _scoreMatchCandidate(b.key, song).compareTo(_scoreMatchCandidate(a.key, song)));

      // 从最优候选开始，并发获取封面和歌词，最多尝试 3 个候选
      Song? bestMatch;
      int tried = 0;
      for (final candidate in candidates) {
        final score = _scoreMatchCandidate(candidate.key, song);
        if (score < 0.3) break;
        if (tried >= 3) break;
        tried++;

        String? coverUrl;
        String? lyric;

        // 优先使用搜索结果中已有的 coverUrl（避免不必要的 API 调用）
        final existingCover = candidate.key.coverUrl;
        if (existingCover != null && existingCover.isNotEmpty) {
          coverUrl = existingCover;
        }

        // 并发获取封面和歌词
        final results = await Future.wait([
          coverUrl == null
              ? manager.getPic(candidate.key, preferBuiltIn: false)
                  .timeout(const Duration(seconds: 8))
              : Future<String?>.value(coverUrl),
          manager.getLyricResult(candidate.key).timeout(const Duration(seconds: 8)),
        ]);

        if (coverUrl == null) {
          coverUrl = results[0] as String?;
        }
        final lyricResult = results[1] as dynamic;
        if (lyricResult != null) {
          final crlyric = lyricResult.crlyric as String?;
          final lrc = lyricResult.lrc as String?;
          if (crlyric != null && crlyric.isNotEmpty) {
            lyric = crlyric;
          } else if (lrc != null && lrc.isNotEmpty) {
            lyric = lrc;
          }
        }

        // 至少获取到封面或歌词才算成功
        if (coverUrl != null || lyric != null) {
          debugPrint('[BatchMatch] ${song.title} → 封面=${coverUrl != null ? "✓" : "✗"} 歌词=${lyric != null ? "✓" : "✗"} 来源=${candidate.key.source}');
          bestMatch = song.copyWith(
            title: candidate.key.title.isNotEmpty ? candidate.key.title : song.title,
            artist: candidate.key.artist.isNotEmpty ? candidate.key.artist : song.artist,
            album: candidate.key.album.isNotEmpty ? candidate.key.album : song.album,
            coverUrl: coverUrl ?? song.coverUrl,
            hasCover: (coverUrl != null && coverUrl.isNotEmpty) || song.hasCover,
            lrc: lyric ?? song.lrc,
          );
          break;
        }
      }

      if (bestMatch != null) {
        await ref.read(localMusicNotifierProvider.notifier).upsertSong(bestMatch);
        // 如果是当前正在播放的歌曲，同步更新播放队列
        ref.read(playbackControllerProvider.notifier).updateSongInQueue(bestMatch);
        _doBatchMatch(colors, songs, index + 1, matched + 1);
        return;
      }
      debugPrint('[BatchMatch] ${song.title} 未找到可用封面或歌词（尝试了 $tried 个候选）');
    } catch (e) {
      debugPrint('[BatchMatch] ${song.title} 异常: $e');
    }
    _doBatchMatch(colors, songs, index + 1, matched);
  }

  /// 评分候选结果。返回 0.0 ~ 1.0 的分数。
  double _scoreMatchCandidate(Song candidate, Song local) {
    double score = 0.0;

    // 标题匹配 (权重 0.5)
    final titleA = candidate.title.toLowerCase();
    final titleB = local.title.toLowerCase();
    if (titleA == titleB) {
      score += 0.5;
    } else if (titleA.contains(titleB) || titleB.contains(titleA)) {
      score += 0.4;
    } else {
      final setA = titleA.split('').toSet();
      final setB = titleB.split('').toSet();
      final intersection = setA.intersection(setB).length;
      final union = setA.union(setB).length;
      score += (union > 0 ? intersection / union : 0.0) * 0.5;
    }

    // 艺术家匹配 (权重 0.3)
    final artistA = candidate.artist.toLowerCase();
    final artistB = local.artist.toLowerCase();
    if (artistA == artistB) {
      score += 0.3;
    } else if (artistA.contains(artistB) || artistB.contains(artistA)) {
      score += 0.25;
    } else {
      final setA = artistA.split('').toSet();
      final setB = artistB.split('').toSet();
      final intersection = setA.intersection(setB).length;
      final union = setA.union(setB).length;
      score += (union > 0 ? intersection / union : 0.0) * 0.3;
    }

    // 时长匹配 (权重 0.1)
    if (local.duration > 0 && candidate.duration > 0) {
      final durationDiff = (candidate.duration - local.duration).abs();
      final durationScore = durationDiff <= 3
          ? 1.0
          : durationDiff <= 10
              ? 0.7
              : durationDiff <= 30
                  ? 0.3
                  : 0.0;
      score += durationScore * 0.1;
    }

    // 封面可用性 (权重 0.05)
    if (candidate.coverUrl != null && candidate.coverUrl!.isNotEmpty) {
      score += 0.05;
    }

    // 歌词可用性 (权重 0.05)
    score += 0.05;

    return score;
  }

  /// 搜索源显示名称
  static const Map<String, String> _sourceDisplayNames = {
    'wy': '网易云',
    'kg': '酷狗',
    'kw': '酷我',
    'tx': 'QQ',
    'mg': '咪咕',
  };

  /// 聚合五大平台搜索，每源最多取 2 条，总计最多 10 条
  Future<List<Song>> _searchOnlineForMatch(String keyword) async {
    try {
      final manager = ref.read(musicSourceManagerProvider);
      final aggregated = await manager.aggregateSearch(
        keyword,
        sourceIds: const ['wy', 'kg', 'tx', 'kw', 'mg'],
        limit: 5,
      );
      // 每源最多取 2 条，确保结果均衡
      final perSourceLimit = 2;
      final all = <Song>[];
      for (final entry in aggregated.entries) {
        final sourceSongs = entry.value.take(perSourceLimit).toList();
        for (final song in sourceSongs) {
          all.add(song.copyWith(source: entry.key));
        }
      }
      return all.take(10).toList();
    } catch (_) {
      return [];
    }
  }

  void _showAccurateMatch(ThemeColors colors, Song song) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return Container(
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: EdgeInsets.only(bottom: bottomPadding + 72),
              child: DraggableScrollableSheet(
              initialChildSize: 0.6,
              minChildSize: 0.3,
              maxChildSize: 0.9,
              expand: false,
              builder: (context, scrollController) {
              return Column(
                children: [
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: colors.divider,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    context.tr('精准匹配'),
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.textPrimary),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                    child: Text(
                      '${song.title} - ${song.artist}',
                      style: TextStyle(fontSize: 13, color: colors.textHint),
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Expanded(
                    child: FutureBuilder<List<Song>>(
                      future: _searchOnlineForMatch(song.title),
                      builder: (context, snapshot) {
                        if (snapshot.connectionState == ConnectionState.waiting) {
                          return const Center(child: CircularProgressIndicator());
                        }
                        final results = snapshot.data ?? [];
                        if (results.isEmpty) {
                          return Center(
                            child: Text(context.tr('未找到匹配结果'), style: TextStyle(color: colors.textHint)),
                          );
                        }
                        return ListView.builder(
                          controller: scrollController,
                          itemCount: results.length,
                          addAutomaticKeepAlives: false,
                          addRepaintBoundaries: true,
                          itemBuilder: (context, index) {
                            final candidate = results[index];
                            return _buildMatchCandidate(colors, song, candidate);
                          },
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMatchCandidate(ThemeColors colors, Song original, Song candidate) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg, vertical: AppSpacing.xs),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: colors.divider),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.sm),
                image: candidate.coverUrl != null
                    ? DecorationImage(image: NetworkImage(candidate.coverUrl!), fit: BoxFit.cover)
                    : null,
              ),
              child: candidate.coverUrl == null
                  ? Icon(Icons.music_note, size: 20, color: colors.textHint)
                  : null,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    candidate.title,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: colors.textPrimary),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      if (candidate.source != null)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            _sourceDisplayNames[candidate.source] ?? candidate.source!,
                            style: TextStyle(fontSize: 10, color: colors.primary, fontWeight: FontWeight.w500),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          '${candidate.artist} · ${candidate.album}',
                          style: TextStyle(fontSize: 12, color: colors.textHint),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            GestureDetector(
              onTap: () {
                // 关闭搜索结果弹窗，然后打开确认弹窗
                Navigator.of(context, rootNavigator: true).pop();
                _showMatchConfirmation(colors, original, candidate);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  context.tr('使用'),
                  style: TextStyle(fontSize: 12, color: colors.textOnPrimary, fontWeight: FontWeight.w500),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 精准匹配确认弹窗：展示封面预览、歌词预览，确认后保存到本地歌曲
  void _showMatchConfirmation(ThemeColors colors, Song original, Song candidate) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _MatchConfirmationSheet(
          original: original,
          candidate: candidate,
          bottomPadding: bottomPadding,
        );
      },
    );
  }

  void _showAddToPlaylistSheet(ThemeColors colors, Song song, AsyncValue playlistsAsync) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    playlistsAsync.when(
      data: (playlists) {
        showModalBottomSheet(
          context: context,
          useRootNavigator: true,
          backgroundColor: Colors.transparent,
          builder: (context) {
            return Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.only(bottom: bottomPadding + 72),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(height: AppSpacing.md),
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: colors.divider,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          context.tr('添加到歌单'),
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.textPrimary),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (playlists.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Text(context.tr('暂无歌单'), style: TextStyle(color: colors.textHint)),
                          )
                        else
                          ...playlists.map<Widget>((playlist) => ListTile(
                                leading: Icon(Icons.queue_music, color: colors.textSecondary),
                                title: Text(playlist.name, style: TextStyle(color: colors.textPrimary)),
                                trailing: Text(
                                  context.tr('${playlist.songCount}首'),
                                  style: TextStyle(fontSize: 12, color: colors.textHint),
                                ),
                                onTap: () {
                                  Navigator.pop(context);
                                  ref.read(playlistsProvider.notifier).addSongToPlaylist(playlist.id, song);
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text(context.tr('已添加到"${playlist.name}"')),
                                      duration: const Duration(seconds: 2),
                                    ),
                                  );
                                },
                              )),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
      loading: () => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('加载歌单中...')), duration: const Duration(seconds: 1)),
      ),
      error: (_, __) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('加载歌单失败')), duration: const Duration(seconds: 2)),
      ),
    );
  }

  Future<void> _showDirModal(ThemeColors colors) async {
    // 从持久化加载真实目录（FutureProvider 首次 init 后走缓存）。
    final dirs = List<String>.from(await ref.read(scannedDirectoriesProvider.future));
    if (!mounted) return;
    final bottomPadding = MediaQuery.of(context).padding.bottom;

    showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(context).viewInsets.bottom + bottomPadding + 72,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: AppSpacing.md),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: colors.divider,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      context.tr('扫描目录设置'),
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.textPrimary),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      context.tr(
                        dirs.isEmpty
                            ? '未设置目录时将扫描设备全部音乐'
                            : '设置目录后仅扫描指定目录下的音乐',
                      ),
                      style: TextStyle(fontSize: 12, color: colors.textHint),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (dirs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.all(AppSpacing.lg),
                        child: Column(
                          children: [
                            Icon(Icons.all_inclusive, size: 32, color: colors.primary.withValues(alpha: 0.5)),
                            const SizedBox(height: AppSpacing.sm),
                            Text(context.tr('当前：扫描全部音乐'), style: TextStyle(color: colors.textSecondary, fontSize: 13)),
                          ],
                        ),
                      )
                    else
                      ...dirs.map((d) => Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                              vertical: AppSpacing.xs,
                            ),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                                vertical: AppSpacing.sm,
                              ),
                              decoration: BoxDecoration(
                                color: colors.surfaceVariant,
                                borderRadius: BorderRadius.circular(AppRadius.md),
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.folder, size: 18, color: colors.textSecondary),
                                  const SizedBox(width: AppSpacing.sm),
                                  Expanded(
                                    child: Text(
                                      d,
                                      style: TextStyle(fontSize: 13, color: colors.textPrimary),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  GestureDetector(
                                    onTap: () {
                                      dirs.remove(d);
                                      setModalState(() {});
                                      // 立即持久化，避免不点确认直接关闭弹窗后丢失
                                      unawaited(
                                        ref
                                            .read(localMusicNotifierProvider.notifier)
                                            .setDirectories(dirs),
                                      );
                                    },
                                    child: Icon(Icons.close, size: 16, color: colors.textHint),
                                  ),
                                ],
                              ),
                            ),
                          )),
                    const SizedBox(height: AppSpacing.lg),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                      child: Row(
                        children: [
                          Expanded(
                            child: GestureDetector(
                              onTap: () {
                                dirs.clear();
                                setModalState(() {});
                                unawaited(
                                  ref
                                      .read(localMusicNotifierProvider.notifier)
                                      .setDirectories(dirs),
                                );
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: colors.surfaceVariant,
                                  borderRadius: BorderRadius.circular(AppRadius.full),
                                  border: Border.all(color: colors.divider),
                                ),
                                child: Text(
                                  context.tr('扫描全部'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: colors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: AppSpacing.md),
                          Expanded(
                            child: GestureDetector(
                              onTap: () async {
                                final result = await _pickDirectory();
                                if (result != null && !dirs.contains(result)) {
                                  dirs.add(result);
                                  setModalState(() {});
                                  unawaited(
                                    ref
                                        .read(localMusicNotifierProvider.notifier)
                                        .setDirectories(dirs),
                                  );
                                }
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                decoration: BoxDecoration(
                                  color: colors.surfaceVariant,
                                  borderRadius: BorderRadius.circular(AppRadius.full),
                                  border: Border.all(color: colors.divider),
                                ),
                                child: Text(
                                  context.tr('添加文件夹'),
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: colors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                      child: GestureDetector(
                        onTap: () async {
                          await ref.read(localMusicNotifierProvider.notifier).setDirectories(dirs);
                          await ref.read(localMusicNotifierProvider.notifier).scanAll();
                          if (context.mounted) {
                            Navigator.pop(context);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(context.tr('目录已保存并重新扫描')), duration: const Duration(seconds: 2)),
                            );
                          }
                        },
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          decoration: BoxDecoration(
                            color: colors.primary,
                            borderRadius: BorderRadius.circular(AppRadius.full),
                          ),
                          child: Text(
                            context.tr('确认并重新扫描'),
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.textOnPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.lg),
                  ],
                ),
              ),
            ),
            );
          },
        );
      },
    );
  }

  Future<String?> _pickDirectory() async {
    try {
      final result = await FilePicker.platform.getDirectoryPath();
      return result;
    } catch (_) {
      return null;
    }
  }
}

class _LocalSongItem extends ConsumerWidget {
  const _LocalSongItem({
    super.key,
    required this.song,
    required this.index,
    required this.onPlay,
    required this.onContextMenu,
    this.selectionMode = false,
    this.selected = false,
    this.onSelectionToggle,
    this.onLongPress,
  });

  /// 单行高度（48 封面 + 上下各 8 内边距）。
  ///
  /// 行高由内容决定，这里用 SizedBox 固定住，保证定位时用的行高常量与真实
  /// 行高完全一致 —— 否则每一行几像素的误差到第 85 行就会放大成几百像素，
  /// 目标会滚出可视区。
  static const double itemExtent = 64.0;

  /// 列表分隔间距（ListView.separated）。
  static const double separatorExtent = 2.0;

  final Song song;
  final int index;
  final void Function(Song song) onPlay;
  final void Function(ThemeColors colors, Song song) onContextMenu;
  final bool selectionMode;
  final bool selected;
  final void Function(Song song)? onSelectionToggle;

  /// 长按回调：进入批量选择模式（菜单改由右侧 more_vert 按钮触发）。
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final playingId = ref.watch(playbackControllerProvider.select((s) => s.currentSong?.id));
    final isPlaying = playingId == song.id;

    return SizedBox(
      // 固定行高，保证 itemExtent 与实际布局一致
      height: itemExtent,
      child: GestureDetector(
      onTap: selectionMode ? () => onSelectionToggle?.call(song) : () => onPlay(song),
      onLongPress: selectionMode ? null : onLongPress,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected
              ? colors.primary.withValues(alpha: 0.10)
              : (isPlaying ? colors.primary.withValues(alpha: 0.08) : Colors.transparent),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          children: [
            // 序号 / 勾选框
            SizedBox(
              width: 28,
              child: selectionMode
                  ? IgnorePointer(
                      // 只做展示：整行点击由外层 GestureDetector 处理
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) {},
                        activeColor: colors.primary,
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    )
                  : (isPlaying
                        ? Icon(Icons.play_arrow, size: 18, color: colors.primary)
                        : Text(
                            '${index + 1}',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 13,
                              color: colors.textHint,
                              fontWeight: FontWeight.w500,
                            ),
                          )),
            ),
            const SizedBox(width: AppSpacing.sm),
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              // 优先使用 coverUrl（精准匹配后的在线封面），再回退到设备本地封面
              child: song.coverUrl != null && song.coverUrl!.isNotEmpty
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: MusicCoverImage(
                        key: ValueKey('local_cover_${song.id}'),
                        url: song.coverUrl,
                        fit: BoxFit.cover,
                        width: 48,
                        height: 48,
                        errorWidget: Icon(
                          isPlaying ? Icons.equalizer : Icons.music_note,
                          size: 22,
                          color: isPlaying ? colors.primary : colors.textHint,
                        ),
                      ),
                    )
                  : ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                      child: MusicCoverImage(
                        key: ValueKey('local_cover_${song.id}'),
                        songId: song.id,
                        // 桌面端没有 MediaStore，封面来自扫描时写入的封面缓存
                        mediaStoreId: song.mediaStoreId,
                        fit: BoxFit.cover,
                        width: 48,
                        height: 48,
                        errorWidget: Icon(
                          isPlaying ? Icons.equalizer : Icons.music_note,
                          size: 22,
                          color:
                              isPlaying ? colors.primary : colors.textHint,
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
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isPlaying ? colors.primary : colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    song.artist,
                    style: TextStyle(fontSize: 12, color: colors.textHint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (song.duration > 0)
              Text(
                song.displayDuration,
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            // 多选模式下隐藏「更多」按钮，避免与选择手势冲突
            if (!selectionMode) ...[
              const SizedBox(width: AppSpacing.xs),
              GestureDetector(
                onTap: () => onContextMenu(colors, song),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.more_vert, size: 18, color: colors.textHint),
                ),
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}

/// 精准匹配确认弹窗：展示封面预览、歌词预览，确认后保存到本地歌曲
class _MatchConfirmationSheet extends ConsumerStatefulWidget {
  const _MatchConfirmationSheet({
    required this.original,
    required this.candidate,
    required this.bottomPadding,
  });

  final Song original;
  final Song candidate;
  final double bottomPadding;

  @override
  ConsumerState<_MatchConfirmationSheet> createState() => _MatchConfirmationSheetState();
}

class _MatchConfirmationSheetState extends ConsumerState<_MatchConfirmationSheet> {
  String? _lyric;
  bool _loadingLyric = true;
  String? _lyricError;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _fetchLyric();
  }

  Future<void> _fetchLyric() async {
    try {
      final manager = ref.read(musicSourceManagerProvider);
      final lyric = await manager.getLyric(widget.candidate);
      if (mounted) {
        setState(() {
          _lyric = lyric;
          _loadingLyric = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _lyricError = '歌词获取失败: $e';
          _loadingLyric = false;
        });
      }
    }
  }

  Future<void> _handleConfirm() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      final updated = widget.original.copyWith(
        title: widget.candidate.title,
        artist: widget.candidate.artist,
        album: widget.candidate.album,
        coverUrl: widget.candidate.coverUrl,
        hasCover: widget.candidate.coverUrl != null,
        lrc: _lyric?.isNotEmpty == true ? _lyric : null,
      );
      await ref.read(localMusicNotifierProvider.notifier).upsertSong(updated, forceOverwrite: true);
      // 同步更新播放队列中的歌曲，确保迷你播放器/全屏播放页封面和歌词即时刷新
      ref.read(playbackControllerProvider.notifier).updateSongInQueue(updated);
      if (mounted) {
        Navigator.of(context, rootNavigator: true).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('已应用匹配结果')), duration: const Duration(seconds: 2)),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('保存失败: $e')), duration: const Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final candidate = widget.candidate;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: Column(
        children: [
          // 拖拽指示条
          const SizedBox(height: AppSpacing.md),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: colors.divider,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            context.tr('确认匹配'),
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: colors.textPrimary),
          ),
          const SizedBox(height: AppSpacing.sm),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              '${widget.original.title} - ${widget.original.artist}',
              style: TextStyle(fontSize: 13, color: colors.textHint),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 封面预览
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                // 原始封面
                Column(
                  children: [
                    Text(context.tr('当前'), style: TextStyle(fontSize: 11, color: colors.textHint)),
                    const SizedBox(height: 4),
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: widget.original.hasCover && widget.original.coverUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              child: Image.network(
                                widget.original.coverUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(Icons.music_note, size: 28, color: colors.textHint),
                              ),
                            )
                          : Icon(Icons.music_note, size: 28, color: colors.textHint),
                    ),
                  ],
                ),
                const SizedBox(width: AppSpacing.md),
                // 箭头
                Icon(Icons.arrow_forward, color: colors.primary, size: 24),
                const SizedBox(width: AppSpacing.md),
                // 匹配封面
                Column(
                  children: [
                    Text(context.tr('匹配'), style: TextStyle(fontSize: 11, color: colors.primary)),
                    const SizedBox(height: 4),
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: candidate.coverUrl != null
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              child: Image.network(
                                candidate.coverUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(Icons.music_note, size: 28, color: colors.textHint),
                              ),
                            )
                          : Icon(Icons.music_note, size: 28, color: colors.textHint),
                    ),
                  ],
                ),
                const SizedBox(width: AppSpacing.lg),
                // 歌曲信息
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        candidate.title,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: colors.textPrimary),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        candidate.artist,
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (candidate.album.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          candidate.album,
                          style: TextStyle(fontSize: 12, color: colors.textHint),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.lg),

          // 歌词预览区域
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: [
                Icon(Icons.lyrics_outlined, size: 16, color: colors.textSecondary),
                const SizedBox(width: AppSpacing.xs),
                Text(context.tr('歌词预览'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: colors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: colors.surfaceVariant.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                padding: const EdgeInsets.all(AppSpacing.md),
                child: _buildLyricPreview(colors),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),

          // 底部按钮
          Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.lg,
              right: AppSpacing.lg,
              bottom: widget.bottomPadding + AppSpacing.md,
            ),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(context, rootNavigator: true).pop(),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: colors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                        border: Border.all(color: colors.divider),
                      ),
                      child: Text(
                        context.tr('取消'),
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: colors.textPrimary),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  flex: 2,
                  child: GestureDetector(
                    onTap: _saving ? null : _handleConfirm,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: _saving ? colors.primary.withValues(alpha: 0.5) : colors.primary,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          if (_saving) ...[
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2, color: colors.textOnPrimary),
                            ),
                            const SizedBox(width: AppSpacing.xs),
                          ],
                          Text(
                            context.tr(_saving ? '保存中...' : '确认使用'),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: colors.textOnPrimary),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLyricPreview(ThemeColors colors) {
    if (_loadingLyric) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: colors.primary),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(context.tr('正在获取歌词...'), style: TextStyle(fontSize: 12, color: colors.textHint)),
          ],
        ),
      );
    }

    if (_lyricError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 24, color: colors.textHint),
            const SizedBox(height: AppSpacing.xs),
            Text(context.tr(_lyricError!), style: TextStyle(fontSize: 12, color: colors.textHint)),
          ],
        ),
      );
    }

    if (_lyric == null || _lyric!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined, size: 24, color: colors.textHint),
            const SizedBox(height: AppSpacing.xs),
            Text(context.tr('未找到歌词'), style: TextStyle(fontSize: 12, color: colors.textHint)),
          ],
        ),
      );
    }

    // 解析 LRC 格式歌词，提取纯文本行展示
    final lines = _lyric!
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .map((l) {
          // 去除 LRC 时间标签 [mm:ss.xx]
          return l.replaceAll(RegExp(r'\[\d{2}:\d{2}[\.:]?\d{0,2}\]'), '').trim();
        })
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) {
      return Center(
        child: Text(context.tr('未找到有效歌词'), style: TextStyle(fontSize: 12, color: colors.textHint)),
      );
    }

    return ListView.builder(
      itemCount: lines.length,
      itemBuilder: (context, index) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text(
            lines[index],
            style: TextStyle(fontSize: 13, color: colors.textPrimary, height: 1.6),
            textAlign: TextAlign.center,
          ),
        );
      },
    );
  }
}
