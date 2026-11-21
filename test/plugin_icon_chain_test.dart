import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/core/storage/app_preferences.dart';
import 'package:mintmusic/features/settings/application/plugin_providers.dart';

/// 复现用户真实数据（插件 id = 标识-author-version，iconPath 存相对路径）
/// 下的图标链路：pluginsProvider → pluginIconPathProvider。
///
/// 目的：定位「icons 目录有图标、切换音源按钮却显示内置圆标」的断点。
void main() {
  // 1x1 合法 PNG（与真实图标文件字节头一致）。
  final png = Uint8List.fromList(const [
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x62, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
  ]);

  test('真实数据链路：pluginsProvider → pluginIconPathProvider 返回图标路径', () async {
    final tmp = Directory.systemTemp.createTempSync('mintmusic_icon_chain');
    AppPaths.debugRootOverride = tmp.path;
    final container = ProviderContainer();
    addTearDown(() {
      container.dispose();
      AppPaths.debugRootOverride = null;
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    // 预置设置：installed_plugins 与用户重装后的落盘形态一致
    //（iconPath 存相对路径），并生成对应的图标文件。
    final prefs = await AppPreferences.getInstance();
    await prefs.setString('installed_plugins', jsonEncode([
      {
        'id': 'wy-MintMusic-1.9.0',
        'name': '网易_数据源',
        'version': '1.9.0',
        'author': 'MintMusic',
        'type': 'cr',
        'isEnabled': true,
        'installTime': '2026-11-21T22:43:54.000000',
        'supportedSources': [
          {
            'id': 'wy',
            'name': '网易云',
            'qualities': ['128k', '320k'],
            'downloadQualities': ['128k', '320k'],
          },
        ],
        'filePath': 'wy-MintMusic-1.9.0________js',
        'iconUrl': 'https://s1.music.126.net/style/favicon.ico',
        'iconPath': 'icons/wy-MintMusic-1.9.0.png',
        'isDataSource': true,
      },
    ]));
    final pluginsDirPath = (await AppPaths.pluginDirectory()).path;
    final iconsDir = Directory(
      '$pluginsDirPath${Platform.pathSeparator}icons',
    );
    await iconsDir.create(recursive: true);
    File(
      '${iconsDir.path}${Platform.pathSeparator}wy-MintMusic-1.9.0.png',
    ).writeAsBytesSync(png);

    // pluginsProvider（会先等插件系统初始化——测试环境里 JS 引擎不可用，
    // 各插件加载失败会被吞掉，不影响列表与图标路径的读取）。
    final plugins = await container
        .read(pluginsProvider.future)
        .timeout(const Duration(seconds: 30));
    for (final plugin in plugins) {
      // ignore: avoid_print
      print('[diag] plugin ${plugin.id} iconPath=${plugin.iconPath}');
    }

    final resolved = container.read(
      pluginIconPathProvider('wy-MintMusic-1.9.0'),
    );
    // ignore: avoid_print
    print('[diag] pluginIconPathProvider → $resolved');

    expect(resolved, isNotNull, reason: '图标链路断点复现：provider 返回了 null');
    expect(File(resolved!).existsSync(), isTrue);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
