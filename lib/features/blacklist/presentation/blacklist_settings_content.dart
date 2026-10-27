import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../application/blacklist_providers.dart';

/// 设置 → 黑名单设置：分别管理歌曲黑名单和歌手黑名单（增删改查）。
class BlacklistSettingsContent extends ConsumerStatefulWidget {
  const BlacklistSettingsContent({super.key});

  @override
  ConsumerState<BlacklistSettingsContent> createState() =>
      _BlacklistSettingsContentState();
}

/// 当前管理的黑名单类型。
enum _BlacklistTab { songs, artists }

class _BlacklistSettingsContentState
    extends ConsumerState<BlacklistSettingsContent> {
  _BlacklistTab _tab = _BlacklistTab.songs;
  final TextEditingController _searchController = TextEditingController();
  String _keyword = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final data = ref.watch(blacklistProvider);
    final keyword = blacklistNormalize(_keyword);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildCard(
          colors,
          children: [
            Row(
              children: [
                Expanded(child: _buildTabButton(colors, _BlacklistTab.songs)),
                const SizedBox(width: AppSpacing.sm),
                Expanded(child: _buildTabButton(colors, _BlacklistTab.artists)),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _keyword = value),
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: context.tr('搜索黑名单'),
                hintStyle: TextStyle(fontSize: 14, color: colors.textHint),
                prefixIcon: Icon(
                  Icons.search,
                  size: 18,
                  color: colors.textHint,
                ),
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
            ),
            const SizedBox(height: AppSpacing.md),
            // 与设置里「选择目录」一致的胶囊描边按钮：主色细边框 + 主色文字，
            // 不填充底色（Material 3 的 OutlinedButton 默认就是胶囊形）。
            OutlinedButton(
              onPressed: _addEntry,
              style: OutlinedButton.styleFrom(
                foregroundColor: colors.primary,
                side: BorderSide(color: colors.primary),
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 16, color: colors.primary),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    context.tr(_tab == _BlacklistTab.songs ? '添加歌曲' : '添加歌手'),
                  ),
                ],
              ),
            ),
          ],
        ),
        _buildCard(
          colors,
          children: [
            Text(
              _tab == _BlacklistTab.songs
                  ? context.tr('歌曲黑名单（匹配歌曲名 + 歌手）')
                  : context.tr('歌手黑名单（只匹配歌手）'),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: colors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              context.tr('被拉黑的歌曲不会播放，列表里显示「黑名单」标签；播放时自动跳过。'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_tab == _BlacklistTab.songs)
              _buildSongList(colors, keyword)
            else
              _buildArtistList(colors, keyword),
          ],
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
                _buildRow(
                  colors,
                  icon: Icons.verified_outlined,
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

  Widget _buildTabButton(ThemeColors colors, _BlacklistTab tab) {
    final selected = _tab == tab;
    final label = switch (tab) {
      _BlacklistTab.songs => context.tr('歌曲黑名单'),
      _BlacklistTab.artists => context.tr('歌手黑名单'),
    };
    // 与「添加歌曲」按钮同一套描边样式：选中用主色描边 + 主色文字，
    // 未选中用分隔线色描边 + 次要文字色。
    return OutlinedButton(
      onPressed: () => setState(() => _tab = tab),
      style: OutlinedButton.styleFrom(
        foregroundColor: selected ? colors.primary : colors.textSecondary,
        side: BorderSide(color: selected ? colors.primary : colors.divider),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        textStyle: TextStyle(
          fontSize: 14,
          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      child: Text(label),
    );
  }

  Widget _buildSongList(ThemeColors colors, String keyword) {
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
    if (entries.isEmpty) {
      return _buildEmpty(colors, context.tr('还没有歌曲被拉黑'));
    }
    return Column(
      children: [
        for (final entry in entries)
          _buildRow(
            colors,
            icon: Icons.music_off_outlined,
            title: entry.title,
            subtitle: entry.artist,
            onEdit: () => _editEntry(entry),
            onDelete: () =>
                ref.read(blacklistProvider.notifier).removeSongEntry(entry),
          ),
      ],
    );
  }

  Widget _buildArtistList(ThemeColors colors, String keyword) {
    final artists = ref
        .watch(blacklistProvider)
        .artists
        .where(
          (e) => keyword.isEmpty || blacklistNormalize(e).contains(keyword),
        )
        .toList(growable: false);
    if (artists.isEmpty) {
      return _buildEmpty(colors, context.tr('还没有歌手被拉黑'));
    }
    return Column(
      children: [
        for (final artist in artists)
          _buildRow(
            colors,
            icon: Icons.person_off_outlined,
            title: artist,
            subtitle: context.tr('该歌手的所有歌曲都不播放'),
            onEdit: () => _editArtist(artist),
            onDelete: () =>
                ref.read(blacklistProvider.notifier).removeArtist(artist),
          ),
      ],
    );
  }

  Widget _buildEmpty(ThemeColors colors, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
      child: Center(
        child: Text(
          text,
          style: TextStyle(fontSize: 13, color: colors.textHint),
        ),
      ),
    );
  }

  Widget _buildRow(
    ThemeColors colors, {
    required IconData icon,
    required String title,
    required String subtitle,
    VoidCallback? onEdit,
    VoidCallback? onDelete,
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
          Icon(icon, size: 18, color: colors.textHint),
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
          if (onEdit != null)
            IconButton(
              icon: Icon(Icons.edit_outlined, size: 18, color: colors.textHint),
              visualDensity: VisualDensity.compact,
              tooltip: context.tr('编辑'),
              onPressed: onEdit,
            ),
          if (onDelete != null)
            IconButton(
              icon: Icon(Icons.delete_outline, size: 18, color: colors.error),
              visualDensity: VisualDensity.compact,
              tooltip: context.tr('删除'),
              onPressed: onDelete,
            ),
        ],
      ),
    );
  }

  // ------------------------------------------------------------ 增 / 改

  Future<void> _addEntry() async {
    if (_tab == _BlacklistTab.songs) {
      final entry = await _showSongDialog();
      if (entry == null) return;
      await ref.read(blacklistProvider.notifier).addSongEntry(entry);
      return;
    }
    final artist = await _showArtistDialog();
    if (artist == null) return;
    await ref.read(blacklistProvider.notifier).addArtist(artist);
  }

  Future<void> _editEntry(BlacklistEntry entry) async {
    final next = await _showSongDialog(initial: entry);
    if (next == null) return;
    await ref.read(blacklistProvider.notifier).updateSongEntry(entry, next);
  }

  Future<void> _editArtist(String artist) async {
    final next = await _showArtistDialog(initial: artist);
    if (next == null) return;
    await ref.read(blacklistProvider.notifier).updateArtist(artist, next);
  }

  Future<BlacklistEntry?> _showSongDialog({BlacklistEntry? initial}) {
    return showDialog<BlacklistEntry>(
      context: context,
      builder: (_) => _SongEntryDialog(initial: initial),
    );
  }

  Future<String?> _showArtistDialog({String? initial}) {
    return showDialog<String>(
      context: context,
      builder: (_) => _ArtistEntryDialog(initial: initial),
    );
  }
}

/// 新增 / 编辑一条歌曲黑名单（歌曲名 + 歌手）。
class _SongEntryDialog extends ConsumerStatefulWidget {
  const _SongEntryDialog({this.initial});

  final BlacklistEntry? initial;

  @override
  ConsumerState<_SongEntryDialog> createState() => _SongEntryDialogState();
}

class _SongEntryDialogState extends ConsumerState<_SongEntryDialog> {
  late final TextEditingController _titleController = TextEditingController(
    text: widget.initial?.title ?? '',
  );
  late final TextEditingController _artistController = TextEditingController(
    text: widget.initial?.artist ?? '',
  );

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final editing = widget.initial != null;
    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        context.tr(editing ? '编辑歌曲' : '添加歌曲'),
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

/// 新增 / 编辑一位歌手黑名单。
class _ArtistEntryDialog extends ConsumerStatefulWidget {
  const _ArtistEntryDialog({this.initial});

  final String? initial;

  @override
  ConsumerState<_ArtistEntryDialog> createState() => _ArtistEntryDialogState();
}

class _ArtistEntryDialogState extends ConsumerState<_ArtistEntryDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial ?? '',
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final editing = widget.initial != null;
    return AlertDialog(
      backgroundColor: colors.surface,
      title: Text(
        context.tr(editing ? '编辑歌手' : '添加歌手'),
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
