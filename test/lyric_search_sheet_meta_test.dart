import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
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
import 'package:mintmusic/shared/widgets/source_icon.dart';
import 'package:mintmusic/shared/widgets/source_selector_row.dart';

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

/// 记录每次搜索用的音源，用于验证「点平铺图标直接换源并重新搜索」。
class _FakeSourceManagerRecording extends _FakeSourceManager {
  final List<String> searchedSourceIds = [];

  @override
  Future<List<Song>> search(
    String query, {
    String sourceId = 'wy',
    int page = 1,
    int limit = 30,
  }) {
    searchedSourceIds.add(sourceId);
    return super.search(query, sourceId: sourceId, page: page, limit: limit);
  }
}

/// 搜索结果不带年份（只有专辑 id）：验证弹框会像编辑标签页那样补查年份。
class _FakeSourceManagerAlbumYear implements MusicSourceManager {
  int resolveCalls = 0;

  @override
  Future<List<Song>> search(
    String query, {
    String sourceId = 'wy',
    int page = 1,
    int limit = 30,
  }) async {
    return [
      Song(
        id: 'kw_1',
        title: 'No Limit (Extended Version)',
        artist: '2 Unlimited',
        album: 'No Limit',
        duration: 355,
        source: 'kw',
        lx: const {'albumId': 'album_9527'},
      ),
      Song(
        id: 'kw_2',
        title: 'No Limit (Remix)',
        artist: '2 Unlimited',
        album: 'Retro Megamix',
        duration: 215,
        source: 'kw',
        lx: const {'albumId': 'album_9528'},
      ),
    ];
  }

  @override
  Future<int?> resolveSongYear(Song song) async {
    resolveCalls++;
    return (song.lx?['albumId'] ?? '') == 'album_9527' ? 2014 : null;
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

    // 本地歌曲信息行（合并单行）。
    expect(find.text('专辑：化风行万里　·　年份：2022　·　时长：4:25'), findsOneWidget);
    // 卡片 1：专辑 / 年份 / 时长 各占一行。
    expect(find.text('专辑：化风行万里'), findsOneWidget);
    expect(find.text('年份：2022'), findsOneWidget);
    expect(find.text('时长：4:25'), findsOneWidget);
    // 卡片 3：只有年份 / 时长，专辑缺失显示 —。
    expect(find.text('专辑：风行合集'), findsOneWidget);
    expect(find.text('年份：2023'), findsOneWidget);
    expect(find.text('时长：5:00'), findsOneWidget);
    // 卡片 2：三者皆缺 → 显示 —。
    expect(find.text('专辑：-'), findsOneWidget);
    expect(find.text('年份：—'), findsOneWidget);
    expect(find.text('时长：—'), findsOneWidget);
  });

  testWidgets('搜索结果缺少年份时按专辑补查（与编辑标签页在线搜索一致）', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final audio = _MemoryAudioHandler();
    final sources = _FakeSourceManagerAlbumYear();
    final controller = PlaybackController(audio, sources, _NoIoAudioEffects());
    controller.getQualityForSource = (_) => '320k';
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await audio.dispose();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          musicSourceManagerProvider.overrideWithValue(sources),
          playbackControllerProvider.overrideWith((_) => controller),
          searchSupportedSourcesProvider.overrideWithValue([
            const SourceInfo(id: 'kw@kw-test-1.9.0', name: '酷我'),
          ]),
          themeColorsProvider.overrideWithValue(_colors()),
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

    await tester.runAsync(() async {
      await tester.tap(find.text('open'));
      await tester.pump();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await tester.pump();
    });
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // 第一个候选的专辑查到了年份，卡片从「年份：—」变成「年份：2014」。
    expect(find.text('年份：2014'), findsOneWidget);
    // 第二个候选的专辑查不到（负缓存），仍显示 —，不会误填其他专辑的年份。
    expect(find.text('年份：—'), findsOneWidget);
    // 两个不同专辑各查一次；同一专辑的重复候选不会重复请求。
    expect(sources.resolveCalls, 2);
  });

  testWidgets('音源超过 4 个：平铺行改为横向滚动，不溢出、鼠标可拖动', (tester) async {
    const sources = [
      SourceInfo(id: 'wy@a', name: '网易'),
      SourceInfo(id: 'tx@a', name: 'QQ'),
      SourceInfo(id: 'kg@a', name: '酷狗'),
      SourceInfo(id: 'kw@a', name: '酷我'),
      SourceInfo(id: 'mg@a', name: '咪咕'),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [themeColorsProvider.overrideWithValue(_colors())],
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 400,
                child: SourceSelectorRow(
                  sources: sources,
                  selectedId: 'wy@a',
                  onSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SourceIcon), findsNWidgets(5));
    expect(find.byKey(const ValueKey('source_dot_mg@a')), findsOneWidget);
    expect(tester.takeException(), isNull);

    // 桌面默认不允许鼠标拖动：放开后第 5 个音源才能拖进视野。
    await tester.drag(find.byType(SingleChildScrollView), const Offset(-120, 0));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Windows：音源平铺成图标，点未选中的源直接切源并重新搜索',
    (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      final audio = _MemoryAudioHandler();
      final sources = _FakeSourceManagerRecording();
      final controller = PlaybackController(
        audio,
        sources,
        _NoIoAudioEffects(),
      );
      controller.getQualityForSource = (_) => '320k';
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await audio.dispose();
      });

      const sourceList = [
        SourceInfo(id: 'wy@wy-test-1.9.0', name: '网易'),
        SourceInfo(id: 'tx@tx-test-1.9.0', name: 'QQ'),
        SourceInfo(id: 'kg@kg-test-1.9.0', name: '酷狗'),
        SourceInfo(id: 'kw@kw-test-1.9.0', name: '酷我'),
      ];

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            musicSourceManagerProvider.overrideWithValue(sources),
            playbackControllerProvider.overrideWith((_) => controller),
            searchSupportedSourcesProvider.overrideWithValue(sourceList),
            themeColorsProvider.overrideWithValue(_colors()),
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

      await tester.runAsync(() async {
        await tester.tap(find.text('open'));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 900));
        await tester.pump();
      });
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      // 四个音源全部平铺；原来的「切换音源」弹出菜单不再出现。
      expect(find.byType(SourceIcon), findsNWidgets(4));
      expect(find.byTooltip('切换音源'), findsNothing);
      expect(sources.searchedSourceIds, ['wy@wy-test-1.9.0']);

      // 点「酷我」：直接切到酷我并重新搜一次，不需要再点确认。
      await tester.runAsync(() async {
        await tester.tap(
          find.byKey(const ValueKey('source_dot_kw@kw-test-1.9.0')),
        );
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await tester.pump();
      });
      await tester.pumpAndSettle(const Duration(milliseconds: 200));

      expect(sources.searchedSourceIds, [
        'wy@wy-test-1.9.0',
        'kw@kw-test-1.9.0',
      ]);

      // 手动换过音源后，弹框 dispose 会用防抖 timer 保存「上次使用的音源」；
      // 这里主动卸载并把时钟推过去，避免测试结束时留下 pending timer。
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
    },
    skip: !Platform.isWindows,
  );
}
