import 'dart:async';
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

  /// 单张封面的下载超时。
  ///
  /// 封面原图可能有好几 MB，网速慢时需要多等一会儿；超过这个时间就换下一个
  /// 候选地址，避免整个下载任务被一张封面卡住。
  static const Duration timeout = Duration(seconds: 30);

  static final Dio _plainDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: timeout,
    ),
  );

  static final Dio _userAgentDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: timeout,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      },
    ),
  );

  static final Dio _refererDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: timeout,
      headers: const {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Referer': 'https://music.163.com',
      },
    ),
  );

  /// 下载封面；失败返回 null。
  static Future<Uint8List?> fetch(String rawUrl) => fetchAny(<String?>[rawUrl]);

  /// 只查本地图片缓存，不发起任何网络请求。
  ///
  /// 列表里显示过的封面通常已经缓存好了，命中时可以直接用来写标签。
  static Future<Uint8List?> fetchCached(String? rawUrl) async {
    if (rawUrl == null || rawUrl.isEmpty) return null;
    for (final candidate in candidatesOf(rawUrl)) {
      final bytes = await _fromCache(candidate);
      if (bytes != null) return bytes;
    }
    return null;
  }

  /// 从多个候选地址里取封面。
  ///
  /// 顺序很重要：先把**所有**候选地址的本地缓存查一遍，只要有一张已经缓存
  /// 就直接使用（列表里显示过的封面不会再走网络）；全部都没缓存时才依次
  /// 下载，每个地址最多等待 [timeout]。
  static Future<Uint8List?> fetchAny(Iterable<String?> rawUrls) async {
    final candidates = <String>[];
    for (final rawUrl in rawUrls) {
      if (rawUrl == null || rawUrl.isEmpty) continue;
      for (final candidate in candidatesOf(rawUrl)) {
        if (!candidates.contains(candidate)) candidates.add(candidate);
      }
    }
    if (candidates.isEmpty) {
      debugPrint('[CoverFetcher] 没有可用的封面地址');
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
    debugPrint('[CoverFetcher] 全部候选地址都失败: $candidates');
    return null;
  }

  /// 只查本地缓存，不触发下载。
  static Future<Uint8List?> _fromCache(String url) async {
    try {
      // getFileFromCache 返回 FileInfo，缓存文件在 file 字段里。
      final info = await AppImageCache.manager.getFileFromCache(url);
      if (info == null) return null;
      final bytes = await info.file.readAsBytes();
      if (bytes.length >= _minBytes && _looksLikeImage(bytes)) {
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
      final file = await AppImageCache.manager
          .getSingleFile(url)
          .timeout(timeout);
      final bytes = await file.readAsBytes();
      if (bytes.length >= _minBytes && _looksLikeImage(bytes)) {
        debugPrint('[CoverFetcher] 从图片缓存取到封面 ($url, ${bytes.length} bytes)');
        return bytes;
      }
    } catch (e) {
      debugPrint('[CoverFetcher] 图片缓存兜底失败 ($url): $e');
    }
    return null;
  }

  /// 简单校验图片头，避免把错误页 / HTML 当成封面写进音频文件。
  static bool _looksLikeImage(Uint8List data) {
    if (data.length < 12) return false;
    // JPEG
    if (data[0] == 0xFF && data[1] == 0xD8 && data[2] == 0xFF) return true;
    // PNG
    if (data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return true;
    }
    // WEBP (RIFF....WEBP)
    if (data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      return true;
    }
    // GIF
    if (data[0] == 0x47 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x38) {
      return true;
    }
    // BMP
    if (data[0] == 0x42 && data[1] == 0x4D) return true;
    return false;
  }

  /// 按 CDN 规则生成候选地址（顺序即尝试顺序）。
  static List<String> candidatesOf(String rawUrl) {
    final result = <String>[];
    void add(String url) {
      if (url.isNotEmpty && !result.contains(url)) result.add(url);
    }

    final original = rawUrl.trim();
    if (!original.startsWith('http://') && !original.startsWith('https://')) {
      return result;
    }

    var url = original;
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
    // 列表缓存里存的可能正是原始地址（例如 http 的网易封面），缓存查找时
    // 也要能命中，避免明明有缓存却又去走一遍网络。
    add(original);
    return result;
  }

  static Future<Uint8List?> _download(String url) async {
    final needsReferer = url.contains('music.126.net');
    final list = needsReferer
        ? <Dio>[_refererDio, _plainDio, _userAgentDio]
        : <Dio>[_plainDio, _userAgentDio, _refererDio];

    // 同一个地址的所有重试共用一个超时预算，避免一个地址卡好几分钟。
    final deadline = DateTime.now().add(timeout);
    for (final dio in list) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) break;

      final cancelToken = CancelToken();
      try {
        final response = await dio
            .get<List<int>>(
              url,
              cancelToken: cancelToken,
              options: Options(responseType: ResponseType.bytes),
            )
            .timeout(remaining);
        final data = response.data;
        if (data != null && data.length >= _minBytes) {
          final bytes = Uint8List.fromList(data);
          if (_looksLikeImage(bytes)) return bytes;
        }
        debugPrint('[CoverFetcher] 响应不是图片 ($url, ${data?.length ?? 0} bytes)');
      } on TimeoutException {
        cancelToken.cancel('封面下载超时');
        debugPrint('[CoverFetcher] 下载超时 ($url, ${timeout.inSeconds}s)');
        break;
      } catch (e) {
        debugPrint('[CoverFetcher] 下载失败 ($url): $e');
      }
    }
    return null;
  }
}
