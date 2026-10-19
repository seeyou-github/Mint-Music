import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/player/application/playback_controller.dart';
import '../../features/player/domain/models/playback_state.dart';

/// Windows 任务栏缩略图工具栏。
///
/// 鼠标悬停任务栏图标时，系统会在缩略图下方显示一排按钮。原生侧
/// （`windows/runner/thumbnail_toolbar.cpp`）通过 `ITaskbarList3` 把
/// 「上一首 / 播放暂停 / 下一首」交给系统绘制，点击按钮后原生侧再通过
/// 本通道通知 Dart 执行对应操作。
class TaskbarThumbnailService {
  TaskbarThumbnailService(this._ref) {
    _channel.setMethodCallHandler(_handleNativeCall);
    _playbackSubscription = _ref.listen<PlaybackState>(
      playbackControllerProvider,
      (previous, next) => _notifyPlaybackState(next.isPlaying),
      fireImmediately: true,
    );
  }

  static const MethodChannel _channel = MethodChannel('com.mintmusic/taskbar');

  final Ref _ref;

  ProviderSubscription<PlaybackState>? _playbackSubscription;

  /// 处理原生侧发来的按钮事件。
  Future<void> _handleNativeCall(MethodCall call) async {
    final controller = _ref.read(playbackControllerProvider.notifier);
    switch (call.method) {
      case 'playPause':
        await controller.togglePlayPause();
        break;
      case 'previous':
        await controller.previous();
        break;
      case 'next':
        await controller.next();
        break;
      default:
        break;
    }
  }

  /// 把播放状态回传给原生侧，用于切换播放 / 暂停图标。
  void _notifyPlaybackState(bool playing) {
    if (!Platform.isWindows) return;
    _channel
        .invokeMethod<void>('playbackState', {'playing': playing})
        .catchError((Object _) {});
  }

  void dispose() {
    _playbackSubscription?.close();
    _playbackSubscription = null;
  }
}

/// 任务栏缩略图工具栏服务（仅 Windows 生效，其它平台为空实现）。
final taskbarThumbnailServiceProvider =
    Provider<TaskbarThumbnailService>((ref) {
      final service = TaskbarThumbnailService(ref);
      ref.onDispose(service.dispose);
      return service;
    });
