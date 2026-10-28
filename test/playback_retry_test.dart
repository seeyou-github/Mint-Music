import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mintmusic/features/player/application/playback_controller.dart';
import 'package:mintmusic/features/player/domain/models/play_mode.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/platform/audio_effect_service.dart';
import 'package:mintmusic/features/player/platform/audio_handler.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/data/plugin_host.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';

// A failed load leaves the previous source installed, so play() still plays it.
class _MemoryAudioHandler implements MusicAudioHandler {
  final _states = StreamController<PlayerState>.broadcast();
  final loads = <({Song? song, String url})>[];
  final playedSongs = <Song?>[];
  final playedUrls = <String?>[];
  final failingUrls = <String>{};
  Song? loadedSong;
  String? loadedUrl;
  PlayerState _playerState = PlayerState(false, ProcessingState.idle);

  @override
  void Function()? onSkipNext;
  @override
  void Function()? onSkipPrevious;
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

  // Delayed snapshots must not overwrite the player's newer synchronous getters.
  void emitLateState(PlayerState state) => _states.add(state);

  @override
  void markSessionActive() {}

  @override
  Future<void> setAudioSource(
    String url, {
    Song? song,
    Map<String, String>? headers,
  }) async {
    loads.add((song: song, url: url));
    emitState(PlayerState(playing, ProcessingState.loading));
    if (failingUrls.contains(url)) {
      emitState(PlayerState(false, ProcessingState.idle));
      throw StateError('Cannot load $url');
    }
    loadedSong = song;
    loadedUrl = url;
    currentPosition = Duration.zero;
    emitState(PlayerState(playing, ProcessingState.ready));
  }

  @override
  Future<void> play() async {
    playedSongs.add(loadedSong);
    playedUrls.add(loadedUrl);
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
    emitState(
      PlayerState(
        playing,
        processingState == ProcessingState.completed
            ? ProcessingState.ready
            : processingState,
      ),
    );
  }

  @override
  Future<void> dispose() => _states.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MemorySourceManager implements MusicSourceManager {
  final requests = <({Song song, String quality})>[];
  final unavailable = <String>{};
  final results = <String, PluginMusicUrlResult>{};
  bool throwOnUnavailable = false;
  Future<List<PluginMusicUrlResult>>? pendingFallback;
  Completer<void>? fallbackStarted;

  @override
  Future<List<PluginMusicUrlResult>> getMusicUrlResultCandidates(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    bool includeQualityFallbacks = false,
    List<PluginHost>? pluginHosts,
    void Function(String message)? onResolveError,
  }) async {
    requests.add((song: song, quality: quality));
    if (quality == '128k' && pendingFallback != null) {
      fallbackStarted?.complete();
      return pendingFallback!;
    }
    if (unavailable.contains(song.id)) {
      if (throwOnUnavailable) throw StateError('Resolver offline');
      onResolveError?.call('Resolver offline');
      return const [];
    }
    final result =
        results[song.id] ??
        PluginMusicUrlResult(url: _url(song.id), quality: quality);
    return excludedUrls.contains(result.url) ? const [] : [result];
  }

  @override
  Future<PluginMusicUrlResult?> getMusicUrlResult(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    void Function(String message)? onResolveError,
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
  List<String> getMusicQualityFallbacks(Song song, String requested) => [
    requested,
    if (requested == '320k') '128k',
  ];

  @override
  List<String> getSupportedQualitiesForSourceId(String sourceId) => [
    '128k',
    '320k',
  ];

  @override
  String? dataSourcePluginIdForSong(Song song) => null;

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

const _localPath = 'D:/memory-only/b.flac';
final _localB = _song('b').copyWith(
  source: 'local',
  sourceUrl: _localPath,
  filePath: _localPath,
  sourceQuality: 'flac',
);

void main() {
  late _MemoryAudioHandler audio;
  late _MemorySourceManager sources;
  late PlaybackController controller;
  late List<String> messages;
  late Song a;
  late Song b;
  late Song c;

  setUp(() {
    audio = _MemoryAudioHandler();
    sources = _MemorySourceManager();
    controller = PlaybackController(audio, sources, _NoIoAudioEffects());
    controller.setAutoQualityDowngrade(false);
    controller.getQualityForSource = (_) => '320k';
    messages = [];
    controller.onMessage = (message, {backgroundColor}) =>
        messages.add(message);
    a = _song('a');
    b = _song('b');
    c = _song('c');
  });

  tearDown(() async {
    controller.dispose();
    await audio.dispose();
  });

  Iterable<String?> playedIds() => audio.playedSongs.map((song) => song?.id);

  void expectSelectedB({required bool playing}) {
    final state = controller.playbackState;
    expect(state.queue.map((song) => song.id), ['a', 'b', 'c']);
    expect(state.currentSong?.id, 'b');
    expect(state.currentIndex, 1);
    expect(state.isLoading, isFalse);
    expect(state.isPlaying, playing);
    expect(audio.playing, playing);
  }

  Future<void> startA() async {
    await controller.setQueue([a]);
    await pumpEventQueue();
    expect(playedIds(), ['a']);
    expect(audio.loadedSong?.id, 'a');
    expect(audio.loadedUrl, _url('a'));
    expect(controller.playbackState.isPlaying, isTrue);
  }

  void expectOnlyBRequestedSince(int count) {
    final retryRequests = sources.requests.skip(count).toList();
    expect(retryRequests, isNotEmpty, reason: 'Retry must resolve b again');
    expect(retryRequests.map((request) => request.song.id), everyElement('b'));
  }

  for (final mode in PlayMode.values) {
    test(
      '${mode.name}: playlist failure retries selected b, never a/c',
      () async {
        await controller.setPlayMode(mode);
        await startA();
        sources.unavailable.add('b');
        await controller.setQueue([a, b, c], startIndex: 1);
        await pumpEventQueue();
        expectSelectedB(playing: false);
        expect(playedIds(), ['a']);
        expect(
          audio.loadedSong?.id,
          'a',
          reason: 'Old source is still installed',
        );
        expect(messages, isNotEmpty);

        final beforeRetry = sources.requests.length;
        sources.unavailable.remove('b');
        await controller.togglePlayPause();
        await pumpEventQueue();

        expectOnlyBRequestedSince(beforeRetry);
        expect(playedIds(), ['a', 'b']);
        expect(audio.loads.map((load) => load.song?.id), ['a', 'b']);
        expect(audio.playedUrls, [_url('a'), _url('b')]);
        expectSelectedB(playing: true);
        expect(controller.playbackState.playMode, mode);

        // A successful retry must clear the reload flag: pause/resume is cheap.
        final resolutions = sources.requests.length;
        final loads = audio.loads.length;
        await controller.togglePlayPause();
        await pumpEventQueue();
        expectSelectedB(playing: false);
        await controller.togglePlayPause();
        await pumpEventQueue();
        expectSelectedB(playing: true);
        expect(sources.requests, hasLength(resolutions));
        expect(audio.loads, hasLength(loads));
        expect(playedIds(), ['a', 'b', 'b']);
      },
    );
  }

  test(
    'repeated resolver exceptions keep b selected until a retry succeeds',
    () async {
      await startA();
      sources.throwOnUnavailable = true;
      sources.unavailable.add('b');
      await controller.setQueue([a, b, c], startIndex: 1);
      await pumpEventQueue();
      expectSelectedB(playing: false);

      for (var attempt = 0; attempt < 2; attempt++) {
        final beforeRetry = sources.requests.length;
        await controller.togglePlayPause();
        await pumpEventQueue();
        expectOnlyBRequestedSince(beforeRetry);
        expectSelectedB(playing: false);
        expect(playedIds(), ['a']);
        expect(audio.loads.map((load) => load.song?.id), ['a']);
      }

      final beforeSuccess = sources.requests.length;
      sources.unavailable.remove('b');
      await controller.togglePlayPause();
      await pumpEventQueue();
      expectOnlyBRequestedSince(beforeSuccess);
      expectSelectedB(playing: true);
      expect(playedIds(), ['a', 'b']);
    },
  );

  for (final cached in [false, true]) {
    test(
      'failed ${cached ? 'cached' : 'resolved'} URL is cleared and b gets a fresh URL',
      () async {
        const expired = PluginMusicUrlResult(
          url: 'https://audio.invalid/b-expired.mp3',
          quality: '320k',
          headers: {'X-Test-Token': 'expired'},
        );
        const fresh = PluginMusicUrlResult(
          url: 'https://audio.invalid/b-fresh.mp3',
          quality: '320k',
          headers: {'X-Test-Token': 'fresh'},
        );
        await startA();
        if (cached) {
          b = b.copyWith(
            sourceUrl: expired.url,
            sourceHeaders: expired.headers,
            sourceQuality: expired.quality,
          );
        }
        sources.results['b'] = expired;
        audio.failingUrls.add(expired.url);
        await controller.setQueue([a, b, c], startIndex: 1);
        await pumpEventQueue();
        expectSelectedB(playing: false);
        expect(audio.loadedSong?.id, 'a');
        expect(playedIds(), ['a']);
        expect(audio.loads.last.url, expired.url);
        expect(audio.loads.last.song?.sourceHeaders, expired.headers);
        for (final song in [
          controller.playbackState.currentSong!,
          controller.playbackState.queue[1],
        ]) {
          expect(
            song.sourceUrl,
            isNull,
            reason: 'Failed remote URL must be cleared',
          );
          expect(song.sourceHeaders, isNull);
          expect(song.sourceQuality, isNull);
        }

        final beforeRetry = sources.requests.length;
        sources.results['b'] = fresh;
        await controller.togglePlayPause();
        await pumpEventQueue();
        expectOnlyBRequestedSince(beforeRetry);
        final retrySong = sources.requests.last.song;
        expect(retrySong.sourceUrl, isNull);
        expect(retrySong.sourceHeaders, isNull);
        expect(retrySong.sourceQuality, isNull);
        expect(audio.loads.map((load) => load.url), [
          _url('a'),
          expired.url,
          fresh.url,
        ]);
        expect(audio.loadedSong?.sourceHeaders, fresh.headers);
        expect(audio.loadedSong?.sourceQuality, fresh.quality);
        expect(audio.playedUrls, [_url('a'), fresh.url]);
        expect(playedIds(), ['a', 'b']);
        expectSelectedB(playing: true);
      },
    );
  }

  test(
    'local load failure keeps the path and retries the same file without resolving',
    () async {
      await startA();
      audio.failingUrls.add(_localPath);
      await controller.setQueue([a, _localB, c], startIndex: 1);
      await pumpEventQueue();
      expectSelectedB(playing: false);
      expect(audio.loadedSong?.id, 'a');
      expect(playedIds(), ['a']);
      expect(
        messages,
        isNotEmpty,
        reason: 'Local failures use common failure cleanup',
      );
      for (final song in [
        controller.playbackState.currentSong!,
        controller.playbackState.queue[1],
      ]) {
        expect(song.sourceUrl, _localPath);
        expect(song.filePath, _localPath);
      }

      final beforeRetry = sources.requests.length;
      audio.failingUrls.remove(_localPath);
      await controller.togglePlayPause();
      await pumpEventQueue();
      expect(sources.requests, hasLength(beforeRetry));
      expect(audio.loads.map((load) => load.url), [
        _url('a'),
        _localPath,
        _localPath,
      ]);
      expect(audio.loads.last.song?.filePath, _localPath);
      expect(audio.playedUrls, [_url('a'), _localPath]);
      expect(playedIds(), ['a', 'b']);
      expectSelectedB(playing: true);
    },
  );

  test(
    'ordinary pause/resume neither resolves nor reloads a successful source',
    () async {
      await controller.setQueue([a, b, c], startIndex: 1);
      await pumpEventQueue();
      expectSelectedB(playing: true);
      final loaded = audio.loadedSong;
      final resolutions = sources.requests.length;
      final loads = audio.loads.length;
      await controller.seek(const Duration(seconds: 42));
      await controller.togglePlayPause();
      await pumpEventQueue();
      expectSelectedB(playing: false);
      await controller.togglePlayPause();
      await pumpEventQueue();
      expectSelectedB(playing: true);
      expect(identical(audio.loadedSong, loaded), isTrue);
      expect(audio.currentPosition, const Duration(seconds: 42));
      expect(sources.requests, hasLength(resolutions));
      expect(audio.loads, hasLength(loads));
      expect(playedIds(), ['b', 'b']);
    },
  );

  test(
    'switching quality after failure clears retry state and keeps position',
    () async {
      await startA();
      sources.unavailable.add('b');
      await controller.setQueue([a, b, c], startIndex: 1);
      await pumpEventQueue();
      expectSelectedB(playing: false);
      await controller.seek(const Duration(seconds: 42));
      sources.unavailable.remove('b');
      sources.results['b'] = const PluginMusicUrlResult(
        url: 'https://audio.invalid/b-128k.mp3',
        quality: '128k',
      );

      await controller.setQuality('128k');
      await pumpEventQueue();
      expectSelectedB(playing: false);
      expect(controller.playbackState.currentQuality, '128k');
      final resolutions = sources.requests.length;
      final loads = audio.loads.length;

      await controller.togglePlayPause();
      await pumpEventQueue();

      expectSelectedB(playing: true);
      expect(playedIds(), ['a', 'b']);
      expect(sources.requests, hasLength(resolutions));
      expect(audio.loads, hasLength(loads));
      expect(audio.currentPosition, const Duration(seconds: 42));
      expect(controller.playbackState.position, const Duration(seconds: 42));
    },
  );

  test(
    'obsolete quality fallback failure does not stop newly selected c',
    () async {
      final fallback = Completer<List<PluginMusicUrlResult>>();
      final started = Completer<void>();
      sources
        ..unavailable.add('b')
        ..pendingFallback = fallback.future
        ..fallbackStarted = started;
      controller.setAutoQualityDowngrade(true);
      final oldRequest = controller.setQueue([a, b, c], startIndex: 1);
      await started.future;
      await controller.playSongAt(2);
      await pumpEventQueue();
      expect(playedIds(), ['c']);
      expect(controller.playbackState.currentSong?.id, 'c');
      expect(controller.playbackState.isPlaying, isTrue);

      fallback.complete([]);
      await oldRequest;
      await pumpEventQueue();

      expect(controller.playbackState.currentSong?.id, 'c');
      expect(controller.playbackState.currentIndex, 2);
      expect(controller.playbackState.isPlaying, isTrue);
      expect(controller.playbackState.isLoading, isFalse);
      expect(audio.playing, isTrue);
      expect(messages, isEmpty);
      final loads = audio.loads.length;
      await controller.togglePlayPause();
      await controller.togglePlayPause();
      await pumpEventQueue();
      expect(playedIds(), ['c', 'c']);
      expect(audio.loads, hasLength(loads));
    },
  );

  test(
    'failed selection retries even if old player still reports playing',
    () async {
      await startA();
      sources.unavailable.add('b');
      await controller.setQueue([a, b, c], startIndex: 1);
      await pumpEventQueue();
      audio.emitState(PlayerState(true, ProcessingState.ready));
      await pumpEventQueue();
      expect(controller.playbackState.isPlaying, isFalse);
      sources.unavailable.remove('b');

      await controller.togglePlayPause();
      await pumpEventQueue();

      expectSelectedB(playing: true);
      expect(playedIds(), ['a', 'b']);
      expect(audio.loadedSong?.id, 'b');
    },
  );

  test(
    'late old-player loading/ready/buffering events cannot revive failed b',
    () async {
      await startA();
      sources.unavailable.add('b');
      await controller.setQueue([a, b, c], startIndex: 1);
      await pumpEventQueue();
      final resolutions = sources.requests.length;
      for (final oldState in [
        PlayerState(false, ProcessingState.loading),
        PlayerState(true, ProcessingState.ready),
        PlayerState(true, ProcessingState.buffering),
        PlayerState(false, ProcessingState.idle),
      ]) {
        audio.emitLateState(oldState);
        await pumpEventQueue();
        expectSelectedB(playing: false);
        expect(playedIds(), ['a']);
        expect(sources.requests, hasLength(resolutions));
      }
    },
  );

  for (final mode in PlayMode.values) {
    test(
      '${mode.name}: ignores old completed, accepts natural completion after retry',
      () async {
        await controller.setPlayMode(mode);
        await startA();
        sources.unavailable.add('b');
        await controller.setQueue([a, b, c], startIndex: 1);
        await pumpEventQueue();
        final beforeCompleted = sources.requests.length;
        audio.emitState(PlayerState(false, ProcessingState.completed));
        // Allow both debounce and resolver retry if shuffle incorrectly picks b.
        await Future<void>.delayed(const Duration(seconds: 1));
        await pumpEventQueue();
        expectSelectedB(playing: false);
        expect(sources.requests, hasLength(beforeCompleted));
        expect(audio.loads.map((load) => load.song?.id), ['a']);
        expect(playedIds(), ['a']);

        sources.unavailable.remove('b');
        await controller.togglePlayPause();
        await pumpEventQueue();
        expectSelectedB(playing: true);
        expect(playedIds(), ['a', 'b']);
        final loadsBeforeNaturalEnd = audio.loads.length;
        final resolutionsBeforeNaturalEnd = sources.requests.length;

        // ExoPlayer can keep playWhenReady=true at natural completion.
        audio.currentPosition = const Duration(seconds: 180);
        audio.emitState(PlayerState(true, ProcessingState.completed));
        await Future<void>.delayed(const Duration(seconds: 1));
        await pumpEventQueue();
        expect(audio.playedSongs, hasLength(3));
        final state = controller.playbackState;
        expect(state.isPlaying, isTrue);
        expect(state.isLoading, isFalse);
        expect(state.playMode, mode);
        expect(state.queue.map((song) => song.id), ['a', 'b', 'c']);
        expect(state.currentSong?.id, audio.playedSongs.last?.id);
        expect(state.queue[state.currentIndex].id, audio.playedSongs.last?.id);
        switch (mode) {
          case PlayMode.listLoop:
            expect(playedIds(), ['a', 'b', 'c']);
            expect(state.currentIndex, 2);
          case PlayMode.singleLoop:
            expect(playedIds(), ['a', 'b', 'b']);
            expect(state.currentIndex, 1);
            expect(audio.currentPosition, Duration.zero);
            expect(audio.loads, hasLength(loadsBeforeNaturalEnd));
            expect(sources.requests, hasLength(resolutionsBeforeNaturalEnd));
          case PlayMode.shuffle:
            expect(audio.playedSongs.last?.id, isIn(['a', 'b', 'c']));
            expect(audio.loads, hasLength(loadsBeforeNaturalEnd + 1));
        }
      },
    );
  }

  for (final local in [false, true]) {
    test(
      'restored ${local ? 'local' : 'remote'} session loads selected b on first play',
      () async {
        // Saved remote sessions have their transient URLs removed by the store.
        expect(
          controller.restoreSession(
            queue: [a, local ? _localB : b, c],
            index: 1,
            quality: local ? 'flac' : '320k',
          ),
          isTrue,
        );
        expectSelectedB(playing: false);
        expect(audio.loads, isEmpty);
        expect(audio.playedSongs, isEmpty);
        expect(sources.requests, isEmpty);
        await controller.togglePlayPause();
        await pumpEventQueue();
        expectSelectedB(playing: true);
        expect(playedIds(), ['b']);
        expect(audio.loads.map((load) => load.song?.id), ['b']);
        expect(audio.playedUrls, [local ? _localPath : _url('b')]);
        expect(
          sources.requests.map((request) => request.song.id),
          local ? [] : ['b'],
        );
      },
    );
  }
}
