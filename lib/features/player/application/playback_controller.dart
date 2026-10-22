import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../data/playback_state_store.dart';
import '../domain/models/song.dart';
import '../domain/models/playback_state.dart';
import '../domain/models/play_mode.dart';
import '../platform/audio_handler.dart';
import '../platform/audio_effect_service.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/services/audio_service_init.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../settings/application/settings_providers.dart';
import 'auto_switch_source_service.dart';
import '../../local/application/local_providers.dart';

final audioHandlerProvider = Provider<MusicAudioHandler>((ref) {
  return audioHandler;
});

bool _hasPlayableUrl(String? url) => url != null && url.isNotEmpty;

final playbackControllerProvider =
    StateNotifierProvider<PlaybackController, PlaybackState>((ref) {
      final audioHandler = ref.watch(audioHandlerProvider);
      final musicSourceManager = ref.watch(musicSourceManagerProvider);
      final controller = PlaybackController(
        audioHandler,
        musicSourceManager,
        audioEffectService,
      );
      controller.onSongUpdated = (song) {
        ref.read(localMusicNotifierProvider.notifier).upsertSong(song);
        controller.updateSongInQueue(song);
      };

      controller.getQualityForSource = (sourceId) {
        final sourceQuality = ref.read(sourceQualityProvider);
        final globalQuality = ref.read(globalQualityProvider);
        final sourceName = kSourceIdToName[sourceId];
        if (sourceName != null && sourceQuality.containsKey(sourceName)) {
          return sourceQuality[sourceName]!;
        }
        return globalQuality;
      };
      // 用户在播放页切换音质后，默认音质与全局音质都跟着更新。
      controller.onQualityChanged = (quality, sourceId) {
        unawaited(
          persistUserQuality(
            ref,
            quality: quality,
            sourceId: sourceId,
          ),
        );
      };
      controller.setAutoQualityDowngrade(
        ref.read(autoQualityDowngradeProvider),
      );
      controller.setAutoSwitchSource(ref.read(autoSwitchSourceProvider));
      controller.onEnsureMusicSourcesReady = () =>
          ref.read(pluginInitializedProvider.future);

      ref.listen(rememberProgressProvider, (prev, next) {
        controller.setRememberProgress(next);
      });

      ref.listen(autoQualityDowngradeProvider, (prev, next) {
        controller.setAutoQualityDowngrade(next);
      });

      ref.listen(autoSwitchSourceProvider, (prev, next) {
        controller.setAutoSwitchSource(next);
      });

      void syncAudioEffects() {
        controller.setAudioEffects(
          AudioEffectsConfig(
            masterEnabled: ref.read(audioEffectEnabledProvider),
            equalizerEnabled: ref.read(equalizerEnabledProvider),
            equalizerBands: List<double>.from(ref.read(equalizerBandsProvider)),
            bassBoostEnabled: ref.read(bassBoostEnabledProvider),
            bassBoostGain: ref.read(bassBoostGainProvider),
            surroundEnabled: ref.read(surroundEnabledProvider),
            surroundMode: ref.read(surroundModeProvider),
            balanceEnabled: ref.read(balanceEnabledProvider),
            balance: ref.read(balanceValueProvider),
            visualizerEnabled: ref.read(audioVisualizerEnabledProvider),
          ),
        );
      }

      ref.listen(audioEffectEnabledProvider, (_, __) => syncAudioEffects());
      ref.listen(equalizerEnabledProvider, (_, __) => syncAudioEffects());
      ref.listen(equalizerBandsProvider, (_, __) => syncAudioEffects());
      ref.listen(bassBoostEnabledProvider, (_, __) => syncAudioEffects());
      ref.listen(bassBoostGainProvider, (_, __) => syncAudioEffects());
      ref.listen(surroundEnabledProvider, (_, __) => syncAudioEffects());
      ref.listen(surroundModeProvider, (_, __) => syncAudioEffects());
      ref.listen(balanceEnabledProvider, (_, __) => syncAudioEffects());
      ref.listen(balanceValueProvider, (_, __) => syncAudioEffects());
      syncAudioEffects();

      // 播放记忆：保存／恢复进度
      ref
          .read(settingsServiceProvider.future)
          .then((svc) async {
            controller.setRememberProgress(svc.getRememberProgress());
            controller.setAutoQualityDowngrade(svc.getAutoQualityDowngrade());
            controller.setAutoSwitchSource(svc.getAutoSwitchSource());
            unawaited(controller.setSpeed(svc.getPlaybackSpeed()));
            // 播放状态每 5 秒就要存一次，属于高频写入，放在临时库里；
            // 队列只有变化时才写那几十 KB，高频保存只动当前歌曲那一行。
            final stateStore = PlaybackStateStore();
            await stateStore.load();
            controller.onSavePlaybackState = (data) {
              stateStore.save(data);
            };
            controller.onRestorePlaybackState = () => stateStore.restore();
            controller.onClearPlaybackState = () => stateStore.clear();
            // 回调就绪后自动恢复上次播放会话
            // 直接从偏好设置读取音质，避免 provider 未初始化的竞态
            final persistedQuality = svc.getGlobalQuality();
            final persistedSourceQuality = svc.getSourceQuality();
            await controller.restoreLastSession(
              autoPlay: svc.getAutoPlay(),
              rememberProgress: svc.getRememberProgress(),
              quality: persistedQuality,
              sourceQualities: persistedSourceQuality,
            );
          })
          .catchError((e) {
            debugPrint('[PlaybackController] settingsService error: $e');
          });

      ref.onDispose(() => controller.dispose());
      return controller;
    });

// Song equality intentionally uses the stable queue ID. Cross-source fallback
// keeps that ID, so UI consumers need a separate signal for visible song
// metadata. Quality switching replaces only the transient audio URL, so it
// must not make player pages behave as if a new song was selected.
final currentSongIdentityProvider = Provider<int>((ref) {
  final song = ref.watch(playbackControllerProvider).currentSong;
  if (song == null) return 0;
  return Object.hashAll([
    song.id,
    song.source,
    song.title,
    song.artist,
    song.album,
    song.coverUrl,
    song.lyricUrl,
    song.lrc,
  ]);
});

const _sourceIdToChineseName = {
  'wy': '网易云音乐',
  'tx': 'QQ音乐',
  'kg': '酷狗音乐',
  'kw': '酷我音乐',
  'mg': '咪咕音乐',
  'local': '本地音乐',
};

/// 音源展示名：内置音源带「-内置」，插件音源带插件名。
///
/// 播放地址由插件解析时，歌曲的音源字段可能还是内置源的平台 id，这里统一
/// 交给音源管理器给出与切换列表一致的名称。
String _getSourceName(String sourceId, MusicSourceManager manager) {
  if (sourceId.isEmpty) return sourceId;
  final name = manager.sourceDisplayName(sourceId);
  if (name.isNotEmpty) return name;
  return _sourceIdToChineseName[sourceId] ?? sourceId;
}

class PlaybackController extends StateNotifier<PlaybackState> {
  final MusicAudioHandler _audioHandler;
  final MusicSourceManager _musicSourceManager;
  final AudioEffectService _audioEffectService;
  late final AutoSwitchSourceService _autoSwitchService;

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _bufferedSub;
  StreamSubscription<Duration?>? _durationSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StreamSubscription? _errorListenerSub;
  StreamSubscription<int?>? _audioSessionSub;

  void Function(Song)? onSongUpdated;
  void Function(String message, {Color? backgroundColor})? onMessage;
  String Function(String sourceId)? getQualityForSource;

  /// 用户手动切换音质后回调（用于同步「默认音质 / 全局音质」设置）。
  void Function(String quality, String? sourceId)? onQualityChanged;
  void Function(Map<String, dynamic> data)? onSavePlaybackState;
  Map<String, dynamic>? Function()? onRestorePlaybackState;
  VoidCallback? onClearPlaybackState;
  Future<void> Function()? onEnsureMusicSourcesReady;

  int _currentPlayRequestId = 0;
  int? _qualitySwitchRequestId;
  bool _settingQueue = false;
  Duration _lastEmittedPosition = Duration.zero;
  static const Duration _positionThrottle = Duration(milliseconds: 200);

  /// seek 后等待位置流追上目标位置的临时锁。
  ///
  /// 部分播放器在 seek 完成前还会吐出旧位置，如果直接接受会把刚更新的
  /// 进度条/歌词拽回旧位置。位置接近目标后立即解除。
  Duration? _seekTarget;
  Timer? _seekTargetTimer;

  bool _rememberProgress = true;
  bool _autoQualityDowngrade = false;

  /// 「当前音源播放失败自动切换音源」开关（默认关闭）。
  /// 关闭时播放失败直接停止播放，不跨音源换源、不自动播放下一首。
  bool _autoSwitchSource = false;
  bool _needsUrlRefresh = false;
  int? _pendingRestorePosition;
  String? _pendingRestoreSongId;
  Timer? _saveTimer;
  Timer? _loadingTimer;

  /// 看门狗武装时记录的播放位置，用于判断是否真的「没有进度」。
  Duration? _stallBaselinePosition;
  static const Duration _saveInterval = Duration(seconds: 5);
  static const Duration _loadingTimeout = Duration(seconds: 30);

  bool get _isSwitchingQuality =>
      _qualitySwitchRequestId != null &&
      _qualitySwitchRequestId == _currentPlayRequestId &&
      state.isLoading;

  /// 歌曲刚刚 natural complete 的标志。
  /// 设为 true 后，_playerStateSub 会在 completed→ready 过渡事件中
  /// 跳过 isPlaying 更新（因为 ExoPlayer 在 ENDED 状态下 playWhenReady
  /// 保持 true，seek(0) 后会错误地发出 playing=true 事件）。
  /// 带一个微任务周期后由 _playerStateSub 或 next() 清除。
  bool _justCompleted = false;

  /// CeruMusic 风格的自动下一首防重入标志。
  /// completed 事件中设为 true，Future.microtask 排空后执行 next()
  /// 前检查此标志。任何用户操作通过 _cancelPendingAutoNext() 清 false，
  /// 避免已入队的 microtask 仍然执行过期的 next()。
  bool _pendingAutoNext = false;

  void _cancelPendingAutoNext() {
    _pendingAutoNext = false;
  }

  PlaybackController(
    this._audioHandler,
    this._musicSourceManager,
    this._audioEffectService,
  ) : super(const PlaybackState()) {
    _autoSwitchService = AutoSwitchSourceService(
      musicSourceManager: _musicSourceManager,
      showMessage: (message, {backgroundColor}) {
        onMessage?.call(message, backgroundColor: backgroundColor);
      },
    );
    _init();
  }

  void setRememberProgress(bool enabled) {
    _rememberProgress = enabled;
    if (!enabled) {
      _stopSaveTimer();
    } else if (state.isPlaying) {
      _startSaveTimer();
    }
  }

  void setAutoQualityDowngrade(bool enabled) {
    _autoQualityDowngrade = enabled;
  }

  void setAutoSwitchSource(bool enabled) {
    _autoSwitchSource = enabled;
  }

  void setAudioEffects(AudioEffectsConfig config) {
    unawaited(_audioEffectService.apply(config));
  }

  void _savePlaybackState() {
    if (!_rememberProgress) return;
    final song = state.currentSong;
    if (song == null) return;
    final positionMs = state.position.inMilliseconds;
    if (positionMs <= 0) return;
    final persistedSong = _stripTransientPlaybackData(song);
    final persistedQueue = state.queue
        .map(_stripTransientPlaybackData)
        .toList();
    onSavePlaybackState?.call({
      'song': persistedSong.toJson(),
      'positionMs': positionMs,
      'queue': persistedQueue.map((s) => s.toJson()).toList(),
      'currentIndex': state.currentIndex,
      'currentQuality': state.currentQuality,
    });
  }

  /// Online music URLs and their headers often contain short-lived tokens.
  /// They must never survive process death; playback restoration always
  /// resolves a fresh URL from the original source metadata.
  Song _stripTransientPlaybackData(Song song) {
    if (song.source == 'local') return song;
    return song.copyWith(clearSourceUrl: true, clearSourceHeaders: true);
  }

  void _startSaveTimer() {
    _stopSaveTimer();
    _saveTimer = Timer.periodic(_saveInterval, (_) => _savePlaybackState());
  }

  void _stopSaveTimer() {
    _saveTimer?.cancel();
    _saveTimer = null;
  }

  /// 武装「加载卡死」看门狗。
  ///
  /// 原实现有两个问题，导致「切后台后当前播放会停止」这种偶发问题：
  /// 1. 用 `??=` 武装，Timer 触发后 `_loadingTimer` 仍非 null（非空但已过期），
  ///    之后再进入 loading 也永远不会重新计时，看门狗实质只生效一次；
  /// 2. 只要 `processingState == loading` 就算「卡死」。而 App 切到后台时，
  ///    Android 会重配音频路由 / 回收解码器，ExoPlayer 很容易短暂回到
  ///    `loading`——这是正常现象。原来的逻辑会在后台 30s 后把这首歌判死，
  ///    强制 `isPlaying = false` 并跳歌；队列只有一首时 `next()` 会直接
  ///    `pause()`，于是表现为「切后台后播放停了」。
  ///
  /// 现在改为：重新计时 + 记录基准进度 + 真正「没有进度」才算卡死，
  /// 并且 App 不在前台时一律不判定。
  void _armStallWatchdog() {
    _loadingTimer?.cancel();
    _stallBaselinePosition = state.position;
    _loadingTimer = Timer(_loadingTimeout, _onStallTimeout);
  }

  void _onStallTimeout() {
    // 置空后才能在下次 loading 时重新武装。
    _loadingTimer = null;
    if (!mounted || state.currentSong == null) return;
    // 已经恢复播放/不再加载，无需继续看门狗。
    if (!state.isLoading) {
      _stallBaselinePosition = null;
      return;
    }

    // App 不在前台时不判定卡死：此时 loading 多为音频路由重配的正常抖动。
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final inForeground =
        lifecycle == null || lifecycle == AppLifecycleState.resumed;

    // 必须「进度完全没动」才算卡死；仅仅处于 loading 可能只是缓冲偏慢。
    final baseline = _stallBaselinePosition;
    final noProgress = baseline == null || state.position <= baseline;

    if (!inForeground || !noProgress) {
      // 不跳歌，但只要还卡在 loading 就继续重新武装，保证回到前台后
      // 看门狗依然有效（否则后台这段时间里它就永久失效了）。
      if (state.currentSong != null) _armStallWatchdog();
      return;
    }

    debugPrint(
      '[PlaybackController] 加载超时（${_loadingTimeout.inSeconds}s）且无进度，停止播放',
    );
    _stallBaselinePosition = null;
    // 播放卡死 → 停止播放，不自动跳歌。
    unawaited(_stopPlaybackOnFailure(tr('播放加载超时')));
  }

  /// 启动时恢复上次播放会话（CeruMusic 风格：仅恢复队列+UI，不获取 URL）
  Future<void> restoreLastSession({
    required bool autoPlay,
    required bool rememberProgress,
    String quality = '320k',
    Map<String, String> sourceQualities = const {},
  }) async {
    _loadingTimer?.cancel();
    _loadingTimer = null;
    if (!autoPlay && !rememberProgress) return;
    if (state.queue.isNotEmpty) return;

    final data = onRestorePlaybackState?.call();
    if (data == null) return;

    final songJson = data['song'] as Map<String, dynamic>?;
    if (songJson == null) return;

    final positionMs = data['positionMs'] as int? ?? 0;
    final savedSong = Song.fromJson(songJson);

    // 恢复完整队列
    List<Song> queue;
    final queueJson = data['queue'] as List<dynamic>?;
    int currentIndex = data['currentIndex'] as int? ?? 0;
    if (queueJson != null && queueJson.isNotEmpty) {
      queue = queueJson
          .map((s) => Song.fromJson(s as Map<String, dynamic>))
          .toList();
      if (currentIndex < 0 || currentIndex >= queue.length) {
        currentIndex = queue.indexWhere((s) => s.id == savedSong.id);
        if (currentIndex < 0) currentIndex = 0;
      }
    } else {
      queue = [savedSong];
      currentIndex = 0;
    }

    // 清除所有在线歌曲的临时 URL 和请求头，避免重启后复用已过期的
    // token。历史版本的记录也在此统一清理。
    queue = queue.map(_stripTransientPlaybackData).toList();
    final restoredSong = queue[currentIndex];

    // 恢复队列和 UI 状态（含音质），不获取 URL 不设音源（延迟到用户点击播放时）
    final restoredQuality = (data['currentQuality'] as String?) ?? quality;
    state = state.copyWith(
      queue: queue,
      currentIndex: currentIndex,
      currentSong: restoredSong,
      currentQuality: restoredQuality,
      isLoading: false,
      isPlaying: false,
    );

    // 保存待恢复的进度位置（CeruMusic: pendingRestorePosition）
    if (positionMs > 0) {
      _pendingRestorePosition = positionMs;
      _pendingRestoreSongId = restoredSong.id;
    }

    // 标记首次播放需刷新 URL
    _needsUrlRefresh = true;

    // 清除已恢复的记忆，只保留待恢复位置（由 _pendingRestorePosition 携带）
    // 注意：不清除 SharedPrefs，让进度持续保留到用户实际播放时才清除
    // 这样即使用户下次打开不播放，再下次也能继续进度

    // autoPlay：直接走 play() → _needsUrlRefresh → playSongAt → 获取最新 URL
    if (autoPlay) {
      await play();
    }
  }

  Future<void> _restoreAndPlay(Song song) async {
    // 用户实际开始播放时，清除已恢复的记忆（确保下次启动重新读取 SharedPrefs）
    onClearPlaybackState?.call();
    if (_rememberProgress) {
      // 照搬 CeruMusic：仅消费 restoreLastSession 设置的一次性进度标记
      // _pendingRestorePosition → 在 restoreLastSession 中设置，
      // 由 onClearPlaybackState 清除 SharedPrefs，仅在首次播放时可用。
      // 不设回退读取 SharedPrefs 的路径，避免重新播放同源同首歌时误续进度。
      if (_pendingRestorePosition != null && _pendingRestoreSongId == song.id) {
        final savedPos = _pendingRestorePosition!;
        _pendingRestorePosition = null;
        _pendingRestoreSongId = null;
        if (savedPos > 0) {
          await _audioHandler.seek(Duration(milliseconds: savedPos));
        }
      } else {
        // 照搬 CeruMusic（else 分支 pendingRestorePosition = 0）：
        // 非恢复目标歌曲播放时立即清除待恢复进度，避免后续误用
        _pendingRestorePosition = null;
        _pendingRestoreSongId = null;
      }
    }
    await _audioHandler.play();
  }

  Future<void> _ensureMusicSourcesReady() async {
    final ensureReady = onEnsureMusicSourcesReady;
    if (ensureReady == null) return;

    try {
      await ensureReady().timeout(_musicSourceReadyTimeout);
    } catch (error) {
      // Built-in sources are still available if a plugin has a load problem,
      // so do not block playback forever. The current-source URL resolver
      // below will perform its own controlled retry.
      debugPrint(
        '[PlaybackController] music source initialization wait failed: $error',
      );
    }
  }

  Future<List<PluginMusicUrlResult>> _resolveCurrentSourceUrlCandidates(
    Song song, {
    required String quality,
    required int requestId,
    Set<String> excludedUrls = const <String>{},
  }) async {
    Future<List<PluginMusicUrlResult>> resolveOnce() async {
      try {
        return await _musicSourceManager
            .getMusicUrlResultCandidates(
              song,
              quality: quality,
              excludedUrls: excludedUrls,
            )
            .timeout(_urlFetchTimeout);
      } catch (error) {
        debugPrint(
          '[PlaybackController] current-source URL resolve failed: '
          'source=${song.source} error=$error',
        );
        return const <PluginMusicUrlResult>[];
      }
    }

    var candidates = await resolveOnce();
    if (candidates.isNotEmpty || _currentPlayRequestId != requestId) {
      return candidates;
    }

    // A cold launch can race plugin engine startup or hit a transient
    // provider request failure. Retry the original source once before the
    // cross-source fallback declares that source unavailable.
    await Future.delayed(const Duration(milliseconds: 400));
    if (_currentPlayRequestId != requestId) {
      return const <PluginMusicUrlResult>[];
    }

    debugPrint(
      '[PlaybackController] retrying current-source URL: '
      'source=${song.source} quality=$quality',
    );
    candidates = await resolveOnce();
    return candidates;
  }

  /// 换源后从原进度继续播放（如暂停期间 URL 过期，恢复时触发换源的场景），
  /// 避免重头播放。resumePosition 为 0 或已超过歌曲时长时跳过。
  Future<void> _resumeFromPosition(Duration resumePosition) async {
    if (resumePosition <= Duration.zero) return;
    final duration = _audioHandler.currentDuration;
    if (duration != null && resumePosition >= duration) return;
    await _audioHandler.seek(resumePosition);
  }

  bool get hasQueue => state.queue.isNotEmpty;

  void _init() {
    _audioSessionSub = _audioHandler.audioSessionIdStream.listen((sessionId) {
      unawaited(_audioEffectService.setSessionId(sessionId));
    });
    final currentSessionId = _audioHandler.currentAudioSessionId;
    if (currentSessionId != null) {
      unawaited(_audioEffectService.setSessionId(currentSessionId));
    }
    _positionSub = _audioHandler.positionStream.listen((position) {
      if (mounted) {
        final seekTarget = _seekTarget;
        if (seekTarget != null) {
          // seek 完成前可能还有旧位置事件，先忽略，避免歌词/进度条回跳。
          if ((position - seekTarget).abs() >
              const Duration(milliseconds: 500)) {
            return;
          }
          _seekTarget = null;
          _seekTargetTimer?.cancel();
          _seekTargetTimer = null;
        }
        final diff = (position - _lastEmittedPosition).abs();
        if (diff >= _positionThrottle) {
          _lastEmittedPosition = position;
          state = state.copyWith(position: position);
        }
      }
    });
    _bufferedSub = _audioHandler.bufferedPositionStream.listen((buffered) {
      if (mounted) {
        final diff = (buffered - state.buffered).abs();
        if (diff >= const Duration(seconds: 1)) {
          state = state.copyWith(buffered: buffered);
        }
      }
    });
    _durationSub = _audioHandler.durationStream.listen((duration) {
      if (mounted && duration != null && duration != Duration.zero) {
        state = state.copyWith(actualDuration: duration);
      }
    });
    _playerStateSub = _audioHandler.playerStateStream.listen((playerState) {
      if (!mounted) return;
      // 注意：这里不再用 _settingQueue 门控整个监听器。
      // 之前在 setQueue / playSongAt 期间整体忽略 playerStateStream，
      // 会导致 ready 等关键事件被丢弃，isPlaying / isLoading 长期错乱
      // （按钮卡在转圈、迷你播放器显示暂停态等）。
      // 这里改为始终响应 just_audio 的真实状态，仅在「当前歌曲尚未确定」的
      // 极短窗口内跳过 completed 自动切歌逻辑，避免误触发。
      final processingState = playerState.processingState;
      final isLoading = processingState == ProcessingState.loading;

      if (isLoading) {
        _armStallWatchdog();
      } else {
        _loadingTimer?.cancel();
        _loadingTimer = null;
        _stallBaselinePosition = null;
      }

      final wasPlaying = state.isPlaying;

      if (processingState == ProcessingState.ready ||
          processingState == ProcessingState.buffering) {
        // _justCompleted 在 completed 处理器中设置。
        // 后续可能收到两类 ready 事件：
        //   A. ready(playing=false) — 单曲队列 next() 中 seek(0) 触发，
        //      不应更新 isPlaying（ExoPlayer 在 ENDED 下 playWhenReady
        //      保持 true，seek 后误报 playing=true）。
        //   B. ready(playing=true)  — 正常切歌后 play() 的确认信号，
        //      必须用于更新 isPlaying。
        //
        // 区分：playing=true 时清除标记并继续正常处理；
        // playing=false 时跳过 isPlaying 更新（只清 isLoading）。
        if (_justCompleted) {
          if (playerState.playing) {
            // 播放器确认正在播放 → 清除 completed 标记，继续正常处理
            _justCompleted = false;
          } else {
            state = state.copyWith(isLoading: false);
            return;
          }
        }
        // 关键修复：ready(playing=true) 也必须突破 _settingQueue 守卫。
        //
        // playSongAt 内 setAudioSource() 发出 ready(playing=false)，
        // 然后 _restoreAndPlay → play() 发出 ready(playing=true)。
        // 这两个事件都是微任务，在 _settingQueue 仍为 true 时被处理：
        //   · ready(playing=false) → 被守卫拦住 ✅（不应覆盖 isLoading:true）
        //   · ready(playing=true)  → 也被拦住 ❌ —— 这是 play() 的确认信号，
        //     丢了它 isPlaying 永远 false、isLoading 永远 true，
        //     只有等下次用户操作（如点击通知栏按钮）触发新事件才能恢复。
        //
        // 解决方案：playing=true 的事件总是处理，不受 _settingQueue 门控。
        if ((!_settingQueue && !_isSwitchingQuality) || playerState.playing) {
          state = state.copyWith(
            isPlaying: playerState.playing,
            isLoading: false,
          );
        }
      } else if (processingState == ProcessingState.loading) {
        state = state.copyWith(isLoading: true);
        // isPlaying 不变（play()/playSongAt() 已乐观设置）
      } else if (processingState == ProcessingState.completed) {
        debugPrint('[PlaybackController] 歌曲播放完成');
        _justCompleted = true;
        state = state.copyWith(isPlaying: false, isLoading: false);
        // 使用 Future.microtask 延迟 next() 到所有 pending 的
        // playerStateStream 事件（idle/loading 等）处理完毕之后。
        // 直接调用 next() 可能与之竞态，导致 playSongAt 被中断。
        if (!_settingQueue && !_pendingAutoNext) {
          _pendingAutoNext = true;
          Future.microtask(() {
            if (mounted && _pendingAutoNext) {
              _pendingAutoNext = false;
              next();
            }
          });
        }
        // 注意：不在设 _justCompleted=false；由 next() 或下次
        // playSongAt/seek 等明确清除，防止 seek 触发的 ready 事件
        // 用错误的 playing=true 覆盖 UI。
      } else if (processingState == ProcessingState.idle &&
          !playerState.playing) {
        // idle 但 playing=false 通常是停止 / 重置。
        // _settingQueue 期间（切歌、换源）just_audio 会短暂回到 idle，
        // 此时保留 playSongAt 设置的乐观 isPlaying / isLoading，避免提前清零导致
        // 按钮状态与实际播放不一致。
        if (!_settingQueue && !_isSwitchingQuality) {
          state = state.copyWith(isPlaying: false, isLoading: false);
        }
      }

      if (state.isPlaying != wasPlaying) {
        if (state.isPlaying) {
          _startSaveTimer();
        } else {
          _savePlaybackState();
          _stopSaveTimer();
        }
      }
    });

    // 通知栏控制回调（通知栏下一首/上一首按钮）
    _audioHandler.onSkipNext = () => next();
    _audioHandler.onSkipPrevious = () => previous();
  }

  int get _currentIndex {
    if (state.currentSong == null || state.queue.isEmpty) return -1;
    return state.queue.indexWhere((s) => s.id == state.currentSong!.id);
  }

  // ==================== 核心播放方法 ====================

  /// 播放指定索引的歌曲（照搬 CeruMusic playSong 逻辑）
  ///
  /// 容错分层：
  /// 1. 原源 URL 获取成功 → 直接播放
  /// 2. 原源 URL 获取失败 → 依次尝试更低音质（需开启「音质自动降级」）
  /// 3. 仍失败且开启「当前音源播放失败自动切换音源」→ getCandidateSongs 换源
  /// 4. 播放器运行时 error → error listener 中同样按上述规则处理
  /// 5. 关闭自动换源、或换源后所有音源都失败 → 停止播放，**不自动播放下一首**
  static const Duration _urlFetchTimeout = Duration(seconds: 12);
  static const Duration _audioSetTimeout = Duration(seconds: 10);
  static const Duration _musicSourceReadyTimeout = Duration(seconds: 12);

  Future<void> playSongAt(int index) async {
    if (index < 0 || index >= state.queue.length) return;

    _cancelPendingAutoNext();
    _clearSeekTarget();
    // playSongAt 总是会重新加载音源（setAudioSource），恢复会话的
    // _needsUrlRefresh 标记随之失效。
    // 否则：启动恢复会话 → 搜索播放（setQueue 不清此标记）→ 暂停 →
    // play() 误判需要刷新 URL → 重新 playSongAt 加载音源 → 进度归零
    // （_pendingRestorePosition 已被 setQueue 清空，无法 seek 回原进度）。
    _needsUrlRefresh = false;
    _loadingTimer?.cancel();
    _loadingTimer = null;

    _savePlaybackState();

    _settingQueue = true;
    // 清除 completed 标记：新歌开始播放，后续的 ready 事件应正常处理
    _justCompleted = false;
    final requestId = ++_currentPlayRequestId;
    final song = state.queue[index];

    debugPrint(
      '[PlaybackController] playSongAt: ${song.title}, index=$index, requestId=$requestId',
    );

    // 照搬 CeruMusic：300ms 防抖，防止快速切歌导致并发请求混乱
    await Future.delayed(const Duration(milliseconds: 300));
    if (_currentPlayRequestId != requestId) return;

    _errorListenerSub?.cancel();
    _errorListenerSub = null;

    final sourceId = song.source ?? 'wy';
    final isLocal = sourceId == 'local';
    if (!isLocal) {
      await _ensureMusicSourcesReady();
      if (_currentPlayRequestId != requestId) return;
    }
    final initialDisplayCover = sourceId == 'kw'
        ? _musicSourceManager.getHighResolutionCoverUrl(song)
        : null;
    final initialSong =
        initialDisplayCover == null || initialDisplayCover == song.coverUrl
        ? song
        : song.copyWith(coverUrl: initialDisplayCover);
    if (!identical(initialSong, song)) {
      _replaceSongInQueue(index, initialSong);
    }
    final pendingCoverFuture =
        !isLocal &&
            ((song.coverUrl == null || song.coverUrl!.isEmpty) ||
                sourceId == 'kw')
        ? _musicSourceManager.getPic(
            song,
            preferBuiltIn: sourceId == 'kw',
            bypassCache: sourceId == 'kw',
          )
        : null;
    final defaultQuality = isLocal
        ? _getQualityFromSong(song)
        : (getQualityForSource?.call(sourceId) ?? _getQualityFromSong(song));
    // 仅当处于待恢复状态（重启后首次播放）时使用恢复的音质，否则走默认
    final isRestorePlay =
        _pendingRestorePosition != null && _pendingRestoreSongId == song.id;
    final quality = isRestorePlay && state.currentQuality.isNotEmpty
        ? state.currentQuality
        : defaultQuality;
    final availableQualities = isLocal
        ? <String>[quality]
        : _musicSourceManager.getSupportedQualitiesForSourceId(sourceId);
    if (!availableQualities.contains(quality)) {
      final fallback = availableQualities.isNotEmpty
          ? availableQualities.last
          : '320k';
      state = state.copyWith(
        currentIndex: index,
        currentSong: initialSong,
        position: Duration.zero,
        isLoading: true,
        currentQuality: fallback,
        availableQualities: availableQualities,
      );
    } else {
      state = state.copyWith(
        currentIndex: index,
        currentSong: initialSong,
        position: Duration.zero,
        isLoading: true,
        currentQuality: quality,
        availableQualities: availableQualities,
      );
    }

    try {
      Song currentSongToPlay = initialSong;
      String? urlToPlay = song.sourceUrl;
      var resolvedUrlCandidates = <PluginMusicUrlResult>[];

      if (isLocal && urlToPlay != null && urlToPlay.isNotEmpty) {
        try {
          await _audioHandler
              .setAudioSource(urlToPlay, song: currentSongToPlay)
              .timeout(_audioSetTimeout);
          await _restoreAndPlay(currentSongToPlay);
        } catch (_) {
          state = state.copyWith(isLoading: false, isPlaying: false);
          return;
        }
        // 遵循 CeruMusic：不乐观设 isPlaying=true。
        // 由 _playerStateSub 的 ready(playing=true) 或
        // finally 中的 Future.microtask 根据实际播放器状态同步。
        state = state.copyWith(
          isLoading: false,
          currentSong: currentSongToPlay,
        );
        // 同步更新队列中的歌曲，确保本地列表等 UI 显示正确的封面
        if (!identical(currentSongToPlay, song)) {
          _replaceSongInQueue(index, currentSongToPlay);
        }
        return;
      }

      if (!_hasPlayableUrl(urlToPlay)) {
        debugPrint('[PlaybackController] URL 为空，正在解析: ${song.title}');
        resolvedUrlCandidates = await _resolveCurrentSourceUrlCandidates(
          currentSongToPlay,
          quality: state.currentQuality,
          requestId: requestId,
        );
        urlToPlay = resolvedUrlCandidates.isEmpty
            ? null
            : resolvedUrlCandidates.first.url;
        if (_currentPlayRequestId != requestId) {
          // 已被新的播放请求取代；isLoading 由新请求管理，不在此重置以免覆盖。
          return;
        }

        if (urlToPlay != null && urlToPlay.isNotEmpty) {
          final result = resolvedUrlCandidates.firstWhere(
            (candidate) => candidate.url == urlToPlay,
            orElse: () => const PluginMusicUrlResult(url: ''),
          );
          currentSongToPlay = currentSongToPlay.copyWith(
            sourceUrl: urlToPlay,
            sourceHeaders: result.headers.isEmpty ? null : result.headers,
            sourceQuality: result.quality.isEmpty ? null : result.quality,
            clearSourceHeaders: result.headers.isEmpty,
            clearSourceQuality: result.quality.isEmpty,
            // 内置源的歌曲由插件解析地址，这里把音源标记成实际提供地址的插件，
            // 播放详情页显示的就是真正正在使用的音源。
            source: result.source ?? currentSongToPlay.source,
          );
          _replaceSongInQueue(index, currentSongToPlay);
          if (result.quality.isNotEmpty) {
            state = state.copyWith(currentQuality: result.quality);
          }
        }
      }

      if ((urlToPlay == null || urlToPlay.isEmpty) &&
          _autoQualityDowngrade &&
          !isLocal) {
        final qualityFallbackSong = await _tryQualityFallbackAfterFailure(
          song: currentSongToPlay,
          index: index,
          requestId: requestId,
          resumePosition: Duration.zero,
          excludedUrls: const <String>{},
        );
        if (qualityFallbackSong != null) {
          _errorListenerSub = _mountOneTimeErrorListener(
            requestId,
            index,
            qualityFallbackSong,
          );
          return;
        }

        // Only after every lower quality has been requested and verified may
        // playback fall through to the cross-source resolver.
        if (urlToPlay == null || urlToPlay.isEmpty) {
          await _tryPlayFromAlternateSources(
            originalSong: song,
            index: index,
            requestId: requestId,
            quality: state.currentQuality,
          );
          return;
        }
      }

      if ((urlToPlay == null || urlToPlay.isEmpty) && !isLocal) {
        await _tryPlayFromAlternateSources(
          originalSong: song,
          index: index,
          requestId: requestId,
          quality: state.currentQuality,
        );
        return;
      }

      if (urlToPlay != null && urlToPlay.isNotEmpty) {
        try {
          await _audioHandler
              .setAudioSource(urlToPlay, song: currentSongToPlay)
              .timeout(_audioSetTimeout);
          await _restoreAndPlay(currentSongToPlay);
        } catch (_) {
          if (_currentPlayRequestId != requestId) return;

          // 先尝试同一歌曲的其他洛雪脚本/音质 URL；
          // 只有全部失败后才考虑跨平台换源（且需开启自动切换音源）。
          // 这能覆盖“接口返回 URL，但该 URL 的音频响应不可播放”的情况。
          final failedUrl = urlToPlay;
          final failedUrls = <String>{if (failedUrl.isNotEmpty) failedUrl};
          for (final candidate in resolvedUrlCandidates) {
            final candidateUrl = candidate.url;
            if (_currentPlayRequestId != requestId ||
                failedUrls.contains(candidateUrl)) {
              continue;
            }

            failedUrls.add(candidateUrl);

            try {
              final fallbackSong = currentSongToPlay.copyWith(
                sourceUrl: candidateUrl,
                sourceHeaders: candidate.headers.isEmpty
                    ? null
                    : candidate.headers,
                sourceQuality: candidate.quality.isEmpty
                    ? null
                    : candidate.quality,
                // 标记实际提供地址的音源，界面上显示真正正在使用的音源。
                source: candidate.source ?? currentSongToPlay.source,
                clearSourceHeaders: candidate.headers.isEmpty,
                clearSourceQuality: candidate.quality.isEmpty,
              );
              await _audioHandler
                  .setAudioSource(candidateUrl, song: fallbackSong)
                  .timeout(_audioSetTimeout);
              await _restoreAndPlay(fallbackSong);
              currentSongToPlay = fallbackSong;
              _replaceSongInQueue(index, fallbackSong);
              final fallbackQuality = candidate.quality.isEmpty
                  ? state.currentQuality
                  : candidate.quality;
              state = state.copyWith(
                isLoading: false,
                currentSong: fallbackSong,
                currentQuality: fallbackQuality,
              );
              onMessage?.call(tr('原播放链接失败，已切换到备用播放链接'));
              _errorListenerSub = _mountOneTimeErrorListener(
                requestId,
                index,
                fallbackSong,
              );
              return;
            } catch (_) {
              continue;
            }
          }

          // 原源与同源候选都失败：开启自动换源时跨平台换源，
          // 否则按用户要求停止播放（绝不自动跳歌）。
          try {
            if (_autoQualityDowngrade && !isLocal) {
              final qualityFallbackSong = await _tryQualityFallbackAfterFailure(
                song: currentSongToPlay,
                index: index,
                requestId: requestId,
                resumePosition: Duration.zero,
                excludedUrls: failedUrls,
              );
              if (qualityFallbackSong != null) {
                _errorListenerSub = _mountOneTimeErrorListener(
                  requestId,
                  index,
                  qualityFallbackSong,
                );
                return;
              }
            }

            // 未开启「当前音源播放失败自动切换音源」→ 停止播放，不跨源换源。
            if (!_autoSwitchSource) {
              // 内置音源本身没有地址接口：即使用户关掉了自动换源，也允许用
              // 已安装的插件解析（同名插件优先，失败再试其它平台），且不弹提示。
              final usedPlugin = await _tryPluginFallbackForBuiltIn(
                song: song,
                index: index,
                requestId: requestId,
                excludedUrls: failedUrls,
              );
              if (usedPlugin) return;

              await _stopPlaybackOnFailure(
                _playbackFailureReason(
                  song.source ?? '',
                  autoSwitchEnabled: false,
                ),
              );
              return;
            }

            final candidates = await _autoSwitchService.getCandidateSongs(
              song,
              candidateSources: _fallbackSourceIds(song.source ?? ''),
            );
            if (_currentPlayRequestId != requestId) return;

            var playSuccess = false;
            for (final candidate in candidates) {
              if (_currentPlayRequestId != requestId) return;

              try {
                final result = await _musicSourceManager
                    .getMusicUrlResult(candidate, quality: state.currentQuality)
                    .timeout(_urlFetchTimeout);
                if (_currentPlayRequestId != requestId) return;
                if (result == null || result.url.isEmpty) continue;
                final url = result.url;
                // 避免重试刚刚失败的 URL
                if (url == urlToPlay) continue;

                // 照搬 CeruMusic：保留原始 song 的 id，确保队列索引一致
                final switchedSong = candidate.copyWith(
                  id: song.id,
                  sourceUrl: url,
                  sourceHeaders: result.headers.isEmpty ? null : result.headers,
                  sourceQuality: result.quality.isEmpty ? null : result.quality,
                  clearSourceHeaders: result.headers.isEmpty,
                  clearSourceQuality: result.quality.isEmpty,
                );
                _replaceSongInQueue(index, switchedSong);

                await _audioHandler
                    .setAudioSource(url, song: switchedSong)
                    .timeout(_audioSetTimeout);
                await _restoreAndPlay(switchedSong);

                // CeruMusic：只有播放成功后（waitForAudioReady/setAudioSource 成功）
                // 才显示切换成功消息，避免切换消息显示后播放又失败
                onMessage?.call(
                  tr('已自动切换到 ${_getSourceName(candidate.source ?? '', _musicSourceManager)} 源播放'),
                );
                playSuccess = true;
                // CeruMusic: 不乐观设 isPlaying, 由播放器事件驱动
                state = state.copyWith(
                  isLoading: false,
                  currentSong: switchedSong,
                );
                _errorListenerSub = _mountOneTimeErrorListener(
                  requestId,
                  index,
                  switchedSong,
                );
                break;
              } catch (_) {
                continue;
              }
            }

            if (_currentPlayRequestId != requestId) return;

            if (!playSuccess) {
              await _stopPlaybackOnFailure(
                _playbackFailureReason(
                  song.source ?? '',
                  autoSwitchEnabled: true,
                ),
              );
            }
          } catch (e) {
            if (_currentPlayRequestId != requestId) return;
            await _stopPlaybackOnFailure(tr('自动换源失败：$e'));
          }
          return;
        }

        // CeruMusic: 不乐观设 isPlaying
        state = state.copyWith(
          isLoading: false,
          currentSong: currentSongToPlay,
        );

        _errorListenerSub = _mountOneTimeErrorListener(
          requestId,
          index,
          currentSongToPlay,
        );
      } else {
        try {
          if (!_autoSwitchSource) {
            // 内置音源即使用户关掉了自动换源，也要先试已安装的插件。
            final usedPlugin = await _tryPluginFallbackForBuiltIn(
              song: song,
              index: index,
              requestId: requestId,
              excludedUrls: const <String>{},
            );
            if (usedPlugin) return;
            await _stopPlaybackOnFailure(
              _playbackFailureReason(
                song.source ?? '',
                autoSwitchEnabled: false,
              ),
            );
            return;
          }

          final candidates = await _autoSwitchService.getCandidateSongs(
            song,
            candidateSources: _fallbackSourceIds(song.source ?? ''),
          );
          if (_currentPlayRequestId != requestId) return;

          var playSuccess = false;
          for (final candidate in candidates) {
            if (_currentPlayRequestId != requestId) return;

            try {
              final result = await _musicSourceManager
                  .getMusicUrlResult(candidate, quality: state.currentQuality)
                  .timeout(_urlFetchTimeout);
              if (_currentPlayRequestId != requestId) return;
              if (result == null || result.url.isEmpty) continue;
              final url = result.url;

              // 照搬 CeruMusic：保留原始 song 的 id，确保队列索引一致
              final switchedSong = candidate.copyWith(
                id: song.id,
                sourceUrl: url,
                title: song.title,
                artist: song.artist,
                album: song.album,
                sourceHeaders: result.headers.isEmpty ? null : result.headers,
                sourceQuality: result.quality.isEmpty ? null : result.quality,
                clearSourceHeaders: result.headers.isEmpty,
                clearSourceQuality: result.quality.isEmpty,
              );
              _replaceSongInQueue(index, switchedSong);

              await _audioHandler
                  .setAudioSource(url, song: switchedSong)
                  .timeout(_audioSetTimeout);
              await _restoreAndPlay(switchedSong);

              onMessage?.call(
                tr('已自动切换到 ${_getSourceName(candidate.source ?? '', _musicSourceManager)} 源播放'),
              );
              playSuccess = true;
              // CeruMusic: 不乐观设 isPlaying
              state = state.copyWith(
                isLoading: false,
                currentSong: switchedSong,
              );
              _errorListenerSub = _mountOneTimeErrorListener(
                requestId,
                index,
                switchedSong,
              );
              break;
            } catch (_) {
              continue;
            }
          }

          if (_currentPlayRequestId != requestId) return;

          if (!playSuccess) {
            await _stopPlaybackOnFailure(
              _playbackFailureReason(
                song.source ?? '',
                autoSwitchEnabled: true,
              ),
            );
          }
        } catch (e) {
          if (_currentPlayRequestId != requestId) return;
          await _stopPlaybackOnFailure(tr('自动换源失败：$e'));
        }
      }
    } catch (e) {
      debugPrint('[PlaybackController] playSongAt error: $e');
      if (_currentPlayRequestId != requestId) return;
      await _stopPlaybackOnFailure(tr('播放歌曲失败'));
    } finally {
      if (pendingCoverFuture != null && _currentPlayRequestId == requestId) {
        unawaited(
          _applyResolvedCover(
            song: initialSong,
            index: index,
            requestId: requestId,
            coverFuture: pendingCoverFuture,
          ),
        );
      }
      _settingQueue = false;
      if (_rememberProgress && state.isPlaying) {
        _startSaveTimer();
      }
      // 兜底（CeruMusic 风格）：若所有微任务事件处理完后 isLoading
      // 仍有残留且播放器实际在播放，强制清除。
      Future.microtask(() {
        if (!mounted) return;
        if (state.isLoading && _audioHandler.playing) {
          debugPrint('[PlaybackController] 修复 isLoading 残留: 强制设为 false');
          state = state.copyWith(isLoading: false);
        }
      });
    }
  }

  // ==================== 下一首 / 上一首（照搬 CeruMusic 逻辑） ====================

  /// 下一首（照搬 CeruMusic playNext）
  /// - singleLoop: 重置到 0，重新播放当前歌曲
  /// - 队列仅一首且非单曲循环 → 暂停
  /// - listLoop: (currentIndex + 1) % length
  /// - shuffle: 随机索引
  Future<void> next() async {
    _cancelPendingAutoNext();
    if (state.queue.isEmpty) return;

    // 队列仅一首且非单曲循环 → 播放完毕直接暂停，不重播
    if (state.queue.length == 1 && state.playMode != PlayMode.singleLoop) {
      debugPrint('[PlaybackController] 队列仅一首，暂停');
      // 遵循 CeruMusic/Sollin-Music 的 ExoPlayer 行为认知：
      // 歌曲 normal complete 后 ExoPlayer 保持 playWhenReady=true，
      // 直接调用 pause() 在 STATE_ENDED 下可能被忽略。
      // 必须先 seek(0) 让播放器离开 ENDED(→READY)，
      // 再 pause() 才能真正停止播放。
      await _audioHandler.seek(Duration.zero);
      await _audioHandler.pause();
      // 排空 seek/pause 触发的 playerStateStream 微任务事件
      await Future.microtask(() {});
      // 清除 completed 标记 & 强制同步 UI 状态
      _justCompleted = false;
      state = state.copyWith(isPlaying: false);
      return;
    }

    try {
      // singleLoop 模式：重新播放当前歌曲
      if (state.playMode == PlayMode.singleLoop && state.currentSong != null) {
        debugPrint('[PlaybackController] singleLoop: 重新播放当前歌曲');
        await _audioHandler.seek(Duration.zero);
        await _audioHandler.play();
        return;
      }

      final currentIndex = _currentIndex;
      int nextIndex;

      if (state.playMode == PlayMode.shuffle) {
        // shuffle 模式：随机索引（可能与当前相同）
        nextIndex = Random().nextInt(state.queue.length);
      } else {
        // listLoop 模式：顺序播放，到末尾后循环
        nextIndex = (currentIndex + 1) % state.queue.length;
      }

      if (nextIndex >= 0 && nextIndex < state.queue.length) {
        await playSongAt(nextIndex);
      }
    } catch (e) {
      debugPrint('[PlaybackController] next() error: $e');
      onMessage?.call(tr('播放下一首失败'), backgroundColor: Colors.red);
    }
  }

  /// 上一首（照搬 CeruMusic playPrevious）
  /// - shuffle: 随机索引
  /// - listLoop/singleLoop: currentIndex - 1（到开头后循环到末尾）
  Future<void> previous() async {
    _cancelPendingAutoNext();
    if (state.queue.isEmpty) return;

    try {
      final currentIndex = _currentIndex;
      int prevIndex;

      if (state.playMode == PlayMode.shuffle) {
        // shuffle 模式：随机索引
        prevIndex = Random().nextInt(state.queue.length);
      } else {
        // 顺序模式：上一首，到开头后循环到末尾
        prevIndex = currentIndex <= 0
            ? state.queue.length - 1
            : currentIndex - 1;
      }

      if (prevIndex >= 0 && prevIndex < state.queue.length) {
        await playSongAt(prevIndex);
      }
    } catch (e) {
      debugPrint('[PlaybackController] previous() error: $e');
      onMessage?.call(tr('播放上一首失败'), backgroundColor: Colors.red);
    }
  }

  // ==================== 播放控制 ====================

  Future<void> play() async {
    _cancelPendingAutoNext();
    // 用户主动播放，清除 completed 标记
    _justCompleted = false;
    // 首次恢复后播放：强制刷新 URL（CeruMusic 从不保存 URL，每次播放都重新获取）
    if (_needsUrlRefresh && state.currentSong != null) {
      _needsUrlRefresh = false;
      final idx = _currentIndex;
      if (idx >= 0) {
        final currentSong = state.currentSong!;
        if (currentSong.source != 'local') {
          _replaceSongInQueue(
            idx,
            currentSong.copyWith(
              clearSourceUrl: true,
              clearSourceHeaders: true,
            ),
          );
        }
        await playSongAt(idx);
        return;
      }
    }
    await _audioHandler.play();
    // 遵循 CeruMusic：不乐观设 isPlaying=true。
    // 由 _playerStateSub 的 ready(playing=true) 或微任务兜底同步。
    if (_rememberProgress) _startSaveTimer();
  }

  Future<void> pause() async {
    _cancelPendingAutoNext();
    // 遵循 CeruMusic stop()：先立即设 isPlay=false，再调 audio.pause()。
    // 这样即使 audio.pause() 异步延迟或失败，UI 状态也已正确更新。
    _justCompleted = false;
    state = state.copyWith(isPlaying: false);
    await _audioHandler.pause();
    _savePlaybackState();
    _stopSaveTimer();
  }

  Future<void> togglePlayPause() async {
    // 遵循 CeruMusic：以实际播放器状态判断按钮意图，
    // 不依赖可能滞后的 state.isPlaying。
    // CeruMusic 的 togglePlayPause:
    //   const isActuallyPlaying = a ? !a.paused : Audio.value.isPlay
    final isActuallyPlaying = _audioHandler.playing;
    if (isActuallyPlaying) {
      await pause();
    } else {
      await play();
    }
  }

  void _clearSeekTarget() {
    _seekTargetTimer?.cancel();
    _seekTargetTimer = null;
    _seekTarget = null;
  }

  Future<void> seek(Duration position) async {
    _cancelPendingAutoNext();
    // 用户主动拖拽进度条，清除 completed 标记
    _justCompleted = false;

    var target = position;
    if (target < Duration.zero) target = Duration.zero;

    // 乐观更新，让进度条和歌词在 seek 完成前就响应，而不是等待
    // 200ms 节流的位置流。
    _clearSeekTarget();
    _seekTarget = target;
    if (mounted) {
      state = state.copyWith(position: target);
    }
    _seekTargetTimer = Timer(const Duration(seconds: 2), _clearSeekTarget);

    await _audioHandler.seek(target);
  }

  Future<void> setSpeed(double speed) async {
    await _audioHandler.setSpeed(speed);
  }

  // ==================== 播放模式 ====================

  void cyclePlayMode() {
    final modes = PlayMode.values;
    final currentIndex = modes.indexOf(state.playMode);
    final nextIndex = (currentIndex + 1) % modes.length;
    state = state.copyWith(playMode: modes[nextIndex]);
  }

  Future<void> setPlayMode(PlayMode mode) async {
    state = state.copyWith(playMode: mode);
  }

  // ==================== 队列管理 ====================

  /// 设置播放队列（照搬 CeruMusic replacePlaylist）
  Future<void> setQueue(List<Song> songs, {int startIndex = 0}) async {
    _cancelPendingAutoNext();
    if (songs.isEmpty) return;
    // 用户主动切换队列（搜索/歌单等），不应用待恢复进度
    _pendingRestorePosition = null;
    _pendingRestoreSongId = null;
    onClearPlaybackState?.call();
    // 用户主动起播 → 解除 clearQueue() 设置的会话屏蔽，
    // 否则 playSongAt 里的 setAudioSource 会被忽略、根本播不出声音。
    _audioHandler.markSessionActive();
    _settingQueue = true;
    final index = startIndex.clamp(0, songs.length - 1);

    // 更新队列状态
    state = state.copyWith(
      queue: List.from(songs),
      currentIndex: index,
      currentSong: songs[index],
      position: Duration.zero,
      isLoading: true,
    );

    _settingQueue = false;

    // 播放指定索引的歌曲
    await playSongAt(index);
  }

  /// 添加到队列末尾（照搬 CeruMusic addToPlaylistEnd）
  ///
  /// 队列为空（或还没有当前歌曲）时，视为「用这些歌重新开始播放」：
  /// 直接从第一首播起。否则只把歌塞进队列而不播放，App 内不会出现迷你播放栏，
  /// 用户也无法再对队列做增删操作。
  Future<void> appendToQueue(List<Song> songs) async {
    if (songs.isEmpty) return;
    // 队列为空且无当前歌曲：从头开始播放这批歌曲。
    if (state.queue.isEmpty && state.currentSong == null) {
      _cancelPendingAutoNext();
      _pendingRestorePosition = null;
      _pendingRestoreSongId = null;
      onClearPlaybackState?.call();
      await setQueue(songs);
      return;
    }
    // Remote URLs are transient. Resolve lazily when a song becomes current.
    final newQueue = [...state.queue, ...songs];
    state = state.copyWith(queue: newQueue);
  }

  /// 插入到当前歌曲之后（照搬 CeruMusic addToPlaylistAndPlay 的插入逻辑）
  ///
  /// 与 [appendToQueue] 一样：队列为空且没有当前歌曲时没有「下一首」可言，
  /// 直接从这批歌曲开始播放。
  Future<void> insertNext(List<Song> songs) async {
    if (songs.isEmpty) return;
    if (state.queue.isEmpty && state.currentSong == null) {
      _cancelPendingAutoNext();
      _pendingRestorePosition = null;
      _pendingRestoreSongId = null;
      onClearPlaybackState?.call();
      await setQueue(songs);
      return;
    }
    final insertIndex = _currentIndex + 1;
    final newQueue = List<Song>.from(state.queue);
    newQueue.insertAll(insertIndex, songs);
    state = state.copyWith(queue: newQueue);
  }

  /// 插入到队列首位并播放（照搬 CeruMusic addSongToFirst + playSong）
  Future<void> prependAndPlay(Song song) async {
    // 用户主动插播，不应用待恢复进度
    _pendingRestorePosition = null;
    _pendingRestoreSongId = null;
    onClearPlaybackState?.call();
    // 用户主动起播 → 解除 clearQueue() 设置的会话屏蔽，
    // 否则紧随其后的 setAudioSource 会被忽略。
    _audioHandler.markSessionActive();
    final resolved = [song];
    final newQueue = List<Song>.from(state.queue);
    newQueue.insertAll(0, resolved);
    state = state.copyWith(
      queue: newQueue,
      currentIndex: 0,
      currentSong: resolved.first,
      position: Duration.zero,
    );
    await playSongAt(0);
  }

  /// 从队列中移除歌曲
  Future<void> removeFromQueue(int index) async {
    if (index < 0 || index >= state.queue.length) return;
    final newQueue = List<Song>.from(state.queue);
    final removedSong = newQueue.removeAt(index);
    int newIndex = _currentIndex;

    if (index < newIndex) {
      newIndex--;
    } else if (removedSong.id == state.currentSong?.id) {
      // 移除的是当前歌曲，播放下一首
      if (newQueue.isEmpty) {
        await clearQueue();
        return;
      }
      if (newIndex >= newQueue.length) {
        newIndex = newQueue.length - 1;
      }
    }

    final newCurrentSong = newIndex >= 0 && newIndex < newQueue.length
        ? newQueue[newIndex]
        : null;

    state = state.copyWith(
      queue: newQueue,
      currentIndex: newIndex,
      currentSong: newCurrentSong,
    );

    // 如果移除的是当前歌曲，播放新的当前歌曲
    if (removedSong.id == state.currentSong?.id && newCurrentSong != null) {
      await playSongAt(newIndex);
    }
  }

  /// 清空队列
  ///
  /// 顺序参照 MusicFree 的 `TrackPlayer.clearPlayList()`：
  /// 先清播放列表与当前曲目，再硬重置底层播放器，最后清持久化状态。
  ///
  /// 最关键的一步是 [_currentPlayRequestId] 自增 + 取消 [_errorListenerSub]：
  /// `playSongAt` / `setQuality` 内部有 300ms 防抖和最长 12s 的取URL/换源
  /// 异步过程，只靠 `requestId` 守卫来放弃过期操作。如果这里不把它们作废，
  /// 在途的请求会在 await 之后继续 `setAudioSource`：
  ///   · 重新点亮通知栏（旧曲目 + 可点的播放键）→ 正是「清空后通知栏还在、
  ///     点播放还能继续播」的根因；
  ///   · 队列已空时 `state.queue.length <= 1` 成立 → 弹出「播放中断，请手动重试」。
  Future<void> clearQueue() async {
    // 1) 作废所有在途的加载 / 换源 / 音质切换请求
    _currentPlayRequestId++;
    _qualitySwitchRequestId = null;
    unawaited(_errorListenerSub?.cancel());
    _errorListenerSub = null;
    _justCompleted = false;
    _cancelPendingAutoNext();
    _needsUrlRefresh = false;
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _stallBaselinePosition = null;
    // 用户主动清空，不应用待恢复进度
    _pendingRestorePosition = null;
    _pendingRestoreSongId = null;

    // 2) 复位状态（保存定时器随即短路，不再写盘），再清持久化，
    //避免保存定时器在两者之间把旧队列写回去。
    state = const PlaybackState();
    onClearPlaybackState?.call();

    // 3) 硬重置媒体会话：停播 + 卸音源 + 清 queue/mediaItem，通知栏同步消失
    await _audioHandler.clearMediaSession();
  }

  // ==================== 音质切换 ====================

  void _finishQualitySwitch(int requestId) {
    if (_qualitySwitchRequestId == requestId) {
      _qualitySwitchRequestId = null;
    }
  }

  Future<void> setQuality(String quality) async {
    if (state.currentQuality == quality) return;

    final currentSong = state.currentSong;
    if (currentSong == null) return;

    final requestId = ++_currentPlayRequestId;
    _qualitySwitchRequestId = requestId;
    state = state.copyWith(isLoading: true);
    final currentPosition = state.position;
    final originalUrl = currentSong.sourceUrl;

    try {
      final result = await _musicSourceManager.getMusicUrlResult(
        currentSong,
        quality: quality,
      );
      if (_currentPlayRequestId != requestId) return;

      if (result == null || result.url.isEmpty) {
        state = state.copyWith(isLoading: false);
        _finishQualitySwitch(requestId);
        onMessage?.call(tr('无法获取该音质的播放链接，当前音质保持不变'), backgroundColor: Colors.red);
        return;
      }

      final updatedSong = currentSong.copyWith(
        sourceUrl: result.url,
        sourceHeaders: result.headers.isEmpty ? null : result.headers,
        sourceQuality: result.quality.isEmpty ? quality : result.quality,
        clearSourceHeaders: result.headers.isEmpty,
        // 标记实际提供地址的音源，界面上显示真正正在使用的音源。
        source: result.source ?? currentSong.source,
      );
      await _audioHandler.setAudioSource(result.url, song: updatedSong);
      await _audioHandler.seek(currentPosition);
      await _audioHandler.play();
      state = state.copyWith(
        isLoading: false,
        isPlaying: true,
        currentQuality: quality,
        currentSong: updatedSong,
      );
      _finishQualitySwitch(requestId);
      onMessage?.call(tr('已切换到 ${_getQualityDisplayName(quality)}'));
      // 用户手动切换音质：同步「默认音质 / 全局音质」。
      onQualityChanged?.call(quality, currentSong.source);
    } catch (e) {
      if (_currentPlayRequestId != requestId) return;
      // 恢复原音源
      try {
        if (originalUrl != null && originalUrl.isNotEmpty) {
          await _audioHandler.setAudioSource(originalUrl, song: currentSong);
          await _audioHandler.seek(currentPosition);
          await _audioHandler.play();
        }
      } catch (_) {}
      state = state.copyWith(isLoading: false);
      _finishQualitySwitch(requestId);
      onMessage?.call(tr('切换音质失败，当前音质保持不变: $e'), backgroundColor: Colors.red);
    }
  }

  // ==================== 内部辅助方法 ====================

  void _replaceSongInQueue(int index, Song newSong) {
    final newQueue = List<Song>.from(state.queue);
    newQueue[index] = newSong;
    state = state.copyWith(queue: newQueue);
  }

  /// 更新播放队列和当前歌曲的元数据（封面、歌词、标题等）。
  /// 供自动获取和精准匹配调用，确保 UI 同步刷新。
  void updateSongInQueue(Song updatedSong) {
    final currentSong = state.currentSong;
    if (currentSong == null || currentSong.id != updatedSong.id) return;

    // 更新队列中的歌曲
    final idx = state.queue.indexWhere((s) => s.id == updatedSong.id);
    if (idx >= 0) {
      final newQueue = List<Song>.from(state.queue);
      newQueue[idx] = updatedSong;
      state = state.copyWith(
        queue: newQueue,
        currentSong: updatedSong,
        forceCurrentSong: true,
      );
    } else {
      state = state.copyWith(
        currentSong: updatedSong,
        forceCurrentSong: true,
      );
    }

    // 同步更新通知栏/锁屏封面
    _audioHandler.updateCurrentMediaItem(updatedSong);
  }

  Future<void> _applyResolvedCover({
    required Song song,
    required int index,
    required int requestId,
    required Future<String?> coverFuture,
  }) async {
    try {
      final coverUrl = await coverFuture;
      if (!mounted ||
          _currentPlayRequestId != requestId ||
          coverUrl == null ||
          coverUrl.isEmpty) {
        return;
      }

      final currentSong = state.currentSong;
      if (currentSong == null ||
          currentSong.id != song.id ||
          currentSong.source != song.source) {
        return;
      }

      final shouldRefreshKuwoCover = currentSong.source == 'kw';
      if (!shouldRefreshKuwoCover &&
          (currentSong.coverUrl?.isNotEmpty ?? false)) {
        return;
      }
      if (currentSong.coverUrl == coverUrl) return;

      final enrichedSong = currentSong.copyWith(coverUrl: coverUrl);
      if (index >= 0 &&
          index < state.queue.length &&
          state.queue[index].id == currentSong.id) {
        _replaceSongInQueue(index, enrichedSong);
      }
      state = state.copyWith(currentSong: enrichedSong);
      _audioHandler.updateCurrentMediaItem(enrichedSong);
    } catch (error) {
      debugPrint('[PlaybackController] cover resolution failed: $error');
    }
  }

  /// 播放失败时的提示语。
  ///
  /// * **内置音源**：它自己没有播放地址接口，失败说明没有可用的第三方音源，
  ///   提示用户去装对应平台的音源；
  /// * **插件音源**：未开启自动换源时说明是用户主动关掉的；开启了但所有
  ///   候选都失败则是所有音源都不可用。
  String _playbackFailureReason(
    String source, {
    required bool autoSwitchEnabled,
  }) {
    if (source.isNotEmpty && !source.contains('@')) {
      return _builtInSourceMissingMessage(source);
    }
    if (!autoSwitchEnabled) {
      return tr('当前音源播放失败，自动切换音源已关闭');
    }
    return tr('所有音源均无法播放');
  }

  /// 内置音源缺少第三方音源时的提示。
  String _builtInSourceMissingMessage(String source) {
    // 用平台名（不带「-内置」后缀），提示语读起来更自然。
    final (baseId, _) = MusicSourceManager.splitSourceId(source);
    final name = _sourceIdToChineseName[baseId] ??
        _getSourceName(source, _musicSourceManager);
    return tr('没有第三方对应$name音源，请先安装$name音源');
  }

  /// 换源时要尝试的音源（同平台优先，再其它平台，不区分插件格式）。
  List<String> _fallbackSourceIds(String currentSource) {
    return _musicSourceManager.playbackFallbackSourceIds(currentSource);
  }

  /// 跨音源换源：遍历 `getCandidateSongs` 返回的候选并按顺序尝试播放。
  ///
  /// 插件音源仅在开启「当前音源播放失败自动切换音源」时换源，未开启时直接
  /// 停止播放；内置音源即使关闭开关也会用插件兜底解析。所有候选都失败同样
  /// 停止播放，**不自动播放下一首**。
  Future<bool> _tryPlayFromAlternateSources({
    required Song originalSong,
    required int index,
    required int requestId,
    required String quality,
  }) async {
    final source = originalSong.source ?? '';
    // 内置音源自己没有地址接口，必须由插件解析：即使用户关掉了自动换源，
    // 也要依次尝试其它已安装的音源，直到全部失败。
    final isBuiltInSource = source.isNotEmpty && !source.contains('@');

    // 内置源 + 一个可用的插件音源都没有 → 必然播不了，直接提示去装插件，
    // 不用白跑一轮跨平台搜索。
    if (isBuiltInSource && _musicSourceManager.pluginSourceIds.isEmpty) {
      if (_currentPlayRequestId == requestId) {
        await _stopPlaybackOnFailure(
          _playbackFailureReason(source, autoSwitchEnabled: _autoSwitchSource),
        );
      }
      return false;
    }

    // 未开启「当前音源播放失败自动切换音源」→ 停止播放，不跨源换源。
    if (!_autoSwitchSource && !isBuiltInSource) {
      if (_currentPlayRequestId == requestId) {
        await _stopPlaybackOnFailure(
          _playbackFailureReason(source, autoSwitchEnabled: false),
        );
      }
      return false;
    }

    if (!_autoSwitchSource) {
      // 内置音源：即使用户关掉了自动换源，也允许用已安装的插件解析
      // （同名插件优先，失败再试其它平台），且不弹任何提示。
      final usedPlugin = await _tryPluginFallbackForBuiltIn(
        song: originalSong,
        index: index,
        requestId: requestId,
        excludedUrls: const <String>{},
      );
      if (usedPlugin) return true;
      if (_currentPlayRequestId == requestId) {
        await _stopPlaybackOnFailure(
          _playbackFailureReason(source, autoSwitchEnabled: false),
        );
      }
      return false;
    }

    try {
      final candidates = await _autoSwitchService.getCandidateSongs(
        originalSong,
        candidateSources: _fallbackSourceIds(source),
      );
      if (_currentPlayRequestId != requestId) return false;

      for (final candidate in candidates) {
        if (_currentPlayRequestId != requestId) return false;
        try {
          final result = await _musicSourceManager
              .getMusicUrlResult(candidate, quality: quality)
              .timeout(_urlFetchTimeout);
          if (result == null || result.url.isEmpty) continue;

          final switchedSong = candidate.copyWith(
            id: originalSong.id,
            sourceUrl: result.url,
            sourceHeaders: result.headers.isEmpty ? null : result.headers,
            sourceQuality: result.quality.isEmpty ? quality : result.quality,
            clearSourceHeaders: result.headers.isEmpty,
            clearSourceQuality: false,
          );
          await _audioHandler
              .setAudioSource(result.url, song: switchedSong)
              .timeout(_audioSetTimeout);
          await _restoreAndPlay(switchedSong);
          _replaceSongInQueue(index, switchedSong);
          state = state.copyWith(
            currentSong: switchedSong,
            currentQuality: switchedSong.sourceQuality ?? quality,
            isLoading: false,
          );
          onMessage?.call(
            tr('已自动切换到 ${_getSourceName(candidate.source ?? '', _musicSourceManager)} 源播放'),
          );
          _errorListenerSub = _mountOneTimeErrorListener(
            requestId,
            index,
            switchedSong,
          );
          return true;
        } catch (e) {
          debugPrint('[PlaybackController] alternate source failed: $e');
        }
      }
    } catch (e) {
      debugPrint('[PlaybackController] alternate source lookup failed: $e');
    }

    if (_currentPlayRequestId == requestId) {
      await _stopPlaybackOnFailure(
        _playbackFailureReason(source, autoSwitchEnabled: true),
      );
    }
    return false;
  }

  /// 内置音源的歌曲改用已安装的插件解析播放地址。
  ///
  /// 内置源只负责搜索与元数据，本身没有地址接口，播放地址必须由插件解析。
  /// 按同平台插件（酷狗1 → 酷狗2）→ 其它平台内置源 → 其它平台插件的顺序
  /// 重新搜索同一首歌再解析，直到所有音源都失败。
  ///
  /// 即使关掉了「当前音源播放失败自动切换音源」也会走这个兜底，并且**不弹
  /// 任何提示**，实际使用的音源在播放详情页顶部显示。
  Future<bool> _tryPluginFallbackForBuiltIn({
    required Song song,
    required int index,
    required int requestId,
    required Set<String> excludedUrls,
  }) async {
    final source = song.source;
    if (source == null || source.isEmpty) return false;
    // 只有内置音源（平台 id）需要这个兜底；插件音源自己就能解析地址。
    if (source.contains('@')) return false;

    final pluginIds = _musicSourceManager.pluginSourceIds;
    if (pluginIds.isEmpty) return false;
    // 同平台插件（酷狗1 → 酷狗2）重新搜索同一首歌，失败后再试其它平台；
    // MusicFree 插件必须用自己搜索结果里的 musicItem 才能解析地址。
    final others = _fallbackSourceIds(source);
    if (others.isEmpty) return false;

    List<Song> candidates;
    try {
      candidates = await _autoSwitchService.getCandidateSongs(
        song,
        candidateSources: others,
        silent: true,
      );
    } catch (e) {
      debugPrint('[PlaybackController] 内置源插件兜底搜索失败: $e');
      return false;
    }
    if (_currentPlayRequestId != requestId) return false;

    for (final candidate in candidates) {
      if (_currentPlayRequestId != requestId) return false;
      try {
        final result = await _musicSourceManager
            .getMusicUrlResult(candidate, quality: state.currentQuality)
            .timeout(_urlFetchTimeout);
        if (_currentPlayRequestId != requestId) return false;
        if (result == null || result.url.isEmpty) continue;
        final url = result.url;
        if (excludedUrls.contains(url)) continue;

        // 保留原始 song 的 id，确保队列索引一致。
        final switchedSong = candidate.copyWith(
          id: song.id,
          sourceUrl: url,
          sourceHeaders: result.headers.isEmpty ? null : result.headers,
          sourceQuality: result.quality.isEmpty ? null : result.quality,
          clearSourceHeaders: result.headers.isEmpty,
          clearSourceQuality: result.quality.isEmpty,
          // 标记实际提供地址的音源，界面上显示真正正在使用的音源。
          source: result.source ?? candidate.source,
        );
        _replaceSongInQueue(index, switchedSong);

        await _audioHandler
            .setAudioSource(url, song: switchedSong)
            .timeout(_audioSetTimeout);
        await _restoreAndPlay(switchedSong);

        debugPrint(
          '[PlaybackController] 内置源改用插件解析播放: '
          'source=${candidate.source}',
        );
        state = state.copyWith(
          isLoading: false,
          currentSong: switchedSong,
        );
        _errorListenerSub = _mountOneTimeErrorListener(
          requestId,
          index,
          switchedSong,
        );
        return true;
      } catch (e) {
        debugPrint(
          '[PlaybackController] 内置源插件兜底解析失败: '
          'source=${candidate.source} error=$e',
        );
        continue;
      }
    }
    return false;
  }

  /// 播放失败后的统一收尾：停止播放并提示，绝不自动播放下一首。
  ///
  /// 用户明确要求：不论是否开启「当前音源播放失败自动切换音源」，
  /// 只要当前音源（或换源后所有音源）播放失败，就停止播放，
  /// **不要自动播放下一首**。
  Future<void> _stopPlaybackOnFailure(String reason) async {
    debugPrint('[PlaybackController] 播放失败，停止播放：$reason');

    _cancelPendingAutoNext();
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _stallBaselinePosition = null;
    if (mounted) {
      state = state.copyWith(isLoading: false);
    }

    try {
      await _audioHandler.pause();
    } catch (e) {
      debugPrint('[PlaybackController] 停止播放失败: $e');
    }
    if (!mounted) return;
    state = state.copyWith(isPlaying: false, isLoading: false);

    // 限频/限流时给出更具体的提示。
    final isRateLimited = reason.contains('频率') || reason.contains('限制');
    onMessage?.call(
      isRateLimited ? tr('播放失败：$reason，请稍后重试') : tr('播放失败：$reason，已停止播放'),
      backgroundColor: Colors.red,
    );
  }

  Future<List<PluginMusicUrlResult>> _getLowerQualityCandidates(
    Song song, {
    required Set<String> excludedUrls,
  }) async {
    if (!_autoQualityDowngrade ||
        song.source == null ||
        song.source == 'local') {
      return const <PluginMusicUrlResult>[];
    }

    final results = <PluginMusicUrlResult>[];
    final qualityChain = _musicSourceManager.getMusicQualityFallbacks(
      song,
      state.currentQuality,
    );
    for (final fallbackQuality in qualityChain) {
      if (fallbackQuality == state.currentQuality) continue;
      try {
        final candidates = await _musicSourceManager
            .getMusicUrlResultCandidates(
              song,
              quality: fallbackQuality,
              excludedUrls: excludedUrls,
            )
            .timeout(_urlFetchTimeout);
        for (final candidate in candidates) {
          if (candidate.url.isNotEmpty &&
              !excludedUrls.contains(candidate.url) &&
              !results.any((item) => item.url == candidate.url)) {
            results.add(
              candidate.quality.isEmpty
                  ? PluginMusicUrlResult(
                      url: candidate.url,
                      quality: fallbackQuality,
                      headers: candidate.headers,
                    )
                  : candidate,
            );
          }
        }
      } catch (e) {
        debugPrint(
          '[PlaybackController] quality fallback lookup failed: '
          'quality=$fallbackQuality error=$e',
        );
      }
    }
    return results;
  }

  Future<Song?> _tryQualityFallbackAfterFailure({
    required Song song,
    required int index,
    required int requestId,
    required Duration resumePosition,
    required Set<String> excludedUrls,
  }) async {
    if (!_autoQualityDowngrade ||
        song.source == null ||
        song.source == 'local') {
      return null;
    }

    final triedUrls = <String>{...excludedUrls};
    final qualityChain = _musicSourceManager.getMusicQualityFallbacks(
      song,
      state.currentQuality,
    );

    // Request one quality, verify its URLs immediately, then continue to the
    // next lower quality only when every URL at this level fails.
    for (final fallbackQuality in qualityChain) {
      if (_currentPlayRequestId != requestId ||
          fallbackQuality == state.currentQuality) {
        continue;
      }

      List<PluginMusicUrlResult> candidates;
      try {
        candidates = await _musicSourceManager
            .getMusicUrlResultCandidates(
              song,
              quality: fallbackQuality,
              excludedUrls: triedUrls,
            )
            .timeout(_urlFetchTimeout);
      } catch (e) {
        debugPrint(
          '[PlaybackController] quality fallback lookup failed: '
          'quality=$fallbackQuality error=$e',
        );
        continue;
      }

      for (final candidate in candidates) {
        if (_currentPlayRequestId != requestId ||
            candidate.url.isEmpty ||
            !triedUrls.add(candidate.url)) {
          continue;
        }

        final resolvedQuality = candidate.quality.isEmpty
            ? fallbackQuality
            : candidate.quality;
        final fallbackSong = song.copyWith(
          sourceUrl: candidate.url,
          sourceHeaders: candidate.headers.isEmpty ? null : candidate.headers,
          sourceQuality: resolvedQuality,
          clearSourceHeaders: candidate.headers.isEmpty,
          clearSourceQuality: false,
        );

        try {
          await _audioHandler
              .setAudioSource(candidate.url, song: fallbackSong)
              .timeout(_audioSetTimeout);
          await _restoreAndPlay(fallbackSong);
          await _resumeFromPosition(resumePosition);
          _replaceSongInQueue(index, fallbackSong);
          state = state.copyWith(
            currentSong: fallbackSong,
            currentQuality: resolvedQuality,
            isLoading: false,
          );
          onMessage?.call(tr('已自动降级到 ${_getQualityDisplayName(resolvedQuality)}'));
          return fallbackSong;
        } catch (e) {
          debugPrint(
            '[PlaybackController] quality fallback playback failed: '
            'quality=$resolvedQuality error=$e',
          );
        }
      }
    }
    return null;
  }

  // ignore: unused_element
  Future<Song?> _tryQualityFallbackAfterFailureLegacy({
    required Song song,
    required int index,
    required int requestId,
    required Duration resumePosition,
    required Set<String> excludedUrls,
  }) async {
    if (!_autoQualityDowngrade ||
        song.source == null ||
        song.source == 'local') {
      return null;
    }

    final candidates = await _getLowerQualityCandidates(
      song,
      excludedUrls: excludedUrls,
    );

    for (final candidate in candidates) {
      if (_currentPlayRequestId != requestId ||
          candidate.url.isEmpty ||
          excludedUrls.contains(candidate.url)) {
        continue;
      }

      final resolvedQuality = candidate.quality.isEmpty
          ? state.currentQuality
          : candidate.quality;
      final fallbackSong = song.copyWith(
        sourceUrl: candidate.url,
        sourceHeaders: candidate.headers.isEmpty ? null : candidate.headers,
        sourceQuality: resolvedQuality,
        clearSourceHeaders: candidate.headers.isEmpty,
        clearSourceQuality: false,
      );

      try {
        await _audioHandler
            .setAudioSource(candidate.url, song: fallbackSong)
            .timeout(_audioSetTimeout);
        await _restoreAndPlay(fallbackSong);
        await _resumeFromPosition(resumePosition);
        _replaceSongInQueue(index, fallbackSong);
        state = state.copyWith(
          currentSong: fallbackSong,
          currentQuality: resolvedQuality,
          isLoading: false,
        );
        onMessage?.call(
          tr('原音质播放失败，已降级到 ${_getQualityDisplayName(resolvedQuality)}'),
        );
        return fallbackSong;
      } catch (e) {
        debugPrint(
          '[PlaybackController] quality fallback playback failed: '
          'quality=$resolvedQuality error=$e',
        );
      }
    }
    return null;
  }

  /// 一次性错误监听器（照搬 CeruMusic 的 error listener 机制）
  ///
  /// CeruMusic 使用 HTML5 Audio 元素的原生 error 事件（{ once: true }），
  /// 一次性检测播放错误并触发自动换源。这里用 just_audio 的 playerStateStream
  /// 模拟相同的语义：
  ///
  /// 1. 监听异常 processingState 过渡：ready/loading/buffering → idle
  /// 2. 至少播放 minPlayDuration 后才激活（避免启动阶段的误判）
  /// 3. 一次性：触发一次后自动取消订阅
  ///
  /// 失败处理逻辑（对齐 CeruMusic error handler，但失败后不自动跳歌）：
  /// - 先尝试原源重新获取 URL（可能只是 URL 过期）
  /// - 原源失败则遍历候选源（仅在开启「自动切换音源」时）
  /// - 全部失败 → 停止播放
  StreamSubscription _mountOneTimeErrorListener(
    int requestId,
    int index,
    Song song,
  ) {
    const minPlayDuration = Duration(seconds: 6);
    bool handled = false;
    ProcessingState? lastState;
    final startTime = DateTime.now();
    late final StreamSubscription sub;

    sub = _audioHandler.playerStateStream.listen((playerState) async {
      if (_currentPlayRequestId != requestId || handled) return;

      final current = playerState.processingState;

      // 自然完成 → 不触发换源
      if (current == ProcessingState.completed) {
        handled = true;
        sub.cancel();
        return;
      }

      // 至少播放 minPlayDuration 后才检测错误（CeruMusic 风格）
      final elapsed = DateTime.now().difference(startTime);
      if (elapsed < minPlayDuration) {
        lastState = current;
        return;
      }

      // 检测异常过渡：ready/loading/buffering → idle（播放中断）
      final isErrorTransition =
          current == ProcessingState.idle &&
          !playerState.playing &&
          lastState != null &&
          lastState != ProcessingState.idle &&
          lastState != ProcessingState.completed;

      if (!isErrorTransition) {
        lastState = current;
        return;
      }

      // 一次性触发
      handled = true;
      sub.cancel();

      debugPrint('[PlaybackController] 检测到播放错误: $lastState → idle, 开始换源');

      // 捕获出错/暂停前的播放进度，换源成功后 seek 回去，避免重头播放
      // （如暂停期间 URL 过期，恢复播放时报错触发换源的情况）
      final resumePosition = state.position;

      // 乐观更新 UI
      state = state.copyWith(isLoading: true);

      try {
        // 1) 先尝试原源重新获取 URL（可能是 URL 过期 / token 失效）
        final excludedUrls = song.sourceUrl == null || song.sourceUrl!.isEmpty
            ? const <String>{}
            : <String>{song.sourceUrl!};
        final resolved = await _musicSourceManager
            .resolveSingleSongUrl(song, excludedUrls: excludedUrls)
            .timeout(_urlFetchTimeout, onTimeout: () => song);
        if (_currentPlayRequestId != requestId) return;

        if (resolved.sourceUrl != null &&
            resolved.sourceUrl!.isNotEmpty &&
            resolved.sourceUrl != song.sourceUrl) {
          // 原源新 URL 成功 → 直接播放
          _replaceSongInQueue(index, resolved);
          try {
            await _audioHandler
                .setAudioSource(resolved.sourceUrl!, song: resolved)
                .timeout(_audioSetTimeout);
            await _restoreAndPlay(resolved);
            await _resumeFromPosition(resumePosition);
            state = state.copyWith(currentSong: resolved, isLoading: false);
            onMessage?.call(
              tr('已重新获取 ${_getSourceName(resolved.source ?? '', _musicSourceManager)} 源 URL，继续播放'),
            );
            return;
          } catch (_) {
            debugPrint('[PlaybackController] 原源新 URL 播放失败，尝试换源');
          }
        }

        // 原源重新获取失败后，按开关决定是否尝试更低音质。
        final qualityFallbackSong = await _tryQualityFallbackAfterFailure(
          song: song,
          index: index,
          requestId: requestId,
          resumePosition: resumePosition,
          excludedUrls: excludedUrls,
        );
        if (qualityFallbackSong != null) {
          _errorListenerSub = _mountOneTimeErrorListener(
            requestId,
            index,
            qualityFallbackSong,
          );
          return;
        }

        // 2) 原源重试失败 → 按开关决定是否遍历候选源
        if (!_autoSwitchSource) {
          // 内置音源即使用户关掉了自动换源，也要先试已安装的插件。
          final usedPlugin = await _tryPluginFallbackForBuiltIn(
            song: song,
            index: index,
            requestId: requestId,
            excludedUrls: excludedUrls,
          );
          if (usedPlugin) return;
          await _stopPlaybackOnFailure(
            _playbackFailureReason(
              song.source ?? '',
              autoSwitchEnabled: false,
            ),
          );
          return;
        }
        final candidates = await _autoSwitchService.getCandidateSongs(
          song,
          candidateSources: _fallbackSourceIds(song.source ?? ''),
        );
        if (_currentPlayRequestId != requestId) return;

        for (final candidate in candidates) {
          if (_currentPlayRequestId != requestId) return;

          try {
            final result = await _musicSourceManager
                .getMusicUrlResult(candidate, quality: state.currentQuality)
                .timeout(_urlFetchTimeout);
            if (_currentPlayRequestId != requestId) return;
            if (result == null || result.url.isEmpty) continue;
            final url = result.url;
            if (url == song.sourceUrl) continue;

            // 照搬 CeruMusic：保留原始 song 的 id，确保队列索引一致
            final switchedSong = candidate.copyWith(
              id: song.id,
              sourceUrl: url,
              sourceHeaders: result.headers.isEmpty ? null : result.headers,
              sourceQuality: result.quality.isEmpty ? null : result.quality,
              clearSourceHeaders: result.headers.isEmpty,
              clearSourceQuality: result.quality.isEmpty,
            );
            _replaceSongInQueue(index, switchedSong);

            await _audioHandler
                .setAudioSource(url, song: switchedSong)
                .timeout(_audioSetTimeout);
            await _restoreAndPlay(switchedSong);
            await _resumeFromPosition(resumePosition);

            onMessage?.call(
              tr('已自动切换到 ${_getSourceName(candidate.source ?? '', _musicSourceManager)} 源播放'),
            );
            state = state.copyWith(currentSong: switchedSong, isLoading: false);
            return;
          } catch (_) {
            continue;
          }
        }

        // 3) 全部失败 → 停止播放（不自动跳歌）
        if (_currentPlayRequestId != requestId) return;
        await _stopPlaybackOnFailure(
          _playbackFailureReason(song.source ?? '', autoSwitchEnabled: true),
        );
      } catch (e) {
        debugPrint('[PlaybackController] 处理播放错误时出错: $e');
        if (_currentPlayRequestId != requestId) return;
        await _stopPlaybackOnFailure(tr('播放出错且自动换源失败'));
      }
    });

    return sub;
  }

  String _getQualityDisplayName(String quality) {
    return getQualityDisplayName(quality);
  }

  String _getQualityFromSong(Song song) {
    final filePath = song.filePath?.toLowerCase() ?? '';
    final bitrate = song.bitrate;
    final sampleRate = song.sampleRate;

    if (filePath.endsWith('.flac')) {
      if (sampleRate != null && sampleRate > 48000) {
        return 'hires';
      }
      return 'flac';
    }

    if (filePath.endsWith('.wav') ||
        filePath.endsWith('.ape') ||
        filePath.endsWith('.dsd') ||
        filePath.endsWith('.dff') ||
        filePath.endsWith('.dsf')) {
      return 'hires';
    }

    if (filePath.endsWith('.m4a') || filePath.endsWith('.aac')) {
      if (bitrate != null && bitrate > 0) {
        if (bitrate <= 128000) return '128k';
        if (bitrate <= 320000) return '320k';
      }
      return '320k';
    }

    if (filePath.endsWith('.ogg') || filePath.endsWith('.wma')) {
      if (bitrate != null && bitrate > 0) {
        if (bitrate <= 128000) return '128k';
        if (bitrate <= 320000) return '320k';
      }
      return '320k';
    }

    if (bitrate == null || bitrate <= 0) {
      if (filePath.endsWith('.mp3')) {
        return '320k';
      }
      return '320k';
    }

    if (bitrate <= 128000) {
      return '128k';
    } else if (bitrate <= 320000) {
      return '320k';
    } else if (sampleRate != null && sampleRate > 48000) {
      return 'hires';
    } else {
      return 'flac';
    }
  }

  List<String> getAvailableQualities() {
    return state.availableQualities;
  }

  @override
  void dispose() {
    _audioSessionSub?.cancel();
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _stopSaveTimer();
    _clearSeekTarget();
    _positionSub?.cancel();
    _bufferedSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _errorListenerSub?.cancel();
    super.dispose();
  }
}
