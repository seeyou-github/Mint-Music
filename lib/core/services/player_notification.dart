import 'dart:io';

import 'package:flutter/services.dart';

/// 通知栏播放卡片（仅 Android）与原生之间的桥。
///
/// 原生实现分两块：
/// - 卡片本身：`third_party/audio_service/.../MintNotification.java`（vendored 的
///   audio_service 里，改掉默认的 MediaStyle 通知）；
/// - 通道：`android/app/src/main/kotlin/.../PlayerNotificationChannel.kt`。
///
/// 卡片上的五个按钮：收藏 / 上一首 / 播放暂停 / 下一首 / 桌面歌词。其中上一首、
/// 播放暂停、下一首是系统媒体键，完全走原生（和耳机线控同一条链路），Dart 不用参与；
/// 只有「收藏」和「桌面歌词」需要应用层处理，就是这里的两条通道。
class PlayerNotification {
  PlayerNotification._();

  static const MethodChannel _channel = MethodChannel('mintmusic/notification');

  /// 自定义通知卡片只在 Android 上有。
  static bool get supported => Platform.isAndroid;

  /// 通知栏按钮的动作。
  static const String actionFavorite = 'favorite';
  static const String actionLyric = 'lyric';

  /// 注册 Dart 侧处理器（应用启动时调用一次）。
  static void attach({required void Function(String action) onAction}) {
    if (!supported) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action') {
        final action = call.arguments as String?;
        if (action != null && action.isNotEmpty) onAction(action);
      }
      return null;
    });
  }

  /// 原生侧暂存的动作（Dart 还没注册处理器时点了通知按钮），启动后取一次。
  ///
  /// 返回后原生侧即清空，不会重复处理。
  static Future<String?> consumeLaunchAction() async {
    if (!supported) return null;
    try {
      return await _channel.invokeMethod<String>('consumeLaunchAction');
    } catch (_) {
      return null;
    }
  }

  /// 把「当前歌曲是否已收藏」同步给原生，通知里的红心据此显示实心 / 空心。
  ///
  /// 值没变时原生侧直接忽略，不会重绘通知。
  static Future<void> setFavorite(bool value) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('setFavorite', value);
    } catch (_) {
      // 原生侧还没起来（或在别的平台）时静默忽略：红心只是慢一拍。
    }
  }
}
