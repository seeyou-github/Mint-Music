import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../discover/application/search_providers.dart';
import '../../../player/application/playback_controller.dart';
import '../../../player/domain/models/song.dart';
import '../../../plugin/application/plugin_providers.dart';
import '../../../plugin/domain/plugin_types.dart';
import '../../../settings/application/settings_providers.dart';
import '../../../../shared/widgets/source_icon.dart';
import '../../application/local_providers.dart';
import '../song_compare_dialog.dart';

/// 应用精准匹配结果：写回本地歌曲库，并同步播放队列（界面随之刷新）。
///
/// 本地歌曲列表与播放页都走这一份逻辑，避免两处实现不一致。
Future<void> applyAccurateMatchResult(
  BuildContext context,
  WidgetRef ref,
  Song updated,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await ref
        .read(localMusicNotifierProvider.notifier)
        .upsertSong(updated, forceOverwrite: true);
    // 同步更新播放队列中的歌曲，迷你播放器 / 全屏播放页的封面与歌词即时刷新。
    ref.read(playbackControllerProvider.notifier).updateSongInQueue(updated);
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(context.tr('已应用匹配结果')),
        duration: const Duration(seconds: 2),
      ),
    );
  } catch (e) {
    if (!context.mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(context.tr('保存失败: $e')),
        duration: const Duration(seconds: 2),
      ),
    );
  }
}

/// 打开「精准匹配」弹层。
///
/// [hostContext] 要用页面（而不是弹层）的 context：选择候选后弹层会被关掉，
/// 接着的「歌曲信息对比」弹窗需要它。
/// [onApply] 在用户确认对比结果后调用（写回本地歌曲库并同步播放队列）。
Future<void> showAccurateMatchSheet(
  BuildContext context, {
  required Song song,
  required Future<void> Function(Song song) onApply,
}) {
  return showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) =>
        AccurateMatchSheet(song: song, hostContext: context, onApply: onApply),
  );
}

/// 精准匹配关键词：歌曲名 + 歌手名（匹配更准）。
String accurateMatchKeyword(Song song) {
  final title = song.title.trim();
  final artist = song.artist.trim();
  if (artist.isEmpty) return title;
  if (title.isEmpty) return artist;
  return '$title $artist';
}

/// 「精准匹配」底部弹窗。
///
/// 默认用当前音源搜索（与发现页 / 插件管理里正在使用的音源一致），右上角的
/// 圆形按钮可以换成别的音源重新搜索。
class AccurateMatchSheet extends ConsumerStatefulWidget {
  const AccurateMatchSheet({
    super.key,
    required this.song,
    required this.hostContext,
    required this.onApply,
  });

  /// 要匹配的本地歌曲。
  final Song song;

  /// 页面 context：弹窗关闭后再打开对比弹窗时要用它。
  final BuildContext hostContext;

  /// 应用对比结果（写回本地歌曲库）。
  final Future<void> Function(Song song) onApply;

  @override
  ConsumerState<AccurateMatchSheet> createState() => _AccurateMatchSheetState();
}

class _AccurateMatchSheetState extends ConsumerState<AccurateMatchSheet> {
  static const double _sourceButtonSize = 36;

  final _sourceButtonKey = GlobalKey();

  /// 当前搜索音源；空串表示音源列表还没就绪。
  String _sourceId = '';
  List<Song> _results = const <Song>[];
  bool _searching = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSelection());
  }

  /// 音源列表可能在弹窗打开之后才就绪：拿到列表再选默认音源并开始搜索。
  void _ensureSelection() {
    if (!mounted || _searching || _loaded) return;
    final sources = ref.read(searchAvailableSourcesProvider);
    if (sources.isEmpty) return;
    final sourceId = _resolvedSourceId(sources);
    setState(() => _sourceId = sourceId);
    unawaited(_search(sourceId));
  }

  /// 当前音源优先：用户刚选的 > 全局当前音源 > 列表第一个。
  String _resolvedSourceId(List<SourceInfo> sources) {
    if (sources.any((source) => source.id == _sourceId)) return _sourceId;
    final current = ref.read(defaultSourceIdProvider);
    if (sources.any((source) => source.id == current)) return current;
    return sources.first.id;
  }

  Future<void> _search(String sourceId) async {
    setState(() => _searching = true);
    var results = const <Song>[];
    try {
      results = await ref
          .read(musicSourceManagerProvider)
          .search(
            accurateMatchKeyword(widget.song),
            sourceId: sourceId,
            limit: 20,
          );
    } catch (_) {
      results = const <Song>[];
    }
    // 搜索期间又换了音源：这次的结果已经过时，丢掉。
    if (!mounted || sourceId != _sourceId) return;
    setState(() {
      _results = results;
      _searching = false;
      _loaded = true;
    });
  }

  void _switchSource(String sourceId) {
    if (!mounted || sourceId == _sourceId) return;
    setState(() => _sourceId = sourceId);
    unawaited(_search(sourceId));
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final sources = ref.watch(searchAvailableSourcesProvider);
    // 插件还在加载时先转圈；加载完仍然没有可搜的音源才算「没有结果」。
    final pluginReady = ref.watch(pluginInitializedProvider).hasValue;
    if (!_searching && !_loaded && sources.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _ensureSelection());
    }

    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
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
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: Row(
                    children: [
                      // 与右侧音源按钮等宽，让标题保持居中。
                      const SizedBox(width: _sourceButtonSize),
                      Expanded(
                        child: Text(
                          context.tr('精准匹配'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: colors.textPrimary,
                          ),
                        ),
                      ),
                      _buildSourceButton(colors, sources),
                    ],
                  ),
                ),
                const SizedBox(height: AppSpacing.sm),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: Text(
                    '${widget.song.title} - ${widget.song.artist}',
                    style: TextStyle(fontSize: 13, color: colors.textHint),
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Expanded(
                  child: _buildResults(
                    colors,
                    scrollController,
                    pluginReady: pluginReady,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 右上角的音源切换按钮：显示当前搜索音源的图标。
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
      child: GestureDetector(
        key: _sourceButtonKey,
        onTap: sources.isEmpty
            ? null
            : () => _showSourceMenu(colors, sources, currentId),
        child: Container(
          width: _sourceButtonSize,
          height: _sourceButtonSize,
          decoration: BoxDecoration(
            color: colors.surfaceVariant,
            shape: BoxShape.circle,
          ),
          clipBehavior: Clip.antiAlias,
          child: current == null
              ? Icon(
                  Icons.library_music_outlined,
                  size: 18,
                  color: colors.textHint,
                )
              : SourceIcon(
                  sourceId: current.id,
                  size: _sourceButtonSize,
                  label: current.name,
                ),
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
      if (selectedId == null) return;
      _switchSource(selectedId);
    });
  }

  Widget _buildResults(
    ThemeColors colors,
    ScrollController scrollController, {
    required bool pluginReady,
  }) {
    if (!_loaded) {
      if (!pluginReady || _searching) {
        return const Center(child: CircularProgressIndicator());
      }
      // 插件已就绪但一个可搜索的音源都没有。
      return Center(
        child: Text(
          context.tr('未找到匹配结果'),
          style: TextStyle(color: colors.textHint),
        ),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          context.tr('未找到匹配结果'),
          style: TextStyle(color: colors.textHint),
        ),
      );
    }
    return Column(
      children: [
        // 换音源重搜时保留旧结果，只在顶部显示细进度条，列表不闪空。
        SizedBox(
          height: 2,
          child: _searching
              ? LinearProgressIndicator(
                  minHeight: 2,
                  color: colors.primary,
                  backgroundColor: colors.divider,
                )
              : null,
        ),
        Expanded(
          child: ListView.builder(
            controller: scrollController,
            // 列表贴到底部留一点余量，不再额外垫一大块空白。
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            itemCount: _results.length,
            addAutomaticKeepAlives: false,
            addRepaintBoundaries: true,
            itemBuilder: (context, index) =>
                _buildCandidate(colors, _results[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildCandidate(ThemeColors colors, Song candidate) {
    final source = candidate.source ?? '';
    final sourceName = source.isEmpty ? '' : SourceInfo.getNameById(source);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.xs,
      ),
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
                    ? DecorationImage(
                        image: NetworkImage(candidate.coverUrl!),
                        fit: BoxFit.cover,
                      )
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
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      if (sourceName.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          margin: const EdgeInsets.only(right: 4),
                          decoration: BoxDecoration(
                            color: colors.primary.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            sourceName,
                            style: TextStyle(
                              fontSize: 10,
                              color: colors.primary,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          '${candidate.artist} · ${candidate.album}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textHint,
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
            GestureDetector(
              onTap: () => _useCandidate(candidate),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
                child: Text(
                  context.tr('使用'),
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textOnPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 选中候选：先关掉搜索弹窗，再打开「歌曲信息对比」。
  void _useCandidate(Song candidate) {
    final hostContext = widget.hostContext;
    final original = widget.song;
    final onApply = widget.onApply;
    Navigator.of(context).pop();
    unawaited(_compareAndApply(hostContext, original, candidate, onApply));
  }

  Future<void> _compareAndApply(
    BuildContext context,
    Song original,
    Song candidate,
    Future<void> Function(Song song) onApply,
  ) async {
    final merged = await showSongCompareDialog(
      context,
      original: original,
      candidate: candidate,
    );
    if (merged == null) return;
    await onApply(merged);
  }
}
