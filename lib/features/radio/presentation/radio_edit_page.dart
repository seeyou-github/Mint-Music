import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../discover/application/discover_providers.dart';
import '../../discover/domain/models/leaderboard.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../application/radio_providers.dart';

/// 打开「新增 / 编辑电台」页面，保存成功返回 true。
Future<bool?> showRadioEditor(
  BuildContext context, {
  RadioStation? station,
  String? categoryId,
}) {
  return Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          RadioEditPage(station: station, initialCategoryId: categoryId),
    ),
  );
}

class RadioEditPage extends ConsumerStatefulWidget {
  const RadioEditPage({super.key, this.station, this.initialCategoryId});

  final RadioStation? station;
  final String? initialCategoryId;

  @override
  ConsumerState<RadioEditPage> createState() => _RadioEditPageState();
}

class _RadioEditPageState extends ConsumerState<RadioEditPage> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.station?.name ?? '',
  );
  late final TextEditingController _coverController = TextEditingController(
    text: (widget.station?.coverUrl.startsWith('http') ?? false)
        ? widget.station!.coverUrl
        : '',
  );
  final TextEditingController _keywordController = TextEditingController();

  late String _coverSource = widget.station?.coverUrl ?? '';
  late String _categoryId =
      widget.station?.categoryId ??
      widget.initialCategoryId ??
      RadioCategory.allId;
  late final Set<String> _sources = {...?widget.station?.sourceIds};
  late final Map<String, RadioTagRef> _tags = {
    for (final tag in widget.station?.tags ?? const <RadioTagRef>[])
      tag.key: tag,
  };
  late final List<String> _keywords = [...?widget.station?.keywords];

  final Map<String, List<PlaylistTagGroup>> _tagGroups = {};
  final Set<String> _loadingTags = {};
  bool _saving = false;

  bool get _isEditing => widget.station != null;

  @override
  void initState() {
    super.initState();
    // 默认选中发现页当前音源，省得每次都要手动勾。
    if (_sources.isEmpty) {
      final fallback = ref.read(discoverSourceIdProvider);
      final available = ref
          .read(discoverSupportedSourcesProvider)
          .map((s) => s.id)
          .toSet();
      if (available.contains(fallback)) _sources.add(fallback);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final id in _sources) {
        _ensureTagsLoaded(id);
      }
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _coverController.dispose();
    _keywordController.dispose();
    super.dispose();
  }

  Future<void> _ensureTagsLoaded(String sourceId) async {
    if (_tagGroups.containsKey(sourceId) || _loadingTags.contains(sourceId)) {
      return;
    }
    _loadingTags.add(sourceId);
    try {
      final groups = await ref
          .read(musicSourceManagerProvider)
          .getPlaylistTags(sourceId: sourceId);
      if (!mounted) return;
      setState(() => _tagGroups[sourceId] = groups);
    } catch (_) {
      if (mounted) setState(() => _tagGroups[sourceId] = const []);
    } finally {
      _loadingTags.remove(sourceId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final categories = [
      RadioCategory.all,
      ...ref.watch(radioProvider).categories,
    ];
    final sources = ref.watch(discoverSupportedSourcesProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(colors),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.xxxl,
                ),
                children: [
                  _buildCoverSection(colors),
                  const SizedBox(height: AppSpacing.lg),
                  _buildSection(
                    colors,
                    title: context.tr('电台名称'),
                    child: TextField(
                      controller: _nameController,
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                      decoration: _fieldDecoration(
                        colors,
                        hint: context.tr('给电台起个名字'),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _buildCategorySection(colors, categories),
                  const SizedBox(height: AppSpacing.lg),
                  _buildSourceSection(colors, sources),
                  const SizedBox(height: AppSpacing.lg),
                  _buildTagSection(colors),
                  const SizedBox(height: AppSpacing.lg),
                  _buildKeywordSection(colors),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    context.tr('歌单分类和搜索关键词至少填一个；两个都填时随机挑一种取歌。'),
                    style: TextStyle(fontSize: 12, color: colors.textHint),
                  ),
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
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.close, color: colors.textPrimary),
            tooltip: context.tr('取消'),
            onPressed: () => Navigator.of(context).pop(false),
          ),
          Expanded(
            child: Text(
              context.tr(_isEditing ? '编辑电台' : '新增电台'),
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: colors.textPrimary,
              ),
            ),
          ),
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  )
                : Text(
                    context.tr('保存'),
                    style: TextStyle(color: colors.primary, fontSize: 15),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSection(
    ThemeColors colors, {
    required String title,
    required Widget child,
    String? subtitle,
    Widget? trailing,
  }) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          child,
        ],
      ),
    );
  }

  InputDecoration _fieldDecoration(ThemeColors colors, {required String hint}) {
    return InputDecoration(
      isDense: true,
      hintText: hint,
      hintStyle: TextStyle(fontSize: 14, color: colors.textHint),
      filled: true,
      fillColor: colors.surfaceVariant,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: 10,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide.none,
      ),
    );
  }

  Widget _buildCoverSection(ThemeColors colors) {
    return _buildSection(
      colors,
      title: context.tr('电台封面'),
      subtitle: context.tr('必填：可以选本地图片，也可以填网络图片地址'),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.md),
            child: SizedBox(
              width: 96,
              height: 96,
              child: _buildCoverPreview(colors),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _buildSmallButton(
                      colors,
                      icon: Icons.folder_open,
                      label: context.tr('本地上传'),
                      onTap: _pickLocalCover,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _buildSmallButton(
                      colors,
                      icon: Icons.link,
                      label: context.tr('用网络地址'),
                      onTap: _applyCoverUrl,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _coverController,
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                  decoration: _fieldDecoration(
                    colors,
                    hint: context.tr('https://... 封面图片地址'),
                  ),
                  onSubmitted: (_) => _applyCoverUrl(),
                ),
                if (_coverSource.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    _coverSource,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoverPreview(ThemeColors colors) {
    final value = _coverSource.trim();
    if (value.isEmpty) {
      return Container(
        color: colors.surfaceVariant,
        child: Icon(Icons.radio, size: 32, color: colors.textHint),
      );
    }
    if (value.startsWith('http')) {
      return Image.network(
        value,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: colors.surfaceVariant,
          child: Icon(Icons.broken_image, color: colors.textHint),
        ),
      );
    }
    return Image.file(
      File(value),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: colors.surfaceVariant,
        child: Icon(Icons.broken_image, color: colors.textHint),
      ),
    );
  }

  Widget _buildSmallButton(
    ThemeColors colors, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: colors.divider),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: colors.textSecondary),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickLocalCover() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    setState(() {
      _coverSource = path;
      _coverController.text = '';
    });
  }

  void _applyCoverUrl() {
    final value = _coverController.text.trim();
    if (value.isEmpty) return;
    setState(() => _coverSource = value);
  }

  Widget _buildCategorySection(
    ThemeColors colors,
    List<RadioCategory> categories,
  ) {
    return _buildSection(
      colors,
      title: context.tr('电台分类'),
      child: Wrap(
        spacing: AppSpacing.sm,
        runSpacing: AppSpacing.sm,
        children: [
          for (final category in categories)
            _buildChoice(
              colors,
              label: category.name,
              selected: category.id == _categoryId,
              onTap: () => setState(() => _categoryId = category.id),
              onDelete: category.isAll ? null : () => _removeCategory(category),
            ),
          _buildChoice(
            colors,
            label: context.tr('+ 新建分类'),
            selected: false,
            onTap: _createCategory,
          ),
        ],
      ),
    );
  }

  Future<void> _createCategory() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final colors = ref.read(themeColorsProvider);
        return AlertDialog(
          backgroundColor: colors.surface,
          title: Text(
            context.tr('新建电台分类'),
            style: TextStyle(fontSize: 17, color: colors.textPrimary),
          ),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: TextStyle(fontSize: 14, color: colors.textPrimary),
            decoration: _fieldDecoration(colors, hint: context.tr('分类名称')),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                context.tr('取消'),
                style: TextStyle(color: colors.textHint),
              ),
            ),
            TextButton(
              onPressed: () {
                final value = controller.text.trim();
                if (value.isEmpty) return;
                Navigator.pop(ctx, value);
              },
              child: Text(
                context.tr('创建'),
                style: TextStyle(color: colors.primary),
              ),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (name == null) return;
    final category = await ref.read(radioProvider.notifier).addCategory(name);
    if (!mounted) return;
    setState(() => _categoryId = category.id);
  }

  /// 删除分类：分类里的电台回到「全部」，电台本身保留。
  Future<void> _removeCategory(RadioCategory category) async {
    if (category.isAll) return;
    final colors = ref.read(themeColorsProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('删除分类'),
          style: TextStyle(fontSize: 17, color: colors.textPrimary),
        ),
        content: Text(
          context.tr('删除「${category.name}」后，里面的电台会回到「全部」，电台本身不会删除。'),
          style: TextStyle(fontSize: 14, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              context.tr('删除'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await ref.read(radioProvider.notifier).removeCategory(category.id);
    if (!mounted) return;
    if (_categoryId == category.id) {
      setState(() => _categoryId = RadioCategory.allId);
    }
  }

  Widget _buildSourceSection(ThemeColors colors, List<SourceInfo> sources) {
    return _buildSection(
      colors,
      title: context.tr('音源'),
      subtitle: context.tr('可多选；某个音源被关闭 / 卸载时会自动用其它音源'),
      child: sources.isEmpty
          ? Text(
              context.tr('当前没有可用的音源'),
              style: TextStyle(fontSize: 13, color: colors.textHint),
            )
          : Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final source in sources)
                  _buildChoice(
                    colors,
                    label: source.name,
                    selected: _sources.contains(source.id),
                    onTap: () {
                      setState(() {
                        if (!_sources.remove(source.id)) {
                          _sources.add(source.id);
                        }
                      });
                      if (_sources.contains(source.id)) {
                        _ensureTagsLoaded(source.id);
                      }
                      // 音源被取消勾选时，把这个音源下的分类也一起取消。
                      _tags.removeWhere(
                        (_, tag) => !_sources.contains(tag.sourceId),
                      );
                    },
                  ),
              ],
            ),
    );
  }

  Widget _buildTagSection(ThemeColors colors) {
    return _buildSection(
      colors,
      title: context.tr('歌单分类'),
      subtitle: context.tr('可选：随机从这些分类的歌单里取歌'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final sourceId in _sources) _buildSourceTags(colors, sourceId),
          if (_sources.isEmpty)
            Text(
              context.tr('先选择音源，再挑分类'),
              style: TextStyle(fontSize: 13, color: colors.textHint),
            ),
        ],
      ),
    );
  }

  Widget _buildSourceTags(ThemeColors colors, String sourceId) {
    final groups = _tagGroups[sourceId];
    if (groups == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        child: Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: colors.primary,
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              context.tr('正在加载分类…'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ],
        ),
      );
    }
    final tags = [
      for (final group in groups) ...group.tags,
    ].where((tag) => tag.id.isNotEmpty).toList(growable: false);
    if (tags.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Text(
          context.tr('$sourceId 没有提供分类'),
          style: TextStyle(fontSize: 12, color: colors.textHint),
        ),
      );
    }
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: [
        for (final tag in tags)
          _buildChoice(
            colors,
            label: tag.name,
            selected: _tags.containsKey('$sourceId|${tag.id}'),
            onTap: () {
              final key = '$sourceId|${tag.id}';
              setState(() {
                if (_tags.containsKey(key)) {
                  _tags.remove(key);
                } else {
                  _tags[key] = RadioTagRef(
                    sourceId: sourceId,
                    tagId: tag.id,
                    tagName: tag.name,
                  );
                }
              });
            },
          ),
      ],
    );
  }

  Widget _buildKeywordSection(ThemeColors colors) {
    return _buildSection(
      colors,
      title: context.tr('搜索歌单关键词'),
      subtitle: context.tr('可选：按这些关键词搜歌单，再随机取歌'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _keywordController,
                  style: TextStyle(fontSize: 14, color: colors.textPrimary),
                  decoration: _fieldDecoration(
                    colors,
                    hint: context.tr('例如：华语 情歌'),
                  ),
                  onSubmitted: (_) => _addKeyword(),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              _buildSmallButton(
                colors,
                icon: Icons.add,
                label: context.tr('添加'),
                onTap: _addKeyword,
              ),
            ],
          ),
          if (_keywords.isNotEmpty) ...[
            const SizedBox(height: AppSpacing.sm),
            Wrap(
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              children: [
                for (final keyword in _keywords)
                  InputChip(
                    label: Text(
                      keyword,
                      style: TextStyle(fontSize: 12, color: colors.textPrimary),
                    ),
                    backgroundColor: colors.surfaceVariant,
                    side: BorderSide(color: colors.divider),
                    onDeleted: () => setState(() => _keywords.remove(keyword)),
                    deleteIconColor: colors.textHint,
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  void _addKeyword() {
    final value = _keywordController.text.trim();
    if (value.isEmpty) return;
    if (!_keywords.contains(value)) {
      setState(() => _keywords.add(value));
    }
    _keywordController.clear();
  }

  Widget _buildChoice(
    ThemeColors colors, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
    VoidCallback? onDelete,
  }) {
    final chip = Container(
      padding: EdgeInsets.fromLTRB(
        AppSpacing.md,
        6,
        onDelete == null ? AppSpacing.md : AppSpacing.lg,
        6,
      ),
      decoration: BoxDecoration(
        color: selected
            ? colors.primary.withValues(alpha: 0.15)
            : colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.full),
        border: Border.all(color: selected ? colors.primary : colors.divider),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: selected ? colors.primary : colors.textSecondary,
        ),
      ),
    );
    final choice = GestureDetector(onTap: onTap, child: chip);
    if (onDelete == null) return choice;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        choice,
        Positioned(
          right: -6,
          top: -6,
          child: Semantics(
            button: true,
            label: context.tr('删除分类'),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onDelete,
              child: SizedBox(
                width: 26,
                height: 26,
                child: Center(
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: colors.error,
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.background, width: 1.5),
                    ),
                    child: const Icon(
                      Icons.close_rounded,
                      size: 10,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final cover = _coverSource.trim();
    if (name.isEmpty) {
      _toast(context.tr('请填写电台名称'));
      return;
    }
    if (cover.isEmpty) {
      _toast(context.tr('请设置电台封面'));
      return;
    }
    if (_tags.isEmpty && _keywords.isEmpty) {
      _toast(context.tr('歌单分类和搜索关键词至少填一个'));
      return;
    }
    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final station = RadioStation(
        id: widget.station?.id ?? 'radio_${now.millisecondsSinceEpoch}',
        name: name,
        coverUrl: cover,
        coverPath: widget.station?.coverPath,
        categoryId: _categoryId,
        sourceIds: _sources.toList(growable: false),
        tags: _tags.values.toList(growable: false),
        keywords: List.of(_keywords),
        createTime: widget.station?.createTime ?? now,
        updateTime: now,
      );
      await ref.read(radioProvider.notifier).saveStation(station);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) _toast(context.tr('保存失败：$e'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );
  }
}
