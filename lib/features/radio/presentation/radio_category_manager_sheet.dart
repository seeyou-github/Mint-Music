import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../application/radio_providers.dart';

/// 打开「电台分类管理」弹框：新建 + 已建分类的排序 / 改名 / 删除。
///
/// 电台面板与新增 / 编辑电台页共用；[onCreated] 在新建分类后回调，
/// 调用方可以把新分类设为当前选中。
Future<void> showRadioCategoryManagerSheet(
  BuildContext context, {
  required ThemeColors colors,
  required ValueChanged<RadioCategory> onCreated,
}) {
  return showModalBottomSheet<void>(
    useRootNavigator: true,
    context: context,
    isScrollControlled: true,
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 220),
      reverseDuration: Duration(milliseconds: 180),
    ),
    backgroundColor: colors.dialogSurface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
    ),
    builder: (_) =>
        RadioCategoryManagerSheet(colors: colors, onCreated: onCreated),
  );
}

/// 电台分类管理弹框：顶部新建，下方列出已建分类（拖动排序 / 点名称修改 / 删除）。
class RadioCategoryManagerSheet extends ConsumerStatefulWidget {
  const RadioCategoryManagerSheet({
    super.key,
    required this.colors,
    required this.onCreated,
  });

  final ThemeColors colors;

  /// 新建分类后回调（调用方把新分类设为当前选中）。
  final ValueChanged<RadioCategory> onCreated;

  @override
  ConsumerState<RadioCategoryManagerSheet> createState() =>
      _RadioCategoryManagerSheetState();
}

class _RadioCategoryManagerSheetState
    extends ConsumerState<RadioCategoryManagerSheet> {
  final TextEditingController _nameController = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() => _creating = true);
    try {
      final category = await ref.read(radioProvider.notifier).addCategory(name);
      _nameController.clear();
      if (mounted) widget.onCreated(category);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  Future<void> _rename(RadioCategory category) async {
    final colors = widget.colors;
    final controller = TextEditingController(text: category.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
        title: Text(
          context.tr('修改分类名称'),
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
              if (value.isEmpty || value == category.name) return;
              Navigator.pop(ctx, value);
            },
            child: Text(
              context.tr('保存'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    await ref.read(radioProvider.notifier).renameCategory(category.id, name);
  }

  /// 删除分类：分类里的电台回到「全部」，电台本身保留。
  Future<void> _delete(RadioCategory category) async {
    final colors = widget.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
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
    if (ok != true) return;
    await ref.read(radioProvider.notifier).removeCategory(category.id);
  }

  /// 从分类管理弹框里删除电台（与电台页的删除确认一致）。
  Future<void> _deleteStation(RadioStation station) async {
    final colors = widget.colors;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
        title: Text(
          context.tr('删除电台'),
          style: TextStyle(fontSize: 17, color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定删除「${station.name}」吗？'),
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
    await ref.read(radioProvider.notifier).removeStation(station.id);
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    // 「全部」是内置分类，不参与管理。
    final categories = [
      for (final category in ref.watch(radioProvider).categories)
        if (!category.isAll) category,
    ];
    final stations = ref.watch(radioProvider).stations;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('新建电台分类'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    context.tr('分类可拖动排序、点名称改名；电台可拖动排序、删除'),
                    style: TextStyle(fontSize: 12, color: colors.textHint),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                0,
                AppSpacing.lg,
                AppSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _nameController,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _create(),
                      style: TextStyle(fontSize: 14, color: colors.textPrimary),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: context.tr('输入新分类名称'),
                        hintStyle: TextStyle(
                          fontSize: 13,
                          color: colors.textHint,
                        ),
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
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  TextButton(
                    onPressed: _creating ? null : _create,
                    child: Text(
                      context.tr(_creating ? '创建中' : '创建'),
                      style: TextStyle(color: colors.primary),
                    ),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: colors.divider.withValues(alpha: 0.4)),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _sectionLabel(
                      context.tr('已建分类'),
                      context.tr('拖动排序；点名称可修改'),
                    ),
                    if (categories.isEmpty)
                      _emptyHint(context.tr('还没有自建分类'))
                    else
                      ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        buildDefaultDragHandles: false,
                        itemCount: categories.length,
                        onReorder: (oldIndex, newIndex) => ref
                            .read(radioProvider.notifier)
                            .reorderCategories(oldIndex, newIndex),
                        itemBuilder: (context, index) =>
                            _categoryRow(categories, index),
                      ),
                    _sectionLabel(
                      context.tr('已创建的电台'),
                      context.tr('拖动排序；电台页按此顺序显示'),
                    ),
                    if (stations.isEmpty)
                      _emptyHint(context.tr('还没有创建电台'))
                    else
                      ReorderableListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        padding: EdgeInsets.zero,
                        buildDefaultDragHandles: false,
                        itemCount: stations.length,
                        onReorder: (oldIndex, newIndex) => ref
                            .read(radioProvider.notifier)
                            .reorderStations(oldIndex, newIndex),
                        itemBuilder: (context, index) =>
                            _stationRow(stations, index),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionLabel(String title, String hint) {
    final colors = widget.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              hint,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.textHint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyHint(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.sm,
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12, color: widget.colors.textHint),
      ),
    );
  }

  Widget _categoryRow(List<RadioCategory> categories, int index) {
    final colors = widget.colors;
    final category = categories[index];
    return Container(
      key: ValueKey(category.id),
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 2, AppSpacing.xs, 2),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.drag_handle, size: 20, color: colors.textHint),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () => _rename(category),
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  category.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 14, color: colors.textPrimary),
                ),
              ),
            ),
          ),
          IconButton(
            tooltip: context.tr('修改名称'),
            icon: Icon(Icons.edit_outlined, size: 18, color: colors.textHint),
            onPressed: () => _rename(category),
          ),
          IconButton(
            tooltip: context.tr('删除'),
            icon: Icon(Icons.delete_outline, size: 18, color: colors.error),
            onPressed: () => _delete(category),
          ),
        ],
      ),
    );
  }

  Widget _stationRow(List<RadioStation> stations, int index) {
    final colors = widget.colors;
    final station = stations[index];
    return Container(
      key: ValueKey('station:${station.id}'),
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 2, AppSpacing.xs, 2),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.drag_handle, size: 20, color: colors.textHint),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                station.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, color: colors.textPrimary),
              ),
            ),
          ),
          IconButton(
            tooltip: context.tr('删除'),
            icon: Icon(Icons.delete_outline, size: 18, color: colors.error),
            onPressed: () => _deleteStation(station),
          ),
        ],
      ),
    );
  }
}
