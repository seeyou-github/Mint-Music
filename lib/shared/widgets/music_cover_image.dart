import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import '../services/cover_cache_service.dart';

/// 统一的封面图片组件，支持：
/// - HTTP/HTTPS URL（网络图片）
/// - 本地文件路径（如 /data/.../*.jpg）
/// - 无 URL 时通过 CoverCacheService 从 MediaStore 提取（songId + mediaStoreId）
class MusicCoverImage extends StatefulWidget {
  final String? url;
  final String? songId;
  final int? mediaStoreId;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;
  final BorderRadius? borderRadius;
  final int? cacheWidth;
  final int? cacheHeight;
  final FilterQuality filterQuality;

  const MusicCoverImage({
    super.key,
    this.url,
    this.songId,
    this.mediaStoreId,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
    this.borderRadius,
    this.cacheWidth,
    this.cacheHeight,
    this.filterQuality = FilterQuality.medium,
  });

  /// 封面被改动（编辑标签页上传 / 删除封面）后调用。
  ///
  /// 清掉这首歌的内存缓存，并让所有已构建的封面组件重新取图。
  static void refresh(String songId) => _MusicCoverImageState.refresh(songId);

  @override
  State<MusicCoverImage> createState() => _MusicCoverImageState();
}

class _MusicCoverImageState extends State<MusicCoverImage> {
  static final LinkedHashMap<String, Uint8List> _cache = LinkedHashMap();
  static final Map<String, List<void Function(Uint8List)>> _pending = {};
  static const int _maxCacheBytes = 24 * 1024 * 1024;
  static int _cacheBytes = 0;

  /// 封面被改动（编辑标签页上传 / 删除封面）后自增，用来让所有封面组件
  /// 丢掉旧字节重新取图 —— 否则列表、播放页会一直显示改动前的封面。
  static int _revision = 0;

  /// 通知所有封面组件：这张封面变了，请重新取图。
  static void refresh(String songId) {
    final removed = _cache.remove(songId);
    if (removed != null) _cacheBytes -= removed.length;
    _pending.remove(songId);
    _revision++;
  }

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  static final Dio _refererDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36',
      },
    ),
  );

  Uint8List? _bytes;
  bool _loading = true;
  String? _lastKey;

  /// 上一次取图时的全局封面版本号（见 [_MusicCoverImageState.refresh]）。
  int _revision = _MusicCoverImageState._revision;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(MusicCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.songId != widget.songId ||
        oldWidget.mediaStoreId != widget.mediaStoreId) {
      _load();
      return;
    }
    // 封面被别处改过（上传 / 删除）：丢掉旧字节重新取图。
    if (_revision != _MusicCoverImageState._revision) {
      _lastKey = null;
      _bytes = null;
      _load();
    }
  }

  void _load() {
    _revision = _MusicCoverImageState._revision;
    final url = widget.url;

    // Case 1: 无 URL — 从 CoverCacheService 获取（MediaStore 提取 / 桌面端缓存）
    if (url == null || url.isEmpty) {
      if (widget.songId != null) {
        _loadFromCoverCache();
      } else {
        setState(() {
          _loading = false;
          _bytes = null;
        });
      }
      return;
    }

    // Case 2: 有 URL — 根据类型加载本地文件或网络图片
    final cacheKey = url;

    if (_lastKey == cacheKey && _bytes != null) {
      setState(() {
        _loading = false;
      });
      return;
    }
    _lastKey = cacheKey;

    // 内存缓存命中
    final cached = _cache.remove(cacheKey);
    if (cached != null) {
      _cache[cacheKey] = cached;
      setState(() {
        _bytes = cached;
        _loading = false;
      });
      return;
    }

    // 正在加载中，加入等待队列
    if (_pending.containsKey(cacheKey)) {
      _pending[cacheKey]!.add((bytes) {
        if (mounted && _lastKey == cacheKey) {
          setState(() {
            _bytes = bytes;
            _loading = false;
          });
        }
      });
      return;
    }

    _pending[cacheKey] = [];
    _loading = true;

    // 本地文件路径
    if (_isLocalPath(url)) {
      _readLocalFile(url, cacheKey);
      return;
    }

    // 网络 URL
    _fetchImage(url, cacheKey);
  }

  bool _isLocalPath(String path) {
    return path.startsWith('/') ||
        path.startsWith('\\\\') ||
        path.startsWith('file://');
  }

  Future<void> _readLocalFile(String path, String cacheKey) async {
    try {
      String filePath = path;
      if (filePath.startsWith('file://')) {
        filePath = filePath.substring(7);
      }
      final file = File(filePath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) {
          _putCache(cacheKey, bytes);
          if (mounted && _lastKey == cacheKey) {
            setState(() {
              _bytes = bytes;
              _loading = false;
            });
          }
          _notifyPending(cacheKey, bytes);
          return;
        }
      }
    } catch (e) {
      debugPrint('[MusicCoverImage] 本地文件读取失败: $path - $e');
    }
    _onError(cacheKey);
  }

  void _loadFromCoverCache() {
    final songId = widget.songId!;
    final mediaStoreId = widget.mediaStoreId;

    if (_lastKey == songId && _bytes != null) {
      setState(() {
        _loading = false;
      });
      return;
    }
    _lastKey = songId;

    _loading = true;

    // 异步从 CoverCacheService 获取
    _fetchFromCoverCache(songId, mediaStoreId);
  }

  Future<void> _fetchFromCoverCache(
      String songId, int? mediaStoreId) async {
    try {
      final cache = CoverCacheService();
      final bytes = await cache.getArtwork(songId, mediaStoreId: mediaStoreId);

      if (bytes != null && bytes.isNotEmpty) {
        _putCache(songId, bytes);
        if (mounted && _lastKey == songId) {
          setState(() {
            _bytes = bytes;
            _loading = false;
          });
        }
        _notifyPending(songId, bytes);
        return;
      }
    } catch (e) {
      debugPrint('[MusicCoverImage] CoverCache 加载失败: $songId - $e');
    }
    _onError(songId);
  }

  void _putCache(String key, Uint8List bytes) {
    if (bytes.length > _maxCacheBytes) return;
    while (_cacheBytes + bytes.length > _maxCacheBytes && _cache.isNotEmpty) {
      final oldestKey = _cache.keys.first;
      final oldest = _cache.remove(oldestKey);
      if (oldest != null) _cacheBytes -= oldest.length;
    }
    _cache[key] = bytes;
    _cacheBytes += bytes.length;
  }

  void _notifyPending(String key, Uint8List bytes) {
    final callbacks = _pending.remove(key);
    if (callbacks != null) {
      for (final cb in callbacks) {
        cb(bytes);
      }
    }
  }

  Future<void> _fetchImage(String imageUrl, String cacheKey) async {
    // URL 处理：Referer 头、CDN 降级
    var needsReferer = imageUrl.contains('music.126.net');
    if (needsReferer && imageUrl.startsWith('http://')) {
      imageUrl = 'https://${imageUrl.substring(7)}';
    }
    if ((imageUrl.contains('kwcdn.kuwo.cn') ||
            imageUrl.contains('kuwo.cn') ||
            imageUrl.contains('img1.kuwo.cn')) &&
        imageUrl.startsWith('https://')) {
      imageUrl = 'http://${imageUrl.substring(8)}';
    }

    try {
      final dio = needsReferer ? _refererDio : _dio;
      final options = Options(responseType: ResponseType.bytes);
      if (needsReferer) {
        options.headers = {'Referer': 'https://music.163.com'};
      }

      final response = await dio.get<List<int>>(
        imageUrl,
        options: options,
      );

      if (response.data == null) {
        _onError(cacheKey);
        return;
      }

      final bytes = Uint8List.fromList(response.data!);

      if (bytes.length < 100) {
        debugPrint(
            '[MusicCoverImage] 响应过小 (${bytes.length} bytes)，可能不是图片: $imageUrl');
        _onError(cacheKey);
        return;
      }

      _putCache(cacheKey, bytes);

      if (mounted && _lastKey == cacheKey) {
        setState(() {
          _bytes = bytes;
          _loading = false;
        });
      }

      _notifyPending(cacheKey, bytes);
    } catch (e) {
      if (!needsReferer) {
        try {
          debugPrint('[MusicCoverImage] 首次加载失败，带 User-Agent 重试: $imageUrl');
          final response = await _refererDio.get<List<int>>(
            imageUrl,
            options: Options(responseType: ResponseType.bytes),
          );
          if (response.data != null && response.data!.length >= 100) {
            final bytes = Uint8List.fromList(response.data!);
            _putCache(cacheKey, bytes);
            if (mounted && _lastKey == cacheKey) {
              setState(() {
                _bytes = bytes;
                _loading = false;
              });
            }
            _notifyPending(cacheKey, bytes);
            return;
          }
        } catch (_) {}
      }
      debugPrint('[MusicCoverImage] 加载失败: $imageUrl - $e');
      _onError(cacheKey);
    }
  }

  void _onError(String cacheKey) {
    _pending.remove(cacheKey);
    if (mounted && _lastKey == cacheKey) {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _bytes == null) {
      return widget.errorWidget ?? _buildPlaceholder();
    }

    if (_bytes == null) {
      return widget.errorWidget ?? _buildPlaceholder();
    }

    final image = Image.memory(
      _bytes!,
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      gaplessPlayback: true,
      cacheWidth: widget.cacheWidth ?? _decodeDimension(widget.width),
      cacheHeight: widget.cacheHeight ?? _decodeDimension(widget.height),
      filterQuality: widget.filterQuality,
    );

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: image);
    }

    return image;
  }

  static int _decodeDimension(double? dimension) {
    if (dimension == null || !dimension.isFinite || dimension <= 0) {
      return 512;
    }
    return (dimension * 2).round().clamp(64, 1024);
  }

  Widget _buildPlaceholder() {
    if (widget.placeholder != null) return widget.placeholder!;
    final container = Container(
      width: widget.width,
      height: widget.height,
      color: Colors.grey.withValues(alpha: 0.15),
      child: Icon(
        Icons.music_note,
        size: (widget.width ?? 48) * 0.5,
        color: Colors.grey.withValues(alpha: 0.4),
      ),
    );
    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: container);
    }
    return container;
  }
}
