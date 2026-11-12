import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';

/// 随安装包内置的高斯模糊背景图文件名（资源在 `assets/images/backgrounds/`）。
///
/// 首次启动会复制进 `config/setting/background_pic`，之后和用户自己添加的图
/// 一样按文件名使用；文件被删掉时下次启动自动补回来。
const List<String> builtinBlurBackgroundNames = [
  '1.jpg',
  '2.jpg',
  '3.jpg',
  '4.jpg',
];

/// 把内置背景图复制到设置目录，返回实际可用的文件名。
///
/// 已存在的文件不覆盖（用户目录里的同名文件优先保持原样），单个文件失败
/// 只打日志、不影响启动。
Future<List<String>> ensureBuiltinBlurBackgrounds() async {
  final dir = await AppPaths.blurBackgroundDirectory();
  final available = <String>[];
  for (final name in builtinBlurBackgroundNames) {
    final file = File(p.join(dir.path, name));
    try {
      if (!await file.exists()) {
        final data = await rootBundle.load('assets/images/backgrounds/$name');
        await file.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      available.add(name);
    } catch (e) {
      debugPrint('[Background] 内置背景图 $name 写入失败: $e');    }
  }
  return available;
}
