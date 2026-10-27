import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../plugin/domain/source_id_mapping.dart';
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

  /// 缓存文件名：`歌手 - 歌名 [音质-音源标签].扩展名`，
  /// 音源标签见 [sourceLabelFor]（裸平台 id 用平台名，插件用
  /// `平台-插件-插件id`）。
  ///
  /// 缓存目录里的音频文件用「歌手 - 歌名」命名，方便直接识别；
  /// 歌手 / 歌名缺失时回退为 `歌曲id [音质-音源].扩展名`。
  ///
  /// 方括号里必须带**音源标签**：同名同歌手的不同歌曲（翻唱 / Live /
  /// 不同平台的版本）在旧命名下会互相命中对方的缓存，播错音频。
  /// 音质也保留在键里，避免同一首歌 128k / 320k 互相错命中。
  static String fileNameFor({
    required String songId,
    required String quality,
    required String extension,
    String? source,
    String? artist,
    String? title,
  }) {
    final safeArtist = _sanitizeFileName(artist);
    final safeTitle = _sanitizeFileName(title);
    final tag = _sanitizeFileName('$quality-${sourceLabelFor(source)}');
    if (safeArtist.isNotEmpty && safeTitle.isNotEmpty) {
      return '$safeArtist - $safeTitle [$tag].$extension';
    }
    if (safeTitle.isNotEmpty) {
      return '$safeTitle [$tag].$extension';
    }
    if (safeArtist.isNotEmpty) {
      return '$safeArtist [$tag].$extension';
    }
    final safeId = _sanitizeFileName(songId);
    return '$safeId [$tag].$extension';
  }

  /// 音源 id → 文件名里的音源标签。
  ///
  /// * 裸平台 id（wy / kg / …）→平台名，如「网易云音乐」；
  /// * 插件音源带 `@插件id` 后缀（如 `wy@1a16f66000f`）→
  ///   「网易云音乐-插件-1a16f66000f」。
  ///
  /// 插件音源**必须带上插件 id**：同一平台可以装多个插件（比如两个网易插件），
  /// 它们的展示名可能完全相同（单音源插件在界面上连插件名都不显示，都叫
  /// 「网易云音乐-插件」），只按平台名区分会让两个插件的缓存互相命中——
  /// 表现为 A 插件解析的歌播出来是 B 插件缓存下来的音频（音质 / 文件都可能不同）。
  /// 插件 id 是安装时生成并持久化的（`PluginService`），能稳定区分。
  static String sourceLabelFor(String? source) {
    final raw = (source ?? '').trim();
    if (raw.isEmpty) return '未知音源';
    if (raw == 'local') return '本地';
    final at = raw.indexOf('@');
    final base = (at == -1 ? raw : raw.substring(0, at)).trim();
    if (base.isEmpty) return '未知音源';
    final name = SourceIdMapping.idToName[base] ?? base;
    if (at == -1) return name;
    final pluginId = raw.substring(at + 1).trim();
    if (pluginId.isEmpty) return '$name-插件';
    return '$name-插件-$pluginId';
  }

  /// 去掉文件名里的非法字符（与下载文件名规则保持一致）。
  static String _sanitizeFileName(String? value) {
    if (value == null) return '';
    return value
        .replaceAll(RegExp(r'[/\\:*?"<>|\r\n\t]'), '')
        .replaceAll(RegExp(r'^\.+'), '')
        .replaceAll(RegExp(r'\.+$'), '')
        .trim();
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
  ///
  /// 文件名按「当前歌曲的音源」推导：同一首歌换了音源（不同插件 /
  /// 不同平台）后不会命中别的源缓存的文件。
  static Future<File?> findCachedFile({
    required String songId,
    required String quality,
    required String url,
    String? source,
    String? artist,
    String? title,
  }) async {
    try {
      final dir = await CachePaths.subDirectory(subDirectoryName);
      final file = File(
        '${dir.path}${Platform.pathSeparator}'
        '${fileNameFor(songId: songId, quality: quality, extension: extensionFor(url, quality), source: source, artist: artist, title: title)}',
      );
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
    } catch (e) {
      debugPrint('[AudioCacheService] 查找缓存失败: $e');
    }
    return null;
  }

  /// 正在进行的后台缓存任务（同一首歌快速重播时直接复用，避免两个下载
  /// 同时写同一个 `.part` 临时文件）。
  static final Map<String, Future<void>> _inFlight = {};

  /// 后台把音频下载到缓存目录（失败静默忽略，不影响播放）。
  static Future<void> cacheInBackground({
    required String url,
    required Map<String, String> headers,
    required String songId,
    required String quality,
    String? source,
    String? artist,
    String? title,
  }) {
    final dedupeKey = '$songId|$quality|$source|$url';
    final running = _inFlight[dedupeKey];
    if (running != null) return running;
    final future = _doCacheInBackground(
      url: url,
      headers: headers,
      songId: songId,
      quality: quality,
      source: source,
      artist: artist,
      title: title,
    );
    _inFlight[dedupeKey] = future;
    return future.whenComplete(() => _inFlight.remove(dedupeKey));
  }

  static Future<void> _doCacheInBackground({
    required String url,
    required Map<String, String> headers,
    required String songId,
    required String quality,
    String? source,
    String? artist,
    String? title,
  }) async {
    File? temp;
    try {
      final dir = await CachePaths.subDirectory(subDirectoryName);
      final target = File(
        '${dir.path}${Platform.pathSeparator}'
        '${fileNameFor(songId: songId, quality: quality, extension: extensionFor(url, quality), source: source, artist: artist, title: title)}',
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
