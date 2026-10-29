import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../core/platform/app_paths.dart';

/// 「用户配置里引用的图片」的本地缓存（电台封面 / 自定义歌单封面等）。
///
/// 每个实例对应 `AppData/config/<folder>` 下的一个子目录。放在配置目录而不是
/// 缓存目录：这些图属于用户配置，不该被「清理缓存」一起清掉。
class ConfigImageStore {
  const ConfigImageStore(this.folder);

  /// 子目录名（`config/` 下）。
  final String folder;

  Future<Directory> _directory() async {
    final config = await AppPaths.configDirectory();
    final dir = Directory(p.join(config.path, folder));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _hash(String value) =>
      md5.convert(utf8.encode(value)).toString();

  static String _extensionOf(String path, {String fallback = '.jpg'}) {
    final ext = p.extension(path).toLowerCase();
    if (const [
      '.jpg',
      '.jpeg',
      '.png',
      '.webp',
      '.gif',
      '.bmp',
    ].contains(ext)) {
      return ext;
    }
    return fallback;
  }

  /// 缓存图片，返回本地路径；失败返回 null。
  ///
  /// [source] 可以是本地文件路径，也可以是 http(s) 地址。
  Future<String?> cache(String source) async {
    final value = source.trim();
    if (value.isEmpty) return null;
    try {
      final dir = await _directory();
      final isRemote =
          value.startsWith('http://') || value.startsWith('https://');

      if (!isRemote) {
        final file = File(value);
        if (!await file.exists()) return null;
        final target = File(
          p.join(dir.path, '${_hash(value)}${_extensionOf(value)}'),
        );
        if (p.equals(file.path, target.path)) return target.path;
        await file.copy(target.path);
        return target.path;
      }

      final target = File(
        p.join(dir.path, '${_hash(value)}${_extensionOf(value)}'),
      );
      if (await target.exists() && await target.length() > 0) {
        return target.path;
      }
      final response = await Dio().get<List<int>>(
        value,
        options: Options(
          responseType: ResponseType.bytes,
          followRedirects: true,
          receiveTimeout: const Duration(seconds: 20),
        ),
      );
      final bytes = response.data;
      if (bytes == null || bytes.isEmpty) return null;
      await target.writeAsBytes(bytes, flush: true);
      return target.path;
    } catch (e) {
      debugPrint('[ConfigImageStore/$folder] 缓存图片失败: $e');
      return null;
    }
  }

  /// 删除某个已缓存的图片（配置被删 / 换图时调用）。
  Future<void> remove(String? path) async {
    final value = path?.trim() ?? '';
    if (value.isEmpty) return;
    try {
      final file = File(value);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
