import 'package:dio/dio.dart' as dio;

import 'webdav_service.dart';

/// 一次远端同步 / 备份尝试：超时上限 + 可取消的 HTTP 请求。
///
/// 仅用 `Future.timeout` 只是「不再等待」——底层请求还在跑，服务器迟到的响应
/// 仍可能被合并、写盘。这里给每次尝试配一个 `dio.CancelToken`，[WebDavService]
/// 的每个请求都带上它，超时的那一刻把请求真正取消掉，迟到的响应不会再被使用。
///
/// 超时时长：首次尝试 1 分钟，之后每次重试 2 分钟（继续重试仍是 2 分钟）。
class SyncAttempt {
  SyncAttempt(this.attempt, {Duration? overwriteTimeout})
    : cancelToken = dio.CancelToken(),
      _overwriteTimeout = overwriteTimeout;

  /// 首次尝试的超时。
  static const Duration firstTimeout = Duration(minutes: 1);

  /// 重试的超时（第 2 次及以后）。
  static const Duration retryTimeout = Duration(minutes: 2);

  /// 第 [attempt] 次尝试（从 1 开始）应该用多长的超时。
  static Duration timeoutFor(int attempt) =>
      attempt <= 1 ? firstTimeout : retryTimeout;

  /// 这是第几次尝试（1 = 用户刚点的那次，2 起是「重新同步」）。
  final int attempt;

  /// 覆盖默认超时：下载备份这类耗时与文件大小成正比的操作用它单独放大。
  final Duration? _overwriteTimeout;

  /// 本次尝试的取消令牌：一旦超时，所有带它的请求都会被取消。
  final dio.CancelToken cancelToken;

  Duration get timeout => _overwriteTimeout ?? timeoutFor(attempt);

  bool get isCancelled => cancelToken.isCancelled;

  /// 主动取消（超时时自动调用）。
  void cancel([String reason = '同步超时']) {
    if (!cancelToken.isCancelled) cancelToken.cancel(reason);
  }

  /// 给整次远端操作套上超时：到点先取消底层请求，再抛出可读的超时原因。
  ///
  /// 取消后正在等待的请求会以 `DioException(cancel)` 结束，这个错误不会再
  /// 传到界面上（调用方拿到的是下面的 [WebDavException]）。
  Future<T> run<T>(Future<T> future) {
    return future.timeout(
      timeout,
      onTimeout: () {
        cancel();
        throw WebDavException(
          '超时：${_describe(timeout)}内没有完成，'
          '请检查网络或 WebDAV 服务器后重试',
        );
      },
    );
  }

  /// 超时时长的人话描述：放大到几分钟之后，不能再一律按「N 分钟内」播报。
  static String _describe(Duration duration) {
    if (duration.inSeconds < 60) return '${duration.inSeconds} 秒';
    if (duration.inSeconds % 60 == 0) return '${duration.inMinutes} 分钟';
    return '${duration.inMinutes} 分 ${duration.inSeconds % 60} 秒';
  }
}
