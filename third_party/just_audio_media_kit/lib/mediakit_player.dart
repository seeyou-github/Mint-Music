library just_audio_media_kit;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:just_audio_platform_interface/just_audio_platform_interface.dart';
import 'package:logging/logging.dart';
import 'package:media_kit/media_kit.dart';
import 'src/set_property.dart';

/// An [AudioPlayerPlatform] which wraps `package:media_kit`'s [Player]
class MediaKitPlayer extends AudioPlayerPlatform {
  static const kErrorCode = 1;

  /// `package:media_kit`'s [Player]
  late final Player _player;

  /// The subscriptions that have to be disposed
  late final List<StreamSubscription> _streamSubscriptions;

  final _readyCompleter = Completer<void>();

  /// Completes when the player is ready
  Future<void> ready() => _readyCompleter.future;

  static final _logger = Logger('MediaKitPlayer');

  final _eventController = StreamController<PlaybackEventMessage>.broadcast();
  final _dataController = StreamController<PlayerDataMessage>.broadcast();

  ProcessingStateMessage _processingState = ProcessingStateMessage.idle;
  Duration _bufferedPosition = Duration.zero;
  Duration _position = Duration.zero;
  Duration? _duration;
  bool _playing = false;
  bool _mediaOpened = false;
  int? _errorCode;
  String? _errorMessage;
  Completer<Duration?>? _loadCompleter;

  /// The index that's currently playing
  int _currentIndex = 0;

  /// [LoadRequest.initialPosition] or [seek] request before [Player.play] was called and/or finished loading.
  Duration? _setPosition;

  Media? get _currentMedia {
    var medias = _player.state.playlist.medias;
    if (medias.isEmpty) return null;
    return medias[_player.state.playlist.index];
  }

  /// 首次 `load()` 之前必须完成的 mpv 属性写入（见 [_enableMp3FastSeek]）。
  ///
  /// 用 `late final` 而不是在构造函数里 `unawaited`：属性写入是异步的，宿主
  /// 紧接着 `load()` 时可能抢在它前面把音源 open 了，那一次 open 拿到的还是
  /// mpv 默认 seek 行为（拖动又会整首下载）。放进 `load()` 里 await 才确定。
  late final Future<void> _fastSeekReady = _enableMp3FastSeek();

  MediaKitPlayer(super.id) {
    _player = Player(
        configuration: PlayerConfiguration(
      pitch: JustAudioMediaKit.pitch,
      protocolWhitelist: JustAudioMediaKit.protocolWhitelist,
      title: JustAudioMediaKit.title,
      bufferSize: JustAudioMediaKit.bufferSize,
      logLevel: JustAudioMediaKit.mpvLogLevel,
      ready: () => _readyCompleter.complete(),
    ));

    if (JustAudioMediaKit.prefetchPlaylist) {
      setProperty(_player, 'prefetch-playlist', 'yes');
    }

    // Mint Music 本地补丁：mpv 默认会自动加载同目录同名的外部文件
    // （`sub-auto` 把 .lrc/.srt 当字幕、`cover-art-auto` 把 .jpg 当封面）。
    // .lrc 侧栏歌词不是 mpv 能解析的字幕格式，mpv 报
    // `Can not open external file`；media_kit 又把 cplayer 的 error 日志一律
    // 当致命错误，正在加载的媒体被改回 idle，just_audio 的 setAudioSource
    // 就永远不返回（表现为带 .lrc 的本地歌曲「播放歌曲失败」）。App 自己
    // 解析歌词，不需要 mpv 加载外部文件，这里直接关掉这两种自动加载。
    unawaited(setProperty(_player, 'sub-auto', 'no'));
    unawaited(setProperty(_player, 'cover-art-auto', 'no'));

    // Mint Music 本地补丁：media_kit 默认 `cache-on-disk=yes`，会把 demuxer
    // 缓存（上限 = `demuxer-max-bytes`，本项目 4MB）写到系统临时目录下的
    // mpv 缓存文件里。本项目只要运行内存缓存（见 MemoryCacheAudioSource），
    // 音频数据本来就在内存，不需要 mpv 再落一份盘。关掉后 `cache=yes` 仍在，
    // 前向 / 回退窗口照旧，只是不再写文件。
    unawaited(setProperty(_player, 'cache-on-disk', 'no'));

    // Mint Music 本地补丁：MP3 的 seek 默认不走 HTTP Range 请求，而是
    // 「顺序读转发」。mp3 demuxer 没有 read_timestamp，ffmpeg 的 `mp3_seek`
    // 在无 Xing TOC 且未开 AVFMT_FLAG_FAST_SEEK 时直接返回 -1，av_seek_frame
    // 落到 seek_frame_generic —— 从已索引的最后一帧起顺序读取数据包直到目标
    // 时间戳，中间的字节全部从 HTTP 连接下载后丢弃（实测不发 Range 请求）。
    // 表现为暂停状态把进度条拖到 11 分钟时，先以下载速度把当前位置到 11
    // 分钟之间（极端情况下整首歌）全部拉完；而已下载的部分不会保留
    // （demuxer 缓存上限只有 demuxer-max-bytes=4MB），点播放 / 再拖动又要
    // 重新下载——「拖动 = 全量下载 + 全部作废」。
    //
    // `fflags=+fastseek` 让 mp3_seek 走「CBR 字节估算 + mp3_sync 帧同步
    // （目标 ±4KB 扫描）」，底层 avio_seek 触发 mp_seek → 真正的 Range 请求：
    // 拖动只下载目标位置起的一小段（配合 demuxer-max-bytes=4MB 即「拖动仅
    // 缓存 4MB」），缓存完成后再点播放 / 在缓存窗口内拖动都不会再触发下载。
    // 代价是 VBR 文件的 seek 位置可能有偏差（CBR 按平均码率估算），换来
    // seek 只花 4MB 流量；在线音乐（128k/320k CBR）不受影响。
    //
    // media_kit 初始化时已写入一份 `demuxer-lavf-o`（seg_max_retry / strict /
    // allowed_extensions / protocol_whitelist，见 media_kit real.dart）。
    // NativePlayer 的初始化 Completer 在这份属性写完之后才 complete
    // （idle-active 事件里 `await future`，future 即整个 _create 流程），
    // 所以这里重设的值一定落在 media_kit 默认值之后（后写覆盖先写）。
    // 具体写法见 [_enableMp3FastSeek]：整体重建 + 追加，不能读现值再追加
    // （mpv 读属性会剥掉方括号，见方法内注释）。
    //
    // 注意不要在这里 `unawaited` 就完事：属性写入是跨进程/跨线程的异步调用，
    // 宿主紧接着调用 `load()` 时可能先把音源 open 了，那一次 open 就还是默认
    // 行为（拖动又变回整首下载）。改为 `load()` 里 await 这个 late final，
    // 见 [_fastSeekReady]。

    _streamSubscriptions = [
      _player.stream.duration.listen((duration) {
        if (_currentMedia?.extras?['overrideDuration'] != null) return;

        if (_setPosition != null && duration.inSeconds > 0) {
          unawaited(_player.seek(_setPosition!));
          _setPosition = null;
        }
        _updateDuration(duration);
        _updatePlaybackEvent();
      }),
      _player.stream.position.listen((position) {
        _position = position;
        final start = _currentMedia?.start;
        if (start != null) _position -= start;
        if (_position < Duration.zero) _position = Duration.zero;
        _updatePlaybackEvent();
      }),
      _player.stream.buffering.listen((isBuffering) {
        final start = _currentMedia?.start;
        if (!isBuffering && start != null && _bufferedPosition <= start) {
          // Not ready yet, will be triggered by _player.stream.buffer
          return;
        }
        if (_processingState == ProcessingStateMessage.loading) {
          if (!isBuffering && _mediaOpened) {
            _processingState = ProcessingStateMessage.ready;
            if (_loadCompleter?.isCompleted != true) {
              _loadCompleter?.complete(_duration);
            }
          }
        } else if (_processingState != ProcessingStateMessage.completed ||
            isBuffering) {
          _processingState = isBuffering
              ? ProcessingStateMessage.buffering
              : ProcessingStateMessage.ready;
          if (_duration == null) {
            _updateDuration(_player.state.duration);
          }
        }
        _errorCode = null;
        _errorMessage = null;
        _updatePlaybackEvent();
      }),
      _player.stream.buffer.listen((buffer) {
        _bufferedPosition = buffer;
        // Detect ready for clipping audio source
        final start = _currentMedia?.start;
        if (!_player.state.buffering &&
            _mediaOpened &&
            start != null &&
            _bufferedPosition > start) {
          _processingState = ProcessingStateMessage.ready;
          if (_loadCompleter?.isCompleted != true) {
            _loadCompleter?.complete(_duration);
          }
        }
        _updatePlaybackEvent();
      }),
      _player.stream.volume.listen((volume) {
        _dataController.add(PlayerDataMessage(volume: volume / 100.0));
      }),
      _player.stream.completed.listen((completed) {
        _bufferedPosition = _position = Duration.zero;
        if (completed &&
            // is at the end of the [Playlist]
            _currentIndex == _player.state.playlist.medias.length - 1 &&
            // is not looping (technically this shouldn't be fired if the player is looping)
            _player.state.playlistMode == PlaylistMode.none) {
          _processingState = ProcessingStateMessage.completed;
        }
        _errorCode = null;
        _errorMessage = null;

        _updatePlaybackEvent();
      }),
      _player.stream.error.listen((error) {
        // Mint Music 本地补丁：外部文件（侧栏歌词、封面等）打不开不代表正片
        // 失败，不能据此把当前媒体判成加载失败（见构造函数里关闭 sub-auto /
        // cover-art-auto 的说明；这里兜底旧版 mpv 不认这两个属性的情况）。
        if (error.startsWith('Can not open external file')) {
          _logger.warning('Ignored external file error: $error');
          return;
        }
        // Mint Music 本地补丁 2：只有「打开 / 加载失败」类错误才致命。
        //
        // mpv 播放中遇到损坏帧只丢那一帧、播放继续走到 eof。典型：酷我车机
        // CDN 的转码 FLAC 普遍存在最后一帧坏帧，曲末打
        //   [ffmpeg/audio:error] flac: decode_frame() failed
        //   [ad:error] Error decoding audio
        // media_kit 会把 ad / cplayer / stream 前缀的 error 日志原样转成
        // stream.error；若据此把处理状态改成 idle，just_audio 会在
        // 「非 idle → idle」跳变时调用 _setPlatformActive(false)（等同
        // stop()）把真实播放器直接废掉、事件订阅一并取消，随后 mpv 正常
        // 发出的 eof-reached=true（→ completed）永远送不到宿主 —— 表现为
        // 「整首播完不自动切下一首，进度停在最后一秒且仍显示播放中」。
        //
        // 因此这里改为白名单：只有确定表示加载失败的错误才置 idle（保留
        // 原有「加载失败 → 上层换源」行为），解码类错误一律忽略，EOF 由
        // eof-reached 属性正常上报。
        final isLoadFailure = error.startsWith('Failed to open ') ||
            error.startsWith('No protocol handler') ||
            error.startsWith('tcp:') ||
            error.startsWith('http:');
        if (!isLoadFailure) {
          _logger
              .warning('Ignored non-fatal error (playback continues): $error');
          return;
        }
        final errorUri = RegExp(r'Failed to open (.*)\.').firstMatch(error)?[1];
        if (errorUri == null || errorUri == _currentMedia?.uri) {
          _processingState = ProcessingStateMessage.idle;
          _errorCode = kErrorCode;
          _errorMessage = error;
          _updatePlaybackEvent();
        }
        _logger.severe('ERROR OCCURRED: $error');
      }),
      _player.stream.playlist.listen((playlist) {
        if (_currentIndex != playlist.index) {
          _bufferedPosition = _position = Duration.zero;
          _currentIndex = playlist.index;
        }
        _duration = _currentMedia?.extras?['overrideDuration'];
        _updatePlaybackEvent();
      }),
      _player.stream.playlistMode.listen((playlistMode) {
        _dataController.add(
            PlayerDataMessage(loopMode: _playlistModeToLoopMode(playlistMode)));
      }),
      _player.stream.pitch.listen((pitch) {
        _dataController.add(PlayerDataMessage(pitch: pitch));
      }),
      _player.stream.rate.listen((rate) {
        _dataController.add(PlayerDataMessage(speed: rate));
      }),
      _player.stream.log.listen((event) {
        // Mint Music 本地补丁：改用 debugPrint。release 下宿主 main.dart 把
        // debugPrint 置空，mpv error 日志（坏帧 / 网络重连时可能连续刷屏）
        // 不再逐条做字符串插值 + 控制台写入，避免白白占用主 isolate；
        // debug 下保留完整日志。
        debugPrint("MPV: [${event.level}] ${event.prefix}: ${event.text}");
      }),
    ];
  }

  /// MP3 在线播放启用「快进式 seek」，把拖动进度条变成真正的 Range 请求。
  ///
  /// 实现是整体重设 `demuxer-lavf-o`（media_kit 默认值 + `fflags=+fastseek`），
  /// 详见构造函数内的补丁说明。失败静默忽略：这个属性设不上时，
  /// mpv 回到默认行为（顺序读转发），播放仍然可用。
  Future<void> _enableMp3FastSeek() async {
    try {
      // 注意不能「读现值再追加」：mpv 读属性（mpv_get_property_string）会把
      // `protocol_whitelist=[a,b,c]` 的方括号剥掉，回写就变成
      // `protocol_whitelist=udp` + 一串垃圾条目，追加的 fflags 会被吞进
      // 垃圾键里（ffmpeg 报 `Could not set AVOption
      // rtp,tcp,...,fflags='+fastseek'`），修复完全失效。所以按 media_kit
      // 1.2.6 real.dart 的默认值整体重建，追加 fastseek 后一次写入。
      // 升级 media_kit 时需同步核对该默认值。
      final merged =
          'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,'
          'protocol_whitelist=[${JustAudioMediaKit.protocolWhitelist.join(',')}],'
          'fflags=+fastseek';
      await setProperty(_player, 'demuxer-lavf-o', merged);
    } catch (_) {}
  }

  void _updateDuration(Duration duration) {
    final start = _currentMedia?.start;
    final end = _currentMedia?.end;
    if (end != null) duration = end;
    if (start != null) duration -= start;
    _duration = duration;
  }

  PlaylistMode _loopModeToPlaylistMode(LoopModeMessage loopMode) {
    return switch (loopMode) {
      LoopModeMessage.off => PlaylistMode.none,
      LoopModeMessage.one => PlaylistMode.single,
      LoopModeMessage.all => PlaylistMode.loop,
    };
  }

  LoopModeMessage _playlistModeToLoopMode(PlaylistMode playlistMode) {
    return switch (playlistMode) {
      PlaylistMode.none => LoopModeMessage.off,
      PlaylistMode.single => LoopModeMessage.one,
      PlaylistMode.loop => LoopModeMessage.all,
    };
  }

  @override
  Stream<PlaybackEventMessage> get playbackEventMessageStream =>
      _eventController.stream;

  @override
  Stream<PlayerDataMessage> get playerDataMessageStream =>
      _dataController.stream;

  /// Updates the playback event
  void _updatePlaybackEvent() {
    _eventController.add(PlaybackEventMessage(
      processingState: _processingState,
      updateTime: DateTime.now(),
      updatePosition: _position,
      bufferedPosition: _bufferedPosition,
      duration: _duration,
      icyMetadata: null,
      currentIndex: _currentIndex,
      androidAudioSessionId: null,
      errorCode: _errorCode,
      errorMessage: _errorMessage,
    ));
  }

  @override
  Future<LoadResponse> load(LoadRequest request) async {
    _logger.finest('load(${request.toMap()})');
    // fastseek 必须在这一首 open 之前写进 mpv，否则本次 open 还是默认 seek
    // 行为（拖动整首下载），见构造函数里的说明。
    await _fastSeekReady;
    _mediaOpened = false;
    _loadCompleter = Completer();
    _currentIndex = request.initialIndex ?? 0;
    _bufferedPosition = Duration.zero;
    _position = Duration.zero;
    _duration = null;
    _processingState = ProcessingStateMessage.loading;
    _errorCode = null;
    _errorMessage = null;
    _updatePlaybackEvent();

    if (request.audioSourceMessage is ConcatenatingAudioSourceMessage) {
      final audioSource =
          request.audioSourceMessage as ConcatenatingAudioSourceMessage;
      final playable = Playlist(
          audioSource.children.map(_convertAudioSourceIntoMediaKit).toList(),
          index: _currentIndex);

      await _player.open(playable, play: _playing);
    } else {
      final playable =
          _convertAudioSourceIntoMediaKit(request.audioSourceMessage);
      _logger.finest('playable is ${playable.toString()}');
      await _player.open(playable, play: _playing);
    }
    _mediaOpened = true;

    if (request.initialPosition != null) {
      _setPosition = _position = request.initialPosition!;
    }

    _updatePlaybackEvent();
    final duration = await _loadCompleter?.future;
    return LoadResponse(duration: duration);
  }

  @override
  Future<PlayResponse> play(PlayRequest request) async {
    _playing = true;
    if (_mediaOpened) {
      await _player.play();
    }
    return PlayResponse();
  }

  @override
  Future<PauseResponse> pause(PauseRequest request) async {
    _playing = false;
    if (_mediaOpened) {
      await _player.pause();
    }
    return PauseResponse();
  }

  @override
  Future<SetVolumeResponse> setVolume(SetVolumeRequest request) {
    return _player
        .setVolume(request.volume * 100.0)
        .then((value) => SetVolumeResponse());
  }

  @override
  Future<SetSpeedResponse> setSpeed(SetSpeedRequest request) {
    return _player.setRate(request.speed).then((_) => SetSpeedResponse());
  }

  @override
  Future<SetPitchResponse> setPitch(SetPitchRequest request) =>
      _player.setPitch(request.pitch).then((_) => SetPitchResponse());

  @override
  Future<SetLoopModeResponse> setLoopMode(SetLoopModeRequest request) async {
    await _player.setPlaylistMode(_loopModeToPlaylistMode(request.loopMode));
    return SetLoopModeResponse();
  }

  @override
  Future<SetShuffleModeResponse> setShuffleMode(
      SetShuffleModeRequest request) async {
    bool shuffling = request.shuffleMode != ShuffleModeMessage.none;
    await _player.setShuffle(shuffling);

    _dataController.add(PlayerDataMessage(
        shuffleMode:
            shuffling ? ShuffleModeMessage.all : ShuffleModeMessage.none));
    return SetShuffleModeResponse();
  }

  @override
  Future<SeekResponse> seek(SeekRequest request) async {
    _logger.finest('seek(${request.toMap()})');
    if (request.index != null) {
      await _player.jump(request.index!);
      if (!_playing) await _player.pause();
    }

    final position = request.position;
    if (position != null) {
      _position = position;

      final start = _currentMedia?.start;
      var nativePosition = position;
      if (start != null) nativePosition += start;
      if (_player.state.duration.inSeconds > 0) {
        await _player.seek(nativePosition);
      } else {
        _setPosition = nativePosition;
      }
    } else {
      _position = Duration.zero;
    }

    // reset position on seek
    _updatePlaybackEvent();
    return SeekResponse();
  }

  @override
  Future<ConcatenatingInsertAllResponse> concatenatingInsertAll(
      ConcatenatingInsertAllRequest request) async {
    // _logger.fine('concatenatingInsertAll(${request.toMap()})');
    for (final source in request.children) {
      await _player.add(_convertAudioSourceIntoMediaKit(source));

      final length = _player.state.playlist.medias.length;

      if (length == 0 || length == 1) continue;

      if (request.index < (length - 1) && request.index >= 0) {
        await _player.move(length, request.index);
      }
    }

    return ConcatenatingInsertAllResponse();
  }

  @override
  Future<ConcatenatingRemoveRangeResponse> concatenatingRemoveRange(
      ConcatenatingRemoveRangeRequest request) async {
    for (var i = request.startIndex; i < request.endIndex; i++) {
      await _player.remove(request.startIndex);
    }

    return ConcatenatingRemoveRangeResponse();
  }

  @override
  Future<ConcatenatingMoveResponse> concatenatingMove(
      ConcatenatingMoveRequest request) {
    return _player
        .move(
            request.currentIndex,
            // not sure why, but apparently there's an underlying difference between just_audio's move implementation
            // and media_kit, so let's fix it
            request.currentIndex > request.newIndex
                ? request.newIndex
                : request.newIndex + 1)
        .then((_) => ConcatenatingMoveResponse());
  }

  /// Release the resources used by this player.
  Future<void> release() async {
    _logger.info('releasing player resources');
    _mediaOpened = false;
    await _player.dispose();
    // cancel all stream subscriptions
    for (final StreamSubscription subscription in _streamSubscriptions) {
      unawaited(subscription.cancel());
    }
    _streamSubscriptions.clear();
  }

  /// Converts an [AudioSourceMessage] into a [Media] for playback
  Media _convertAudioSourceIntoMediaKit(AudioSourceMessage audioSource) {
    switch (audioSource) {
      case final UriAudioSourceMessage uriSource:
        return Media(uriSource.uri, httpHeaders: audioSource.headers);

      // removed because it doesn't seem to be actually working.
      // Related media-kit issue: https://github.com/media-kit/media-kit/issues/28
      // case final SilenceAudioSourceMessage silenceSource:
      //   // from https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137
      //   return Media(
      //     'av://lavfi:anullsrc=d=${silenceSource.duration.inMilliseconds}ms',
      //     extras: {'overrideDuration': silenceSource.duration},
      //   );

      case final ClippingAudioSourceMessage clippingSource:
        return Media(clippingSource.child.uri,
            start: clippingSource.start, end: clippingSource.end);

      default:
        throw UnsupportedError(
            '${audioSource.runtimeType} is currently not supported');
    }
  }
}
