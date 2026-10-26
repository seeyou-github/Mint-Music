import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../../../core/platform/app_paths.dart';
import 'dart:convert';

/// 电台封面缓存：把用户填的封面（本地图片 / 网络地址）落到应用数据目录，
/// 之后离线也能显示。
///
/// 放在 `config/radio_covers` 而不是缓存目录：缓存目录可能被「清理缓存」
/// 清掉，电台封面属于用户配置，不该跟着缓存一起消失。
class RadioCoverCache {
  const RadioCoverCache._();

  static const String _folderName = 'radio_covers';

  static Future<Directory> _directory() async {
    final config = await AppPaths.configDirectory();
    final dir = Directory(p.join(config.path, _folderName));
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

  /// 缓存封面，返回本地路径；失败返回 null。
  ///
  /// [source] 可以是本地文件路径，也可以是 http(s) 地址。
  static Future<String?> cache(String source) async {
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
      debugPrint('[RadioCoverCache] 缓存封面失败: $e');
      return null;
    }
  }

  /// 删除某个封面文件（电台被删 / 换封面时调用）。
  static Future<void> remove(String? path) async {
    final value = path?.trim() ?? '';
    if (value.isEmpty) return;
    try {
      final file = File(value);
      if (await file.exists()) await file.delete();
    } catch (_) {}
  }
}
