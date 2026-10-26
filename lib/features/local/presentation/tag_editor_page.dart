import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/services/cover_cache_service.dart';
import '../../../shared/widgets/source_icon.dart';
import '../../discover/application/search_providers.dart';
import '../../download/domain/services/audio_tag_writer.dart';
import '../../plugin/domain/plugin_types.dart';
import '../application/local_providers.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../player/application/root_overlay_tracker.dart';
import '../data/local_metadata_reader.dart';
import 'song_compare_dialog.dart';

class TagEditorPage extends ConsumerStatefulWidget {
  const TagEditorPage({super.key, this.songId});

  final String? songId;

  @override
  ConsumerState<TagEditorPage> createState() => _TagEditorPageState();
}

class _TagEditorPageState extends ConsumerState<TagEditorPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _titleController;
  late TextEditingController _artistController;
  late TextEditingController _albumController;
  late TextEditingController _yearController;
  late TextEditingController _genreController;
  late TextEditingController _lrcController;
  late TextEditingController _searchController;

  Song? _song;
  bool _saving = false;
  bool _searching = false;
  List<Song> _searchResults = [];

  /// 正在写入封面（上传 / 删除），期间禁用封面按钮。
  bool _coverBusy = false;

  /// 封面版本号：封面改动后自增，用作 [MusicCoverImage] 的 key，
  /// 强制它重建并重新取图。
  int _coverVersion = 0;

  /// 在线搜索使用的音源 id（默认网易云，和之前一致）。
  String _searchSourceId = 'wy';

  /// 切换音源按钮的锚点，用于把菜单弹在按钮下方。
  final _sourceButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 登记根级覆盖页状态（左侧栏封面 / 来源标签的「再点关闭」要用）。
    RootOverlayTracker.instance.retain(RootOverlayTracker.tagEditor);
    _tabController = TabController(length: 2, vsync: this);
    _titleController = TextEditingController();
    _artistController = TextEditingController();
    _albumController = TextEditingController();
    _yearController = TextEditingController();
    _genreController = TextEditingController();
    _lrcController = TextEditingController();
    _searchController = TextEditingController();
    // 监听放在控制器创建之后：回调里会读这些输入框的内容。
    _tabController.addListener(_handleTabChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadSong();
    });
  }

  /// 切到「在线搜索」时，用歌曲名 / 歌手输入框的**当前**内容重建关键词。
  ///
  /// 用户很可能在「编辑信息」里改过歌名或歌手（比如去掉多余的括号、修正错别字），
  /// 搜索时必须用改后的内容，而不是加载时缓存下来的旧关键词。
  void _handleTabChanged() {
    if (_tabController.indexIsChanging) return;
    if (_tabController.index != 1) return;
    final keyword = _keywordFromFields();
    if (keyword.isEmpty || keyword == _searchController.text) return;
    setState(() => _searchController.text = keyword);
  }

  /// 由「歌曲名 + 歌手」输入框当前内容拼出的搜索关键词。
  String _keywordFromFields() {
    final title = _titleController.text.trim();
    final artist = _artistController.text.trim();
    if (artist.isEmpty) return title;
    if (title.isEmpty) return artist;
    return '$title $artist';
  }

  void _loadSong() {
    final songId = widget.songId;
    if (songId == null || songId.isEmpty) return;

    final repo = ref.read(localMusicRepositoryProvider);
    final song = repo.getSongById(songId);
    if (song != null) {
      setState(() {
        _song = song;
        _titleController.text = song.title;
        _artistController.text = song.artist;
        _albumController.text = song.album;
        _yearController.text = song.year?.toString() ?? '';
        _genreController.text = '';
        _lrcController.text = song.lrc ?? '';
        // 搜索词带上歌手名，匹配更准。
    _searchController.text = _searchKeywordFor(song);
      });
      // 索引里没有年份 / 歌词时，现读文件里的标签补上。
      _loadFileMetadata(song);
    }
  }

  /// 读取本地文件里的标签（年份 / 内嵌歌词），补齐索引里没有的信息。
  Future<void> _loadFileMetadata(Song song) async {
    final path = song.filePath;
    if (path == null || path.isEmpty) return;
    try {
      final metadata = await LocalMetadataReader.read(path);
      if (!mounted) return;
      setState(() {
        if (_yearController.text.trim().isEmpty) {
          final year = song.year ?? metadata.year;
          if (year != null) _yearController.text = year.toString();
        }
        if (_lrcController.text.trim().isEmpty) {
          final lrc = song.lrc ?? metadata.lyrics;
          if (lrc != null && lrc.isNotEmpty) _lrcController.text = lrc;
        }
      });
    } catch (e) {
      debugPrint('[TagEditor] 读取文件标签失败: $e');
    }
  }

  @override
  void dispose() {
    RootOverlayTracker.instance.release(RootOverlayTracker.tagEditor);
    _tabController.removeListener(_handleTabChanged);
    _tabController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _albumController.dispose();
    _yearController.dispose();
    _genreController.dispose();
    _lrcController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(colors),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              decoration: BoxDecoration(
                color: colors.surface,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: TabBar(
                controller: _tabController,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                labelColor: colors.textOnPrimary,
                unselectedLabelColor: colors.textSecondary,
                labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.normal),
                dividerColor: Colors.transparent,
                tabs: [
                  Tab(text: context.tr('编辑信息')),
                  Tab(text: context.tr('在线搜索')),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildEditTab(colors),
                  _buildSearchTab(colors),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () => context.pop(),
            child: Container(
              padding: const EdgeInsets.all(AppSpacing.xs),
              child: Icon(Icons.close, size: 24, color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              context.tr('编辑标签'),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          if (_song != null)
            GestureDetector(
              onTap: _saving ? null : _handleSave,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: AppSpacing.xs,
                ),
                decoration: BoxDecoration(
                  color: _saving ? colors.textHint : colors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_saving)
                      SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors.textOnPrimary,
                        ),
                      )
                    else
                      Icon(Icons.check, size: 16, color: colors.textOnPrimary),
                    const SizedBox(width: 4),
                    Text(
                      context.tr('保存'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.textOnPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildEditTab(ThemeColors colors) {
    if (_song == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.textHint),
            const SizedBox(height: AppSpacing.md),
            Text(context.tr('未找到歌曲信息'), style: TextStyle(color: colors.textHint)),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildCoverSection(colors),
          const SizedBox(height: AppSpacing.xl),
          _buildField(context.tr('歌曲名'), _titleController, colors, Icons.music_note),
          _buildField(context.tr('歌手'), _artistController, colors, Icons.person),
          _buildField(context.tr('专辑'), _albumController, colors, Icons.album),
          Row(
            children: [
              Expanded(
                child: _buildField(context.tr('年份'), _yearController, colors, Icons.calendar_today),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _buildField(context.tr('流派'), _genreController, colors, Icons.category),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          _buildLrcSection(colors),
          const SizedBox(height: AppSpacing.xxxl),
        ],
      ),
    );
  }

  Widget _buildCoverSection(ThemeColors colors) {
    final song = _song;
    if (song == null) return const SizedBox.shrink();
    final hasCover = song.coverUrl != null || song.hasCover;
    return Center(
      child: Column(
        children: [
          Container(
            width: 160,
            height: 160,
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
            clipBehavior: Clip.antiAlias,
            // 有封面就直接显示封面：网络封面用 coverUrl，本地内嵌封面
            // 走 MusicCoverImage（从 MediaStore / 文件里取）。
            // key 带上版本号：上传 / 删除封面后强制重建，否则会一直显示旧图。
            child: hasCover
                ? MusicCoverImage(
                    key: ValueKey('tag_cover_${song.id}_$_coverVersion'),
                    url: song.coverUrl,
                    songId: song.id,
                    mediaStoreId: song.mediaStoreId,
                    width: 160,
                    height: 160,
                    fit: BoxFit.cover,
                    errorWidget: Container(
                      width: 160,
                      height: 160,
                      color: colors.surfaceVariant,
                      child: Icon(
                        Icons.music_note,
                        size: 48,
                        color: colors.primary.withValues(alpha: 0.5),
                      ),
                    ),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.music_note, size: 48, color: colors.primary.withValues(alpha: 0.5)),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        context.tr('无封面'),
                        style: TextStyle(fontSize: 11, color: colors.textHint),
                      ),
                    ],
                  ),
          ),
          const SizedBox(height: AppSpacing.sm),
          // 封面操作：本地上传 / 删除
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildCoverAction(
                colors,
                icon: Icons.add_photo_alternate_outlined,
                label: context.tr('本地上传图片'),
                onTap: _coverBusy ? null : _pickCover,
              ),
              if (hasCover) ...[
                const SizedBox(width: AppSpacing.md),
                _buildCoverAction(
                  colors,
                  icon: Icons.delete_outline,
                  label: context.tr('删除封面'),
                  danger: true,
                  onTap: _coverBusy ? null : _removeCover,
                ),
              ],
            ],
          ),
          if (_coverBusy) ...[
            const SizedBox(height: AppSpacing.xs),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.primary,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xs),
          if (song.filePath != null)
            Text(
              song.filePath!.split(RegExp(r'[/\\]')).last,
              style: TextStyle(fontSize: 11, color: colors.textHint),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          if (song.bitrate != null && song.bitrate! > 0) ...[
            const SizedBox(height: 2),
            Text(
              context.tr(
                '${(song.bitrate! / 1000).round()} kbps'
                '${song.sampleRate != null ? ' · ${(song.sampleRate! / 1000).toStringAsFixed(1)} kHz' : ''}'
                '${song.channels != null ? ' · ${song.channels == 2 ? '立体声' : '单声道'}' : ''}',
              ),
              style: TextStyle(fontSize: 11, color: colors.textHint),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCoverAction(
    ThemeColors colors, {
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    bool danger = false,
  }) {
    final enabled = onTap != null;
    final color = danger ? colors.error : colors.primary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: enabled
              ? color.withValues(alpha: 0.12)
              : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(
            color: enabled
                ? color.withValues(alpha: 0.35)
                : colors.divider,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: enabled ? color : colors.textHint),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: enabled ? color : colors.textHint,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 从本地选一张图片，写进音频文件的封面标签。
  Future<void> _pickCover() async {
    final song = _song;
    final path = song?.filePath;
    if (song == null || path == null || path.isEmpty) return;

    final result = await FilePicker.platform.pickFiles(
      dialogTitle: context.tr('选择封面图片'),
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
      allowMultiple: false,
    );
    final files = result?.files;
    if (files == null || files.isEmpty) return;
    final imagePath = files.first.path;
    if (imagePath == null || imagePath.isEmpty) return;

    setState(() => _coverBusy = true);
    try {
      // 先取出 notifier：写文件是异步的，期间页面可能已经被关掉，
      // 那时再用 ref.read 会抛「after dispose」。
      final notifier = ref.read(localMusicNotifierProvider.notifier);
      final bytes = await File(imagePath).readAsBytes();
      if (bytes.isEmpty) {
        throw Exception(context.tr('图片读取失败'));
      }
      // 直接写进音频文件（MP3 / FLAC），其它格式会返回 false。
      final ok = await AudioTagWriter.write(path, artwork: bytes);
      if (!ok) {
        throw Exception(context.tr('该音频格式不支持写入封面'));
      }
      // 更新封面缓存 + 索引，列表 / 播放页也会跟着刷新。
      await CoverCacheService().putArtwork(song.id, bytes);
      MusicCoverImage.refresh(song.id);
      await notifier.upsertSong(
        song.copyWith(hasCover: true, clearCover: true),
        // 封面信息要以文件为准：合并写入会保留旧的 coverUrl / hasCover，
        // 所以这里整条覆盖（传的就是索引里读出来的完整歌曲对象）。
        forceOverwrite: true,
      );
      if (!mounted) return;
      setState(() {
        _song = song.copyWith(hasCover: true, clearCover: true);
        _coverVersion++;
      });
      _toast(context.tr('封面已更新'));
    } catch (e) {
      if (mounted) _toast(context.tr('封面更新失败: $e'));
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  /// 删除音频文件里的封面。
  Future<void> _removeCover() async {
    final song = _song;
    final path = song?.filePath;
    if (song == null || path == null || path.isEmpty) return;

    setState(() => _coverBusy = true);
    try {
      final notifier = ref.read(localMusicNotifierProvider.notifier);
      final ok = await AudioTagWriter.write(path, removeArtwork: true);
      if (!ok) {
        throw Exception(context.tr('该音频格式不支持删除封面'));
      }
      // 清掉内存 / 磁盘里的封面缓存，界面才会回到「无封面」。
      CoverCacheService().invalidate(song.id);
      MusicCoverImage.refresh(song.id);
      await notifier.upsertSong(
        song.copyWith(hasCover: false, clearCover: true),
        forceOverwrite: true,
      );
      if (!mounted) return;
      setState(() {
        _song = song.copyWith(hasCover: false, clearCover: true);
        _coverVersion++;
      });
      _toast(context.tr('封面已删除'));
    } catch (e) {
      if (mounted) _toast(context.tr('删除封面失败: $e'));
    } finally {
      if (mounted) setState(() => _coverBusy = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildField(
    String label,
    TextEditingController controller,
    ThemeColors colors,
    IconData icon,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Column(
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
          TextField(
            controller: controller,
            style: TextStyle(fontSize: 15, color: colors.textPrimary),
            decoration: InputDecoration(
              prefixIcon: Icon(icon, size: 18, color: colors.textHint),
              filled: true,
              fillColor: colors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLrcSection(ThemeColors colors) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.lyrics, size: 16, color: colors.textHint),
            const SizedBox(width: AppSpacing.xs),
            Text(
              context.tr('歌词'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colors.textHint,
              ),
            ),
            const Spacer(),
            if (_lrcController.text.isNotEmpty)
              GestureDetector(
                onTap: () {
                  setState(() {
                    _lrcController.clear();
                  });
                },
                child: Text(
                  context.tr('清空'),
                  style: TextStyle(fontSize: 12, color: colors.primary),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Container(
          constraints: const BoxConstraints(minHeight: 120, maxHeight: 250),
          child: TextField(
            controller: _lrcController,
            maxLines: null,
            style: TextStyle(
              fontSize: 13,
              color: colors.textPrimary,
              fontFamily: 'monospace',
              height: 1.5,
            ),
            decoration: InputDecoration(
              filled: true,
              fillColor: colors.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              hintText: context.tr('输入LRC歌词内容'),
              hintStyle: TextStyle(color: colors.textHint, fontSize: 13),
              contentPadding: const EdgeInsets.all(AppSpacing.md),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSearchTab(ThemeColors colors) {
    final sources = ref
        .watch(searchAvailableSourcesProvider)
        .toList(growable: false);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              Expanded(child: _buildSearchBar(colors)),
              const SizedBox(width: AppSpacing.sm),
              _buildSourceButton(colors, sources),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Expanded(
          child: _searching
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(color: colors.primary),
                      const SizedBox(height: AppSpacing.md),
                      Text(context.tr('搜索中...'), style: TextStyle(color: colors.textHint, fontSize: 14)),
                    ],
                  ),
                )
              : _searchResults.isNotEmpty
                  ? _buildSearchResults(colors)
                  : _buildSearchEmpty(colors),
        ),
      ],
    );
  }

  /// 搜索框与音源按钮共用的高度。
  static const double _searchBarHeight = 44;

  /// 搜索框右侧的音源切换按钮（与发现页搜索页的样式保持一致）。
  Widget _buildSourceButton(ThemeColors colors, List<SourceInfo> sources) {
    SourceInfo? current;
    for (final source in sources) {
      if (source.id == _searchSourceId) {
        current = source;
        break;
      }
    }
    return GestureDetector(
      key: _sourceButtonKey,
      onTap: sources.isEmpty ? null : () => _showSourceMenu(colors, sources),
      child: Container(
        width: _searchBarHeight,
        height: _searchBarHeight,
        decoration: BoxDecoration(
          color: colors.surface,
          shape: BoxShape.circle,
        ),
        clipBehavior: Clip.antiAlias,
        child: current == null
            ? Icon(
                Icons.library_music_outlined,
                size: 20,
                color: colors.textHint,
              )
            : SourceIcon(
                // 同名插件的变体 id 要还原成平台 id 才能取到对应图标。
                sourceId: SourceInfo.baseIdOf(current.id),
                size: _searchBarHeight,
                label: current.name,
              ),
      ),
    );
  }

  void _showSourceMenu(ThemeColors colors, List<SourceInfo> sources) {
    final box =
        _sourceButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      color: colors.surface,
      elevation: 8,
      items: [
        for (final source in sources)
          PopupMenuItem<String>(
            value: source.id,
            height: 44,
            child: Row(
              children: [
                SourceIcon(
                  sourceId: SourceInfo.baseIdOf(source.id),
                  size: 18,
                  label: source.name,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    source.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: source.id == _searchSourceId
                          ? colors.primary
                          : colors.textPrimary,
                      fontWeight: source.id == _searchSourceId
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (source.id == _searchSourceId)
                  Icon(Icons.check, size: 16, color: colors.primary),
              ],
            ),
          ),
      ],
    ).then((selectedId) {
      if (selectedId == null || selectedId == _searchSourceId) return;
      final id = selectedId;
      setState(() => _searchSourceId = id);
      // 已经搜过的话，换音源后直接用新音源重搜一次。
      if (_searchResults.isNotEmpty) {
        unawaited(_handleSearch());
      }
    });
  }

  Widget _buildSearchBar(ThemeColors colors) {
    return Container(
      // 与右侧音源按钮等高，视觉上是一条完整的搜索栏。
      height: _searchBarHeight,
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
              onSubmitted: (_) => _handleSearch(),
              decoration: InputDecoration(
                hintText: context.tr('输入关键词搜索 (歌曲名 歌手)'),
                border: InputBorder.none,
                filled: false,
                isDense: true,
                hintStyle: TextStyle(color: colors.textHint, fontSize: 14),
              ),
              style: TextStyle(color: colors.textPrimary, fontSize: 14),
            ),
          ),
          if (_searchController.text.isNotEmpty)
            GestureDetector(
              onTap: () {
                _searchController.clear();
              },
              child: Icon(Icons.close, size: 18, color: colors.textHint),
            ),
          const SizedBox(width: AppSpacing.xs),
          GestureDetector(
            onTap: _searching ? null : _handleSearch,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Text(
                context.tr('搜索'),
                style: TextStyle(fontSize: 13, color: colors.textOnPrimary, fontWeight: FontWeight.w500),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResults(ThemeColors colors) {
    return ListView.separated(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      itemCount: _searchResults.length,
      separatorBuilder: (_, __) => Divider(height: 1, color: colors.divider),
      itemBuilder: (context, index) {
        final item = _searchResults[index];
        return _buildSearchResultItem(colors, item);
      },
    );
  }

  Widget _buildSearchResultItem(ThemeColors colors, Song item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              image: item.coverUrl != null
                  ? DecorationImage(
                      image: NetworkImage(item.coverUrl!),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: item.coverUrl == null
                ? Icon(Icons.music_note, size: 20, color: colors.textHint)
                : null,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.title,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: colors.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(AppRadius.xs),
                      ),
                      child: Text(
                        // 显示这条结果真正来自哪个音源（不再写死 WY）。
                        SourceInfo.baseIdOf(
                          (item.source ?? '').isEmpty
                              ? _searchSourceId
                              : item.source!,
                        ).toUpperCase(),
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: colors.primary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${item.artist}${item.album.isNotEmpty ? ' · ${item.album}' : ''}',
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          GestureDetector(
            onTap: () => _applyResult(item),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: colors.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.full),
                border: Border.all(color: colors.primary.withValues(alpha: 0.3)),
              ),
              child: Text(
                context.tr('使用'),
                style: TextStyle(
                  fontSize: 12,
                  color: colors.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchEmpty(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.search, size: 48, color: colors.textHint.withValues(alpha: 0.5)),
          const SizedBox(height: AppSpacing.md),
          Text(
            context.tr(
              _searchController.text.isEmpty ? '输入关键词开始搜索' : '未找到相关结果',
            ),
            style: TextStyle(color: colors.textHint, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Future<void> _handleSearch() async {
    // 关键词以搜索框为准；框里是空的就用「歌曲名 + 歌手」输入框的最新内容
    // （用户可能刚改过歌名 / 歌手）。
    var keyword = _searchController.text.trim();
    if (keyword.isEmpty) {
      keyword = _keywordFromFields();
      if (keyword.isNotEmpty) {
        setState(() => _searchController.text = keyword);
      }
    }
    if (keyword.isEmpty) return;

    setState(() => _searching = true);

    try {
      final manager = ref.read(musicSourceManagerProvider);
      final results = await manager.search(
        keyword,
        sourceId: _searchSourceId,
        limit: 30,
      );
      if (mounted) {
        setState(() {
          _searchResults = results;
          _searching = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _searching = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('搜索失败: $e')), duration: const Duration(seconds: 2)),
        );
      }
    }
  }

  /// 搜索关键词：歌曲名 + 歌手名。
  static String _searchKeywordFor(Song song) {
    final title = song.title.trim();
    final artist = song.artist.trim();
    if (artist.isEmpty) return title;
    if (title.isEmpty) return artist;
    return '$title $artist';
  }

  Future<void> _applyResult(Song result) async {
    // 弹出「歌曲信息对比」页：左边原歌曲、右边下载的版本，
    // 中间的箭头逐项选择采用哪一版（封面 / 歌曲信息 / 歌词）。
    final original = _song;
    final merged = await showSongCompareDialog(
      context,
      original: original ?? result,
      candidate: result,
    );
    if (merged == null || !mounted) return;

    setState(() => _saving = true);

    try {
      _titleController.text = merged.title.isNotEmpty
          ? merged.title
          : _titleController.text;
      _artistController.text = merged.artist.isNotEmpty
          ? merged.artist
          : _artistController.text;
      _albumController.text = merged.album.isNotEmpty
          ? merged.album
          : _albumController.text;

      if (merged.coverUrl != null && merged.coverUrl!.isNotEmpty) {
        setState(() {
          _song = _song?.copyWith(
            coverUrl: merged.coverUrl,
            hasCover: true,
          );
        });
      }

      final lyric = merged.lrc;
      if (lyric != null && lyric.isNotEmpty) {
        _lrcController.text = lyric;
      }

      _tabController.animateTo(0);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('已应用元数据，请检查后保存')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('应用失败: $e')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _handleSave() async {
    if (_song == null) return;

    setState(() => _saving = true);

    try {
      final updated = _song!.copyWith(
        title: _titleController.text.trim().isEmpty ? null : _titleController.text.trim(),
        artist: _artistController.text.trim().isEmpty ? null : _artistController.text.trim(),
        album: _albumController.text.trim().isEmpty ? null : _albumController.text.trim(),
        year: int.tryParse(_yearController.text.trim()),
        lrc: _lrcController.text.trim().isEmpty ? null : _lrcController.text.trim(),
      );

      await ref.read(localMusicNotifierProvider.notifier).upsertSong(updated);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('标签已保存')), duration: const Duration(seconds: 2)),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(context.tr('保存失败: $e')), duration: Duration(seconds: 2)),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
