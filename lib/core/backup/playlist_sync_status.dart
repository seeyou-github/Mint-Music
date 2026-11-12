import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 歌单同步的当前状态（用于应用窗口底部的同步提示）。
enum PlaylistSyncPhase {
  /// 空闲：不显示提示。
  idle,

  /// 正在同步：底部显示转圈 + 「正在同步歌单」。
  syncing,

  /// 刚刚同步成功：短暂显示勾选后自动隐藏。
  success,

  /// 同步失败：短暂显示失败原因后自动隐藏。
  failed,
}

/// 同步的内容：歌单，还是「自动同步」里的设置 / 插件备份。
///
/// 两者共用窗口底部的一条提示，只是文案不同。
enum PlaylistSyncKind { playlist, backup }

/// 同步状态。
class PlaylistSyncStatus {
  const PlaylistSyncStatus({
    this.phase = PlaylistSyncPhase.idle,
    this.message,
    this.kind = PlaylistSyncKind.playlist,
  });

  final PlaylistSyncPhase phase;

  /// 失败原因（[phase] 为 failed 时有值）。
  final String? message;

  /// 这次提示对应的是歌单同步还是设置备份。
  final PlaylistSyncKind kind;

  bool get isVisible => phase != PlaylistSyncPhase.idle;

  static const idle = PlaylistSyncStatus();
}

/// 全局歌单同步状态。
///
/// 只有「自动同步」（收藏页增删改触发的推送、开启实时同步开关后触发的同步）
/// 会写入这里，用于在窗口底部显示提示；启动时的后台同步不写，保持静默，
/// 失败时才弹框（见 `app.dart`）。
class PlaylistSyncStatusNotifier extends StateNotifier<PlaylistSyncStatus> {
  PlaylistSyncStatusNotifier() : super(PlaylistSyncStatus.idle);

  Timer? _hideTimer;

  /// 同步开始。
  void start({PlaylistSyncKind kind = PlaylistSyncKind.playlist}) {
    _hideTimer?.cancel();
    _hideTimer = null;
    state = PlaylistSyncStatus(phase: PlaylistSyncPhase.syncing, kind: kind);
  }

  /// 同步成功：显示 2 秒后自动隐藏。
  void succeed({PlaylistSyncKind kind = PlaylistSyncKind.playlist}) {
    _hideTimer?.cancel();
    state = PlaylistSyncStatus(phase: PlaylistSyncPhase.success, kind: kind);
    _hideTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) state = PlaylistSyncStatus.idle;
    });
  }

  /// 同步失败：显示 4 秒后自动隐藏。
  void fail(
    String message, {
    PlaylistSyncKind kind = PlaylistSyncKind.playlist,
  }) {
    _hideTimer?.cancel();
    state = PlaylistSyncStatus(
      phase: PlaylistSyncPhase.failed,
      message: message,
      kind: kind,
    );
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) state = PlaylistSyncStatus.idle;
    });
  }

  /// 立即隐藏（例如开始播放全屏页面时）。
  void dismiss() {
    _hideTimer?.cancel();
    _hideTimer = null;
    state = PlaylistSyncStatus.idle;
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }
}

final playlistSyncStatusProvider =
    StateNotifierProvider<PlaylistSyncStatusNotifier, PlaylistSyncStatus>(
      (ref) => PlaylistSyncStatusNotifier(),
    );
