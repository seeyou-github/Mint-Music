import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../features/download/application/download_providers.dart';
import '../../features/library/application/playlist_providers.dart';
import '../../features/player/domain/models/song.dart';
import '../../features/plugin/application/plugin_providers.dart';

/// 歌曲批量选择控制器。
///
/// 参考 CeruMusic 的批量选择：选中集合只存歌曲 id（`Set<String>`），
/// 选中的歌曲对象始终由「当前列表数据源」过滤得出，因此列表刷新/删除后
/// 不会出现「幽灵选中」。
class SongSelectionController extends ChangeNotifier {
  bool _active = false;
  final Set<String> _ids = <String>{};

  /// 是否处于多选模式。
  bool get isActive => _active;

  /// 已选数量。
  int get count => _ids.length;

  bool get isEmpty => _ids.isEmpty;

  bool isSelected(String id) => _ids.contains(id);

  /// 全选判定：列表为空时恒为 false（与 CeruMusic 的 `size > 0` 短路一致）。
  bool isAllSelected(int total) => total > 0 && _ids.length >= total;

  /// 进入多选模式；[id] 通常是触发长按的那首歌，进入时即选中。
  void enter([String? id]) {
    _active = true;
    _ids.clear();
    if (id != null) _ids.add(id);
    notifyListeners();
  }

  /// 退出多选模式并清空选择。
  void exit() {
    if (!_active && _ids.isEmpty) return;
    _active = false;
    _ids.clear();
    notifyListeners();
  }

  void toggle(String id) {
    if (!_ids.remove(id)) _ids.add(id);
    notifyListeners();
  }

  /// 全选 / 取消全选（二态，与 CeruMusic 一致）。
  void toggleAll(List<Song> songs) {
    if (isAllSelected(songs.length)) {
      _ids.clear();
    } else {
      _ids
        ..clear()
        ..addAll(songs.map((s) => s.id));
    }
    notifyListeners();
  }

  /// 从当前列表数据源中取出已选歌曲，保持列表中的顺序。
  List<Song> selectedSongs(List<Song> source) =>
      source.where((s) => _ids.contains(s.id)).toList(growable: false);
}

/// 多选模式下的顶部栏：已选计数 + 全选 + 完成。
///
/// 对应 CeruMusic 中「列表列头被整行替换为操作栏」的设计。
class SongSelectionBar extends StatelessWidget {
  const SongSelectionBar({
    super.key,
    required this.colors,
    required this.controller,
    required this.songs,
  });

  final ThemeColors colors;
  final SongSelectionController controller;
  final List<Song> songs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final allSelected = controller.isAllSelected(songs.length);
        return Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.lg,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: colors.primary.withValues(alpha: 0.08),
            border: Border(
              bottom: BorderSide(color: colors.divider.withValues(alpha: 0.5)),
            ),
          ),
          child: Row(
            children: [
              Icon(Icons.checklist, size: 18, color: colors.primary),
              const SizedBox(width: AppSpacing.sm),
              Text(
                context.tr('已选择 ${controller.count} 首'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: songs.isEmpty
                    ? null
                    : () => controller.toggleAll(songs),
                child: Text(
                  context.tr(allSelected ? '取消全选' : '全选'),
                  style: TextStyle(color: colors.primary),
                ),
              ),
              TextButton(
                onPressed: controller.exit,
                child: Text(
                  context.tr('完成'),
                  style: TextStyle(color: colors.primary),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 多选模式下的底部批量操作栏。
class SongBatchActionBar extends StatelessWidget {
  const SongBatchActionBar({
    super.key,
    required this.colors,
    required this.controller,
    required this.onPlayNext,
    required this.onAddToQueue,
    required this.onAddToPlaylist,
    required this.onFavorite,
    this.onDownload,
    this.onRemove,
    this.removeLabel = '删除',
    this.removeIcon = Icons.delete_outline,
    this.bottomInset = 0,
  });

  /// 操作栏大致高度，列表在多选模式下据此增加底部留白。
  static const double height = 60;

  final ThemeColors colors;
  final SongSelectionController controller;
  final VoidCallback onPlayNext;
  final VoidCallback onAddToQueue;
  final VoidCallback onAddToPlaylist;
  final VoidCallback onFavorite;
  final VoidCallback? onDownload;

  /// 删除 / 移出歌单。为 null 时不显示该按钮（CeruMusic 里本地音乐页就没有）。
  final VoidCallback? onRemove;
  final String removeLabel;
  final IconData removeIcon;

  /// 底部需要避让的高度（迷你播放器等）。
  final double bottomInset;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final enabled = controller.count > 0;
        final actions = <_BatchAction>[
          _BatchAction(Icons.playlist_play, '下一首播放', onPlayNext),
          _BatchAction(Icons.playlist_add, '加入播放列表', onAddToQueue),
          _BatchAction(Icons.library_add, '添加到歌单', onAddToPlaylist),
          _BatchAction(Icons.favorite_border, '收藏', onFavorite),
          if (onDownload != null)
            _BatchAction(Icons.download_outlined, '下载', onDownload!),
          if (onRemove != null)
            _BatchAction(removeIcon, removeLabel, onRemove!),
        ];
        return Container(
          margin: EdgeInsets.fromLTRB(
            AppSpacing.md,
            0,
            AppSpacing.md,
            AppSpacing.sm + bottomInset,
          ),
          padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
          decoration: BoxDecoration(
            color: colors.surface,
            borderRadius: BorderRadius.circular(AppRadius.lg),
            boxShadow: [
              BoxShadow(
                color: colors.shadow.withValues(alpha: 0.25),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: actions
                .map(
                  (a) => Expanded(
                    child: _BatchActionButton(
                      colors: colors,
                      icon: a.icon,
                      label: a.label,
                      enabled: enabled,
                      danger: a.icon == removeIcon && onRemove != null,
                      onTap: a.onTap,
                    ),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
  }
}

class _BatchAction {
  const _BatchAction(this.icon, this.label, this.onTap);
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _BatchActionButton extends StatelessWidget {
  const _BatchActionButton({
    required this.colors,
    required this.icon,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.danger = false,
  });

  final ThemeColors colors;
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? colors.disabled
        : (danger ? colors.error : colors.textSecondary);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 2),
            Text(
              context.tr(label),
              style: TextStyle(fontSize: 10, color: color),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// 批量「添加到歌单」底部弹窗。
Future<void> showAddSongsToPlaylistSheet(
  BuildContext context,
  WidgetRef ref,
  ThemeColors colors,
  List<Song> songs,
) async {
  if (songs.isEmpty) return;
  final playlistsAsync = ref.read(playlistsProvider);
  final playlists = playlistsAsync.valueOrNull;
  if (playlists == null) {
    _snack(context, '加载歌单中...');
    return;
  }
  // 「我的收藏」有自己的入口，不出现在普通歌单列表里（与单曲菜单一致）。
  final targets = playlists.where((p) => p.id != '__favorites__').toList();
  final bottomPadding = MediaQuery.of(context).padding.bottom;

  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(bottom: bottomPadding),
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
                  ctx.tr('添加到歌单'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (targets.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(AppSpacing.xl),
                    child: Text(
                      ctx.tr('暂无歌单'),
                      style: TextStyle(color: colors.textHint),
                    ),
                  )
                else
                  ...targets.map(
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
                        ctx.tr('${playlist.songCount}首'),
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                      onTap: () async {
                        Navigator.pop(ctx);
                        await ref
                            .read(playlistsProvider.notifier)
                            .addSongsToPlaylist(playlist.id, songs);
                        if (context.mounted) {
                          _snack(
                            context,
                            '已添加 ${songs.length} 首到"${playlist.name}"',
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
}

/// 批量下载：先选音质，再逐首入队（自动跳过本地歌曲）。
Future<void> showBatchDownloadSheet(
  BuildContext context,
  WidgetRef ref,
  List<Song> songs,
) async {
  final candidates = songs.where((s) => !s.isLocal).toList();
  if (candidates.isEmpty) {
    _snack(context, '没有可下载的歌曲');
    return;
  }
  final manager = ref.read(musicSourceManagerProvider);
  // 批量下载用「下载音质」声明（与单曲下载菜单一致，避免下到插件给不了的档位）。
  final first = candidates.first;
  final qualities = manager.getDownloadQualitiesForSourceId(
    manager.effectivePlaybackSourceForSong(first) ?? first.source ?? 'wy',
  );
  if (qualities.isEmpty) {
    _snack(context, '当前音源无可下载音质');
    return;
  }

  final quality = await showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => SafeArea(
      child: Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1E1E1E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.md),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              ctx.tr('选择下载音质'),
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            ...qualities.map(
              (q) => ListTile(
                title: Text(q, style: const TextStyle(color: Colors.white)),
                onTap: () => Navigator.pop(ctx, q),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    ),
  );
  if (quality == null) return;

  final repo = ref.read(downloadRepositoryProvider);
  var added = 0;
  for (final song in candidates) {
    try {
      await repo.addTask(song: song, quality: quality);
      added++;
    } catch (_) {
      // 单首失败不中断整批。
    }
  }
  if (context.mounted) {
    _snack(context, '已添加 $added 首歌曲到下载队列');
  }
}

void _snack(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(context.tr(message)),
      duration: const Duration(seconds: 2),
    ),
  );
}
