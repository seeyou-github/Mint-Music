import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../discover/application/discover_providers.dart';
import '../../player/application/playback_controller.dart';
import '../application/radio_providers.dart';
import '../application/radio_session.dart';
import 'radio_category_manager_sheet.dart';
import 'radio_edit_page.dart';

/// 发现页的「电台」分类：分类栏 + 电台列表。
class RadioPanel extends ConsumerStatefulWidget {
  const RadioPanel({super.key});

  @override
  ConsumerState<RadioPanel> createState() => _RadioPanelState();
}

class _RadioPanelState extends ConsumerState<RadioPanel> {
  String _categoryId = RadioCategory.allId;

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
    // 尺寸 / 字体与发现页歌单分类栏保持一致：36 高、13 号字、12×4 内边距、
    // 圆角 6、标签间距 8。
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.only(
                left: AppSpacing.lg,
                right: ResponsiveLayout.horizontalPadding(context),
              ),
              itemCount: categories.length,
              separatorBuilder: (_, _) => const SizedBox(width: AppSpacing.sm),
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: selected
                          ? activeChipColor(colors)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      category.name,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                        // 激活的分类名称用主题色（与侧栏「发现」一致）。
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

  /// 电台分类管理弹框：新建 + 已建分类的排序 / 改名 / 删除。
  ///
  /// 删除当前选中的分类不用额外处理：build 里的兜底会自动回到「全部」。
  Future<void> _createCategory() async {
    final colors = ref.read(themeColorsProvider);
    await showRadioCategoryManagerSheet(
      context,
      colors: colors,
      onAddStation: () => _openEditor(categoryId: _categoryId),
      onCreated: (category) {
        if (mounted) setState(() => _categoryId = category.id);
      },
    );
  }

  Future<void> _confirmRemoveCategory(RadioCategory category) async {
    final colors = ref.read(themeColorsProvider);
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
      // 已经有电台就不再占一张卡片：「新增电台」收进分类管理弹框里。
      if (data.stations.isEmpty) _buildAddCard(colors),
    ];

    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);
    return GridView.builder(
      padding: EdgeInsets.fromLTRB(
        ResponsiveLayout.horizontalPadding(context),
        AppSpacing.sm,
        ResponsiveLayout.horizontalPadding(context),
        // 底部多留一段，最后一行电台卡片才不会被悬浮的迷你播放器挡住。
        AppSpacing.miniPlayerHeight + AppSpacing.lg,
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

  /// 随机电台的内置封面：用户没给自定义封面时用它，比「随机」图标更像一张
  /// 真的电台卡。图片随安装包内置（assets/images/radio_random_cover.jpg）。
  static const String _randomCoverAsset =
      'assets/images/radio_random_cover.jpg';

  Widget _buildRandomCard(ThemeColors colors) {
    final starting =
        ref.watch(radioStartingStationProvider) == RadioStation.randomId;
    final isCurrent =
        ref.watch(radioSessionProvider)?.stationId == RadioStation.randomId;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    final isLoading = ref.watch(
      playbackControllerProvider.select((state) => state.isLoading),
    );
    final config = ref.watch(
      radioProvider.select((data) => data.randomStation),
    );
    // 设置过封面就用自己的封面；没有就退回内置的随机电台封面图。
    // 播放中背景保持电台自己的封面不变（不再换成当前歌曲的模糊封面）。
    final coverSource = config?.displayCover ?? '';
    // 名称跟随「外观设置 → 字体颜色」；蒙层按字色明暗反向取色，
    // 在内置深色封面 / 自定义封面上同样看得清。
    final nameColor = colors.textPrimary;
    final dimCover =
        coverSource.isNotEmpty &&
        !ref.watch(isLightThemeActiveProvider) &&
        (ref.watch(radioCoverLuminanceProvider(coverSource)).valueOrNull ??
                0) >=
            _brightCoverLuminance;
    // 底图始终存在（自定义封面 / 内置封面），所以
    // 名称下面永远垫色带、菜单按钮用白色。
    const onBackdrop = true;
    return _buildCardFrame(
      colors,
      child: InkWell(
        onTap: starting ? _cancelPendingStart : _startRandom,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverSource.isNotEmpty)
              _buildCover(
                colors,
                coverSource,
                fallback: Icons.shuffle,
                dim: dimCover,
              )
            else
              // 没有自定义封面：用内置的随机电台封面图，而不是「随机」图标。
              Image.asset(
                _randomCoverAsset,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            // 名称下面垫半透明色带，避免封面与字色接近时看不清。
            _buildNameOverlay(
              context.tr('随机电台'),
              textColor: nameColor,
              scrimColor: _scrimColorFor(nameColor),
              showBar: onBackdrop,
            ),
            Positioned(
              top: 2,
              right: 2,
              child: _buildRandomMenu(
                colors,
                onBackdrop: onBackdrop,
                hasConfig: config != null,
              ),
            ),
            // 播放中整卡压暗（与起播转圈的遮罩同色），铺在徽章下面，
            // 不影响徽章自身的点击；暂停后恢复不压暗。
            if (isCurrent && !starting && (isPlaying || isLoading))
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: _cardDimAlpha),
                  ),
                ),
              ),
            if (isCurrent && !starting)
              _buildNowPlayingBadge(
                colors,
                isPlaying: isPlaying,
                isLoading: isLoading,
              ),
            // 准备中的遮罩只负责显示转圈：必须忽略点击，否则会挡住
            // 卡片本身的「再点一次取消」手势。
            if (starting)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: Colors.black.withValues(alpha: _cardDimAlpha),
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
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStationCard(ThemeColors colors, RadioStation station) {
    final starting = ref.watch(radioStartingStationProvider) == station.id;
    final isCurrent = ref.watch(radioSessionProvider)?.stationId == station.id;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    final isLoading = ref.watch(
      playbackControllerProvider.select((state) => state.isLoading),
    );
    // 没设封面的电台共用默认封面（随机电台的封面，它也没配就用内置图）。
    // 播放中背景保持电台自己的封面不变（不再换成当前歌曲的模糊封面）。
    final randomCover = ref.watch(
      radioProvider.select(
        (data) => data.randomStation?.displayCover.trim() ?? '',
      ),
    );
    final ownCover = station.displayCover;
    final coverSource = ownCover.isNotEmpty ? ownCover : randomCover;
    // 名称跟随「外观设置 → 字体颜色」；蒙层按字色明暗反向取色，保证
    // 浅色主题（黑字）时名称仍然看得清。
    final nameColor = colors.textPrimary;
    final scrimColor = _scrimColorFor(nameColor);
    // 深色模式下亮色封面会盖过右上角菜单和歌名，压一层 30% 黑。
    final dimCover =
        coverSource.isNotEmpty &&
        !ref.watch(isLightThemeActiveProvider) &&
        (ref.watch(radioCoverLuminanceProvider(coverSource)).valueOrNull ??
                0) >=
            _brightCoverLuminance;
    return _buildCardFrame(
      colors,
      child: InkWell(
        onTap: starting ? _cancelPendingStart : () => _startStation(station),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (coverSource.isNotEmpty)
              _buildCover(
                colors,
                coverSource,
                fallback: Icons.radio,
                dim: dimCover,
              )
            else
              Image.asset(
                _randomCoverAsset,
                width: double.infinity,
                height: double.infinity,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.high,
              ),
            _buildNameOverlay(
              station.name,
              textColor: nameColor,
              scrimColor: scrimColor,
              showBar: true,
            ),
            Positioned(
              top: 2,
              right: 2,
              child: _buildStationMenu(colors, station),
            ),
            // 播放中整卡压暗（与起播转圈的遮罩同色），铺在徽章下面，
            // 不影响徽章自身的点击；暂停后恢复不压暗。
            if (isCurrent && !starting && (isPlaying || isLoading))
              Positioned.fill(
                child: IgnorePointer(
                  child: ColoredBox(
                    color: Colors.black.withValues(alpha: _cardDimAlpha),
                  ),
                ),
              ),
            if (isCurrent && !starting)
              _buildNowPlayingBadge(
                colors,
                isPlaying: isPlaying,
                isLoading: isLoading,
              ),
            // 准备中的遮罩只负责显示转圈：必须忽略点击，否则会挡住
            // 卡片本身的「再点一次取消」手势。
            if (starting)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    color: Colors.black.withValues(alpha: _cardDimAlpha),
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
              ),
          ],
        ),
      ),
    );
  }

  /// 卡片底部的电台名称。
  ///
  /// 封面颜色和文字接近时（浅底配浅字 / 深底配深字）看不清名称，所以在
  /// 名称下面垫一条通栏的半透明色带；色带按字色明暗反向取色
  /// （[scrimColor]，深色字配白色带、浅色字配黑色带）。
  /// 色带顶部保持水平硬边：不在上方叠渐变，整条颜色均匀，封面与色带
  /// 直接分界，避免渐变把封面上半段也拖暗、显得发糊。
  Widget _buildNameOverlay(
    String name, {
    required Color textColor,
    required Color scrimColor,
    required bool showBar,
  }) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.sm,
          AppSpacing.md,
          AppSpacing.sm,
          AppSpacing.sm,
        ),
        color: showBar ? scrimColor.withValues(alpha: 0.55) : null,
        child: Text(
          name,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            // 名称跟随「外观设置 → 字体颜色」。
            color: textColor,
          ),
        ),
      ),
    );
  }

  /// 当前电台封面的正中央「正在播放 / 已暂停」标志：点一下切换播放与暂停。
  ///
  /// 标志直径取封面短边的 50%，随卡片尺寸缩放。
  ///
  /// 播放中只显示静态暂停图标，不做任何动画：电台是一首接一首自动换的，
  /// 原本那三根 `repeat()` 跳动的音柱既是永不结束的 60fps 动画（卡片常驻在
  /// 发现页里，最小化也照跑），看久了也像卡在“正在加载”。
  Widget _buildNowPlayingBadge(
    ThemeColors colors, {
    required bool isPlaying,
    required bool isLoading,
  }) {
    // 换歌 / 缓冲期间也算「正在播放」：电台由自己接管下一首，此时不该退回
    // 三角图标闪一下，保持暂停图标可点（随时能暂停）。
    final showPause = isPlaying || isLoading;
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
                onTap: () {
                  final controller = ref.read(
                    playbackControllerProvider.notifier,
                  );
                  // 换歌 / 解析地址期间点一下就是「停止这次加载」。
                  if (isLoading) {
                    controller.cancelLoading();
                  } else {
                    controller.togglePlayPause();
                  }
                },
                child: Tooltip(
                  message: context.tr(
                    isLoading ? '停止加载' : (showPause ? '暂停' : '播放'),
                  ),
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: Icon(
                      showPause ? Icons.pause : Icons.play_arrow,
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
    bool dim = false,
  }) {
    final value = source.trim();
    if (value.isEmpty) {
      return Container(
        color: colors.surfaceVariant,
        child: Icon(fallback, size: 40, color: colors.textHint),
      );
    }
    // 小图也要铺满整张卡片：显式给满尺寸 + cover 放大，并用高质量插值平滑
    // 放大后的边缘，避免小尺寸封面在卡片里缩成一块或发糊。
    Widget image(String path) => path.startsWith('http')
        ? Image.network(
            path,
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => _buildCoverFallback(colors, fallback),
          )
        : Image.file(
            File(path),
            width: double.infinity,
            height: double.infinity,
            fit: BoxFit.cover,
            filterQuality: FilterQuality.high,
            errorBuilder: (_, _, _) => _buildCoverFallback(colors, fallback),
          );

    final cover = image(value);
    if (!dim) return cover;
    return Stack(
      fit: StackFit.expand,
      children: [
        cover,
        // 亮色封面压 30% 黑，保证右上角菜单和底部歌名仍然看得清。
        ColoredBox(color: Colors.black.withValues(alpha: 0.3)),
      ],
    );
  }

  Widget _buildCoverFallback(ThemeColors colors, IconData fallback) {
    return Container(
      color: colors.surfaceVariant,
      child: Icon(fallback, size: 40, color: colors.textHint),
    );
  }

  Widget _buildStationMenu(ThemeColors colors, RadioStation station) {
    return PopupMenuButton<String>(
      icon: Icon(
        Icons.more_vert,
        size: 18,
        color: Colors.white.withValues(alpha: 0.9),
      ),
      color: colors.dialogSurface,
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

  /// 随机电台卡片右上角的菜单：编辑 / 重置。
  Widget _buildRandomMenu(
    ThemeColors colors, {
    required bool onBackdrop,
    required bool hasConfig,
  }) {
    // 封面 / 模糊背景上必须用白色，纯色底上跟随字体颜色。
    final iconColor = onBackdrop
        ? Colors.white.withValues(alpha: 0.9)
        : colors.textPrimary.withValues(alpha: 0.8);
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 18, color: iconColor),
      color: colors.dialogSurface,
      tooltip: context.tr('更多'),
      onSelected: (value) {
        if (value == 'edit') {
          _openRandomEditor();
        } else if (value == 'reset') {
          _confirmResetRandom();
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
          value: 'reset',
          enabled: hasConfig,
          child: Text(
            context.tr('重置电台'),
            style: TextStyle(
              color: hasConfig ? colors.error : colors.textHint,
              fontSize: 14,
            ),
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

  Future<void> _openEditor({RadioStation? station, String? categoryId}) async {
    final saved = await showRadioEditor(
      context,
      station: station,
      categoryId: categoryId ?? _categoryId,
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

  Future<void> _openRandomEditor() async {
    final saved = await showRadioEditor(
      context,
      station: ref.read(radioProvider).randomStation,
      randomMode: true,
    );
    if (saved == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('电台已保存')),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// 重置随机电台：删封面 + 清空音源 / 歌单分类 / 搜索关键词。
  Future<void> _confirmResetRandom() async {
    final colors = ref.read(themeColorsProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
        title: Text(
          context.tr('重置电台'),
          style: TextStyle(fontSize: 17, color: colors.textPrimary),
        ),
        content: Text(
          context.tr('重置后会删除随机电台的封面，并清空音源、歌单分类和搜索歌单关键词。'),
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
              context.tr('重置'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(radioProvider.notifier).resetRandomStation();
  }

  Future<void> _confirmRemoveStation(RadioStation station) async {
    final colors = ref.read(themeColorsProvider);
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

  Future<void> _startRandom() => _start(
    () => ref
        .read(radioSessionProvider.notifier)
        .startRandom(sourceId: ref.read(discoverSourceIdProvider)),
  );

  Future<void> _startStation(RadioStation station) => _start(
    () => ref.read(radioSessionProvider.notifier).startStation(station),
  );

  /// 再次点击正在准备的卡片：取消这次起播，转圈立即消失。
  void _cancelPendingStart() {
    ref.read(radioSessionProvider.notifier).cancelPendingStart();
  }

  Future<void> _start(Future<void> Function() start) async {
    // 起播状态由 radioStartingStationProvider 统一维护：点其它电台会直接
    // 顶掉当前转圈，之前那次请求返回后会被丢弃；已取消的请求不会抛错。
    try {
      await start();
      // 电台开始播放后只显示迷你播放器，不自动打开播放详情页。
    } on RadioException catch (e) {
      if (mounted) await _showError(e.message);
    } catch (e) {
      if (mounted) await _showError(context.tr('电台启动失败：$e'));
    }
  }

  Future<void> _showError(String message) {
    final colors = ref.read(themeColorsProvider);
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
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

/// 卡片底部名称蒙层的颜色：按文字明暗反向取色，深色字配白色蒙层、
/// 浅色字配黑色蒙层。
Color _scrimColorFor(Color textColor) {
  final lightText =
      ThemeData.estimateBrightnessForColor(textColor) == Brightness.light;
  return lightText ? Colors.black : Colors.white;
}

/// 深色模式下，封面平均亮度（0..1）达到这个值就压一层 30% 黑。
const _brightCoverLuminance = 0.55;

/// 电台卡片整卡压暗的统一程度：起播转圈遮罩与播放中遮罩共用同一档
/// 35% 黑，视觉上「加载中」和「播放中」的背景明暗完全一致。
const _cardDimAlpha = 0.35;
