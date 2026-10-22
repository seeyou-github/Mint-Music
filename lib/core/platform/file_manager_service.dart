import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 调用系统文件管理器打开目录 / 定位文件。
///
/// 目前只有 Windows 端实现了原生通道（`com.mintmusic/file_manager`）：
/// * `openFolder`：用资源管理器打开指定目录；
/// * `revealFile`：用资源管理器打开文件所在目录并选中该文件。
///
/// 其它平台没有原生实现，调用会返回 false，由调用方决定降级行为
/// （例如改成把路径显示出来）。
class FileManagerService {
  const FileManagerService._();

  static const MethodChannel _channel = MethodChannel(
    'com.mintmusic/file_manager',
  );

  /// 当前平台是否支持调用系统文件管理器。
  static bool get isSupported => Platform.isWindows;

  /// 用系统文件管理器打开 [path] 目录。
  ///
  /// 返回 false 表示当前平台不支持或打开失败。
  static Future<bool> openFolder(String path) async {
    if (path.trim().isEmpty) return false;
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('openFolder', {
        'path': path,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('[FileManagerService] 打开目录失败: $e');
      return false;
    }
  }

  /// 用系统文件管理器打开 [path] 所在目录，并选中该文件。
  static Future<bool> revealFile(String path) async {
    if (path.trim().isEmpty) return false;
    if (!isSupported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('revealFile', {
        'path': path,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('[FileManagerService] 定位文件失败: $e');
      return false;
    }
  }

  /// 用系统文件管理器打开 [filePath] 所在的文件夹。
  ///
  /// 优先直接打开所在目录（在资源管理器里浏览该目录）；目录打不开时再退回
  /// 到「打开目录并选中文件」。这样即使文件已经被移动/删除，也至少能把所在
  /// 目录打开出来，而不是直接报「无法打开所在文件夹」。
  static Future<bool> openFolderOf(String filePath) async {
    if (filePath.trim().isEmpty) return false;
    final dir = _parentDir(filePath);
    if (dir.isNotEmpty && await openFolder(dir)) return true;
    return revealFile(filePath);
  }

  /// 取文件所在目录（取不到时返回空串）。
  static String _parentDir(String filePath) {
    try {
      final parent = File(filePath).parent.path;
      if (parent.isEmpty || parent == '.') return '';
      return parent;
    } catch (_) {
      return '';
    }
  }
}
