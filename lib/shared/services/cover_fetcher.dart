import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import 'app_image_cache.dart';

/// 统一的封面图片下载。
///
/// 各音源的封面地址来自不同 CDN，兼容性差异很大，这里把「列表里显示封面」
/// 那套已经验证过的处理逻辑抽出来给下载写标签等场景复用：
///
/// * 网易 CDN（music.126.net）：强制 https、需要 Referer，原图有 2MB+，
///   优先请求 `?param=400y400` 缩略图；
/// * 酷我 CDN（kuwo.cn）：不支持 https，需要降级成 http；
/// * 其它 CDN：原样请求，失败后再带 User-Agent 重试一次。
class CoverFetcher {
  CoverFetcher._();

  /// 最小可用图片字节数（小于这个值认为是错误页而不是封面）。
  static const int _minBytes = 100;

  static final Dio _plainDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ),
  );

  static final Dio _userAgentDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ),
  );

  static final Dio _refererDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://music.163.com',
      },
    ),
  );

  /// 下载封面；失败返回 null。
  ///
  /// 顺序：先看本地图片缓存（列表里显示过的封面通常已经缓存好了），
  /// 本地没有再走网络下载。
  static Future<Uint8List?> fetch(String rawUrl) async {
    final candidates = candidatesOf(rawUrl);
    if (candidates.isEmpty) {
      debugPrint('[CoverFetcher] 无效的封面地址: $rawUrl');
      return null;
    }
    // 1) 优先使用本地已缓存的封面
    for (final candidate in candidates) {
      final bytes = await _fromCache(candidate);
      if (bytes != null) return bytes;
    }
    // 2) 本地没有，再下载
    for (final candidate in candidates) {
      final bytes = await _download(candidate);
      if (bytes != null) return bytes;
    }
    // 3) 兜底：交给图片缓存管理器下载（它的网络策略已在列表里验证过）
    for (final candidate in candidates) {
      final bytes = await _fromImageCache(candidate);
      if (bytes != null) return bytes;
    }
    debugPrint('[CoverFetcher] 全部候选地址都失败: $rawUrl');
    return null;
  }

  /// 只查本地缓存，不触发下载。
  static Future<Uint8List?> _fromCache(String url) async {
    try {
      // getFileFromCache 返回 FileInfo，缓存文件在 file 字段里。
      final info = await AppImageCache.manager.getFileFromCache(url);
      if (info == null) return null;
      final bytes = await info.file.readAsBytes();
      if (bytes.length >= _minBytes) {
        debugPrint('[CoverFetcher] 命中本地封面缓存 ($url, ${bytes.length} bytes)');
        return bytes;
      }
    } catch (e) {
      debugPrint('[CoverFetcher] 读取本地封面缓存失败 ($url): $e');
    }
    return null;
  }

  /// 从应用图片缓存里取封面（命中本地缓存或由缓存管理器下载）。
  static Future<Uint8List?> _fromImageCache(String url) async {
    try {
      final file = await AppImageCache.manager.getSingleFile(url);
      final bytes = await file.readAsBytes();
      if (bytes.length >= _minBytes) {
        debugPrint('[CoverFetcher] 从图片缓存取到封面 ($url, ${bytes.length} bytes)');
        return bytes;
      }
    } catch (e) {
      debugPrint('[CoverFetcher] 图片缓存兜底失败 ($url): $e');
    }
    return null;
  }

  /// 按 CDN 规则生成候选地址（顺序即尝试顺序）。
  static List<String> candidatesOf(String rawUrl) {
    final result = <String>[];
    void add(String url) {
      if (url.isNotEmpty && !result.contains(url)) result.add(url);
    }

    var url = rawUrl.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return result;
    }

    if (url.contains('music.126.net')) {
      if (url.startsWith('http://')) {
        url = 'https://${url.substring(7)}';
      }
      // 原图可能好几 MB，先用 400x400 缩略图。
      final base = url.split('?').first;
      add('$base?param=400y400');
    }

    // 酷我图片 CDN 不支持 https。
    if (url.contains('kuwo.cn') && url.startsWith('https://')) {
      add('http://${url.substring(8)}');
    }

    add(url);
    return result;
  }

  static Future<Uint8List?> _download(String url) async {
    final needsReferer = url.contains('music.126.net');
    final list = needsReferer
        ? <Dio>[_refererDio, _plainDio, _userAgentDio]
        : <Dio>[_plainDio, _userAgentDio, _refererDio];
    for (final dio in list) {
      try {
        final response = await dio.get<List<int>>(
          url,
          options: Options(responseType: ResponseType.bytes),
        );
        final data = response.data;
        if (data != null && data.isNotEmpty && data.length >= _minBytes) {
          return Uint8List.fromList(data);
        }
        debugPrint('[CoverFetcher] 响应不是图片 ($url, ${data?.length ?? 0} bytes)');
      } catch (e) {
        debugPrint('[CoverFetcher] 下载失败 ($url): $e');
      }
    }
    return null;
  }
}
