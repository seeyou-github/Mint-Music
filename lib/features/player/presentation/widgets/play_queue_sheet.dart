import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:async';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/scroll_locate.dart';
import '../../../../shared/widgets/music_cover_image.dart';
import '../../../blacklist/application/blacklist_providers.dart';
import '../../application/playback_controller.dart';
import '../../domain/models/playback_state.dart';

/// 播放队列单行高度。
///
/// 队列行是「带 leading + 双行（title/subtitle）」的 ListTile，Material 3 下
/// 高度为 72。之前这里写成 64，每行差 8px，定位到第 85 首时累计偏差 680px，
/// 目标会整个滚出可视区。同时把这个值交给 ListView 的 [itemExtent]，
/// 让"估算行高"与"真实行高"由同一个常量保证一致。
const double _kQueueItemExtent = 72.0;

/// 播放队列底部弹层（与全屏播放页中的播放队列完全一致）。
///
/// 从 FullPlayerPage 抽取为共享组件，供全屏播放页与迷你播放器复用：
/// 迷你播放器点击播放队列按钮时直接弹出此面板，无需跳转全屏页。
Future<void> showPlayQueueSheet(
  BuildContext context, {
  required PlaybackState playbackState,
  required PlaybackController controller,
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  // 播放队列已经显示时，再次点击播放队列按钮应当隐藏它。
  if (PlayQueueSheetController.isVisible) {
    PlayQueueSheetController.hideIfVisible();
    return;
  }
  PlayQueueSheetController.attach(navigator);
  try {
    await showModalBottomSheet(
      context: context,
      useRootNavigator: true,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _PlayQueueSheetContent(controller: controller),
    );
  } finally {
    PlayQueueSheetController.detach(navigator);
  }
}

/// 播放队列弹层的开关状态。
///
/// 记录弹层所在的 Navigator，这样「再次点击播放队列按钮」时可以直接把
/// 已经显示的弹层关掉，而不会重复弹出多个播放队列。
class PlayQueueSheetController {
  PlayQueueSheetController._();

  static NavigatorState? _navigator;
  static bool _visible = false;

  /// 当前是否已经显示了播放队列弹层。
  static bool get isVisible => _visible;

  /// 记录弹层所在的 Navigator（弹层显示时调用）。
  static void attach(NavigatorState navigator) {
    _navigator = navigator;
    _visible = true;
  }

  /// 弹层关闭后的清理。
  static void detach(NavigatorState navigator) {
    if (identical(_navigator, navigator)) {
      _navigator = null;
    }
    _visible = false;
  }

  /// 隐藏已经显示的播放队列；没有显示时返回 false。
  static bool hideIfVisible() {
    if (!_visible) return false;
    final navigator = _navigator;
    _navigator = null;
    _visible = false;
    if (navigator != null && navigator.canPop()) {
      navigator.pop();
    }
    return true;
  }
}

class _PlayQueueSheetContent extends ConsumerStatefulWidget {
  const _PlayQueueSheetContent({required this.controller});

  final PlaybackController controller;

  @override
  ConsumerState<_PlayQueueSheetContent> createState() =>
      _PlayQueueSheetContentState();
}

class _PlayQueueSheetContentState
    extends ConsumerState<_PlayQueueSheetContent> {
  final ScrollController _listScrollController = ScrollController();

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  void _locateCurrentSong() {
    final state = ref.read(playbackControllerProvider);
    final index = state.currentIndex;
    if (index < 0 || index >= state.queue.length) {
      return;
    }
    if (!_listScrollController.hasClients) return;

    unawaited(
      scrollToItemIndex(
        _listScrollController,
        index: index,
        itemExtent: _kQueueItemExtent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 队列是「活」的：直接 watch provider，删除某首后就地刷新列表，
    // 不需要关闭弹层再重新打开。
    final playbackState = ref.watch(playbackControllerProvider);
    final blacklist = ref.watch(blacklistProvider);
    final queue = playbackState.queue;
    final currentIndex = playbackState.currentIndex;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        minimum: const EdgeInsets.only(bottom: 70),
        child: DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          expand: false,
          builder: (context, scrollController) => Stack(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          context.tr('播放队列'),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: AppColors.textPrimary,
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              context.tr('${queue.length}首'),
                              style: const TextStyle(color: AppColors.textHint),
                            ),
                            const SizedBox(width: 16),
                            GestureDetector(
                              onTap: () {
                                widget.controller.clearQueue();
                                Navigator.pop(context);
                              },
                              child: Text(
                                context.tr('清空'),
                                style: const TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (queue.isEmpty)
                    Expanded(
                      child: Center(
                        child: Text(
                          context.tr('播放队列为空'),
                          style: const TextStyle(color: AppColors.textHint),
                        ),
                      ),
                    )
                  else
                    Expanded(
                      child: ListView.builder(
                        controller: _listScrollController,
                        itemCount: queue.length,
                        // 与定位用的行高常量一致，避免估算行高累积误差
                        itemExtent: _kQueueItemExtent,
                        addAutomaticKeepAlives: false,
                        addRepaintBoundaries: true,
                        itemBuilder: (context, index) {
                          final queueSong = queue[index];
                          final isCurrent = index == currentIndex;
                          // 黑名单歌曲：只显示、不可播放，播放时会自动跳过。
                          final blocked = blacklist.isBlocked(queueSong);
                          return ListTile(
                            enabled: !blocked,
                            leading: SizedBox(
                              // 四位数序号也不折行：序号列 + 间距 + 封面总宽。
                              width: 92,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // 序号：当前播放歌曲用播放图标，其他用数字
                                  SizedBox(
                                    // 四位数序号不换行。
                                    width: 44,
                                    child: isCurrent
                                        ? Icon(
                                            Icons.play_arrow,
                                            size: 14,
                                            color: AppColors.primary,
                                          )
                                        : Padding(
                                            padding: EdgeInsets.only(left: 2),
                                            child: Text(
                                              '${index + 1}',
                                              textAlign: TextAlign.start,
                                              maxLines: 1,
                                              softWrap: false,
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: AppColors.textHint,
                                              ),
                                            ),
                                          ),
                                  ),
                                  const SizedBox(width: 4),
                                  // 封面：内嵌封面歌曲通过 MediaStore 提取
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      color: AppColors.surfaceVariant,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: MusicCoverImage(
                                        url: queueSong.coverUrl,
                                        songId: queueSong.id,
                                        mediaStoreId: queueSong.mediaStoreId,
                                        fit: BoxFit.cover,
                                        errorWidget: Icon(
                                          Icons.music_note,
                                          size: 20,
                                          color: isCurrent
                                              ? AppColors.primary
                                              : AppColors.textHint,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            title: Text(
                              queueSong.title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w500,
                                color: blocked
                                    // 黑名单歌曲名颜色更浅
                                    ? AppColors.textPrimary.withValues(
                                        alpha: 0.45,
                                      )
                                    : (isCurrent
                                          ? AppColors.primary
                                          : AppColors.textPrimary),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Row(
                              children: [
                                if (blocked) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: AppColors.error.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                    child: Text(
                                      context.tr('黑名单'),
                                      style: const TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.error,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                ],
                                Expanded(
                                  child: Text(
                                    '${queueSong.artist} - ${queueSong.album}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: blocked
                                          ? AppColors.textHint.withValues(
                                              alpha: 0.7,
                                            )
                                          : (isCurrent
                                                ? AppColors.primary.withValues(
                                                    alpha: 0.7,
                                                  )
                                                : AppColors.textHint),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            trailing: isCurrent
                                ? const Icon(
                                    Icons.volume_up,
                                    size: 18,
                                    color: AppColors.primary,
                                  )
                                : IconButton(
                                    icon: const Icon(
                                      Icons.close,
                                      size: 18,
                                      color: AppColors.textHint,
                                    ),
                                    onPressed: () {
                                      // 不关闭弹层：就地删除并继续，
                                      // 否则每删一首都要重新点开迷你播放栏的队列。
                                      widget.controller.removeFromQueue(index);
                                    },
                                  ),
                            onTap: blocked
                                ? null
                                : () {
                                    widget.controller.playSongAt(index);
                                    Navigator.pop(context);
                                  },
                          );
                        },
                      ),
                    ),
                ],
              ),
              // 定位当前播放歌曲的悬浮按钮（列表右侧悬浮）
              if (currentIndex >= 0 && currentIndex < queue.length)
                Positioned(
                  right: 60,
                  bottom: 40,
                  child: GestureDetector(
                    onTap: _locateCurrentSong,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.15),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: const Icon(
                        Icons.my_location,
                        size: 20,
                        color: AppColors.primary,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
