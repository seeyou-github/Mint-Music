import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../../plugin/application/music_source_manager.dart';
import '../../../plugin/application/plugin_providers.dart';
import '../../../plugin/domain/plugin_types.dart';
import '../../domain/models/song.dart';

/// 评论排序 id → 下拉框文案（简体源串，繁体由 context.tr 转换）。
const Map<String, String> _sortLabels = {
  'hot': '热度',
  'time_desc': '时间倒序',
  'time_asc': '时间顺序',
};

String _sortLabel(BuildContext context, String sort) {
  final label = _sortLabels[sort];
  return label == null ? sort : context.tr(label);
}

String _formatDate(int milliseconds) {
  if (milliseconds <= 0) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  return '${date.year}年${date.month}月${date.day}日';
}

/// 点赞数：≥1 万显示「x.x万」，≥1 千显示「x.x千」，多出的小数截断不进位。
String _formatLikeCount(int value) {
  if (value >= 10000) return '${_oneDecimal(value / 10000)}万';
  if (value >= 1000) return '${_oneDecimal(value / 1000)}千';
  return '$value';
}

String _oneDecimal(double value) {
  final truncated = (value * 10).floor() / 10;
  return truncated == truncated.roundToDouble()
      ? truncated.toInt().toString()
      : truncated.toStringAsFixed(1);
}

/// 歌曲评论弹层：底部展开，高度占窗口 80%。
Future<void> showCommentSheet(BuildContext context, Song song) {
  final size = MediaQuery.sizeOf(context);
  final width = Platform.isAndroid ? size.width : size.width * 0.7;
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    constraints: BoxConstraints(maxWidth: width, maxHeight: size.height * 0.8),
    sheetAnimationStyle: const AnimationStyle(
      duration: Duration(milliseconds: 220),
      reverseDuration: Duration(milliseconds: 180),
    ),
    builder: (_) => _CommentSheet(song: song),
  );
}

class _CommentSheet extends ConsumerStatefulWidget {
  const _CommentSheet({required this.song});

  final Song song;

  @override
  ConsumerState<_CommentSheet> createState() => _CommentSheetState();
}

class _CommentSheetState extends ConsumerState<_CommentSheet> {
  final ScrollController _scroll = ScrollController();
  late final MusicSourceManager _manager;
  late final CommentCapabilities _capabilities;
  late String _sort;

  final List<CommentItem> _comments = [];
  int _page = 1;
  int? _total;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loadMoreError = false;
  String? _error;

  /// 请求代次：切排序 / 重试时旧的请求结果直接丢弃。
  int _seq = 0;

  bool get _supported => _capabilities.sorts.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(musicSourceManagerProvider);
    _capabilities = _manager.commentCapabilitiesFor(widget.song);
    _sort = _capabilities.defaultSort;
    _scroll.addListener(_onScroll);
    if (_supported) _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loading || _loadingMore) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 320) {
      _loadMore();
    }
  }

  void _changeSort(String? value) {
    if (value == null || value == _sort) return;
    _sort = value;
    _load(reset: true);
  }

  Future<void> _loadMore() => _load(reset: false);

  Future<void> _load({required bool reset}) async {
    if (!_supported) return;
    final seq = reset ? ++_seq : _seq;
    setState(() {
      if (reset) {
        _loading = true;
        _loadingMore = false;
        _loadMoreError = false;
        _error = null;
        _page = 1;
        _hasMore = false;
        _total = null;
        _comments.clear();
      } else {
        _loadingMore = true;
        _loadMoreError = false;
      }
    });
    if (reset && _scroll.hasClients) _scroll.jumpTo(0);

    try {
      final result = await _manager.getComments(
        widget.song,
        sort: _sort,
        page: _page,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _comments.addAll(result.comments);
        _total = result.total;
        _hasMore = result.hasMore && result.comments.isNotEmpty;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
      _prefetchIfNotScrollable();
    } catch (error) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (_comments.isEmpty) {
          _error = error is CommentException
              ? error.message
              : context.tr('评论加载失败，请稍后重试');
        } else {
          _loadMoreError = true;
        }
      });
    }
  }

  /// 首屏不到一屏时没有滚动事件，这里主动补一页。
  void _prefetchIfNotScrollable() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasMore || _loading || _loadingMore) return;
      if (!_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0) _loadMore();
    });
  }

  Widget _buildPlaceholder(
    ThemeColors colors,
    String message, {
    VoidCallback? onRetry,
  }) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.chat_bubble_outline, size: 44, color: colors.textHint),
          const SizedBox(height: AppSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: colors.textHint),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AppSpacing.sm),
            TextButton(onPressed: onRetry, child: Text(context.tr('重试'))),
          ],
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Row(
      children: [
        Text(
          context.tr('评论'),
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        if (_total != null && _total! > 0) ...[
          const SizedBox(width: AppSpacing.sm),
          Text(
            '$_total',
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
        ],
        const Spacer(),
        if (_supported)
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _sort,
              isDense: true,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              dropdownColor: colors.dialogSurfaceVariant,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              icon: Icon(
                Icons.arrow_drop_down,
                size: 20,
                color: colors.textSecondary,
              ),
              style: TextStyle(fontSize: 13, color: colors.textSecondary),
              items: [
                for (final sort in _capabilities.sorts)
                  DropdownMenuItem(
                    value: sort,
                    child: Text(_sortLabel(context, sort)),
                  ),
              ],
              onChanged: _changeSort,
            ),
          ),
      ],
    );
  }

  Widget _buildBody(ThemeColors colors) {
    if (!_supported) {
      return _buildPlaceholder(
        colors,
        widget.song.isLocal ? context.tr('本地歌曲没有评论') : context.tr('当前音源暂不支持评论'),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _buildPlaceholder(
        colors,
        _error!,
        onRetry: () => _load(reset: true),
      );
    }
    if (_comments.isEmpty) {
      return _buildPlaceholder(colors, context.tr('还没有评论'));
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.sm,
        AppSpacing.xl,
        AppSpacing.lg,
      ),
      itemCount: _comments.length + 1,
      itemBuilder: (context, index) {
        if (index >= _comments.length) {
          if (_loadMoreError) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Center(
                child: TextButton(
                  onPressed: _loadMore,
                  child: Text(context.tr('加载失败，点击重试')),
                ),
              ),
            );
          }
          if (_hasMore) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Center(
              child: Text(
                context.tr('没有更多了'),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ),
          );
        }
        return _CommentTile(
          item: _comments[index],
          colors: colors,
          onShowReplies: _capabilities.replies && _comments[index].replies > 0
              ? () => _openReplies(_comments[index])
              : null,
        );
      },
    );
  }

  Future<void> _openReplies(CommentItem item) {
    // 与评论弹框同样从底部弹出，高度比评论弹框（80%）少 15%。
    final size = MediaQuery.sizeOf(context);
    final width = Platform.isAndroid ? size.width : size.width * 0.7;
    return showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      constraints: BoxConstraints(
        maxWidth: width,
        maxHeight: size.height * 0.65,
      ),
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      builder: (_) => _CommentRepliesSheet(song: widget.song, parent: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final size = MediaQuery.sizeOf(context);
    // 宽度给死：底部弹层的约束有上限但不给最小宽度，Container 会缩到内容宽。
    final width = Platform.isAndroid ? size.width : size.width * 0.7;

    return SizedBox(
      width: width,
      height: size.height * 0.8,
      child: Container(
        decoration: BoxDecoration(
          color: colors.dialogSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.sm,
                  AppSpacing.md,
                  AppSpacing.xs,
                ),
                child: _buildHeader(colors),
              ),
              Divider(height: 1, color: colors.divider),
              Expanded(child: _buildBody(colors)),
            ],
          ),
        ),
      ),
    );
  }
}

class _CommentTile extends StatelessWidget {
  const _CommentTile({
    required this.item,
    required this.colors,
    this.onShowReplies,
  });

  final CommentItem item;
  final ThemeColors colors;

  /// 为 null 表示当前音源不支持查看回复，只显示不可点的回复数。
  final VoidCallback? onShowReplies;

  @override
  Widget build(BuildContext context) {
    // Android 不显示头像，评论文字因此更宽；正文与用户名同字号，整体大 2 号。
    final android = Platform.isAndroid;
    final textFontSize = android ? 17.0 : 15.0;
    final metaFontSize = android ? 14.0 : 12.0;
    final date = _formatDate(item.createAt);
    final meta = [
      if (date.isNotEmpty) date,
      if (item.location.isNotEmpty) item.location,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!android) ...[
            _CommentAvatar(url: item.avatar, size: 42, colors: colors),
            const SizedBox(width: AppSpacing.md),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.nickName.isEmpty
                            ? context.tr('匿名用户')
                            : item.nickName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: textFontSize,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (item.like > 0) ...[
                      const SizedBox(width: AppSpacing.sm),
                      _LikeCount(
                        value: item.like,
                        colors: colors,
                        fontSize: android ? 15 : 13,
                      ),
                    ],
                  ],
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: metaFontSize,
                      color: colors.textHint,
                    ),
                  ),
                ],
                const SizedBox(height: AppSpacing.md),
                Text(
                  item.comment,
                  style: TextStyle(
                    fontSize: textFontSize,
                    height: 1.5,
                    color: colors.textSecondary,
                  ),
                ),
                if (item.replies > 0) ...[
                  const SizedBox(height: AppSpacing.sm),
                  InkWell(
                    onTap: onShowReplies,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '${item.replies}${context.tr('条回复')}',
                          style: TextStyle(
                            fontSize: android ? 15 : 13,
                            color: onShowReplies == null
                                ? colors.textHint
                                : colors.primary,
                          ),
                        ),
                        if (onShowReplies != null)
                          Icon(
                            Icons.chevron_right,
                            size: android ? 18 : 16,
                            color: colors.primary,
                          ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 评论头像；没有头像或加载失败时保留同尺寸空白占位，保证用户名左对齐。
class _CommentAvatar extends StatelessWidget {
  const _CommentAvatar({
    required this.url,
    required this.size,
    required this.colors,
  });

  final String url;
  final double size;
  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: colors.divider, shape: BoxShape.circle),
    );
    if (url.isEmpty) return placeholder;
    return ClipOval(
      child: Image.network(
        url,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

/// 点赞数 + 图标：文字与图标同色（跟随用户名颜色）。
class _LikeCount extends StatelessWidget {
  const _LikeCount({
    required this.value,
    required this.colors,
    this.fontSize = 13,
  });

  final int value;
  final ThemeColors colors;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    // height 1.0 时文本行高等于字号；图标单独放大，避免点赞数旁边的小图标看不清。
    const iconSize = 17.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _formatLikeCount(value),
          style: TextStyle(
            fontSize: fontSize,
            height: 1.0,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(width: 3),
        Icon(
          Icons.thumb_up_off_alt,
          size: iconSize,
          color: colors.textPrimary,
        ),
      ],
    );
  }
}

/// 一条评论的二级回复弹层。
class _CommentRepliesSheet extends ConsumerStatefulWidget {
  const _CommentRepliesSheet({required this.song, required this.parent});

  final Song song;
  final CommentItem parent;

  @override
  ConsumerState<_CommentRepliesSheet> createState() =>
      _CommentRepliesSheetState();
}

class _CommentRepliesSheetState extends ConsumerState<_CommentRepliesSheet> {
  final ScrollController _scroll = ScrollController();
  late final MusicSourceManager _manager;

  final List<CommentItem> _replies = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = false;
  bool _loadingMore = false;
  bool _loadMoreError = false;
  String? _error;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    _manager = ref.read(musicSourceManagerProvider);
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_hasMore || _loading || _loadingMore) return;
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 240) {
      _load(reset: false);
    }
  }

  Future<void> _load({required bool reset}) async {
    final seq = reset ? ++_seq : _seq;
    setState(() {
      if (reset) {
        _loading = true;
        _loadingMore = false;
        _loadMoreError = false;
        _error = null;
        _page = 1;
        _hasMore = false;
        _replies.clear();
      } else {
        _loadingMore = true;
        _loadMoreError = false;
      }
    });

    try {
      final result = await _manager.getCommentReplies(
        widget.song,
        widget.parent,
        page: _page,
      );
      if (!mounted || seq != _seq) return;
      setState(() {
        _replies.addAll(result.comments);
        _hasMore = result.hasMore && result.comments.isNotEmpty;
        _page += 1;
        _loading = false;
        _loadingMore = false;
      });
      _prefetchIfNotScrollable();
    } catch (error) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (_replies.isEmpty) {
          _error = error is CommentException
              ? error.message
              : context.tr('回复加载失败，请稍后重试');
        } else {
          _loadMoreError = true;
        }
      });
    }
  }

  /// 回复很少时没有滚动事件，这里主动补一页。
  void _prefetchIfNotScrollable() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_hasMore || _loading || _loadingMore) return;
      if (!_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent <= 0) _load(reset: false);
    });
  }

  Widget _buildList(ThemeColors colors) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.textHint),
            ),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => _load(reset: true),
              child: Text(context.tr('重试')),
            ),
          ],
        ),
      );
    }
    if (_replies.isEmpty) {
      return Center(
        child: Text(
          context.tr('还没有回复'),
          style: TextStyle(fontSize: 13, color: colors.textHint),
        ),
      );
    }

    return ListView.builder(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.xl,
        AppSpacing.xs,
        AppSpacing.xl,
        AppSpacing.md,
      ),
      itemCount: _replies.length + 1,
      itemBuilder: (context, index) {
        if (index >= _replies.length) {
          if (_loadMoreError) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
              child: Center(
                child: TextButton(
                  onPressed: () => _load(reset: false),
                  child: Text(context.tr('加载失败，点击重试')),
                ),
              ),
            );
          }
          if (_hasMore) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          return const SizedBox.shrink();
        }
        return _ReplyTile(item: _replies[index], colors: colors);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final size = MediaQuery.sizeOf(context);
    final width = Platform.isAndroid ? size.width : size.width * 0.7;
    final count = widget.parent.replies;

    return SizedBox(
      width: width,
      height: size.height * 0.65,
      child: Container(
        decoration: BoxDecoration(
          color: colors.dialogSurface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.xl,
                  AppSpacing.sm,
                  AppSpacing.sm,
                  AppSpacing.xs,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        count > 0
                            ? '$count${context.tr('条回复')}'
                            : context.tr('回复'),
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).maybePop(),
                      icon: Icon(
                        Icons.close,
                        size: 20,
                        color: colors.textSecondary,
                      ),
                      tooltip: context.tr('关闭'),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.divider),
              Expanded(child: _buildList(colors)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 弹框里的一条回复：比主列表更紧凑，且不再显示下级回复入口。
class _ReplyTile extends StatelessWidget {
  const _ReplyTile({required this.item, required this.colors});

  final CommentItem item;
  final ThemeColors colors;

  @override
  Widget build(BuildContext context) {
    // Android 不显示头像，回复文字更宽，字号整体大 2 号。
    final android = Platform.isAndroid;
    final nameFontSize = android ? 15.0 : 13.0;
    final metaFontSize = android ? 13.0 : 11.0;
    final bodyFontSize = android ? 16.0 : 14.0;
    final date = _formatDate(item.createAt);
    final meta = [
      if (date.isNotEmpty) date,
      if (item.location.isNotEmpty) item.location,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!android) ...[
            _CommentAvatar(url: item.avatar, size: 32, colors: colors),
            const SizedBox(width: AppSpacing.sm),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        item.nickName.isEmpty
                            ? context.tr('匿名用户')
                            : item.nickName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: nameFontSize,
                          fontWeight: FontWeight.w500,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (item.like > 0) ...[
                      const SizedBox(width: AppSpacing.sm),
                      _LikeCount(
                        value: item.like,
                        colors: colors,
                        fontSize: android ? 15 : 13,
                      ),
                    ],
                  ],
                ),
                if (meta.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    meta,
                    style: TextStyle(
                      fontSize: metaFontSize,
                      color: colors.textHint,
                    ),
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  item.comment,
                  style: TextStyle(
                    fontSize: bodyFontSize,
                    height: 1.45,
                    color: colors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
