import 'dart:io';

import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('com.mintmusic/app_info');

/// 读取已安装 APK 的 `versionName`。
///
/// versionName 在 `android/app/build.gradle.kts` 里固定写成 `20261111`
/// （与 versionCode 同一个值），本地构建和 GitHub Actions 打出来的包完全一致，
/// 不再随编译时间变化；重装、覆盖安装后依然是这个值。
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
