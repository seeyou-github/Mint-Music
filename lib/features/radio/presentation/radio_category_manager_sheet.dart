import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../application/radio_providers.dart';

/// 打开「电台分类管理」弹框：已建电台的排序 / 删除 / 新增，以及分类的
/// 新建 / 排序 / 改名 / 删除。
///
/// 电台面板与新增 / 编辑电台页共用；[onCreated] 在新建分类后回调，
/// 调用方可以把新分类设为当前选中；[onAddStation] 用于弹框右上角的
/// 「新增电台」。
Future<void> showRadioCategoryManagerSheet(
  BuildContext context, {
  required ThemeColors colors,
  required ValueChanged<RadioCategory> onCreated,
  VoidCallback? onAddStation,
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
    builder: (_) => RadioCategoryManagerSheet(
      colors: colors,
      onCreated: onCreated,
      onAddStation: onAddStation,
    ),
  );
}

/// 电台分类管理弹框：已建电台列表、新建分类输入框、已建分类列表。
class RadioCategoryManagerSheet extends ConsumerStatefulWidget {
  const RadioCategoryManagerSheet({
    super.key,
    required this.colors,
    required this.onCreated,
    this.onAddStation,
  });

  final ThemeColors colors;

  /// 新建分类后回调（调用方把新分类设为当前选中）。
  final ValueChanged<RadioCategory> onCreated;

  /// 点「新增电台」时打开新增页面。
  final VoidCallback? onAddStation;

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
    final data = ref.watch(radioProvider);
    // 「全部」是内置分类，不参与管理。
    final categories = [
      for (final category in data.categories)
        if (!category.isAll) category,
    ];
    final stations = data.stations;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  Expanded(child: _sectionTitle(context.tr('已创建的电台'))),
                  if (widget.onAddStation != null)
                    _buildPillButton(
                      context.tr('新增电台'),
                      widget.onAddStation,
                    ),
                ],
              ),
            ),
            Expanded(
              flex: 3,
              child: stations.isEmpty
                  ? _emptyHint(context.tr('还没有创建电台'))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(
                        top: AppSpacing.xs,
                        bottom: AppSpacing.sm,
                      ),
                      buildDefaultDragHandles: false,
                      itemCount: stations.length,
                      onReorder: (oldIndex, newIndex) => ref
                          .read(radioProvider.notifier)
                          .reorderStations(oldIndex, newIndex),
                      itemBuilder: (context, index) =>
                          _stationRow(stations, index),
                    ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.sm,
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
                  _buildPillButton(
                    context.tr('新增分类'),
                    _creating ? null : _create,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.xs,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: _sectionTitle(context.tr('已建分类')),
            ),
            Expanded(
              flex: 2,
              child: categories.isEmpty
                  ? _emptyHint(context.tr('还没有自建分类'))
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.only(
                        top: AppSpacing.xs,
                        bottom: AppSpacing.lg,
                      ),
                      buildDefaultDragHandles: false,
                      itemCount: categories.length,
                      onReorder: (oldIndex, newIndex) => ref
                          .read(radioProvider.notifier)
                          .reorderCategories(oldIndex, newIndex),
                      itemBuilder: (context, index) =>
                          _categoryRow(categories, index),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: widget.colors.textPrimary,
      ),
    );
  }

  /// 描边胶囊按钮（弹框里的「新增电台 / 新增分类」）。
  ///
  /// 文字用正常字重（w400），避免 13px 的 w500 在深色底上显得发粗；
  /// 内边距放大到 16×8、字号 14，让按钮高度接近旁边的输入框。
  Widget _buildPillButton(String label, VoidCallback? onTap) {
    final colors = widget.colors;
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: colors.primary,
        side: BorderSide(
          color: onTap == null ? colors.divider : colors.primary,
        ),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
      ),
      child: Text(label),
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
