import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:mintmusic/features/player/application/playback_controller.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/player/platform/audio_effect_service.dart';
import 'package:mintmusic/features/player/platform/audio_handler.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';

/// 模拟 Windows 上 just_audio + media_kit 的播完行为：
/// - 播完后上报进度重置为 0，playWhenReady 仍为 true；
/// - just_audio 的 play() 看到 playing 已为 true 会直接返回，不发声；
/// - media_kit 自己的 play() 在 completed 时会回到开头重新播放。
class _EndOfTrackAudioHandler implements MusicAudioHandler {
  final _states = StreamController<PlayerState>.broadcast();

  PlayerState _state = PlayerState(false, ProcessingState.idle);
  Duration _position = Duration.zero;
  bool _sounding = false;

  /// 播完后 seek 失败（播放器在末尾时可能发生）。
  bool failSeekAtEnd = false;

  /// 设置后 seek 会挂起，直到测试把它完成：用来制造「停顿流程还没跑完」的窗口。
  Completer<void>? seekGate;

  bool get sounding => _sounding;

  @override
  void Function()? onSkipNext;
  @override
  void Function()? onSkipPrevious;

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
  Duration? get currentDuration => const Duration(seconds: 180);
  @override
  Duration get currentPosition => _position;
  @override
  PlayerState get currentPlayerState => _state;
  @override
  ProcessingState get processingState => _state.processingState;
  @override
  bool get playing => _state.playing;

  void emitState(PlayerState state) {
    _state = state;
    _states.add(state);
  }

  /// 歌曲自然播完：进度归零，playWhenReady 留着 true（just_audio 不会自己清）。
  void emitCompleted() {
    _position = Duration.zero;
    _sounding = false;
    emitState(PlayerState(true, ProcessingState.completed));
  }

  @override
  void markSessionActive() {}

  @override
  Future<void> setAudioSource(
    String url, {
    Song? song,
    Map<String, String>? headers,
  }) async {
    _position = Duration.zero;
    _sounding = false;
    emitState(PlayerState(_state.playing, ProcessingState.ready));
  }

  @override
  Future<void> play() async {
    // just_audio：playing 已为 true 时直接返回，播放器不会有任何变化。
    if (_state.playing) return;
    // media_kit：completed 时 play() 会自己回到开头再播。
    _position = Duration.zero;
    _sounding = true;
    emitState(PlayerState(true, ProcessingState.ready));
  }

  @override
  Future<void> pause() async {
    if (!_state.playing) return;
    _sounding = false;
    emitState(PlayerState(false, _state.processingState));
  }

  @override
  Future<void> seek(Duration position) async {
    if (failSeekAtEnd && _state.processingState == ProcessingState.completed) {
      throw StateError('seek failed at end of track');
    }
    final gate = seekGate;
    if (gate != null) await gate.future;
    _position = position;
    _sounding = false;
    emitState(PlayerState(_state.playing, ProcessingState.ready));
  }

  @override
  Future<void> dispose() => _states.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoIoSourceManager implements MusicSourceManager {
  @override
  List<String> getSupportedQualitiesForSourceId(String sourceId) => ['320k'];

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

Song _song() => const Song(
  id: 'only',
  title: 'Only song',
  artist: 'Test artist',
  album: 'Test album',
  duration: 180,
  source: 'wy',
  sourceUrl: 'https://audio.invalid/only.mp3',
  sourceQuality: '320k',
);

void main() {
  late _EndOfTrackAudioHandler audio;
  late PlaybackController controller;

  setUp(() {
    audio = _EndOfTrackAudioHandler();
    controller = PlaybackController(
      audio,
      _NoIoSourceManager(),
      _NoIoAudioEffects(),
    );
    controller.getQualityForSource = (_) => '320k';
  });

  tearDown(() async {
    controller.dispose();
    await audio.dispose();
  });

  Future<void> startSingleSongQueue() async {
    await controller.setQueue([_song()]);
    await pumpEventQueue();
    expect(audio.sounding, isTrue);
    expect(controller.playbackState.isPlaying, isTrue);
  }

  test('单曲队列播完自动停止后，点播放从开头重新播放', () async {
    await startSingleSongQueue();

    audio.emitCompleted();
    await pumpEventQueue();

    expect(controller.playbackState.isPlaying, isFalse);
    expect(audio.playing, isFalse, reason: '播完必须真的把播放器停下来');
    expect(audio.currentPosition, Duration.zero);

    await controller.togglePlayPause();
    await pumpEventQueue();

    expect(audio.sounding, isTrue, reason: '播放按钮必须真的重新出声');
    expect(controller.playbackState.isPlaying, isTrue);
    expect(audio.currentPosition, Duration.zero);
  });

  test('自动停顿里 seek 失败时，播放按钮仍然能重新播放', () async {
    await startSingleSongQueue();
    audio.failSeekAtEnd = true;

    audio.emitCompleted();
    await pumpEventQueue();

    // seek 失败不能跳过 pause，否则内部 playing 一直挂着 true，
    // 之后点播放会被 just_audio 直接忽略。
    expect(audio.playing, isFalse);
    expect(controller.playbackState.isPlaying, isFalse);

    audio.failSeekAtEnd = false;
    await controller.togglePlayPause();
    await pumpEventQueue();

    expect(audio.sounding, isTrue);
    expect(controller.playbackState.isPlaying, isTrue);
  });

  test('自动停顿进行中点播放，不会被随后的停顿流程吞掉', () async {
    await startSingleSongQueue();

    final gate = Completer<void>();
    audio.seekGate = gate;
    audio.emitCompleted();
    await pumpEventQueue();
    expect(controller.playbackState.isPlaying, isFalse);

    final click = controller.togglePlayPause();
    await pumpEventQueue();

    audio.seekGate = null;
    gate.complete();
    await click;
    await pumpEventQueue();

    expect(audio.sounding, isTrue, reason: '用户的播放操作不能被停顿流程覆盖');
    expect(controller.playbackState.isPlaying, isTrue);
  });
}
