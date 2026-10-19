import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/player/platform/audio_handler.dart';

MusicAudioHandler? _audioHandler;

MusicAudioHandler get audioHandler {
  if (_audioHandler == null) {
    throw StateError('AudioService 未初始化，请先调用 initAudioService()');
  }
  return _audioHandler!;
}

/// audio_service 只实现了 Android / iOS / macOS / Web。
///
/// Windows / Linux 上没有原生实现，`AudioService.init` 会抛
/// `MissingPluginException`（通知栏 / 媒体会话在桌面端本来也不存在）。
/// 桌面端直接构造 [MusicAudioHandler]：它本质上是 just_audio 播放器的封装，
/// 不依赖 audio_service 的平台通道，播放、歌词、队列都能正常工作。
bool get _audioServicePlatformSupported =>
    !(Platform.isWindows || Platform.isLinux);

Future<void> initAudioService() async {
  if (!_audioServicePlatformSupported) {
    debugPrint('[AudioService] 桌面端无 audio_service 实现，直接创建播放器 handler');
    _audioHandler = MusicAudioHandler();
    return;
  }

  debugPrint('[AudioService] 开始初始化');

  _audioHandler = await AudioService.init(
    builder: () => MusicAudioHandler(),
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.mintmusic.channel.audio',
      androidNotificationChannelName: '音乐播放',
      androidNotificationOngoing: true,
      androidNotificationIcon: 'mipmap/logo',
      androidShowNotificationBadge: false,
      notificationColor: const Color(0xFF1DB954),
    ),
  );

  debugPrint('[AudioService] 初始化完成');
}
