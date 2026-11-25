import 'package:flutter/material.dart';

import '../../features/player/domain/models/song.dart';
import '../../features/plugin/application/music_source_manager.dart';
import 'music_cover_image.dart';

/// 带「接口兜底」的播放器封面：URL 为空或图片加载失败时，自动调
/// [MusicSourceManager.getPic] 换一个可用地址重试——与歌曲列表项封面的
/// 自愈策略一致。
///
/// 背景：插件歌曲的 coverUrl 可能是失效地址（如酷我老接口拼出的缩略图
/// 直链）。歌曲列表有逐行 getPic 兜底所以显示正常，播放器（左侧栏迷你
/// 封面 / 播放详情页大封面）此前直接渲染 coverUrl，死链时会一直空白。
///
/// 显示分三种状态：
/// 1. 正在取图（含正在 getPic 解析地址）：显示 [placeholder]，不显示封面；
/// 2. 取到了：显示封面；
/// 3. 确实取不到（地址解析拿不到可用地址 / 多次重试都失败）：显示
///    [errorWidget]（播放器与侧栏传的是默认封面）。
class FallbackCoverImage extends StatefulWidget {
  final Song song;

  /// 初始封面地址（一般是 song.coverUrl）。
  final String? url;

  final MusicSourceManager sourceManager;
  final BoxFit fit;
  final double? width;
  final double? height;

  /// 取图过程中显示的内容（不显示封面）。为空时退回 [errorWidget]。
  final Widget? placeholder;

  /// 确认取不到封面时显示的内容（播放器 / 侧栏传默认封面）。
  final Widget? errorWidget;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;

  const FallbackCoverImage({
    super.key,
    required this.song,
    required this.url,
    required this.sourceManager,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
    this.placeholder,
    this.errorWidget,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  State<FallbackCoverImage> createState() => _FallbackCoverImageState();
}

class _FallbackCoverImageState extends State<FallbackCoverImage> {
  /// 最多向 getPic 要几次地址。
  ///
  /// 除了第一次（歌曲本身没有 coverUrl），每次图片加载失败还会再要一次；
  /// 插件若一直返回新的死链就会无限重试，这里封顶，超了就当「确实没有
  /// 封面」处理，落到默认封面。
  static const int _maxResolveAttempts = 3;

  /// 单次向 getPic 要地址的超时时间。
  static const Duration _resolveTimeout = Duration(seconds: 8);

  String? _url;
  final Set<String> _failedUrls = <String>{};
  bool _resolving = false;

  /// 已经确认拿不到可用封面（重试用尽 / getPic 没给出新地址）。
  bool _exhausted = false;
  int _attempts = 0;

  @override
  void initState() {
    super.initState();
    _url = widget.url;
    if (_url == null || _url!.isEmpty) _resolveFallback();
  }

  @override
  void didUpdateWidget(covariant FallbackCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song.id != widget.song.id || oldWidget.url != widget.url) {
      _url = widget.url;
      _failedUrls.clear();
      _exhausted = false;
      _attempts = 0;
      if (_url == null || _url!.isEmpty) _resolveFallback();
    }
  }

  Future<void> _resolveFallback() async {
    if (_resolving) return;
    if (_attempts >= _maxResolveAttempts) {
      // 重试用尽：明确落到「取不到封面」，让调用方显示默认封面。
      if (mounted) setState(() => _exhausted = true);
      return;
    }
    _attempts++;
    _resolving = true;
    try {
      // 插件接口可能一直不返回（风控 / 网络卡住），超时就当「没有可用地址」，
      // 免得播放器封面一直停在占位上。
      final fallback = await widget.sourceManager
          .getPic(widget.song, excludedUrls: _failedUrls)
          .timeout(_resolveTimeout, onTimeout: () => null);
      if (!mounted) return;
      if (fallback == null ||
          fallback.isEmpty ||
          fallback == _url ||
          _failedUrls.contains(fallback)) {
        setState(() => _exhausted = true);
        return;
      }
      setState(() {
        _url = fallback;
        _exhausted = false;
      });
    } finally {
      _resolving = false;
    }
  }

  void _handleLoadFailed() {
    // 地址已经试过且失败过又轮到它：直接当「没有封面」，别再兜底一次。
    final failed = _url;
    if (failed != null && failed.isNotEmpty && _failedUrls.add(failed)) {
      // 先清空避免死链地址继续占位，再用排除列表重新解析。
      setState(() {
        _url = null;
        _exhausted = false;
      });
      _resolveFallback();
      return;
    }
    if (mounted) setState(() => _exhausted = true);
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null || url.isEmpty || _failedUrls.contains(url)) {
      // 解析中仍走占位（不显示封面）；已经确认取不到才显示兜底内容。
      final fallback = _exhausted
          ? (widget.errorWidget ??
                widget.placeholder ??
                _buildGreyPlaceholder())
          : (widget.placeholder ??
                widget.errorWidget ??
                _buildGreyPlaceholder());
      return fallback;
    }
    return MusicCoverImage(
      // 每个地址一个独立 State：换地址后不复用旧组件的加载状态。
      key: ValueKey('fallback_cover_$url'),
      url: url,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      cacheWidth: widget.cacheWidth,
      cacheHeight: widget.cacheHeight,
      filterQuality: widget.filterQuality,
      placeholder: widget.placeholder,
      errorWidget: widget.errorWidget,
      onLoadFailed: _handleLoadFailed,
    );
  }

  Widget _buildGreyPlaceholder() {
    return Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey.withValues(alpha: 0.15),
    );
  }
}
