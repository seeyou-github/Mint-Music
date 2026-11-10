import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('com.mintmusic/app_info');

/// 读取已安装 APK 的 `versionName`。
///
/// versionName 由 Gradle 在构建时写成编译时间（北京时间，格式
/// `年.月日.时分`，见 `android/app/build.gradle.kts`），所以它代表「这个包
/// 是哪一次构建出来的」，重装、覆盖安装后依然准确。
///
/// 非 Android、通道不可用（单元测试等）或读取失败时返回 null，由调用方兜底。
Future<String?> readAndroidAppVersionName() async {
  if (!Platform.isAndroid) return null;
  try {
    final version = await _channel.invokeMethod<String>('versionName');
    final text = version?.trim() ?? '';
    return text.isEmpty ? null : text;
  } catch (_) {
    return null;
  }
}
