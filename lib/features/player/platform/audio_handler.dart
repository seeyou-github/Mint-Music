import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../domain/models/song.dart';
import '../../../shared/services/cache_paths.dart';
import '../../../shared/services/cover_cache_service.dart';
import 'audio_cache_service.dart';

class MusicAudioHandler extends BaseAudioHandler
    with QueueHandler, SeekHandler {
  final AudioPlayer _player = AudioPlayer();
  final StreamController<String> _errorController =
      StreamController<String>.broadcast();

  DateTime? _lastPositionBroadcast;
  static const _positionBroadcastInterval = Duration(milliseconds: 200);

  Stream<Duration> get positionStream => _player.positionStream;
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

  /// 会话是否已被清空。
  ///
  /// 清空播放列表后，任何**残留的在途请求**（取URL / 自动换源 / 音质切换，
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

  MusicAudioHandler() {
    _init();
  }

  Future<void> _init() async {
    _player.playbackEventStream.listen((event) {
      _broadcastState();
    });

    _player.positionStream.listen((position) {
      final now = DateTime.now();
      if (_lastPositionBroadcast == null ||
          now.difference(_lastPositionBroadcast!) >=
              _positionBroadcastInterval) {
        _lastPositionBroadcast = now;
        _broadcastState();
      }
    });

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

  void _broadcastState() {
    // 清空会话时不要把「带控件的播放状态」推回去，否则通知栏会被重新点亮。
    if (_suppressBroadcast) return;
    // 没有任何曲目时只广播「无控件 + idle」状态。清空播放列表后，
    // _player 仍会吐出零星的位置/状态事件，若此时照常广播带控件的状态，
    // audio_service 会把通知栏重新点亮（旧曲目 + 可点的播放键）。
    if (mediaItem.value == null || queue.value.isEmpty) {
      playbackState.add(_emptyPlaybackState);
      return;
    }
    final processingState = _mapProcessingState(_player.processingState);
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

    debugPrint('[MusicAudioHandler] duration updated: ${duration.inSeconds}s');
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
    session.interruptionEventStream.listen((event) {
      if (event.begin) {
        // duck 只是系统临时压低音量（导航播报），并未停止播放，不要暂停。
        // pause 才是真正被中断（来电等），按预期暂停。
        if (event.type == AudioInterruptionType.pause) {
          pause();
        }
      } else {
        // 中断结束。若我们从未收到暂停事件（短暂的焦点抢占，切后台时最常见），
        // 说明 App 侧一直以为在播放，这里补一次恢复，避免停播后不再自动继续。
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
      debugPrint(
        '[MusicAudioHandler] processingState: $_lastProcessingState → $current, playing=${state.playing}',
      );

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
        artUri = Uri.parse(song.coverUrl!);
      } else if (song.coverUrl!.startsWith('content://')) {
        artUri = Uri.parse(song.coverUrl!);
      } else {
        artUri = Uri.file(song.coverUrl!);
      }
    }

    final duration = song.duration > 0
        ? Duration(seconds: song.duration)
        : null;

    debugPrint(
      '[MusicAudioHandler] _songToMediaItem: ${song.title}, song.duration=${song.duration}s, mediaItem.duration=${duration?.inSeconds}s',
    );

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
    debugPrint(
      'MusicAudioHandler: 设置播放队列 - ${songs.length}首, 起始索引: $startIndex',
    );
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
      await _player.setAudioSource(playlist, initialIndex: startIndex);

      if (startIndex >= 0 && startIndex < mediaItems.length) {
        mediaItem.add(mediaItems[startIndex]);
      }

      _tryUpdateDurationFromPlayer();

      debugPrint('MusicAudioHandler: 队列设置成功');
    } catch (e) {
      debugPrint('MusicAudioHandler: 队列设置失败: $e');
      rethrow;
    }
  }

  Future<List<Song>> _prepareLocalCovers(
    List<Song> songs, {
    int currentIndex = -1,
  }) async {
    final result = List<Song?>.filled(songs.length, null);
    final coverCache = CoverCacheService();

    Future<Song> processSong(Song song) async {
      // 桌面端没有 MediaStore，封面由扫描时写入封面缓存，这里同样能取到。
      if (song.coverUrl == null &&
          (song.mediaStoreId != null || song.source == 'local')) {
        try {
          // 优先从 CoverCacheService 获取（内存/磁盘缓存 + MediaStore 提取）
          final bytes = await coverCache.getArtwork(
            song.id,
            mediaStoreId: song.mediaStoreId,
          );
          if (bytes != null && bytes.isNotEmpty) {
            // 写入播放器专用的缓存目录（供 MediaSession 使用）
            final coverDir = await _getCoverCacheDir();
            final coverPath = '${coverDir!.path}/${song.id}.jpg';
            if (!await File(coverPath).exists()) {
              await File(coverPath).writeAsBytes(bytes);
            }
            return song.copyWith(coverUrl: coverPath);
          }
        } catch (e) {
          debugPrint('MusicAudioHandler: 提取封面失败 ${song.title}: $e');
        }
      }
      return song;
    }

    if (currentIndex >= 0 && currentIndex < songs.length) {
      result[currentIndex] = await processSong(songs[currentIndex]);
    }

    final futures = <Future<void>>[];
    for (int i = 0; i < songs.length; i++) {
      if (i != currentIndex) {
        futures.add(
          processSong(songs[i]).then((s) {
            result[i] = s;
          }),
        );
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }

    for (int i = 0; i < songs.length; i++) {
      result[i] ??= songs[i];
    }

    return result.cast<Song>();
  }

  Future<Directory> _getCoverCacheDir() async {
    return CachePaths.subDirectory('covers');
  }

  Future<void> setSource(Song song) async {
    debugPrint('MusicAudioHandler: 开始设置音源 - 歌曲: ${song.title}');

    if (_sessionCleared) {
      debugPrint('MusicAudioHandler: 会话已清空，忽略过期的 setSource');
      return;
    }

    if (song.sourceUrl != null) {
      debugPrint('MusicAudioHandler: 音源URL: ${song.sourceUrl}');

      try {
        final prepared = await _prepareLocalCovers([song], currentIndex: 0);
        final preparedSong = prepared[0];
        final mediaItem = _songToMediaItem(preparedSong);
        queue.add([mediaItem]);

        await _player.setAudioSource(
          ConcatenatingAudioSource(
            children: [_songToAudioSource(preparedSong)],
          ),
        );

        this.mediaItem.add(mediaItem);
        debugPrint('MusicAudioHandler: 音源设置成功');
      } catch (e) {
        debugPrint('MusicAudioHandler: 设置音源失败: $e');
        rethrow;
      }
    } else {
      debugPrint('MusicAudioHandler: 错误 - 歌曲没有音源URL');
    }
  }

  Future<void> setAudioSource(
    String url, {
    Song? song,
    Map<String, String>? headers,
  }) async {
    debugPrint(
      'MusicAudioHandler: 设置音频源: ${url.substring(0, url.length > 60 ? 60 : url.length)}...',
    );

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

        // 命中音频缓存：直接播放本地文件（秒开、不消耗流量）。
        //
        // 缓存键必须用「解析这个地址时请求的音质」，不能用兜底值：兜底成
        // 320k 会把 128k 的音频存成 320k，之后切换音质或重播就会拿错文件
        // （界面显示 320k、实际播的是 128k 缓存）。音质未知时干脆不走缓存。
        final cacheQuality = song?.sourceQuality ?? '';
        final cachedFile = song != null && cacheQuality.isNotEmpty
            ? await AudioCacheService.findCachedFile(
                songId: song.id,
                quality: cacheQuality,
                source: song.source,
                artist: song.artist,
                title: song.title,
                url: url,
              )
            : null;

        if (cachedFile != null) {
          debugPrint(
            'MusicAudioHandler: 命中音频缓存 -> ${cachedFile.path}',
          );
          await _player.setAudioSource(
            ConcatenatingAudioSource(
              children: [
                AudioSource.uri(Uri.file(cachedFile.path), tag: mediaItem),
              ],
            ),
          );
        } else {
          final audioSource = requestHeaders.isEmpty
              ? AudioSource.uri(uri, tag: mediaItem)
              : AudioSource.uri(uri, tag: mediaItem, headers: requestHeaders);
          await _player.setAudioSource(
            ConcatenatingAudioSource(children: [audioSource]),
          );
          // 后台把音频缓存一份到「缓存目录」，下次播放即可直接走本地文件。
          if (song != null && cacheQuality.isNotEmpty) {
            unawaited(
              AudioCacheService.cacheInBackground(
                url: url,
                headers: requestHeaders,
                songId: song.id,
                quality: cacheQuality,
                source: song.source,
                artist: song.artist,
                title: song.title,
              ),
            );
          }
        }
        await _validateRemoteSongDuration(preparedSong, url);
      } else {
        await _player.setAudioSource(
          ConcatenatingAudioSource(
            children: [AudioSource.uri(uri, tag: mediaItem)],
          ),
        );
      }

      queue.add([mediaItem]);
      this.mediaItem.add(mediaItem);
      debugPrint('MusicAudioHandler: 音频源设置成功');
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

  /// 构建 CDN 音频请求头（含各源 Referer 与酷我车机 CDN 无头规则）。
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
    if (!isKuwoMediaCdn) {
      headers.addAll({
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Accept-Encoding': 'identity',
        'Connection': 'keep-alive',
      });
    }

    if (!isKuwoMediaCdn && (url.contains('kuwo') || url.contains('kugou'))) {
      headers['Referer'] = 'https://www.kuwo.cn/';
    } else if (!isKuwoMediaCdn && url.contains('migu')) {
      headers['Referer'] = 'https://music.migu.cn/';
    } else if (!isKuwoMediaCdn &&
        (url.contains('qq.com') || url.contains('qqmusic'))) {
      headers['Referer'] = 'https://y.qq.com/';
    } else if (!isKuwoMediaCdn &&
        (url.contains('163') || url.contains('netease'))) {
      headers['Referer'] = 'https://music.163.com/';
    }

    // Kuwo's signed media CDN is sensitive to request headers. A Referer,
    // browser defaults, or plugin-provided headers can make it return the
    // short free-listening prompt. CeruMusic/LX assign these URLs directly
    // without forcing headers, so keep this host completely header-free.
    if (!isKuwoMediaCdn) {
      if (songHeaders != null) headers.addAll(songHeaders);
      if (extraHeaders != null) headers.addAll(extraHeaders);
    }
    return headers;
  }

  Future<void> skipToIndex(int index) async {
    debugPrint('MusicAudioHandler: 跳转到索引 $index');
    await _player.seek(Duration.zero, index: index);
  }

  Future<void> onPlay() async {
    debugPrint('MusicAudioHandler: onPlay callback');
    await play();
  }

  Future<void> onPause() async {
    debugPrint('MusicAudioHandler: onPause callback');
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
    debugPrint('MusicAudioHandler: 停止播放');
    await _player.stop();
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
    debugPrint('MusicAudioHandler: 清空媒体会话');

    // 置位：此后所有过期的 setAudioSource / setSource 都会被忽略，
    // 避免在途的取URL / 自动换源流程把已删除的曲目写回通知栏。
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
    debugPrint('MusicAudioHandler: 跳转到 ${position.inSeconds}秒');
    await _player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    debugPrint('MusicAudioHandler: 下一首（通知栏）');
    onSkipNext?.call();
  }

  @override
  Future<void> skipToPrevious() async {
    debugPrint('MusicAudioHandler: 上一首（通知栏）');
    onSkipPrevious?.call();
  }

  Future<void> updateQueueItem(int index, Song song) async {
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
        await _player.setAudioSource(currentPlaylist, initialIndex: index);
      }
    }

    debugPrint('MusicAudioHandler: 队列项更新成功');
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
    _errorController.close();
    await _player.dispose();
  }
}
