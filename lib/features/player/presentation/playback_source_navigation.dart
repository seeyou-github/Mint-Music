import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/app_routes.dart';
import '../../../core/router/app_router.dart';
import '../../../core/router/navigation_shell_provider.dart';
import '../../discover/application/search_providers.dart';
import '../../discover/domain/models/search_collection.dart';
import '../../library/application/playlist_providers.dart';
import '../../library/domain/models/recently_played.dart';
import '../application/root_overlay_tracker.dart';
import '../domain/models/song.dart';

/// 播放来源页是否可打开：歌单（含我的收藏）/ 榜单 / 专辑 / 作者。
bool canOpenPlaybackSource(PlaybackSourceType type) => switch (type) {
  PlaybackSourceType.playlist ||
  PlaybackSourceType.rank ||
  PlaybackSourceType.album ||
  PlaybackSourceType.artist => true,
  _ => false,
};

/// 打开当前歌曲的来源页：歌单（含「我的收藏」）/ 榜单 / 专辑 / 作者。
///
/// [container] 用于读取本地歌单与导航壳；调用方的弹层 / 页面即使马上被
/// 关闭也不影响这里继续跳转。
///
/// * 同一个来源页已经打开时，再次点击关闭它（而不是重复推入一份）；
/// * 播放详情页 / 歌词页盖在内容区上时，先关掉它再跳转，避免右侧只剩背景色。
Future<void> openPlaybackSource(
  ProviderContainer container, {
  required PlaybackSourceType type,
  required String? id,
  String? name,
  Map<String, dynamic>? sourceMeta,
  required Song song,
  bool toggle = true,
}) async {
  if (id == null || id.isEmpty) return;
  final encodedId = Uri.encodeComponent(id);

  String target;
  Object? extra;
  switch (type) {
    case PlaybackSourceType.playlist:
      // 本地歌单（含「我的收藏」）和远端歌单是不同的路由。
      var local = false;
      try {
        final playlists = await container.read(playlistsProvider.future);
        local = playlists.any((p) => p.id == id);
      } catch (_) {
        // 本地歌单读取失败就按远端歌单打开。
      }
      target = local ? '/library/playlist/$encodedId' : '/playlist/$encodedId';
    case PlaybackSourceType.rank:
      target = '/playlist/$encodedId?type=rank';
    case PlaybackSourceType.album:
    case PlaybackSourceType.artist:
      final collectionType = type == PlaybackSourceType.artist
          ? CollectionType.artist
          : CollectionType.album;
      target =
          '${AppRoutes.collectionDetail}?type=${collectionType.id}'
          '&id=$encodedId';
      extra = _collectionOf(
        collectionType,
        song: song,
        id: id,
        name: name,
        meta: sourceMeta,
      );
    case PlaybackSourceType.search:
    case PlaybackSourceType.local:
    case PlaybackSourceType.radio:
    case PlaybackSourceType.unknown:
      return;
  }

  // 播放详情页 / 歌词页这类根级页面盖在内容区上时，先把它关掉。否则在
  // 根级页面上推入分类页面 / 切换分类，右侧只会剩下一片背景色。
  // （关没关掉以登记表为准：路由配置对根级路由的压栈反映不可靠。）
  if (_closeRootOverlays()) {
    // 关掉播放页后等这一帧走完，路由栈回到下面的页面再决定怎么打开。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigateToSource(container, target, extra, toggle: false);
    });
    return;
  }
  _navigateToSource(container, target, extra, toggle: toggle);
}

/// 用歌曲名 / 歌手名打开搜索页并自动搜索。
///
/// 搜索页进入时读取 [pendingSearchQueryProvider]；如果搜索页已经打开
/// （播放页盖在上面），搜索页会监听这个待搜索词直接重搜，不会重复压栈。
Future<void> openSearchForQuery(
  ProviderContainer container,
  String query,
) async {
  final trimmed = query.trim();
  if (trimmed.isEmpty) return;

  void start() {
    // 先安排待搜索词：新搜索页在 initState 里消费，已经打开的搜索页监听它。
    container.read(pendingSearchQueryProvider.notifier).state = trimmed;
    _navigateToSource(container, AppRoutes.search, null, toggle: false);
  }

  // 播放页盖在搜索页上时，先把播放页关掉，等它退场后再决定跳转 / 由当前
  // 搜索页接手，避免搜索页还以为自己被盖着。
  if (_closeRootOverlays()) {
    WidgetsBinding.instance.addPostFrameCallback((_) => start());
    return;
  }
  start();
}

/// 按当前页面决定：关闭同一个页面 / 切分类后推入 / 直接推入。
///
/// [retries] 用于等待根级覆盖页关闭动画走完——覆盖页还在栈顶时推入分支
/// 页面会得到空白的右侧内容区，所以最多再等几帧。
void _navigateToSource(
  ProviderContainer container,
  String target,
  Object? extra, {
  required bool toggle,
  int retries = 3,
}) {
  final currentUri = _currentPageUri();
  final targetUri = Uri.parse(target);

  // 根级覆盖页还没退干净（出栈动画期间登记表已清空、路由栈可能滞后），
  // 等几帧再试。
  if (RootOverlayTracker.instance.isCovered ||
      _isRootOverlay(currentUri.path)) {
    if (retries <= 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _navigateToSource(
        container,
        target,
        extra,
        toggle: toggle,
        retries: retries - 1,
      );
    });
    return;
  }

  // 相关页面已经打开：再次点击关闭它，而不是重复推入一份。
  if (_isSamePage(currentUri, targetUri)) {
    // 刚关掉播放页时露出来的就是这个页面，什么都不用做。
    if (!toggle) return;
    if (appRouter.canPop()) {
      appRouter.pop();
    } else {
      appRouter.go(_branchRoot(currentUri.path));
    }
    return;
  }

  // 目标页属于另一个一级分类：先切到那个分类再推入详情页，
  // 这样页面会落在正确的分支栈里，返回键也能正常回到列表。
  final targetBranch = _branchOf(targetUri.path);
  if (targetBranch != _branchOf(currentUri.path)) {
    final shell = container.read(navigationShellProvider);
    if (shell != null) {
      // 分支切换是异步解析的，等它生效后再推入详情页；如果那个分类
      // 停在这个页面上，就不用再推一份了。
      shell.goBranch(targetBranch);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final restored = _currentPageUri();
        if (_isSamePage(restored, targetUri)) return;
        appRouter.push(target, extra: extra);
      });
      return;
    }
    appRouter.go(target, extra: extra);
    return;
  }

  appRouter.push(target, extra: extra);
}

/// 关掉盖在内容区上的根级页面（播放详情 / 歌词 / 标签编辑），返回是否关过。
///
/// 这些页面在根 Navigator 上，压着整个导航壳；不关掉就推入分支页面，
/// go_router 会在根级页面上再叠一份壳，右侧内容区就空了。
///
/// 覆盖状态以 [RootOverlayTracker] 登记表为准（路由配置对根级路由的
/// 压栈反映不可靠）；pop 前先把登记摘掉——页面 dispose 要等出栈动画
/// 结束才触发，不先摘的话循环会一直认为还有覆盖页，把下面的页面也弹掉。
bool _closeRootOverlays() {
  var closed = false;
  while (RootOverlayTracker.instance.isCovered && appRouter.canPop()) {
    RootOverlayTracker.instance.willPopTop();
    try {
      appRouter.pop();
    } on GoError {
      break;
    }
    closed = true;
  }
  return closed;
}

/// 覆盖整个内容区的根级页面。
bool _isRootOverlay(String path) =>
    path == AppRoutes.fullPlayer ||
    path == AppRoutes.lyric ||
    path == AppRoutes.tagEditor;

/// 是否就是同一个来源页。
///
/// 歌单 / 榜单共用 `/playlist/:id`，id 在路径里；专辑 / 作者共用
/// `/collection`，id 与类型都在查询参数里，必须一起比对。路径按解码后
/// 的形式比较（非 ASCII id 的百分号编码在不同入口可能写法不一）。
bool _isSamePage(Uri current, Uri target) {
  String decode(String path) {
    try {
      return Uri.decodeComponent(path);
    } catch (_) {
      return path;
    }
  }

  if (decode(current.path) != decode(target.path)) return false;
  final currentId = current.queryParameters['id'];
  final targetId = target.queryParameters['id'];
  if (currentId != targetId) return false;
  final currentType = current.queryParameters['type'];
  final targetType = target.queryParameters['type'];
  if (currentId != null && currentType != null && targetType != null) {
    return currentType == targetType;
  }
  return true;
}

/// 页面所属的一级分类（与底部导航 / 左侧导航的分支顺序一致）：
/// 0 发现，1 收藏（歌单），2 本地，3 我的。
int _branchOf(String path) {
  if (path == AppRoutes.library || path.startsWith('${AppRoutes.library}/')) {
    return 1;
  }
  if (path == AppRoutes.local) return 2;
  if (path == AppRoutes.mine ||
      path == AppRoutes.settings ||
      path == AppRoutes.download ||
      path == AppRoutes.pluginManagement ||
      path == AppRoutes.recentlyPlayed ||
      path == AppRoutes.recognize) {
    return 3;
  }
  // /discover、/playlist/:id、/collection、/search 都在「发现」分类下。
  return 0;
}

/// 分类的第一级页面：页面栈里没有上一层可返回时用它兜底。
String _branchRoot(String path) => switch (_branchOf(path)) {
  1 => AppRoutes.library,
  2 => AppRoutes.local,
  3 => AppRoutes.mine,
  _ => AppRoutes.discover,
};

/// 当前路由栈「真正显示的页面」位置（含 push 出来的页面）。
///
/// 不能用 `routerDelegate.currentConfiguration.uri`：go_router 的
/// RouteMatchList.uri **只反映 go()/goBranch() 级别的位置，不含任何
/// push() 推入的页面**（它们是 ImperativeRouteMatch，见 go_router 源码
/// 注释 "only reflects RouteMatchs that are not ImperativeRouteMatch"）。
/// 用它判断「来源页是否已打开」永远比不出相等，表现为点标签每次都
/// 重复推入同一页。这里遍历匹配栈取栈顶：ImperativeRouteMatch.matches.uri
/// 才是 push 页面的真实位置（带查询参数）。
Uri _currentPageUri() {
  final stack = <Uri>[];
  void walk(Iterable<RouteMatchBase> matches) {
    for (final match in matches) {
      if (match is ShellRouteMatch) {
        walk(match.matches);
      } else if (match is ImperativeRouteMatch) {
        stack.add(match.matches.uri);
        walk(match.matches.matches);
      } else if (match is RouteMatch) {
        stack.add(Uri.parse(match.matchedLocation));
      }
    }
  }

  walk(appRouter.routerDelegate.currentConfiguration.matches);
  if (stack.isEmpty) {
    return appRouter.routerDelegate.currentConfiguration.uri;
  }
  return stack.last;
}

/// 打开专辑 / 作者主页用的信息。
///
/// 播放时记录里有完整主页信息（[sourceMeta]）就直接用；
/// 没有时按歌曲字段拼一个。
SearchCollection _collectionOf(
  CollectionType type, {
  required Song song,
  required String id,
  required String? name,
  required Map<String, dynamic>? meta,
}) {
  if (meta != null) return SearchCollection.fromJson(meta, type: type);

  final isArtist = type == CollectionType.artist;
  final title = name ?? (isArtist ? song.artist : song.album);
  return SearchCollection(
    id: id,
    title: title,
    type: type,
    source: song.source ?? '',
    coverUrl: song.coverUrl,
    artist: isArtist ? null : song.artist,
    raw: {
      'id': id,
      'name': title,
      if (isArtist) 'avatar': song.coverUrl ?? '',
      if (!isArtist) 'artist': song.artist,
      if (!isArtist) 'picUrl': song.coverUrl ?? '',
    },
  );
}
