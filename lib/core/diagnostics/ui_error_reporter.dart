import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../platform/app_paths.dart';

/// 界面异常「可见化」。
///
/// 背景：release 版里 build 抛异常时，Flutter 用默认的 [ErrorWidget] 顶上，
/// 表现是**一整块灰屏**，看不到任何原因，日志也没有（Windows GUI 程序没有
/// 控制台，`print` 全丢）。
///
/// 这里做两件事：
/// 1. 把异常写进 `AppData/temp/logs/ui_error.log`（追加，单文件上限 1MB）；
/// 2. 灰屏上直接显示异常摘要 —— 用户截个图就能看出是哪块炸的。
///
/// 只影响「已经出错」的路径，正常渲染不受任何影响。
void installUiErrorReporting() {
  final previousOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    previousOnError?.call(details);
    _dump(
      'FlutterError',
      details.exceptionAsString(),
      details.stack,
      details.context?.toString(),
    );
  };

  // 异步链路（isolate / future）里没被捕获的异常：只记日志，不改变默认行为。
  PlatformDispatcher.instance.onError = (error, stack) {
    _dump('UncaughtError', error.toString(), stack, null);
    return false;
  };

  ErrorWidget.builder = (details) => _buildErrorWidget(details);
}

Widget _buildErrorWidget(FlutterErrorDetails details) {
  final message = details.exceptionAsString();
  final where = details.context?.toString() ?? '';
  // 不用 Material / Theme：出错的可能是主题树本身。
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFF2B2B2B),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '界面渲染失败',
                style: TextStyle(
                  color: Color(0xFFFF8A80),
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                message.length <= 600 ? message : '${message.substring(0, 600)}…',
                style: const TextStyle(
                  color: Color(0xFFE6E6E6),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              if (where.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  where,
                  style: const TextStyle(
                    color: Color(0xFF9E9E9E),
                    fontSize: 11,
                    height: 1.3,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                '完整信息已写入 AppData/temp/logs/ui_error.log',
                style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// 同一种错误 2 秒内只记一次。
///
/// 出问题的时候异常往往是「风暴」：一次缓存清理能连着抛几百条一模一样的
/// Null check，如果每条都写盘，日志本身就会把主线程拖死，反而看不出问题。
final Map<String, DateTime> _lastDumpAt = <String, DateTime>{};
final Map<String, int> _suppressedCount = <String, int>{};
const Duration _dumpInterval = Duration(seconds: 2);

/// 追加写到 `AppData/temp/logs/ui_error.log`；超过 1MB 先清空，避免无限增长。
void _dump(
  String kind,
  String message,
  StackTrace? stack,
  String? context,
) {
  final finger = '$kind|${message.length > 80 ? message.substring(0, 80) : message}';
  final now = DateTime.now();
  final last = _lastDumpAt[finger];
  if (last != null && now.difference(last) < _dumpInterval) {
    _suppressedCount[finger] = (_suppressedCount[finger] ?? 0) + 1;
    return;
  }
  final suppressed = _suppressedCount.remove(finger) ?? 0;
  _lastDumpAt[finger] = now;
  if (_lastDumpAt.length > 200) _lastDumpAt.clear();

  final text = StringBuffer()
    ..writeln('=== [$kind] ${now.toIso8601String()}')
    ..writeln(message);
  if (suppressed > 0) text.writeln('（同类错误另有 $suppressed 条已被合并）');
  if (context != null && context.trim().isNotEmpty) {
    text.writeln('context: $context');
  }
  if (stack != null) text.writeln(stack.toString());
  text.writeln();

  // 错误可能发生在任意时刻，写盘放异步夹具里，绝不在渲染链路里做同步 IO。
  unawaited(() async {
    try {
      final temp = await AppPaths.tempDirectory();
      final dir = Directory('${temp.path}${Platform.pathSeparator}logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final file = File('${dir.path}${Platform.pathSeparator}ui_error.log');
      if (file.existsSync() && file.lengthSync() > 1024 * 1024) {
        file.writeAsStringSync('');
      }
      file.writeAsStringSync(text.toString(), mode: FileMode.append);
    } catch (_) {
      // 记日志失败就算了，不能因此再抛一次。
    }
  }());
}
