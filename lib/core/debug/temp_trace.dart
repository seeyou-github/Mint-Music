// TEMP-TRACE-BEGIN
//
// 临时诊断日志（问题定位后整体删除，删除方式见仓库说明）：
//   · 删除本文件 lib/core/debug/temp_trace.dart
//   · 删除所有带 `TEMP-TRACE` 标记的行 / import
//
// 输出位置：exe 所在目录下的 debug_trace.log（release 构建同样生效）。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

class TempTrace {
  TempTrace._();

  static IOSink? _sink;
  static String? _path;
  static int _writes = 0;
  static bool enabled = true;

  static String get logPath {
    final cached = _path;
    if (cached != null) return cached;
    String dir;
    try {
      dir = File(Platform.resolvedExecutable).parent.path;
    } catch (_) {
      dir = Directory.current.path;
    }
    _path = '$dir${Platform.pathSeparator}debug_trace.log';
    return _path!;
  }

  static IOSink? _ensureSink() {
    final existing = _sink;
    if (existing != null) return existing;
    try {
      final file = File(logPath);
      // 超过 8MB 直接重开，避免无限增长。
      if (file.existsSync() && file.lengthSync() > 8 * 1024 * 1024) {
        file.deleteSync();
      }
      final sink = file.openWrite(mode: FileMode.append);
      _sink = sink;
      sink.writeln(
        '===== trace session start ${DateTime.now().toIso8601String()} =====',
      );
      sink.flush();
      return sink;
    } catch (e) {
      debugPrint('[TempTrace] 打开日志失败: $e');
      return null;
    }
  }

  static void log(String tag, String message) {
    if (!enabled) return;
    final now = DateTime.now();
    final line =
        '${now.toIso8601String()} (+${now.millisecondsSinceEpoch % 1000000}) [$tag] $message';
    debugPrint(line);
    final sink = _ensureSink();
    if (sink == null) return;
    try {
      sink.writeln(line);
      // 每 8 行 flush 一次：崩溃时最多丢几行，又不至于每行都同步刷盘。
      if (++_writes % 8 == 0) unawaited(sink.flush());
    } catch (_) {}
  }

  /// 异常 + 栈，方便一次看清是谁抛的。
  static void error(String tag, String message, Object error, [StackTrace? st]) {
    log(tag, '$message | error=$error');
    if (st != null) {
      final lines = st.toString().split('\n');
      for (final line in lines.take(12)) {
        log(tag, '    $line');
      }
    }
  }
}
// TEMP-TRACE-END
