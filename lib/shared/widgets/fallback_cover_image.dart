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
class FallbackCoverImage extends StatefulWidget {
  final Song song;

  /// 初始封面地址（一般是 song.coverUrl）。
  final String? url;

  final MusicSourceManager sourceManager;
  final BoxFit fit;
  final double? width;
  final double? height;
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
    this.errorWidget,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  State<FallbackCoverImage> createState() => _FallbackCoverImageState();
}

class _FallbackCoverImageState extends State<FallbackCoverImage> {
  String? _url;
  final Set<String> _failedUrls = <String>{};
  bool _resolving = false;

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
      if (_url == null || _url!.isEmpty) _resolveFallback();
    }
  }

  Future<void> _resolveFallback() async {
    if (_resolving) return;
    _resolving = true;
    try {
      final fallback = await widget.sourceManager.getPic(
        widget.song,
        excludedUrls: _failedUrls,
      );
      if (!mounted || fallback == null || fallback.isEmpty) return;
      if (fallback == _url || _failedUrls.contains(fallback)) return;
      setState(() => _url = fallback);
    } finally {
      _resolving = false;
    }
  }

  void _handleLoadFailed() {
    final failed = _url;
    if (failed != null && failed.isNotEmpty && _failedUrls.add(failed)) {
      // 先清空避免死链地址继续占位，再用排除列表重新解析。
      setState(() => _url = null);
      _resolveFallback();
    }
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null || url.isEmpty || _failedUrls.contains(url)) {
      return widget.errorWidget ??
          Container(
            width: widget.width,
            height: widget.height,
            color: Colors.grey.withValues(alpha: 0.15),
          );
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
      errorWidget: widget.errorWidget,
      onLoadFailed: _handleLoadFailed,
    );
  }
}
