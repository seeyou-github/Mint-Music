import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// 回归：歌单 id 可能带 `/`、`?`。
///
/// 插件来源的榜单 id 是 `mf:board:<音源>:<原始 id>`，原始 id 里就有斜杠和查询串
/// （bilibili 的 `popular/series/one?number=396`），收藏后本地歌单 id 变成
/// `discover_mf:board:...:popular/series/one?number=396`。直接拼进
/// `/library/playlist/:id` 会被 go_router 切成多段，报
/// `GoException: no routes for location`。
///
/// 这里复刻 app_router 里的那条路由，锁住「必须 Uri.encodeComponent」这个约定。
void main() {
  const boardPlaylistId =
      'discover_mf:board:bilibili@1a16f66000f:popular/series/one?number=396';

  GoRouter buildRouter() => GoRouter(
    initialLocation: '/library',
    routes: [
      GoRoute(path: '/library', builder: (_, _) => const SizedBox()),
      GoRoute(
        path: '/library/playlist/:id',
        builder: (_, _) => const SizedBox(),
      ),
    ],
  );

  test('编码后的歌单 id 能匹配路由，并还原成原始 id', () {
    final router = buildRouter();
    final match = router.configuration.findMatch(
      Uri.parse('/library/playlist/${Uri.encodeComponent(boardPlaylistId)}'),
    );

    expect(match.isError, isFalse);
    expect(match.pathParameters['id'], boardPlaylistId);

    router.dispose();
  });

  test('未编码的歌单 id 匹配不到路由（这就是原来的 bug）', () {
    final router = buildRouter();
    final match = router.configuration.findMatch(
      Uri.parse('/library/playlist/$boardPlaylistId'),
    );

    expect(match.isError, isTrue);

    router.dispose();
  });

  test('已经编码过一次的 id 再编码一次也不会丢信息', () {
    final router = buildRouter();
    // 新版收藏落盘时已经把原始 id 编码过，打开时还会再编码一次。
    final encodedOnce = 'discover_${Uri.encodeComponent(boardPlaylistId)}';
    final match = router.configuration.findMatch(
      Uri.parse('/library/playlist/${Uri.encodeComponent(encodedOnce)}'),
    );

    expect(match.isError, isFalse);
    expect(match.pathParameters['id'], encodedOnce);

    router.dispose();
  });
}
