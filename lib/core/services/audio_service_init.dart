import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';

import '../../features/player/platform/audio_handler.dart';
import '../../shared/services/app_image_cache.dart';
import '../storage/app_preferences.dart';

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

/// 是否让 ExoPlayer 走硬件 audio offload。
///
/// 只对 Android 有意义，且**必须**在「用户没改过播放速度」时才可以打开：
/// just_audio 是用「放弃 gapless / 变速支持」来换取 offload 的（见其
/// `AudioPlayer.java` 的 setAudioOffloadPreferences），一旦用户把速度调到
/// 1.0 以外，offload 通路就不支持了。速度是启动时从设置读的固定值，
/// 改速度后需要重启才生效——这是有意的取舍：宁可这次运行不开 offload，
/// 也不要让「开了 offload 的会话里变速失效」。
///
/// 真机实测结论（PCLM50 / ColorOS）：
/// * 系统「杜比音效」开启时 offload **实际不可用**：AudioTrack.start() 立刻
///   拿到 EPIPE（-32），HAL 侧 `Compress handle is NULL`，ExoPlayer 把
///   `AudioSink error` 当可恢复错误吞掉、自动回退 PCM 继续播。代价是每次
///   起播多约 440ms 与两次通路重建，耗电影响 <1%，可忽略。
/// * 关掉杜比后 offload 正常生效（AudioFlinger 的 OFFLOAD 线程上有活跃
///   track，HAL 会起 `offload_visualizer` 线程）。
/// 也就是说「能不能用」取决于 ROM 的 effect 配置，而 Dart 层收不到失败信号
/// （错误没冒到 playerStateStream），所以这里不做运行期自愈：坏设备只多付
/// 那点起播时间，不引入额外状态。
Future<bool> _shouldUseAndroidAudioOffload() async {
  if (!Platform.isAndroid) return false;
  try {
    final prefs = await AppPreferences.getInstance();
    return (prefs.getDouble('playback_speed') ?? 1.0) == 1.0;
  } catch (e) {
    // 读设置失败就不要冒险开（offload 会牺牲 gapless / 变速）。
    debugPrint('[AudioService] 读取播放速度失败，关闭 audio offload: $e');
    return false;
  }
}

Future<void> initAudioService() async {
  if (!_audioServicePlatformSupported) {
    debugPrint('[AudioService] 桌面端无 audio_service 实现，直接创建播放器 handler');
    _audioHandler = MusicAudioHandler();
    return;
  }

  final useOffload = await _shouldUseAndroidAudioOffload();
  debugPrint('[AudioService] 开始初始化（audio offload: $useOffload）');

  _audioHandler = await AudioService.init(
    builder: () => MusicAudioHandler(androidAudioOffload: useOffload),
    // 这些通知配置不再落 `shared_prefs/audio_service_preferences.xml`：
    // audio_service 已改为本地源码依赖（third_party/audio_service），其
    // AudioServiceConfig.save() 直接 return；服务比 Dart 先启动、读不到配置时，
    // 会用构造函数里硬编码的同一组值兜底。改这里记得同步那边。
    config: AudioServiceConfig(
      androidNotificationChannelId: 'com.mintmusic.channel.audio',
      androidNotificationChannelName: '音乐播放',
      androidNotificationOngoing: true,
      androidNotificationIcon: 'mipmap/logo',
      androidShowNotificationBadge: false,
      notificationColor: const Color(0xFF1DB954),
      // 通知封面按 512px 解码：原图可能几千像素，全尺寸解码出 30MB+ 的
      // 位图只为了几百像素的通知卡片，纯浪费内存与 CPU。Java 端兜底构造
      // （AudioServiceConfig.java）也要同步这个值。
      artDownscaleWidth: 512,
      artDownscaleHeight: 512,
    ),
    // 通知栏 / 锁屏封面也走 `image_cache`。不传的话 audio_service 会创建
    // `DefaultCacheManager`（key 写死为 `libCachedImageData`），把封面缓存到
    // 系统 cache 目录、索引库建到 files 目录，完全绕过「设置 - 缓存目录」。
    cacheManager: AppImageCache.manager,
  );

  debugPrint('[AudioService] 初始化完成');
}
