import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../discover/application/discover_providers.dart';
import '../../player/application/playback_controller.dart';
import '../application/radio_providers.dart';
import '../application/radio_session.dart';
import 'radio_edit_page.dart';

/// 发现页的「电台」分类：分类栏 + 电台列表。
class RadioPanel extends ConsumerStatefulWidget {
  const RadioPanel({super.key});

  @override
  ConsumerState<RadioPanel> createState() => _RadioPanelState();
}

class _RadioPanelState extends ConsumerState<RadioPanel> {
  String _categoryId = RadioCategory.allId;
  String? _startingId;

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final data = ref.watch(radioProvider);

    // 当前分类被删掉时回到「全部」。
    if (_categoryId != RadioCategory.allId &&
        !data.categories.any((c) => c.id == _categoryId)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _categoryId != RadioCategory.allId) {
          setState(() => _categoryId = RadioCategory.allId);
        }
      });
    }

    return Column(
      children: [
        _buildCategoryBar(colors),
        const SizedBox(height: AppSpacing.sm),
        Expanded(child: _buildBody(colors)),
      ],
    );
  }

  // ------------------------------------------------------------ 分类栏

  Widget _buildCategoryBar(ThemeColors colors) {
    final data = ref.watch(radioProvider);
    final categories = [RadioCategory.all, ...data.categories];
    return SizedBox(
      height: 40,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: ResponsiveLayout.horizontalPadding(context),
              ),
              itemCount: categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.md),
              itemBuilder: (context, index) {
                final category = categories[index];
                final selected = category.id == _categoryId;
                return GestureDetector(
                  onTap: () => setState(() => _categoryId = category.id),
                  onLongPress: category.isAll
                      ? null
                      : () => _confirmRemoveCategory(category),
                  child: Container(
                    alignment: Alignment.center,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: selected
                          ? colors.primary.withValues(alpha: 0.15)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      category.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        color: selected ? colors.primary : colors.textSecondary,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // 最右侧固定「添加新分类」（只有加号图标）
          Padding(
            padding: EdgeInsets.only(
              left: AppSpacing.sm,
              right: ResponsiveLayout.horizontalPadding(context),
            ),
            child: GestureDetector(
              onTap: _createCategory,
              child: Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: colors.divider),
                ),
                child: Icon(Icons.add, size: 18, color: colors.textSecondary),
              ),
            ),
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
            decoration: InputDecoration(
              isDense: true,
              hintText: context.tr('分类名称'),
              hintStyle: TextStyle(fontSize: 14, color: colors.textHint),
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
    if (name == null || name.trim().isEmpty) return;
    final category = await ref.read(radioProvider.notifier).addCategory(name);
    if (!mounted) return;
    setState(() => _categoryId = category.id);
  }

  Future<void> _confirmRemoveCategory(RadioCategory category) async {
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
    if (ok != true) return;
    await ref.read(radioProvider.notifier).removeCategory(category.id);
    if (!mounted) return;
    setState(() => _categoryId = RadioCategory.allId);
  }

  // ------------------------------------------------------------ 电台列表

  Widget _buildBody(ThemeColors colors) {
    final data = ref.watch(radioProvider);
    final stations = data.stationsIn(_categoryId);

    final cards = <Widget>[
      if (_categoryId == RadioCategory.allId) _buildRandomCard(colors),
      for (final station in stations) _buildStationCard(colors, station),
      _buildAddCard(colors),
    ];

    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.sm,
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.xxxl,
      ),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
        crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
        childAspectRatio: isTablet ? 0.86 : 0.8,
      ),
      itemCount: cards.length,
      itemBuilder: (context, index) => cards[index],
    );
  }

  Widget _buildRandomCard(ThemeColors colors) {
    final starting = _startingId == RadioStation.randomId;
    final isCurrent =
        ref.watch(radioSessionProvider)?.stationId == RadioStation.randomId;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    return _buildCardFrame(
      colors,
      child: InkWell(
        onTap: starting ? null : _startRandom,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    colors.primary.withValues(alpha: 0.85),
                    colors.primary.withValues(alpha: 0.35),
                  ],
                ),
              ),
              child: isCurrent
                  ? null
                  : Icon(
                      Icons.shuffle,
                      size: 44,
                      color: colors.textOnPrimary.withValues(alpha: 0.9),
                    ),
            ),
            Positioned(
              left: AppSpacing.sm,
              right: AppSpacing.sm,
              bottom: AppSpacing.sm,
              child: Text(
                context.tr('随机电台'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colors.textOnPrimary,
                ),
              ),
            ),
            if (isCurrent) _buildNowPlayingBadge(colors, isPlaying: isPlaying),
            if (starting)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStationCard(ThemeColors colors, RadioStation station) {
    final starting = _startingId == station.id;
    final isCurrent = ref.watch(radioSessionProvider)?.stationId == station.id;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    return _buildCardFrame(
      colors,
      child: InkWell(
        onTap: starting ? null : () => _startStation(station),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _buildCover(colors, station.displayCover, fallback: Icons.radio),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.sm,
                  12,
                  AppSpacing.sm,
                  AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.transparent,
                      Colors.black.withValues(alpha: 0.65),
                    ],
                  ),
                ),
                child: Text(
                  station.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 2,
              right: 2,
              child: _buildStationMenu(colors, station),
            ),
            if (isCurrent) _buildNowPlayingBadge(colors, isPlaying: isPlaying),
            if (starting)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.35),
                  child: const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 当前电台封面的正中央「正在播放 / 已暂停」标志：点一下切换播放与暂停。
  ///
  /// 标志直径取封面短边的 50%，随卡片尺寸缩放。
  Widget _buildNowPlayingBadge(ThemeColors colors, {required bool isPlaying}) {
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest.shortestSide * 0.5;
          return Center(
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                // 点击只落在标志上，不触发卡片的「重新开始电台」。
                behavior: HitTestBehavior.opaque,
                onTap: () => ref
                    .read(playbackControllerProvider.notifier)
                    .togglePlayPause(),
                child: Tooltip(
                  message: context.tr(isPlaying ? '暂停' : '播放'),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.8),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Icon(
                      isPlaying ? Icons.equalizer : Icons.play_arrow,
                      size: size * 0.58,
                      color: colors.primary,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildCardFrame(ThemeColors colors, {required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }

  Widget _buildCover(
    ThemeColors colors,
    String source, {
    required IconData fallback,
  }) {
    final value = source.trim();
    if (value.isEmpty) {
      return Container(
        color: colors.surfaceVariant,
        child: Icon(fallback, size: 40, color: colors.textHint),
      );
    }
    if (value.startsWith('http')) {
      return Image.network(
        value,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => Container(
          color: colors.surfaceVariant,
          child: Icon(fallback, size: 40, color: colors.textHint),
        ),
      );
    }
    return Image.file(
      File(value),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => Container(
        color: colors.surfaceVariant,
        child: Icon(fallback, size: 40, color: colors.textHint),
      ),
    );
  }

  Widget _buildStationMenu(ThemeColors colors, RadioStation station) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert,
        size: 18,
        color: Colors.white.withValues(alpha: 0.9),
      ),
      color: colors.surface,
      tooltip: context.tr('更多'),
      onSelected: (value) {
        if (value == 'edit') {
          _openEditor(station: station);
        } else if (value == 'delete') {
          _confirmRemoveStation(station);
        }
      },
      itemBuilder: (context) => [
        PopupMenuItem(
          value: 'edit',
          child: Text(
            context.tr('编辑电台'),
            style: TextStyle(color: colors.textPrimary, fontSize: 14),
          ),
        ),
        PopupMenuItem(
          value: 'delete',
          child: Text(
            context.tr('删除电台'),
            style: TextStyle(color: colors.error, fontSize: 14),
          ),
        ),
      ],
    );
  }

  Widget _buildAddCard(ThemeColors colors) {
    return GestureDetector(
      onTap: () => _openEditor(),
      child: Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(color: colors.divider),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add_circle_outline, size: 34, color: colors.textHint),
            const SizedBox(height: AppSpacing.sm),
            Text(
              context.tr('新增电台'),
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 操作

  Future<void> _openEditor({RadioStation? station}) async {
    final saved = await showRadioEditor(
      context,
      station: station,
      categoryId: _categoryId,
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr(station == null ? '电台已创建' : '电台已保存')),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _confirmRemoveStation(RadioStation station) async {
    final colors = ref.read(themeColorsProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
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

  Future<void> _startRandom() => _start(
    RadioStation.randomId,
    () => ref
        .read(radioSessionProvider.notifier)
        .startRandom(sourceId: ref.read(discoverSourceIdProvider)),
  );

  Future<void> _startStation(RadioStation station) => _start(
    station.id,
    () => ref.read(radioSessionProvider.notifier).startStation(station),
  );

  Future<void> _start(String id, Future<void> Function() start) async {
    if (_startingId != null) return;
    setState(() => _startingId = id);
    try {
      await start();
      if (!mounted) return;
      // 进入播放详情页（电台模式下部分控制按钮不可用）。
      // 不 await：等页面关闭才回来的话，这里的「正在启动」状态会一直挂着。
      unawaited(context.push(AppRoutes.fullPlayer));
    } on RadioException catch (e) {
      if (mounted) await _showError(e.message);
    } catch (e) {
      if (mounted) await _showError(context.tr('电台启动失败：$e'));
    } finally {
      if (mounted) setState(() => _startingId = null);
    }
  }

  Future<void> _showError(String message) {
    final colors = ref.read(themeColorsProvider);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('无法播放电台'),
          style: TextStyle(fontSize: 17, color: colors.textPrimary),
        ),
        content: Text(
          message,
          style: TextStyle(fontSize: 14, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              context.tr('知道了'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
  }
}
