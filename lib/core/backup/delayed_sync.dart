import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../platform/app_paths.dart';

/// 自动同步的延迟调度（歌单同步 / 设置备份共用）。
///
/// 触发后先等一段时间再真正同步，避免连续操作（拖动排序、调设置）反复上传：
/// 本次运行里第一次 1 分钟，第二次 3 分钟，之后固定 5 分钟。计数只在本次
/// 运行内累计——应用在等待中退出，下次启动重新从 1 分钟开始。
///
/// 等待期间在 `AppData\temp` 写一个标志文件 [fileName]：
/// - 应用在等待中退出，下次启动看到标志就知道还有一次同步没跑（按第一次的
///   1 分钟延迟补上）；
/// - 标志文件只在 [trigger] / [_clearFlag] 里动，同步完成清标志不会反过来
///   再触发一次同步（触发只来自业务入口：设置写盘、歌单增删改、启动）。
class DelayedSync {
  DelayedSync({required this.fileName, required this.run});

  /// 标志文件名（`AppData\temp` 下）。
  final String fileName;

  /// 到点后真正执行的同步。
  final Future<void> Function() run;

  /// 每次触发对应的等待时间，超出后固定用最后一个。
  static const List<Duration> delays = [
    Duration(minutes: 1),
    Duration(minutes: 3),
    Duration(minutes: 5),
  ];

  Timer? _timer;

  /// 本次运行已经触发了几次（决定下一次的等待时间）。
  int _triggerCount = 0;

  bool _running = false;

  /// 标志文件的「代次」：写 / 删交错时只让最新一次生效，避免早先的删除
  /// 把刚写下的标志删掉（或早先的写入把已取消的标志又写回来）。
  int _flagGeneration = 0;

  /// 触发一次同步（启动 / 数据改动）。
  ///
  /// 已经在等待中的再触发一次，会把等待时间换成下一档（1 → 3 → 5），
  /// 连续操作因此只会越推越晚，不会一路同步。
  void trigger() {
    final index = _triggerCount < delays.length
        ? _triggerCount
        : delays.length - 1;
    final delay = delays[index];
    _triggerCount++;
    _timer?.cancel();
    _timer = Timer(delay, _fire);
    unawaited(_writeFlag(delay, ++_flagGeneration));
  }

  /// 启动时调用：上次退出还留着标志，就按第一次的 1 分钟补一次同步。
  ///
  /// 返回是否补排了。
  Future<bool> resumeIfPending() async {
    if (_timer != null || _running) return false;
    if (!await _flagExists()) return false;
    trigger();
    return true;
  }

  /// 取消等待（手动同步已经做完时调用，避免再做一次重复的自动同步）。
  void cancel() {
    _timer?.cancel();
    _timer = null;
    unawaited(_clearFlag(++_flagGeneration));
  }

  void _fire() {
    _timer = null;
    unawaited(() async {
      if (_running) return;
      _running = true;
      try {
        await run();
      } catch (e) {
        debugPrint('[DelayedSync:$fileName] 同步失败: $e');
      } finally {
        _running = false;
        // 等待期间又被触发过（新定时器还在）：标志要留给那一轮。
        if (_timer == null) await _clearFlag(++_flagGeneration);
      }
    }());
  }

  Future<File?> _flagFile() async {
    try {
      final dir = await AppPaths.tempDirectory();
      return File(p.join(dir.path, fileName));
    } catch (e) {
      debugPrint('[DelayedSync:$fileName] 取临时目录失败: $e');
      return null;
    }
  }

  Future<void> _writeFlag(Duration delay, int generation) async {
    try {
      final file = await _flagFile();
      if (file == null || generation != _flagGeneration) return;
      await file.writeAsString(
        jsonEncode({
          'dueAt': DateTime.now().add(delay).toIso8601String(),
          'delaySeconds': delay.inSeconds,
        }),
        flush: true,
      );
    } catch (e) {
      debugPrint('[DelayedSync:$fileName] 写标志失败: $e');
    }
  }

  Future<bool> _flagExists() async {
    try {
      final file = await _flagFile();
      return file != null && await file.exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearFlag(int generation) async {
    try {
      final file = await _flagFile();
      if (file == null || generation != _flagGeneration) return;
      if (await file.exists()) await file.delete();
    } catch (e) {
      debugPrint('[DelayedSync:$fileName] 清标志失败: $e');
    }
  }
}
