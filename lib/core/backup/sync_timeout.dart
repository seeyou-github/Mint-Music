import 'webdav_service.dart';

/// 远端同步 / 备份操作的超时策略。
///
/// 歌单同步、WebDAV 备份上传、远端备份下载这些操作会连着发好几个请求，
/// 遇到服务器「连上了但一直不回」的情况，单次请求的超时（连接 15s / 接收
/// 30s）未必能及时收场，界面会一直卡在「同步中」。这里给整次尝试加一个
/// 上限：
///
/// - 首次尝试：**1 分钟**；
/// - 之后每次重试：**2 分钟**（继续重试仍是 2 分钟）。
class SyncTimeout {
  const SyncTimeout._();

  /// 首次尝试的超时。
  static const Duration firstAttempt = Duration(minutes: 1);

  /// 重试的超时（第 2 次及以后）。
  static const Duration retry = Duration(minutes: 2);

  /// 第 [attempt] 次尝试（从 1 开始）应该用多长的超时。
  static Duration forAttempt(int attempt) =>
      attempt <= 1 ? firstAttempt : retry;

  /// 给整次远端操作套上第 [attempt] 次尝试的超时。
  ///
  /// 超时抛出 [WebDavException]，界面沿用 `describeWebDavError` 展示原因，
  /// 和网络 / 鉴权失败的展示方式保持一致。
  ///
  /// 注意：`Future.timeout` 只是不再等待，底层请求可能仍在后台跑完，
  /// 因此调用方在超时后不要再基于结果更新界面。
  static Future<T> guard<T>(Future<T> future, {required int attempt}) {
    final limit = forAttempt(attempt);
    return future.timeout(
      limit,
      onTimeout: () => throw WebDavException(
        '超时：${limit.inMinutes} 分钟内没有完成，'
        '请检查网络或 WebDAV 服务器后重试',
      ),
    );
  }
}
