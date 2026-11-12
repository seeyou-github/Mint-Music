import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:file_picker/file_picker.dart';
import '../../../core/constants/app_routes.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../core/utils/scroll_locate.dart';
import '../../../shared/widgets/song_action_sheet.dart';
import '../../../shared/widgets/song_index_width.dart';
import '../../../shared/widgets/song_row_spacing.dart';
import '../../../shared/widgets/song_row_hover.dart';
import '../../../shared/widgets/song_favorite_heart.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/song_selection.dart';
import '../application/local_providers.dart';
import '../../blacklist/application/blacklist_providers.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/mini_player_visibility.dart';
import '../../library/domain/models/recently_played.dart';
import '../data/local_music_repository.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../library/application/playlist_providers.dart';

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

class _LocalPageState extends ConsumerState<LocalPage>
    with SingleTickerProviderStateMixin {
  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  /// 当前选中的扫描文件夹（null = 全部）。
  String? _selectedFolder;

  /// 批量选择控制器（长按歌曲进入多选模式）。
  final _selection = SongSelectionController();

  // ------------------------------------------------------------ 文件夹左右滑动
  //
  // 与发现页切换「歌单 / 榜单 / 电台」同一套：拖动时直接平移整块列表，
  // 只做一层 Transform（GPU 变换），不重建列表子树；切换后新文件夹从另一侧
  // 28% 屏宽处滑入。

  /// 手指位移达到这么多屏宽就算一次翻页（剩下的靠甩动速度判断）。
  static const double _kFolderSwitchDragRatio = 0.18;

  /// 文件夹列表当前的横向位移（像素）。
  final ValueNotifier<double> _folderOffsetX = ValueNotifier<double>(0);

  /// 拖动过程中显示在「下一屏」的文件夹。
  ///
  /// [_dragTargetFolderActive] 为 false 表示没有拖动，或者已经滑到第一个 /
  /// 最后一个文件夹（越界时只能回弹）。与 [_folderOffsetX] 配合：当前列表从
  /// 0 平移到 ±整屏时，另一个文件夹的列表从另一侧同步平移进来，滑动过程中
  /// 就能看到对面的内容（同 PageView）。
  bool _dragTargetFolderActive = false;
  String? _dragTargetFolder;
  int _dragDir = 0;

  /// 位移动画驱动（时长每次按需设置）。
  late final AnimationController _folderAnim = AnimationController(vsync: this);

  /// 当前正在跑的位移动画；为 null 表示没有动画在跑。
  Animation<double>? _folderTween;

  /// 本次拖动累计的横向位移。
  double _folderSwipeDx = 0;

  void _onFolderTick() {
    final animation = _folderTween;
    if (animation != null) _folderOffsetX.value = animation.value;
  }

  /// 把列表位移动画到 [to]（像素）。
  Future<void> _animateFolderOffset(double to, int milliseconds) {
    final from = _folderOffsetX.value;
    _folderAnim.stop();
    if (from == to) {
      _folderTween = null;
      return Future<void>.value();
    }
    _folderAnim.duration = Duration(milliseconds: milliseconds);
    _folderTween = Tween<double>(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: _folderAnim, curve: Curves.easeOutCubic));
    return _folderAnim.forward(from: 0).then((_) {
      _folderTween = null;
      _folderOffsetX.value = to;
    });
  }

  /// 手指位移 → 列表位移（1:1 跟手，最多一屏）。
  ///
  /// 必须与手指严格同步：下一屏是按「当前位移 ± 整屏宽」算位置的，这里一旦
  /// 做加速，两页之间就会露出缝或叠在一起。
  ///
  /// 文件夹是「全部 + 各扫描目录」的有限序列（不循环）：已经在第一个还往右
  /// 拖、或已经在最后一个还往左拖时直接不动，避免拖出一片空白。
  double _folderContentOffset(double dx) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return dx;
    final clamped = dx.clamp(-width, width).toDouble();
    final dir = clamped < 0 ? 1 : (clamped > 0 ? -1 : 0);
    if (dir != 0) {
      final folders = _folderOptions;
      final index = folders.indexOf(_selectedFolder);
      final target = index < 0 ? -1 : index + dir;
      if (target < 0 || target >= folders.length) return 0;
    }
    return clamped;
  }

  /// 「全部」+ 各扫描目录，滑动切换按这个顺序走。
  List<String?> get _folderOptions {
    final dirs =
        ref.read(scannedDirectoriesProvider).valueOrNull ?? const <String>[];
    return <String?>[null, ...dirs];
  }

  @override
  void initState() {
    super.initState();
    _folderAnim.addListener(_onFolderTick);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPermissionAndScan();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _selection.dispose();
    _folderAnim.dispose();
    _folderOffsetX.dispose();
    super.dispose();
  }

  Future<void> _checkPermissionAndScan() async {
    final repo = ref.read(localMusicRepositoryProvider);
    final hasPermission = await repo.checkPermission();
    if (!hasPermission && mounted) _showPermissionDialog();
  }

  /// 一个扫描目录都没设置时，打开「扫描目录设置」引导用户添加。
  ///
  /// 这是「仅扫描已设置的扫描目录」这条规则的兜底：不设目录 = 不扫描，
  /// 而不是退化成扫描设备全部音乐。
  Future<void> _promptAddScanDir(ThemeColors colors) async {
    final repo = ref.read(localMusicRepositoryProvider);
    await repo.init();
    if (!mounted || repo.getScannedDirectories().isNotEmpty) return;
    await _showDirModal(colors);
  }

  void _showPermissionDialog() {
    final colors = ref.read(themeColorsProvider);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: colors.dialogSurface,
        title: Text(
          context.tr('需要存储权限'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('为了扫描本地音乐，Music 需要访问您设备上的音频文件。请授予权限后继续。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final granted = await ref
                  .read(localMusicNotifierProvider.notifier)
                  .requestPermissionAndScan();
              if (!mounted) return;
              if (!granted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(context.tr('权限被拒绝，无法扫描本地音乐')),
                    duration: const Duration(seconds: 3),
                  ),
                );
                return;
              }
              // 授权后不会自动扫全盘：没配扫描目录就引导去添加。
              await _promptAddScanDir(colors);
            },
            child: Text(
              context.tr('授权'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
  }

  /// 当前展示的歌曲：按选中的文件夹过滤（「全部」时不过滤）。
  List<Song> _visibleSongs(List<Song> songs, [String? folder]) => folder == null
      ? songs
      : songs.where((s) => _isInFolder(s, folder)).toList();

  void _locateCurrentSong() {
    final playbackState = ref.read(playbackControllerProvider);
    final currentSong = playbackState.currentSong;
    if (currentSong == null) return;

    final songs = ref.read(filteredLocalSongsProvider);
    // 列表是按当前目录过滤后的结果，下标也必须按同一份列表算；
    // 用全库下标会在选中文件夹时滚到接近末尾的位置。
    final index = _visibleSongs(
      songs,
      _selectedFolder,
    ).indexWhere((s) => s.id == currentSong.id);
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
    final scannedDirs =
        ref.watch(scannedDirectoriesProvider).valueOrNull ?? const <String>[];

    // 选中的文件夹被移除后回到「全部」
    if (_selectedFolder != null && !scannedDirs.contains(_selectedFolder)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _folderOffsetX.value = 0;
        setState(() => _selectedFolder = null);
      });
    }

    // 按当前选中的文件夹过滤（顶部文件夹栏切换）。
    final songs = _visibleSongs(allSongs, _selectedFolder);

    // 当前播放歌曲：判断某个文件夹要不要显示「定位」按钮（见 [_buildSongsPage]）。
    final currentSong = ref.watch(
      playbackControllerProvider.select((s) => s.currentSong),
    );

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
            backgroundColor: Colors.transparent,
            body: SafeArea(
              bottom: false,
              child: Stack(
                children: [
                  Column(
                    children: [
                      _buildHeader(colors, scanProgress),
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
                        child: GestureDetector(
                          // Android：左右滑动切换文件夹（「全部」+ 各扫描目录）。
                          // 与发现页切换「歌单 / 榜单 / 电台」同一套动画。
                          // 纵向列表、横向的文件夹标签行是更深的手势识别器，
                          // 会自己赢下手势，不受影响。
                          behavior: HitTestBehavior.translucent,
                          onHorizontalDragStart:
                              Platform.isAndroid && !selecting
                              ? _onFolderSwipeStart
                              : null,
                          onHorizontalDragUpdate:
                              Platform.isAndroid && !selecting
                              ? _onFolderSwipeUpdate
                              : null,
                          onHorizontalDragEnd: Platform.isAndroid && !selecting
                              ? _onFolderSwipeEnd
                              : null,
                          child: ClipRect(
                            // 两个文件夹的列表一起平移：当前列表从 0 滑到
                            // ±整屏时，下一个文件夹从另一侧同步滑进来，
                            // 拖动过程中就能看到对面的内容（同 PageView）。
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                if (_dragTargetFolderActive && _dragDir != 0)
                                  AnimatedBuilder(
                                    animation: _folderOffsetX,
                                    builder: (context, child) =>
                                        Transform.translate(
                                          offset: Offset(
                                            _folderOffsetX.value +
                                                _dragDir *
                                                    MediaQuery.sizeOf(
                                                      context,
                                                    ).width,
                                            0,
                                          ),
                                          child: child,
                                        ),
                                    // 下一屏只是预览：用独立的滚动位置，
                                    // 两个 ListView 不能共用同一个 controller。
                                    child: _buildSongsPage(
                                      colors,
                                      songsAsync,
                                      allSongs,
                                      _dragTargetFolder,
                                      currentSong,
                                      primary: false,
                                    ),
                                  ),
                                AnimatedBuilder(
                                  animation: _folderOffsetX,
                                  builder: (context, child) =>
                                      Transform.translate(
                                        offset: Offset(_folderOffsetX.value, 0),
                                        child: child,
                                      ),
                                  child: _buildSongsPage(
                                    colors,
                                    songsAsync,
                                    allSongs,
                                    _selectedFolder,
                                    currentSong,
                                    primary: true,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (selecting)
                    Positioned(
                      left: 0,
                      right: 0,
                      // 操作栏紧贴底部：有歌在播时贴着迷你播放器顶部，
                      // 没歌（迷你播放器是空占位）或宽屏侧边栏布局时直接贴底。
                      bottom: ResponsiveLayout.batchBarBottomInset(
                        context,
                        // 播放栏没显示时（没歌在播，或当前页面隐藏了播放栏）操作栏直接贴底。
                        miniPlayerVisible: ref.watch(miniPlayerVisibleProvider),
                      ),
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

  /// 顶部：标题 + 搜索框 + 选择目录 / 扫描 / 快速匹配三个图标按钮。
  ///
  /// 平台区分（提交 8c8ec43 的「隐藏标题、搜索框占满」只保留在 Android）：
  /// - Android：底部导航已标明「本地」，不显示标题，搜索框靠左铺满整行；
  /// - Windows / 桌面：还原旧版——保留「本地音乐」标题，搜索框靠右、
  ///   最大宽度 300（平板 420），不横跨整个窗口。
  Widget _buildHeader(ThemeColors colors, ScanProgress scanProgress) {
    final isTablet = ResponsiveLayout.isTablet(context);
    final compactHeader = Platform.isAndroid;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: ResponsiveLayout.horizontalPadding(context),
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          if (!compactHeader) ...[
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
          ],
          // Android 不显示标题，腾出来的空间全部给搜索框。
          Expanded(
            child: Align(
              alignment: compactHeader
                  ? Alignment.centerLeft
                  : Alignment.centerRight,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: 140,
                  // 手机铺满整行；桌面 / 平板收一点，避免搜索框横跨整个窗口。
                  maxWidth: isTablet
                      ? 420
                      : (compactHeader ? double.infinity : 300),
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
          // 快速匹配：按字段筛选整库，再逐个在线匹配信息 / 封面 / 歌词。
          _buildHeaderIconButton(
            colors,
            Icons.auto_fix_high,
            context.tr('快速匹配本地歌曲'),
            () => context.push(AppRoutes.quickMatch),
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
          decoration: floatingButtonDecoration(colors, radius: AppRadius.md),
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
    final dirs =
        ref.watch(scannedDirectoriesProvider).valueOrNull ?? const <String>[];
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
                        folder: null,
                        isSelected: _selectedFolder == null,
                        onTap: () => _selectFolder(null),
                      );
                    }
                    final dir = dirs[index - 1];
                    return _buildFolderChip(
                      colors,
                      _folderName(dir),
                      folder: dir,
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
                // 用第二字体颜色：textHint 在浅色主题下太淡。
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
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
    required String? folder,
  }) {
    return GestureDetector(
      // 滑动切换后要靠它把标签栏滚到选中项（见 [_revealFolderChip]）。
      key: GlobalObjectKey(_folderKey(folder)),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: isSelected
            // 选中态与侧栏「发现」一致：底色把主题色调暗一档，文字用主题色。
            ? activeChipDecoration(
                colors,
                radius: AppRadius.full,
                withBorder: true,
              )
            : BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(color: colors.divider),
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
              color: isSelected ? colors.primary : colors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  /// 切换选中的文件夹（null = 全部）。
  ///
  /// 点击文件夹标签时 [animate] 为 true：新文件夹从切换方向的另一侧 28% 屏宽
  /// 处滑入；左右滑动切换时传 false —— 两页已经跟着手指一起平移到位了。
  void _selectFolder(String? dir, {bool animate = true}) {
    if (_selectedFolder == dir) return;
    final folders = _folderOptions;
    final from = folders.indexOf(_selectedFolder);
    final to = folders.indexOf(dir);
    if (animate && Platform.isAndroid && from >= 0 && to >= 0 && from != to) {
      final width = MediaQuery.sizeOf(context).width;
      // 向后（索引变大）→ 从右侧进场；向前 → 从左侧。
      _folderOffsetX.value = to > from ? width * 0.28 : -width * 0.28;
      unawaited(_animateFolderOffset(0, 200));
    }
    // 新文件夹的列表从头开始，不要把上一个文件夹的滚动位置带过去。
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    setState(() {
      _selectedFolder = dir;
      // 切换完成后收掉「下一屏」的预览。
      _dragTargetFolderActive = false;
      _dragTargetFolder = null;
      _dragDir = 0;
    });
    _revealFolderChip(dir);
  }

  /// 文件夹标签用的稳定 key。
  ///
  /// 「全部」用一个独立对象，避免和真实目录名（理论上可能叫 `__all__`）
  /// 撞成同一个 key。
  static final Object _allFolderChipKey = Object();

  Object _folderKey(String? folder) => folder ?? _allFolderChipKey;

  /// 把文件夹标签栏滚到选中项。
  ///
  /// 左右滑动切换时，选中的可能是屏幕外的标签，不滚过去用户就看不到
  /// 「现在在哪个文件夹」。
  void _revealFolderChip(String? folder) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final chipContext = GlobalObjectKey(_folderKey(folder)).currentContext;
      if (chipContext == null) return;
      unawaited(
        Scrollable.ensureVisible(
          chipContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutCubic,
        ),
      );
    });
  }

  void _onFolderSwipeStart(DragStartDetails details) {
    _folderAnim.stop();
    _folderTween = null;
    _folderSwipeDx = 0;
    _folderOffsetX.value = 0;
    if (_dragTargetFolderActive || _dragDir != 0) {
      setState(() {
        _dragTargetFolderActive = false;
        _dragTargetFolder = null;
        _dragDir = 0;
      });
    }
  }

  void _onFolderSwipeUpdate(DragUpdateDetails details) {
    _folderSwipeDx += details.delta.dx;
    final offset = _folderContentOffset(_folderSwipeDx);
    _folderOffsetX.value = offset;
    _syncFolderDragTarget(offset);
  }

  /// 根据当前位移确定「下一屏」是哪个文件夹（到头 / 到第一个就没有下一屏）。
  ///
  /// 只在方向或目标变化时 `setState` 一次，拖动过程中不反复重建列表。
  void _syncFolderDragTarget(double offset) {
    final dir = offset < 0 ? 1 : (offset > 0 ? -1 : 0);
    final folders = _folderOptions;
    final index = folders.indexOf(_selectedFolder);
    var active = false;
    String? folder;
    if (dir != 0 && index >= 0) {
      final target = index + dir;
      if (target >= 0 && target < folders.length) {
        active = true;
        folder = folders[target];
      }
    }
    if (active == _dragTargetFolderActive &&
        folder == _dragTargetFolder &&
        dir == _dragDir) {
      return;
    }
    setState(() {
      _dragTargetFolderActive = active;
      _dragTargetFolder = folder;
      _dragDir = dir;
    });
  }

  /// 左右滑动结束：位移够就翻页，不够看甩动速度；都不够就弹回原位。
  void _onFolderSwipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final dx = _folderSwipeDx;
    _folderSwipeDx = 0;
    final width = MediaQuery.sizeOf(context).width;
    final bool swipeLeft;
    if (dx.abs() >= width * _kFolderSwitchDragRatio) {
      swipeLeft = dx < 0;
    } else if (velocity.abs() >= 260) {
      swipeLeft = velocity < 0;
    } else {
      unawaited(_settleFolderDrag(-1, 0));
      return;
    }
    final folders = _folderOptions;
    final index = folders.indexOf(_selectedFolder);
    final next = index < 0 ? -1 : index + (swipeLeft ? 1 : -1);
    if (next < 0 || next >= folders.length) {
      // 已经是第一个 / 最后一个文件夹：没有可切换的，弹回原位。
      unawaited(_settleFolderDrag(-1, 0));
      return;
    }
    unawaited(_settleFolderDrag(next, swipeLeft ? 1 : -1));
  }

  /// 收尾：两页一起滑到位后切换文件夹，或者回弹。
  ///
  /// [target] 是目标文件夹在 [_folderOptions] 里的下标，传 -1 表示没有可切换的
  /// 目标（已经在第一个 / 最后一个）。不能用 null 表示「没有目标」——「全部」
  /// 这个文件夹本身就是 null，否则从最后一个文件夹滑回「全部」会被当成回弹，
  /// 永远切不过去。
  ///
  /// 切换用 `animate: false` —— 位移已经自己走完，再让 [_selectFolder] 做一次
  /// 「从侧边 28% 进场」会闪。
  Future<void> _settleFolderDrag(int target, int dir) async {
    final width = MediaQuery.sizeOf(context).width;
    final folders = _folderOptions;
    if (target >= 0 && target < folders.length) {
      final next = folders[target];
      await _animateFolderOffset(dir > 0 ? -width : width, 220);
      if (!mounted) return;
      _selectFolder(next, animate: false);
      _folderOffsetX.value = 0;
      return;
    }
    await _animateFolderOffset(0, 200);
    if (!mounted) return;
    if (_dragTargetFolderActive || _dragDir != 0) {
      setState(() {
        _dragTargetFolderActive = false;
        _dragTargetFolder = null;
        _dragDir = 0;
      });
    }
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
      // 与顶栏按钮统一：底色 + 轻阴影，不画描边。
      decoration: floatingButtonDecoration(colors),
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
              decoration: const InputDecoration(
                border: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.zero,
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

  /// 构建某个文件夹的歌曲页（列表 / 空态 / 加载 / 错误）。
  ///
  /// [primary] 为当前选中的文件夹：它独占 [_scrollController]、显示「定位当前
  /// 播放歌曲」按钮，并跟随多选状态；拖动过程中露出的下一屏只是预览，用独立的
  /// 滚动状态（两个 ListView 不能共用同一个 ScrollController）。
  Widget _buildSongsPage(
    ThemeColors colors,
    AsyncValue<List<Song>> songsAsync,
    List<Song> allSongs,
    String? folder,
    Song? currentSong, {
    required bool primary,
  }) {
    final songs = _visibleSongs(allSongs, folder);
    // 搜索没命中时不能把空结果说成「当前目录为空」：目录里可能还有歌。
    final searching = ref.watch(localSearchQueryProvider).trim().isNotEmpty;
    // 定位按钮只在当前页显示：下一屏还没切过去，点了也没有可滚动的位置。
    final showLocateBtn =
        primary &&
        !_selection.isActive &&
        currentSong != null &&
        currentSong.source == 'local' &&
        songs.any((s) => s.id == currentSong.id);
    return songsAsync.when(
      data: (_) => _buildSongList(
        colors,
        songs,
        showLocateBtn,
        folder: searching ? null : folder,
        controller: primary ? _scrollController : null,
      ),
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => _buildErrorState(colors, e.toString()),
    );
  }

  Widget _buildSongList(
    ThemeColors colors,
    List<Song> songs,
    bool showLocateBtn, {
    required String? folder,
    ScrollController? controller,
  }) {
    if (songs.isEmpty) {
      return _buildEmptyState(colors, folder: folder);
    }

    final selecting = _selection.isActive;
    // 多选时批量操作栏紧贴迷你播放器，列表底部要一并让开。
    final batchBarInset = ResponsiveLayout.batchBarBottomInset(
      context,
      miniPlayerVisible: ref.watch(miniPlayerVisibleProvider),
    );
    return Stack(
      children: [
        ListView.separated(
          // 当前页显式传 [_scrollController]（定位 / 切文件夹要用），
          // 拖动中露出的下一屏传 null，让它用自己的滚动状态。
          controller: controller,
          primary: controller == null ? false : null,
          padding: EdgeInsets.only(
            // 左右各 8（原来是 16）：配合行内 4px 内边距，序号左边距、
            // 「更多」按钮到屏幕边缘的距离都缩到原来的一半。
            // Windows 上改由行内统一给 [wideSongRowPadding]，外层不再叠加，
            // 这样本地列表与歌单详情页等共享列表的边距完全一致。
            left: useWideSongRowSpacing ? 0 : AppSpacing.sm,
            right: useWideSongRowSpacing ? 0 : AppSpacing.sm,
            // 底部多留出空间，避免最后一项被悬浮的迷你播放器遮挡；
            // 多选模式下还要再避开底部批量操作栏。
            bottom:
                AppSpacing.xxxl +
                AppSpacing.huge +
                (selecting ? SongBatchActionBar.height + batchBarInset : 0),
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
              maxIndex: songs.length,
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

  /// 空状态。
  ///
  /// 选中了某个扫描目录时只是这个目录里没歌（歌曲可能还在别的目录），
  /// 不该再提示「暂无本地音乐」和扫描按钮，只说明当前目录为空。
  ///
  /// 一个扫描目录都没添加时同样不提示「暂无本地音乐」（还没扫过，说不上「暂无」）：
  /// 只留引导文案，按钮改成「选择目录」直接去加目录。
  Widget _buildEmptyState(ThemeColors colors, {String? folder}) {
    final inFolder = folder != null;
    final noDirectory =
        !inFolder &&
        (ref.watch(scannedDirectoriesProvider).valueOrNull ?? const <String>[])
            .isEmpty;
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
            child: Icon(
              inFolder ? Icons.folder_open_outlined : Icons.library_music,
              size: 40,
              color: colors.primary.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          if (!noDirectory)
            Text(
              context.tr(inFolder ? '当前目录为空' : '暂无本地音乐'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
              ),
            ),
          if (!inFolder) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              context.tr('先添加扫描目录，再扫描其中的音乐'),
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
            GestureDetector(
              // 没有目录时扫描没有任何意义，直接引导去选目录（选完关闭
              // 目录弹框会自动扫一次，见 _showDirModal）。
              onTap: noDirectory
                  ? () => _showDirModal(colors)
                  : _scanLibrary,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 10,
                ),
                // 与侧栏「发现」的激活态一致：主题色调暗做底、文字用主题色。
                decoration: activeChipDecoration(
                  colors,
                  radius: AppRadius.full,
                  withBorder: true,
                ),
                child: Text(
                  context.tr(noDirectory ? '选择目录' : '扫描本地音乐'),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
          ],
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
            onPressed: () =>
                ref.read(localMusicNotifierProvider.notifier).refresh(),
            child: Text(
              context.tr('重试'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
  }

  void _playSong(Song song) {
    // 播放队列与列表保持一致：选中某个文件夹时只用该文件夹里的歌，
    // 不要混进「全部」分类里的其它歌曲。
    final songs = _visibleSongs(
      ref.read(filteredLocalSongsProvider),
      _selectedFolder,
    );
    final index = songs.indexWhere((s) => s.id == song.id);
    final controller = ref.read(playbackControllerProvider.notifier);
    PlaybackContext.instance.set(PlaybackSourceType.local);
    controller.setQueue(songs, startIndex: index >= 0 ? index : 0);
  }

  Future<void> _scanLibrary() async {
    // 没设置扫描目录就直接打开目录设置：这种情况下扫描没有任何意义，
    // 也不允许退化成「扫描整机音乐」。
    final repo = ref.read(localMusicRepositoryProvider);
    await repo.init();
    if (!mounted) return;
    if (repo.getScannedDirectories().isEmpty) {
      await _showDirModal(ref.read(themeColorsProvider));
      return;
    }
    final granted = await ref
        .read(localMusicNotifierProvider.notifier)
        .requestPermissionAndScan();
    // 扫描成功不弹任何提示，只有权限被拒绝时才说明原因。
    if (!mounted || granted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('权限被拒绝，无法扫描本地音乐')),
        duration: const Duration(seconds: 2),
      ),
    );
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
  }

  Future<void> _confirmDeleteSelected(List<Song> songs) async {
    final selected = _selectedSongs(songs);
    if (selected.isEmpty) return;
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      useRootNavigator: true,
      builder: (context) => AlertDialog(
        backgroundColor: colors.dialogSurface,
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
        backgroundColor: colors.dialogSurface,
        title: Text(
          context.tr('删除歌曲'),
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定要删除「${song.title}」吗？\n此操作将从本地音乐库移除该歌曲。'),
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

    final ok = await ref
        .read(localMusicNotifierProvider.notifier)
        .deleteSong(song);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok ? context.tr('已删除「${song.title}」') : context.tr('删除失败'),
        ),
        duration: const Duration(seconds: 2),
        backgroundColor: ok ? null : Colors.red,
      ),
    );
  }

  Widget _contextMenuItem(
    ThemeColors colors,
    IconData icon,
    String label,
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

  void _showAddToPlaylistSheet(
    ThemeColors colors,
    Song song,
    AsyncValue playlistsAsync,
  ) {
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
                color: colors.dialogSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
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
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        if (playlists.isEmpty)
                          Padding(
                            padding: const EdgeInsets.all(AppSpacing.xl),
                            child: Text(
                              context.tr('暂无歌单'),
                              style: TextStyle(color: colors.textHint),
                            ),
                          )
                        else
                          ...playlists.map<Widget>(
                            (playlist) => ListTile(
                              leading: Icon(
                                Icons.queue_music,
                                color: colors.textSecondary,
                              ),
                              title: Text(
                                playlist.name,
                                style: TextStyle(color: colors.textPrimary),
                              ),
                              trailing: Text(
                                context.tr('${playlist.songCount}首'),
                                style: TextStyle(
                                  fontSize: 12,
                                  color: colors.textHint,
                                ),
                              ),
                              onTap: () {
                                Navigator.pop(context);
                                ref
                                    .read(playlistsProvider.notifier)
                                    .addSongToPlaylist(playlist.id, song);
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(
                                      context.tr('已添加到"${playlist.name}"'),
                                    ),
                                    duration: const Duration(seconds: 2),
                                  ),
                                );
                              },
                            ),
                          ),
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
        SnackBar(
          content: Text(context.tr('加载歌单中...')),
          duration: const Duration(seconds: 1),
        ),
      ),
      error: (_, __) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('加载歌单失败')),
          duration: const Duration(seconds: 2),
        ),
      ),
    );
  }

  Future<void> _showDirModal(ThemeColors colors) async {
    // 从持久化加载真实目录（FutureProvider 首次 init 后走缓存）。
    final dirs = List<String>.from(
      await ref.read(scannedDirectoriesProvider.future),
    );
    if (!mounted) return;
    final initialDirs = List<String>.from(dirs);
    // 「确认」按钮自己会扫，弹窗关闭回调里不要重复扫一次。
    var confirmed = false;

    // 关闭弹窗时按「目录集合」判断有没有变化：增删目录会改变歌曲索引，
    // 只重排顺序不改变集合（见 reorderDirectories），不必重跑全盘扫描。
    bool directoriesChanged() {
      if (dirs.length != initialDirs.length) return true;
      for (final d in dirs) {
        if (!initialDirs.contains(d)) return true;
      }
      return false;
    }

    final bottomPadding = MediaQuery.of(context).padding.bottom;

    final sheet = showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              decoration: BoxDecoration(
                color: colors.dialogSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(16),
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  // 只留安全区 / 键盘高度。原来这里额外加了 72，底部那排
                  // 按钮就会浮在弹窗边缘上方一截，看着像没贴底。
                  padding: EdgeInsets.only(
                    bottom:
                        MediaQuery.of(context).viewInsets.bottom + bottomPadding,
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
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        context.tr(
                          dirs.isEmpty ? '未设置扫描目录时不会扫描任何音乐' : '仅扫描下面这些目录里的音乐',
                        ),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      if (dirs.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(AppSpacing.lg),
                          child: Column(
                            children: [
                              Icon(
                                Icons.folder_off_outlined,
                                size: 32,
                                color: colors.primary.withValues(alpha: 0.5),
                              ),
                              const SizedBox(height: AppSpacing.sm),
                              Text(
                                context.tr('当前：未设置扫描目录，请添加'),
                                style: TextStyle(
                                  color: colors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        )
                      else
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxHeight:
                                MediaQuery.of(context).size.height * 0.45,
                          ),
                          child: ReorderableListView.builder(
                            shrinkWrap: true,
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.lg,
                            ),
                            buildDefaultDragHandles: false,
                            itemCount: dirs.length,
                            onReorder: (oldIndex, newIndex) {
                              if (newIndex > oldIndex) newIndex -= 1;
                              final item = dirs.removeAt(oldIndex);
                              dirs.insert(newIndex, item);
                              setModalState(() {});
                              // 顺序即扫描顺序，拖完立即持久化，避免不点确认
                              // 直接关闭弹窗后丢失；只重排不算歌曲索引，
                              // 目录栏能马上按新顺序刷新。
                              unawaited(
                                ref
                                    .read(localMusicNotifierProvider.notifier)
                                    .reorderDirectories(dirs),
                              );
                            },
                            itemBuilder: (context, index) {
                              final d = dirs[index];
                              return Padding(
                                key: ValueKey(d),
                                padding: const EdgeInsets.symmetric(
                                  vertical: AppSpacing.xs,
                                ),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.sm,
                                    vertical: AppSpacing.sm,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colors.surfaceVariant,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.md,
                                    ),
                                  ),
                                  child: Row(
                                    children: [
                                      ReorderableDragStartListener(
                                        index: index,
                                        child: Padding(
                                          padding: const EdgeInsets.all(
                                            AppSpacing.xs,
                                          ),
                                          child: Icon(
                                            Icons.drag_handle,
                                            size: 18,
                                            color: colors.textHint,
                                          ),
                                        ),
                                      ),
                                      Icon(
                                        Icons.folder,
                                        size: 18,
                                        color: colors.textSecondary,
                                      ),
                                      const SizedBox(width: AppSpacing.sm),
                                      Expanded(
                                        child: Text(
                                          d,
                                          style: TextStyle(
                                            fontSize: 13,
                                            color: colors.textPrimary,
                                          ),
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
                                                .read(
                                                  localMusicNotifierProvider
                                                      .notifier,
                                                )
                                                .setDirectories(dirs),
                                          );
                                        },
                                        child: Padding(
                                          padding: const EdgeInsets.all(
                                            AppSpacing.xs,
                                          ),
                                          child: Icon(
                                            Icons.close,
                                            size: 16,
                                            color: colors.textHint,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      const SizedBox(height: AppSpacing.lg),
                      // 底部一行两个按钮：左边添加文件夹，右边确认。
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.lg,
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: GestureDetector(
                                onTap: () async {
                                  final result = await _pickDirectory();
                                  if (result != null &&
                                      !dirs.contains(result)) {
                                    dirs.add(result);
                                    setModalState(() {});
                                    unawaited(
                                      ref
                                          .read(
                                            localMusicNotifierProvider.notifier,
                                          )
                                          .setDirectories(dirs),
                                    );
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  decoration: BoxDecoration(
                                    color: colors.surfaceVariant,
                                    borderRadius: BorderRadius.circular(
                                      AppRadius.full,
                                    ),
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
                            const SizedBox(width: AppSpacing.md),
                            Expanded(
                              child: GestureDetector(
                                onTap: () async {
                                  // 一个目录都没有时不会开始扫描（见 scanAll
                                  // 的注释），弹窗留着让用户继续添加。
                                  if (dirs.isEmpty) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          context.tr(
                                            '未设置扫描目录时不会扫描任何音乐',
                                          ),
                                        ),
                                        duration: const Duration(seconds: 2),
                                      ),
                                    );
                                    return;
                                  }
                                  // 「确认」自己会扫，弹窗关闭回调里别再扫一次。
                                  confirmed = true;
                                  final notifier = ref.read(
                                    localMusicNotifierProvider.notifier,
                                  );
                                  // 先把弹窗收掉再扫：几千首歌的扫描可能要跑
                                  // 很久，弹窗盖着会挡住顶部的扫描进度。
                                  Navigator.pop(context);
                                  await notifier.setDirectories(dirs);
                                  await notifier.scanAll();
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  // 主题色底 + 主题色描边 + 主题色文字，
                                  // 与侧栏「发现」的激活态一致。
                                  decoration: activeChipDecoration(
                                    colors,
                                    radius: AppRadius.full,
                                    withBorder: true,
                                  ),
                                  child: Text(
                                    context.tr('确认'),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                      color: colors.primary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
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
    // 不论用哪种方式关掉弹窗（下滑 / 点遮罩 / 返回键），只要目录集合变了
    // 就补一次扫描，避免用户不点「确认」直接关掉后列表还是旧的。
    unawaited(
      sheet.whenComplete(() async {
        if (!mounted || confirmed) return;
        if (!directoriesChanged()) return;
        final notifier = ref.read(localMusicNotifierProvider.notifier);
        // 弹窗里增删目录的持久化是 unawaited 的，这里再存一次，保证扫描
        // 读到的一定是最新目录。
        await notifier.setDirectories(dirs);
        await notifier.scanAll();
      }),
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
    required this.maxIndex,
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

  /// 列表里的最大序号：序号列宽度按它的位数自适应。
  final int maxIndex;
  final void Function(Song song) onPlay;
  final void Function(ThemeColors colors, Song song) onContextMenu;
  final bool selectionMode;
  final bool selected;
  final void Function(Song song)? onSelectionToggle;

  /// 长按回调：进入批量选择模式（菜单改由右侧 more_vert 按钮触发）。
  final VoidCallback? onLongPress;

  /// 序号列宽度：按最大序号位数自适应；多选模式至少要放得下勾选框。
  ///
  /// Windows 上再给序号左右各加 [wideSongIndexInset]，与共享列表一致；
  /// 多选模式显示勾选框，不加这段宽度以免挤压它。
  double _indexWidth(BuildContext context) {
    var width = songIndexWidth(context, maxIndex: maxIndex, fontSize: 13);
    if (useWideSongRowSpacing && !selectionMode) width += wideSongIndexExtra;
    const checkboxWidth = 34.0;
    return selectionMode && width < checkboxWidth ? checkboxWidth : width;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = ref.watch(themeColorsProvider);
    final playingId = ref.watch(
      playbackControllerProvider.select((s) => s.currentSong?.id),
    );
    final isPlaying = playingId == song.id;
    final blocked = ref.watch(blacklistProvider).isBlocked(song);

    // 与歌单详情页 SongListItem 的 InkWell 用同一个 hover 颜色
    // （深色主题白 4% / 浅色主题黑 4%）；本地列表没有 InkWell，由
    // SongRowHover 补上这层悬浮反馈。
    final hoverColor = Theme.of(context).hoverColor;
    return SongRowHover(hoverColor: hoverColor, child: SizedBox(
      // 固定行高，保证 itemExtent 与实际布局一致
      height: itemExtent,
      child: GestureDetector(
        onTap: selectionMode
            ? () => onSelectionToggle?.call(song)
            : blocked
            ? () => _showBlockedHint(context)
            : () => onPlay(song),
        onLongPress: selectionMode ? null : onLongPress,
        child: Container(
          // 左右内边距减半（8 → 4），上下保持 8：行高 64 = 封面 48 + 上下各 8，
          // 竖向一旦改动，`itemExtent` 定位就会偏。
          // Windows 上改用与共享列表统一的 [wideSongRowPadding]（外层不再叠加
          // 8dp），序号左边距与「更多」按钮右边距相等。
          padding: EdgeInsets.symmetric(
            horizontal: useWideSongRowSpacing
                ? wideSongRowPadding
                : AppSpacing.xs,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected
                ? colors.primary.withValues(alpha: 0.10)
                : (isPlaying
                      ? colors.primary.withValues(alpha: 0.08)
                      : Colors.transparent),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            children: [
              // 序号 / 勾选框
              SizedBox(
                // 宽度按整库最大序号的位数自适应（两位数只有十几像素），
                // 多选模式下至少留出勾选框的位置。
                width: _indexWidth(context),
                child: selectionMode
                    ? IgnorePointer(
                        // 只做展示：整行点击由外层 GestureDetector 处理
                        child: Checkbox(
                          value: selected,
                          onChanged: (_) {},
                          activeColor: colors.primary,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                        ),
                      )
                    : Padding(
                        // Windows 上序号左右各留 12dp：序号列变宽、序号不贴
                        // 屏幕边缘也不贴封面，与共享列表一致。
                        padding: EdgeInsets.symmetric(
                          horizontal: useWideSongRowSpacing
                              ? wideSongIndexInset
                              : 0,
                        ),
                        child: isPlaying
                            ? Icon(
                                Icons.play_arrow,
                                size: 18,
                                color: colors.primary,
                              )
                            : Text(
                                '${index + 1}',
                                // 序号贴着列表左边，不再居中留一大块空白。
                                textAlign: TextAlign.left,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  fontSize: 13,
                                  // 序号用「第二字体颜色」：浅色主题下 textHint 太淡。
                                  color: colors.textSecondary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                      ),
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
                          filePath: song.filePath,
                          // 桌面端没有 MediaStore，封面来自扫描时写入的封面缓存
                          mediaStoreId: song.mediaStoreId,
                          fit: BoxFit.cover,
                          width: 48,
                          height: 48,
                          errorWidget: Icon(
                            isPlaying ? Icons.equalizer : Icons.music_note,
                            size: 22,
                            color: isPlaying ? colors.primary : colors.textHint,
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
                        // 与在线歌曲一致：黑名单里的歌名变灰，表示放不了。
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
                        Expanded(
                          child: Text(
                            song.artist,
                            style: TextStyle(
                              fontSize: 12,
                              color: colors.textSecondary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // 收藏红心：放在时长左侧，与其它歌曲列表一致；悬停时出现空心，
              // 点一下直接收藏，已收藏则实心。
              if (!selectionMode) SongFavoriteHeart(song: song),
              if (song.duration > 0)
                Text(
                  song.displayDuration,
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              // 多选模式下隐藏「更多」按钮，避免与选择手势冲突
              if (!selectionMode) ...[
                const SizedBox(width: AppSpacing.xs),
                GestureDetector(
                  onTap: () => onContextMenu(colors, song),
                  child: Padding(
                    // 右侧只留 2（原来 4），配合行内 4px：⋮ 到屏幕边缘
                    // 由 28 收到 14。Windows 上放宽到 4，让按钮内侧留白
                    // ≈12dp，与共享列表的「更多」按钮一致，左右边距相等。
                    padding: EdgeInsets.only(
                      left: AppSpacing.xs,
                      right: useWideSongRowSpacing ? AppSpacing.xs : 2,
                      top: AppSpacing.xs,
                      bottom: AppSpacing.xs,
                    ),
                    child: Icon(
                      Icons.more_vert,
                      size: 18,
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ));
  }

  /// 黑名单标签（与在线歌曲列表同款，显示在歌手名左侧）。
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
}
