import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'app/app.dart';
import 'core/services/audio_service_init.dart';
import 'features/settings/application/settings_providers.dart';
import 'shared/services/amll_toggle_service.dart';
import 'shared/services/app_image_cache.dart';
import 'shared/services/cache_paths.dart';
import 'features/player/presentation/widgets/amll_lyric_player.dart';

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

  // 初始化 AMLL 开关
  await AmllToggleService().loadFromPrefs();
  print('>>> main: AMLL toggle loaded: ${AmllToggleService().enabled}');

  // 缓存目录：封面 / 网络图片等缓存统一写到「设置 - 存储管理」里指定的目录。
  try {
    CachePaths.configure(container.read(cacheDirProvider));
    CachePaths.maxBytes =
        container.read(maxCacheSizeMbProvider) * 1024 * 1024;
    await AppImageCache.configure();
    unawaited(CachePaths.enforceLimit());
    print('>>> main: 缓存目录 -> ${CachePaths.root ?? "应用默认缓存目录"}');
  } catch (e) {
    print('>>> main: 缓存目录初始化失败: $e');
  }

  // Route preload is an idle-time optimization controlled by settings. It
  // only prepares the cached AMLL document; no WebView or audio resource is
  // created until the lyric route is actually shown.
  if (container.read(routePreloadEnabledProvider)) {
    unawaited(AmllLyricPlayerState.prewarm());
    // 预热字体缓存：在后台完成 base64 编码，避免首次打开歌词页时阻塞 UI
    unawaited(AmllLyricPlayerState.prewarmFonts('lyricfont'));
  }

  print('>>> main: 启动应用...');
  runApp(UncontrolledProviderScope(container: container, child: const App()));
}

class _NeteaseImageHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..userAgent = null;
  }
}
