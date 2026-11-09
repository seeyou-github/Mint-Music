import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/theme_provider.dart';
import '../../features/library/application/playlist_providers.dart';
import '../../features/library/domain/models/playlist.dart';

/// 「添加到歌单」弹层顶部的「新增歌单」入口。
class CreatePlaylistTile extends StatelessWidget {
  final ThemeColors colors;

  const CreatePlaylistTile({super.key, required this.colors});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(Icons.playlist_add, color: colors.primary),
      title: Text(
        context.tr('新增歌单'),
        style: TextStyle(color: colors.primary, fontWeight: FontWeight.w500),
      ),
      onTap: () => showCreatePlaylistDialog(context),
    );
  }
}

/// 打开「新增歌单」弹窗：上方新建歌单，下方管理已有歌单
/// （拖拽排序 / 重命名 / 删除）。
Future<void> showCreatePlaylistDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    useRootNavigator: true,
    builder: (_) => const _CreatePlaylistDialog(),
  );
}

class _CreatePlaylistDialog extends ConsumerStatefulWidget {
  const _CreatePlaylistDialog();

  @override
  ConsumerState<_CreatePlaylistDialog> createState() =>
      _CreatePlaylistDialogState();
}

class _CreatePlaylistDialogState extends ConsumerState<_CreatePlaylistDialog> {
  final _nameController = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  /// 「我的收藏」固定在最前，不参与这里的排序。
  List<Playlist> _targets(List<Playlist>? playlists) => [
    for (final playlist in playlists ?? const <Playlist>[])
      if (playlist.id != '__favorites__') playlist,
  ];

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      await ref.read(playlistsProvider.notifier).createPlaylist(name);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('创建歌单失败'))));
    }
  }

  Future<void> _rename(Playlist playlist) async {
    final controller = TextEditingController(text: playlist.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('重命名歌单')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: context.tr('歌单名称')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(context.tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(context.tr('保存')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.isEmpty || name == playlist.name) return;
    await ref
        .read(playlistsProvider.notifier)
        .updatePlaylist(playlist.copyWith(name: name));
  }

  Future<void> _delete(Playlist playlist) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.tr('删除歌单')),
        content: Text(context.tr('确定删除「${playlist.name}」吗？歌曲不会从本地删除。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.tr('删除')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(playlistsProvider.notifier).deletePlaylist(playlist.id);
  }

  void _reorder(List<Playlist> targets, int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final reordered = [...targets];
    reordered.insert(newIndex, reordered.removeAt(oldIndex));
    ref.read(playlistsProvider.notifier).reorderPlaylists([
      for (final playlist in reordered) playlist.id,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final playlistsAsync = ref.watch(playlistsProvider);
    final targets = _targets(playlistsAsync.valueOrNull);

    return AlertDialog(
      scrollable: true,
      backgroundColor: colors.surface,
      title: Text(
        context.tr('新增歌单'),
        style: TextStyle(color: colors.textPrimary),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _nameController,
              autofocus: true,
              onSubmitted: (_) => _create(),
              decoration: InputDecoration(
                hintText: context.tr('歌单名称'),
                hintStyle: TextStyle(color: colors.textHint),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: colors.divider),
                ),
                focusedBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
              style: TextStyle(color: colors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              context.tr('已有歌单'),
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.xs),
            if (playlistsAsync.isLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.lg),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (targets.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  context.tr('暂无歌单'),
                  style: TextStyle(color: colors.textHint),
                ),
              )
            else
              SizedBox(
                height: 240,
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  shrinkWrap: true,
                  itemCount: targets.length,
                  onReorder: (oldIndex, newIndex) =>
                      _reorder(targets, oldIndex, newIndex),
                  itemBuilder: (context, index) {
                    final playlist = targets[index];
                    return ListTile(
                      key: ValueKey(playlist.id),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: ReorderableDragStartListener(
                        index: index,
                        child: Icon(
                          Icons.drag_handle,
                          size: 20,
                          color: colors.textHint,
                        ),
                      ),
                      title: Text(
                        playlist.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textPrimary),
                      ),
                      subtitle: Text(
                        context.tr('${playlist.songCount}首'),
                        style: TextStyle(fontSize: 11, color: colors.textHint),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: context.tr('重命名'),
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.edit_outlined,
                              size: 18,
                              color: colors.textSecondary,
                            ),
                            onPressed: () => _rename(playlist),
                          ),
                          IconButton(
                            tooltip: context.tr('删除'),
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: colors.error,
                            ),
                            onPressed: () => _delete(playlist),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
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
          onPressed: _saving ? null : _create,
          child: Text(
            context.tr('创建'),
            style: TextStyle(color: colors.primary),
          ),
        ),
      ],
    );
  }
}
