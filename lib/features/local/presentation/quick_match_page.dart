import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/services/lyric_cache.dart';
import '../application/local_providers.dart';
import '../domain/local_song_filter.dart';

/// 「快速匹配本地歌曲」页面。
///
/// 顶部是扫描目录下拉（默认第一个目录），下面是字段「有 / 无」筛选栏，
/// 再下面是歌曲列表：封面、歌名、歌手、专辑、年份、流派、注释、歌词状态，
/// 每行右侧有「编辑标签」与「匹配」两个图标按钮。
class QuickMatchPage extends ConsumerStatefulWidget {
  const QuickMatchPage({super.key});

  @override
  ConsumerState<QuickMatchPage> createState() => _QuickMatchPageState();
}

class _QuickMatchPageState extends ConsumerState<QuickMatchPage> {
  /// 当前目录；空串表示「全部目录」。
  String _dir = '';

  /// 是否已经按「第一个目录」初始化过（目录列表是异步来的）。
  bool _dirInitialized = false;

  final Map<LocalSongField, FieldFilter> _filters = {
    for (final field in LocalSongField.values) field: FieldFilter.any,
  };

  /// 歌曲 id → 歌词状态（内嵌歌词 + 歌词缓存）。
  Map<String, LyricPresence> _lyricStatus = const {};
  bool _loadingStatus = true;

  /// 已经算过歌词状态的歌曲 id 集合，避免列表刷新时重复计算。
  final Set<String> _statusLoadedIds = <String>{};

  /// 正在批量算歌词状态（防止 build 里重复排队）。
  bool _statusRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initDir());
  }

  void _initDir() {
    final dirs =
        ref.read(scannedDirectoriesProvider).valueOrNull ?? const <String>[];
    if (!mounted) return;
    setState(() {
      _dir = dirs.isEmpty ? '' : dirs.first;
      _dirInitialized = true;
    });
  }

  // ------------------------------------------------------------ 歌词状态

  /// 批量算一遍歌词状态：内嵌歌词（扫描时记下的标记）+ 歌词缓存。
  Future<void> _loadLyricStatus(List<Song> songs) async {
    if (!mounted || _statusRunning || songs.isEmpty) return;
    _statusRunning = true;
    setState(() => _loadingStatus = true);
    final entries = await LyricCache.readMany(songs);
    if (!mounted) {
      _statusRunning = false;
      return;
    }
    final status = <String, LyricPresence>{};
    for (final song in songs) {
      final entry = entries[LyricCache.keyFor(song)];
      final cachedLrc = <String?>[
        entry?.lrc,
        entry?.crlyric,
        entry?.ttml,
      ].any((text) => (text ?? '').trim().isNotEmpty);
      final cachedWord = <String?>[
        entry?.crlyric,
        entry?.ttml,
      ].any((text) => (text ?? '').trim().isNotEmpty);
      final ownLrc = song.lrc?.trim() ?? '';
      final hasLyric = song.hasLyric || cachedLrc || ownLrc.isNotEmpty;
      final hasWord =
          song.hasWordLyric || cachedWord || isWordLyricText(ownLrc);
      status[song.id] = LyricPresence(
        hasLyric: hasLyric,
        hasWordLyric: hasWord,
      );
      _statusLoadedIds.add(song.id);
    }
    setState(() {
      _lyricStatus = status;
      _loadingStatus = false;
    });
    _statusRunning = false;
  }

  /// 从匹配页回来：重新算这些歌的歌词状态（可能被写入了歌词）。
  Future<void> _refreshAfterMatch(List<Song> songs) async {
    _statusLoadedIds.clear();
    await _loadLyricStatus(songs);
  }

  /// 打开「编辑标签 - 在线搜索」并自动搜索一次。
  ///
  /// 匹配界面已经并入编辑标签页，这里不再单独开一个匹配页。
  Future<void> _openMatch(Song song, List<Song> all) async {
    await context.push('${AppRoutes.tagEditor}?songId=${song.id}&autoSearch=1');
    if (!mounted) return;
    await _refreshAfterMatch(all);
  }

  /// 目录为空时引导用户添加一个扫描目录。
  Future<void> _addDirectory() async {
    final result = await FilePicker.platform.getDirectoryPath(
      dialogTitle: context.tr('选择音乐目录'),
    );
    if (result == null || result.isEmpty) return;
    final dirs = [
      ...(ref.read(scannedDirectoriesProvider).valueOrNull ?? const <String>[]),
    ];
    if (!dirs.contains(result)) {
      dirs.add(result);
      await ref.read(localMusicNotifierProvider.notifier).setDirectories(dirs);
      await ref.read(localMusicNotifierProvider.notifier).scanAll();
    }
    if (!mounted) return;
    setState(() {
      _dir = result;
      _dirInitialized = true;
    });
  }

  // ------------------------------------------------------------ 过滤

  /// 当前是否有任何筛选条件（用于显示「清空筛选」）。
  bool get _hasActiveFilter =>
      _filters.values.any((state) => state != FieldFilter.any);

  /// 按目录 + 字段筛选（纯逻辑在 domain/local_song_filter.dart）。
  List<Song> _filtered(List<Song> songs) {
    final result = filterLocalSongs(
      songs,
      directory: _dir,
      filters: _filters,
      lyricStatus: _lyricStatus,
    );
    result.sort(compareSongByArtistFirstChar);
    return result;
  }

  void _cycleFilter(LocalSongField field) {
    setState(() {
      _filters[field] = nextFieldFilter(_filters[field] ?? FieldFilter.any);
    });
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final songsAsync = ref.watch(localMusicNotifierProvider);
    final dirs =
        ref.watch(scannedDirectoriesProvider).valueOrNull ?? const <String>[];
    if (!_dirInitialized && dirs.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _initDir());
    }

    final allSongs = songsAsync.valueOrNull ?? const <Song>[];
    // 首次进入（以及新扫描出来的歌）算一次歌词状态。
    final needStatus =
        allSongs.isNotEmpty &&
        allSongs.any((song) => !_statusLoadedIds.contains(song.id));
    if (needStatus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadLyricStatus(allSongs));
      });
    }
    final songs = _filtered(allSongs);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(colors, dirs, songs.length, allSongs.length),
            _buildFilterBar(colors),
            const SizedBox(height: AppSpacing.xs),
            _buildListHeader(colors),
            Expanded(
              child: songsAsync.when(
                data: (_) => _loadingStatus && songs.isEmpty
                    ? const Center(child: CircularProgressIndicator())
                    : songs.isEmpty
                    ? _buildEmpty(colors, dirs, allSongs)
                    : _buildSongList(colors, songs, allSongs),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(
                  child: Text('$e', style: TextStyle(color: colors.textHint)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(
    ThemeColors colors,
    List<String> dirs,
    int shown,
    int total,
  ) {
    final current = dirs.contains(_dir)
        ? _dir
        : (dirs.isEmpty ? '' : dirs.first);
    final label = current.isEmpty ? context.tr('全部目录') : _dirName(current);
    return Padding(
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
              context.tr('快速匹配本地歌曲'),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          // 目录下拉：默认第一个目录，可切到别的目录 / 全部目录。
          PopupMenuButton<String>(
            enabled: dirs.isNotEmpty,
            tooltip: context.tr('选择目录'),
            color: colors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            onSelected: (value) => setState(() => _dir = value),
            itemBuilder: (_) => [
              for (final dir in dirs)
                PopupMenuItem<String>(
                  value: dir,
                  height: 44,
                  child: Row(
                    children: [
                      Icon(
                        Icons.folder_outlined,
                        size: 16,
                        color: dir == current
                            ? colors.primary
                            : colors.textHint,
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Text(
                          _dirName(dir),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: dir == current
                                ? colors.primary
                                : colors.textPrimary,
                          ),
                        ),
                      ),
                      if (dir == current)
                        Icon(Icons.check, size: 16, color: colors.primary),
                    ],
                  ),
                ),
            ],
            child: Container(
              constraints: const BoxConstraints(maxWidth: 260),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_open, size: 16, color: colors.textHint),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: colors.textPrimary),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: colors.textHint),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Text(
            '$shown / $total',
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
          IconButton(
            onPressed: () => context.pop(),
            icon: Icon(Icons.close, color: colors.textHint),
            tooltip: context.tr('关闭'),
          ),
        ],
      ),
    );
  }

  /// 筛选栏：点一次「有」，再点「无」，第三次取消（默认没有任何过滤）。
  Widget _buildFilterBar(ThemeColors colors) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Row(
        children: [
          Text(
            context.tr('筛选'),
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
          const SizedBox(width: AppSpacing.sm),
          for (final field in LocalSongField.values) ...[
            _buildFilterChip(colors, field),
            const SizedBox(width: AppSpacing.xs),
          ],
          if (_hasActiveFilter)
            TextButton(
              onPressed: () => setState(() {
                for (final field in LocalSongField.values) {
                  _filters[field] = FieldFilter.any;
                }
              }),
              child: Text(
                context.tr('清空筛选'),
                style: TextStyle(fontSize: 12, color: colors.primary),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(ThemeColors colors, LocalSongField field) {
    final state = _filters[field] ?? FieldFilter.any;
    final active = state != FieldFilter.any;
    final color = state == FieldFilter.lacks ? colors.error : colors.primary;
    return GestureDetector(
      onTap: () => _cycleFilter(field),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: 0.14) : colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: active ? color.withValues(alpha: 0.8) : colors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              context.tr(_fieldLabel(field)),
              style: TextStyle(
                fontSize: 12,
                color: active ? color : colors.textSecondary,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 4),
              Text(
                state == FieldFilter.has ? context.tr('有') : context.tr('无'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 列表列头（与每一行对齐）。
  Widget _buildListHeader(ThemeColors colors) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final style = TextStyle(fontSize: 11, color: colors.textHint);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
      child: Row(
        children: [
          const SizedBox(width: _coverSize + AppSpacing.sm),
          Expanded(flex: 4, child: Text(context.tr('歌名 / 歌手'), style: style)),
          if (wide)
            Expanded(flex: 3, child: Text(context.tr('专辑'), style: style)),
          SizedBox(
            width: _yearWidth,
            child: Text(context.tr('年份'), style: style),
          ),
          if (wide)
            Expanded(flex: 2, child: Text(context.tr('流派'), style: style)),
          if (wide)
            Expanded(flex: 2, child: Text(context.tr('注释'), style: style)),
          SizedBox(
            width: _lyricWidth,
            child: Text(context.tr('歌词'), style: style),
          ),
          const SizedBox(width: _actionWidth),
        ],
      ),
    );
  }

  Widget _buildSongList(ThemeColors colors, List<Song> songs, List<Song> all) {
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return ListView.builder(
      padding: const EdgeInsets.only(bottom: AppSpacing.xxxl),
      itemCount: songs.length,
      itemExtent: _rowHeight,
      itemBuilder: (context, index) {
        final song = songs[index];
        return _buildRow(colors, song, wide: wide, all: all);
      },
    );
  }

  Widget _buildRow(
    ThemeColors colors,
    Song song, {
    required bool wide,
    required List<Song> all,
  }) {
    final lyric = _lyricStatus[song.id];
    final hasLyric = lyric?.hasLyric ?? song.hasLyric;
    final hasWord = lyric?.hasWordLyric ?? song.hasWordLyric;

    return InkWell(
      // 点整行也进匹配界面；回来同样重算歌词状态（可能刚写入了歌词）。
      onTap: () => unawaited(_openMatch(song, all)),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
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
              child: MusicCoverImage(
                url: song.coverUrl,
                songId: song.id,
                width: _coverSize,
                height: _coverSize,
                errorWidget: Container(
                  width: _coverSize,
                  height: _coverSize,
                  color: colors.surfaceVariant,
                  child: Icon(
                    Icons.music_note,
                    size: 18,
                    color: colors.textHint,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
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
                  Text(
                    song.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ],
              ),
            ),
            if (wide) Expanded(flex: 3, child: _cell(colors, song.album)),
            SizedBox(
              width: _yearWidth,
              child: _cell(colors, song.year?.toString() ?? ''),
            ),
            if (wide) Expanded(flex: 2, child: _cell(colors, song.genre)),
            if (wide) Expanded(flex: 2, child: _cell(colors, song.comment)),
            SizedBox(
              width: _lyricWidth,
              child: _buildLyricBadges(colors, hasLyric, hasWord),
            ),
            SizedBox(
              width: _actionWidth,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  _iconButton(
                    colors,
                    icon: Icons.edit,
                    tooltip: context.tr('编辑标签'),
                    onTap: () => context.push(
                      '${AppRoutes.tagEditor}?songId=${song.id}',
                    ),
                  ),
                  _iconButton(
                    colors,
                    icon: Icons.auto_fix_high,
                    tooltip: context.tr('匹配'),
                    onTap: () => unawaited(_openMatch(song, all)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(ThemeColors colors, String? text) {
    final value = (text ?? '').trim();
    return Text(
      value.isEmpty ? '-' : value,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: colors.textSecondary),
    );
  }

  Widget _buildLyricBadges(ThemeColors colors, bool hasLyric, bool hasWord) {
    if (!hasLyric) {
      return Text('-', style: TextStyle(fontSize: 12, color: colors.textHint));
    }
    return Row(
      children: [
        _badge(colors, context.tr('歌词'), colors.primary),
        if (hasWord) ...[
          const SizedBox(width: 4),
          _badge(colors, context.tr('逐字'), colors.error),
        ],
      ],
    );
  }

  Widget _badge(ThemeColors colors, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.6)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Widget _iconButton(
    ThemeColors colors, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        onTap: onTap,
        radius: 18,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(icon, size: 18, color: colors.textSecondary),
        ),
      ),
    );
  }

  Widget _buildEmpty(ThemeColors colors, List<String> dirs, List<Song> all) {
    // 还没有扫描目录、曲库也是空的：提示先添加一个（否则匹配无从谈起）。
    if (dirs.isEmpty && all.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_off_outlined, size: 44, color: colors.textHint),
            const SizedBox(height: AppSpacing.md),
            Text(
              context.tr('还没有添加扫描目录'),
              style: TextStyle(color: colors.textHint),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              context.tr('先添加一个音乐目录，扫描后才能匹配本地歌曲'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
            const SizedBox(height: AppSpacing.md),
            FilledButton.icon(
              onPressed: () => unawaited(_addDirectory()),
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(context.tr('添加扫描目录')),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.filter_alt_off_outlined, size: 44, color: colors.textHint),
          const SizedBox(height: AppSpacing.md),
          Text(
            _hasActiveFilter ? context.tr('没有符合条件的歌曲') : context.tr('暂无歌曲'),
            style: TextStyle(color: colors.textHint),
          ),
        ],
      ),
    );
  }

  String _fieldLabel(LocalSongField field) => switch (field) {
    LocalSongField.cover => '封面',
    LocalSongField.title => '歌名',
    LocalSongField.artist => '歌手',
    LocalSongField.album => '专辑',
    LocalSongField.year => '年份',
    LocalSongField.genre => '流派',
    LocalSongField.comment => '注释',
    LocalSongField.lyric => '歌词',
    LocalSongField.wordLyric => '逐字歌词',
  };

  /// 目录只显示最后一级，完整路径放在 tooltip 里。
  String _dirName(String dir) {
    final parts = dir.split(RegExp(r'[/\\]'))
      ..removeWhere((part) => part.isEmpty);
    return parts.isEmpty ? dir : parts.last;
  }

  static const double _coverSize = 40;
  static const double _rowHeight = 58;
  static const double _yearWidth = 56;
  static const double _lyricWidth = 96;
  static const double _actionWidth = 76;
}
