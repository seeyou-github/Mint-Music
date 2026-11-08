import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../app/app_page_background.dart';
import '../../app/app_shell.dart';
import '../../features/discover/presentation/discover_page.dart';
import '../../features/discover/presentation/search_page.dart';
import '../../features/discover/presentation/collection_detail_page.dart';
import '../../features/discover/domain/models/search_collection.dart';
import '../../features/discover/presentation/playlist_detail_page.dart';
import '../../features/library/presentation/library_page.dart';
import '../../features/library/presentation/artist_update_page.dart';
import '../../features/library/presentation/local_playlist_detail_page.dart';
import '../../features/library/domain/models/recently_played.dart';
import '../../features/library/presentation/recently_played_page.dart';
import '../../features/discover/presentation/recognize_page.dart';
import '../../features/local/presentation/tag_editor_page.dart';
import '../../features/local/presentation/quick_match_page.dart';
import '../../features/settings/presentation/plugin_management_page.dart';
import '../../features/local/presentation/local_page.dart';
import '../../features/mine/presentation/mine_page.dart';
import '../../features/download/presentation/download_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import '../../features/player/presentation/full_player_page.dart';
import '../../features/player/presentation/lyric_page.dart';
import '../constants/app_routes.dart';
import 'navigation_shell_provider.dart';

/// 二级页面的统一转场：从右侧滑入，并给页面铺一层不透明的主界面背景。
///
/// 页面自己的 `Scaffold` 是透明的（主界面背景由 `MaterialApp.builder` 里那层
/// 全局渐变负责）。转场里**必须**把这份背景也塞进滑动的那一块：
/// 否则滑入时下面那一页的内容会从缝隙里透出来，滑出时看着像底部页面提前出现，
/// 而不是被慢慢地揭开。详见 [AppPageBackground]。
Widget _slideTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  return SlideTransition(
    position: Tween<Offset>(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
    child: AppPageBackground(child: child),
  );
}

/// 右侧滑入的二级页面转场。
CustomTransitionPage<void> _slidePage({
  required LocalKey key,
  required Widget child,
}) {
  return CustomTransitionPage<void>(
    key: key,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: _slideTransition,
  );
}

final appRouter = GoRouter(
  initialLocation: AppRoutes.discover,
  routes: [
    StatefulShellRoute.indexedStack(
      builder: (context, state, navigationShell) {
        return AppShell(navigationShell: navigationShell);
      },
      branches: [
        // ── 发现 ──────────────────────────────────────────────
        // 歌单 / 榜单详情放在发现分支内，切换分类再切回来时会恢复到
        // 之前打开的那张歌单。
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.discover,
              builder: (context, state) => const DiscoverPage(),
            ),
            GoRoute(
              path: AppRoutes.playlistDetail,
              pageBuilder: (context, state) {
                final playlistId = state.pathParameters['id'] ?? '';
                // 排行榜打开的记成「榜单」来源（播放页显示来源标签）。
                final sourceType = state.uri.queryParameters['type'] == 'rank'
                    ? PlaybackSourceType.rank
                    : PlaybackSourceType.playlist;
                return CustomTransitionPage(
                  key: state.pageKey,
                  child: PlaylistDetailPage(
                    playlistId: playlistId,
                    sourceType: sourceType,
                  ),
                  transitionDuration: const Duration(milliseconds: 220),
                  reverseTransitionDuration: const Duration(milliseconds: 180),
                  transitionsBuilder: _slideTransition,
                );
              },
            ),
            GoRoute(
              path: AppRoutes.collectionDetail,
              builder: (context, state) {
                final extra = state.extra;
                if (extra is! SearchCollection) {
                  return const SizedBox.shrink();
                }
                return CollectionDetailPage(collection: extra);
              },
            ),
            GoRoute(
              path: AppRoutes.search,
              pageBuilder: (context, state) => CustomTransitionPage(
                key: state.pageKey,
                child: const SearchPage(),
                transitionDuration: const Duration(milliseconds: 220),
                reverseTransitionDuration: const Duration(milliseconds: 180),
                transitionsBuilder: _slideTransition,
              ),
            ),
          ],
        ),

        // ── 歌单 ──────────────────────────────────────────────
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.library,
              builder: (context, state) => const LibraryPage(),
            ),
            GoRoute(
              path: AppRoutes.localPlaylistDetail,
              pageBuilder: (context, state) {
                final playlistId = state.pathParameters['id'] ?? '';
                return CustomTransitionPage(
                  key: state.pageKey,
                  child: LocalPlaylistDetailPage(playlistId: playlistId),
                  transitionDuration: const Duration(milliseconds: 220),
                  reverseTransitionDuration: const Duration(milliseconds: 180),
                  transitionsBuilder: _slideTransition,
                );
              },
              routes: [
                GoRoute(
                  path: 'artist-update',
                  pageBuilder: (context, state) => _slidePage(
                    key: state.pageKey,
                    child: ArtistUpdatePage(
                      playlistId: state.pathParameters['id'] ?? '',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),

        // ── 本地 ──────────────────────────────────────────────
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.local,
              builder: (context, state) => const LocalPage(),
            ),
          ],
        ),

        // ── 我的 ──────────────────────────────────────────────
        // 设置 / 下载 / 插件管理 / 最近播放 / 听歌识曲都属于「我的」分支。
        StatefulShellBranch(
          routes: [
            GoRoute(
              path: AppRoutes.mine,
              builder: (context, state) => const MinePage(),
            ),
            GoRoute(
              path: AppRoutes.settings,
              pageBuilder: (context, state) =>
                  _slidePage(key: state.pageKey, child: const SettingsPage()),
            ),
            GoRoute(
              path: AppRoutes.download,
              pageBuilder: (context, state) =>
                  _slidePage(key: state.pageKey, child: const DownloadPage()),
            ),
            GoRoute(
              path: AppRoutes.pluginManagement,
              pageBuilder: (context, state) => CustomTransitionPage(
                key: state.pageKey,
                child: const PluginManagementPage(),
                transitionDuration: const Duration(milliseconds: 220),
                reverseTransitionDuration: const Duration(milliseconds: 180),
                transitionsBuilder: _slideTransition,
              ),
            ),
            GoRoute(
              path: AppRoutes.recentlyPlayed,
              pageBuilder: (context, state) => CustomTransitionPage(
                key: state.pageKey,
                child: const RecentlyPlayedPage(),
                transitionDuration: const Duration(milliseconds: 220),
                reverseTransitionDuration: const Duration(milliseconds: 180),
                transitionsBuilder: _slideTransition,
              ),
            ),
            GoRoute(
              path: AppRoutes.recognize,
              // 听歌识曲依赖移动端 WebView，桌面端不提供该功能。
              redirect: (context, state) =>
                  Platform.isWindows || Platform.isLinux || Platform.isMacOS
                  ? AppRoutes.mine
                  : null,
              pageBuilder: (context, state) => CustomTransitionPage(
                key: state.pageKey,
                child: const RecognizePage(),
                transitionDuration: const Duration(milliseconds: 220),
                reverseTransitionDuration: const Duration(milliseconds: 180),
                transitionsBuilder: _slideTransition,
              ),
            ),
          ],
        ),
      ],
    ),

    // ── 全局二级页面（覆盖整个内容区，不属于任何分类） ──────────
    GoRoute(
      path: AppRoutes.tagEditor,
      pageBuilder: (context, state) {
        final songId = state.uri.queryParameters['songId'];
        // 快速匹配页的「匹配」按钮：进来直接切到在线搜索并自动搜一次。
        final autoSearch = state.uri.queryParameters['autoSearch'] == '1';
        return CustomTransitionPage(
          key: state.pageKey,
          child: TagEditorPage(songId: songId, autoSearch: autoSearch),
          transitionDuration: const Duration(milliseconds: 220),
          reverseTransitionDuration: const Duration(milliseconds: 180),
          transitionsBuilder: _slideTransition,
        );
      },
    ),
    GoRoute(
      path: AppRoutes.quickMatch,
      pageBuilder: (context, state) => CustomTransitionPage(
        key: state.pageKey,
        child: const QuickMatchPage(),
        transitionDuration: const Duration(milliseconds: 220),
        reverseTransitionDuration: const Duration(milliseconds: 180),
        transitionsBuilder: _slideTransition,
      ),
    ),
    GoRoute(
      path: AppRoutes.fullPlayer,
      // 播放详情页用 NoTransitionPage：打开 / 关闭都不做渐变。
      //
      // 这一页是整个应用最重的页面（封面、模糊背景、歌词 PageView、进度条），
      // 200ms 的 FadeTransition 要把它整页合成一层再做透明度动画，低端机上是
      // 明显的一顿；而淡入淡出本身不携带任何信息，去掉后点击封面/迷你播放器
      // 是「立刻」出现，体感反而更快。
      pageBuilder: (context, state) =>
          NoTransitionPage(key: state.pageKey, child: const FullPlayerPage()),
    ),
    GoRoute(
      path: AppRoutes.lyric,
      // 歌词页与播放详情页同属「整页播放界面」，同样用 NoTransitionPage：
      // 它从封面点进来，240ms 的上滑会把这个重页面（整屏歌词 + 逐行动画）
      // 边滑边合成，掉帧最明显。
      pageBuilder: (context, state) =>
          NoTransitionPage(key: state.pageKey, child: const LyricPage()),
    ),
  ],
);
