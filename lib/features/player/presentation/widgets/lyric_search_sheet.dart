import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../../shared/widgets/music_cover_image.dart';
import '../../../../shared/widgets/source_icon.dart';
import '../../../plugin/application/music_source_manager.dart';
import '../../../plugin/application/plugin_providers.dart';
import '../../../plugin/domain/plugin_types.dart';
import '../../application/lyric_controller.dart';
import '../../application/playback_controller.dart';
import '../../domain/models/lyric_line.dart';
import '../../domain/models/song.dart';
import 'lyric_scroll_view.dart';

/// 打开「搜索歌词」弹层。
///
/// 找不到歌词时可以换音源、手动改歌名 / 歌手重新搜；搜到的结果能直接预览，
/// 预览跟着当前播放进度走，也可以手动滚动。
Future<void> showLyricSearchSheet(BuildContext context, {required Song song}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 220),
      reverseDuration: Duration(milliseconds: 180),
    ),
    builder: (ctx) => _LyricSearchSheet(song: song),
  );
}

class _LyricSearchSheet extends ConsumerStatefulWidget {
  const _LyricSearchSheet({required this.song});

  final Song song;

  @override
  ConsumerState<_LyricSearchSheet> createState() => _LyricSearchSheetState();
}

class _LyricSearchSheetState extends ConsumerState<_LyricSearchSheet> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _artistController = TextEditingController();

  String _sourceId = 'wy';
  List<Song> _results = const [];
  bool _searching = false;
  String? _searchError;

  int _selectedIndex = -1;
  List<LyricLine> _previewLines = const [];
  LyricResult? _previewResult;
  bool _loadingPreview = false;
  String? _previewError;

  @override
  void initState() {
    super.initState();
    _titleController.text = widget.song.title;
    _artistController.text = widget.song.artist;
    _sourceId = _initialSourceId();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_search());
    });
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  /// 默认用当前歌曲的音源（优先插件变体），列表里没有就退到平台 / 第一个可选音源。
  String _initialSourceId() {
    final sources = ref.read(searchSupportedSourcesProvider);
    if (sources.isEmpty) return widget.song.source ?? 'wy';
    final current = widget.song.preferredSource?.trim().isNotEmpty ?? false
        ? widget.song.preferredSource!.trim()
        : (widget.song.source ?? '').trim();
    if (current.isNotEmpty) {
      final exact = sources.where((s) => s.id == current).firstOrNull;
      if (exact != null) return exact.id;
      final base = MusicSourceManager.splitSourceId(current).$1;
      final sameBase = sources.where((s) => s.id == base).firstOrNull;
      if (sameBase != null) return sameBase.id;
    }
    return sources.first.id;
  }

  String get _keyword {
    final title = _titleController.text.trim();
    final artist = _artistController.text.trim();
    return [title, artist].where((e) => e.isNotEmpty).join(' ');
  }

  /// 用当前音源 + 歌名 / 歌手搜索候选歌曲。
  Future<void> _search() async {
    final keyword = _keyword;
    if (keyword.isEmpty || _searching) return;
    setState(() {
      _searching = true;
      _searchError = null;
      _results = const [];
      _selectedIndex = -1;
      _previewLines = const [];
      _previewResult = null;
      _previewError = null;
    });
    try {
      final songs = await ref
          .read(musicSourceManagerProvider)
          .search(keyword, sourceId: _sourceId, limit: 20);
      if (!mounted) return;
      final filtered = songs
          .where((s) => s.title.trim().isNotEmpty)
          .toList(growable: false);
      setState(() {
        _results = filtered;
        _searching = false;
        _searchError = filtered.isEmpty ? context.tr('没有搜到相关歌曲') : null;
      });
      if (filtered.isNotEmpty) unawaited(_selectResult(0));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = context.tr('搜索失败：$e');
      });
    }
  }

  /// 选中某个候选，拉取并解析它的歌词用于预览。
  Future<void> _selectResult(int index) async {
    if (index < 0 || index >= _results.length) return;
    setState(() {
      _selectedIndex = index;
      _loadingPreview = true;
      _previewError = null;
      _previewLines = const [];
      _previewResult = null;
    });
    try {
      final result = await ref
          .read(musicSourceManagerProvider)
          .getLyricResult(_results[index]);
      if (!mounted || _selectedIndex != index) return;
      final lines = result == null
          ? const <LyricLine>[]
          : buildLyricLinesFrom(result);
      setState(() {
        _loadingPreview = false;
        _previewResult = lines.isEmpty ? null : result;
        _previewLines = lines;
        _previewError = lines.isEmpty ? context.tr('这首歌没有歌词') : null;
      });
    } catch (e) {
      if (!mounted || _selectedIndex != index) return;
      setState(() {
        _loadingPreview = false;
        _previewError = context.tr('歌词加载失败：$e');
      });
    }
  }

  /// 使用预览里的这份歌词：立即生效并写入缓存，下次播放直接命中。
  Future<void> _applyPreview() async {
    final result = _previewResult;
    if (result == null) return;
    final messenger = ScaffoldMessenger.of(context);
    // 弹层开着的时候可能已经自动切歌了，这份歌词就对不上了。
    final current = ref.read(playbackControllerProvider).currentSong;
    final sameSong =
        current != null &&
        current.id == widget.song.id &&
        current.source == widget.song.source;
    if (!sameSong) {
      final switched = context.tr('歌曲已切换，请重新搜索歌词');
      Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(switched),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    final message = context.tr('已使用这份歌词');
    await ref
        .read(lyricControllerProvider.notifier)
        .applyManualLyric(widget.song, result);
    if (!mounted) return;
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final viewInsets = MediaQuery.viewInsetsOf(context);
    final available = MediaQuery.sizeOf(context).height - viewInsets.bottom;
    final sheetHeight = available * 0.9;
    return Padding(
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: Container(
        height: sheetHeight,
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(AppRadius.lg),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              _buildHeader(colors),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.sm,
                ),
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final fields = [
                      _buildField(
                        colors,
                        controller: _titleController,
                        hint: context.tr('歌曲名'),
                        icon: Icons.music_note,
                      ),
                      _buildField(
                        colors,
                        controller: _artistController,
                        hint: context.tr('歌手名'),
                        icon: Icons.person_outline,
                      ),
                    ];
                    if (constraints.maxWidth < 520) {
                      return Column(
                        children: [
                          fields[0],
                          const SizedBox(height: AppSpacing.sm),
                          fields[1],
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(flex: 3, child: fields[0]),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(flex: 2, child: fields[1]),
                      ],
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Row(
                  children: [
                    _buildSourcePicker(colors),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: _buildSearchButton(colors),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.sm),
              _buildResults(colors),
              const Divider(height: 1),
              Expanded(child: _buildPreview(colors)),
              _buildFooter(colors),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              context.tr('搜索歌词'),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 20, color: colors.textHint),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildField(
    ThemeColors colors, {
    required TextEditingController controller,
    required String hint,
    required IconData icon,
  }) {
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => unawaited(_search()),
      style: TextStyle(fontSize: 14, color: colors.textPrimary),
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: TextStyle(fontSize: 14, color: colors.textHint),
        prefixIcon: Icon(icon, size: 18, color: colors.textHint),
        prefixIconConstraints: const BoxConstraints(minWidth: 36),
        filled: true,
        fillColor: colors.surfaceVariant,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 10,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }

  Widget _buildSourcePicker(ThemeColors colors) {
    final sources = ref.watch(searchSupportedSourcesProvider);
    if (sources.isEmpty) return const SizedBox.shrink();
    final selected = sources.where((s) => s.id == _sourceId).firstOrNull;
    final label = selected?.name ?? _sourceId;
    return PopupMenuButton<String>(
      tooltip: context.tr('切换音源'),
      color: colors.surface,
      position: PopupMenuPosition.under,
      onSelected: (value) {
        if (value == _sourceId) return;
        setState(() => _sourceId = value);
        unawaited(_search());
      },
      itemBuilder: (context) => [
        for (final source in sources)
          PopupMenuItem<String>(
            value: source.id,
            height: 40,
            child: Row(
              children: [
                SourceIcon(sourceId: source.id, size: 16, label: source.name),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    source.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: source.id == _sourceId
                          ? colors.primary
                          : colors.textPrimary,
                      fontWeight: source.id == _sourceId
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (source.id == _sourceId)
                  Icon(Icons.check, size: 16, color: colors.primary),
              ],
            ),
          ),
      ],
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: colors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.dns_outlined, size: 14, color: colors.textHint),
            const SizedBox(width: AppSpacing.xs),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textSecondary),
              ),
            ),
            Icon(Icons.arrow_drop_down, size: 16, color: colors.textHint),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchButton(ThemeColors colors) {
    return GestureDetector(
      onTap: _searching ? null : () => unawaited(_search()),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 7,
        ),
        decoration: BoxDecoration(
          color: _searching ? colors.surfaceVariant : colors.primary,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_searching)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.textHint,
                ),
              )
            else
              Icon(Icons.search, size: 14, color: colors.textOnPrimary),
            const SizedBox(width: AppSpacing.xs),
            Text(
              context.tr(_searching ? '搜索中' : '搜索'),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: _searching ? colors.textHint : colors.textOnPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 候选歌曲：横向卡片，选中项用主色描边。
  Widget _buildResults(ThemeColors colors) {
    if (_searching && _results.isEmpty) {
      return const SizedBox(height: 12);
    }
    if (_results.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.xs,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            _searchError ?? context.tr('按歌名 / 歌手搜索歌词'),
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
        ),
      );
    }
    return SizedBox(
      height: 62,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        itemCount: _results.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
        itemBuilder: (context, index) {
          final song = _results[index];
          final selected = index == _selectedIndex;
          return GestureDetector(
            onTap: () => unawaited(_selectResult(index)),
            child: Container(
              width: 210,
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(
                  color: selected ? colors.primary : Colors.transparent,
                ),
              ),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: SizedBox(
                      width: 40,
                      height: 40,
                      child: MusicCoverImage(
                        url: song.coverUrl,
                        songId: song.id,
                        mediaStoreId: song.mediaStoreId,
                        fit: BoxFit.cover,
                        errorWidget: Icon(
                          Icons.music_note,
                          size: 18,
                          color: colors.textHint,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: selected
                                ? colors.primary
                                : colors.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: colors.textHint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// 歌词预览：跟随当前播放进度，也可以手动滚动。
  Widget _buildPreview(ThemeColors colors) {
    if (_loadingPreview) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_previewLines.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
          child: Text(
            _previewError ?? context.tr('选择上面的搜索结果预览歌词'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: colors.textHint),
          ),
        ),
      );
    }
    final position = ref.watch(
      playbackControllerProvider.select((s) => s.position),
    );
    final isPlaying = ref.watch(
      playbackControllerProvider.select((s) => s.isPlaying),
    );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: LyricScrollView(
        lines: _previewLines,
        currentTimeMs: position.inMilliseconds,
        isPlaying: isPlaying,
        hasYrc: _previewLines.any((line) => line.isYrc),
        activeColor: colors.primary,
        inactiveColor: colors.textHint,
        mainFontSize: 18,
        transFontSize: 13,
        romanFontSize: 11,
        fontSizeRate: 1,
        enableBlur: false,
        enableScale: true,
        centerAlign: true,
      ),
    );
  }

  Widget _buildFooter(ThemeColors colors) {
    final enabled = _previewResult != null && !_loadingPreview;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: SizedBox(
        width: double.infinity,
        child: GestureDetector(
          onTap: enabled ? () => unawaited(_applyPreview()) : null,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 11),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: enabled ? colors.primary : colors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppRadius.full),
            ),
            child: Text(
              context.tr('使用这份歌词'),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: enabled ? colors.textOnPrimary : colors.textHint,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
