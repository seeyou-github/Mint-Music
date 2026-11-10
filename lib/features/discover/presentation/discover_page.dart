import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
// ScrollDirection 定义在 rendering.dart，material.dart 没有把它一起导出。
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/app_surface.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../core/utils/responsive_layout.dart';
import '../../../shared/widgets/cover_badge.dart';
import '../../radio/presentation/radio_panel.dart';
import '../../../shared/pagination/grid_page_rows.dart';
import '../../../shared/pagination/page_slicer.dart';
import '../../../shared/widgets/music_cover_image.dart';
import '../../../shared/widgets/page_bar.dart';
import '../../../shared/widgets/load_more_footer.dart';
import '../../../shared/widgets/source_icon.dart';
import '../../../shared/widgets/song_index_width.dart';
import '../application/discover_providers.dart';
import '../application/hot_board_providers.dart';
import '../domain/models/hot_board.dart';
import '../domain/models/playlist.dart';
import '../domain/models/leaderboard.dart';
import '../../custom_sheet/application/custom_sheet_providers.dart';
import '../../custom_sheet/presentation/custom_sheet_edit_page.dart';
import '../../library/application/playlist_providers.dart';
import '../../library/domain/models/playlist.dart' as local;
import '../../library/domain/models/recently_played.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/song.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';

class DiscoverPage extends ConsumerStatefulWidget {
  const DiscoverPage({super.key});

  @override
  ConsumerState<DiscoverPage> createState() => _DiscoverPageState();
}

/// 分类标签栏的滚动行为：桌面端允许用鼠标拖动横向列表。
///
/// Material 默认的 [MaterialScrollBehavior] 只接受触摸 / 触控笔拖动，
/// 桌面端鼠标无法拖动，这里把鼠标与触摸板也加进来。
class _CategoryScrollBehavior extends MaterialScrollBehavior {
  const _CategoryScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => const {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.invertedStylus,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.unknown,
  };
}

/// 榜单分类：热榜（自定义展示的榜单 TOP 10）/ 所有（音源榜单列表）。
enum _LeaderboardCategory { hot, all }

class _DiscoverPageState extends ConsumerState<DiscoverPage>
    with TickerProviderStateMixin {
  final ScrollController _scrollController = ScrollController();
  final GlobalKey _sourceButtonKey = GlobalKey();
  bool _hasInitialized = false;

  /// 榜单分类。
  ///
  /// 每次进入榜单页都会重新决定默认值：当前音源有热榜（看标志位）就选「热榜」，
  /// 没有（还没添加过）就直接选「所有」。
  _LeaderboardCategory _leaderboardCategory = _LeaderboardCategory.hot;

  /// 用户手动点过榜单分类：之后不再用「默认值」覆盖他的选择。
  bool _leaderboardCategoryPicked = false;

  /// 首帧就停在「榜单」页时，默认分类只算一次。
  bool _leaderboardDefaultApplied = false;

  /// 「所有」榜单里的分组过滤（null = 全部）。切音源后分组消失时自动视为全部。
  String? _selectedLeaderboardGroup;

  /// 正在挑选 / 获取热榜数据。
  bool _addingHotBoard = false;

  /// 正在拉取完整榜单并收藏的热榜（按榜单 id）。
  final Set<String> _favoritingHotBoards = {};

  /// 自定义歌单在分类栏里的 tag id：「全部自定义歌单」与「某个分类」。
  static const String _customAllTagId = 'custom_all';
  static const String _customCategoryPrefix = 'custom_cat:';

  static bool _isCustomTag(String tagId) =>
      tagId == _customAllTagId || tagId.startsWith(_customCategoryPrefix);

  static String _customCategoryTag(String categoryId) =>
      '$_customCategoryPrefix$categoryId';

  /// 歌单 / 榜单列表分页：每页多少行 × 每行多少列 就是每页条数。
  /// 行数按平台取（Android 30 行、桌面 10 行，见 [gridPageRows]）。
  static int get _playlistPageRows => gridPageRows;
  final PageSlicer _playlistPager = PageSlicer(pageSize: _playlistPageRows);
  final PageSlicer _leaderboardPager = PageSlicer(pageSize: _playlistPageRows);
  final ScrollController _leaderboardScrollController = ScrollController();

  /// 正在为某一页补数据。
  bool _pagingLoading = false;
  int _pagingGeneration = 0;

  /// 顶部分类顺序（左右滑动切换用，滑动循环绕回）。
  static const List<DiscoverTab> _tabOrder = [
    DiscoverTab.playlists,
    DiscoverTab.leaderboards,
    DiscoverTab.radio,
  ];

  /// 本次横向滑动累计的手指位移（用来判断是否达到翻页门槛）。
  double _tabSwipeDx = 0;

  /// 手指位移达到这么多屏宽就算一次翻页（剩下的靠甩动速度判断）。
  static const double _kTabSwitchDragRatio = 0.18;

  /// 分类内容当前的横向位移（像素）。
  ///
  /// 拖动时直接跟着手指走，松手后由 [_animateTabOffset] 动画收尾（回弹，
  /// 或顺着方向滑出去）。用一层 `Transform` 平移整块内容，只是 GPU 变换，
  /// 不会重建三个分类各自的列表子树。
  final ValueNotifier<double> _tabOffsetX = ValueNotifier<double>(0);

  /// 拖动过程中显示在「下一屏」的分类；null 表示没有拖动（或已到边界）。
  ///
  /// 与 [_tabOffsetX] 配合：当前页从 0 平移到 ±整屏时，下一屏从另一侧同步
  /// 平移进来，滑动过程中就能看到对面的内容（与 `PageView` 一致），
  /// 而不是「当前页滑走、新页再从边上飞入」。
  DiscoverTab? _dragTargetTab;

  /// 拖动方向：+1 = 左滑（下一个分类，下一屏在右侧）、-1 = 右滑。
  int _dragDir = 0;

  /// 本次切换由滑动触发：位移已经自己走完，`discoverTabProvider` 的监听里
  /// 不要再做「新分类从侧边 28% 进场」，否则会闪一下。
  bool _swipeTransition = false;

  /// 分类内容横向位移的动画驱动（时长每次按需设置）。
  late final AnimationController _tabAnim = AnimationController(vsync: this);

  /// 当前正在跑的位移动画；为 null 表示没有动画在跑。
  ///
  /// 只给控制器挂一个监听（[_onTabTick]），每次动画换掉这个 tween：
  /// 中途被打断时旧 tween 直接置空，不会再有残留的监听往 [_tabOffsetX] 写值。
  Animation<double>? _tabTween;

  /// Android：分类栏（歌单的标签行 / 榜单的「热榜·所有·分组」行）随列表
  /// 滚动收起、回来时展开。1 = 显示、0 = 隐藏。
  ///
  /// [SizeTransition] 负责把高度收掉让列表顶上来，[SlideTransition] 同时做
  /// 上下平移，两者共用同一个进度，视觉上就是分类栏「向上滑出去 / 向下滑回来」。
  late final AnimationController _categoryBarAnim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    value: 1,
  );
  late final Animation<double> _categoryBarProgress = CurvedAnimation(
    parent: _categoryBarAnim,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeOutCubic,
  );
  late final Animation<Offset> _categoryBarSlide = Tween<Offset>(
    begin: const Offset(0, -1),
    end: Offset.zero,
  ).animate(_categoryBarProgress);

  /// 记录显隐状态，避免每一帧滚动通知都重复调用 forward / reverse。
  bool _categoryBarVisible = true;

  /// 把分类栏包成「可随垂直滚动收起 / 展开」的一层（仅 Android）。
  Widget _collapsibleCategoryBar(Widget child) {
    if (!Platform.isAndroid) return child;
    return SizeTransition(
      sizeFactor: _categoryBarProgress,
      axisAlignment: -1,
      child: SlideTransition(position: _categoryBarSlide, child: child),
    );
  }

  /// 垂直滚动方向决定分类栏显隐：
  /// - 上滑看更多内容（[ScrollDirection.reverse]）→ 收起；
  /// - 下滑回看上方（[ScrollDirection.forward]）→ 展开。
  ///
  /// 横向标签栏自己的滑动、以及停止滚动时的 [ScrollDirection.idle] 都忽略，
  /// 否则一停手分类栏就会自己弹回来。电台页没有这一层分类栏，也不处理。
  void _onCategoryScroll(UserScrollNotification notification) {
    if (!Platform.isAndroid) return;
    // 拖动切换分类时两页都在屏幕上，滚动通知可能来自下一屏，先不响应。
    if (_dragTargetTab != null) return;
    if (notification.metrics.axis != Axis.vertical) return;
    if (notification.direction == ScrollDirection.idle) return;
    if (ref.read(discoverTabProvider) == DiscoverTab.radio) return;
    final visible = notification.direction == ScrollDirection.forward;
    if (visible == _categoryBarVisible) return;
    _categoryBarVisible = visible;
    if (visible) {
      _categoryBarAnim.forward();
    } else {
      _categoryBarAnim.reverse();
    }
  }

  void _onTabTick() {
    final animation = _tabTween;
    if (animation != null) _tabOffsetX.value = animation.value;
  }

  /// 把内容位移动画到 [to]（像素）。
  Future<void> _animateTabOffset(double to, int milliseconds) {
    final from = _tabOffsetX.value;
    _tabAnim.stop();
    if (from == to) {
      _tabTween = null;
      return Future<void>.value();
    }
    _tabAnim.duration = Duration(milliseconds: milliseconds);
    _tabTween = Tween<double>(
      begin: from,
      end: to,
    ).animate(CurvedAnimation(parent: _tabAnim, curve: Curves.easeOutCubic));
    return _tabAnim.forward(from: 0).then((_) {
      _tabTween = null;
      _tabOffsetX.value = to;
    });
  }

  /// 手指位移 → 内容位移（1:1 跟手，最多一屏）。
  ///
  /// 必须与手指严格同步：下一屏是按「当前位移 ± 整屏宽」算位置的，这里一旦
  /// 做加速，两页之间就会露出缝或叠在一起。
  double _tabContentOffset(double dx) {
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return dx;
    return dx.clamp(-width, width).toDouble();
  }

  @override
  void initState() {
    super.initState();
    _tabAnim.addListener(_onTabTick);
    _requestNotificationPermission();
  }

  @override
  void dispose() {
    _tabAnim.dispose();
    _categoryBarAnim.dispose();
    _tabOffsetX.dispose();
    _scrollController.dispose();
    _leaderboardScrollController.dispose();
    super.dispose();
  }

  /// 切到第 [page] 页；离缓冲区远的页只取该页，不把中间页逐页拉一遍。
  Future<void> _goToPlaylistPage(int page) async {
    if (page < 1 || _pagingLoading) return;
    final previousPage = _playlistPager.page;
    setState(() => _playlistPager.jumpTo(page));
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
    final loaded = ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
    if (_beyondPlaylistBuffer(page, loaded)) {
      await _jumpToPlaylistPageDirect(page, fallbackPage: previousPage);
    } else {
      await _ensurePlaylistPage();
    }
  }

  /// 目标页是否超出「缓冲区 + 下一页」的连续范围。
  ///
  /// 超出（或往回翻出缓冲区）时走跳页直达——只取目标页，不把中间页
  /// 逐页拉一遍；范围内仍走追加补齐，缓冲可以继续复用。
  bool _beyondPlaylistBuffer(int page, int loaded) {
    final contiguousEnd =
        _playlistPager.bufferBase -
        1 +
        (loaded / _playlistPager.pageSize).ceil();
    return page < _playlistPager.bufferBase || page > contiguousEnd + 1;
  }

  /// 跳页直达：只请求目标页并替换缓冲；失败时退回原页码并提示。
  Future<void> _jumpToPlaylistPageDirect(
    int page, {
    required int fallbackPage,
  }) async {
    final generation = _pagingGeneration;
    setState(() => _pagingLoading = true);
    int? effectivePage;
    try {
      effectivePage = await ref
          .read(categoryPlaylistsProvider.notifier)
          .goToPage(
            page: page,
            pageSize: _playlistPager.pageSize,
            sortId: 'hot',
            tagId: ref.read(activeTagIdProvider),
            sourceId: ref.read(discoverSourceIdProvider),
          );
    } catch (_) {
      effectivePage = null;
    } finally {
      if (mounted && generation == _pagingGeneration) {
        setState(() {
          _pagingLoading = false;
          if (effectivePage != null) {
            _playlistPager.rebase(effectivePage);
          } else {
            _playlistPager.jumpTo(fallbackPage);
          }
        });
      }
    }
    if (effectivePage == null && mounted && generation == _pagingGeneration) {
      _showMessage(context.tr('加载第 $page 页失败'));
    }
  }

  /// 补当前页数据：接口一次给的比一页少时继续取，多给的留着下次用。
  Future<void> _ensurePlaylistPage() async {
    if (_pagingLoading) return;
    final generation = _pagingGeneration;
    setState(() => _pagingLoading = true);
    final notifier = ref.read(categoryPlaylistsProvider.notifier);
    try {
      while (mounted && generation == _pagingGeneration) {
        final loaded =
            ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
        if (_playlistPager.missing(loaded, hasMore: !notifier.noMore) == 0) {
          break;
        }
        if (notifier.loadingMore || notifier.loadMoreError != null) break;
        final before = loaded;
        await notifier.fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: ref.read(discoverSourceIdProvider),
        );
        if (!mounted) return;
        final after =
            ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
        if (after == before) break;
      }
    } finally {
      if (mounted && generation == _pagingGeneration) {
        final loaded =
            ref.read(categoryPlaylistsProvider).valueOrNull?.length ?? 0;
        setState(() {
          _pagingLoading = false;
          _playlistPager.clampTo(
            loaded,
            hasMore: !notifier.noMore,
            total: notifier.total,
          );
        });
      }
    }
  }

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.notification.request();
      if (!status.isGranted && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(context.tr('请开启通知权限以使用后台播放功能')),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final tab = ref.watch(discoverTabProvider);

    // 分类切换（左右滑或点顶部标签）都做一次侧向滑入。按 _tabOrder 的
    // 距离判断方向：走一格是「下一个」→ 从右侧进场；往回一格 → 从左侧；
    // 循环绕回（电台 → 歌单）也算下一个，方向跟手势一致。
    ref.listen<DiscoverTab>(discoverTabProvider, (previous, next) {
      if (previous == null || previous == next) return;
      // 换分类时分类栏回到展开状态，不要沿用上一页滚动后收起的状态。
      if (Platform.isAndroid) {
        _categoryBarVisible = true;
        _categoryBarAnim.forward();
      }
      final from = _tabOrder.indexOf(previous);
      final to = _tabOrder.indexOf(next);
      if (from < 0 || to < 0) return;
      final forward = (to - from + _tabOrder.length) % _tabOrder.length == 1;
      if (!Platform.isAndroid) return;
      // 滑动切换时两页已经一起平移到位，这里再插一次「从侧边进场」会闪一下。
      if (_swipeTransition) return;
      // 点标签切换：新分类从切换方向的另一侧 28% 处滑入。
      final width = MediaQuery.sizeOf(context).width;
      _tabOffsetX.value = forward ? width * 0.28 : -width * 0.28;
      unawaited(_animateTabOffset(0, 200));
    });

    ref.listen<String>(defaultSourceIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        ref.read(discoverSourceIdProvider.notifier).state = next;
      }
    });

    // 每次进入「榜单」都重新决定默认分类：当前音源有热榜选「热榜」，没有选「所有」。
    ref.listen<DiscoverTab>(discoverTabProvider, (previous, next) {
      if (next == DiscoverTab.leaderboards &&
          previous != DiscoverTab.leaderboards) {
        _leaderboardCategoryPicked = false;
        _selectedLeaderboardGroup = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _applyLeaderboardDefault();
          _refreshHotBoardsIfHot();
        });
      }
    });

    // 首帧就停在「榜单」（比如从其它页面进来后重建）时，上面的 listen 不会触发，
    // 这里补一次默认分类判断。
    if (!_leaderboardDefaultApplied) {
      _leaderboardDefaultApplied = true;
      if (tab == DiscoverTab.leaderboards) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _applyLeaderboardDefault();
          _refreshHotBoardsIfHot();
        });
      }
    }

    // 热榜标志位变化（首次读到 / 新增 / 删除 / 换音源）时决定分类：
    // 当前音源有热榜选「热榜」，没有选「所有」。用户手动点过分类就不动。
    //
    // 这里看的是「有热榜的音源」标志位，而不是当前音源的热榜数据：标志位只含
    // 音源 id、可同步读，切音源的瞬间就有准确结果，不用等（也不用解析）整份
    // 热榜数据。数据监听在切音源时读到的可能还是上一个音源的空列表，
    // 会先把分类误判成「所有」。
    ref.listen<Set<String>>(hotBoardSourceIdsProvider, (previous, next) {
      if (ref.read(discoverTabProvider) != DiscoverTab.leaderboards) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _applyLeaderboardDefault();
      });
    });

    // 监听源切换，自动重新加载歌单
    ref.listen<String>(discoverSourceIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        _leaderboardPager.reset();
        // 换了音源：分类 / 分组都不记住，按新音源重新决定默认分类
        // （标志位里有这个音源就选「热榜」，没有选「所有」）。
        _leaderboardCategoryPicked = false;
        _selectedLeaderboardGroup = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _applyLeaderboardDefault();
          _refreshHotBoardsIfHot();
        });
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_reloadAfterSourceChange(next));
        });
      }
    });

    // 初始化歌单
    if (!_hasInitialized) {
      _hasInitialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _loadPlaylists();
        }
      });
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _buildHeader(context, colors),
            // Android：顶栏与分类栏之间的空白减半（顶栏自身的下内边距在
            // [_buildHeader] 里同步减半，两处加起来正好是原来的 50%）。
            // 歌单 / 榜单 / 电台三个分类共用这一层，所以同时生效。
            SizedBox(
              height: Platform.isAndroid ? AppSpacing.sm / 2 : AppSpacing.sm,
            ),
            Expanded(
              child: GestureDetector(
                // Android：左右滑动切换顶部分类（循环）。横向滚动的内容
                // （分类标签行等）是更深的手势识别器，会自己赢下手势，不受影响。
                behavior: HitTestBehavior.translucent,
                onHorizontalDragStart: Platform.isAndroid
                    ? _onTabSwipeStart
                    : null,
                onHorizontalDragUpdate: Platform.isAndroid
                    ? _onTabSwipeUpdate
                    : null,
                onHorizontalDragEnd: Platform.isAndroid ? _onTabSwipeEnd : null,
                child: ClipRect(
                  // 两页一起平移：当前页从 0 滑到 ±整屏时，下一屏从另一侧
                  // 同步滑进来，拖动过程中就能看到对面的内容（同 PageView）。
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 下一屏垫在下面，位置 = 当前位移 + 方向 × 整屏宽。
                      // 只包一层 Transform，拖动过程不重建列表子树。
                      if (_dragTargetTab != null && _dragTargetTab != tab)
                        AnimatedBuilder(
                          animation: _tabOffsetX,
                          builder: (context, child) => Transform.translate(
                            offset: Offset(
                              _tabOffsetX.value +
                                  _dragDir * MediaQuery.sizeOf(context).width,
                              0,
                            ),
                            child: child,
                          ),
                          child: _buildTabPage(
                            _dragTargetTab!,
                            colors,
                            primary: false,
                          ),
                        ),
                      AnimatedBuilder(
                        animation: _tabOffsetX,
                        builder: (context, child) => Transform.translate(
                          offset: Offset(_tabOffsetX.value, 0),
                          child: child,
                        ),
                        child: _buildTabPage(tab, colors, primary: true),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建某个分类的整页内容（含「垂直滚动 → 分类栏显隐」的监听）。
  ///
  /// [primary] 为当前分类：它用页面持有的滚动控制器（定位 / 回顶要用）；
  /// 拖动中露出的下一屏传 false，滚动视图自建 controller，两页才不会抢同一个。
  Widget _buildTabPage(
    DiscoverTab tab,
    ThemeColors colors, {
    required bool primary,
  }) {
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        _onCategoryScroll(notification);
        // 不消费通知：列表自身、分页条该收到的滚动事件照常。
        return false;
      },
      child: switch (tab) {
        DiscoverTab.playlists => _buildPlaylistsTab(
          colors,
          controller: primary ? _scrollController : null,
        ),
        DiscoverTab.leaderboards => _buildLeaderboardsTab(
          colors,
          controller: primary ? _leaderboardScrollController : null,
        ),
        DiscoverTab.radio => const RadioPanel(),
      },
    );
  }

  /// 加载歌单列表（带失败重试）。
  ///
  /// 插件音源（MusicFree 等）在插件系统加载完成前会返回空列表，表现为
  /// 「暂无歌单数据」。这里先等插件系统就绪再请求，若仍为空再补一次重试，
  /// 避免用户必须手动点「重试」才能看到内容。
  Future<void> _loadPlaylists() async {
    _pagingGeneration++;
    _pagingLoading = false;
    _playlistPager.reset();
    await _waitForPlugins();
    if (!mounted) return;

    // 插件自带「置顶分类」时优先选中它，而不是「热门」。
    await _applyDefaultTag();
    if (!mounted) return;

    await ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: ref.read(discoverSourceIdProvider),
          reset: true,
        );
    if (!mounted) return;

    final playlists = ref.read(categoryPlaylistsProvider).valueOrNull;
    if (playlists == null || playlists.isNotEmpty) return;

    // 空结果：再等一次插件加载并重试。
    await _waitForPlugins();
    if (!mounted) return;
    await ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: ref.read(discoverSourceIdProvider),
          reset: true,
        );
  }

  /// 等待插件系统初始化完成（最多等待 8 秒）。
  Future<void> _waitForPlugins() async {
    try {
      await ref
          .read(pluginInitializedProvider.future)
          .timeout(const Duration(seconds: 8));
    } catch (_) {}
  }

  void _onTabSwipeStart(DragStartDetails details) {
    _tabAnim.stop();
    _tabTween = null;
    _tabSwipeDx = 0;
    _tabOffsetX.value = 0;
  }

  void _onTabSwipeUpdate(DragUpdateDetails details) {
    _tabSwipeDx += details.delta.dx;
    final offset = _tabContentOffset(_tabSwipeDx);
    _tabOffsetX.value = offset;
    _syncDragTarget(offset);
  }

  /// 根据当前位移确定「下一屏」是哪个分类。
  ///
  /// 只在方向变化时 `setState` 一次：拖动过程中每帧都改状态会把整页列表
  /// 反复重建。
  void _syncDragTarget(double offset) {
    final dir = offset < 0 ? 1 : (offset > 0 ? -1 : 0);
    final current = ref.read(discoverTabProvider);
    final index = _tabOrder.indexOf(current);
    DiscoverTab? target;
    if (dir != 0 && index >= 0) {
      target = _tabOrder[(index + dir + _tabOrder.length) % _tabOrder.length];
      if (target == current) target = null;
    }
    if (target == _dragTargetTab && dir == _dragDir) return;
    setState(() {
      _dragTargetTab = target;
      _dragDir = dir;
    });
  }

  /// 左右滑动切换顶部分类（Android）。
  ///
  /// 方向跟手势走：手指往左滑 = 下一个分类、往右滑 = 上一个，两端循环
  /// （电台再往左回到歌单）。位移不够就靠甩动速度判断，避免轻轻一碰就切；
  /// 不够就弹回原位。
  void _onTabSwipeEnd(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    final dx = _tabSwipeDx;
    _tabSwipeDx = 0;
    final width = MediaQuery.sizeOf(context).width;
    final bool swipeLeft;
    if (dx.abs() >= width * _kTabSwitchDragRatio) {
      swipeLeft = dx < 0;
    } else if (velocity.abs() >= 260) {
      swipeLeft = velocity < 0;
    } else {
      unawaited(_settleTabDrag(null));
      return;
    }
    final current = ref.read(discoverTabProvider);
    final index = _tabOrder.indexOf(current);
    if (index < 0) {
      unawaited(_settleTabDrag(null));
      return;
    }
    final step = swipeLeft ? 1 : -1;
    final next =
        _tabOrder[(index + step + _tabOrder.length) % _tabOrder.length];
    unawaited(_settleTabDrag(next, step));
  }

  /// 收尾：两页一起滑到位后切换分类，或者回弹。
  ///
  /// 切换时「改分类」和「位移归零」在同一个同步块里完成（两者都只是
  /// markNeedsBuild，不会立即 build），build 时读到的已经是新分类 + 0，不闪。
  Future<void> _settleTabDrag(DiscoverTab? next, [int dir = 0]) async {
    final width = MediaQuery.sizeOf(context).width;
    if (next == null) {
      await _animateTabOffset(0, 200);
    } else {
      await _animateTabOffset(dir > 0 ? -width : width, 220);
      if (!mounted) return;
      // 滑动已经自己走完位移，监听里不要再做「从侧边 28% 进场」。
      _swipeTransition = true;
      ref.read(discoverTabProvider.notifier).state = next;
      _tabOffsetX.value = 0;
      _swipeTransition = false;
    }
    if (!mounted) return;
    if (_dragTargetTab != null || _dragDir != 0) {
      setState(() {
        _dragTargetTab = null;
        _dragDir = 0;
      });
    }
  }

  Widget _buildHeader(BuildContext context, ThemeColors colors) {
    final isTablet = ResponsiveLayout.isTablet(context);
    final tab = ref.watch(discoverTabProvider);
    final sourceId = ref.watch(discoverSourceIdProvider);
    final sources = ref.watch(discoverSupportedSourcesProvider);
    // 之前选中的音源如果已经不在可切换列表里（例如它是落雪格式插件提供的），
    // 退回列表第一个，避免主页一直停在空数据上。
    final currentSource =
        sources.where((s) => s.id == sourceId).firstOrNull ??
        (sources.isEmpty ? null : sources.first);
    if (currentSource != null && currentSource.id != sourceId) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(discoverSourceIdProvider) == currentSource.id) return;
        ref.read(discoverSourceIdProvider.notifier).state = currentSource.id;
      });
    }

    return Padding(
      padding: EdgeInsets.only(
        left: ResponsiveLayout.horizontalPadding(context),
        right: ResponsiveLayout.horizontalPadding(context),
        top: AppSpacing.md,
        // Android：顶栏下沿到分类栏的空白减半（顶部状态栏留白不动）；
        // 和 build 里同样减半的 SizedBox 加起来，整段间距正好是原来的 50%。
        bottom: Platform.isAndroid ? AppSpacing.md / 2 : AppSpacing.md,
      ),
      child: Row(
        children: [
          // 「歌单 / 榜单」切换（原「发现音乐」标题的位置）
          _buildTabChip(
            label: context.tr('歌单'),
            isActive: tab == DiscoverTab.playlists,
            colors: colors,
            onTap: () => ref.read(discoverTabProvider.notifier).state =
                DiscoverTab.playlists,
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildTabChip(
            label: context.tr('排行榜'),
            isActive: tab == DiscoverTab.leaderboards,
            colors: colors,
            onTap: () => ref.read(discoverTabProvider.notifier).state =
                DiscoverTab.leaderboards,
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildTabChip(
            label: context.tr('电台'),
            isActive: tab == DiscoverTab.radio,
            colors: colors,
            onTap: () => ref.read(discoverTabProvider.notifier).state =
                DiscoverTab.radio,
          ),
          // 搜索入口：
          // - Android：顶部横向空间紧，做成和音源按钮同尺寸的圆形图标；
          // - Windows / 桌面：空间富余，保留带占位文字的搜索框。
          if (Platform.isAndroid) ...[
            const Spacer(),
            GestureDetector(
              onTap: () => context.push('/search'),
              child: Container(
                width: _searchBarHeight,
                height: _searchBarHeight,
                decoration: floatingButtonDecoration(colors, circle: true),
                alignment: Alignment.center,
                // 放大镜比音源圆标小一圈（音源圆标是实心图案，铺满才不显空），
                // 38 的话放大镜会顶到圆边，显得又大又笨。
                child: Icon(
                  Icons.search,
                  size: _searchIconSize,
                  color: colors.textSecondary,
                ),
              ),
            ),
          ] else
            Expanded(
              child: Align(
                alignment: Alignment.centerRight,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: 140,
                    maxWidth: isTablet ? 420 : 300,
                  ),
                  child: _buildSearchBar(context, colors),
                ),
              ),
            ),
          const SizedBox(width: AppSpacing.sm),
          // 切换音源（插件）按钮：和搜索按钮同样的 40 圆底，但图标用
          // [_circleIconSize]（实心圆标要铺满才饱满，搜索的放大镜另算）。
          GestureDetector(
            key: _sourceButtonKey,
            onTap: () => _showSourceMenu(
              context,
              colors,
              sources,
              currentSource?.id ?? sourceId,
            ),
            child: Container(
              width: _searchBarHeight,
              height: _searchBarHeight,
              decoration: floatingButtonDecoration(colors, circle: true),
              alignment: Alignment.center,
              child: currentSource != null
                  ? ColorFiltered(
                      // 亮度压到 80%（降低 20%）：音源图标都是饱和实心色块，
                      // 顶栏上略压暗一点，不抢标题和搜索框的注意力。
                      colorFilter: const ColorFilter.matrix(<double>[
                        0.8, 0, 0, 0, 0, //
                        0, 0.8, 0, 0, 0, //
                        0, 0, 0.8, 0, 0, //
                        0, 0, 0, 1, 0, //
                      ]),
                      child: _buildSourceIcon(
                        // 变体 id 也一起传进去：插件自带图标时优先显示它。
                        currentSource.id,
                        size: _circleIconSize,
                        label: currentSource.name,
                      ),
                    )
                  : Icon(
                      Icons.music_note,
                      size: _circleIconSize,
                      color: colors.textSecondary,
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶部两个圆形按钮（搜索 / 切换音源）的直径，保持视觉高度一致。
  static const double _searchBarHeight = 40;

  /// 音源圆标的直径（红 / 绿实心图案）。
  ///
  /// 38 是相对 40 圆底留一圈极窄的边：既保留音源圆标原本饱满的观感，
  /// 又不让它顶到按钮边缘。搜索按钮里的放大镜不用这个值，见 [_searchIconSize]。
  static const double _circleIconSize = 38;

  /// Android 搜索按钮里放大镜的直径。
  ///
  /// 放大镜是细线条，铺满整个圆会显得又大又笨（之前的 38 就是这样），
  /// 比实心音源圆标小一圈才对得上。
  static const double _searchIconSize = 20;

  /// 搜索框（Windows / 桌面）：圆角胶囊 + 放大镜，点击进搜索页。
  ///
  /// Android 顶部横向空间不够摆它，那里用圆形图标按钮（见 [_buildHeader]）。
  Widget _buildSearchBar(BuildContext context, ThemeColors colors) {
    return GestureDetector(
      onTap: () => context.push('/search'),
      child: Container(
        height: _searchBarHeight,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        // 与顶栏按钮统一：底色 + 轻阴影，不画描边。
        decoration: floatingButtonDecoration(colors),
        child: Row(
          children: [Icon(Icons.search, size: 18, color: colors.textHint)],
        ),
      ),
    );
  }

  void _showSourceMenu(
    BuildContext context,
    ThemeColors colors,
    List<SourceInfo> sources,
    String currentSourceId,
  ) {
    final renderBox =
        _sourceButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        renderBox.localToGlobal(Offset.zero, ancestor: overlay),
        renderBox.localToGlobal(
          renderBox.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: colors.surface,
      elevation: 8,
      items: sources.map((source) {
        return PopupMenuItem<String>(
          value: source.id,
          height: 44,
          child: Row(
            children: [
              source.id != 'all'
                  ? _buildSourceIcon(
                      // 变体 id 也一起传进去：插件自带图标时优先显示它。
                      source.id,
                      size: 18,
                      label: source.name,
                    )
                  : _buildSourceIcon('all', size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  source.name,
                  style: TextStyle(
                    fontSize: 13,
                    color: source.id == currentSourceId
                        ? colors.primary
                        : colors.textPrimary,
                    fontWeight: source.id == currentSourceId
                        ? FontWeight.w500
                        : FontWeight.normal,
                  ),
                ),
              ),
              if (source.id == currentSourceId)
                Icon(Icons.check, size: 16, color: colors.primary),
            ],
          ),
        );
      }).toList(),
    ).then((selectedId) {
      if (selectedId != null && selectedId != currentSourceId) {
        ref.read(discoverSourceIdProvider.notifier).state = selectedId;
        // 用户最后切换的音源即成为默认音源。
        unawaited(
          persistDefaultSourceId(
            ProviderScope.containerOf(context),
            selectedId,
          ),
        );
        ref.read(activeTagIdProvider.notifier).state = '';
        ref.read(activeCategoryNameProvider.notifier).state = '热门';
        // 分类与歌单交给 discoverSourceIdProvider 的监听统一处理（会自动选中
        // 置顶分类）。这里不要再发一次请求：两次请求会互相覆盖，导致
        // 「推荐」分类里显示成「热门」的内容。
      }
    });
  }

  Widget _buildSourceIcon(String sourceId, {double size = 20, String? label}) {
    return SourceIcon(sourceId: sourceId, size: size, label: label);
  }

  Widget _buildTabChip({
    required String label,
    required bool isActive,
    required ThemeColors colors,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: isActive
            ? BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(AppRadius.full),
              )
            : floatingSurfaceDecoration(
                colors,
                radius: AppRadius.full,
                subtle: true,
              ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: isActive ? colors.textOnPrimary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildPlaylistsTab(
    ThemeColors colors, {
    ScrollController? controller,
  }) {
    final tagsAsync = ref.watch(playlistTagsProvider);
    final hotTagsAsync = ref.watch(hotPlaylistTagsProvider);
    final activeTagId = ref.watch(activeTagIdProvider);
    final activeCategoryName = ref.watch(activeCategoryNameProvider);
    final playlistsAsync = ref.watch(categoryPlaylistsProvider);
    final sourceId = ref.watch(discoverSourceIdProvider);
    final supportsCustomSheets = ref.watch(
      sourceSupportsCustomSheetsProvider(sourceId),
    );
    final customData = ref.watch(customSheetProvider);
    // 自定义分类：选「我的歌单」看全部，选某个分类只看该分类。
    final customSheets = activeTagId.startsWith(_customCategoryPrefix)
        ? customData.sheetsOfCategory(
            sourceId,
            activeTagId.substring(_customCategoryPrefix.length),
          )
        : customData.sheetsOfSource(sourceId);

    return Column(
      children: [
        // Android：随列表上滑收起、下滑展开（上下平移动画）。分类栏和它
        // 下方的间距一起收起，隐藏后顶部不会留一条空白。
        _collapsibleCategoryBar(
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.md),
            child: _buildCategoryBar(
              colors,
              tagsAsync,
              hotTagsAsync,
              activeTagId,
              activeCategoryName,
            ),
          ),
        ),
        Expanded(
          child: _isCustomTag(activeTagId)
              ? _buildCustomSheetGrid(
                  colors,
                  customSheets,
                  sourceId: sourceId,
                  controller: controller,
                )
              : playlistsAsync.when(
                  data: (playlists) {
                    if (playlists.isEmpty) {
                      // 支持自定义歌单的音源：直接显示自定义歌单（没有时给出新建入口），
                      // 不要显示「暂无歌单数据」。
                      if (supportsCustomSheets) {
                        return _buildCustomSheetGrid(
                          colors,
                          customSheets,
                          sourceId: sourceId,
                          controller: controller,
                        );
                      }
                      // 插件音源可能只提供搜索 / 播放地址，不提供歌单与榜单，
                      // 这时给出说明，避免用户以为是加载失败。
                      final hasDiscoverContent = ref
                          .read(musicSourceManagerProvider)
                          .sourceHasDiscoverContent(sourceId);
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.library_music_outlined,
                              size: 48,
                              color: colors.textHint,
                            ),
                            const SizedBox(height: AppSpacing.md),
                            Text(
                              hasDiscoverContent
                                  ? context.tr('暂无歌单数据')
                                  : context.tr('该音源不提供歌单和榜单'),
                              style: TextStyle(color: colors.textHint),
                            ),
                            if (hasDiscoverContent) ...[
                              const SizedBox(height: AppSpacing.md),
                              TextButton(
                                onPressed: () => _loadPlaylists(),
                                child: Text(context.tr('重试')),
                              ),
                            ],
                          ],
                        ),
                      );
                    }
                    return _buildPlaylistGrid(
                      colors,
                      playlists,
                      controller: controller,
                    );
                  },
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, __) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 48,
                          color: colors.textHint,
                        ),
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          context.tr('加载失败'),
                          style: TextStyle(color: colors.textHint),
                        ),
                        const SizedBox(height: AppSpacing.md),
                        TextButton(
                          onPressed: () => _loadPlaylists(),
                          child: Text(context.tr('重试')),
                        ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildCategoryBar(
    ThemeColors colors,
    AsyncValue<List<PlaylistTagGroup>> tagsAsync,
    AsyncValue<List<PlaylistTag>> hotTagsAsync,
    String activeTagId,
    String activeCategoryName,
  ) {
    final hotTags = hotTagsAsync.valueOrNull ?? const <PlaylistTag>[];
    final sourceId = ref.watch(discoverSourceIdProvider);
    final supportsCustomSheets = ref.watch(
      sourceSupportsCustomSheetsProvider(sourceId),
    );
    final customData = ref.watch(customSheetProvider);
    final customSheets = customData.sheetsOfSource(sourceId);
    // 置顶分类（插件可用 `__pinned__` 前缀标记）排在「热门」之前。
    final pinnedTags = hotTags
        .where((tag) => tag.isPinned)
        .toList(growable: false);
    final normalTags = hotTags
        .where((tag) => !tag.isPinned)
        .toList(growable: false);
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          // 分类标签：数量多时支持鼠标拖动 / 触摸左右滑动。
          Expanded(
            child: ScrollConfiguration(
              behavior: const _CategoryScrollBehavior(),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.only(left: AppSpacing.lg),
                children: [
                  for (final tag in pinnedTags)
                    Padding(
                      padding: const EdgeInsets.only(right: AppSpacing.sm),
                      child: _buildTagChip(
                        label: tag.name,
                        isActive: activeTagId == tag.id,
                        colors: colors,
                        onTap: () => _onSelectTag(tag.id, tag.name),
                      ),
                    ),
                  _buildTagChip(
                    label: context.tr('热门'),
                    isActive: activeTagId.isEmpty,
                    colors: colors,
                    onTap: () => _onSelectTag('', '热门'),
                  ),
                  // 自定义歌单：App 侧建歌单，内容用当前音源按关键字搜索。
                  if (supportsCustomSheets && customSheets.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: _buildTagChip(
                        label: context.tr('我的歌单'),
                        isActive: activeTagId == _customAllTagId,
                        colors: colors,
                        onTap: () =>
                            _onSelectTag(_customAllTagId, context.tr('我的歌单')),
                      ),
                    ),
                  if (supportsCustomSheets)
                    for (final category in customData.categories)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: _buildTagChip(
                          label: category.name,
                          isActive:
                              activeTagId == _customCategoryTag(category.id),
                          colors: colors,
                          onTap: () => _onSelectTag(
                            _customCategoryTag(category.id),
                            category.name,
                          ),
                        ),
                      ),
                  for (final tag in normalTags)
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: _buildTagChip(
                        label: tag.name,
                        isActive: activeTagId == tag.id,
                        colors: colors,
                        onTap: () => _onSelectTag(tag.id, tag.name),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 新增歌单（仅图标，仅支持自定义歌单的音源），放在「更多分类」左侧。
          if (supportsCustomSheets)
            Padding(
              padding: const EdgeInsets.only(left: AppSpacing.sm),
              child: _buildAddSheetButton(colors, sourceId),
            ),
          // 「更多分类」固定在最右侧，分类过多时也不会被挤出可视区域。
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.sm,
              right: AppSpacing.lg,
            ),
            child: _buildMoreCategoryButton(colors, tagsAsync, activeTagId),
          ),
        ],
      ),
    );
  }

  Widget _buildTagChip({
    required String label,
    required bool isActive,
    required ThemeColors colors,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive
              ? colors.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
            color: isActive ? colors.primary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildMoreCategoryButton(
    ThemeColors colors,
    AsyncValue<List<PlaylistTagGroup>> tagsAsync,
    String activeTagId,
  ) {
    return GestureDetector(
      onTap: () => _showCategoryBottomSheet(colors, tagsAsync, activeTagId),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: floatingSurfaceDecoration(colors, radius: 6, subtle: true),
        child: Text(
          context.tr('更多分类'),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w400,
            color: colors.textSecondary,
          ),
        ),
      ),
    );
  }

  /// 「新增歌单」按钮（仅图标）：只有支持自定义歌单的音源才显示。
  Widget _buildAddSheetButton(ThemeColors colors, String sourceId) {
    return Tooltip(
      message: context.tr('新增歌单'),
      child: GestureDetector(
        onTap: () => _openSheetEditor(sourceId: sourceId),
        child: Container(
          width: 26,
          height: 26,
          alignment: Alignment.center,
          decoration: floatingSurfaceDecoration(
            colors,
            radius: 6,
            subtle: true,
          ),
          child: Icon(Icons.add, size: 18, color: colors.textSecondary),
        ),
      ),
    );
  }

  /// 打开新增 / 编辑歌单页；保存后切到「我的歌单」让用户立刻看到结果。
  Future<void> _openSheetEditor({
    required String sourceId,
    CustomSheet? sheet,
    String categoryId = '',
  }) async {
    final name = ref
        .read(discoverSupportedSourcesProvider)
        .where((item) => item.id == sourceId)
        .map((item) => item.name)
        .firstOrNull;
    final saved = await showCustomSheetEditor(
      context,
      sourceId: sourceId,
      sourceName: name ?? '',
      sheet: sheet,
      categoryId: categoryId,
    );
    if (!mounted || saved != true) return;
    final current = ref.read(activeTagIdProvider);
    if (!_isCustomTag(current)) {
      _onSelectTag(_customAllTagId, context.tr('我的歌单'));
    }
  }

  /// 删除自定义歌单（带确认）。
  Future<void> _deleteSheet(CustomSheet sheet) async {
    final colors = ref.read(themeColorsProvider);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          context.tr('删除歌单'),
          style: TextStyle(fontSize: 17, color: colors.textPrimary),
        ),
        content: Text(
          context.tr('确定删除「${sheet.name}」？歌单内容会一起消失，音频文件不受影响。'),
          style: TextStyle(fontSize: 14, color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              context.tr('取消'),
              style: TextStyle(color: colors.textHint),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              context.tr('删除'),
              style: TextStyle(color: colors.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(customSheetProvider.notifier).removeSheet(sheet.id);
  }

  /// 自定义歌单卡片长按：编辑 / 删除。
  void _showSheetMenu(CustomSheet sheet) {
    final colors = ref.read(themeColorsProvider);
    showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.lg,
                AppSpacing.xs,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      sheet.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(Icons.edit_outlined, color: colors.textSecondary),
              title: Text(
                context.tr('编辑歌单'),
                style: TextStyle(fontSize: 14, color: colors.textPrimary),
              ),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(
                  _openSheetEditor(
                    sourceId: sheet.sourceId,
                    sheet: sheet,
                    categoryId: sheet.categoryId,
                  ),
                );
              },
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colors.error),
              title: Text(
                context.tr('删除歌单'),
                style: TextStyle(fontSize: 14, color: colors.error),
              ),
              onTap: () {
                Navigator.pop(ctx);
                unawaited(_deleteSheet(sheet));
              },
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }

  /// 自定义歌单网格（App 侧数据，不分页）。
  Widget _buildCustomSheetGrid(
    ThemeColors colors,
    List<CustomSheet> sheets, {
    String? sourceId,
    ScrollController? controller,
  }) {
    if (sheets.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.queue_music_outlined, size: 48, color: colors.textHint),
            const SizedBox(height: AppSpacing.md),
            Text(
              context.tr('还没有歌单，点右上角的 + 新建一个'),
              style: TextStyle(color: colors.textHint),
            ),
            const SizedBox(height: AppSpacing.md),
            if (sourceId != null)
              TextButton.icon(
                onPressed: () => _openSheetEditor(sourceId: sourceId),
                icon: const Icon(Icons.add, size: 18),
                label: Text(context.tr('新增歌单')),
              ),
          ],
        ),
      );
    }

    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);
    return CustomScrollView(
      controller: controller,
      // 下一屏预览没有 controller：不要继承外层 PrimaryScrollController，
      // 由 ScrollView 自建，否则两页会抢同一个。
      primary: controller == null ? false : null,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
            left: ResponsiveLayout.horizontalPadding(context),
            right: ResponsiveLayout.horizontalPadding(context),
            // 自定义歌单不分页，底部要让开悬浮的迷你播放器。
            bottom: AppSpacing.miniPlayerHeight + AppSpacing.xxl,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
              crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
              childAspectRatio: isTablet ? 0.88 : 0.82,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              return floatingCard(
                colors: colors,
                radius: AppRadius.lg,
                child: _buildCustomSheetCard(colors, sheets[index]),
              );
            }, childCount: sheets.length),
          ),
        ),
      ],
    );
  }

  Widget _buildCustomSheetCard(ThemeColors colors, CustomSheet sheet) {
    return GestureDetector(
      onTap: () => context.push('/playlist/${sheet.playlistId}'),
      onLongPress: () => _showSheetMenu(sheet),
      child: Container(
        decoration: floatingSurfaceDecoration(
          colors,
          radius: AppRadius.lg,
          withShadow: false,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _buildSheetCover(colors, sheet),
                  // 自定义歌单角标，和插件歌单区分开。
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.45),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        context.tr('自定义'),
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.xs,
                AppSpacing.sm,
                AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    sheet.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sheet.keyword,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetCover(ThemeColors colors, CustomSheet sheet) {
    final cover = sheet.displayCover.trim();
    Widget fallback() => Container(
      color: colors.surfaceVariant,
      child: Icon(Icons.queue_music, size: 32, color: colors.textHint),
    );
    if (cover.isEmpty) return fallback();
    if (cover.startsWith('http')) {
      return Image.network(
        cover,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback(),
      );
    }
    return Image.file(
      File(cover),
      fit: BoxFit.cover,
      errorBuilder: (_, _, _) => fallback(),
    );
  }

  /// 「更多分类」弹层：高度为窗口高度的 60%，分类按「语种 / 分类…」纵向平铺，
  /// 内容超出时可上下滚动，右侧显示滚动条。
  void _showCategoryBottomSheet(
    ThemeColors colors,
    AsyncValue<List<PlaylistTagGroup>> tagsAsync,
    String activeTagId,
  ) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.6;
    showModalBottomSheet(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (ctx) {
        return tagsAsync.when(
          data: (groups) {
            if (groups.isEmpty) {
              return SizedBox(
                height: sheetHeight,
                child: Center(child: Text(context.tr('暂无分类数据'))),
              );
            }
            return SizedBox(
              height: sheetHeight,
              child: _CategorySheetContent(
                groups: groups,
                activeTagId: activeTagId,
                colors: colors,
                onSelect: (tagId, name) {
                  _onSelectTag(tagId, name);
                  Navigator.pop(ctx);
                },
              ),
            );
          },
          loading: () => SizedBox(
            height: sheetHeight,
            child: const Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => SizedBox(
            height: sheetHeight,
            child: Center(child: Text(context.tr('加载分类失败'))),
          ),
        );
      },
    );
  }

  /// 切换音源后重新加载歌单。
  Future<void> _reloadAfterSourceChange(String sourceId) async {
    if (!mounted) return;
    _pagingGeneration++;
    _pagingLoading = false;
    _playlistPager.reset();
    ref.read(activeTagIdProvider.notifier).state = '';
    ref.read(activeCategoryNameProvider.notifier).state = '热门';
    // 插件自带「置顶分类」时优先选中它，而不是「热门」。
    await _applyDefaultTag();
    if (!mounted) return;
    ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: ref.read(activeTagIdProvider),
          sourceId: sourceId,
          reset: true,
        );
  }

  /// 选中默认分类。
  ///
  /// 插件可以在分类 id 上加 `__pinned__` 前缀声明「置顶分类」（例如网易云插件
  /// 的「推荐」歌单），这时优先选中它；没有置顶分类就保持「热门」。
  Future<void> _applyDefaultTag() async {
    // 切换音源后，分类 provider 的依赖变化是由 Riverpod 在微任务里失效的，
    // 直接读 future 可能拿到上一个音源的旧分类（于是置顶分类没被选中，
    // 列表显示成「热门」的内容）。这里先让出一次微任务再强制刷新，确保
    // 拿到的是当前音源的分类。
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    ref.invalidate(hotPlaylistTagsProvider);
    try {
      await ref.read(hotPlaylistTagsProvider.future);
    } catch (_) {}
    if (!mounted) return;
    final tags =
        ref.read(hotPlaylistTagsProvider).valueOrNull ?? const <PlaylistTag>[];
    final pinned = tags.where((tag) => tag.isPinned).toList();
    if (pinned.isEmpty) return;
    final tag = pinned.first;
    ref.read(activeTagIdProvider.notifier).state = tag.id;
    ref.read(activeCategoryNameProvider.notifier).state = tag.name;
  }

  void _onSelectTag(String tagId, String name) {
    _pagingGeneration++;
    _pagingLoading = false;
    _playlistPager.reset();
    ref.read(activeTagIdProvider.notifier).state = tagId;
    ref.read(activeCategoryNameProvider.notifier).state = name;
    // 自定义歌单是 App 侧数据，不需要向插件请求分类歌单。
    if (_isCustomTag(tagId)) return;
    final srcId = ref.read(discoverSourceIdProvider);
    ref
        .read(categoryPlaylistsProvider.notifier)
        .fetchPlaylists(
          sortId: 'hot',
          tagId: tagId,
          sourceId: srcId,
          reset: true,
        );
  }

  Widget _buildPlaylistGrid(
    ThemeColors colors,
    List<Playlist> playlists, {
    ScrollController? controller,
  }) {
    final notifier = ref.read(categoryPlaylistsProvider.notifier);
    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);

    // 每页 _playlistPageRows 行：每行 crossAxisCount 个，所以每页 行数 × 列数 个。
    _playlistPager.updatePageSize(_playlistPageRows * crossAxisCount);
    _playlistPager.clampTo(
      playlists.length,
      hasMore: !notifier.noMore,
      total: notifier.total,
    );
    final visible = _playlistPager.slice(playlists);
    final pageCount = _playlistPager.pageCount(
      playlists.length,
      hasMore: !notifier.noMore,
      total: notifier.total,
    );
    if (_playlistPager.missing(playlists.length, hasMore: !notifier.noMore) >
            0 &&
        !notifier.loadingMore &&
        notifier.loadMoreError == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_ensurePlaylistPage());
      });
    }

    return CustomScrollView(
      controller: controller,
      // 下一屏预览没有 controller：不要继承外层 PrimaryScrollController，
      // 由 ScrollView 自建，否则两页会抢同一个。
      primary: controller == null ? false : null,
      cacheExtent: 360,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
            left: ResponsiveLayout.horizontalPadding(context),
            right: ResponsiveLayout.horizontalPadding(context),
            top: 0,
            bottom: AppSpacing.md,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
              crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
              childAspectRatio: isTablet ? 0.88 : 0.82,
            ),
            delegate: SliverChildBuilderDelegate((context, index) {
              final playlist = visible[index];
              return RepaintBoundary(
                child: floatingCard(
                  colors: colors,
                  radius: AppRadius.lg,
                  child: _buildPlaylistCard(colors, playlist, index),
                ),
              );
            }, childCount: visible.length),
          ),
        ),
        // 分页条：内容不满一屏时贴到底部，满一屏时跟在网格后面。
        // 自身会避开迷你播放器。
        PageBarFooterSliver(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (notifier.loadingMore || _pagingLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: AppSpacing.xs),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              if (notifier.loadMoreError != null)
                LoadMoreFooter(
                  status: LoadMoreStatus.error,
                  colors: colors,
                  message: notifier.loadMoreError,
                  onRetry: () async {
                    await notifier.fetchPlaylists(
                      sortId: 'hot',
                      tagId: ref.read(activeTagIdProvider),
                      sourceId: ref.read(discoverSourceIdProvider),
                    );
                    if (mounted) await _ensurePlaylistPage();
                  },
                ),
              PageBar(
                currentPage: _playlistPager.page,
                pageCount: pageCount,
                loading: notifier.loadingMore || _pagingLoading,
                docked: true,
                // 没拿到总数、也还没翻到末尾：最后一页是猜的，不写成具体页码。
                lastPageKnown: notifier.noMore || notifier.total != null,
                onChanged: (page) => unawaited(_goToPlaylistPage(page)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistCard(ThemeColors colors, Playlist playlist, int index) {
    return GestureDetector(
      onTap: () {
        context.push('/playlist/${playlist.id}');
      },
      child: Container(
        decoration: floatingSurfaceDecoration(
          colors,
          radius: AppRadius.lg,
          withShadow: false,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          colors.primary.withValues(alpha: 0.3 + index * 0.05),
                          colors.surfaceVariant,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: MusicCoverImage(
                      url: playlist.coverUrl,
                      fit: BoxFit.cover,
                      cacheWidth: 400,
                      cacheHeight: 400,
                      filterQuality: FilterQuality.high,
                      errorWidget: Icon(
                        Icons.music_note,
                        size: 40,
                        color: colors.textHint,
                      ),
                    ),
                  ),
                  if (playlist.playCount != null &&
                      playlist.playCount!.isNotEmpty)
                    Positioned(
                      top: AppSpacing.xs,
                      right: AppSpacing.xs,
                      child: CoverCountBadge(
                        label: playlist.playCount!,
                        icon: Icons.play_arrow,
                        fontSize: 11,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        radius: AppRadius.xs,
                        background: Colors.black54,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    playlist.title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    context.tr('${playlist.songCount}首歌曲'),
                    style: TextStyle(fontSize: 11, color: colors.textSecondary),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeaderboardsTab(
    ThemeColors colors, {
    ScrollController? controller,
  }) {
    final isHot = _leaderboardCategory == _LeaderboardCategory.hot;
    // 榜单分类与「热榜 / 所有」合并成一行：「所有」是全部数据，
    // 右侧各分类直接过滤（分类来自插件给的 group，少于 2 组不显示）。
    final leaderboards =
        ref.watch(leaderboardsProvider).valueOrNull ?? const <Leaderboard>[];
    final groups = _leaderboardGroupsOf(leaderboards);
    final effectiveGroup = groups.contains(_selectedLeaderboardGroup)
        ? _selectedLeaderboardGroup
        : null;
    return Column(
      children: [
        // Android：随列表上滑收起、下滑展开（上下平移动画），与歌单页一致。
        _collapsibleCategoryBar(
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: SizedBox(
              height: 36,
              child: Row(
                children: [
                  // 分类标签：数量增多时支持鼠标拖动 / 触摸左右滑动。
                  Expanded(
                    child: ScrollConfiguration(
                      behavior: const _CategoryScrollBehavior(),
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.only(left: AppSpacing.lg),
                        children: [
                          _buildTagChip(
                            label: context.tr('热榜'),
                            isActive: isHot,
                            colors: colors,
                            onTap: () => _selectLeaderboardCategory(
                              _LeaderboardCategory.hot,
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: AppSpacing.sm),
                            child: _buildTagChip(
                              label: context.tr('所有'),
                              isActive: !isHot && effectiveGroup == null,
                              colors: colors,
                              onTap: () {
                                _leaderboardCategoryPicked = true;
                                setState(() {
                                  _leaderboardCategory =
                                      _LeaderboardCategory.all;
                                  _selectedLeaderboardGroup = null;
                                });
                              },
                            ),
                          ),
                          for (final group in groups)
                            Padding(
                              padding: const EdgeInsets.only(
                                left: AppSpacing.sm,
                              ),
                              child: _buildTagChip(
                                label: group,
                                isActive: !isHot && effectiveGroup == group,
                                colors: colors,
                                onTap: () {
                                  _leaderboardCategoryPicked = true;
                                  setState(() {
                                    _leaderboardCategory =
                                        _LeaderboardCategory.all;
                                    _selectedLeaderboardGroup = group;
                                  });
                                },
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // 「新增热榜数据」固定在最右侧，分类再长也不会被挤出去。
                  Padding(
                    padding: const EdgeInsets.only(
                      left: AppSpacing.sm,
                      right: AppSpacing.lg,
                    ),
                    child: _buildAddHotBoardButton(colors),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: isHot
              ? _buildHotBoardTab(colors)
              : _buildAllLeaderboardsTab(colors, controller: controller),
        ),
      ],
    );
  }

  /// 榜单分类（按插件给出的 group 去重，保持接口顺序）。
  List<String> _leaderboardGroupsOf(List<Leaderboard> leaderboards) {
    final groups = <String>[];
    for (final board in leaderboards) {
      final group = board.group;
      if (group != null && group.isNotEmpty && !groups.contains(group)) {
        groups.add(group);
      }
    }
    return groups;
  }

  /// 按「有没有热榜数据」决定榜单分类：有选「热榜」，没有选「所有」。
  ///
  /// * 进入榜单页 / 切换音源后都会调用（切换音源时不记住上一次的选中的分类）；
  /// * 热榜跨音源聚合，只要有任意一个可用音源配过热榜就选「热榜」，
  ///   不再跟着主页当前音源走；
  /// * 用户在手动点过分类（[_leaderboardCategoryPicked]）就不动，这样在没有
  ///   热榜时点「热榜」去新增数据不会被弹回「所有」。
  void _applyLeaderboardDefault() {
    if (!mounted) return;
    if (_leaderboardCategoryPicked) return;
    final hasHot = _hasVisibleHotBoards();
    final category = hasHot
        ? _LeaderboardCategory.hot
        : _LeaderboardCategory.all;
    if (category == _leaderboardCategory) return;
    setState(() => _leaderboardCategory = category);
  }

  /// 当前是否有可展示的热榜（插件被卸载 / 关闭后，它带来的热榜不再计数）。
  ///
  /// 插件还没初始化完时不能据此隐藏任何配置，否则启动瞬间热榜会被误判为空。
  bool _hasVisibleHotBoards() {
    final boards = ref.read(hotBoardsProvider).valueOrNull;
    if (boards == null) {
      return ref.read(hotBoardSourceIdsProvider).isNotEmpty;
    }
    if (boards.isEmpty) return false;
    if (!ref.read(pluginInitializedProvider).hasValue) return true;
    final enabled = {
      for (final source in ref.read(pluginSupportedSourcesProvider)) source.id,
    };
    return boards.any((board) => enabled.contains(board.source));
  }

  /// 当前启用音源的热榜；插件还没初始化完时先原样展示。
  List<HotBoard> _visibleHotBoards(List<HotBoard> boards) {
    if (!ref.read(pluginInitializedProvider).hasValue) return boards;
    final enabled = {
      for (final source in ref.read(pluginSupportedSourcesProvider)) source.id,
    };
    return [
      for (final board in boards)
        if (enabled.contains(board.source)) board,
    ];
  }

  void _selectLeaderboardCategory(_LeaderboardCategory category) {
    _leaderboardCategoryPicked = true;
    final changed = _leaderboardCategory != category;
    if (changed) setState(() => _leaderboardCategory = category);
    // 点「热榜」时补齐还没取到的歌曲（已有的跳过，不会重复请求）。
    if (category == _LeaderboardCategory.hot) _refreshHotBoards();
  }

  /// 进入「热榜」时补齐内存里还没有的歌曲（所有音源一起）。
  ///
  /// 每个榜单在一次运行里只取一次网络：内存里已有歌曲的榜单会被跳过
  /// （见 `HotBoardsNotifier.refreshSongs`），所以来回切分类 / 切页面不会反复请求。
  void _refreshHotBoards() {
    unawaited(ref.read(hotBoardsProvider.notifier).refreshSongs());
  }

  /// 当前停在「热榜」分类时才刷新（进榜单页 / 切音源时调用）。
  void _refreshHotBoardsIfHot() {
    if (!mounted) return;
    if (_leaderboardCategory != _LeaderboardCategory.hot) return;
    _refreshHotBoards();
  }

  Widget _buildAddHotBoardButton(ThemeColors colors) {
    return Tooltip(
      message: context.tr('新增热榜数据'),
      child: MouseRegion(
        cursor: _addingHotBoard
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _addingHotBoard ? null : () => unawaited(_addHotBoard()),
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: colors.surface,
            ),
            child: _addingHotBoard
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors.primary,
                    ),
                  )
                : Icon(Icons.add, size: 20, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }

  /// 「热榜」分类：没有数据时给出引导，有数据时逐个展示榜单 TOP 10。
  ///
  /// 热榜跨音源聚合：不跟随主页当前音源，但插件被卸载 / 关闭后，它带来的
  /// 榜单不再显示（配置仍保留，重新启用插件后会再出现）。
  Widget _buildHotBoardTab(ThemeColors colors) {
    // 音源开关变化要重建这里，才能及时隐藏 / 恢复对应热榜。
    ref.watch(pluginInitializedProvider);
    ref.watch(pluginSupportedSourcesProvider);
    return ref
        .watch(hotBoardsProvider)
        .when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 48, color: colors.textHint),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.tr('热榜数据加载失败'),
                  style: TextStyle(color: colors.textHint),
                ),
                const SizedBox(height: AppSpacing.md),
                TextButton(
                  onPressed: () => ref.invalidate(hotBoardsProvider),
                  child: Text(context.tr('重试')),
                ),
              ],
            ),
          ),
          data: (all) {
            final boards = _visibleHotBoards(all);
            // 没有配置过榜单才算「空」；歌曲是实时的，可能还在取 / 取失败，
            // 那种情况交给卡片自己显示加载中 / 重试，不能当成「没有热榜」。
            if (boards.isEmpty) return _buildHotBoardEmpty(colors);
            return _buildHotBoardContent(colors, boards);
          },
        );
  }

  Widget _buildHotBoardEmpty(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.local_fire_department_outlined,
            size: 48,
            color: colors.textHint,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(context.tr('还没有热榜数据'), style: TextStyle(color: colors.textHint)),
          const SizedBox(height: AppSpacing.xs),
          Text(
            context.tr('点击右上角 + 选择要展示的榜单'),
            style: TextStyle(fontSize: 12, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.md),
          OutlinedButton.icon(
            onPressed: _addingHotBoard ? null : () => unawaited(_addHotBoard()),
            icon: const Icon(Icons.add, size: 18),
            label: Text(context.tr('选择榜单')),
          ),
        ],
      ),
    );
  }

  Widget _buildHotBoardContent(ThemeColors colors, List<HotBoard> boards) {
    final horizontalPadding = ResponsiveLayout.horizontalPadding(context);
    return CustomScrollView(
      cacheExtent: 480,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            AppSpacing.sm,
            horizontalPadding,
            // 热榜不分页、底下没有分页条，这里要让开悬浮的迷你播放器，
            // 否则滚到最后一张卡片会被播放栏盖住。
            AppSpacing.miniPlayerHeight + AppSpacing.xxl,
          ),
          sliver: SliverToBoxAdapter(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final columns = _hotBoardColumns(constraints.maxWidth);
                const spacing = AppSpacing.md;
                final width =
                    (constraints.maxWidth - spacing * (columns - 1)) / columns;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (final board in boards)
                      SizedBox(
                        width: width,
                        child: floatingCard(
                          colors: colors,
                          radius: AppRadius.lg,
                          child: _buildHotBoardCard(colors, board),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  /// 热榜列数：桌面一般 3 列、宽屏 4 列；手机竖屏 1 列，平板竖屏 2 列。
  int _hotBoardColumns(double width) {
    if (width >= 1680) return 4;
    if (width >= 1000) return 3;
    if (width >= 640) return 2;
    return 1;
  }

  Widget _buildHotBoardCard(ThemeColors colors, HotBoard board) {
    final favorited = _isHotBoardFavorited(board);
    final favoriting = _favoritingHotBoards.contains(board.id);
    final sourceName = ref
        .read(musicSourceManagerProvider)
        .sourceDisplayName(board.source);
    return Container(
      decoration: floatingSurfaceDecoration(
        colors,
        radius: AppRadius.lg,
        withShadow: false,
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () => _openHotBoardDetail(board),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    child: SizedBox(
                      width: 86,
                      height: 86,
                      child: MusicCoverImage(
                        url: board.coverUrl,
                        fit: BoxFit.cover,
                        errorWidget: Icon(
                          Icons.show_chart,
                          size: 32,
                          color: colors.textHint,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        board.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          height: 1.15,
                          color: colors.textPrimary,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.sm),
                      Row(
                        children: [
                          _buildHotBoardButton(
                            colors,
                            icon: Icons.play_arrow_rounded,
                            tooltip: context.tr('播放'),
                            onTap: () => unawaited(_playHotSong(board, 0)),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          _buildHotBoardButton(
                            colors,
                            icon: favorited
                                ? Icons.favorite
                                : Icons.favorite_border,
                            tooltip: context.tr(favorited ? '取消收藏' : '收藏'),
                            color: favorited ? colors.primary : null,
                            loading: favoriting,
                            onTap: () =>
                                unawaited(_toggleHotBoardFavorite(board)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                _buildSourceNameTag(colors, sourceName),
              ],
            ),
          ),
          if (board.songs.isEmpty)
            _buildHotBoardSongsPlaceholder(colors, board)
          else
            for (var i = 0; i < board.songs.length; i++)
              _buildHotSongItem(colors, board, i),
          _buildHotBoardFooter(colors, board),
        ],
      ),
    );
  }

  /// 榜单卡片右上角的音源名称标签。
  ///
  /// 固定宽度 = 5 个中文字符（字号 13，与歌曲名同字号）；名称超出时直接
  /// 裁掉，不加省略号。完整名称放在 Tooltip 里。
  Widget _buildSourceNameTag(ThemeColors colors, String name) {
    return Tooltip(
      message: name,
      child: Container(
        width: 69,
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.xs),
        ),
        child: ClipRect(
          child: Text(
            name,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.clip,
            style: TextStyle(fontSize: 13, color: colors.textSecondary),
          ),
        ),
      ),
    );
  }

  Widget _buildHotBoardButton(
    ThemeColors colors, {
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? color,
    bool loading = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          alignment: Alignment.center,
          decoration: floatingSurfaceDecoration(
            colors,
            radius: AppRadius.sm,
            subtle: true,
          ),
          child: loading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.primary,
                  ),
                )
              : Icon(icon, size: 20, color: color ?? colors.textPrimary),
        ),
      ),
    );
  }

  /// 榜单歌曲还没到时的占位行：加载中转圈，失败 / 空给一个「点击重试」。
  Widget _buildHotBoardSongsPlaceholder(ThemeColors colors, HotBoard board) {
    final loading = board.songsLoading;
    final failed = board.songsError != null;
    final label = loading
        ? context.tr('正在获取榜单歌曲…')
        : failed
        ? context.tr('榜单歌曲获取失败，点击重试')
        : context.tr('暂无榜单歌曲，点击重试');
    return InkWell(
      onTap: loading
          ? null
          : () => unawaited(
              ref.read(hotBoardsProvider.notifier).refreshBoard(board),
            ),
      child: SizedBox(
        height: 64,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            else
              Icon(Icons.refresh, size: 16, color: colors.textHint),
            const SizedBox(width: AppSpacing.sm),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHotBoardFooter(ThemeColors colors, HotBoard board) {
    return InkWell(
      onTap: () => _openHotBoardDetail(board),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            Text(
              context.tr('查看全部'),
              style: TextStyle(fontSize: 12, color: colors.textSecondary),
            ),
            Icon(Icons.chevron_right, size: 16, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.md),
          ],
        ),
      ),
    );
  }

  void _openHotBoardDetail(HotBoard board) {
    context.push('/playlist/${board.id}?type=rank');
  }

  bool _isHotBoardFavorited(HotBoard board) {
    final playlists = ref.watch(playlistsProvider).valueOrNull;
    return playlists?.any((item) => item.meta['discoverId'] == board.id) ??
        false;
  }

  /// 收藏整个榜单：先按页取回完整歌曲，再存进「我的歌单」。
  Future<void> _toggleHotBoardFavorite(HotBoard board) async {
    if (_favoritingHotBoards.contains(board.id)) return;
    final playlists =
        ref.read(playlistsProvider).valueOrNull ?? const <local.Playlist>[];
    final existing = playlists
        .where((item) => item.meta['discoverId'] == board.id)
        .firstOrNull;
    if (existing != null) {
      await ref.read(playlistsProvider.notifier).deletePlaylist(existing.id);
      return;
    }

    setState(() => _favoritingHotBoards.add(board.id));
    try {
      final songs = await _fetchAllHotBoardSongs(board);
      if (!mounted) return;
      if (songs.isEmpty) {
        _showMessage(context.tr('没有获取到榜单歌曲'));
        return;
      }
      await ref
          .read(playlistsProvider.notifier)
          .createPlaylistFromModel(
            local.Playlist(
              id: 'discover_${Uri.encodeComponent(board.id)}',
              name: board.name,
              coverImgUrl: board.coverUrl ?? '',
              source: board.source,
              createTime: DateTime.now(),
              updateTime: DateTime.now(),
              songs: songs,
              meta: {'discoverId': board.id, 'type': 'discover_playlist'},
            ),
          );
      if (mounted) _showMessage(context.tr('已收藏到我的歌单'));
    } catch (e) {
      if (mounted) {
        _showMessage(
          context.tr('收藏失败：${e.toString().replaceFirst('Exception: ', '')}'),
        );
      }
    } finally {
      if (mounted) setState(() => _favoritingHotBoards.remove(board.id));
    }
  }

  /// 热榜里只存了前 10 首，收藏时从第 1 页继续取到末页。
  Future<List<Song>> _fetchAllHotBoardSongs(HotBoard board) async {
    final seen = <String>{};
    final all = <Song>[];
    for (final song in board.songs) {
      if (seen.add(song.id)) all.add(song);
    }
    final repository = ref.read(discoverRepositoryProvider);
    var emptyStreak = 0;
    for (var page = 1; page <= 50; page++) {
      final result = await repository.getPlaylistDetailPage(
        board.id,
        page: page,
      );
      var added = 0;
      for (final song in result.playlist?.songs ?? const <Song>[]) {
        if (seen.add(song.id)) {
          all.add(song);
          added++;
        }
      }
      if (result.isEnd) break;
      if (result.total != null && all.length >= result.total!) break;
      // 插件可能把整页不可播放的歌曲过滤成空页，连续几页没新歌才停下。
      if (added == 0 && ++emptyStreak >= 5) break;
    }
    return all;
  }

  Widget _buildHotSongItem(ThemeColors colors, HotBoard board, int index) {
    final song = board.songs[index];
    final isTopThree = index < 3;
    final isCurrent =
        ref.watch(
          playbackControllerProvider.select((state) => state.currentSong?.id),
        ) ==
        song.id;
    // 歌曲行深浅交错：奇数行垫一层略亮的颜色。
    final background = index.isOdd
        ? colors.surfaceVariant.withValues(alpha: 0.55)
        : Colors.transparent;
    final title = Text(
      song.title,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: isTopThree ? 14 : 13,
        fontWeight: isTopThree ? FontWeight.w600 : FontWeight.w400,
        color: isCurrent ? colors.primary : colors.textPrimary,
      ),
    );
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(_playHotSong(board, index)),
      child: Container(
        height: isTopThree ? 58 : 44,
        color: background,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Row(
          children: [
            SizedBox(
              // 序号列按榜单最大序号的位数自适应（热榜一般 10 首 = 两位数），
              // 用前三行的大字号量，保证所有行宽度一致且不折行。
              width: songIndexWidth(
                context,
                maxIndex: board.songs.length,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
              child: Text(
                '${index + 1}',
                textAlign: TextAlign.left,
                maxLines: 1,
                softWrap: false,
                style: TextStyle(
                  fontSize: isTopThree ? 16 : 13,
                  fontWeight: isTopThree ? FontWeight.w700 : FontWeight.w500,
                  color: isTopThree ? colors.error : colors.textPrimary,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (isTopThree) ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xs),
                child: SizedBox(
                  width: 40,
                  height: 40,
                  child: MusicCoverImage(
                    url: song.coverUrl,
                    songId: song.id,
                    fit: BoxFit.cover,
                    errorWidget: Icon(
                      Icons.music_note,
                      size: 18,
                      color: colors.textHint,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              // 前三首只显示歌名，不显示歌手名。
              Expanded(child: title),
            ] else ...[
              // 第 4 首起不显示封面：歌名与前三首封面的左边缘对齐。
              Expanded(child: title),
            ],
            if (isCurrent) ...[
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.equalizer, size: 16, color: colors.primary),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _playHotSong(HotBoard board, int index) async {
    if (board.songs.isEmpty) {
      // 歌曲是实时拉的：还没到 / 取失败时先触发一次，别拿空队列去播。
      unawaited(ref.read(hotBoardsProvider.notifier).refreshBoard(board));
      _showMessage(context.tr('正在获取榜单歌曲，请稍候'));
      return;
    }
    PlaybackContext.instance.set(
      PlaybackSourceType.rank,
      id: board.id,
      name: board.name,
    );
    await ref
        .read(playbackControllerProvider.notifier)
        .setQueue(board.songs, startIndex: index);
  }

  /// 选择当前音源下的榜单，把它的前 10 首歌存成「热榜」。
  ///
  /// 弹框里已添加的榜单置顶，可拖动排序、删除；新增的榜单追加在末尾。
  Future<void> _addHotBoard() async {
    if (_addingHotBoard) return;
    setState(() => _addingHotBoard = true);
    final colors = ref.read(themeColorsProvider);
    try {
      // 所有已启用的音源都可以选：弹框里用 tab 切换音源，榜单按 tab 拉取。
      final allSources = ref.read(switchableSourcesProvider);
      if (allSources.isEmpty) {
        _showMessage(context.tr('暂无可用音源'));
        return;
      }
      final currentId = ref.read(discoverSourceIdProvider);
      final sources = [
        for (final source in allSources)
          if (source.id == currentId) source,
        for (final source in allSources)
          if (source.id != currentId) source,
      ];
      await _showHotBoardPicker(colors, sources, sources.first.id);
      if (!mounted) return;
      setState(() => _leaderboardCategory = _LeaderboardCategory.hot);
      _refreshHotBoards();
    } finally {
      if (mounted) setState(() => _addingHotBoard = false);
    }
  }

  Future<void> _showHotBoardPicker(
    ThemeColors colors,
    List<SourceInfo> sources,
    String initialSourceId,
  ) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.72;
    return showModalBottomSheet<void>(
      useRootNavigator: true,
      context: context,
      isScrollControlled: true,
      sheetAnimationStyle: const AnimationStyle(
        duration: Duration(milliseconds: 220),
        reverseDuration: Duration(milliseconds: 180),
      ),
      backgroundColor: colors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xl)),
      ),
      builder: (_) => _HotBoardPickerSheet(
        colors: colors,
        sources: sources,
        initialSourceId: initialSourceId,
        height: sheetHeight,
        onAdd: _addPickedHotBoard,
      ),
    );
  }

  /// 把选中的榜单加入热榜（只记配置；歌曲由 notifier 立刻取一次、只留内存）。
  /// 弹框保持打开，可以继续添加其它榜单。
  Future<void> _addPickedHotBoard(Leaderboard selected) async {
    try {
      final board = HotBoard(
        id: selected.id,
        name: selected.name,
        source: selected.source,
        coverUrl: selected.coverUrl,
      );
      final notifier = ref.read(hotBoardsProvider.notifier);
      await notifier.add(board);
      // 加完顺手取一次歌曲（只进内存）：不用等下次进「热榜」才看到内容。
      unawaited(notifier.refreshBoard(board));
    } catch (e) {
      if (mounted) {
        _showMessage(
          context.tr('添加榜单失败：${e.toString().replaceFirst('Exception: ', '')}'),
        );
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  Widget _buildAllLeaderboardsTab(
    ThemeColors colors, {
    ScrollController? controller,
  }) {
    final leaderboardsAsync = ref.watch(leaderboardsProvider);

    return leaderboardsAsync.when(
      data: (leaderboards) {
        if (leaderboards.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.show_chart, size: 48, color: colors.textHint),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.tr('暂无榜单数据'),
                  style: TextStyle(color: colors.textHint),
                ),
              ],
            ),
          );
        }
        // 分类 chips 在「热榜 / 所有」同一行里（见 _buildLeaderboardsTab），
        // 这里只按选中的分类过滤；选中分类失效（切音源后）时回退全部。
        final groups = _leaderboardGroupsOf(leaderboards);
        final selected = groups.contains(_selectedLeaderboardGroup)
            ? _selectedLeaderboardGroup
            : null;
        final filtered = selected == null
            ? leaderboards
            : leaderboards
                  .where((board) => board.group == selected)
                  .toList(growable: false);
        return _buildLeaderboardGrid(colors, filtered, controller: controller);
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.textHint),
            const SizedBox(height: AppSpacing.md),
            Text(context.tr('加载失败'), style: TextStyle(color: colors.textHint)),
            const SizedBox(height: AppSpacing.md),
            TextButton(
              onPressed: () => ref.invalidate(leaderboardsProvider),
              child: Text(context.tr('重试')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeaderboardGrid(
    ThemeColors colors,
    List<Leaderboard> leaderboards, {
    ScrollController? controller,
  }) {
    final crossAxisCount = ResponsiveLayout.gridCrossAxisCount(context);
    final isTablet = ResponsiveLayout.isTablet(context);

    _leaderboardPager.updatePageSize(_playlistPageRows * crossAxisCount);
    _leaderboardPager.clampTo(leaderboards.length, hasMore: false);
    final visible = _leaderboardPager.slice(leaderboards);
    return CustomScrollView(
      controller: controller,
      primary: controller == null ? false : null,
      cacheExtent: 360,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.only(
            left: ResponsiveLayout.horizontalPadding(context),
            right: ResponsiveLayout.horizontalPadding(context),
            bottom: AppSpacing.md,
          ),
          sliver: SliverGrid(
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: crossAxisCount,
              mainAxisSpacing: isTablet ? 16 : AppSpacing.md,
              crossAxisSpacing: isTablet ? 16 : AppSpacing.md,
              childAspectRatio: isTablet ? 0.88 : 0.82,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) => floatingCard(
                colors: colors,
                radius: AppRadius.lg,
                child: _buildLeaderboardCard(colors, visible[index], index),
              ),
              childCount: visible.length,
              addAutomaticKeepAlives: false,
            ),
          ),
        ),
        // 分页条：内容不满一屏时贴到底部，满一屏时跟在网格后面。
        PageBarFooterSliver(
          child: PageBar(
            currentPage: _leaderboardPager.page,
            pageCount: _leaderboardPager.pageCount(
              leaderboards.length,
              hasMore: false,
            ),
            docked: true,
            onChanged: (page) {
              setState(() => _leaderboardPager.jumpTo(page));
              if (_leaderboardScrollController.hasClients) {
                _leaderboardScrollController.jumpTo(0);
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLeaderboardCard(
    ThemeColors colors,
    Leaderboard board,
    int index,
  ) {
    return GestureDetector(
      onTap: () {
        context.push('/playlist/${board.id}?type=rank');
      },
      child: Container(
        decoration: floatingSurfaceDecoration(
          colors,
          radius: AppRadius.lg,
          withShadow: false,
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          colors.primary.withValues(alpha: 0.3 + index * 0.05),
                          colors.surfaceVariant,
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: MusicCoverImage(
                      url: board.coverUrl,
                      fit: BoxFit.cover,
                      errorWidget: Icon(
                        Icons.show_chart,
                        size: 40,
                        color: colors.textHint,
                      ),
                    ),
                  ),
                  if (board.playCount != null && board.playCount!.isNotEmpty)
                    Positioned(
                      top: AppSpacing.xs,
                      right: AppSpacing.xs,
                      child: CoverCountBadge(
                        label: board.playCount!,
                        icon: Icons.play_arrow,
                        fontSize: 11,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: 2,
                        ),
                        radius: AppRadius.xs,
                        background: Colors.black54,
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppSpacing.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    board.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (board.updateFrequency != null)
                    Text(
                      board.updateFrequency!,
                      style: TextStyle(fontSize: 11, color: colors.textHint),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 「新增热榜数据」弹框：顶部按音源分 tab，已添加的榜单置顶、可拖动排序 /
/// 删除，下方是该音源还能添加的榜单（新增的追加在已添加列表末尾）。
class _HotBoardPickerSheet extends ConsumerStatefulWidget {
  const _HotBoardPickerSheet({
    required this.colors,
    required this.sources,
    required this.initialSourceId,
    required this.height,
    required this.onAdd,
  });

  final ThemeColors colors;
  final List<SourceInfo> sources;
  final String initialSourceId;
  final double height;
  final Future<void> Function(Leaderboard board) onAdd;

  @override
  ConsumerState<_HotBoardPickerSheet> createState() =>
      _HotBoardPickerSheetState();
}

class _HotBoardPickerSheetState extends ConsumerState<_HotBoardPickerSheet> {
  String? _addingId;
  late String _sourceId = widget.initialSourceId;

  Future<void> _add(Leaderboard board) async {
    if (_addingId != null) return;
    setState(() => _addingId = board.id);
    try {
      await widget.onAdd(board);
    } finally {
      if (mounted) setState(() => _addingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final sourceId = widget.sources.any((source) => source.id == _sourceId)
        ? _sourceId
        : widget.sources.first.id;
    final boardsAsync = ref.watch(leaderboardsForSourceProvider(sourceId));
    return SizedBox(
      height: widget.height,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('新增热榜数据'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  context.tr('已添加的榜单可以拖动排序，新增的榜单排在下方'),
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
              ],
            ),
          ),
          _buildSourceTabs(colors, sourceId),
          Divider(height: 1, color: colors.divider.withValues(alpha: 0.4)),
          Expanded(
            child: boardsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      context.tr('榜单数据加载失败'),
                      style: TextStyle(color: colors.textHint),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: () => ref.invalidate(
                        leaderboardsForSourceProvider(sourceId),
                      ),
                      child: Text(context.tr('重试')),
                    ),
                  ],
                ),
              ),
              data: (boards) => _buildBoardList(colors, sourceId, boards),
            ),
          ),
        ],
      ),
    );
  }

  /// 音源切换 tab：横向滚动，当前音源高亮。
  Widget _buildSourceTabs(ThemeColors colors, String sourceId) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < widget.sources.length; i++) ...[
              if (i > 0) const SizedBox(width: AppSpacing.sm),
              _buildSourceTab(
                colors,
                widget.sources[i],
                selected: widget.sources[i].id == sourceId,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSourceTab(
    ThemeColors colors,
    SourceInfo source, {
    required bool selected,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.full),
      onTap: selected
          ? null
          : () => setState(() {
              _sourceId = source.id;
              _addingId = null;
            }),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: 6,
        ),
        decoration: BoxDecoration(
          color: selected ? colors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.full),
          border: Border.all(color: selected ? colors.primary : colors.divider),
        ),
        child: Text(
          source.name,
          maxLines: 1,
          style: TextStyle(
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
            color: selected ? colors.textOnPrimary : colors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildBoardList(
    ThemeColors colors,
    String sourceId,
    List<Leaderboard> boards,
  ) {
    final added = [
      for (final board
          in ref.watch(hotBoardsProvider).valueOrNull ?? const <HotBoard>[])
        if (board.source == sourceId) board,
    ];
    final addedIds = {for (final board in added) board.id};
    final available = [
      for (final board in boards)
        if (!addedIds.contains(board.id)) board,
    ];
    final pickerGroups = _pickerGroupsOf(available);
    final ungrouped = _ungroupedOf(available);
    return SingleChildScrollView(
      padding: const EdgeInsets.only(bottom: AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (added.isNotEmpty) ...[
            _sectionLabel('已添加', '按住右侧图标拖动排序'),
            ReorderableListView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              buildDefaultDragHandles: false,
              padding: EdgeInsets.zero,
              itemCount: added.length,
              onReorder: (oldIndex, newIndex) => ref
                  .read(hotBoardsProvider.notifier)
                  .reorderForSource(sourceId, oldIndex, newIndex),
              itemBuilder: (context, index) {
                final board = added[index];
                return _AddedHotBoardTile(
                  key: ValueKey('${board.source}:${board.id}'),
                  colors: colors,
                  board: board,
                  index: index,
                  onDelete: () =>
                      ref.read(hotBoardsProvider.notifier).remove(board),
                );
              },
            ),
          ],
          _sectionLabel('添加榜单', null),
          if (available.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.md,
              ),
              child: Text(
                boards.isEmpty
                    ? context.tr('该音源暂无榜单数据')
                    : context.tr('当前音源的榜单都已添加'),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            )
          else if (pickerGroups.length < 2)
            for (final board in available) _availableTile(board)
          else ...[
            // 榜单按分类分节展示（与发现页的分类 chips 同一套数据）
            for (final group in pickerGroups) ...[
              _pickerGroupLabel(group),
              for (final board in available)
                if (board.group == group) _availableTile(board),
            ],
            if (ungrouped.isNotEmpty) ...[
              _pickerGroupLabel(context.tr('其他')),
              for (final board in ungrouped) _availableTile(board),
            ],
          ],
        ],
      ),
    );
  }

  /// 待添加榜单的分类（按插件给出的 group 去重，保持顺序；少于 2 组不分节）。
  List<String> _pickerGroupsOf(List<Leaderboard> available) {
    final groups = <String>[];
    for (final board in available) {
      final group = board.group;
      if (group != null && group.isNotEmpty && !groups.contains(group)) {
        groups.add(group);
      }
    }
    return groups;
  }

  /// 没有分类归属的榜单（分节展示时归到「其他」）。
  List<Leaderboard> _ungroupedOf(List<Leaderboard> available) {
    if (_pickerGroupsOf(available).length < 2) return const <Leaderboard>[];
    return [
      for (final board in available)
        if (board.group == null || board.group!.isEmpty) board,
    ];
  }

  Widget _pickerGroupLabel(String title) {
    final colors = widget.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.sm,
        AppSpacing.lg,
        AppSpacing.xs,
      ),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: colors.primary,
        ),
      ),
    );
  }

  Widget _sectionLabel(String title, String? hint) {
    final colors = widget.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.md,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Row(
        children: [
          Text(
            context.tr(title),
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: colors.textSecondary,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                context.tr(hint),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.textHint),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _availableTile(Leaderboard board) {
    final colors = widget.colors;
    final adding = _addingId == board.id;
    return InkWell(
      onTap: adding ? null : () => _add(board),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: SizedBox(
                width: 44,
                height: 44,
                child: MusicCoverImage(
                  url: board.coverUrl,
                  fit: BoxFit.cover,
                  errorWidget: Icon(
                    Icons.show_chart,
                    size: 20,
                    color: colors.textHint,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    board.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: colors.textPrimary,
                    ),
                  ),
                  if (board.updateFrequency != null &&
                      board.updateFrequency!.isNotEmpty)
                    Text(
                      board.updateFrequency!,
                      style: TextStyle(fontSize: 11, color: colors.textHint),
                    ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            if (adding)
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              )
            else
              Icon(Icons.add_circle_outline, size: 20, color: colors.textHint),
          ],
        ),
      ),
    );
  }
}

class _AddedHotBoardTile extends StatelessWidget {
  const _AddedHotBoardTile({
    super.key,
    required this.colors,
    required this.board,
    required this.index,
    required this.onDelete,
  });

  final ThemeColors colors;
  final HotBoard board;
  final int index;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        0,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.fromLTRB(AppSpacing.sm, 6, 2, 6),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.xs),
            child: SizedBox(
              width: 36,
              height: 36,
              child: MusicCoverImage(
                url: board.coverUrl,
                fit: BoxFit.cover,
                errorWidget: Icon(
                  Icons.show_chart,
                  size: 18,
                  color: colors.textHint,
                ),
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              board.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: colors.textPrimary,
              ),
            ),
          ),
          Tooltip(
            message: context.tr('删除'),
            child: InkWell(
              onTap: onDelete,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: colors.error,
                ),
              ),
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Icon(Icons.drag_handle, size: 20, color: colors.textHint),
            ),
          ),
        ],
      ),
    );
  }
}

/// 「更多分类」弹层内容：分类纵向平铺，超出可滚动，右侧显示滚动条。
class _CategorySheetContent extends StatefulWidget {
  const _CategorySheetContent({
    required this.groups,
    required this.activeTagId,
    required this.colors,
    required this.onSelect,
  });

  final List<PlaylistTagGroup> groups;
  final String activeTagId;
  final ThemeColors colors;
  final void Function(String tagId, String name) onSelect;

  @override
  State<_CategorySheetContent> createState() => _CategorySheetContentState();
}

class _CategorySheetContentState extends State<_CategorySheetContent> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: ListView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.lg,
          AppSpacing.md,
          AppSpacing.lg,
          AppSpacing.xl,
        ),
        children: [
          for (var i = 0; i < widget.groups.length; i++) ...[
            _buildGroupTitle(context, widget.groups[i].name),
            const SizedBox(height: AppSpacing.sm),
            _buildTagWrap(context, widget.groups[i]),
            // 分组标题本身已带一条贯穿的横线，组与组之间只留间距，
            // 不再画整宽分割线（否则和标题横线叠成两条）。
            if (i != widget.groups.length - 1)
              const SizedBox(height: AppSpacing.xxl),
          ],
        ],
      ),
    );
  }

  /// 分类标题（如「语种」「分类」）。
  Widget _buildGroupTitle(BuildContext context, String name) {
    final colors = widget.colors;
    return Row(
      children: [
        Text(
          context.tr(name),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Divider(
            height: 1,
            color: colors.divider.withValues(alpha: 0.35),
          ),
        ),
      ],
    );
  }

  /// 分类下的标签平铺（自动换行）。
  Widget _buildTagWrap(BuildContext context, PlaylistTagGroup group) {
    final colors = widget.colors;
    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: group.tags.map((tag) {
        final isActive = widget.activeTagId == tag.id;
        return GestureDetector(
          onTap: () => widget.onSelect(tag.id, tag.name),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: isActive
                  ? colors.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isActive
                    ? colors.primary.withValues(alpha: 0.5)
                    : colors.divider.withValues(alpha: 0.4),
              ),
            ),
            child: Text(
              tag.name,
              style: TextStyle(
                fontSize: 13,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                color: isActive ? colors.primary : colors.textSecondary,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
