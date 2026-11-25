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
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/services/cover_cache_service.dart';
import '../../../shared/utils/song_field_display.dart';
import '../../../shared/utils/song_match_score.dart';
import '../../../shared/widgets/source_icon.dart';
import '../../../shared/widgets/source_selector_row.dart';
import '../../discover/application/search_providers.dart';
import '../../download/domain/services/audio_tag_writer.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';
import '../application/local_providers.dart';
import '../../player/application/lyric_controller.dart';
import '../../player/application/lyric_resolver.dart';
import '../../player/application/lyric_search_source_store.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/services/lyric_text_formatter.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../player/application/root_overlay_tracker.dart';
import '../data/local_metadata_reader.dart';
import '../domain/services/local_song_from_file.dart';
import 'match_widgets.dart';

class TagEditorPage extends ConsumerStatefulWidget {
  const TagEditorPage({
    super.key,
    this.songId,
    this.filePath,
    this.autoSearch = false,
  });

  final String? songId;

  /// 歌曲文件路径。
  ///
  /// 曲库里查不到这首歌时用它兜底：下载管理里播放的歌（文件在下载目录，
  /// 而下载目录通常不在「本地音乐」的扫描目录里）就属于这种情况，以前会
  /// 直接显示「未找到歌曲信息」。
  final String? filePath;

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

  /// 这首歌是不是曲库索引里的（扫描目录里的）。
  ///
  /// 下载管理播放的歌不在曲库索引里：改完标签只写文件，不往本地曲库里插一行，
  /// 否则「本地音乐」里会冒出一首其实不属于任何扫描目录的歌，下次重扫又消失。
  bool _inLibrary = true;

  /// 还在解析要编辑的歌曲：下载管理里的歌要现读文件标签，第一帧先别显示
  /// 「未找到歌曲信息」，否则会闪一下错误提示。
  bool _loadingSong = true;

  bool _saving = false;
  bool _searching = false;
  String? _searchError;
  List<Song> _searchResults = const <Song>[];

  /// 当前选中的候选（默认第一个）。
  int _selectedIndex = 0;
  String? _candidateLyric;
  bool _loadingCandidateLyric = false;
  int? _candidateYear;

  /// 当前候选歌词的拉取任务：在「在线搜索」里直接点保存时先等它回来。
  Future<void>? _candidateLyricFuture;

  /// 对比里每一项是否采用匹配结果：封面 / 歌曲信息 / 歌词。
  bool _useCandidateCover = true;
  bool _useCandidateInfo = true;
  bool _useCandidateLyric = true;

  /// 文件里歌名 + 歌手都有标签：搜索框拆成两个，结果按「精确匹配优先」
  /// 排序（匹配的排最前 / 最左，其余结果保持原顺序跟在后面，全部显示）。
  bool _splitSearchFields = false;

  /// 本次页面生命周期内是否已经搜过一次（自动 / 手动都算）。
  ///
  /// 切回「在线搜索」时据此决定要不要自动搜：搜过就保留现有结果和已选候选，
  /// 不重搜。
  bool _hasSearched = false;

  /// 是否已经安排过自动搜索（从快速匹配页进来 + 手动切到在线搜索共用）。
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

  /// 用户在本次会话里手动切换过音源：退出（dispose）时保存为「上次使用的
  /// 音源」（搜索歌词与在线搜索共用）；没切换过不保存。
  bool _sourceChanged = false;

  /// 上次使用的音源读取完成（搜索前必须等它，见 [_handleSearch]）。
  late final Future<void> _lastUsedSourceFuture = _loadLastUsedSource();

  /// 读取「上次使用的音源」，在当前可搜索音源列表里才采用。
  Future<void> _loadLastUsedSource() async {
    final last = await LyricSearchSourceStore.load();
    if (!mounted || last == null) return;
    final sources = ref.read(searchAvailableSourcesProvider);
    if (sources.any((source) => source.id == last)) {
      setState(() => _searchSourceId = last);
    }
  }

  /// 切换音源按钮的锚点，用于把菜单弹在按钮下方。
  final _sourceButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // 登记根级覆盖页状态（左侧栏封面 / 来源标签的「再点关闭」要用）。
    RootOverlayTracker.instance.retain(RootOverlayTracker.tagEditor);
    unawaited(_lastUsedSourceFuture);
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
      unawaited(_loadSong());
    });
  }

  /// 切到「在线搜索」时，用歌曲名 / 歌手输入框的**当前**内容重建关键词，
  /// 并在还没搜过时自动搜一次。
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

  /// 切到「在线搜索」时自动搜一次，省掉手动点搜索按钮。
  ///
  /// 只在本次页面还没搜过时触发：已有结果 / 已选候选时切回来不重搜，
  /// 避免把用户挑好的候选清掉；手动搜过（含搜不到结果）也不再自动搜。
  /// 从快速匹配页进来（`widget.autoSearch`）走的也是这里。
  void _maybeAutoSearch() {
    if (_autoSearchTriggered || _hasSearched) return;
    if (_song == null) return;
    // 歌名 / 歌手都空：没有可搜的关键词。
    if (_queryText().isEmpty) return;
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

  /// 加载要编辑的歌曲：先查曲库索引，查不到就用传进来的文件路径现读。
  Future<void> _loadSong() async {
    final songId = widget.songId;
    final repo = ref.read(localMusicRepositoryProvider);
    var song = (songId == null || songId.isEmpty)
        ? null
        : repo.getSongById(songId);
    var inLibrary = song != null;
    if (song == null) {
      // 下载管理里播放的歌：文件在下载目录，而下载目录通常不在「本地音乐」
      // 的扫描目录里，曲库索引里没有这一行。按路径现读标签，改完只写文件。
      song = await _songFromFilePath();
      if (song == null) {
        if (mounted) setState(() => _loadingSong = false);
        return;
      }
      inLibrary = false;
    }
    if (!mounted) return;
    _inLibrary = inLibrary;
    _applySongFields(song);
    _captureBaseline();
    // 索引里没有年份 / 歌词时，现读文件里的标签补上。
    _loadFileMetadata(song);
    if (widget.autoSearch) {
      _tabController.animateTo(1);
      _maybeAutoSearch();
    } else if (_tabController.index == 1) {
      // 用户抢在歌曲加载完之前就点了「在线搜索」：那时还没有歌名 / 歌手，
      // 自动搜索被跳过；这里补一次。
      _maybeAutoSearch();
    }
  }

  /// 用文件路径构造一个「临时」歌曲对象（不在曲库索引里）。
  Future<Song?> _songFromFilePath() =>
      buildLocalSongFromFile(widget.filePath ?? '');

  /// 把歌曲字段灌进各个输入框。
  void _applySongFields(Song song) {
    setState(() {
      _song = song;
      _loadingSong = false;
      _titleController.text = song.title;
      _artistController.text = song.artist;
      // 老索引可能存着「未知专辑」占位：编辑框里按空处理，避免把占位文案
      // 当成真实专辑再写回文件（用户看到的也是空，符合「没有专辑」）。
      _albumController.text = albumForEdit(song.album);
      _yearController.text = song.year?.toString() ?? '';
      _genreController.text = song.genre ?? '';
      _commentController.text = song.comment ?? '';
      _lrcController.text = song.lrc ?? '';
      // 搜索词带上歌手名，匹配更准。
      _searchController.text = _searchKeywordFor(song);
      _searchTitleController.text = song.title;
      _searchArtistController.text = song.artist;
      // 文件里歌名 + 歌手都有标签：搜索框拆成两个，结果按「精确匹配优先」
      // 排序显示。
      _splitSearchFields =
          !_isUnknownTitle(song.title) && !_isUnknownArtist(song.artist);
    });
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
        // 索引里缺歌名 / 歌手时用文件标签补（在线搜索按这两个字段把精确
        // 匹配的结果排到最前）。
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
    if (_sourceChanged) {
      unawaited(LyricSearchSourceStore.save(_searchSourceId));
    }
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
      backgroundColor: Colors.transparent,
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
                // 与侧栏「发现」的激活态一致：主题色调暗做底、文字用主题色。
                indicator: BoxDecoration(
                  color: activeChipColor(colors),
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                labelColor: colors.primary,
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
                // 与侧栏「发现」的激活态一致：主题色调暗做底、文字用主题色。
                decoration: _saving
                    ? BoxDecoration(
                        color: colors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                      )
                    : activeChipDecoration(
                        colors,
                        radius: AppRadius.full,
                        withBorder: true,
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
                          color: colors.primary,
                        ),
                      )
                    else
                      Icon(Icons.check, size: 16, color: colors.primary),
                    const SizedBox(width: 4),
                    Text(
                      context.tr('保存到文件'),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: colors.primary,
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
      if (_loadingSong) {
        return const Center(child: CircularProgressIndicator());
      }
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
    // 索引里的 hasCover 只反映「扫描时记录到有封面」。老索引（Android 端
    // 以前扫描根本不读文件标签）可能把它记成 false，而文件里其实有内嵌封面
    // ——这里把刚读出来的文件标签也算一个依据，避免有封面却显示「无封面」。
    final hasCover =
        song.coverUrl != null ||
        song.hasCover ||
        (_fileMeta?.artwork?.isNotEmpty ?? false);
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
                    // 缓存 / MediaStore 都取不到时，现场从音频文件里抽内嵌封面。
                    filePath: song.filePath,
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
    // WebM / WebA 这类容器放不下封面（规范不支持附件）：直接说明，
    // 别让用户选完图片才失败。
    if (!AudioTagWriter.supportsArtwork(path)) {
      _toast(context.tr('该音频格式不支持写入封面'));
      return;
    }

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
      if (_inLibrary) {
        await notifier.upsertSong(
          song.copyWith(hasCover: true, clearCover: true),
          // 封面信息要以文件为准：合并写入会保留旧的 coverUrl / hasCover，
          // 所以这里整条覆盖（传的就是索引里读出来的完整歌曲对象）。
          forceOverwrite: true,
        );
      }
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
    if (!AudioTagWriter.supportsArtwork(path)) {
      _toast(context.tr('该音频格式不支持删除封面'));
      return;
    }

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
      if (_inLibrary) {
        await notifier.upsertSong(
          song.copyWith(hasCover: false, clearCover: true),
          forceOverwrite: true,
        );
      }
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
          child: _buildSearchHeader(colors, sources, sourceId),
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
            // 与侧栏「发现」的激活态一致：主题色调暗做底、文字用主题色。
            style: FilledButton.styleFrom(
              backgroundColor: activeChipColor(colors),
              foregroundColor: colors.primary,
              disabledBackgroundColor: colors.surfaceVariant,
              disabledForegroundColor: colors.textHint,
              side: BorderSide(color: colors.primary.withValues(alpha: 0.5)),
            ),
            child: Text(context.tr('使用')),
          ),
        ],
      ),
    );
  }

  /// 搜索框与音源按钮共用的高度。
  static const double _searchBarHeight = 44;

  /// Windows：平铺全部可选音源，点哪个就切到哪个并立刻重新搜索。
  ///
  /// 与「单按钮 + 菜单」相比少一次点击；音源多时这一行可横向滚动。
  Widget _buildFlatSources(List<SourceInfo> sources, String currentId) {
    if (sources.isEmpty) return const SizedBox(width: _searchBarHeight);
    return SourceSelectorRow(
      sources: sources,
      selectedId: currentId,
      size: _searchBarHeight,
      onSelected: (id) {
        if (id == currentId) return;
        setState(() {
          _searchSourceId = id;
          _sourceChanged = true;
        });
        // 换音源后自动重新搜索一次（上次没结果也照样换源再搜）。
        unawaited(_handleSearch());
      },
    );
  }

  /// 搜索框右侧的音源按钮（非 Windows）：直接显示 [currentId] 这个音源的
  /// 图标，点开后再从菜单里选。
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
                // 传完整音源 id（带 @插件id）：插件自带图标时优先显示它，
                // 内置平台才退回彩色圆标。
                sourceId: current.id,
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
      color: colors.dialogSurface,
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
      setState(() {
        _searchSourceId = id;
        _sourceChanged = true;
      });
      // 换音源后自动重新搜索一次（上次没结果也照样换源再搜）。
      unawaited(_handleSearch());
    });
  }

  /// 搜索输入区。
  ///
  /// 文件里歌名 + 歌手都有标签时是「两个输入框各占一行」，右侧各配一个按钮
  /// ——两个框并排放在一行里时，手机宽度下每个只剩一百来像素，歌名稍长就
  /// 看不全，用户会以为输入框坏了。
  ///
  /// 布局与「搜索歌词」弹框保持一致：第一行歌曲名 + 搜索，第二行歌手名 +
  /// 音源；Windows 上音源直接平铺（点一下切源并重新搜索），其它平台是
  /// 单个音源按钮 + 弹出菜单。
  /// 只有一个关键词框时仍是一行：输入框 + 搜索 + 音源。
  Widget _buildSearchHeader(
    ThemeColors colors,
    List<SourceInfo> sources,
    String sourceId,
  ) {
    final flatSources = Platform.isWindows;

    if (_splitSearchFields) {
      return Column(
        children: [
          Row(
            children: [
              Expanded(
                child: _buildSearchInput(
                  colors,
                  controller: _searchTitleController,
                  hint: context.tr('歌曲'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _buildSearchButton(colors, sources),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _buildSearchInput(
                  colors,
                  controller: _searchArtistController,
                  hint: context.tr('歌手'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              if (flatSources)
                _buildFlatSources(sources, sourceId)
              else
                _buildSourceButton(colors, sources, sourceId),
            ],
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(
          child: _buildSearchInput(
            colors,
            controller: _searchController,
            icon: Icons.search,
            hint: context.tr('输入关键词搜索 (歌曲名 歌手)'),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        _buildSearchButton(colors, sources),
        const SizedBox(width: AppSpacing.sm),
        if (flatSources)
          _buildFlatSources(sources, sourceId)
        else
          _buildSourceButton(colors, sources, sourceId),
      ],
    );
  }

  Widget _buildSearchInput(
    ThemeColors colors, {
    required TextEditingController controller,
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
          // 有内容才显示清除按钮：用 ValueListenableBuilder 单独监听输入，
          // 不用整页 setState（以前只在别的操作触发重建时才冒出来）。
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(controller.clear),
                child: Padding(
                  padding: const EdgeInsets.only(left: AppSpacing.xs),
                  child: Icon(Icons.close, size: 18, color: colors.textHint),
                ),
              );
            },
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
        // 和音源按钮同一尺寸的圆形：两行输入框里各放一个，右边缘才能对齐。
        width: _searchBarHeight,
        height: _searchBarHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          // 与侧栏「发现」的激活态一致：主题色调暗做底、文字用主题色。
          color: enabled
              ? activeChipColor(colors)
              : activeChipColor(colors).withValues(alpha: 0.5),
          shape: BoxShape.circle,
        ),
        child: _searching
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            : Text(
                context.tr('搜索'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.primary,
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
          Icon(Icons.search, size: 48, color: colors.textHint),
          const SizedBox(height: AppSpacing.md),
          Text(
            keyword.isEmpty ? context.tr('输入关键词开始搜索') : context.tr('未找到相关结果'),
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

  /// 是否按「歌曲名 + 歌手」给结果排序（精确匹配的排前面）。
  bool get _exactMatchActive => _splitSearchFields;

  /// 匹配基准用编辑信息里的**当前**内容（改了歌名 / 歌手后对比的是改后的），
  /// 时长取曲库索引里记的（只展示与排序用，不参与写文件）。
  LocalSongMatchFields get _localMatchFields {
    final song = _song;
    return LocalSongMatchFields(
      title: _titleController.text,
      artist: _artistController.text,
      album: _albumController.text,
      year: int.tryParse(_yearController.text.trim()) ?? song?.year ?? 0,
      durationSeconds: song?.duration ?? 0,
    );
  }

  /// 按匹配优先级（1~12，五字段全中最高、其它最低）排到最前（横向列表的
  /// 左侧），同优先级保持原顺序——不隐藏任何结果，交给用户自己判断。
  /// 定级规则见共享的 [songMatchPriority] / [sortSongsByMatchLevel]。
  List<Song> _sortExactMatchesFirst(List<Song> results) {
    if (!_exactMatchActive) return results;
    return sortSongsByMatchLevel(results, _localMatchFields);
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
      // 「原歌曲」卡片同样要能显示文件里的内嵌封面（老索引可能记成 false）。
      hasCover: song.hasCover || (_fileMeta?.artwork?.isNotEmpty ?? false),
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
    // 「上次使用的音源」是异步读的：任何搜索（含进页自动搜索）都等它应用
    // 完，否则这次搜索会退回「跟随当前音源」。
    try {
      await _lastUsedSourceFuture;
    } catch (_) {
      // 读偏好失败不影响搜索：按「跟随当前音源」继续。
    }
    final keyword = _queryText();
    if (keyword.isEmpty || _searching) return;
    _lastSearchKeyword = keyword;
    // 本次页面已经搜过：之后切回「在线搜索」不再自动重搜。
    _hasSearched = true;

    setState(() {
      _searching = true;
      _searchError = null;
      _searchResults = const <Song>[];
      _selectedIndex = 0;
      _candidateLyric = null;
      _candidateLyricFuture = null;
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
      final sorted = _sortExactMatchesFirst(results);
      setState(() {
        _searching = false;
        _searchResults = sorted;
        _selectedIndex = 0;
      });
      if (sorted.isNotEmpty) _selectCandidate(0);
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
    final lyricFuture = _fetchCandidateLyric(_searchResults[index]);
    _candidateLyricFuture = lyricFuture;
    unawaited(lyricFuture);
    unawaited(_resolveCandidateYear(_searchResults[index]));
  }

  Future<void> _fetchCandidateLyric(Song candidate) async {
    String? lyric;
    try {
      // 与播放页 / 搜索歌词弹框走同一个竞速取词入口（TTML 词库 + 音源歌词
      // 并发，谁先给出逐字歌词就用谁）：同一首歌在这里拿到的格式与翻译，
      // 和播放页显示的完全一致。
      // 写进文件时统一成「逐字增强 LRC + 同时间戳译文行」，见 LyricTextFormatter。
      final result = await ref
          .read(lyricResolverProvider)
          .resolveRacing(candidate);
      final text = result == null ? '' : LyricTextFormatter.fromResult(result);
      lyric = text.isEmpty ? null : text;
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

  /// 把选中的匹配结果填进「编辑信息」表单（不写文件、不切页签）。
  ///
  /// 底部「使用」和右上角「保存到文件」共用这一套：后者在「在线搜索」里
  /// 直接保存时先应用选中结果，再走正常的写盘流程。
  bool _applyCandidateToFields() {
    final candidate = _currentCandidate;
    final song = _song;
    if (candidate == null || song == null) return false;

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
    return true;
  }

  /// 底部「使用」：应用选中结果并切回「编辑信息」。
  ///
  /// 这里不写歌曲文件，用户确认后再点右上角「保存到文件」才真正写盘。
  void _applySelected() {
    if (!_applyCandidateToFields()) return;
    _tabController.animateTo(0);
    _toast(context.tr('已应用到编辑信息，点右上角「保存到文件」写入歌曲文件'));
  }

  Future<void> _handleSave() async {
    final song = _song;
    if (song == null || _saving) return;

    setState(() => _saving = true);

    try {
      // 在「在线搜索」里选中了匹配结果、没点底部「使用」就直接保存：
      // 先把选中结果应用进表单，再和普通保存走同一条写文件流程。
      if (_tabController.index == 1 && _currentCandidate != null) {
        final pending = _candidateLyricFuture;
        if (_useCandidateLyric && pending != null) {
          await pending;
        }
        if (!mounted) return;
        _applyCandidateToFields();
      }

      final title = _titleController.text.trim();
      final artist = _artistController.text.trim();
      final album = _albumController.text.trim();
      final yearText = _yearController.text.trim();
      final genre = _genreController.text.trim();
      final comment = _commentController.text.trim();
      final lyric = _lrcController.text;
      final lyricChanged = lyric.trim() != _baseLrc.trim();
      final year = int.tryParse(yearText);
      final changed = _hasChanges;
      final coverUrl = _webCoverUrl;
      final path = song.filePath ?? '';

      // 网络封面要在写标签前先下载成图片，才能一起写进 APIC / PICTURE。
      // WebM / WebA 放不下封面（规范不支持附件）：跳过下载，最后给一句
      // 提示，别让用户以为封面写进文件了。
      final canStoreArtwork = AudioTagWriter.supportsArtwork(path);
      final coverSkipped = coverUrl != null && !canStoreArtwork;
      Uint8List? artwork;
      if (changed || coverUrl != null) {
        if (coverUrl != null && path.isNotEmpty && canStoreArtwork) {
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
      //
      // 歌词不写进索引：本地歌曲的歌词只有一个来源——歌曲文件。索引里留一份
      // 会盖住文件（`LyricController.loadLyrics` 先看 `song.lrc`，为空才读
      // 文件），文件被外部工具改过、或者这次没能写进文件时，界面就会显示
      // 过期内容。只有「这次没写进文件」（aac / ogg 等不支持内嵌的格式 / 只读文件）
      // 才把这份留在内存里当本次会话的兜底 —— 它本来也不落盘。
      var updated = song.copyWith(
        title: title,
        artist: artist,
        album: album,
        year: year,
        clearYear: year == null,
        genre: genre,
        comment: comment,
        clearLrc: true,
      );
      if (!fileWritten && lyric.trim().isNotEmpty) {
        updated = updated.copyWith(lrc: lyric.trim());
      }

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

      // 曲库索引里的歌才回写索引。下载管理里的歌（不在扫描目录）只改文件：
      // 往索引里插一行会让「本地音乐」多出一首并不属于任何扫描目录的歌，
      // 下次重扫又消失。
      if (_inLibrary) {
        await ref
            .read(localMusicNotifierProvider.notifier)
            .upsertSong(updated, forceOverwrite: true);
      } else if (mounted) {
        setState(() => _song = updated);
      }

      // 歌词改过：歌词缓存会盖住刚写入文件的新歌词，必须用新内容刷新；
      // 正在播放这首歌时顺带立即重新解析。
      if (lyricChanged) {
        await ref
            .read(lyricControllerProvider.notifier)
            .onLyricsWritten(updated);
      }

      if (mounted) {
        final String message;
        Color? background;
        if (fileWritten && coverSkipped) {
          message = context.tr('标签已写入歌曲文件，该格式不支持内嵌封面，封面已跳过');
          background = Colors.orange;
        } else if (!changed && artwork == null) {
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
