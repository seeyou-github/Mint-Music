import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mintmusic/features/player/application/playback_controller.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/platform/audio_effect_service.dart';
import 'package:mintmusic/features/player/platform/audio_handler.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/data/plugin_host.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';

/// 复用 playback_retry_test 的假播放器 / 假音源：队列移除不依赖网络。
class _MemoryAudioHandler implements MusicAudioHandler {
  final _states = StreamController<PlayerState>.broadcast();
  final playedSongs = <Song?>[];
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
    loadedSong = song;
    loadedUrl = url;
    currentPosition = Duration.zero;
    emitState(PlayerState(playing, ProcessingState.ready));
  }

  @override
  Future<void> play() async {
    playedSongs.add(loadedSong);
    emitState(
      PlayerState(
        true,
        loadedUrl == null ? ProcessingState.idle : ProcessingState.ready,
      ),
    );
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
  Future<void> dispose() => _states.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemorySourceManager implements MusicSourceManager {
  @override
  Future<List<PluginMusicUrlResult>> getMusicUrlResultCandidates(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    List<PluginHost>? pluginHosts,
    void Function(String message)? onResolveError,
    bool allowMultiHost = false,
    bool allowQualityDowngrade = false,
  }) async {
    return [
      PluginMusicUrlResult(url: _url(song.id), quality: quality),
    ].where((candidate) => !excludedUrls.contains(candidate.url)).toList();
  }

  @override
  Future<PluginMusicUrlResult?> getMusicUrlResult(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    void Function(String message)? onResolveError,
    bool allowQualityDowngrade = false,
  }) async {
    final candidates = await getMusicUrlResultCandidates(
      song,
      quality: quality,
      excludedUrls: excludedUrls,
      onResolveError: onResolveError,
    );
    return candidates.firstOrNull;
  }

  @override
  Future<Song> resolveSingleSongUrl(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    void Function(String message)? onResolveError,
  }) async {
    final result = await getMusicUrlResult(
      song,
      quality: quality,
      excludedUrls: excludedUrls,
      onResolveError: onResolveError,
    );
    return result == null
        ? song
        : song.copyWith(sourceUrl: result.url, sourceQuality: quality);
  }

  @override
  List<String> getSupportedQualitiesForSourceId(String sourceId) => const [
    '128k',
    '320k',
  ];

  @override
  List<String> getQualitiesForSourceId(
    String sourceId, {
    QualityUsage usage = QualityUsage.play,
  }) => const ['128k', '320k'];

  @override
  String? dataSourcePluginIdForSong(Song song) => null;

  @override
  String? effectivePlaybackSourceForSong(Song song) => null;

  @override
  Set<String> getLoginGatedQualities(
    String sourceId, {
    QualityUsage usage = QualityUsage.play,
  }) => const <String>{};

  @override
  String sourceDisplayName(String sourceId) => sourceId;

  @override
  bool hasPluginForPlatform(String baseId) => true;

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

String _url(String id) => 'https://audio.invalid/$id.mp3';

Song _song(String id) => Song(
  id: id,
  title: id,
  artist: 'Test artist',
  album: 'Test playlist',
  duration: 180,
  source: 'wy',
);

void main() {
  late _MemoryAudioHandler audio;
  late _MemorySourceManager sources;
  late PlaybackController controller;
  late Song a;
  late Song b;
  late Song c;

  setUp(() {
    audio = _MemoryAudioHandler();
    sources = _MemorySourceManager();
    controller = PlaybackController(audio, sources, _NoIoAudioEffects());
    controller.getQualityForSource = (_) => '320k';
    a = _song('a');
    b = _song('b');
    c = _song('c');
  });

  tearDown(() async {
    controller.dispose();
    await audio.dispose();
  });

  Iterable<String?> playedIds() => audio.playedSongs.map((song) => song?.id);

  Future<void> playB() async {
    await controller.setQueue([a, b, c], startIndex: 1);
    await pumpEventQueue();
    expect(controller.playbackState.currentSong?.id, 'b');
    expect(playedIds(), ['b']);
  }

  test('移除正在播放的歌曲时自动切到下一首', () async {
    await playB();

    await controller.removeFromQueue(1);
    await pumpEventQueue();

    final state = controller.playbackState;
    expect(state.queue.map((song) => song.id), ['a', 'c']);
    expect(state.currentSong?.id, 'c');
    expect(state.currentIndex, 1);
    // 实际下发播放了下一首 c。
    expect(playedIds(), ['b', 'c']);
  });

  test('移除未播放的歌曲不打断当前播放', () async {
    await playB();

    await controller.removeFromQueue(2);
    await pumpEventQueue();

    final state = controller.playbackState;
    expect(state.queue.map((song) => song.id), ['a', 'b']);
    expect(state.currentSong?.id, 'b');
    expect(state.currentIndex, 1);
    // 没有触发新的播放。
    expect(playedIds(), ['b']);
  });

  test('移除当前歌曲且它是队尾时播放上一首', () async {
    await playB();
    await controller.removeFromQueue(2); // 先把 c 摘掉
    await pumpEventQueue();

    // 现在队列是 [a, b]，b 正在播放且是队尾：移除 b 应播 a。
    await controller.removeFromQueue(1);
    await pumpEventQueue();

    final state = controller.playbackState;
    expect(state.queue.map((song) => song.id), ['a']);
    expect(state.currentSong?.id, 'a');
    expect(state.currentIndex, 0);
    expect(playedIds(), ['b', 'a']);
  });

  test('removeSongsByIds 批量移除（含正在播放的那首）', () async {
    await playB();

    await controller.removeSongsByIds([b.id, c.id]);
    await pumpEventQueue();

    final state = controller.playbackState;
    expect(state.queue.map((song) => song.id), ['a']);
    expect(state.currentSong?.id, 'a');
    // b 正在播放，b 和 c 一起被删：直接切到下一首存活的 a，
    // 中间的 c 不会被短暂播放一遍。
    expect(playedIds(), ['b', 'a']);
  });

  test('removeSongsByIds 对不在队列中的 id 不产生任何影响', () async {
    await playB();

    await controller.removeSongsByIds(['missing']);
    await pumpEventQueue();

    final state = controller.playbackState;
    expect(state.queue.map((song) => song.id), ['a', 'b', 'c']);
    expect(state.currentSong?.id, 'b');
    expect(playedIds(), ['b']);
  });
}
