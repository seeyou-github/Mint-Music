import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/foundation.dart' show kReleaseMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'app/app.dart';
import 'core/backup/auto_backup.dart';
import 'core/backup/data_sync_coordinator.dart';
import 'core/platform/app_paths.dart';
import 'core/platform/taskbar_thumbnail_service.dart';
import 'core/services/audio_service_init.dart';
import 'core/storage/app_database.dart';
import 'core/storage/app_preferences.dart';
import 'core/storage/legacy_shared_prefs.dart';
import 'core/theme/app_font_manager.dart';
import 'core/theme/app_typography.dart';
import 'features/settings/application/font_providers.dart';
import 'features/settings/application/settings_providers.dart';
import 'shared/services/app_image_cache.dart';
import 'shared/services/cache_paths.dart';
import 'features/player/application/playback_controller.dart';
import 'features/player/domain/services/lyric_cache.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // release 下把 debugPrint 变成空实现。
  //
  // 全项目有 500+ 处 debugPrint（切歌、封面、插件桥接、歌词……都在热路径），
  // release 里它们仍然会把字符串格式化好再写 logcat —— 格式化是纯浪费，
  // 写入 logcat 还要走一次 IPC + 环形缓冲区。后台长播时这些是白白的 CPU
  // 唤醒与电量。真正需要 release 留痕的（证书校验放行）改用
  // `dart:developer` 的 log()。
  if (kReleaseMode) {
    debugPrint = (String? message, {int? wrapWidth}) {};
  }

  // 解码图缓存。全平台统一 128MB / 200 张：
  // 48MB 旧上限下很快就顶到 47MB，之后每滚一屏都要淘汰 + 重新解码封面，
  // 长列表滚动就会一顿一顿的。移动端现在同样按 128MB 给——封面解码后的
  // 常驻占用本来就远小于这个上限，只在大歌单连续滚动时才会用满，
  // 换来的是不再反复淘汰重解码。
  PaintingBinding.instance.imageCache.maximumSize = 200;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 128 << 20;

  HttpOverrides.global = _NeteaseImageHttpOverrides();

  // 目录结构（`AppData\config\setting`、`config\db`、`config\plugin`、
  // `download_music`、`temp`）是后改的：先把旧结构里的数据搬过来，再往下走，
  // 否则设置 / 收藏 / 插件都会「凭空消失」。幂等，失败只打日志。
  await AppPaths.migrateLegacyLayout();

  // Windows 上 just_audio 没有原生实现（需要额外后端），否则所有 AudioPlayer
  // 调用（包括插件测试的试听校验与正常播放）都会抛 MissingPluginException。
  // 这里注册 media_kit（libmpv）后端；Android/iOS 依旧使用 just_audio 原生实现。
  if (Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized(windows: true);
    // 出现在 Windows 音量合成器里的名称。
    JustAudioMediaKit.title = 'Mint Music';
    // mpv 的解码前缓存窗口（会分别设成 demuxer-max-bytes 与
    // demuxer-max-back-bytes，即「往前预读 / 往后保留」各一份）。
    //
    // 这个库默认给 32MB —— 那是拿来看视频的。本项目纯音频，4MB 足够：
    // 320kbps 约 1.7 分钟、128kbps 约 4 分钟、无损 FLAC 约 22 秒，
    // 都比「上游卡一下」能容忍的时长大得多，也省得 mpv 白占几十 MB。
    //
    // （Android 走 just_audio 的 ExoPlayer 后端，缓冲策略由 ExoPlayer 自己的
    // LoadControl 按「秒」管理，没有可以设字节数的公开接口。）
    JustAudioMediaKit.bufferSize = 4 * 1024 * 1024;
    print('>>> main: 已启用 media_kit Windows 音频后端');
  }

  print('>>> main: 设置初始化...');

  final container = ProviderContainer();
  try {
    await container
        .read(settingsInitProvider.future)
        .timeout(const Duration(seconds: 5));
    print('>>> main: 设置初始化成功');
  } catch (e, stack) {
    print('>>> main: 设置初始化失败: $e');
    print('>>> main: 堆栈: $stack');
  }

  // Android：设置已经统一存进 settings.json，`shared_prefs/` 里旧的
  // FlutterSharedPreferences.xml（内容已迁移）和 audio_service 的通知渠道
  // 配置都没有保留价值，启动完成后清一次（见 [LegacySharedPrefs]）。
  unawaited(LegacySharedPrefs.cleanup());

  // 加载导入的字体文件，并恢复上次选择的应用字体。
  // 没有选择过就用内置的思源宋体。
  unawaited(
    AppFontManager.instance.load().then((_) {
      final selected = AppFontManager.instance.selectedFamily;
      container.read(appFontSelectedProvider.notifier).state = selected;
      AppTypography.fontFamily = (selected == null || selected.isEmpty)
          ? AppTypography.defaultFontFamily
          : selected;
      print('>>> main: 应用字体 -> ${AppTypography.fontFamily}');
    }),
  );

  // 缓存目录固定为 `AppData\temp`（Windows / Android），不再有设置项。
  // 这里只做旧缓存子目录改名 / 清理（artwork_cache → local_songs_image_cache，
  // 删掉不再使用的 covers / image_discovery_cache）与图片缓存配置。
  try {
    await CachePaths.migrateLegacySubDirectories();
    await AppImageCache.configure();
    print('>>> main: 缓存目录 -> ${(await CachePaths.rootDirectory()).path}');
  } catch (e) {
    print('>>> main: 缓存目录初始化失败: $e');
  }

  // 音频服务必须排在缓存目录配置之后：`AudioService.init()` 的 `cacheManager`
  // 不传就会创建 `DefaultCacheManager`（key 写死 `libCachedImageData`），它的
  // 索引库会建到 files 目录、封面文件写到系统 cache 目录，且构造时就 open 建库
  // —— 表现就是每次启动都凭空多出 `libCachedImageData.db` 和对应文件夹，
  // 绕过「设置 - 缓存目录」。所以这里在 `AppImageCache.configure()` 之后才初始化。
  print('>>> main: 开始初始化音频服务...');
  try {
    await initAudioService().timeout(const Duration(seconds: 10));
    print('>>> main: 音频服务初始化成功');
  } catch (e, stack) {
    print('>>> main: 音频服务初始化失败: $e');
    print('>>> main: 堆栈: $stack');
  }

  // 旧版把歌词缓存成「一首歌一个 JSON 文件」，现在搬进临时库。
  unawaited(LyricCache.migrateLegacyFiles());

  // 自动同步（「设置 - 备份还原」里的开关）：任何设置写盘（插件、热榜、电台、
  // 扫描目录、字体……最终都写 settings.json）后排一次延迟备份到 WebDAV
  // （1 → 3 → 5 分钟，见 DelayedSync）；上次延迟没跑完就退出的，启动时补排。
  AutoBackup.attach(container);
  // 附加数据（黑名单 / 电台 / 热榜 / 插件）与播放进度的同步编排。
  DataSyncCoordinator.attach(container);
  AppPreferences.onWrite = () {
    AutoBackup.schedule();
    DataSyncCoordinator.scheduleExtras();
  };

  // Windows 任务栏缩略图工具栏（悬停任务栏图标时缩略图下方显示播放等按钮）。
  if (Platform.isWindows) {
    container.read(taskbarThumbnailServiceProvider);
  }

  print('>>> main: 启动应用...');
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: _AppLifecycleFlush(container: container, child: const App()),
    ),
  );
}

/// 应用切后台 / 退出前，把「延迟写」的高频数据立刻落盘。
///
/// 本地歌曲列表、最近播放这些数据在运行期只在内存里改，攒够一批才写进数据库；
/// 如果不在这里强制落盘，进程被杀就会丢掉最近的一段。
///
/// 桌面端关窗时，Flutter 引擎会先发 `System.requestAppExit` 等待 Dart 确认，
/// [didRequestAppExit] 利用这段时间完成落盘，之后再让窗口销毁。
class _AppLifecycleFlush extends StatefulWidget {
  const _AppLifecycleFlush({required this.child, required this.container});

  final Widget child;

  /// 退出前要用它结算当前歌曲的收听时长。
  final ProviderContainer container;

  @override
  State<_AppLifecycleFlush> createState() => _AppLifecycleFlushState();
}

class _AppLifecycleFlushState extends State<_AppLifecycleFlush>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // inactive（桌面窗口失焦）不算「要退出」，不触发全量 flush——
    // 那会在日常使用中频繁把所有延迟写器落盘。最小化（hidden）、
    // 切后台（paused）、引擎分离（detached）才需要。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(AppDatabase.flushAll());
      // 设置是防抖落盘，切后台时把还没到点的写入结算掉。
      final prefs = AppPreferences.maybeInstance;
      if (prefs != null) unawaited(prefs.flushNow());
    }
  }

  @override
  Future<AppExitResponse> didRequestAppExit() async {
    // 先把正在播放的这一段真实收听时长结算进待写队列，再统一落盘，
    // 否则「听了一半就关软件」的那段统计会丢。
    try {
      final container = widget.container;
      if (container.exists(playbackControllerProvider)) {
        container
            .read(playbackControllerProvider.notifier)
            .settleListenSession();
      }
    } catch (e) {
      debugPrint('[App] 退出前结算收听时长失败: $e');
    }

    // 设上限，避免数据库异常时卡住关窗；超时后仍然正常退出。
    try {
      await AppDatabase.flushAll()
          .then((_) => AppDatabase.checkpointAll())
          .timeout(const Duration(seconds: 2));
      await AppPreferences.maybeInstance?.flushNow().timeout(
        const Duration(seconds: 2),
      );
      // 进度 / 附加数据：关窗时不再等 WebDAV 往返，只在 temp 写一个待同步
      // 标记；下次启动看到标记会立即补一次完整同步。
      await DataSyncCoordinator.markExitSyncPending().timeout(
        const Duration(seconds: 1),
      );
    } catch (e) {
      debugPrint('[App] 退出前落盘失败或超时: $e');
    }
    return AppExitResponse.exit;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _NeteaseImageHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..userAgent = null;
  }
}
