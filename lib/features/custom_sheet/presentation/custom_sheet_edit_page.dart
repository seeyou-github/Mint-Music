import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../application/custom_sheet_providers.dart';

/// 打开「新增 / 编辑自定义歌单」页面，保存成功返回 true。
///
/// 歌单的搜索关键字决定内容：详情页会用 [CustomSheet.sourceId] 这个音源按
/// 关键字搜索，搜索结果就是歌单里的歌。
Future<bool?> showCustomSheetEditor(
  BuildContext context, {
  required String sourceId,
  String sourceName = '',
  CustomSheet? sheet,
  String categoryId = '',
}) {
  return Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => CustomSheetEditPage(
        sourceId: sourceId,
        sourceName: sourceName,
        sheet: sheet,
        initialCategoryId: categoryId,
      ),
    ),
  );
}

class CustomSheetEditPage extends ConsumerStatefulWidget {
  const CustomSheetEditPage({
    super.key,
    required this.sourceId,
    this.sourceName = '',
    this.sheet,
    this.initialCategoryId = '',
  });

  final String sourceId;
  final String sourceName;
  final CustomSheet? sheet;
  final String initialCategoryId;

  @override
  ConsumerState<CustomSheetEditPage> createState() =>
      _CustomSheetEditPageState();
}

class _CustomSheetEditPageState extends ConsumerState<CustomSheetEditPage> {
  late final TextEditingController _nameController = TextEditingController(
    text: widget.sheet?.name ?? '',
  );
  late final TextEditingController _keywordController = TextEditingController(
    text: widget.sheet?.keyword ?? '',
  );
  late final TextEditingController _coverController = TextEditingController(
    text: (widget.sheet?.coverUrl.startsWith('http') ?? false)
        ? widget.sheet!.coverUrl
        : '',
  );

  late String _coverSource = widget.sheet?.coverUrl ?? '';
  late String _categoryId =
      widget.sheet?.categoryId ?? widget.initialCategoryId;

  bool _saving = false;

  bool get _isEditing => widget.sheet != null;

  @override
  void dispose() {
    _nameController.dispose();
    _keywordController.dispose();
    _coverController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final data = ref.watch(customSheetProvider);

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
                    title: context.tr('歌单名称'),
                    child: TextField(
                      controller: _nameController,
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                      decoration: _fieldDecoration(
                        colors,
                        hint: context.tr('给歌单起个名字'),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _buildSection(
                    colors,
                    title: context.tr('搜索关键字'),
                    subtitle: context.tr('歌单内容 = 用这个关键字搜索得到的歌曲'),
                    child: TextField(
                      controller: _keywordController,
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                      decoration: _fieldDecoration(
                        colors,
                        hint: context.tr('例如：周杰伦、钢琴曲、白噪音'),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  _buildCategorySection(colors, data.categories),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    context.tr(
                      '歌单绑定音源：${widget.sourceName.isEmpty ? widget.sourceId : widget.sourceName}',
                    ),
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
              context.tr(_isEditing ? '编辑歌单' : '新增歌单'),
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
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
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
      title: context.tr('歌单封面'),
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
        child: Icon(Icons.queue_music, size: 32, color: colors.textHint),
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

  Widget _buildCategorySection(
    ThemeColors colors,
    List<CustomSheetCategory> categories,
  ) {
    return _buildSection(
      colors,
      title: context.tr('歌单分类'),
      subtitle: context.tr('可以不选；分类可以在右侧「管理」里增删改'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _buildChoice(
                colors,
                label: context.tr('未分类'),
                selected: _categoryId.isEmpty,
                onTap: () => setState(() => _categoryId = ''),
              ),
              for (final category in categories)
                _buildChoice(
                  colors,
                  label: category.name,
                  selected: category.id == _categoryId,
                  onTap: () => setState(() => _categoryId = category.id),
                ),
              GestureDetector(
                onTap: _showCategoryManager,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(AppRadius.full),
                    border: Border.all(color: colors.divider),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.tune, size: 13, color: colors.textSecondary),
                      const SizedBox(width: 4),
                      Text(
                        context.tr('管理分类'),
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildChoice(
    ThemeColors colors, {
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: 6,
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
      ),
    );
  }

  Future<void> _showCategoryManager() async {
    final colors = ref.read(themeColorsProvider);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => _SheetCategoryManagerSheet(colors: colors),
    );
    if (!mounted) return;
    // 当前选中的分类可能已被删除。
    if (_categoryId.isNotEmpty &&
        ref.read(customSheetProvider).categoryById(_categoryId) == null) {
      setState(() => _categoryId = '');
    }
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

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final keyword = _keywordController.text.trim();
    final cover = _coverSource.trim();
    final colors = ref.read(themeColorsProvider);

    void toast(String message) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
      );
    }

    if (cover.isEmpty) {
      toast(context.tr('请先设置歌单封面'));
      return;
    }
    if (name.isEmpty) {
      toast(context.tr('请填写歌单名称'));
      return;
    }
    if (keyword.isEmpty) {
      toast(context.tr('请填写搜索关键字'));
      return;
    }

    setState(() => _saving = true);
    try {
      final notifier = ref.read(customSheetProvider.notifier);
      final base =
          widget.sheet ??
          notifier.draft(sourceId: widget.sourceId, categoryId: _categoryId);
      await notifier.saveSheet(
        base.copyWith(
          sourceId: widget.sourceId,
          name: name,
          keyword: keyword,
          coverUrl: cover,
          categoryId: _categoryId,
        ),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      toast(context.tr('保存失败: $e'));
      debugPrint('[CustomSheetEditPage] 保存失败: $e / $colors');
    }
  }
}

/// 歌单分类管理：新建 / 改名 / 删除。
class _SheetCategoryManagerSheet extends ConsumerStatefulWidget {
  const _SheetCategoryManagerSheet({required this.colors});

  final ThemeColors colors;

  @override
  ConsumerState<_SheetCategoryManagerSheet> createState() =>
      _SheetCategoryManagerSheetState();
}

class _SheetCategoryManagerSheetState
    extends ConsumerState<_SheetCategoryManagerSheet> {
  final TextEditingController _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final categories = ref.watch(customSheetProvider).categories;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      context.tr('歌单分类管理'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      context.tr('完成'),
                      style: TextStyle(color: colors.primary),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: context.tr('新分类名称'),
                        hintStyle: TextStyle(
                          fontSize: 14,
                          color: colors.textHint,
                        ),
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
                      ),
                      onSubmitted: (_) => _create(),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    onPressed: _create,
                    child: Text(
                      context.tr('新建'),
                      style: TextStyle(color: colors.primary, fontSize: 14),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Flexible(
              child: categories.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(AppSpacing.xl),
                      child: Text(
                        context.tr('还没有分类，先在上面新建一个'),
                        style: TextStyle(fontSize: 13, color: colors.textHint),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                      ),
                      itemCount: categories.length,
                      itemBuilder: (context, index) {
                        final category = categories[index];
                        return ListTile(
                          dense: true,
                          title: Text(
                            category.name,
                            style: TextStyle(
                              fontSize: 14,
                              color: colors.textPrimary,
                            ),
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                tooltip: context.tr('改名'),
                                icon: Icon(
                                  Icons.edit_outlined,
                                  size: 18,
                                  color: colors.textSecondary,
                                ),
                                onPressed: () => _rename(category),
                              ),
                              IconButton(
                                tooltip: context.tr('删除'),
                                icon: Icon(
                                  Icons.delete_outline,
                                  size: 18,
                                  color: colors.error,
                                ),
                                onPressed: () => _remove(category),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) return;
    await ref.read(customSheetProvider.notifier).addCategory(name);
    _nameController.clear();
  }

  Future<void> _rename(CustomSheetCategory category) async {
    final colors = widget.colors;
    final controller = TextEditingController(text: category.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('分类改名'),
          style: TextStyle(fontSize: 17, color: colors.textPrimary),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: TextStyle(fontSize: 14, color: colors.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: colors.surfaceVariant,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide.none,
            ),
          ),
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
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(
              context.tr('保存'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    await ref
        .read(customSheetProvider.notifier)
        .renameCategory(category.id, name);
  }

  Future<void> _remove(CustomSheetCategory category) async {
    final colors = widget.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('删除分类'),
          style: TextStyle(fontSize: 17, color: colors.textPrimary),
        ),
        content: Text(
          context.tr('删除「${category.name}」后，里面的歌单会变成「未分类」，歌单本身不会删除。'),
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
    if (ok != true) return;
    await ref.read(customSheetProvider.notifier).removeCategory(category.id);
  }
}
