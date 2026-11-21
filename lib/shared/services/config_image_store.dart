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
    final config = await AppPaths.settingsDirectory();
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
        // 已经在缓存目录里：直接复用，避免每次保存都再复制一份。
        if (p.isWithin(dir.path, file.path) ||
            p.equals(p.dirname(file.path), dir.path)) {
          return file.path;
        }
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

  /// 保存同步下来的图片，按内容摘要命名（重复内容自然去重）。
  ///
  /// 与 [cache] 不同：调用方已经拿到了图片内容，不需要再按来源路径下载。
  Future<String?> saveSynced(String digest, List<int> bytes) async {
    final name = digest.trim();
    if (name.isEmpty || bytes.isEmpty) return null;
    try {
      final dir = await _directory();
      final target = File(p.join(dir.path, '$name.img'));
      if (await target.exists() && await target.length() == bytes.length) {
        return target.path;
      }
      await target.writeAsBytes(bytes, flush: true);
      return target.path;
    } catch (e) {
      debugPrint('[ConfigImageStore/$folder] 保存图片失败: $e');
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

  // ------------------------------------------------------------ 持久化路径

  /// 存进设置前把本目录里的路径缩成文件名。
  ///
  /// 便携版整体搬目录 / 跨设备还原设置后，绝对路径必然失效；只存文件名，
  /// 读取时再拼当前目录（见 [resolveCoverPath]）。外部图片、网络地址原样保留。
  String storedValue(String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty || _isUrl(v)) return v;
    if (!p.isAbsolute(v)) return v;
    if (p.basename(p.dirname(v)) != folder) return v;
    return p.basename(v);
  }

  /// 把设置里的 `coverPath` 解析成当前目录下的绝对路径。
  ///
  /// 文件已经不在旧位置（搬过目录 / 换设备还原）时按文件名找回；
  /// 找不到返回 null，让界面回退到 `coverUrl`。
  Future<String?> resolveCoverPath(String? value) async {
    final v = value?.trim() ?? '';
    if (v.isEmpty || _isUrl(v)) return null;
    if (p.isAbsolute(v) && await File(v).exists()) return v;
    return _findByName(p.basename(v));
  }

  /// 把设置里的 `coverUrl` 里「本目录的本地图片」换成当前路径。
  ///
  /// 网络地址、外部本地文件原样返回；本目录里的旧绝对路径找不到文件时退回原文。
  Future<String> resolveCoverUrl(String? value) async {
    final v = value?.trim() ?? '';
    if (v.isEmpty || _isUrl(v)) return v;
    if (p.isAbsolute(v) && await File(v).exists()) return v;
    if (p.isAbsolute(v) && p.basename(p.dirname(v)) != folder) return v;
    // 这里只可能是本目录文件名（或旧绝对路径）；文件没了就不该再当封面用。
    return await _findByName(p.basename(v)) ?? '';
  }

  Future<String?> _findByName(String name) async {
    if (name.isEmpty) return null;
    final file = File(p.join((await _directory()).path, name));
    return await file.exists() ? file.path : null;
  }

  static bool _isUrl(String value) =>
      value.startsWith('http://') || value.startsWith('https://');
}
