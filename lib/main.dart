import 'dart:async';
import 'dart:io';
import 'dart:ui' show AppExitResponse;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'app/app.dart';
import 'core/platform/taskbar_thumbnail_service.dart';
import 'core/services/audio_service_init.dart';
import 'core/storage/app_database.dart';
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

  // A large unbounded decoded-image cache causes memory pressure and GC jank
  // after browsing many playlists on lower-end devices. Cover widgets keep
  // their own small byte cache, so a bounded framework cache is sufficient.
  PaintingBinding.instance.imageCache.maximumSize = 120;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;

  HttpOverrides.global = _NeteaseImageHttpOverrides();

  // Windows 上 just_audio 没有原生实现（需要额外后端），否则所有 AudioPlayer
  // 调用（包括插件测试的试听校验与正常播放）都会抛 MissingPluginException。
  // 这里注册 media_kit（libmpv）后端；Android/iOS 依旧使用 just_audio 原生实现。
  if (Platform.isWindows) {
    JustAudioMediaKit.ensureInitialized(windows: true);
    // 出现在 Windows 音量合成器里的名称。
    JustAudioMediaKit.title = 'Mint Music';
    print('>>> main: 已启用 media_kit Windows 音频后端');
  }

  print('>>> main: 开始初始化音频服务...');

  try {
    await initAudioService().timeout(const Duration(seconds: 10));
    print('>>> main: 音频服务初始化成功');
  } catch (e, stack) {
    print('>>> main: 音频服务初始化失败: $e');
    print('>>> main: 堆栈: $stack');
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

  // 缓存目录：封面 / 网络图片等缓存统一写到「设置 - 存储管理」里指定的目录。
  try {
    CachePaths.configure(container.read(cacheDirProvider));
    CachePaths.maxBytes = container.read(maxCacheSizeMbProvider) * 1024 * 1024;
    await AppImageCache.configure();
    unawaited(CachePaths.enforceLimit());
    print('>>> main: 缓存目录 -> ${CachePaths.root ?? "应用默认缓存目录"}');
  } catch (e) {
    print('>>> main: 缓存目录初始化失败: $e');
  }

  // 旧版把歌词缓存成「一首歌一个 JSON 文件」，现在搬进临时库。
  unawaited(LyricCache.migrateLegacyFiles());

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
/// 本地歌曲列表、最近播放、下载列表、搜索历史这些数据在运行期只在内存里改，
/// 攒够一批才写进数据库；如果不在这里强制落盘，进程被杀就会丢掉最近的一段。
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
          .then((_) => AppDatabase.checkpoint())
          .timeout(const Duration(seconds: 2));
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
