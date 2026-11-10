import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../discover/application/discover_providers.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
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
                        color: selected
                            ? colors.primary
                            : colors.textSecondary,
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

  Widget _buildRandomCard(ThemeColors colors) {
    final starting = _startingId == RadioStation.randomId;
    final isCurrent =
        ref.watch(radioSessionProvider)?.stationId == RadioStation.randomId;
    final isPlaying = ref.watch(
      playbackControllerProvider.select((state) => state.isPlaying),
    );
    // 正在播放随机电台时，卡片背景换成当前歌曲的模糊封面。
    final currentSong = isCurrent
        ? ref.watch(
            playbackControllerProvider.select((state) => state.currentSong),
          )
        : null;
    // 底色不用主题色，跟随主界面背景：与歌单详情页顶栏同一取色方式，
    // 取背景渐变顶部色派生，保证卡片始终比身后的背景略亮一档。
    final background = ref.watch(detailHeaderSurfaceProvider);
    return _buildCardFrame(
      colors,
      child: InkWell(
        onTap: starting ? null : _startRandom,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (currentSong != null)
              _RadioCardBackground(
                song: currentSong,
                isPlaying: isPlaying,
                fallbackColor: background,
              )
            else
              Container(
                decoration: BoxDecoration(color: background),
                child: isCurrent
                    ? null
                    : Icon(
                        Icons.shuffle,
                        size: 44,
                        color: colors.textPrimary.withValues(alpha: 0.9),
                      ),
              ),
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
                // 背景变为模糊封面后需要压一层底部渐变，保证名称仍然清晰。
                decoration: currentSong == null
                    ? null
                    : BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            _scrimColorFor(
                              colors.textPrimary,
                            ).withValues(alpha: 0.65),
                          ],
                        ),
                      ),
                child: Text(
                  context.tr('随机电台'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    // 名称跟随「外观设置 → 字体颜色」。
                    color: colors.textPrimary,
                  ),
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
    // 正在播放这个电台时，卡片背景换成当前歌曲的模糊封面。
    final currentSong = isCurrent
        ? ref.watch(
            playbackControllerProvider.select((state) => state.currentSong),
          )
        : null;
    // 名称跟随「外观设置 → 字体颜色」；蒙层按字色明暗反向取色，保证
    // 浅色主题（黑字）时名称仍然看得清。
    final nameColor = colors.textPrimary;
    final scrimColor = _scrimColorFor(nameColor);
    return _buildCardFrame(
      colors,
      child: InkWell(
        onTap: starting ? null : () => _startStation(station),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (currentSong != null)
              _RadioCardBackground(
                song: currentSong,
                isPlaying: isPlaying,
                fallbackColor: colors.surfaceVariant,
              )
            else
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
                      scrimColor.withValues(alpha: 0.65),
                    ],
                  ),
                ),
                child: Text(
                  station.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: nameColor,
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
                      color: Colors.white.withValues(alpha: 0.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: isPlaying
                        ? _AnimatedPlayingBars(
                            size: size * 0.58,
                            color: colors.primary,
                          )
                        : Icon(
                            Icons.play_arrow,
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
      // 电台开始播放后只显示迷你播放器，不自动打开播放详情页。
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

/// 卡片底部名称蒙层的颜色：按文字明暗反向取色，深色字配白色蒙层、
/// 浅色字配黑色蒙层。
Color _scrimColorFor(Color textColor) {
  final lightText =
      ThemeData.estimateBrightnessForColor(textColor) == Brightness.light;
  return lightText ? Colors.black : Colors.white;
}

/// 电台卡片正在播放时的背景：当前歌曲封面 + 高斯模糊 + 黑色半透明遮罩 +
/// 缓慢漂移的柔光光斑（播放时带轻微呼吸）。
class _RadioCardBackground extends StatefulWidget {
  const _RadioCardBackground({
    required this.song,
    required this.isPlaying,
    required this.fallbackColor,
  });

  final Song song;
  final bool isPlaying;

  /// 封面加载失败 / 没有封面时垫在下面的底色。
  final Color fallbackColor;

  @override
  State<_RadioCardBackground> createState() => _RadioCardBackgroundState();
}

class _RadioCardBackgroundState extends State<_RadioCardBackground>
    with SingleTickerProviderStateMixin {
  /// 光斑完整走一圈的时长：刻意放慢，避免看起来像在「闪」。
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 16),
  );

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(covariant _RadioCardBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _syncTicker();
  }

  /// 暂停时停住光斑与呼吸，恢复播放后从当前相位继续。
  void _syncTicker() {
    if (widget.isPlaying) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final placeholder = ColoredBox(color: widget.fallbackColor);
    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 模糊会把图片边缘吃掉一圈，放大 25% 避免卡片四周透出底色。
          Transform.scale(
            scale: 1.25,
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 28, sigmaY: 28),
              child: MusicCoverImage(
                key: ValueKey('radio_card_bg_${song.id}'),
                url: song.coverUrl,
                songId: song.id,
                mediaStoreId: song.mediaStoreId,
                filePath: song.filePath,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.low,
                placeholder: placeholder,
                errorWidget: placeholder,
              ),
            ),
          ),
          // 压暗封面，让名称、播放标志和菜单按钮保持可读。
          ColoredBox(color: Colors.black.withValues(alpha: 0.42)),
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => RepaintBoundary(
              child: CustomPaint(
                painter: _AmbientGlowPainter(
                  progress: _controller.value,
                  breathing: widget.isPlaying,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片背景上的氛围光斑：两团柔光沿不同轨迹缓慢漂移，
/// 播放时叠一层轻微的亮度 / 半径呼吸。
class _AmbientGlowPainter extends CustomPainter {
  const _AmbientGlowPainter({required this.progress, required this.breathing});

  /// 0–1 的循环进度。
  final double progress;

  /// 是否随播放做呼吸变化（暂停时保持静止）。
  final bool breathing;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final base = size.shortestSide;
    final breath = breathing
        ? 0.88 + 0.12 * math.sin(progress * 4 * math.pi)
        : 1.0;
    final first = Offset(
      size.width * (0.30 + 0.14 * math.sin(progress * 2 * math.pi)),
      size.height * (0.32 + 0.12 * math.cos(progress * 2 * math.pi)),
    );
    final second = Offset(
      size.width * (0.72 + 0.12 * math.cos(progress * 2 * math.pi)),
      size.height * (0.70 + 0.10 * math.sin(progress * 2 * math.pi)),
    );
    _drawGlow(canvas, first, base * 0.78 * breath, 0.18 * breath);
    _drawGlow(canvas, second, base * 0.60 * breath, 0.12 * breath);
  }

  void _drawGlow(Canvas canvas, Offset center, double radius, double alpha) {
    final color = Colors.white.withValues(alpha: alpha);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [color, color.withValues(alpha: 0)],
      ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, paint);
  }

  @override
  bool shouldRepaint(covariant _AmbientGlowPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.breathing != breathing;
  }
}

/// 电台卡片中央的「正在播放」标志：三根高低跳动的音柱。
class _AnimatedPlayingBars extends StatefulWidget {
  const _AnimatedPlayingBars({required this.size, required this.color});

  final double size;
  final Color color;

  @override
  State<_AnimatedPlayingBars> createState() => _AnimatedPlayingBarsState();
}

class _AnimatedPlayingBarsState extends State<_AnimatedPlayingBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final barWidth = widget.size * 0.18;
    final gap = widget.size * 0.12;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return SizedBox(
          width: widget.size,
          height: widget.size,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            // 音柱以中线为轴上下伸缩，整体才会居中；底对齐会贴到圆形底部。
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var i = 0; i < 3; i++) ...[
                if (i > 0) SizedBox(width: gap),
                Container(
                  width: barWidth,
                  height:
                      widget.size *
                      (0.35 +
                          0.6 *
                              (0.5 +
                                  0.5 * math.sin((t + i / 3) * 2 * math.pi))),
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(barWidth / 2),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
