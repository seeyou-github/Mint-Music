import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../application/blacklist_providers.dart';

/// 设置 → 黑名单设置：上下两个固定高度的歌曲 / 歌手黑名单框，
/// 各自带搜索、滚动与逐条删除，框下方提供导出与合并导入。
class BlacklistSettingsContent extends ConsumerStatefulWidget {
  const BlacklistSettingsContent({super.key});

  @override
  ConsumerState<BlacklistSettingsContent> createState() =>
      _BlacklistSettingsContentState();
}

class _BlacklistSettingsContentState
    extends ConsumerState<BlacklistSettingsContent> {
  /// 两个黑名单框的固定高度：内容超出后改为框内滚动。
  static const double _songsBoxHeight = 260;
  static const double _artistsBoxHeight = 200;

  /// 平铺条目的目标宽度：按框宽算出每行放几个。
  static const double _tileTargetWidth = 200;

  /// 框宽小于该值时，标题和搜索框改成上下两行，避免挤在一起。
  static const double _stackBreakpoint = 520;

  static const String _exportType = 'mintmusic_blacklist';

  final TextEditingController _songSearchController = TextEditingController();
  final TextEditingController _artistSearchController = TextEditingController();
  final ScrollController _songScrollController = ScrollController();
  final ScrollController _artistScrollController = ScrollController();
  String _songKeyword = '';
  String _artistKeyword = '';

  @override
  void dispose() {
    _songSearchController.dispose();
    _artistSearchController.dispose();
    _songScrollController.dispose();
    _artistScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final data = ref.watch(blacklistProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildListCard(
          colors,
          title: context.tr('歌曲黑名单'),
          subtitle: context.tr('匹配歌曲名 + 歌手'),
          searchController: _songSearchController,
          searchHint: context.tr('搜索歌曲 / 歌手'),
          onSearchChanged: (value) => setState(() => _songKeyword = value),
          boxHeight: _songsBoxHeight,
          scrollController: _songScrollController,
          tiles: _buildSongTiles(colors, blacklistNormalize(_songKeyword)),
          onAdd: _addSong,
          emptyText: context.tr('还没有歌曲被拉黑'),
        ),
        _buildListCard(
          colors,
          title: context.tr('歌手黑名单'),
          subtitle: context.tr('只匹配歌手，该歌手的所有歌曲都不播放'),
          searchController: _artistSearchController,
          searchHint: context.tr('搜索歌手'),
          onSearchChanged: (value) => setState(() => _artistKeyword = value),
          boxHeight: _artistsBoxHeight,
          scrollController: _artistScrollController,
          tiles: _buildArtistTiles(colors, blacklistNormalize(_artistKeyword)),
          onAdd: _addArtist,
          emptyText: context.tr('还没有歌手被拉黑'),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: Row(
            children: [
              Expanded(
                child: _buildActionButton(
                  colors,
                  icon: Icons.upload_file,
                  label: context.tr('导出黑名单'),
                  onPressed: _exportBlacklist,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _buildActionButton(
                  colors,
                  icon: Icons.download,
                  label: context.tr('导入黑名单'),
                  onPressed: _importBlacklist,
                ),
              ),
            ],
          ),
        ),
        if (data.whitelist.isNotEmpty)
          _buildCard(
            colors,
            children: [
              Text(
                context.tr('白名单（不受歌手黑名单影响）'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: colors.textSecondary,
                ),
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                context.tr('从「歌手黑名单」被拉黑的歌曲移出黑名单时会加入这里。'),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final entry in data.whitelist)
                _buildWhitelistRow(
                  colors,
                  title: entry.title,
                  subtitle: entry.artist,
                  onDelete: () => ref
                      .read(blacklistProvider.notifier)
                      .removeWhitelistEntry(entry),
                ),
            ],
          ),
      ],
    );
  }

  // ------------------------------------------------------------ 列表卡片

  Widget _buildListCard(
    ThemeColors colors, {
    required String title,
    required String subtitle,
    required TextEditingController searchController,
    required String searchHint,
    required ValueChanged<String> onSearchChanged,
    required double boxHeight,
    required ScrollController scrollController,
    required List<Widget> tiles,
    required VoidCallback onAdd,
    required String emptyText,
  }) {
    return _buildCard(
      colors,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < _stackBreakpoint;
            final titleBlock = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
              ],
            );
            final search = _buildSearchField(
              colors,
              controller: searchController,
              hint: searchHint,
              onChanged: onSearchChanged,
            );
            final add = _buildAddButton(colors, onTap: onAdd);
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(child: titleBlock),
                      const SizedBox(width: AppSpacing.sm),
                      add,
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  search,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: titleBlock),
                const SizedBox(width: AppSpacing.md),
                SizedBox(width: 240, child: search),
                const SizedBox(width: AppSpacing.sm),
                add,
              ],
            );
          },
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: boxHeight,
          child: tiles.isEmpty
              ? _buildEmpty(colors, emptyText)
              : Scrollbar(
                  controller: scrollController,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: scrollController,
                    padding: const EdgeInsets.only(right: AppSpacing.sm),
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final columns =
                            (constraints.maxWidth / _tileTargetWidth)
                                .floor()
                                .clamp(1, 8);
                        final width =
                            (constraints.maxWidth -
                                AppSpacing.sm * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: AppSpacing.sm,
                          runSpacing: AppSpacing.sm,
                          children: [
                            for (final tile in tiles)
                              SizedBox(width: width, child: tile),
                          ],
                        );
                      },
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildCard(ThemeColors colors, {required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.lg),
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  Widget _buildSearchField(
    ThemeColors colors, {
    required TextEditingController controller,
    required String hint,
    required ValueChanged<String> onChanged,
  }) {
    return SizedBox(
      height: 36,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: TextStyle(fontSize: 13, color: colors.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(fontSize: 13, color: colors.textSecondary),
          prefixIcon: Icon(Icons.search, size: 16, color: colors.textHint),
          prefixIconConstraints: const BoxConstraints(minWidth: 32),
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
      ),
    );
  }

  /// 与标题同一行的「+」按钮，点击弹出新增对话框。
  Widget _buildAddButton(ThemeColors colors, {required VoidCallback onTap}) {
    return Tooltip(
      message: context.tr('添加'),
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.md),
            border: Border.all(color: colors.primary),
          ),
          child: Icon(Icons.add, size: 18, color: colors.primary),
        ),
      ),
    );
  }

  Widget _buildActionButton(
    ThemeColors colors, {
    required IconData icon,
    required String label,
    required VoidCallback onPressed,
  }) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16, color: colors.primary),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.primary,
        side: BorderSide(color: colors.primary),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }

  // ------------------------------------------------------------ 平铺条目

  List<Widget> _buildSongTiles(ThemeColors colors, String keyword) {
    final entries = ref
        .watch(blacklistProvider)
        .songs
        .where(
          (e) =>
              keyword.isEmpty ||
              blacklistNormalize(e.title).contains(keyword) ||
              blacklistNormalize(e.artist).contains(keyword),
        )
        .toList(growable: false);
    return [
      for (final entry in entries)
        _buildTile(
          colors,
          title: entry.title,
          subtitle: entry.artist,
          onDelete: () =>
              ref.read(blacklistProvider.notifier).removeSongEntry(entry),
        ),
    ];
  }

  List<Widget> _buildArtistTiles(ThemeColors colors, String keyword) {
    final artists = ref
        .watch(blacklistProvider)
        .artists
        .where(
          (e) => keyword.isEmpty || blacklistNormalize(e).contains(keyword),
        )
        .toList(growable: false);
    return [
      for (final artist in artists)
        _buildTile(
          colors,
          title: artist,
          onDelete: () =>
              ref.read(blacklistProvider.notifier).removeArtist(artist),
        ),
    ];
  }

  Widget _buildTile(
    ThemeColors colors, {
    required String title,
    String? subtitle,
    required VoidCallback onDelete,
  }) {
    return Container(
      padding: const EdgeInsets.only(left: AppSpacing.sm, right: 2),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (subtitle != null && subtitle.isNotEmpty) ...[
                    const SizedBox(height: 1),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11, color: colors.textHint),
                    ),
                  ],
                ],
              ),
            ),
          ),
          _buildDeleteButton(colors, onDelete),
        ],
      ),
    );
  }

  Widget _buildDeleteButton(ThemeColors colors, VoidCallback onDelete) {
    return Tooltip(
      message: context.tr('删除'),
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: onDelete,
        borderRadius: BorderRadius.circular(AppRadius.xs),
        child: SizedBox(
          width: 26,
          height: 26,
          child: Icon(Icons.close, size: 15, color: colors.error),
        ),
      ),
    );
  }

  Widget _buildWhitelistRow(
    ThemeColors colors, {
    required String title,
    required String subtitle,
    required VoidCallback onDelete,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.xs,
        AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          Icon(Icons.verified_outlined, size: 18, color: colors.textHint),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colors.textPrimary,
                  ),
                ),
                if (subtitle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.textHint),
                  ),
                ],
              ],
            ),
          ),
          _buildDeleteButton(colors, onDelete),
        ],
      ),
    );
  }

  Widget _buildEmpty(ThemeColors colors, String text) {
    return Center(
      child: Text(
        text,
        style: TextStyle(fontSize: 13, color: colors.textSecondary),
      ),
    );
  }

  // ------------------------------------------------------------ 增

  Future<void> _addSong() async {
    final entry = await showDialog<BlacklistEntry>(
      context: context,
      builder: (_) => const _SongEntryDialog(),
    );
    if (entry == null) return;
    await ref.read(blacklistProvider.notifier).addSongEntry(entry);
  }

  Future<void> _addArtist() async {
    final artist = await showDialog<String>(
      context: context,
      builder: (_) => const _ArtistEntryDialog(),
    );
    if (artist == null) return;
    await ref.read(blacklistProvider.notifier).addArtist(artist);
  }

  // ------------------------------------------------------------ 导出 / 导入

  Future<void> _exportBlacklist() async {
    final data = ref.read(blacklistProvider);
    try {
      final payload = <String, dynamic>{
        'type': _exportType,
        'version': 1,
        'exportedAt': DateTime.now().toIso8601String(),
        ...data.toJson(),
      };
      final bytes = Uint8List.fromList(
        utf8.encode(const JsonEncoder.withIndent('  ').convert(payload)),
      );
      final path = await FilePicker.platform.saveFile(
        dialogTitle: context.tr('导出黑名单'),
        fileName: _buildExportFileName(),
        type: FileType.any,
        bytes: bytes,
      );
      if (path == null || !mounted) return; // 用户取消 / 页面已关闭
      _toast(context.tr('已导出黑名单'));
    } catch (e) {
      if (!mounted) return;
      _toast(context.tr('导出失败：$e'), error: true);
    }
  }

  Future<void> _importBlacklist() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        final f = File(file.path!);
        if (await f.exists()) bytes = await f.readAsBytes();
      }
      if (!mounted) return;
      if (bytes == null) {
        _toast(context.tr('无法读取所选文件'), error: true);
        return;
      }

      Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(bytes));
      } catch (_) {
        decoded = null;
      }
      if (decoded is! Map) {
        _toast(context.tr('文件格式不正确'), error: true);
        return;
      }
      final map = Map<String, dynamic>.from(decoded);
      if (map['type'] != null && map['type'] != _exportType) {
        _toast(context.tr('文件格式不正确'), error: true);
        return;
      }
      final imported = BlacklistData.fromJson(map);
      if (imported.isEmpty) {
        _toast(context.tr('文件里没有黑名单数据'), error: true);
        return;
      }

      await ref.read(blacklistProvider.notifier).merge(imported);
      if (!mounted) return;
      _toast(context.tr('已导入并合并黑名单'));
    } catch (e) {
      if (!mounted) return;
      _toast(context.tr('导入失败：$e'), error: true);
    }
  }

  String _buildExportFileName() {
    final now = DateTime.now();
    final y = now.year.toString().padLeft(4, '0');
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return 'mintmusic_blacklist_$y$m$d.json';
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }
}

/// 新增一条歌曲黑名单（歌曲名 + 歌手）。
class _SongEntryDialog extends ConsumerStatefulWidget {
  const _SongEntryDialog();

  @override
  ConsumerState<_SongEntryDialog> createState() => _SongEntryDialogState();
}

class _SongEntryDialogState extends ConsumerState<_SongEntryDialog> {
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _artistController = TextEditingController();

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return AlertDialog(
      backgroundColor: colors.dialogSurface,
      title: Text(
        context.tr('添加歌曲'),
        style: TextStyle(color: colors.textPrimary, fontSize: 17),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dialogField(
            colors,
            controller: _titleController,
            hint: context.tr('歌曲名'),
            autofocus: true,
          ),
          const SizedBox(height: AppSpacing.sm),
          _dialogField(
            colors,
            controller: _artistController,
            hint: context.tr('歌手名'),
          ),
        ],
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
          onPressed: () {
            final title = _titleController.text.trim();
            if (title.isEmpty) return;
            Navigator.pop(
              context,
              BlacklistEntry(
                title: title,
                artist: _artistController.text.trim(),
              ),
            );
          },
          child: Text(
            context.tr('保存'),
            style: TextStyle(color: colors.primary),
          ),
        ),
      ],
    );
  }
}

/// 新增一位歌手黑名单。
class _ArtistEntryDialog extends ConsumerStatefulWidget {
  const _ArtistEntryDialog();

  @override
  ConsumerState<_ArtistEntryDialog> createState() => _ArtistEntryDialogState();
}

class _ArtistEntryDialogState extends ConsumerState<_ArtistEntryDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    return AlertDialog(
      backgroundColor: colors.dialogSurface,
      title: Text(
        context.tr('添加歌手'),
        style: TextStyle(color: colors.textPrimary, fontSize: 17),
      ),
      content: _dialogField(
        colors,
        controller: _controller,
        hint: context.tr('歌手名'),
        autofocus: true,
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
          onPressed: () {
            final value = _controller.text.trim();
            if (value.isEmpty) return;
            Navigator.pop(context, value);
          },
          child: Text(
            context.tr('保存'),
            style: TextStyle(color: colors.primary),
          ),
        ),
      ],
    );
  }
}

Widget _dialogField(
  ThemeColors colors, {
  required TextEditingController controller,
  required String hint,
  bool autofocus = false,
}) {
  return TextField(
    controller: controller,
    autofocus: autofocus,
    style: TextStyle(fontSize: 14, color: colors.textPrimary),
    decoration: InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14, color: colors.textHint),
      filled: true,
      fillColor: colors.surfaceVariant,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
    ),
  );
}
