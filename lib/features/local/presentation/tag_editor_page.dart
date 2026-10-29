import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
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
import '../../settings/application/settings_providers.dart';
import '../application/local_providers.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../player/application/root_overlay_tracker.dart';
import '../data/local_metadata_reader.dart';
import 'match_widgets.dart';

class TagEditorPage extends ConsumerStatefulWidget {
  const TagEditorPage({super.key, this.songId, this.autoSearch = false});

  final String? songId;

  /// 进来就切到「在线搜索」并自动搜一次（快速匹配页的「匹配」按钮用）。
  final bool autoSearch;

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
  late TextEditingController _commentController;
  late TextEditingController _lrcController;
  late TextEditingController _searchController;

  /// 在线搜索的歌曲名 / 歌手输入框（文件里两个标签都有时用两个框）。
  late TextEditingController _searchTitleController;
  late TextEditingController _searchArtistController;

  Song? _song;
  bool _saving = false;
  bool _searching = false;
  String? _searchError;
  List<Song> _searchResults = const <Song>[];

  /// 当前选中的候选（默认第一个）。
  int _selectedIndex = 0;
  String? _candidateLyric;
  bool _loadingCandidateLyric = false;
  int? _candidateYear;

  /// 对比里每一项是否采用匹配结果：封面 / 歌曲信息 / 歌词。
  bool _useCandidateCover = true;
  bool _useCandidateInfo = true;
  bool _useCandidateLyric = true;

  /// 文件里歌名 + 歌手都有标签：搜索框拆成两个，并按这两个字段精确过滤结果。
  bool _splitSearchFields = false;

  /// 本次搜索放弃精确过滤（过滤后一条都没有时，用户点「显示全部结果」）。
  bool _ignoreExactMatch = false;

  /// 精确过滤把搜索结果全滤掉了（界面给出「显示全部结果」的出口）。
  bool _exactMatchBlocked = false;

  /// 自动搜索只触发一次（从快速匹配页的「匹配」按钮进来时）。
  bool _autoSearchTriggered = false;

  /// 上一次实际用来搜索的关键词（编辑信息里改了歌名 / 歌手时据此同步输入框）。
  String _lastSearchKeyword = '';

  /// 文件里读出来的标签（内嵌歌词 / 年份，用于对比）。
  LocalAudioMetadata? _fileMeta;

  /// 从网络搜索「使用」过来的封面地址。
  ///
  /// 网络封面只是 URL，只有保存到文件时才会下载成图片写进 APIC / PICTURE。
  String? _webCoverUrl;

  /// 正在写入封面（上传 / 删除），期间禁用封面按钮。
  bool _coverBusy = false;

  /// 封面版本号：封面改动后自增，用作 [MusicCoverImage] 的 key，
  /// 强制它重建并重新取图。
  int _coverVersion = 0;

  /// 打开页面时各字段的原始值。
  ///
  /// 保存时用它判断「到底有没有改过」：没改就不动音频文件。
  String _baseTitle = '';
  String _baseArtist = '';
  String _baseAlbum = '';
  String _baseYear = '';
  String _baseGenre = '';
  String _baseComment = '';
  String _baseLrc = '';

  /// 在线搜索使用的音源 id。
  ///
  /// 空串表示用户还没手动选过：默认跟随当前音源（见 [_resolvedSearchSourceId]）。
  String _searchSourceId = '';

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
    _commentController = TextEditingController();
    _lrcController = TextEditingController();
    _searchController = TextEditingController();
    _searchTitleController = TextEditingController();
    _searchArtistController = TextEditingController();
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
    // 编辑信息里的歌名 / 歌手改过了：同步到搜索框（别用改之前的关键词去搜）。
    final keyword = _keywordFromFields();
    if (keyword.isNotEmpty && keyword != _lastSearchKeyword) {
      setState(() {
        _searchTitleController.text = _titleController.text;
        _searchArtistController.text = _artistController.text;
        _searchController.text = keyword;
      });
    }
    _maybeAutoSearch();
  }

  /// 从快速匹配页的「匹配」按钮进来时，切到在线搜索后自动搜一次。
  void _maybeAutoSearch() {
    if (!widget.autoSearch || _autoSearchTriggered) return;
    if (_song == null) return;
    _autoSearchTriggered = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_autoSearch());
    });
  }

  /// 等插件（音源）就绪后再自动搜索，避免刚进页面时音源列表还是空的。
  Future<void> _autoSearch() async {
    try {
      await ref.read(pluginInitializedProvider.future);
    } catch (_) {
      // 插件初始化失败也照常尝试一次，失败时页面会显示原因。
    }
    if (!mounted) return;
    await _handleSearch();
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
        _genreController.text = song.genre ?? '';
        _commentController.text = song.comment ?? '';
        _lrcController.text = song.lrc ?? '';
        // 搜索词带上歌手名，匹配更准。
        _searchController.text = _searchKeywordFor(song);
        _searchTitleController.text = song.title;
        _searchArtistController.text = song.artist;
        // 文件里歌名 + 歌手都有标签：搜索框拆成两个，并按两个字段精确过滤。
        _splitSearchFields =
            !_isUnknownTitle(song.title) && !_isUnknownArtist(song.artist);
      });
      _captureBaseline();
      // 索引里没有年份 / 歌词时，现读文件里的标签补上。
      _loadFileMetadata(song);
      if (widget.autoSearch) {
        _tabController.animateTo(1);
        _maybeAutoSearch();
      }
    }
  }

  static bool _isUnknownTitle(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty || text == '未知曲目';
  }

  static bool _isUnknownArtist(String? value) {
    final text = (value ?? '').trim();
    return text.isEmpty || text == '未知艺术家' || text == '未知歌手';
  }

  /// 把当前输入框内容记成「原始值」（用于判断有没有修改）。
  void _captureBaseline() {
    _baseTitle = _titleController.text;
    _baseArtist = _artistController.text;
    _baseAlbum = _albumController.text;
    _baseYear = _yearController.text;
    _baseGenre = _genreController.text;
    _baseComment = _commentController.text;
    _baseLrc = _lrcController.text;
  }

  /// 输入框内容是否跟打开时不一样（真的改过）。
  bool get _hasChanges =>
      _titleController.text != _baseTitle ||
      _artistController.text != _baseArtist ||
      _albumController.text != _baseAlbum ||
      _yearController.text != _baseYear ||
      _genreController.text != _baseGenre ||
      _commentController.text != _baseComment ||
      _lrcController.text != _baseLrc;

  /// 读取本地文件里的标签（年份 / 内嵌歌词），补齐索引里没有的信息。
  Future<void> _loadFileMetadata(Song song) async {
    final path = song.filePath;
    if (path == null || path.isEmpty) return;
    try {
      final metadata = await LocalMetadataReader.read(path);
      if (!mounted) return;
      setState(() {
        _fileMeta = metadata;
        // 索引里缺歌名 / 歌手时用文件标签补（在线搜索要按这两个字段精确匹配）。
        if (_isUnknownTitle(song.title) && !_isUnknownTitle(metadata.title)) {
          _titleController.text = metadata.title!;
          _baseTitle = _titleController.text;
        }
        if (_isUnknownArtist(song.artist) &&
            !_isUnknownArtist(metadata.artist)) {
          _artistController.text = metadata.artist!;
          _baseArtist = _artistController.text;
        }
        if (!_splitSearchFields &&
            !_isUnknownTitle(_titleController.text) &&
            !_isUnknownArtist(_artistController.text)) {
          _splitSearchFields = true;
          _searchTitleController.text = _titleController.text;
          _searchArtistController.text = _artistController.text;
        }
        // 只给空字段补值，并把补进来的值也算成「原始值」——文件里本来就是这样，
        // 不算用户修改，保存时也就不会无谓地重写文件。
        if (_yearController.text.trim().isEmpty) {
          final year = song.year ?? metadata.year;
          if (year != null) {
            _yearController.text = year.toString();
            _baseYear = _yearController.text;
          }
        }
        if (_lrcController.text.trim().isEmpty) {
          final lrc = song.lrc ?? metadata.lyrics;
          if (lrc != null && lrc.isNotEmpty) {
            _lrcController.text = lrc;
            _baseLrc = _lrcController.text;
          }
        }
        if (_genreController.text.trim().isEmpty) {
          final genre = song.genre ?? metadata.genre;
          if (genre != null && genre.isNotEmpty) {
            _genreController.text = genre;
            _baseGenre = _genreController.text;
          }
        }
        if (_commentController.text.trim().isEmpty) {
          final comment = song.comment ?? metadata.comment;
          if (comment != null && comment.isNotEmpty) {
            _commentController.text = comment;
            _baseComment = _commentController.text;
          }
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
    _commentController.dispose();
    _lrcController.dispose();
    _searchController.dispose();
    _searchTitleController.dispose();
    _searchArtistController.dispose();
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
                labelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.normal,
                ),
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
                children: [_buildEditTab(colors), _buildSearchTab(colors)],
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
                      context.tr('保存到文件'),
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
            Text(
              context.tr('未找到歌曲信息'),
              style: TextStyle(color: colors.textHint),
            ),
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
          _buildField(
            context.tr('歌曲名'),
            _titleController,
            colors,
            Icons.music_note,
          ),
          _buildField(
            context.tr('歌手'),
            _artistController,
            colors,
            Icons.person,
          ),
          _buildField(context.tr('专辑'), _albumController, colors, Icons.album),
          Row(
            children: [
              Expanded(
                child: _buildField(
                  context.tr('年份'),
                  _yearController,
                  colors,
                  Icons.calendar_today,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: _buildField(
                  context.tr('流派'),
                  _genreController,
                  colors,
                  Icons.category,
                ),
              ),
            ],
          ),
          _buildField(
            context.tr('注释'),
            _commentController,
            colors,
            Icons.notes,
            maxLines: 3,
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
                      Icon(
                        Icons.music_note,
                        size: 48,
                        color: colors.primary.withValues(alpha: 0.5),
                      ),
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
            color: enabled ? color.withValues(alpha: 0.35) : colors.divider,
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
      // 本地上传的图片已经写进文件了：别再把之前的网络封面写一遍。
      _webCoverUrl = null;
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
      _webCoverUrl = null;
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
    IconData icon, {
    int maxLines = 1,
  }) {
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
            maxLines: maxLines,
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

  /// 实际使用的搜索音源。
  ///
  /// 用户手动选过的优先；没选过时跟随当前音源（发现页 / 插件管理里正在用的
  /// 那个），当前音源不可搜索时退回到列表里的第一个。
  String _resolvedSearchSourceId(List<SourceInfo> sources) {
    if (sources.any((source) => source.id == _searchSourceId)) {
      return _searchSourceId;
    }
    final current = ref.read(defaultSourceIdProvider);
    if (sources.any((source) => source.id == current)) return current;
    return sources.isEmpty ? _searchSourceId : sources.first.id;
  }

  Widget _buildSearchTab(ThemeColors colors) {
    final sources = ref
        .watch(searchAvailableSourcesProvider)
        .toList(growable: false);
    final sourceId = _resolvedSearchSourceId(sources);
    final candidate = _currentCandidate;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Row(
            children: [
              Expanded(child: _buildSearchFields(colors)),
              const SizedBox(width: AppSpacing.sm),
              _buildSearchButton(colors, sources),
              const SizedBox(width: AppSpacing.sm),
              _buildSourceButton(colors, sources, sourceId),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        if (candidate != null) ...[
          MatchCandidateStrip(
            colors: colors,
            results: _searchResults,
            selectedIndex: _selectedIndex,
            onSelect: _selectCandidate,
          ),
          const SizedBox(height: AppSpacing.md),
        ],
        Expanded(child: _buildSearchBody(colors, candidate)),
        _buildSearchBottomBar(colors, candidate),
      ],
    );
  }

  /// 搜索区主体：加载中 / 空状态 / 三行对比。
  Widget _buildSearchBody(ThemeColors colors, Song? candidate) {
    if (_searching) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: colors.primary),
            const SizedBox(height: AppSpacing.md),
            Text(
              context.tr('搜索中...'),
              style: TextStyle(color: colors.textHint, fontSize: 14),
            ),
          ],
        ),
      );
    }
    if (candidate == null) return _buildSearchEmpty(colors);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: MatchCompareView(
        colors: colors,
        original: _originalSong,
        candidate: candidate,
        originalYear: _originalYear,
        candidateYear: _candidateYear ?? candidate.year,
        originalLyric: _originalLyric,
        candidateLyric: _candidateLyric,
        loadingCandidateLyric: _loadingCandidateLyric,
        useCover: _useCandidateCover,
        useInfo: _useCandidateInfo,
        useLyric: _useCandidateLyric,
        onUseCover: (use) => setState(() => _useCandidateCover = use),
        onUseInfo: (use) => setState(() => _useCandidateInfo = use),
        onUseLyric: (use) => setState(() => _useCandidateLyric = use),
      ),
    );
  }

  /// 底部「取消 / 使用」：使用只把选中数据填进「编辑信息」，不写文件。
  Widget _buildSearchBottomBar(ThemeColors colors, Song? candidate) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => _tabController.animateTo(0),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            onPressed: candidate == null ? null : _applySelected,
            child: Text(context.tr('使用')),
          ),
        ],
      ),
    );
  }

  /// 搜索框与音源按钮共用的高度。
  static const double _searchBarHeight = 44;

  /// 搜索框右侧的音源切换按钮（与发现页搜索页的样式保持一致）。
  ///
  /// 按钮直接显示 [currentId] 这个音源的图标，用户一眼能看出当前在搜哪个音源。
  Widget _buildSourceButton(
    ThemeColors colors,
    List<SourceInfo> sources,
    String currentId,
  ) {
    SourceInfo? current;
    for (final source in sources) {
      if (source.id == currentId) {
        current = source;
        break;
      }
    }
    return GestureDetector(
      key: _sourceButtonKey,
      onTap: sources.isEmpty
          ? null
          : () => _showSourceMenu(colors, sources, currentId),
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

  void _showSourceMenu(
    ThemeColors colors,
    List<SourceInfo> sources,
    String currentId,
  ) {
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
                SourceIcon(sourceId: source.id, size: 18, label: source.name),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    source.name,
                    style: TextStyle(
                      fontSize: 13,
                      color: source.id == currentId
                          ? colors.primary
                          : colors.textPrimary,
                      fontWeight: source.id == currentId
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (source.id == currentId)
                  Icon(Icons.check, size: 16, color: colors.primary),
              ],
            ),
          ),
      ],
    ).then((selectedId) {
      if (selectedId == null || selectedId == currentId) return;
      final id = selectedId;
      setState(() => _searchSourceId = id);
      // 换音源后自动重新搜索一次（上次没结果也照样换源再搜）。
      unawaited(_handleSearch());
    });
  }

  /// 搜索输入区：文件里歌名 + 歌手都有标签时是两个框（按这两个字段精确匹配），
  /// 否则一个关键词框。
  Widget _buildSearchFields(ThemeColors colors) {
    if (_splitSearchFields) {
      return Row(
        children: [
          Expanded(
            child: _buildSearchInput(
              colors,
              controller: _searchTitleController,
              label: context.tr('歌曲'),
              hint: context.tr('歌曲名'),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _buildSearchInput(
              colors,
              controller: _searchArtistController,
              label: context.tr('歌手'),
              hint: context.tr('歌手'),
            ),
          ),
        ],
      );
    }
    return _buildSearchInput(
      colors,
      controller: _searchController,
      icon: Icons.search,
      hint: context.tr('输入关键词搜索 (歌曲名 歌手)'),
    );
  }

  Widget _buildSearchInput(
    ThemeColors colors, {
    required TextEditingController controller,
    String? label,
    String? hint,
    IconData? icon,
  }) {
    return Container(
      height: _searchBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Row(
        children: [
          if (label != null) ...[
            Text(label, style: TextStyle(fontSize: 12, color: colors.textHint)),
            const SizedBox(width: AppSpacing.sm),
          ],
          if (icon != null) ...[
            Icon(icon, size: 18, color: colors.textHint),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              onSubmitted: (_) => _handleSearch(),
              decoration: InputDecoration(
                hintText: hint,
                border: InputBorder.none,
                filled: false,
                isDense: true,
                hintStyle: TextStyle(color: colors.textHint, fontSize: 14),
              ),
              style: TextStyle(color: colors.textPrimary, fontSize: 14),
            ),
          ),
          if (controller.text.isNotEmpty)
            GestureDetector(
              onTap: () => setState(controller.clear),
              child: Icon(Icons.close, size: 18, color: colors.textHint),
            ),
        ],
      ),
    );
  }

  Widget _buildSearchButton(ThemeColors colors, List<SourceInfo> sources) {
    final enabled = sources.isNotEmpty && !_searching;
    return GestureDetector(
      onTap: enabled ? () => unawaited(_handleSearch()) : null,
      child: Container(
        height: _searchBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled
              ? colors.primary
              : colors.primary.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: _searching
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.textOnPrimary,
                ),
              )
            : Text(
                context.tr('搜索'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.textOnPrimary,
                ),
              ),
      ),
    );
  }

  Widget _buildSearchEmpty(ThemeColors colors) {
    final keyword = _queryText();
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search,
            size: 48,
            color: colors.textHint.withValues(alpha: 0.5),
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            keyword.isEmpty
                ? context.tr('输入关键词开始搜索')
                : _exactMatchBlocked
                ? context.tr('没有精确匹配的结果')
                : context.tr('未找到相关结果'),
            style: TextStyle(color: colors.textHint, fontSize: 14),
          ),
          if (_searchError != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xl),
              child: Text(
                context.tr('搜索失败: $_searchError'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ),
          ],
          if (_exactMatchBlocked) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () {
                setState(() {
                  _ignoreExactMatch = true;
                  _exactMatchBlocked = false;
                });
                unawaited(_handleSearch());
              },
              child: Text(context.tr('显示全部结果')),
            ),
          ],
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 搜索

  /// 当前搜索词：两个输入框时是「歌曲名 + 歌手」，否则是关键词框。
  String _queryText() {
    if (_splitSearchFields) {
      final title = _searchTitleController.text.trim();
      final artist = _searchArtistController.text.trim();
      if (title.isEmpty) return artist;
      if (artist.isEmpty) return title;
      return '$title $artist';
    }
    return _searchController.text.trim();
  }

  /// 是否按「歌曲名 + 歌手」精确过滤结果。
  bool get _exactMatchActive => _splitSearchFields && !_ignoreExactMatch;

  /// 精确匹配时要去掉的字符：空白与常见标点 / 括号（全角半角都算），
  /// 「你的样子（女版）」与「你的样子 (女版)」这种排版差异不该影响匹配。
  static const String _matchNoiseChars =
      ' \u3000（）()[]【】{}<>《》「」『』"“”\'‘’·、,，.。!！?？:：;；_-—–/\\|&+~';

  static String _normalizeForMatch(String value) {
    final buffer = StringBuffer();
    for (final rune in value.toLowerCase().runes) {
      final ch = String.fromCharCode(rune);
      if (_matchNoiseChars.contains(ch)) continue;
      buffer.write(ch);
    }
    return buffer.toString();
  }

  /// 搜索结果是否与文件里的歌名 + 歌手精确对应。
  ///
  /// 歌名要求完全一致（忽略排版差异）；歌手允许「包含」——很多结果把
  /// 合作歌手拼在一起（「三妹、苗小青」），要求完全相等会把它们全过滤掉。
  bool _matchesExactly(Song song, String title, String artist) {
    if (_normalizeForMatch(song.title) != title) return false;
    final resultArtist = _normalizeForMatch(song.artist);
    if (resultArtist.isEmpty) return false;
    return resultArtist == artist ||
        resultArtist.contains(artist) ||
        artist.contains(resultArtist);
  }

  List<Song> _filterExactMatches(List<Song> results) {
    if (!_exactMatchActive) return results;
    final title = _normalizeForMatch(_searchTitleController.text);
    final artist = _normalizeForMatch(_searchArtistController.text);
    if (title.isEmpty || artist.isEmpty) return results;
    return [
      for (final song in results)
        if (_matchesExactly(song, title, artist)) song,
    ];
  }

  Song? get _currentCandidate {
    if (_searchResults.isEmpty) return null;
    if (_selectedIndex < 0 || _selectedIndex >= _searchResults.length) {
      return null;
    }
    return _searchResults[_selectedIndex];
  }

  /// 原歌曲（用编辑信息里**当前**的内容，改了歌名 / 歌手后对比的是改后的）。
  Song get _originalSong {
    final song = _song;
    if (song == null) {
      return Song(
        id: '',
        title: _titleController.text,
        artist: _artistController.text,
        album: '',
        duration: 0,
      );
    }
    return song.copyWith(
      title: _titleController.text,
      artist: _artistController.text,
      album: _albumController.text,
      year: int.tryParse(_yearController.text.trim()) ?? song.year,
      genre: _genreController.text,
    );
  }

  int? get _originalYear =>
      int.tryParse(_yearController.text.trim()) ??
      _song?.year ??
      _fileMeta?.year;

  String? get _originalLyric {
    final lyric = _lrcController.text;
    if (lyric.trim().isNotEmpty) return lyric;
    final embedded = _fileMeta?.lyrics;
    if (embedded != null && embedded.trim().isNotEmpty) return embedded;
    return null;
  }

  Future<void> _handleSearch() async {
    final keyword = _queryText();
    if (keyword.isEmpty || _searching) return;
    // 换了搜索词才算新搜索：重新允许精确过滤。同一个词重搜（比如点了
    // 「显示全部结果」后）要保留用户放行全部结果的选择，否则按钮不生效。
    if (_splitSearchFields && keyword != _lastSearchKeyword) {
      _ignoreExactMatch = false;
    }
    _lastSearchKeyword = keyword;

    setState(() {
      _searching = true;
      _searchError = null;
      _exactMatchBlocked = false;
      _searchResults = const <Song>[];
      _selectedIndex = 0;
      _candidateLyric = null;
      _candidateYear = null;
      _loadingCandidateLyric = false;
      _useCandidateCover = true;
      _useCandidateInfo = true;
      _useCandidateLyric = true;
    });

    // 用户没手动选过音源时，要按当前音源搜，而不是某个写死的平台。
    final sourceId = _resolvedSearchSourceId(
      ref.read(searchAvailableSourcesProvider),
    );
    if (sourceId.isEmpty) {
      if (mounted) {
        setState(() => _searching = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('请先在插件管理里启用音源')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    try {
      final manager = ref.read(musicSourceManagerProvider);
      final results = await manager.search(
        keyword,
        sourceId: sourceId,
        limit: 30,
      );
      if (!mounted) return;
      final filtered = _filterExactMatches(results);
      setState(() {
        _searching = false;
        _searchResults = filtered;
        _selectedIndex = 0;
        // 精确过滤把结果全滤掉了：给用户一个「显示全部结果」的出口。
        _exactMatchBlocked =
            filtered.isEmpty && results.isNotEmpty && _exactMatchActive;
      });
      if (filtered.isNotEmpty) _selectCandidate(0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  /// 选中某个候选，并拉取它的歌词 / 年份。
  void _selectCandidate(int index) {
    if (index < 0 || index >= _searchResults.length) return;
    setState(() {
      _selectedIndex = index;
      _candidateLyric = null;
      _loadingCandidateLyric = true;
      _candidateYear = null;
      _useCandidateCover = true;
      _useCandidateInfo = true;
      _useCandidateLyric = true;
    });
    unawaited(_fetchCandidateLyric(_searchResults[index]));
    unawaited(_resolveCandidateYear(_searchResults[index]));
  }

  Future<void> _fetchCandidateLyric(Song candidate) async {
    String? lyric;
    try {
      // 用 getLyricResult：逐字歌词在 crlyric 里，getLyric 只会给整行时间轴。
      final result = await ref
          .read(musicSourceManagerProvider)
          .getLyricResult(candidate);
      final word = result?.crlyric?.trim() ?? '';
      final plain = result?.lrc?.trim() ?? '';
      lyric = word.isNotEmpty
          ? result!.crlyric
          : (plain.isNotEmpty ? plain : null);
    } catch (_) {
      lyric = null;
    }
    if (!mounted) return;
    // 期间又点了别的候选：丢弃这次结果。
    final current = _currentCandidate;
    if (current == null || current.id != candidate.id) return;
    setState(() {
      _candidateLyric = lyric;
      _loadingCandidateLyric = false;
    });
  }

  /// 补查候选的发行年份：搜索里带年份直接用，否则按专辑 id 查一次。
  Future<void> _resolveCandidateYear(Song candidate) async {
    final own = candidate.year;
    if (own != null && own > 0) {
      if (!mounted) return;
      setState(() => _candidateYear = own);
      return;
    }
    int? year;
    try {
      year = await ref
          .read(musicSourceManagerProvider)
          .resolveSongYear(candidate);
    } catch (_) {
      year = null;
    }
    if (!mounted) return;
    final current = _currentCandidate;
    if (current == null || current.id != candidate.id) return;
    setState(() => _candidateYear = year);
  }

  /// 搜索关键词：歌曲名 + 歌手名。
  static String _searchKeywordFor(Song song) {
    final title = song.title.trim();
    final artist = song.artist.trim();
    if (artist.isEmpty) return title;
    if (title.isEmpty) return artist;
    return '$title $artist';
  }

  /// 底部「使用」：把选中的匹配结果填进「编辑信息」并切过去。
  ///
  /// **不写歌曲文件**——这里只是把数据搬进编辑表单，用户确认后再点右上角
  /// 「保存到文件」才真正写盘。
  void _applySelected() {
    final candidate = _currentCandidate;
    final song = _song;
    if (candidate == null || song == null) return;

    setState(() {
      if (_useCandidateInfo) {
        if (candidate.title.trim().isNotEmpty) {
          _titleController.text = candidate.title;
        }
        if (candidate.artist.trim().isNotEmpty) {
          _artistController.text = candidate.artist;
        }
        if (candidate.album.trim().isNotEmpty) {
          _albumController.text = candidate.album;
        }
        final year = _candidateYear ?? candidate.year;
        if (year != null && year > 0) _yearController.text = year.toString();
        final genre = (candidate.genre ?? '').trim();
        if (genre.isNotEmpty) _genreController.text = genre;
      }
      if (_useCandidateCover) {
        final url = candidate.coverUrl ?? '';
        if (url.isNotEmpty) {
          // 网络封面先记下来：保存到文件时再下载并写进 APIC / PICTURE。
          _webCoverUrl = url;
          _song = song.copyWith(coverUrl: url, hasCover: true);
          _coverVersion++;
        }
      }
      if (_useCandidateLyric) {
        final lyric = _candidateLyric;
        if (lyric != null && lyric.trim().isNotEmpty) {
          _lrcController.text = lyric;
        }
      }
    });

    _tabController.animateTo(0);
    _toast(context.tr('已应用到编辑信息，点右上角「保存到文件」写入歌曲文件'));
  }

  Future<void> _handleSave() async {
    final song = _song;
    if (song == null) return;

    setState(() => _saving = true);

    try {
      final title = _titleController.text.trim();
      final artist = _artistController.text.trim();
      final album = _albumController.text.trim();
      final yearText = _yearController.text.trim();
      final genre = _genreController.text.trim();
      final comment = _commentController.text.trim();
      final lyric = _lrcController.text;
      final year = int.tryParse(yearText);
      final changed = _hasChanges;
      final coverUrl = _webCoverUrl;
      final path = song.filePath ?? '';

      // 网络封面要在写标签前先下载成图片，才能一起写进 APIC / PICTURE。
      Uint8List? artwork;
      if (changed || coverUrl != null) {
        if (coverUrl != null && path.isNotEmpty) {
          artwork = await _downloadImage(coverUrl);
        }
      }

      // 1) 有修改就必须写回音频文件（标题 / 歌手 / 专辑 / 年份 / 流派 / 注释 /
      //    歌词，以及从网络搜索带过来的封面）。清空的字段也一起删掉，
      //    别让旧标签留在文件里。
      var fileWritten = false;
      var fileSupported = false;
      if ((changed || artwork != null) && path.isNotEmpty) {
        fileSupported = AudioTagWriter.supports(path);
        if (fileSupported) {
          fileWritten = await AudioTagWriter.write(
            path,
            title: title,
            artist: artist,
            album: album,
            year: yearText,
            genre: genre,
            comment: comment,
            lyrics: lyric.trim(),
            artwork: artwork,
            removeEmptyFields: true,
          );
        }
      }

      // 2) 再更新曲库索引（整条覆盖：清空的字段也要清掉）。
      var updated = song.copyWith(
        title: title,
        artist: artist,
        album: album,
        year: year,
        clearYear: year == null,
        genre: genre,
        comment: comment,
        lrc: lyric.trim().isEmpty ? null : lyric.trim(),
        clearLrc: lyric.trim().isEmpty,
      );

      // 封面已经写进文件了：之后统一走本地封面缓存，不再依赖网络地址。
      if (fileWritten && artwork != null) {
        await CoverCacheService().putArtwork(song.id, artwork);
        MusicCoverImage.refresh(song.id);
        updated = updated.copyWith(hasCover: true, clearCover: true);
        _webCoverUrl = null;
        if (mounted) {
          setState(() {
            _song = updated;
            _coverVersion++;
          });
        }
      }

      await ref
          .read(localMusicNotifierProvider.notifier)
          .upsertSong(updated, forceOverwrite: true);

      if (mounted) {
        final String message;
        Color? background;
        if (!changed && artwork == null) {
          message = context.tr('标签已保存');
        } else if (fileWritten) {
          message = context.tr('标签已保存，并写入歌曲文件');
        } else if (path.isEmpty) {
          message = context.tr('标签已保存到曲库（找不到歌曲文件，未写入文件）');
          background = Colors.orange;
        } else {
          message = fileSupported
              ? context.tr('标签已保存到曲库，但写入歌曲文件失败')
              : context.tr('标签已保存到曲库，该音频格式暂不支持写入文件');
          background = Colors.orange;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 3),
            backgroundColor: background,
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('保存失败: $e')),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 下载网络封面，转成可写进标签的图片字节；失败返回 null。
  Future<Uint8List?> _downloadImage(String url) async {
    try {
      final response = await Dio().get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      return Uint8List.fromList(bytes);
    } catch (e) {
      debugPrint('[TagEditor] 下载封面失败: $e');
      return null;
    }
  }
}
