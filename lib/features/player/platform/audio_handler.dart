import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:just_audio/just_audio.dart';

import '../domain/models/song.dart';
import '../../../shared/services/cover_cache_service.dart';
import '../../../shared/services/cover_fetcher.dart';

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler, WidgetsBindingObserver {
  /// ExoPlayer 实例。`androidOffloadSchedulingEnabled` 由构造函数决定，
  /// 见 [MusicAudioHandler]。
  final AudioPlayer _player;
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  DateTime? _lastPositionBroadcast;

  /// 纯进度事件（播放状态没变）的广播节流间隔。
  ///
  /// 媒体会话 / 通知里的进度条由系统按 playbackState 的 position+speed 自行
  /// 外推，所以后台（熄屏）时没必要保持前台那点精度：前台 500ms、后台 2s，
  /// 每次广播都是一次跨平台通道 / binder 调用。
  static const _broadcastIntervalForeground = Duration(milliseconds: 500);
  static const _broadcastIntervalBackground = Duration(seconds: 2);

  Duration get _positionBroadcastInterval => _appForeground
      ? _broadcastIntervalForeground
      : _broadcastIntervalBackground;

  /// 位置轮询周期：前台 200ms（与 UI 进度条节流粒度一致），后台 1s。
  ///
  /// just_audio 自带 positionStream 的周期 = 时长/800（夹在 16ms–200ms），
  /// 短音频会以最高 60Hz 唤醒 Dart 做状态拷贝 / 广播；这里自己控周期，并且
  /// **随前后台切换**：熄屏播放一整夜时，200ms 一次唤醒纯属浪费。
  static const _positionPeriodForeground = Duration(milliseconds: 200);
  static const _positionPeriodBackground = Duration(seconds: 1);

  /// 是否在前台。切换时更换位置轮询周期，并影响广播节流间隔。
  bool _appForeground = true;

  /// 对外暴露的位置流：broadcast，多个订阅者共用同一份内部轮询。
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();

  StreamSubscription<Duration>? _positionFeed;

  /// 对外的位置流。
  ///
  /// 与 `AudioPlayer.positionStream` 的差异（订阅方注意）：broadcast、
  /// **不 replay 当前值**，暂停 / 缓冲时也不发事件——订阅后最多要等一个
  /// 周期才收到第一个位置。需要「一订阅就有值」的场景请先读
  /// [currentPosition]，别指望首帧。
  Stream<Duration> get positionStream => _positionController.stream;

  /// 按当前前后台状态（重新）挂一条位置轮询。
  ///
  /// `createPositionStream` 的 timer 跟着订阅走：取消旧订阅即停掉旧周期的
  /// timer，不会出现两条轮询同时在跑。
  void _restartPositionFeed() {
    _positionFeed?.cancel();
    _positionFeed = null;
    // 暂停时位置不会再变：just_audio 的 createPositionStream 内部是个
    // `Timer.periodic`，每拍只在 playing 时才发事件——也就是说暂停之后它仍然
    // 每秒（后台）/ 每 200ms（前台）醒一次，什么都不做。暂停就不挂这条流，
    // 恢复播放时由 `playingStream` 重新挂上。
    if (!_player.playing) return;
    final period = _appForeground
        ? _positionPeriodForeground
        : _positionPeriodBackground;
    _positionFeed = _player
        .createPositionStream(steps: 800, minPeriod: period, maxPeriod: period)
        .listen(
          (position) {
            if (!_positionController.isClosed) {
              _positionController.add(position);
            }
          },
          onError: (Object error) {
            debugPrint('[MusicAudioHandler] 位置流异常: $error');
          },
        );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final foreground = state == AppLifecycleState.resumed;
    if (foreground == _appForeground) return;
    _appForeground = foreground;
    debugPrint(
      '[MusicAudioHandler] 切到${foreground ? "前台" : "后台"}：位置流'
      '${foreground ? "200ms" : "1s"}、进度广播'
      '${foreground ? "500ms" : "2s"}',
    );
    _restartPositionFeed();
  }

  /// 上次真正广播出去的播放状态：两条流都会调 [_broadcastState]，用它把
  /// 节流窗口内的重复进度事件合并掉。
  bool? _lastBroadcastPlaying;
  AudioProcessingState? _lastBroadcastProcessingState;

  /// 位置流订阅方的注意事项：见 [positionStream] 与 [_restartPositionFeed]。
  Stream<Duration> get bufferedPositionStream => _player.bufferedPositionStream;
  Stream<PlayerState> get playerStateStream => _player.playerStateStream;
  Stream<Duration?> get durationStream => _player.durationStream;
  Duration? get currentDuration => _player.duration;
  Duration get currentPosition => _player.position;
  Stream<int?> get currentIndexStream => _player.currentIndexStream;
  Stream<int?> get audioSessionIdStream => _player.androidAudioSessionIdStream;
  int? get currentAudioSessionId => _player.androidAudioSessionId;
  Stream<String> get playbackErrorStream => _errorController.stream;

  PlayerState? get currentPlayerState => _player.playerState;
  ProcessingState get processingState => _player.processingState;
  bool get playing => _player.playing;

  ProcessingState _lastProcessingState = ProcessingState.idle;
  bool _errorMonitoring = false;

  /// 清空媒体会话期间屏蔽状态广播，见 [clearMediaSession]。
  bool _suppressBroadcast = false;

  /// 换源计数（[_setPlayerSource] 执行期间 > 0，用计数而非 bool 是为了
  /// 快速连点切歌时两个换源重叠，先结束的那个不会提前清掉标记）。
  ///
  /// Android 上 just_audio 每次 `setAudioSource` 都会先把播放器切回 idle，
  /// 而 audio_service 收到「非 idle → idle」跳变会直接 `stop()` 撤销通知；
  /// 切歌时就会看到通知先消失、新歌起播后又重新出现。换源期间用它把 idle
  /// 伪装成 buffering，通知保持常驻。详见 [_broadcastState]。
  int _switchingSourceCount = 0;

  /// 会话是否已被清空。
  ///
  /// 清空播放列表后，任何**残留的在途请求**（取URL / 音质切换，
  /// 这些流程里有十几处 `await`，无法只靠调用点的 requestId 守卫全部覆盖）
  /// 恢复执行时都会调用 [setAudioSource] / [setSource]，把已经删除的曲目
  /// 重新写回通知栏，并让系统媒体控制重新「可播放」。这里直接把它们全部忽略，
  /// 直到用户主动建立新的播放列表（[setQueue] / [markSessionActive]）。
  bool _sessionCleared = false;

  /// 声明会话有效（用户主动开启了新的播放）。
  ///
  /// [setQueue] 内部会自动调用；[MusicAudioHandler.prependAndPlay] 这类
  /// 不经过 [setQueue] 的入口需要由 `PlaybackController` 显式调用一次。
  void markSessionActive() {
    _sessionCleared = false;
  }

  /// 「无曲目」时的干净播放状态：不带任何控件 + idle。
  ///
  /// [PlaybackState] 的默认值（`controls: const []`、`systemActions: const {}`、
  /// `playing: false`、`processingState: idle`）正好就是我们要的，
  /// 直接用默认构造即可。它的构造函数不是 const，所以不能写成 `const`。
  static final PlaybackState _emptyPlaybackState = PlaybackState();

  /// 通知栏控制回调（由 PlaybackController 设置）
  VoidCallback? onSkipNext;
  VoidCallback? onSkipPrevious;

  /// 播放即将停止的回调（由 PlaybackController 设置）。
  ///
  /// 通知栏 ✕ 与系统媒体键 stop 都会走到 [stop]；必须在 [_player.stop]
  /// 产生 idle 事件**之前**通知控制器作废在途请求（尤其是切歌后挂载的一次性
  /// 错误监听器——它会把「ready→idle 且未播放」误判为播放中断，自动重取
  /// URL 续播，表现为「点了关闭，通知先消失又出现、歌曲自己又开始播」）。
  VoidCallback? onStopRequested;

  /// [androidAudioOffload] 直接映射到 just_audio 的
  /// `androidOffloadSchedulingEnabled`。
  ///
  /// 打开后 ExoPlayer 才会真正把 PCM 交给硬件 offload 通路（解码从 CPU 挪到
  /// DSP，熄屏长播时 CPU 可以更深地睡）。代价见 just_audio 的
  /// `AudioPlayer.java`：开启即意味着放弃「gapless 必需」与「变速必需」两个
  /// 要求，否则 ExoPlayer 会为了保住它们而放弃 offload。所以调用方只在
  /// 「播放速度 = 1.0」、且平台是 Android 时打开（见 `initAudioService`）。
  MusicAudioHandler({bool androidAudioOffload = false})
    : _player = AudioPlayer(
        androidOffloadSchedulingEnabled: androidAudioOffload,
        // 桌面端（media_kit/mpv）不用 just_audio 那个本地代理，见
        // [usesProxyForRequestHeaders]。
        useProxyForRequestHeaders: usesProxyForRequestHeaders,
      ) {
    _init();
    // 后台播放时把位置轮询 / 状态广播降到低频（见 didChangeAppLifecycleState）。
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _init() async {
    _player.playbackEventStream.listen((event) {
      _broadcastState();
    });

    // 播放 / 暂停切换时重挂位置轮询：暂停期间不跑那个空转的定时器。
    // `playingStream` 直接反映 play() / pause() 的意图，与后端实现无关。
    _player.playingStream.distinct().listen((playing) {
      _restartPositionFeed();
    });

    // 两条流都调 _broadcastState()：节流 / 去重统一放在那里，避免各自
    // 计时后叠加重复广播。位置轮询由 [_restartPositionFeed] 按前后台挂载。
    _positionController.stream.listen((_) => _broadcastState());
    _restartPositionFeed();

    _player.durationStream.listen((duration) {
      if (duration != null && duration > Duration.zero) {
        _updateMediaItemDuration(duration);
      }
    });

    await _initAudioSession();

    _player.currentIndexStream.listen((index) {
      if (index != null &&
          queue.value.isNotEmpty &&
          index < queue.value.length) {
        mediaItem.add(queue.value[index]);
        _tryUpdateDurationFromPlayer();
      }
    });
  }

  /// 统一替换音源，并在整个 await 期间递增 [_switchingSourceCount]。
  ///
  /// 只包住 `setAudioSource` 这一段：之后的 duration 校验、媒体项更新等
  /// 都发生在 loading / ready 状态，不会触发上面那个 idle 跳变。
  /// 参数是 `AudioSource` 而非 `ConcatenatingAudioSource`，兼容所有调用点。
  Future<void> _setPlayerSource(
    AudioSource source, {
    int? initialIndex,
    Duration? initialPosition,
  }) async {
    _switchingSourceCount++;
    try {
      await _player.setAudioSource(
        source,
        initialIndex: initialIndex,
        initialPosition: initialPosition,
      );
    } finally {
      _switchingSourceCount--;
    }
  }

  void _broadcastState() {
    // 清空会话时不要把「带控件的播放状态」推回去，否则通知栏会被重新点亮。
    if (_suppressBroadcast) return;
    // 没有任何曲目时只广播「无控件 + idle」状态。清空播放列表后，
    // _player 仍会吐出零星的位置/状态事件，若此时照常广播带控件的状态，
    // audio_service 会把通知栏重新点亮（旧曲目 + 可点的播放键）。
    if (mediaItem.value == null || queue.value.isEmpty) {
      // 换源瞬间新队列 / 媒体项可能还没写进来（setAudioSource 先于 queue.add
      // 的路径），此时不要广播 idle，保持通知原样即可。
      if (Platform.isAndroid && _switchingSourceCount > 0) return;
      _lastBroadcastPlaying = null;
      _lastBroadcastProcessingState = null;
      playbackState.add(_emptyPlaybackState);
      return;
    }
    // Android：见 [_switchingSourceCount] —— 把换源瞬间的 idle 报成 buffering，
    // 避免 audio_service 误判为「用户停止播放」而 cancel 通知并 stopSelf。
    // 真正的停止走 stop() / clearMediaSession()，它们不经过换源路径，
    // idle 广播仍然照常生效。Windows 不接 audio_service，行为完全不变。
    var processingState = _mapProcessingState(_player.processingState);
    final now = DateTime.now();
    final playing = _player.playing;
    // playbackEventStream 与 positionStream 都调这里；状态没变且广播间隔
    // 内已经推过一次，就跳过这次纯进度事件，避免通知栏 / 媒体会话重复刷新。
    // 间隔随前后台变化（前台 500ms / 后台 2s，见 [_positionBroadcastInterval]）。
    final stateChanged =
        playing != _lastBroadcastPlaying ||
        processingState != _lastBroadcastProcessingState;
    if (!stateChanged &&
        _lastPositionBroadcast != null &&
        now.difference(_lastPositionBroadcast!) < _positionBroadcastInterval) {
      return;
    }
    _lastPositionBroadcast = now;
    _lastBroadcastPlaying = playing;
    _lastBroadcastProcessingState = processingState;
    if (Platform.isAndroid &&
        _switchingSourceCount > 0 &&
        processingState == AudioProcessingState.idle) {
      processingState = AudioProcessingState.buffering;
    }
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          _player.playing ? MediaControl.pause : MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
          MediaAction.skipToNext,
          MediaAction.skipToPrevious,
        },
        playing: _player.playing,
        processingState: processingState,
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: _player.currentIndex,
      ),
    );
  }

  void _updateMediaItemDuration(Duration duration) {
    final currentItem = mediaItem.value;
    if (currentItem == null) return;
    if (currentItem.duration == duration) return;

    final updatedItem = currentItem.copyWith(duration: duration);
    mediaItem.add(updatedItem);

    final currentQueue = queue.value;
    final index = _player.currentIndex;
    if (index != null && index >= 0 && index < currentQueue.length) {
      final queueItem = currentQueue[index];
      if (queueItem.duration != duration) {
        final newQueue = List<MediaItem>.from(currentQueue);
        newQueue[index] = queueItem.copyWith(duration: duration);
        queue.add(newQueue);
      }
    }

    if (kDebugMode)
      debugPrint(
        '[MusicAudioHandler] duration updated: ${duration.inSeconds}s',
      );
  }

  void _tryUpdateDurationFromPlayer() {
    final duration = _player.duration;
    if (duration != null && duration > Duration.zero) {
      _updateMediaItemDuration(duration);
    }
  }

  Future<void> _initAudioSession() async {
    // audio_session 只实现了 Android / iOS / macOS / Web，桌面端（Windows /
    // Linux）没有插件实现，`AudioSession.instance` 会抛 MissingPluginException。
    // 桌面端也不需要处理来电/音频焦点抢占，直接跳过。
    if (Platform.isWindows || Platform.isLinux) return;

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    session.becomingNoisyEventStream.listen((_) {
      pause();
    });

    // 此前完全没有订阅 interruptionEventStream：来电、导航播报、其它 App
    // 抢音频焦点等中断事件被静默丢弃。系统此时已经把 ExoPlayer 停掉，而 App
    // 侧状态仍是「播放中」，表现就是「切后台后播放莫名停住/停掉」。
    //
    // 注意 just_audio 自带的 handleInterruptions（AudioPlayer 默认开启）也在
    // 处理同一份事件流（begin pause/unknown → 暂停 + _playInterrupted；
    // end pause → _playInterrupted 才恢复），两边必须互相让路：
    // * unknown 类型的结束事件不自动续播（与 just_audio 语义一致）。旧逻辑
    //   在这里靠可能滞后 200ms 的广播状态误判「还在播放」，造成多余的音频
    //   焦点请求 / 意外续播；
    // * 播放器还在播放（begin 的 pause 尚未落地）时不要插手：此时 play()
    //   会把 just_audio 的 _playInterrupted 清掉，end-pause 的自带恢复反而
    //   失效——表现为短暂中断后播放停在半路；
    // * 剩下的兜底场景：系统停掉了播放器但 begin 事件没送达（个别 ROM 的
    //   瞬时焦点抢占），此时播放器已停而广播仍是「播放中」，补一次 play()
    //   恢复，避免停播后不再自动继续。
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        // duck 只是系统临时压低音量（导航播报），并未停止播放，不要暂停。
        // pause 才是真正被中断（来电等），按预期暂停。
        if (event.type == AudioInterruptionType.pause) {
          pause();
        }
      } else {
        if (event.type == AudioInterruptionType.unknown) return;
        if (_player.playing) return;
        if (playbackState.value.playing) {
          play();
        }
      }
    });
  }

  void startErrorMonitoring() {
    if (_errorMonitoring) return;
    _errorMonitoring = true;

    _player.playerStateStream.listen((state) {
      final current = state.processingState;
      // playerStateStream 在缓冲期间一秒能发多次事件，这条日志是热路径上
      // 最高频的一行：release 下连字符串插值都不做（kDebugMode 是编译期常量，
      // AOT 直接裁掉这个分支，下同）。
      if (kDebugMode) {
        debugPrint(
          '[MusicAudioHandler] processingState: $_lastProcessingState → $current, playing=${state.playing}',
        );
      }

      if (_lastProcessingState == ProcessingState.loading &&
          current == ProcessingState.idle &&
          !state.playing) {
        _errorController.add('playback_load_failed');
        debugPrint('[MusicAudioHandler] 检测到播放错误: loading→idle (加载失败)');
      }

      if (_lastProcessingState == ProcessingState.buffering &&
          current == ProcessingState.idle) {
        _errorController.add('playback_buffering_failed');
        debugPrint('[MusicAudioHandler] 检测到播放错误: buffering→idle (缓冲失败)');
      }

      if (_lastProcessingState == ProcessingState.ready &&
          current == ProcessingState.idle) {
        _errorController.add('playback_unexpected_stop');
        debugPrint('[MusicAudioHandler] 检测到播放错误: ready→idle (异常停止)');
      }

      _lastProcessingState = current;
    });
  }

  void stopErrorMonitoring() {
    _errorMonitoring = false;
  }

  void emitError(String error) {
    _errorController.add(error);
  }

  MediaItem _songToMediaItem(Song song) {
    Uri? artUri;
    if (song.coverUrl != null && song.coverUrl!.isNotEmpty) {
      if (song.coverUrl!.startsWith('http')) {
        // 通知封面用网易缩略图（400y400）：原图好几 MB，而 audio_service
        // 会先把 artUri 下载到本地再解码成通知大图，拉原图纯属浪费流量与
        // 内存。只对网易 CDN 替换：其它音源的候选列表可能为空（非标准
        // scheme），或像酷我那样把 https 降级成 http，直接用原图更稳。
        // audio_service 的 artUri 只支持单地址，缩略图失败时不兜底，
        // 与列表封面同源所以命中率极高。
        final raw = song.coverUrl!;
        final candidates = CoverFetcher.candidatesOf(raw);
        artUri = Uri.parse(
          raw.contains('music.126.net') && candidates.isNotEmpty
              ? candidates.first
              : raw,
        );
      } else if (song.coverUrl!.startsWith('content://')) {
        artUri = Uri.parse(song.coverUrl!);
      } else {
        artUri = Uri.file(song.coverUrl!);
      }
    }

    final duration = song.duration > 0
        ? Duration(seconds: song.duration)
        : null;

    if (kDebugMode) {
      debugPrint(
        '[MusicAudioHandler] _songToMediaItem: ${song.title}, song.duration=${song.duration}s, mediaItem.duration=${duration?.inSeconds}s',
      );
    }

    return MediaItem(
      id: song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      duration: duration,
      artUri: artUri,
    );
  }

  AudioSource _songToAudioSource(Song song) {
    final mediaItem = _songToMediaItem(song);

    // 如果没有 sourceUrl，使用一个不会导致立即失败的临时方案
    // 我们使用一个简短的本地静音音频或者保持为 null，但为了队列完整性，
    // 我们暂时使用一个特殊的标记，让 PlaybackController 处理
    if (song.sourceUrl == null || song.sourceUrl!.isEmpty) {
      debugPrint('[MusicAudioHandler] 歌曲无 sourceUrl: ${song.title}');
      // 这里我们仍然需要返回一个有效的 AudioSource，
      // 所以我们先使用一个特殊的 URL 占位，
      // PlaybackController 的后台解析会更新它
      final placeholderUri = Uri.parse('https://example.com/placeholder');
      return AudioSource.uri(placeholderUri, tag: mediaItem);
    }

    final uri = song.sourceUrl!.startsWith('http')
        ? Uri.parse(song.sourceUrl!)
        : Uri.file(song.sourceUrl!);

    if (song.sourceUrl!.startsWith('http')) {
      final headers = audioHeadersForUrl(
        song.sourceUrl!,
        songHeaders: song.sourceHeaders,
      );
      return AudioSource.uri(uri, tag: mediaItem, headers: headers);
    }

    return AudioSource.uri(uri, tag: mediaItem);
  }

  Future<void> setQueue(List<Song> songs, int startIndex) async {
    if (kDebugMode) {
      debugPrint(
        'MusicAudioHandler: 设置播放队列 - ${songs.length}首, 起始索引: $startIndex',
      );
    }
    // 用户主动建立新队列 → 会话恢复有效。
    _sessionCleared = false;

    final processedSongs = await _prepareLocalCovers(
      songs,
      currentIndex: startIndex,
    );
    final children = processedSongs.map(_songToAudioSource).toList();
    final mediaItems = processedSongs.map(_songToMediaItem).toList();
    queue.add(mediaItems);

    try {
      final playlist = ConcatenatingAudioSource(children: children);
      await _setPlayerSource(playlist, initialIndex: startIndex);

      if (startIndex >= 0 && startIndex < mediaItems.length) {
        mediaItem.add(mediaItems[startIndex]);
      }

      _tryUpdateDurationFromPlayer();

      if (kDebugMode) debugPrint('MusicAudioHandler: 队列设置成功');
    } catch (e) {
      debugPrint('MusicAudioHandler: 队列设置失败: $e');
      rethrow;
    }
  }

  /// 设队列时预先准备封面的「前面几首」数量（含当前曲）。
  ///
  /// 整队列逐首 `ensureDiskFile`（stat / MediaStore 平台通道查询）在几千首的
  /// 歌单上是实打实的 CPU 尖峰；而其余歌曲真正播放前一定会再经过
  /// [setAudioSource] 的单曲准备（`_prepareLocalCovers([song])`），封面不会
  /// 缺席。所以这里只覆盖「当前曲 + 紧接着要播的两首」（下一首也要有封面，
  /// 通知栏才不会空一下）。
  static const int _coverPrepareAhead = 2;

  Future<List<Song>> _prepareLocalCovers(
    List<Song> songs, {
    int currentIndex = -1,
  }) async {
    final result = List<Song>.from(songs);
    final coverCache = CoverCacheService();

    Future<Song> processSong(Song song) async {
      // 桌面端没有 MediaStore，封面由扫描时写入封面缓存，这里同样能取到。
      if (song.coverUrl == null &&
          (song.mediaStoreId != null || song.source == 'local')) {
        try {
          // 直接使用本地歌曲封面缓存里的 `<歌曲id>.jpg`（已落盘的那份），
          // 不再复制到 covers 目录。
          final coverPath = await coverCache.ensureDiskFile(
            song.id,
            mediaStoreId: song.mediaStoreId,
          );
          if (coverPath != null) {
            return song.copyWith(coverUrl: coverPath);
          }
        } catch (e) {
          debugPrint('MusicAudioHandler: 提取封面失败 ${song.title}: $e');
        }
      }
      return song;
    }

    final from = currentIndex >= 0 ? currentIndex : 0;
    // 已经有封面的歌不用再跑（processSong 内部也会早返回，但这里连调用都省掉）。
    final targets = <int>[
      for (
        var i = from;
        i < songs.length && i <= from + _coverPrepareAhead;
        i++
      )
        if (songs[i].coverUrl == null &&
            (songs[i].mediaStoreId != null || songs[i].source == 'local'))
          i,
    ];
    if (targets.isEmpty) return result;

    // 当前曲先处理：起播瞬间的通知 / 播放页要立刻有封面。
    final first = targets.first;
    result[first] = await processSong(songs[first]);
    if (targets.length > 1) {
      await Future.wait([
        for (final i in targets.skip(1))
          processSong(songs[i]).then((song) => result[i] = song),
      ]);
    }
    return result;
  }

  Future<void> setSource(Song song) async {
    if (kDebugMode) debugPrint('MusicAudioHandler: 开始设置音源 - 歌曲: ${song.title}');

    if (_sessionCleared) {
      debugPrint('MusicAudioHandler: 会话已清空，忽略过期的 setSource');
      return;
    }

    if (song.sourceUrl != null) {
      if (kDebugMode) debugPrint('MusicAudioHandler: 音源URL: ${song.sourceUrl}');

      try {
        final prepared = await _prepareLocalCovers([song], currentIndex: 0);
        final preparedSong = prepared[0];
        final mediaItem = _songToMediaItem(preparedSong);
        queue.add([mediaItem]);

        await _setPlayerSource(
          ConcatenatingAudioSource(
            children: [_songToAudioSource(preparedSong)],
          ),
        );

        this.mediaItem.add(mediaItem);
        if (kDebugMode) debugPrint('MusicAudioHandler: 音源设置成功');
      } catch (e) {
        debugPrint('MusicAudioHandler: 设置音源失败: $e');
        rethrow;
      }
    } else {
      debugPrint('MusicAudioHandler: 错误 - 歌曲没有音源URL');
    }
  }

  /// 设置播放地址。
  ///
  /// [initialPosition] 是「上次听到的位置」（续播）：直接交给播放器的 load
  /// 阶段，播放器一打开就从那儿开始，不必先按 0 位置读一段再 seek。
  Future<void> setAudioSource(
    String url, {
    Song? song,
    Map<String, String>? headers,
    Duration? initialPosition,
  }) async {
    if (kDebugMode) {
      debugPrint(
        'MusicAudioHandler: 设置音频源: ${url.substring(0, url.length > 60 ? 60 : url.length)}...',
      );
    }

    if (_sessionCleared) {
      debugPrint('MusicAudioHandler: 会话已清空，忽略过期的 setAudioSource');
      return;
    }

    var preparedSong = song;
    if (preparedSong != null) {
      final prepared = await _prepareLocalCovers([
        preparedSong,
      ], currentIndex: 0);
      preparedSong = prepared[0];
    }

    final mediaItem = preparedSong != null
        ? _songToMediaItem(preparedSong)
        : MediaItem(
            id: url,
            title: song?.title ?? 'Unknown',
            artist: song?.artist,
          );

    final uri = url.startsWith('http') ? Uri.parse(url) : Uri.file(url);

    try {
      if (url.startsWith('http')) {
        final requestHeaders = audioHeadersForUrl(
          url,
          songHeaders: song?.sourceHeaders,
          extraHeaders: headers,
        );

        // 直接用 CDN 地址流播：不做任何内存缓存，单曲循环 / 重播由播放器
        // 重新向 CDN 取数据。
        await _setPlayerSource(
          ConcatenatingAudioSource(
            children: [
              requestHeaders.isEmpty
                  ? AudioSource.uri(uri, tag: mediaItem)
                  : AudioSource.uri(
                      uri,
                      tag: mediaItem,
                      headers: requestHeaders,
                    ),
            ],
          ),
          initialPosition: initialPosition,
        );
        await _validateRemoteSongDuration(preparedSong, url);
      } else {
        // 本地文件：直接播。
        await _setPlayerSource(
          ConcatenatingAudioSource(
            children: [AudioSource.uri(uri, tag: mediaItem)],
          ),
          initialPosition: initialPosition,
        );
      }

      queue.add([mediaItem]);
      this.mediaItem.add(mediaItem);
      if (kDebugMode) debugPrint('MusicAudioHandler: 音频源设置成功');
    } catch (e) {
      debugPrint('MusicAudioHandler: 设置音频源失败: $e');
      rethrow;
    }
  }

  Future<void> _validateRemoteSongDuration(Song? song, String url) async {
    if (song?.source != 'kw') return;

    var actual = _player.duration;
    if (actual == null || actual <= Duration.zero) {
      try {
        actual = await _player.durationStream
            .firstWhere(
              (duration) => duration != null && duration > Duration.zero,
            )
            .timeout(const Duration(seconds: 8));
      } catch (_) {
        actual = null;
      }
    }
    if (actual == null || actual <= Duration.zero) {
      // URL 已成功加载但拿不到时长（车机 CDN 冷启动/大文件 FLAC 慢网速、
      // 播放器时长上报延迟等）。CeruMusic/LX Music 都是直接把插件返回的
      // 酷我地址交给播放器，不做时长校验；这里同样放行，避免把可正常播放
      // 的真实歌曲误判为失败。提示音仍会在时长可得时被下方校验拦截。
      debugPrint(
        '[MusicAudioHandler] Kuwo media duration unavailable, '
        'playing anyway: $url',
      );
      return;
    }

    final error = kuwoDurationValidationError(song!, actual);
    if (error != null) {
      debugPrint(
        '[MusicAudioHandler] rejected Kuwo media: $error '
        'urlHost=${Uri.tryParse(url)?.host ?? 'invalid'}',
      );
      throw FormatException(error);
    }
  }

  /// 校验酷我音频实际加载时长是否与歌曲预期一致。
  ///
  /// 真实播放与插件测试共用同一套规则，保证"测试通过"即"实际可播"：
  /// 返回 null 表示时长可接受，否则返回拒绝原因。歌曲预期时长未知时，
  /// 用绝对阈值拦截明显过短的提示音；预期已知时允许小幅出入（编曲
  /// 前后奏差异），但提示音远超此容差会被拒绝。
  static String? kuwoDurationValidationError(Song song, Duration actual) {
    if (song.source != 'kw') return null;

    final actualSeconds = actual.inSeconds;
    final expectedSeconds = song.duration;

    // 没有预期时长时，用绝对阈值拦截明显的提示音/错误音频。
    if (expectedSeconds <= 0) {
      const minRealSongSeconds = 25;
      if (actualSeconds < minRealSongSeconds) {
        return '酷我音频时长过短（${actualSeconds}s），疑似提示音';
      }
      return null;
    }

    // Search results can differ by a few seconds because of intro/outro
    // edits. A short prompt, however, is far outside this tolerance.
    final tolerance = max(8, (expectedSeconds * 0.12).round());
    if ((actualSeconds - expectedSeconds).abs() > tolerance) {
      return '酷我音频时长(${actualSeconds}s)与歌曲预期(${expectedSeconds}s)不符';
    }
    return null;
  }

  /// 需要宿主补齐默认请求头的音乐平台域名。
  ///
  /// 只给这些已知平台 / CDN 加：第三方解析接口（如 Meting、各类取地址 API）
  /// 常按 UA 做防盗链，**浏览器 UA 会被直接 418**，播放器拿到 418 就报
  /// 「Failed to open」；这类地址补任何 UA 都不如不补——让播放器用自己的 UA
  /// （libmpv 的 Lavf、ExoPlayer 的自身 UA）去请求，302 也能正常跟随。
  static bool needsDefaultHeaders(String host) {
    if (host.isEmpty) return false;
    const domains = <String>[
      'kuwo.cn',
      'kugou.com',
      'kgmusic.cn',
      'music.126.net',
      '163.com',
      'qq.com',
      'migu.cn',
      'bilibili.com',
      'bilivideo.com',
      'hdslb.com',
      'acgvideo.com',
      // 汽水（字节系）
      'douyinvod.com',
      'byteimg.com',
    ];
    for (final domain in domains) {
      if (host == domain || host.endsWith('.$domain')) return true;
    }
    return false;
  }

  /// 是否让 just_audio 用本地 HTTP 代理来转发请求头。
  ///
  /// 只有 iOS 还在用。桌面端走 media_kit/mpv，请求头由插件直接写进 mpv 的
  /// `http-header-fields`（`MediaKitPlayer` 里的 `Media(uri, httpHeaders:)`）；
  /// Android 走 ExoPlayer，just_audio 在 `useProxyForRequestHeaders: false`
  /// 时用 `DefaultHttpDataSource` 的 `setUserAgent` +
  /// `setDefaultRequestProperties` 原生带请求头（见 just_audio 的
  /// AudioPlayer.java `buildDataSourceFactory`）， seek 时 ExoPlayer 直接对
  /// CDN 发 `Range: bytes=…`，不需要代理。
  ///
  /// 代理有害（`_proxyHandlerForUri` 是「读一块 → add → flush」，而 Dart 的
  /// `HttpResponse.flush()` 在客户端不读时照样立刻完成，数据只是排进内存
  /// 队列）：
  /// - Windows（mpv 取满 4MB 缓存停手后，代理仍把剩余响应体一路拉进 Dart
  ///   堆）：表现为「暂停状态拖动进度条，整首歌都被下载下来」，rss 一直涨
  ///   （实测 40MB 的响应，客户端只读 1MB，源站 4 秒内被拉走 9MB 且不会停）；
  /// - Android（ExoPlayer seek 时断开旧连接、带着 Range 重新请求，但代理把
  ///   客户端请求当成「从 0 开始读整个文件」，已跳过的部分照样被完整拉进
  ///   Dart 堆）：表现为「拖到哪就先把前面整段下载完」。
  /// 直连后由播放器自己按住 TCP 反压，只取它需要的量。
  ///
  /// 判断依据是「后端能不能自己带请求头」：Windows/Linux 的 media_kit/mpv
  /// 用 `http-header-fields`、Android 的 ExoPlayer 用
  /// `setDefaultRequestProperties`、iOS 的 AVFoundation 用
  /// `AVURLAssetHTTPHeaderFieldsKey`，都能直连。iOS 暂未放开（未经真机
  /// 验证），验证后再一起关掉。
  static bool get usesProxyForRequestHeaders => Platform.isIOS;

  /// 请求头里哪些域名该配哪家的 Referer。
  ///
  /// 按 **host** 判断，不要按整条 URL 的子串：`m7.music.126.net` 里既没有
  /// `163` 也没有 `netease`，用子串匹配会漏配（线上表现是「只有 UA 没有
  /// Referer」）。这里与 [needsDefaultHeaders] 用同一份域名口径。
  static const _refererByDomain = <String, String>{
    'kuwo.cn': 'https://www.kuwo.cn/',
    'kugou.com': 'https://www.kuwo.cn/',
    'kgmusic.cn': 'https://www.kuwo.cn/',
    'migu.cn': 'https://music.migu.cn/',
    'qq.com': 'https://y.qq.com/',
    'music.126.net': 'https://music.163.com/',
    '163.com': 'https://music.163.com/',
  };

  static String? _refererForHost(String host) {
    if (host.isEmpty) return null;
    for (final entry in _refererByDomain.entries) {
      final domain = entry.key;
      if (host == domain || host.endsWith('.$domain')) return entry.value;
    }
    return null;
  }

  /// 构建 CDN 音频请求头（含各源 Referer 与酷我车机 CDN 无头规则）。
  ///
  /// 是否附加「默认请求头」见 [needsDefaultHeaders]：未知域名不加，交给播放器
  /// 自己请求（避免把浏览器 UA 塞给按 UA 防盗链的第三方解析接口）。
  ///
  /// 公开为静态方法，插件测试等服务可复用同一套请求头规则。
  static Map<String, String> audioHeadersForUrl(
    String url, {
    Map<String, String>? songHeaders,
    Map<String, String>? extraHeaders,
  }) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    // 酷我车机 CDN 对所有 `car-*.kuwo.cn` 域名都敏感，额外请求头可能导致
    // 返回 11 秒免费试听提示音，因此这些地址保持无请求头。
    final isKuwoMediaCdn = host.startsWith('car-') && host.endsWith('.kuwo.cn');
    final headers = <String, String>{};

    // CeruMusic/LX Music assign Kuwo media URLs directly to an audio element.
    // Extra request headers can make this signed CDN return the 11-second
    // free-listening prompt, so keep this host header-free by default.
    if (!isKuwoMediaCdn && needsDefaultHeaders(host)) {
      // 这里只放播放器真正需要的头。`Accept-Encoding` / `Connection` 曾经
      // 也在这里，但出口的 [_stripHopByHopHeaders] 会把它们剔掉（播放器按
      // identity 取原始字节，这两类头交给它自己管），留着只会让人以为生效。
      headers.addAll({
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*',
      });
      final referer = _refererForHost(host);
      if (referer != null) headers['Referer'] = referer;
    }

    // Kuwo's signed media CDN is sensitive to request headers. A Referer,
    // browser defaults, or plugin-provided headers can make it return the
    // short free-listening prompt. CeruMusic/LX assign these URLs directly
    // without forcing headers, so keep this host completely header-free.
    if (!isKuwoMediaCdn) {
      if (songHeaders != null) headers.addAll(songHeaders);
      if (extraHeaders != null) headers.addAll(extraHeaders);
    }
    return _stripHopByHopHeaders(headers);
  }

  /// 播放器不吃、甚至会坏事的那几类头（插件常把浏览器的整套头原样给出）。
  ///
  /// * `host`：由 URL 决定，硬塞插件里的值会让 CDN 收到错误 Host；
  /// * `accept-encoding`：插件多写 `gzip, deflate, br`，播放器按 identity 取
  ///   原始字节，真返回压缩流就解不出来（下载侧同样剔除，见
  ///   `download_repository`）；
  /// * `connection` / `content-length` / `transfer-encoding` / `range`：
  ///   hop-by-hop 或由播放器自己管理，交给它反而会打断分片请求。
  static const _droppedPlaybackHeaders = <String>{
    'host',
    'accept-encoding',
    'content-encoding',
    'connection',
    'keep-alive',
    'content-length',
    'transfer-encoding',
    'range',
  };

  static Map<String, String> _stripHopByHopHeaders(
    Map<String, String> headers,
  ) {
    final out = <String, String>{};
    headers.forEach((key, value) {
      final name = key.trim();
      if (name.isEmpty || value.trim().isEmpty) return;
      if (_droppedPlaybackHeaders.contains(name.toLowerCase())) return;
      out[name] = value;
    });
    return out;
  }

  Future<void> skipToIndex(int index) async {
    if (kDebugMode) debugPrint('MusicAudioHandler: 跳转到索引 $index');
    await _player.seek(Duration.zero, index: index);
  }

  Future<void> onPlay() async {
    if (kDebugMode) debugPrint('MusicAudioHandler: onPlay callback');
    await play();
  }

  Future<void> onPause() async {
    if (kDebugMode) debugPrint('MusicAudioHandler: onPause callback');
    await pause();
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
  }

  @override
  Future<void> play() async {
    unawaited(
      _player.play().catchError((Object e, StackTrace stackTrace) {
        debugPrint('[MusicAudioHandler] play() error: $e');
        if (!_errorController.isClosed) {
          _errorController.add('playback_play_failed');
        }
      }),
    );
    _tryUpdateDurationFromPlayer();
  }

  @override
  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (e) {
      debugPrint('[MusicAudioHandler] pause() error: $e');
    }
  }

  @override
  Future<void> stop() async {
    if (kDebugMode) debugPrint('MusicAudioHandler: 停止播放');
    // 先通知控制器作废在途请求，再停播放器：idle 事件到达时，错误监听器
    // 必须已经被作废，否则会把这次主动 stop 误判成播放中断并自动续播。
    onStopRequested?.call();
    try {
      await _player.stop();
    } catch (e) {
      debugPrint('[MusicAudioHandler] stop() error: $e');
    }
    // super.stop()（BaseAudioHandler）负责把 processingState 推成 idle：
    // Android 端只有收到「非 idle → idle」的跳变才会收回通知栏 / 停掉前台服务。
    // 所以上面停播放器失败也必须走到这里，否则通知栏会一直留着。
    await super.stop();
  }

  /// 清空整个媒体会话：停止播放并彻底抹掉通知栏 / 系统媒体控制里的曲目信息。
  ///
  /// 顺序参照 MusicFree 的 `TrackPlayer.clearPlayList()`（先清列表与当前曲目，
  /// 再硬重置底层播放器，最后清持久化）。
  ///
  /// 关键点在于 audio_service 的 Android 端**只在「非 idle → idle」的状态跳变
  /// 时**才调用 `stop()` 收回通知栏（`AudioService.setPlaybackState`）：
  /// ```java
  /// if (oldProcessingState != idle && processingState == idle) stop();
  /// ```
  /// 所以 idle 状态必须作为**最后一次广播**推出去，且不能被
  /// [_suppressBroadcast] 拦掉，否则通知栏会一直停在「暂停」。
  /// 另外 `mediaItem.add(null)` 对平台侧是无效的——audio_service 的
  /// `_observeMediaItem` 开头就 `if (mediaItem == null) return;`，所以真正
  /// 清掉通知栏的是上面那个 idle 跳变。
  Future<void> clearMediaSession() async {
    if (kDebugMode) debugPrint('MusicAudioHandler: 清空媒体会话');

    // 置位：此后所有过期的 setAudioSource / setSource 都会被忽略，
    // 避免在途的取URL / 音质切换流程把已删除的曲目写回通知栏。
    _sessionCleared = true;

    _suppressBroadcast = true;
    try {
      try {
        await _player.stop();
      } catch (e) {
        debugPrint('MusicAudioHandler: clearMediaSession stop error: $e');
      }
      // 卸掉音源，否则通知栏的「播放」按钮仍能把声音放出来。
      // just_audio 0.9.x 的 setAudioSource 不接受 null，只能把
      // ConcatenatingAudioSource 里的条目全部清空。
      try {
        final source = _player.audioSource;
        if (source is ConcatenatingAudioSource) {
          await source.clear();
        }
      } catch (e) {
        debugPrint('MusicAudioHandler: clearMediaSession unload error: $e');
      }
      queue.add(const <MediaItem>[]);
      mediaItem.add(null);
    } finally {
      _suppressBroadcast = false;
    }

    // 放在 finally 之外，保证这是最后一次、且不受屏蔽影响的 idle 广播，
    // 从而在 Android 侧触发 non-idle → idle 跳变并移除通知栏。
    playbackState.add(_emptyPlaybackState);
  }

  @override
  Future<void> seek(Duration position) async {
    if (kDebugMode) debugPrint('MusicAudioHandler: 跳转到 ${position.inSeconds}秒');
    await _player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    if (kDebugMode) debugPrint('MusicAudioHandler: 下一首（通知栏）');
    onSkipNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    if (kDebugMode) debugPrint('MusicAudioHandler: 上一首（通知栏）');
    onSkipPrevious?.call();
  }

  Future<void> updateQueueItem(int index, Song song) async {
    if (kDebugMode)
      debugPrint('MusicAudioHandler: 更新队列项 $index: ${song.title}');

    final newQueue = List<MediaItem>.from(queue.value);
    if (index >= 0 && index < newQueue.length) {
      newQueue[index] = _songToMediaItem(song);
      queue.add(newQueue);
    }

    final currentPlaylist = _player.audioSource as ConcatenatingAudioSource?;
    if (currentPlaylist != null &&
        index >= 0 &&
        index < currentPlaylist.length) {
      await currentPlaylist.removeAt(index);
      await currentPlaylist.insert(index, _songToAudioSource(song));

      if (_player.currentIndex == index) {
        await _setPlayerSource(currentPlaylist, initialIndex: index);
      }
    }

    if (kDebugMode) debugPrint('MusicAudioHandler: 队列项更新成功');
  }

  /// Refreshes notification artwork without rebuilding the active audio
  /// source. Replacing a source solely for a late cover response can interrupt
  /// playback on some Android devices.
  void updateCurrentMediaItem(Song song) {
    final index = _player.currentIndex;
    final updatedItem = _songToMediaItem(song);
    mediaItem.add(updatedItem);

    if (index != null && index >= 0 && index < queue.value.length) {
      final updatedQueue = List<MediaItem>.from(queue.value);
      updatedQueue[index] = updatedItem;
      queue.add(updatedQueue);
    }
  }

  AudioProcessingState _mapProcessingState(ProcessingState state) {
    switch (state) {
      case ProcessingState.idle:
        return AudioProcessingState.idle;
      case ProcessingState.loading:
        return AudioProcessingState.loading;
      case ProcessingState.buffering:
        return AudioProcessingState.buffering;
      case ProcessingState.ready:
        return AudioProcessingState.ready;
      case ProcessingState.completed:
        return AudioProcessingState.completed;
    }
  }

  Future<void> dispose() async {
    debugPrint('MusicAudioHandler: 释放资源');
    WidgetsBinding.instance.removeObserver(this);
    await _positionFeed?.cancel();
    _positionFeed = null;
    await _positionController.close();
    _errorController.close();
    await _player.dispose();
  }
}
