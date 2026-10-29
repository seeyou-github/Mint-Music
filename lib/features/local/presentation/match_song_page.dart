import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/source_icon.dart';
import '../../discover/application/search_providers.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../data/local_metadata_reader.dart';
import '../domain/local_song_filter.dart';
import 'widgets/accurate_match_sheet.dart';

/// 「快速匹配」的匹配界面（整页）。
///
/// 结构：顶部输入框 + 搜索 / 音源按钮 → 横向候选列表（默认选中第一个）→
/// 「原歌曲 / 选中的匹配结果」三行对比（封面、歌曲信息、歌词）→ 底部取消 / 保存。
class MatchSongPage extends ConsumerStatefulWidget {
  const MatchSongPage({super.key, required this.song});

  /// 要匹配的本地歌曲。
  final Song song;

  /// 打开匹配界面（整页推入，返回后由列表自己刷新）。
  static Future<void> show(BuildContext context, Song song) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => MatchSongPage(song: song),
      ),
    );
  }

  @override
  ConsumerState<MatchSongPage> createState() => _MatchSongPageState();
}

class _MatchSongPageState extends ConsumerState<MatchSongPage> {
  final TextEditingController _queryController = TextEditingController();
  final ScrollController _resultScrollController = ScrollController();

  /// 当前搜索音源（空串表示音源列表还没就绪）。
  String _sourceId = '';

  List<Song> _results = const <Song>[];
  int _selectedIndex = 0;
  bool _searching = false;
  bool _searched = false;
  String? _searchError;

  /// 选中候选的歌词（优先逐字歌词）。
  String? _candidateLyric;
  bool _loadingLyric = false;

  /// 原歌曲文件里的标签（扫描时只存了部分字段，这里现读一次）。
  LocalAudioMetadata? _originalMeta;

  /// 每一项是否采用匹配结果：封面 / 歌曲信息 / 歌词。
  bool _useCandidateCover = true;
  bool _useCandidateInfo = true;
  bool _useCandidateLyric = true;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _queryController.text = _initialKeyword(widget.song);
    // 输入框里的清空按钮与搜索按钮要跟着内容变。
    _queryController.addListener(_onQueryChanged);
    _loadOriginalMetadata();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _ensureSourceAndSearch(),
    );
  }

  void _onQueryChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _queryController.removeListener(_onQueryChanged);
    _queryController.dispose();
    _resultScrollController.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------ 初始数据

  /// 搜索词：文件内嵌的「歌名 + 歌手」，没有就退回到文件名。
  String _initialKeyword(Song song) {
    final title = song.title.trim();
    final artist = song.artist.trim();
    final unknownTitle = title.isEmpty || title == '未知曲目';
    final unknownArtist =
        artist.isEmpty || artist == '未知艺术家' || artist == '未知歌手';
    if (!unknownTitle && !unknownArtist) return '$title $artist';
    if (!unknownTitle) return title;
    final path = song.filePath ?? '';
    return filenameKeyword(path.isEmpty ? song.title : path);
  }

  Future<void> _loadOriginalMetadata() async {
    final path = widget.song.filePath;
    if (path == null || path.isEmpty) return;
    try {
      final metadata = await LocalMetadataReader.read(path);
      if (!mounted) return;
      setState(() => _originalMeta = metadata);
    } catch (_) {
      // 读不到就只用歌曲自己的字段。
    }
  }

  /// 等音源列表就绪后选默认音源并自动搜索一次。
  void _ensureSourceAndSearch() {
    if (!mounted || _searching || _searched) return;
    final sources = ref.read(searchAvailableSourcesProvider);
    if (sources.isEmpty) return;
    final sourceId = _resolvedSourceId(sources);
    setState(() => _sourceId = sourceId);
    unawaited(_search(sourceId));
  }

  /// 当前音源优先：用户选的 > 默认音源 > 列表第一个。
  String _resolvedSourceId(List<SourceInfo> sources) {
    if (sources.any((source) => source.id == _sourceId)) return _sourceId;
    final current = ref.read(defaultSourceIdProvider);
    if (sources.any((source) => source.id == current)) return current;
    return sources.first.id;
  }

  // ------------------------------------------------------------ 搜索

  Future<void> _search(String sourceId) async {
    final query = _queryController.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _results = const <Song>[];
      _selectedIndex = 0;
      _candidateLyric = null;
    });
    List<Song> results;
    try {
      results = await ref
          .read(musicSourceManagerProvider)
          .search(query, sourceId: sourceId, limit: 30);
    } catch (e) {
      if (!mounted || sourceId != _sourceId) return;
      setState(() {
        _searching = false;
        _searched = true;
        _searchError = '$e';
      });
      return;
    }
    // 搜索期间又换了音源 / 改了关键词：这次结果已经过时。
    if (!mounted || sourceId != _sourceId) return;
    setState(() {
      _results = results;
      _searching = false;
      _searched = true;
    });
    if (results.isNotEmpty) {
      _selectCandidate(0);
    }
  }

  void _switchSource(String sourceId) {
    if (!mounted || sourceId == _sourceId) return;
    setState(() {
      _sourceId = sourceId;
      _searched = false;
    });
    unawaited(_search(sourceId));
  }

  /// 选中某个候选，并拉取它的歌词。
  void _selectCandidate(int index) {
    if (index < 0 || index >= _results.length) return;
    setState(() {
      _selectedIndex = index;
      _candidateLyric = null;
      _loadingLyric = true;
      _useCandidateCover = true;
      _useCandidateInfo = true;
      _useCandidateLyric = true;
    });
    unawaited(_fetchCandidateLyric(_results[index]));
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
      _loadingLyric = false;
    });
  }

  Song? get _currentCandidate {
    if (_results.isEmpty) return null;
    if (_selectedIndex < 0 || _selectedIndex >= _results.length) return null;
    return _results[_selectedIndex];
  }

  // ------------------------------------------------------------ 对比与保存

  /// 原歌曲的展示字段：歌曲字段优先，缺的用文件标签补。
  Song get _original {
    final song = widget.song;
    final meta = _originalMeta;
    if (meta == null) return song;
    return song.copyWith(
      title: song.title.trim().isEmpty ? meta.title : null,
      artist: (song.artist.trim().isEmpty || song.artist == '未知艺术家')
          ? meta.artist
          : null,
      album: (song.album.trim().isEmpty || song.album == '未知专辑')
          ? meta.album
          : null,
      year: song.year ?? meta.year,
      genre: song.genre ?? meta.genre,
      comment: song.comment ?? meta.comment,
    );
  }

  String? get _originalLyric {
    final lrc = widget.song.lrc?.trim() ?? '';
    if (lrc.isNotEmpty) return widget.song.lrc;
    final embedded = _originalMeta?.lyrics?.trim() ?? '';
    return embedded.isEmpty ? null : _originalMeta!.lyrics;
  }

  Song _merged(Song original, Song candidate) {
    final lyric =
        _useCandidateLyric && (_candidateLyric ?? '').trim().isNotEmpty
        ? _candidateLyric
        : _originalLyric;

    final title = _useCandidateInfo && candidate.title.trim().isNotEmpty
        ? candidate.title
        : original.title;
    final artist = _useCandidateInfo && candidate.artist.trim().isNotEmpty
        ? candidate.artist
        : original.artist;
    final album = _useCandidateInfo && candidate.album.trim().isNotEmpty
        ? candidate.album
        : original.album;
    final year = _useCandidateInfo
        ? (candidate.year ?? original.year)
        : original.year;

    final useCover = _useCandidateCover;
    final coverUrl = useCover ? candidate.coverUrl : original.coverUrl;

    return original.copyWith(
      title: title,
      artist: artist,
      album: album,
      year: year,
      coverUrl: coverUrl,
      hasCover: (coverUrl ?? '').isNotEmpty || original.hasCover,
      lrc: lyric,
      hasLyric: (lyric ?? '').trim().isNotEmpty,
      hasWordLyric: isWordLyricText(lyric),
      // 流派 / 注释只在原歌曲缺失时用匹配结果补上（匹配结果通常没有这两项）。
      genre: original.genre ?? candidate.genre,
      comment: original.comment ?? candidate.comment,
    );
  }

  Future<void> _save() async {
    final candidate = _currentCandidate;
    if (candidate == null || _saving) return;
    setState(() => _saving = true);
    try {
      await applyAccurateMatchResult(
        context,
        ref,
        _merged(_original, candidate),
      );
      if (!mounted) return;
      Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ------------------------------------------------------------ UI

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final sources = ref.watch(searchAvailableSourcesProvider);
    final pluginReady = ref.watch(pluginInitializedProvider).hasValue;
    if (!_searching && !_searched && sources.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureSourceAndSearch(),
      );
    }
    final candidate = _currentCandidate;

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(colors),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: _buildSearchRow(colors, sources),
            ),
            const SizedBox(height: AppSpacing.md),
            if (candidate != null) _buildCandidateStrip(colors),
            if (candidate != null) const SizedBox(height: AppSpacing.md),
            Expanded(
              child: _buildCompareArea(
                colors,
                candidate,
                pluginReady: pluginReady,
              ),
            ),
            _buildBottomBar(colors, candidate),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.tr('匹配歌曲信息'),
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.close, color: colors.textHint),
            tooltip: context.tr('取消'),
          ),
        ],
      ),
    );
  }

  /// 顶部一行：输入框 + 搜索按钮 + 音源切换按钮。
  Widget _buildSearchRow(ThemeColors colors, List<SourceInfo> sources) {
    return Row(
      children: [
        Expanded(
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Row(
              children: [
                const SizedBox(width: AppSpacing.md),
                Icon(Icons.search, size: 20, color: colors.textHint),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    style: TextStyle(fontSize: 14, color: colors.textPrimary),
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) {
                      if (_sourceId.isNotEmpty) unawaited(_search(_sourceId));
                    },
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: context.tr('输入歌名 / 歌手搜索'),
                      hintStyle: TextStyle(
                        fontSize: 14,
                        color: colors.textHint,
                      ),
                    ),
                  ),
                ),
                if (_queryController.text.isNotEmpty)
                  GestureDetector(
                    onTap: () => setState(_queryController.clear),
                    child: Icon(Icons.cancel, size: 18, color: colors.textHint),
                  ),
                const SizedBox(width: AppSpacing.sm),
              ],
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        _buildSearchButton(colors, sources),
        const SizedBox(width: AppSpacing.sm),
        _buildSourceButton(colors, sources),
      ],
    );
  }

  Widget _buildSearchButton(ThemeColors colors, List<SourceInfo> sources) {
    final enabled = sources.isNotEmpty && !_searching;
    return GestureDetector(
      onTap: enabled ? () => unawaited(_search(_sourceId)) : null,
      child: Container(
        height: 44,
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

  /// 右上角的音源切换按钮（显示当前音源图标，点击弹出音源列表）。
  Widget _buildSourceButton(ThemeColors colors, List<SourceInfo> sources) {
    final currentId = sources.isEmpty ? _sourceId : _resolvedSourceId(sources);
    SourceInfo? current;
    for (final source in sources) {
      if (source.id == currentId) {
        current = source;
        break;
      }
    }
    return Tooltip(
      message: current?.name ?? context.tr('切换音源'),
      child: PopupMenuButton<String>(
        enabled: sources.isNotEmpty,
        tooltip: '',
        color: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        onSelected: _switchSource,
        itemBuilder: (_) => [
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
                      ),
                    ),
                  ),
                  if (source.id == currentId)
                    Icon(Icons.check, size: 16, color: colors.primary),
                ],
              ),
            ),
        ],
        child: Container(
          width: 44,
          height: 44,
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
              : SourceIcon(sourceId: current.id, size: 44, label: current.name),
        ),
      ),
    );
  }

  /// 横向候选列表（桌面端可鼠标左右拖动），默认选中第一个。
  Widget _buildCandidateStrip(ThemeColors colors) {
    return SizedBox(
      height: 96,
      child: ScrollConfiguration(
        behavior: const _DragScrollBehavior(),
        child: ListView.separated(
          controller: _resultScrollController,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          itemCount: _results.length,
          separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
          itemBuilder: (context, index) {
            final song = _results[index];
            final selected = index == _selectedIndex;
            return _CandidateCard(
              song: song,
              selected: selected,
              colors: colors,
              onTap: () => _selectCandidate(index),
            );
          },
        ),
      ),
    );
  }

  Widget _buildCompareArea(
    ThemeColors colors,
    Song? candidate, {
    required bool pluginReady,
  }) {
    if (_searching) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!pluginReady) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_searchError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Text(
            context.tr('搜索失败: $_searchError'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textHint),
          ),
        ),
      );
    }
    if (candidate == null) {
      return Center(
        child: Text(
          context.tr('未找到匹配结果'),
          style: TextStyle(color: colors.textHint),
        ),
      );
    }

    final original = _original;
    final width = MediaQuery.sizeOf(context).width;
    final sideBySide = width >= 760;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCompareRow(
            colors,
            sideBySide: sideBySide,
            useCandidate: _useCandidateCover,
            onSelect: (use) => setState(() => _useCandidateCover = use),
            originalChild: _CoverPreview(
              colors: colors,
              song: original,
              size: 132,
            ),
            candidateChild: _CoverPreview(
              colors: colors,
              song: candidate,
              size: 132,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _buildCompareRow(
            colors,
            sideBySide: sideBySide,
            useCandidate: _useCandidateInfo,
            onSelect: (use) => setState(() => _useCandidateInfo = use),
            originalChild: _InfoPreview(colors: colors, song: original),
            candidateChild: _InfoPreview(colors: colors, song: candidate),
          ),
          const SizedBox(height: AppSpacing.md),
          _buildCompareRow(
            colors,
            sideBySide: sideBySide,
            useCandidate: _useCandidateLyric,
            onSelect: (use) => setState(() => _useCandidateLyric = use),
            originalChild: _LyricPreview(
              colors: colors,
              text: _originalLyric,
              loading: false,
              emptyText: context.tr('原歌曲没有歌词'),
            ),
            candidateChild: _LyricPreview(
              colors: colors,
              text: _candidateLyric,
              loading: _loadingLyric,
              emptyText: context.tr('匹配结果没有歌词'),
            ),
          ),
        ],
      ),
    );
  }

  /// 一行对比：左「原歌曲」，右「匹配结果」，点哪张选中哪张。
  Widget _buildCompareRow(
    ThemeColors colors, {
    required bool sideBySide,
    required bool useCandidate,
    required ValueChanged<bool> onSelect,
    required Widget originalChild,
    required Widget candidateChild,
  }) {
    final originalBox = _CompareSideBox(
      colors: colors,
      title: context.tr('原歌曲'),
      selected: !useCandidate,
      onTap: () => onSelect(false),
      child: originalChild,
    );
    final candidateBox = _CompareSideBox(
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

  Widget _buildBottomBar(ThemeColors colors, Song? candidate) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.divider)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          FilledButton(
            onPressed: candidate == null || _saving ? null : _save,
            child: _saving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.textOnPrimary,
                    ),
                  )
                : Text(context.tr('保存')),
          ),
        ],
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

/// 对比里的一侧（可点击选中）。
class _CompareSideBox extends StatelessWidget {
  const _CompareSideBox({
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
                  if (selected)
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
  const _CoverPreview({
    required this.colors,
    required this.song,
    required this.size,
  });

  final ThemeColors colors;
  final Song song;
  final double size;

  @override
  Widget build(BuildContext context) {
    final hasRemote = (song.coverUrl ?? '').isNotEmpty;
    if (!hasRemote && !song.hasCover) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          width: size,
          height: size,
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
          width: size,
          height: size,
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

/// 歌曲信息预览（歌曲 / 歌手 / 专辑 / 年份 / 流派）。
class _InfoPreview extends StatelessWidget {
  const _InfoPreview({required this.colors, required this.song});

  final ThemeColors colors;
  final Song song;

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
        field(context.tr('年份'), song.year?.toString() ?? ''),
        field(context.tr('流派'), song.genre ?? ''),
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
