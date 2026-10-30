/// 下载速度采样器。
///
/// dio 的 `onReceiveProgress` 每收到一个分片就回调一次，同一毫秒内可能连续
/// 回调多次。若用「相邻两次回调」算瞬时速度，会算出 0（`elapsed == 0`）或
/// 几十 MB/s 的抖动值，界面上就表现为「速度闪一下就变成 -」。
///
/// 这里改成按固定时间窗口取平均：窗口没到就沿用上一次的值（不归零），
/// 只有整个窗口内一个字节都没收到（真的卡住）才归零。
class DownloadSpeedMeter {
  DownloadSpeedMeter({required int startBytes, DateTime? startedAt})
    : _lastSampleTime = startedAt ?? DateTime.now(),
      _lastSampleBytes = startBytes;

  /// 稳定期的采样窗口。太快会抖，太慢反馈迟钝。
  static const Duration window = Duration(milliseconds: 500);

  /// 第一次采样用更短的窗口，避免刚开始下载时长时间显示「-」。
  static const Duration firstWindow = Duration(milliseconds: 150);

  DateTime _lastSampleTime;
  int _lastSampleBytes;
  double _speed = 0;

  /// 当前速度（bytes/s）。窗口未到时返回上一次的采样值。
  double get speed => _speed;

  /// 用最新的累计字节数打点，返回此刻应该显示的速度（bytes/s）。
  ///
  /// [bytes] 是「本次下载累计收到的字节数」，断点续传时应包含续传起点，
  /// 构造时传入同样的起点，第一个窗口就不会把已有字节算成本窗口的流量。
  double sample(int bytes, DateTime now) {
    final elapsed = now.difference(_lastSampleTime);
    // 还没出过速度值时用短窗口，尽快给出第一个读数。
    final needed = _speed > 0 ? window : firstWindow;
    if (elapsed < needed) return _speed;

    final diff = bytes - _lastSampleBytes;
    final ms = elapsed.inMilliseconds;
    _speed = diff > 0 && ms > 0 ? diff * 1000 / ms : 0;
    _lastSampleTime = now;
    _lastSampleBytes = bytes;
    return _speed;
  }
}
