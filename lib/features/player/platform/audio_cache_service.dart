import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../shared/services/cache_paths.dart';

/// 音频缓存服务。
///
/// 播放过的音频会被保存到「设置 - 存储管理 - 缓存目录」下的 `audio_cache`
/// 子目录：
///
/// * 再次播放同一首歌（同一音源 / 音质）时直接读本地文件，秒开且不消耗流量；
/// * 未命中缓存时正常走网络播放，同时在后台把音频下载一份到缓存目录，
///   供下次播放直接使用。
///
/// 缓存文件同时受「最大缓存大小」限制（见 [CachePaths.enforceLimit]），
/// 超限时按修改时间从旧到新清理。
class AudioCacheService {
  AudioCacheService._();

  /// 缓存子目录名。
  static const String subDirectoryName = 'audio_cache';

  /// 缓存键：音源 + 歌曲 id + 音质（不同音源的同一首歌分开缓存）。
  static String cacheKey({
    required String songId,
    required String quality,
    String? source,
  }) {
    return '${source ?? ''}|$songId|$quality';
  }

  /// 缓存文件名：`缓存键.扩展名`（非法字符会被替换）。
  static String fileNameFor(String key, String extension) {
    final safeKey = key.replaceAll(RegExp(r'[^\w\-.]'), '_');
    return '$safeKey.$extension';
  }

  /// 推断缓存文件的扩展名：优先取 URL 上的扩展名，其次按音质判断。
  static String extensionFor(String url, String quality) {
    final path = Uri.tryParse(url)?.path ?? '';
    final dot = path.lastIndexOf('.');
    if (dot >= 0 && dot < path.length - 1) {
      final ext = path.substring(dot + 1).toLowerCase();
      if (ext.length <= 5 && RegExp(r'^[a-z0-9]+$').hasMatch(ext)) {
        return ext;
      }
    }
    final lower = quality.toLowerCase();
    if (lower.contains('flac') ||
        lower.contains('hires') ||
        lower.contains('atmos') ||
        lower.contains('master')) {
      return 'flac';
    }
    return 'mp3';
  }

  /// 查找已缓存的完整音频文件。
  static Future<File?> findCachedFile({
    required String songId,
    required String quality,
    required String url,
    String? source,
  }) async {
    try {
      final dir = await CachePaths.subDirectory(subDirectoryName);
      final key = cacheKey(songId: songId, quality: quality, source: source);
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        '${fileNameFor(key, extensionFor(url, quality))}',
      );
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
    } catch (e) {
      debugPrint('[AudioCacheService] 查找缓存失败: $e');
    }
    return null;
  }

  /// 后台把音频下载到缓存目录（失败静默忽略，不影响播放）。
  static Future<void> cacheInBackground({
    required String url,
    required Map<String, String> headers,
    required String songId,
    required String quality,
    String? source,
  }) async {
    File? temp;
    try {
      final dir = await CachePaths.subDirectory(subDirectoryName);
      final key = cacheKey(songId: songId, quality: quality, source: source);
      final target = File(
        '${dir.path}${Platform.pathSeparator}'
        '${fileNameFor(key, extensionFor(url, quality))}',
      );
      // 已经有缓存文件就不再重复下载。
      if (await target.exists() && await target.length() > 0) return;

      temp = File('${target.path}.part');
      if (await temp.exists()) {
        await temp.delete();
      }

      final dio = Dio();
      await dio.download(
        url,
        temp.path,
        options: Options(
          headers: headers,
          followRedirects: true,
          receiveTimeout: const Duration(minutes: 5),
        ),
      );

      if (await temp.exists() && await temp.length() > 0) {
        await temp.rename(target.path);
      }
      temp = null;

      // 缓存写入后按「最大缓存大小」清理旧文件。
      await CachePaths.enforceLimit();
    } catch (e) {
      debugPrint('[AudioCacheService] 缓存音频失败: $e');
    } finally {
      // 清理可能残留的半成品文件。
      try {
        if (temp != null && await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
    }
  }
}
