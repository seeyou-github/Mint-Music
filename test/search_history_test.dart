import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/features/discover/application/search_providers.dart';

/// 搜索历史的落盘 / 恢复回归测试。
///
/// 背景：搜索历史走 `DeferredWriter` 延迟写盘，而 `DeferredWriter.flush()`
/// 曾经在调用 `_doWrite()` 前把 `_dirty` 清掉，导致 `while (_dirty)` 循环
/// 一次都不执行 —— 搜索历史从来没写进数据库，重启后永远为空。
void main() {
  test('搜索历史写入临时库并在「重启」后按时间倒序恢复', () async {
    final dir = Directory.systemTemp.createTempSync('mintmusic_search_test');
    AppPaths.debugRootOverride = dir.path;
    try {
      final first = SearchHistoryNotifier();
      // 先等初始加载结束，避免它把随后写入的记录当成「旧数据」再合并一次。
      await Future<void>.delayed(const Duration(milliseconds: 200));
      first.addQuery('周杰伦');
      first.addQuery('林俊杰');
      // 立即写库是异步的，等它落盘。
      await Future<void>.delayed(const Duration(milliseconds: 300));

      // 新的 notifier 相当于「重启后重新进入搜索页」。
      final second = SearchHistoryNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(second.state, ['林俊杰', '周杰伦']);

      // 清空后也要落盘，重启不会再冒出来。
      second.clearHistory();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final third = SearchHistoryNotifier();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(third.state, isEmpty);

      first.dispose();
      second.dispose();
      third.dispose();
    } finally {
      AppPaths.debugRootOverride = null;
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });
}
