import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mintmusic/features/player/application/playback_controller.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/platform/audio_effect_service.dart';
import 'package:mintmusic/features/player/platform/audio_handler.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';

/// 只记录「加载了哪个地址」的播放器替身。
class _FakeAudioHandler implements MusicAudioHandler {
  final _states = StreamController<PlayerState>.broadcast();
  final loads = <({Song? song, String url})>[];
  final failingUrls = <String>{};
  Song? loadedSong;
  String? loadedUrl;
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
  final _positions = StreamController<Duration>.broadcast();

  @override
  Stream<Duration> get positionStream => _positions.stream;

  void emitPosition(Duration position) => _positions.add(position);
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
  Duration? get currentDuration =>
      loadedSong == null ? null : Duration(seconds: loadedSong!.duration);
  @override
  PlayerState get currentPlayerState => _playerState;
  @override
  ProcessingState get processingState => _playerState.processingState;
  @override
  bool get playing => _playerState.playing;

  void emitState(PlayerState state) {
    _playerState = state;
    _states.add(state);
  }

  @override
  void markSessionActive() {}

  @override
  Future<void> setAudioSource(
    String url, {
    Song? song,
    Map<String, String>? headers,
    Duration? initialPosition,
  }) async {
    loads.add((song: song, url: url));
    if (failingUrls.contains(url)) {
      emitState(PlayerState(false, ProcessingState.idle));
      throw StateError('Cannot load $url');
    }
    loadedSong = song;
    loadedUrl = url;
    currentPosition = Duration.zero;
    emitState(PlayerState(false, ProcessingState.ready));
  }

  @override
  Future<void> play() async {
    if (loadedUrl == null) return;
    emitState(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    emitState(PlayerState(false, processingState));
  }

  @override
  Future<void> seek(Duration position) async {
    currentPosition = position;
    emitState(PlayerState(playing, ProcessingState.ready));
  }

  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {
    await _states.close();
    await _positions.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSourceManager implements MusicSourceManager {
  int resolveCalls = 0;

  @override
  Future<List<PluginMusicUrlResult>> getMusicUrlResultCandidates(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    List<dynamic>? pluginHosts,
    void Function(String message)? onResolveError,
    bool allowMultiHost = false,
    bool allowQualityDowngrade = false,
  }) async {
    resolveCalls++;
    return [
      PluginMusicUrlResult(url: 'https://audio.invalid/${song.id}.mp3'),
    ];
  }

  @override
  List<String> getQualitiesForSourceId(
    String sourceId, {
    QualityUsage usage = QualityUsage.play,
  }) => const ['128k', '320k'];

  @override
  Set<String> getLoginGatedQualities(
    String sourceId, {
    QualityUsage usage = QualityUsage.play,
  }) => const <String>{};

  @override
  String? dataSourcePluginIdForSong(Song song) => null;

  @override
  String? effectivePlaybackSourceForSong(Song song) => null;

  @override
  String sourceDisplayName(String sourceId) => sourceId;

  @override
  Future<String?> getPic(
    Song song, {
    Set<String> excludedUrls = const <String>{},
    bool refresh = false,
  }) async => null;

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

Song _song(String id) => Song(
  id: id,
  title: id,
  artist: 'Test artist',
  album: 'Test playlist',
  duration: 180,
  source: 'kw',
);

void main() {
  late _FakeAudioHandler audio;
  late _FakeSourceManager sources;
  late PlaybackController controller;

  setUp(() {
    audio = _FakeAudioHandler();
    sources = _FakeSourceManager();
    controller = PlaybackController(audio, sources, _NoIoAudioEffects());
    controller.getQualityForSource = (_) => '320k';
  });

  tearDown(() async {
    controller.dispose();
    await audio.dispose();
  });

  test('收藏歌曲命中缓存时直接播本地文件，不再解析在线地址', () async {
    String? seenQuality;
    controller.resolveCachedAudioFile = (song, quality) async {
      seenQuality = quality;
      return 'D:/cache/${song.id}.mp3';
    };

    await controller.setQueue([_song('s1')], startIndex: 0);
    await Future<void>.delayed(Duration.zero);

    expect(audio.loads.single.url, 'D:/cache/s1.mp3');
    expect(sources.resolveCalls, 0, reason: '有缓存就不该联网解析');
    expect(seenQuality, '320k', reason: '要带本次音质，切换音质后不能拿旧缓存冒充');
    expect(controller.playbackState.currentSong?.id, 's1');
  });

  test('缓存文件放不出来时删掉记录并回退在线播放', () async {
    final discarded = <String>[];
    controller.resolveCachedAudioFile = (song, quality) async =>
        'D:/cache/${song.id}.mp3';
    controller.discardCachedAudioFile = (songId) async {
      discarded.add(songId);
    };
    audio.failingUrls.add('D:/cache/s1.mp3');

    await controller.setQueue([_song('s1')], startIndex: 0);
    await Future<void>.delayed(Duration.zero);

    expect(audio.loads.map((load) => load.url), [
      'D:/cache/s1.mp3',
      'https://audio.invalid/s1.mp3',
    ]);
    expect(discarded, ['s1']);
    expect(sources.resolveCalls, 1);
  });

  test('播到总时长一半时请求一次缓存，之后不重复', () async {
    final requested = <String>[];
    controller.onSongCacheRequested = (song) => requested.add(song.id);

    await controller.setQueue([_song('s1')], startIndex: 0);
    await Future<void>.delayed(Duration.zero);

    // 180 秒的歌：60 秒（1/3）不触发。
    audio.emitPosition(const Duration(seconds: 60));
    await Future<void>.delayed(Duration.zero);
    expect(requested, isEmpty);

    // 90 秒（恰好一半）触发一次。
    audio.emitPosition(const Duration(seconds: 90));
    await Future<void>.delayed(Duration.zero);
    expect(requested, ['s1']);

    // 继续往后播不会重复请求。
    audio.emitPosition(const Duration(seconds: 120));
    audio.emitPosition(const Duration(seconds: 170));
    await Future<void>.delayed(Duration.zero);
    expect(requested, ['s1']);
  });

  test('播完时兜底触发一次（位置流没跑到一半也能缓存）', () async {
    final requested = <String>[];
    controller.onSongCacheRequested = (song) => requested.add(song.id);

    await controller.setQueue([_song('s1')], startIndex: 0);
    await Future<void>.delayed(Duration.zero);

    audio.emitState(PlayerState(true, ProcessingState.ready));
    await Future<void>.delayed(Duration.zero);
    audio.emitState(PlayerState(false, ProcessingState.completed));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(requested, ['s1']);
  });
}
