import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mintmusic/core/theme/theme_colors.dart';
import 'package:mintmusic/core/platform/app_paths.dart';
import 'package:mintmusic/core/l10n/app_locale.dart';
import 'package:mintmusic/core/l10n/l10n.dart';
import 'package:mintmusic/core/theme/theme_provider.dart';
import 'package:mintmusic/features/player/application/playback_controller.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/platform/audio_effect_service.dart';
import 'package:mintmusic/features/player/platform/audio_handler.dart';
import 'package:mintmusic/features/player/presentation/widgets/lyric_search_sheet.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/application/plugin_providers.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';

/// 假播放器 / 假音源：搜索结果带全字段（专辑 / 年份 / 时长）。
class _MemoryAudioHandler implements MusicAudioHandler {
  final _states = StreamController<PlayerState>.broadcast();
  PlayerState _playerState = PlayerState(false, ProcessingState.idle);

  @override
  void Function()? onSkipNext;
  @override
  void Function()? onSkipPrevious;
  @override
  void Function()? onStopRequested;
  @override
  Duration currentPosition = Duration.zero;

  @override
  Stream<PlayerState> get playerStateStream => _states.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration> get bufferedPositionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<int?> get audioSessionIdStream => const Stream.empty();
  @override
  Stream<String> get playbackErrorStream => const Stream.empty();
  @override
  int? get currentAudioSessionId => null;
  @override
  Duration? get currentDuration => null;
  @override
  PlayerState get currentPlayerState => _playerState;
  @override
  ProcessingState get processingState => _playerState.processingState;
  @override
  bool get playing => _playerState.playing;

  @override
  void markSessionActive() {}

  @override
  Future<void> pause() async {
    emitState(PlayerState(false, processingState));
  }

  @override
  Future<void> dispose() => _states.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  void emitState(PlayerState state) {
    _playerState = state;
    _states.add(state);
  }
}

class _FakeSourceManager implements MusicSourceManager {
  @override
  Future<List<Song>> search(
    String query, {
    String sourceId = 'wy',
    int page = 1,
    int limit = 30,
  }) async {
    // ignore: avoid_print
    print('[fake] search called: query=$query sourceId=$sourceId limit=$limit');
    return [
      Song(
        id: 'wy_1',
        title: '化风行万里',
        artist: '安少杰华',
        album: '化风行万里',
        duration: 265,
        year: 2022,
        source: 'wy',
      ),
      Song(
        id: 'wy_2',
        title: '化风行万里',
        artist: '刘艺雯',
        album: '',
        duration: 0,
        year: null,
        source: 'wy',
      ),
      Song(
        id: 'wy_3',
        title: '化风行万里',
        artist: '芸朵',
        album: '风行合集',
        duration: 300,
        year: 2023,
        source: 'wy',
      ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoIoAudioEffects implements AudioEffectService {
  @override
  Future<void> setSessionId(int? sessionId) async {}
  @override
  Future<void> apply(AudioEffectsConfig config) async {}
  @override
  Future<void> reset() async {}
  @override
  Stream<List<double>> get visualizerStream => const Stream.empty();
}

ThemeColors _colors() {
  const white = Colors.white;
  return ThemeColors(
    primary: const Color(0xFFE0B96B),
    primaryLight: white,
    primaryDark: const Color(0xFF222222),
    accent: white,
    accentLight: white,
    background: const Color(0xFF141414),
    surface: const Color(0xFF1C1C1C),
    surfaceVariant: const Color(0xFF2A2A2A),
    dialogSurface: const Color(0xFF1E1E1E),
    dialogSurfaceVariant: const Color(0xFF2A2A2A),
    textPrimary: white,
    textSecondary: const Color(0xFFB0B0B0),
    textHint: const Color(0xFF707070),
    textOnPrimary: const Color(0xFF141414),
    error: const Color(0xFFE57373),
    success: const Color(0xFF81C784),
    warning: const Color(0xFFFFB74D),
    divider: const Color(0xFF3A3A3A),
    disabled: const Color(0xFF555555),
    miniPlayerBackground: const Color(0xFF181818),
    miniPlayerProgress: const Color(0xFFE0B96B),
    coverShadow: const Color(0x00000000),
    shadow: const Color(0x00000000),
  );
}

Song _localSong() => Song(
  id: 'local_x',
  title: '化风行万里',
  artist: '刘艺雯',
  album: '化风行万里',
  duration: 265,
  year: 2022,
  source: 'local',
  filePath: 'D:/music/化风行万里.flac',
);

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('mintmusic_sheet_meta');
    AppPaths.debugRootOverride = tmp.path;
  });

  tearDown(() {
    AppPaths.debugRootOverride = null;
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  testWidgets('搜索结果卡片显示 专辑 · 年份 · 时长 元信息行', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final audio = _MemoryAudioHandler();
    final sources = _FakeSourceManager();
    final controller = PlaybackController(audio, sources, _NoIoAudioEffects());
    controller.getQualityForSource = (_) => '320k';
    addTearDown(() async {
      // 先卸载整棵树（弹框还挂着播放 / 歌词控制器的监听；ProviderScope
      // 卸载时会顺带销毁被 override 的 controller），再关假音频。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await audio.dispose();
    });

    final colors = _colors();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicSourceManagerProvider.overrideWithValue(sources),
          playbackControllerProvider.overrideWith((_) => controller),
          searchSupportedSourcesProvider.overrideWithValue([
            const SourceInfo(id: 'wy@wy-test-1.9.0', name: '网易'),
          ]),
          themeColorsProvider.overrideWithValue(colors),
        ],
        child: L10n(
          locale: AppLocale.zhCn,
          child: MaterialApp(
            home: Scaffold(
              body: Center(
                child: Builder(
                  builder: (context) {
                    return TextButton(
                      onPressed: () =>
                          showLyricSearchSheet(context, song: _localSong()),
                      child: const Text('open'),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );

    // Sheet 内部有真实文件 IO（设置读取）：必须在 runAsync 里等它完成。
    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // 结果卡片渲染出来了（三张卡片的歌名 + 输入框里也有同名文字）。
    expect(find.text('化风行万里'), findsNWidgets(4));

    // 卡片 1：专辑 / 年份 / 时长 都有 → 全部显示。
    expect(find.text('化风行万里 · 2022 · 4:25'), findsOneWidget);
    // 卡片 3：没有专辑，只有年份 + 时长。
    expect(find.text('风行合集 · 2023 · 5:00'), findsOneWidget);
    // 卡片 2：三者皆缺 → 元信息行为空文本（不显示内容但仍占一行）。
    expect(find.text(''), findsWidgets);
  });
}
