import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app/app.dart';
import 'core/services/audio_service_init.dart';
import 'features/settings/application/settings_providers.dart';
import 'shared/services/amll_toggle_service.dart';
import 'features/player/presentation/widgets/amll_lyric_player.dart';

/// 启动耗时诊断用的计时器：启动流程一进来就开始计时。
final Stopwatch _startupStopwatch = Stopwatch()..start();

/// 把启动阶段时间戳追加到 `%TEMP%\mintmusic_startup.log`。
///
/// Windows runner 会先把窗口藏起来、等首帧渲染完成才 `Show()`，所以「窗口
/// 迟迟不出现」既可能是 Dart 侧卡住，也可能是原生引擎/图形初始化慢。这里与
/// `windows/runner` 的 C++ 端写同一个文件，跑一次就能对照出耗时发生在哪一段。
void _logStartup(String stage) {
  try {
    final path =
        '${Directory.systemTemp.path}${Platform.pathSeparator}mintmusic_startup.log';
    File(path).writeAsStringSync(
      '[dart] ${DateTime.now().toIso8601String()} '
      '+${_startupStopwatch.elapsedMilliseconds}ms $stage\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {
    // 诊断日志失败不影响启动流程。
  }
}

void main() async {
  _logStartup('main: 入口');
  WidgetsFlutterBinding.ensureInitialized();

  // A large unbounded decoded-image cache causes memory pressure and GC jank
  // after browsing many playlists on lower-end devices. Cover widgets keep
  // their own small byte cache, so a bounded framework cache is sufficient.
  PaintingBinding.instance.imageCache.maximumSize = 120;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 48 << 20;

  HttpOverrides.global = _NeteaseImageHttpOverrides();

  print('>>> main: 开始初始化音频服务...');

  try {
    await initAudioService().timeout(const Duration(seconds: 10));
    print('>>> main: 音频服务初始化成功');
    _logStartup('main: 音频服务初始化成功');
  } catch (e, stack) {
    print('>>> main: 音频服务初始化失败: $e');
    print('>>> main: 堆栈: $stack');
    _logStartup('main: 音频服务初始化失败: $e');
  }

  print('>>> main: 设置初始化...');

  final container = ProviderContainer();
  try {
    await container
        .read(settingsInitProvider.future)
        .timeout(const Duration(seconds: 5));
    print('>>> main: 设置初始化成功');
    _logStartup('main: 设置初始化成功');
  } catch (e, stack) {
    print('>>> main: 设置初始化失败: $e');
    print('>>> main: 堆栈: $stack');
    _logStartup('main: 设置初始化失败: $e');
  }

  // 初始化 AMLL 开关
  await AmllToggleService().loadFromPrefs();
  print('>>> main: AMLL toggle loaded: ${AmllToggleService().enabled}');
  _logStartup('main: AMLL 开关已载入');

  // Route preload is an idle-time optimization controlled by settings. It
  // only prepares the cached AMLL document; no WebView or audio resource is
  // created until the lyric route is actually shown.
  if (container.read(routePreloadEnabledProvider)) {
    unawaited(AmllLyricPlayerState.prewarm());
    // 预热字体缓存：在后台完成 base64 编码，避免首次打开歌词页时阻塞 UI
    unawaited(AmllLyricPlayerState.prewarmFonts('lyricfont'));
  }

  print('>>> main: 启动应用...');
  _logStartup('main: 调用 runApp');
  runApp(UncontrolledProviderScope(container: container, child: const App()));

  WidgetsBinding.instance.addPostFrameCallback((_) {
    _logStartup('main: 首帧 postFrame 回调');
  });
}

class _NeteaseImageHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)..userAgent = null;
  }
}
