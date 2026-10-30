import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import '../domain/models/song.dart';
import '../domain/models/playback_state.dart';
import '../domain/models/play_mode.dart';
import '../data/playback_session_store.dart';
import '../platform/audio_handler.dart';
import '../platform/audio_effect_service.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/services/audio_service_init.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../blacklist/application/blacklist_providers.dart';
import '../../settings/application/settings_providers.dart';
import 'play_progress_providers.dart';
import 'playback_context.dart';
import '../../library/application/recently_played_providers.dart';
import '../../local/application/local_providers.dart';

final audioHandlerProvider = Provider<MusicAudioHandler>((ref) {
  return audioHandler;
});

bool _hasPlayableUrl(String? url) => url != null && url.isNotEmpty;

final playbackControllerProvider =
    StateNotifierProvider<PlaybackController, PlaybackState>((ref) {
      var disposed = false;
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
          persistUserQuality(ref, quality: quality, sourceId: sourceId),
        );
      };
      controller.setPreferredSources(ref.read(preferredSourceMapProvider));
      controller.setDataSourcePlaybackSources(
        ref.read(dataSourcePlaybackSourcesProvider),
      );

      // 黑名单：播放时跳过被拉黑的歌（歌曲 / 歌手黑名单，白名单豁免）。
      controller.isSongBlocked = (song) =>
          ref.read(blacklistProvider).isBlocked(song);
      ref.listen(blacklistProvider, (prev, next) {
        // 正在播的歌被拉黑（或恢复的队列命中黑名单）→ 立刻跳下一首。
        unawaited(controller.skipBlockedCurrent());
      });

      // 「最近播放」：开始播放时记一条（带来源），切歌/退出时结算收听时长。
      final recentRepo = ref.read(recentlyPlayedRepositoryProvider);
      controller.onPlayStarted = (song) {
        final ctx = PlaybackContext.instance;
        unawaited(
          recentRepo.recordPlay(
            song,
            sourceType: ctx.type,
            sourceId: ctx.id,
            sourceName: ctx.name,
            sourceMeta: ctx.sourceMeta,
          ),
        );
        ref.invalidate(recentlyPlayedProvider);
      };
      controller.onListenEnded = (song, listenedMs) {
        unawaited(
          recentRepo
              .recordListen(
                songId: song.id,
                listenedMs: listenedMs,
                durationMs: song.duration * 1000,
              )
              .then((_) {
                // 退出应用时会结算最后一首歌，此时 provider 已经销毁。
                if (!disposed) ref.invalidate(playbackStatsProvider);
              }),
        );
      };

      // 「已听 / 已听 N%」：播放位置按 1% 粒度记进临时库。
      // 开关在「设置 - 播放设置 - 标记歌曲播放状态」，关掉就完全不记录。
      final playedProgress = ref.read(playedProgressProvider.notifier);
      controller.onProgress = (song, positionMs, durationMs) {
        if (!ref.read(markPlayedStatusProvider)) return;
        playedProgress.record(
          songId: song.id,
          positionMs: positionMs,
          durationMs: durationMs,
        );
      };

      ref.listen(preferredSourceMapProvider, (prev, next) {
        controller.setPreferredSources(next);
      });
      ref.listen(dataSourcePlaybackSourcesProvider, (prev, next) {
        controller.setDataSourcePlaybackSources(next);
      });
      controller.onEnsureMusicSourcesReady = () =>
          ref.read(pluginInitializedProvider.future);

      // 「上次播放的歌曲与播放队列」：写入临时库，重启后恢复，
      // 桌面端左侧播放器因此能直接显示出歌曲信息。
      final sessionStore = PlaybackSessionStore();
      var sessionReady = false;
      List<Song>? savedQueue;
      Song? savedSong;
      String? savedQuality;

      void persistSession() {
        // 初始读取完成前不写，避免启动时的空状态把上次会话清掉。
        if (!sessionReady || disposed) return;
        final current = controller.playbackState;
        final song = current.currentSong;
        if (song == null || current.queue.isEmpty) {
          if (savedQueue != null) {
            savedQueue = null;
            savedSong = null;
            savedQuality = null;
            sessionStore.clear();
          }
          return;
        }
        // 播放进度变化非常频繁，只有歌曲 / 队列 / 音质变了才落盘。
        if (identical(current.queue, savedQueue) &&
            identical(song, savedSong) &&
            current.currentQuality == savedQuality) {
          return;
        }
        savedQueue = current.queue;
        savedSong = song;
        savedQuality = current.currentQuality;
        sessionStore.save(
          PlaybackSession(
            song: song,
            queue: current.queue,
            index: current.currentIndex,
            quality: current.currentQuality,
          ),
        );
      }

      controller.addListener((_) => persistSession());

      unawaited(() async {
        final session = await sessionStore.load();
        if (disposed) return;
        final restored =
            session != null &&
            controller.restoreSession(
              queue: session.queue,
              index: session.index,
              quality: session.quality,
            );
        sessionReady = true;
        if (restored) {
          // 刚恢复的内容与已保存的一致，不需要再写一遍。
          final current = controller.playbackState;
          savedQueue = current.queue;
          savedSong = current.currentSong;
          savedQuality = current.currentQuality;
          return;
        }
        persistSession();
      }());

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

      ref
          .read(settingsServiceProvider.future)
          .then((svc) async {
            unawaited(controller.setSpeed(svc.getPlaybackSpeed()));
          })
          .catchError((e) {
            debugPrint('[PlaybackController] settingsService error: $e');
          });

      ref.onDispose(() {
        disposed = true;
        controller.dispose();
      });
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

/// 音源展示名。
///
/// 播放地址由插件解析时，歌曲的音源字段可能是平台 id 或「平台@插件」，
/// 这里统一交给音源管理器给出与切换列表一致的名称。
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
  Future<void> Function()? onEnsureMusicSourcesReady;

  /// 一首歌开始播放时回调（写「最近播放」）。
  void Function(Song song)? onPlayStarted;

  /// 一段收听结束（切歌 / 退出）时回调：实际收听时长 + 歌曲总时长。
  void Function(Song song, int listenedMs)? onListenEnded;

  /// 播放位置变化时回调（写「已听 N%」进度）。位置 / 时长单位均为毫秒。
  void Function(Song song, int positionMs, int durationMs)? onProgress;

  /// 判断一首歌是否在黑名单里（由 provider 注入，控制器不直接依赖黑名单模块）。
  bool Function(Song song)? isSongBlocked;

  bool _blocked(Song song) => isSongBlocked?.call(song) ?? false;

  /// 从 [from] 开始按 [step] 方向找下一首**可播放**的歌（跳过黑名单）。
  ///
  /// 队列里的歌全是黑名单时返回 null。
  int? _nextPlayableIndex(int from, {int step = 1}) {
    final length = state.queue.length;
    if (length == 0) return null;
    for (var offset = 1; offset <= length; offset++) {
      final index = (from + step * offset) % length;
      if (!_blocked(state.queue[index])) return index;
    }
    return null;
  }

  /// 当前歌曲被拉黑时立刻跳到下一首可播放的歌。
  ///
  /// 用户把正在播放的歌加进黑名单时由 provider 触发；黑名单异步加载完成后
  /// 恢复出来的那首歌也可能命中，同样走这里。
  Future<void> skipBlockedCurrent() async {
    final index = state.currentIndex;
    if (index < 0 || index >= state.queue.length) return;
    if (!_blocked(state.queue[index])) return;
    final next = _nextPlayableIndex(index);
    if (next == null) {
      await pause();
      onMessage?.call(tr('队列里的歌曲都在黑名单里'), backgroundColor: Colors.red);
      return;
    }
    await playSongAt(next);
  }

  int _currentPlayRequestId = 0;
  int? _qualitySwitchRequestId;
  bool _settingQueue = false;

  /// 本次播放请求里，音源接口返回的最后一条具体错误（如「HTTP 412 …」）。
  /// 播放失败的提示语带上它，让用户看到接口真实原因而不是笼统的失败。
  String? _lastResolveError;
  Duration _lastEmittedPosition = Duration.zero;
  static const Duration _positionThrottle = Duration(milliseconds: 200);

  // 恢复会话或播放失败后，底层可能仍留着旧曲目，不能直接恢复播放。
  bool _needsSourceLoad = false;

  /// seek 后等待位置流追上目标位置的临时锁。
  ///
  /// 部分播放器在 seek 完成前还会吐出旧位置，如果直接接受会把刚更新的
  /// 进度条/歌词拽回旧位置。位置接近目标后立即解除。
  Duration? _seekTarget;
  Timer? _seekTargetTimer;

  /// 平台 id → 优先插件音源（由设置页维护）。
  Map<String, String> _preferredSources = const {};
  Timer? _loadingTimer;

  /// 本次播放已经失败过的数据源播放源（key = `songId|songSource`）。
  ///
  /// 作用：自动换源时跳过已经确认失败的源，避免在「重试 → 失败 → 重试」
  /// 之间打转。换歌、手动重播、播放源顺序变化时清空。
  final Map<String, Set<String>> _failedPlaybackSources = {};

  /// 每个数据源播放源单独的超时预算（跨平台换源要「搜索 + 取地址」，
  /// 都算在这 10 秒里）。
  static const Duration _dataSourceSourceTimeout = Duration(seconds: 10);

  /// 看门狗武装时记录的播放位置，用于判断是否真的「没有进度」。
  Duration? _stallBaselinePosition;
  static const Duration _loadingTimeout = Duration(seconds: 30);

  /// 供 provider 读取当前状态（[state] 只对 StateNotifier 子类可见）。
  PlaybackState get playbackState => state;

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

  /// 当前这首歌是否已经在「自然播完」时结算过，
  /// 避免随后 playSongAt 里的 _finalizeListenSession 再记一次。
  bool _completedListenCounted = false;

  /// 当前这段「正在出声」的起始播放进度；暂停 / 缓冲 / 停止时为 null。
  ///
  /// 不用计时器：进入可听状态记下进度，暂停 / 切歌 / 退出等关键时机
  /// 用「结束进度 - 起始进度」累加，只有播放器真正在走进度时才会计入。
  Duration? _listenSegmentStart;

  /// 当前这首歌已累计的收听时长（毫秒），跨多次暂停 / 继续累加。
  int _listenAccumMs = 0;

  /// CeruMusic 风格的自动下一首防重入标志。
  /// completed 事件中设为 true，Future.microtask 排空后执行 next()
  /// 前检查此标志。任何用户操作通过 _cancelPendingAutoNext() 清 false，
  /// 避免已入队的 microtask 仍然执行过期的 next()。
  bool _pendingAutoNext = false;

  void _cancelPendingAutoNext() {
    _pendingAutoNext = false;
  }

  /// 上一次收到的处理状态，用来区分「刚播到末尾」和「播完后的暂停/续播」。
  ProcessingState? _lastProcessingState;

  /// 用户主动播放 / 暂停的次数。
  ///
  /// 单曲队列播完时的停顿流程（seek(0) → pause）中间有 await，
  /// 用户可能正好在这段时间点了播放按钮；停顿流程结束时据此判断
  /// 是否该放手，避免把用户刚恢复的播放又停掉。
  int _userPlayActionSeq = 0;

  PlaybackController(
    this._audioHandler,
    this._musicSourceManager,
    this._audioEffectService,
  ) : super(const PlaybackState()) {
    _init();
  }

  /// 更新「平台 id → 优先插件音源」映射。
  void setPreferredSources(Map<String, String> map) {
    _preferredSources = Map<String, String>.from(map);
    // 同步给管理器：解析裸平台 id 时优先用这个插件音源。
    _musicSourceManager.setPreferredSources(_preferredSources);
  }

  /// 更新「数据源 → 播放源有序列表」映射。
  ///
  /// 数据源插件只提供元数据，播放地址由这里列出的播放源按顺序解析；
  /// 前一个失败会自动尝试下一个（见 `resolveViaDataSource`）。
  void setDataSourcePlaybackSources(Map<String, List<String>> map) {
    _musicSourceManager.setDataSourcePlaybackSources(map);
    // 顺序变了，之前记下的「这个源放过这首但失败了」全部作废：用户可能
    // 刚把新的源拖到了最前面，需要重新有机会被尝试。
    _failedPlaybackSources.clear();
  }

  void setAudioEffects(AudioEffectsConfig config) {
    unawaited(_audioEffectService.apply(config));
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

  Future<void> _startPlayback() async {
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
    // 数据源（只提供元数据）解析失败属于「配置问题」，重试没有意义：还会让
    // 用户多等一轮搜索 + 取地址。
    var dataSourceFailure = false;
    var timedOut = false;
    Future<List<PluginMusicUrlResult>> resolveOnce() async {
      try {
        return await _musicSourceManager
            .getMusicUrlResultCandidates(
              song,
              quality: quality,
              excludedUrls: excludedUrls,
              onResolveError: (message) {
                // 只记录仍在生效的播放请求的接口错误，避免被已取消的旧请求覆盖。
                if (_currentPlayRequestId == requestId) {
                  _lastResolveError = message;
                }
              },
            )
            .timeout(_urlFetchTimeout);
      } catch (error) {
        debugPrint(
          '[PlaybackController] current-source URL resolve failed: '
          'source=${song.source} error=$error',
        );
        if (error is DataSourcePlaybackException) dataSourceFailure = true;
        if (error is TimeoutException) timedOut = true;
        if (_currentPlayRequestId == requestId) {
          _lastResolveError = error is TimeoutException
              ? tr('获取播放地址超时')
              : error.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        }
        return const <PluginMusicUrlResult>[];
      }
    }

    var candidates = await resolveOnce();
    if (candidates.isNotEmpty ||
        _currentPlayRequestId != requestId ||
        dataSourceFailure ||
        // 超时已经等满整个取地址窗口，重试只会再等一轮。
        timedOut) {
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
    await _seekWithoutCounting(resumePosition);
  }

  /// 内部直接 seek（换源 / 换音质后恢复进度 / 单曲重播）。
  ///
  /// 跳过的进度不算收听：先结算当前段，再从目标位置重新起算。
  /// 同时乐观更新 position 并加 seek 锁，避免旧的进度事件把起点算错。
  Future<void> _seekWithoutCounting(Duration target) async {
    _closeListenSegment();
    _listenSegmentStart = target;
    _clearSeekTarget();
    _seekTarget = target;
    if (mounted) state = state.copyWith(position: target);
    _seekTargetTimer = Timer(const Duration(seconds: 2), _clearSeekTarget);
    await _audioHandler.seek(target);
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
        // 进度回退（换歌 / 单曲循环从 0 重播）时以新进度为起点，
        // 避免把上一段的进度算到这一段里。
        final listenStart = _listenSegmentStart;
        if (listenStart != null && position < listenStart) {
          _listenSegmentStart = position;
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
      if (!mounted || _needsSourceLoad) return;
      // 真实收听时长：只有真正出声时采样进度，暂停 / 缓冲 / 加载 / 播完都停。
      _syncListenSession(playerState);
      // 暂停 / 停止时记录一次播放进度。
      _maybeReportProgressOnStateChange(playerState);
      // 注意：这里不再用 _settingQueue 门控整个监听器。
      // 之前在 setQueue / playSongAt 期间整体忽略 playerStateStream，
      // 会导致 ready 等关键事件被丢弃，isPlaying / isLoading 长期错乱
      // （按钮卡在转圈、迷你播放器显示暂停态等）。
      // 这里改为始终响应 just_audio 的真实状态，仅在「当前歌曲尚未确定」的
      // 极短窗口内跳过 completed 自动切歌逻辑，避免误触发。
      final processingState = playerState.processingState;
      final isLoading = processingState == ProcessingState.loading;
      // 记住上一个处理状态：暂停 / 重新播放时播放器会连着发好几次
      // completed（playing 翻转不改处理状态），只有真正「播到末尾」
      // 那一次才应该自动切下一首。
      final previousProcessingState = _lastProcessingState;
      _lastProcessingState = processingState;

      if (isLoading) {
        _armStallWatchdog();
      } else {
        _loadingTimer?.cancel();
        _loadingTimer = null;
        _stallBaselinePosition = null;
      }

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
        // 然后 _startPlayback → play() 发出 ready(playing=true)。
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
            isBuffering: processingState == ProcessingState.buffering,
          );
        }
      } else if (processingState == ProcessingState.loading) {
        state = state.copyWith(isLoading: true, isBuffering: false);
        // isPlaying 不变（play()/playSongAt() 已乐观设置）
      } else if (processingState == ProcessingState.completed) {
        debugPrint('[PlaybackController] 歌曲播放完成');
        // 只有「刚播到末尾」那一次才算自然播完：播完后再暂停 / 续播都会让
        // playing 翻转、处理状态仍是 completed，重复当成自然播完会重复结算
        // 收听时长，还会自动 next() 把用户刚恢复的播放又停掉。
        final isNaturalCompletion =
            previousProcessingState != ProcessingState.completed;
        if (isNaturalCompletion) {
          _justCompleted = true;
          // 换队列期间收到的 completed 属于上一首，setQueue 已经结算过，
          // 这里不再重复记录。
          if (!_settingQueue) _recordCompletedListen();
        }
        state = state.copyWith(
          isPlaying: false,
          isLoading: false,
          isBuffering: false,
        );
        // 使用 Future.microtask 延迟 next() 到所有 pending 的
        // playerStateStream 事件（idle/loading 等）处理完毕之后。
        // 直接调用 next() 可能与之竞态，导致 playSongAt 被中断。
        if (isNaturalCompletion && !_settingQueue && !_pendingAutoNext) {
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
          state = state.copyWith(
            isPlaying: false,
            isLoading: false,
            isBuffering: false,
          );
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

  /// 恢复上次退出时的歌曲与队列。
  ///
  /// 只恢复「听什么」，不恢复进度、不自动播放；恢复后用户点播放时，
  /// [play] 会先重新解析在线地址，避免使用已过期的 URL。
  bool restoreSession({
    required List<Song> queue,
    required int index,
    String? quality,
  }) {
    // 启动期间用户已经开始播放：不要用旧会话覆盖。
    if (state.currentSong != null || state.queue.isNotEmpty) return false;
    if (queue.isEmpty) return false;

    final safeIndex = index.clamp(0, queue.length - 1);
    _needsSourceLoad = true;
    state = state.copyWith(
      queue: List<Song>.from(queue),
      currentIndex: safeIndex,
      currentSong: queue[safeIndex],
      position: Duration.zero,
      isPlaying: false,
      isLoading: false,
      currentQuality: (quality == null || quality.isEmpty)
          ? state.currentQuality
          : quality,
    );
    return true;
  }

  // ==================== 核心播放方法 ====================

  /// 取播放地址的总超时。
  ///
  /// 12 秒只够一次插件请求：数据源歌曲还要先在播放源里搜一遍，插件内部也可能
  /// 串行请求多个接口（如「星海」先查自建后端、再换 GD API），两个 10 秒超时
  /// 叠加就超过 12 秒，看起来像「必超时」。这里给到 25 秒，正好覆盖「搜索 +
  /// 插件内部两次请求」的最坏情况。
  /// 解析播放地址的总超时。
  ///
  /// 要留出插件内部的 30 秒请求超时（见 PluginHost 的解析期下限）；这里设
  /// 50 秒，让「插件自己超时」的错误信息优先暴露，而不是被外层掐断成
  /// 「获取播放地址超时」。
  static const Duration _urlFetchTimeout = Duration(seconds: 50);
  static const Duration _audioSetTimeout = Duration(seconds: 10);
  static const Duration _musicSourceReadyTimeout = Duration(seconds: 12);

  /// 上一次看到的「是否正在播放」，用来捕捉「播放 → 暂停 / 停止」这一下。
  bool _wasPlaying = false;

  /// 上报当前播放进度（用于「已听 N%」标签）。
  ///
  /// 播放进度不是关键数据，没必要跟着位置流逐秒记录：只在
  /// 切上一首 / 下一首、暂停、停止、退出这几个节点各记一次。
  /// 位置流每秒 5 次的高频回调在这里完全不参与。
  void _reportProgressNow() {
    final song = state.currentSong;
    if (song == null || !mounted) return;
    final durationMs = state.duration.inMilliseconds > 0
        ? state.duration.inMilliseconds
        : song.duration * 1000;
    if (durationMs <= 0) return;
    onProgress?.call(song, state.position.inMilliseconds, durationMs);
  }

  /// 播放状态从「正在播」变成「不播」时（暂停 / 停止 / 播完）记一次进度。
  void _maybeReportProgressOnStateChange(PlayerState playerState) {
    final wasPlaying = _wasPlaying;
    _wasPlaying = playerState.playing;
    if (wasPlaying && !playerState.playing) {
      _reportProgressNow();
    }
  }

  /// 播放器状态 → 收听区间的开关。
  ///
  /// `playing` 在缓冲 / 加载时也可能为 true（playWhenReady），所以必须同时
  /// 要求 `processingState == ready`，否则把等待缓冲的时间也算进听歌时长。
  void _syncListenSession(PlayerState playerState) {
    final audible =
        playerState.playing &&
        playerState.processingState == ProcessingState.ready;
    if (audible) {
      _listenSegmentStart ??= _audioHandler.currentPosition;
    } else {
      _closeListenSegment();
    }
  }

  /// 结束当前收听区间，把这段时间的播放进度累加进 [_listenAccumMs]。
  ///
  /// 进度回退（换歌 / 单曲循环）时 delta 不为正，直接忽略。
  void _closeListenSegment([Duration? position]) {
    final start = _listenSegmentStart;
    if (start == null) return;
    _listenSegmentStart = null;
    // 直接读播放器的真实进度：state.position 有 200ms 节流，
    // 后台挂起时也可能停在旧值。
    final delta = (position ?? _audioHandler.currentPosition) - start;
    if (delta > Duration.zero) _listenAccumMs += delta.inMilliseconds;
  }

  /// 结算上一首的收听时长。
  ///
  /// 用各段播放进度差累计：暂停、缓冲、拖动进度条跳过的部分都不计入；
  /// 同一首歌重复播放时，每次结算都会单独累加。
  void _finalizeListenSession() {
    // 切上一首 / 下一首、清空队列、退出应用都会走到这里：先记一次播放进度。
    _reportProgressNow();
    _closeListenSegment();
    final listened = _listenAccumMs;
    _listenAccumMs = 0;
    // 自然播完已经结算过的话，这里累计值已被清零，不会重复上报。
    _completedListenCounted = false;
    final song = state.currentSong;
    if (song == null || listened < 1000) return;
    onListenEnded?.call(song, listened);
  }

  /// 应用退出前主动调用：把当前这段真实收听时长结算掉。
  ///
  /// 退出时 provider 不一定会被 dispose，最后一小段统计会丢，所以由退出流程
  /// 调一次；[_finalizeListenSession] 会清零累计值，重复调用没有副作用。
  void settleListenSession() => _finalizeListenSession();

  /// 自然播完时结算：用进度差累计的真实收听时长，而不是歌曲总时长。
  void _recordCompletedListen() {
    if (_completedListenCounted) return;
    _completedListenCounted = true;
    _closeListenSegment();
    final listened = _listenAccumMs;
    _listenAccumMs = 0;
    final song = state.currentSong;
    if (song == null) return;
    // 整首播完 = 进度 100%，界面显示「已听」。
    if (song.duration > 0) {
      onProgress?.call(song, song.duration * 1000, song.duration * 1000);
    }
    if (listened < 1000) return;
    onListenEnded?.call(song, listened);
  }

  Future<void> playSongAt(
    int index, {
    bool finalizePrevious = true,
    int skipStep = 1,
    bool skipBlocked = true,
  }) async {
    if (index < 0 || index >= state.queue.length) return;

    // 黑名单歌曲不播放：按播放方向跳到下一首可播放的歌。
    if (skipBlocked && _blocked(state.queue[index])) {
      final playable = _nextPlayableIndex(index, step: skipStep);
      if (playable == null) {
        state = state.copyWith(isLoading: false, isPlaying: false);
        onMessage?.call(tr('队列里的歌曲都在黑名单里'), backgroundColor: Colors.red);
        return;
      }
      index = playable;
    }

    _needsSourceLoad = false;
    _cancelPendingAutoNext();
    _clearSeekTarget();
    _loadingTimer?.cancel();
    _loadingTimer = null;

    _settingQueue = true;
    // 清除 completed 标记：新歌开始播放，后续的 ready 事件应正常处理
    _justCompleted = false;
    _lastResolveError = null;
    final requestId = ++_currentPlayRequestId;
    final song = state.queue[index];
    // 切歌时要清掉上一首解析出来的真实时长：actualDuration 只会在拿到新
    // 时长时被覆盖，不清就会在「新歌时长未知」的窗口里显示上一首的长度
    // （酷狗等没有时长元数据的歌尤其明显）。同一首歌重播则保留。
    final previousSongId = state.currentSong?.id;

    debugPrint(
      '[PlaybackController] playSongAt: ${song.title}, index=$index, requestId=$requestId',
    );

    // 用户点播了新歌：立刻停掉正在播放的旧歌，不让它在防抖等待与
    // 新歌解析期间继续发声（表现为「点了 b 之后 a 还在唱」）。
    // 自动连播（歌曲已播完）时播放器本来就不在播放，不会走到这里。
    if (state.isPlaying || _audioHandler.playing) {
      try {
        await _audioHandler.pause();
      } catch (_) {}
      if (_currentPlayRequestId != requestId) return;
      if (mounted) state = state.copyWith(isPlaying: false);
    }

    // 照搬 CeruMusic：300ms 防抖，防止快速切歌导致并发请求混乱
    await Future.delayed(const Duration(milliseconds: 300));
    if (_currentPlayRequestId != requestId) return;

    // 切歌前先把上一首的收听时长结算掉，再记录这首歌的播放。
    // setQueue 会先重置 position / currentSong，因此它传入 false 并自己提前结算。
    if (finalizePrevious) _finalizeListenSession();
    onPlayStarted?.call(song);

    _errorListenerSub?.cancel();
    _errorListenerSub = null;

    final sourceId = song.source ?? '';
    final isLocal = sourceId == 'local';
    if (!isLocal) {
      await _ensureMusicSourcesReady();
      if (_currentPlayRequestId != requestId) return;
    }
    final pendingCoverFuture =
        !isLocal && (song.coverUrl == null || song.coverUrl!.isEmpty)
        ? _musicSourceManager.getPic(song)
        : null;
    final quality = isLocal
        ? _getQualityFromSong(song)
        : (getQualityForSource?.call(SourceInfo.baseIdOf(sourceId)) ??
              _getQualityFromSong(song));
    // 音质列表要跟着「真正出面解析地址的那个源」走：数据源歌曲的 source 是
    // 数据源插件（它不提供播放），真正的音质声明在它的播放源上。
    final qualitySourceId = isLocal
        ? sourceId
        : (_musicSourceManager.effectivePlaybackSourceForSong(song) ?? sourceId);
    final availableQualities = isLocal
        ? <String>[quality]
        : _musicSourceManager.getQualitiesForSourceId(qualitySourceId);
    // 需要登录才能用的档位：仍然显示，但置灰（不隐藏，用户才知道有这个音质）。
    final gatedQualities = isLocal
        ? const <String>{}
        : _musicSourceManager.getLoginGatedQualities(qualitySourceId);
    state = state.copyWith(
      currentIndex: index,
      currentSong: song,
      position: Duration.zero,
      // 换歌 → 时长归零（null 表示沿用，同歌重播不清）。
      actualDuration: previousSongId == song.id ? null : Duration.zero,
      isLoading: true,
      currentQuality: quality,
      availableQualities: availableQualities,
      gatedQualities: gatedQualities,
    );

    try {
      Song currentSongToPlay = song;
      String? urlToPlay = song.sourceUrl;
      var resolvedUrlCandidates = <PluginMusicUrlResult>[];

      // 队列里的地址是按「解析时的音质」保存的。用户之后切换过音质（全局
      // 默认音质 / 播放页手动切换），这个地址（以及它命中的缓存文件）就是
      // 旧音质的；必须清掉重新解析，否则会出现「界面显示 320k、实际播的还是
      // 128k 缓存」。音质没变则继续复用地址，避免每次都联网解析。
      if (!isLocal &&
          _hasPlayableUrl(urlToPlay) &&
          urlToPlay!.startsWith('http') &&
          song.sourceQuality != quality) {
        debugPrint(
          '[PlaybackController] 音质已变化，重新解析: ${song.title} '
          'song=${song.sourceQuality} current=$quality',
        );
        currentSongToPlay = currentSongToPlay.copyWith(
          clearSourceUrl: true,
          clearSourceHeaders: true,
          clearSourceQuality: true,
        );
        urlToPlay = null;
      }

      if (isLocal && urlToPlay != null && urlToPlay.isNotEmpty) {
        try {
          await _audioHandler
              .setAudioSource(urlToPlay, song: currentSongToPlay)
              .timeout(_audioSetTimeout);
          await _startPlayback();
        } catch (_) {
          if (_currentPlayRequestId != requestId) return;
          await _stopPlaybackOnFailure(tr('播放歌曲失败'));
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
            sourceQuality: quality,
            clearSourceHeaders: result.headers.isEmpty,
            clearSourceQuality: false,
            // 歌曲由插件解析地址，这里把音源标记成实际提供地址的插件，
            // 播放详情页显示的就是真正正在使用的音源。
            source: result.source ?? currentSongToPlay.source,
          );
          _replaceSongInQueue(index, currentSongToPlay);
        }
      }

      if (urlToPlay == null || urlToPlay.isEmpty) {
        if (_currentPlayRequestId != requestId) return;
        await _stopPlaybackOnFailure(_playbackFailureReason(song));
        return;
      }

      final playUrl = urlToPlay;
      try {
        await _audioHandler
            .setAudioSource(playUrl, song: currentSongToPlay)
            .timeout(_audioSetTimeout);
        await _startPlayback();
      } catch (_) {
        if (_currentPlayRequestId != requestId) return;

        // 地址不可播放时，只尝试同音质的其它候选地址。
        final failedUrls = <String>{playUrl};
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
              sourceQuality: quality,
              // 标记实际提供地址的音源，界面上显示真正正在使用的音源。
              source: candidate.source ?? currentSongToPlay.source,
              clearSourceHeaders: candidate.headers.isEmpty,
              clearSourceQuality: false,
            );
            await _audioHandler
                .setAudioSource(candidateUrl, song: fallbackSong)
                .timeout(_audioSetTimeout);
            await _startPlayback();
            currentSongToPlay = fallbackSong;
            _replaceSongInQueue(index, fallbackSong);
            state = state.copyWith(isLoading: false, currentSong: fallbackSong);
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

        if (_currentPlayRequestId != requestId) return;
        await _stopPlaybackOnFailure(_playbackFailureReason(song));
        return;
      }

      // CeruMusic: 不乐观设 isPlaying
      state = state.copyWith(isLoading: false, currentSong: currentSongToPlay);

      _errorListenerSub = _mountOneTimeErrorListener(
        requestId,
        index,
        currentSongToPlay,
      );
    } catch (e) {
      debugPrint('[PlaybackController] playSongAt error: $e');
      if (_currentPlayRequestId != requestId) return;
      // 优先显示音源接口返回的具体错误（如 HTTP 412），没有才用笼统提示。
      final detail = _lastResolveError?.trim() ?? '';
      await _stopPlaybackOnFailure(detail.isEmpty ? tr('播放歌曲失败') : detail);
    } finally {
      if (pendingCoverFuture != null && _currentPlayRequestId == requestId) {
        unawaited(
          _applyResolvedCover(
            song: song,
            index: index,
            requestId: requestId,
            coverFuture: pendingCoverFuture,
          ),
        );
      }
      _settingQueue = false;
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
      //
      // 两步各自兜底：seek 失败也不能跳过 pause，否则播放器内部的
      // playing 会一直挂着 true，之后点播放按钮会被 just_audio 直接忽略。
      final actionSeq = _userPlayActionSeq;
      try {
        await _seekWithoutCounting(Duration.zero);
      } catch (e) {
        debugPrint('[PlaybackController] 停止前 seek(0) 失败: $e');
      }
      // 这段 await 期间用户点了播放 / 暂停：以用户操作为准，不再停顿。
      if (_userPlayActionSeq != actionSeq) return;
      try {
        await _audioHandler.pause();
      } catch (e) {
        debugPrint('[PlaybackController] 暂停失败: $e');
      }
      if (_userPlayActionSeq != actionSeq) return;
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
        // 单曲循环重新开始：从 0 重新起算这一段。
        await _seekWithoutCounting(Duration.zero);
        await _audioHandler.play();
        // 允许下一次播完继续结算。
        _completedListenCounted = false;
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
        await playSongAt(prevIndex, skipStep: -1);
      }
    } catch (e) {
      debugPrint('[PlaybackController] previous() error: $e');
      onMessage?.call(tr('播放上一首失败'), backgroundColor: Colors.red);
    }
  }

  // ==================== 播放控制 ====================

  Future<void> play() async {
    _cancelPendingAutoNext();
    _userPlayActionSeq++;
    // 用户主动播放，清除 completed 标记
    _justCompleted = false;
    // 播完后用户又点了播放：这是一次新的收听，重新允许结算。
    _completedListenCounted = false;
    if (_needsSourceLoad) {
      final index = _currentIndex;
      if (index >= 0 && index < state.queue.length) {
        await playSongAt(index, finalizePrevious: false);
        return;
      }
      _needsSourceLoad = false;
    }
    // 上一首自然播完（播放器停在末尾）时再次点播放，就是要「重新播放这首」。
    // 但 Windows 的 media_kit 后端在播完后有两个坑：
    // 1. 内部 playWhenReady 仍为 true，而 just_audio 的 play() 看到 playing
    //    已为 true 会直接返回，播放器依旧停在末尾——表现为点了播放按钮毫无反应；
    // 2. media_kit 在 completed 事件里把上报进度重置成 0，
    //    「进度 >= 时长」永远不成立（上一次就栽在这里），必须看处理状态。
    // 所以先把内部 playing 归位、再回到开头，最后才下发真正的播放请求。
    final atEnd =
        _audioHandler.processingState == ProcessingState.completed ||
        _isPositionAtEnd();
    // 加载中不插手：此时播放请求本来就会被在途的 setAudioSource 接管，
    // 暂停只会把上一首的声音再放出来一下。
    if (_audioHandler.playing && !state.isLoading) {
      try {
        await _audioHandler.pause();
      } catch (_) {
        // 暂停失败也继续，下面照常下发播放请求。
      }
    }
    if (atEnd) {
      try {
        await _seekWithoutCounting(Duration.zero);
      } catch (_) {
        // 读不到进度 / seek 失败就按原路径播，别让播放按钮卡死。
      }
    }
    await _audioHandler.play();
    // 遵循 CeruMusic：不乐观设 isPlaying=true。
    // 由 _playerStateSub 的 ready(playing=true) 或微任务兜底同步。
  }

  bool _isPositionAtEnd() {
    final duration = _audioHandler.currentDuration;
    return duration != null &&
        duration > Duration.zero &&
        _audioHandler.currentPosition >= duration;
  }

  Future<void> pause() async {
    _cancelPendingAutoNext();
    _userPlayActionSeq++;
    // 遵循 CeruMusic stop()：先立即设 isPlay=false，再调 audio.pause()。
    // 这样即使 audio.pause() 异步延迟或失败，UI 状态也已正确更新。
    _justCompleted = false;
    state = state.copyWith(isPlaying: false);
    await _audioHandler.pause();
  }

  Future<void> togglePlayPause() async {
    // 遵循 CeruMusic：以实际播放器状态判断按钮意图，
    // 不依赖可能滞后的 state.isPlaying。
    // CeruMusic 的 togglePlayPause:
    //   const isActuallyPlaying = a ? !a.paused : Audio.value.isPlay
    //
    // 但要同时看 state.isPlaying：歌曲自然播完后部分后端（Windows 的
    // media_kit）的 playWhenReady 仍为 true，此时 state.isPlaying=false、
    // 按钮显示「播放」——若只看 handler 会误走 pause()，点击就没反应。
    // 两个都为 true 才算「正在播放」，否则一律按「要播放」处理（重复 play
    // 是幂等的，不会引入新问题）。
    final isActuallyPlaying = _audioHandler.playing && state.isPlaying;
    if (isActuallyPlaying && !_needsSourceLoad) {
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

    // 拖动进度条跳过的部分不算收听：先按当前位置结算这一段，
    // 再从新位置重新起算。
    _closeListenSegment();
    if (state.isPlaying) _listenSegmentStart = target;

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
    // 用户主动起播 → 解除 clearQueue() 设置的会话屏蔽，
    // 否则 playSongAt 里的 setAudioSource 会被忽略、根本播不出声音。
    _audioHandler.markSessionActive();
    _settingQueue = true;
    final index = startIndex.clamp(0, songs.length - 1);

    // 先按「上一首的当前位置」结算收听时长，再重置状态；
    // 否则 position 已被清零，统计事件会永远记不到。
    _finalizeListenSession();

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
    await playSongAt(index, finalizePrevious: false);
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
    // 清空队列前先把这首歌的真实收听时长结算掉。
    _finalizeListenSession();
    // 1) 作废所有在途的加载 / 换源 / 音质切换请求
    _currentPlayRequestId++;
    _qualitySwitchRequestId = null;
    unawaited(_errorListenerSub?.cancel());
    _errorListenerSub = null;
    _justCompleted = false;
    _cancelPendingAutoNext();
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _stallBaselinePosition = null;
    _needsSourceLoad = false;

    // 2) 复位状态。
    state = const PlaybackState();

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

    // 只允许切到「当前音源声明过」的档位：请求一个插件根本不支持的音质，
    // 结果要么报错、要么被静默降级（界面显示 flac、实际播 320k），都不如
    // 直接说清楚。
    final declared = state.availableQualities;
    if (declared.isNotEmpty && !declared.contains(quality)) {
      onMessage?.call(
        tr('当前音源不支持该音质'),
        backgroundColor: Colors.red,
      );
      return;
    }
    // 需要登录的档位：说明原因，别让用户以为「点了没反应」。
    if (state.gatedQualities.contains(quality)) {
      onMessage?.call(
        tr('该音质需要先在 插件管理 → 该插件 → 凭据 里填写登录信息'),
        backgroundColor: Colors.orange,
      );
      return;
    }

    final requestId = ++_currentPlayRequestId;
    _qualitySwitchRequestId = requestId;
    state = state.copyWith(isLoading: true);
    final currentPosition = state.position;
    final originalUrl = currentSong.sourceUrl;
    final index = _currentIndex;
    final wasPlaying = state.isPlaying || _audioHandler.playing;

    // 正在播放时替换音源，部分平台（ExoPlayer / media_kit）会偶发 prepare
    // 失败，换完音源再按原状态恢复播放。
    if (wasPlaying) {
      try {
        await _audioHandler.pause();
      } catch (_) {}
      if (_currentPlayRequestId != requestId) return;
    }

    try {
      final result = await _musicSourceManager
          .getMusicUrlResult(currentSong, quality: quality)
          .timeout(_urlFetchTimeout);
      if (_currentPlayRequestId != requestId) return;

      if (result == null || result.url.isEmpty) {
        await _resumeAfterQualitySwitch(requestId, wasPlaying);
        state = state.copyWith(isLoading: false);
        _finishQualitySwitch(requestId);
        onMessage?.call(
          tr('无法获取该音质的播放链接，当前音质保持不变'),
          backgroundColor: Colors.red,
        );
        return;
      }

      final updatedSong = currentSong.copyWith(
        sourceUrl: result.url,
        sourceHeaders: result.headers.isEmpty ? null : result.headers,
        sourceQuality: quality,
        clearSourceHeaders: result.headers.isEmpty,
        clearSourceQuality: false,
        // 标记实际提供地址的音源，界面上显示真正正在使用的音源。
        source: result.source ?? currentSong.source,
      );
      if (index >= 0 && index < state.queue.length) {
        _replaceSongInQueue(index, updatedSong);
      }
      await _audioHandler
          .setAudioSource(result.url, song: updatedSong)
          .timeout(_audioSetTimeout);
      if (_currentPlayRequestId != requestId) return;
      _needsSourceLoad = false;
      await _seekWithoutCounting(currentPosition);
      state = state.copyWith(
        isLoading: false,
        isPlaying: wasPlaying,
        currentQuality: quality,
        currentSong: updatedSong,
      );
      await _resumeAfterQualitySwitch(requestId, wasPlaying);
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
          await _seekWithoutCounting(currentPosition);
          await _resumeAfterQualitySwitch(requestId, wasPlaying);
        } else {
          await _resumeAfterQualitySwitch(requestId, wasPlaying);
        }
      } catch (_) {
        await _resumeAfterQualitySwitch(requestId, wasPlaying);
      }
      state = state.copyWith(isLoading: false, isPlaying: wasPlaying);
      _finishQualitySwitch(requestId);
      onMessage?.call(tr('切换音质失败，当前音质保持不变: $e'), backgroundColor: Colors.red);
    }
  }

  /// 切换音质时若原本在播放，替换完音源后恢复播放。
  Future<void> _resumeAfterQualitySwitch(int requestId, bool wasPlaying) async {
    if (!wasPlaying || _currentPlayRequestId != requestId) return;
    try {
      await _audioHandler.play();
    } catch (_) {}
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
      state = state.copyWith(currentSong: updatedSong, forceCurrentSong: true);
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
      if (currentSong == null || currentSong.id != song.id) return;

      // 解析地址时会把队列歌曲的 source 从平台 id 改写成「平台id@插件id」
      // （用来显示实际提供地址的插件），所以这里只能比较平台部分；直接比较
      // source 会让插件音源解析的歌永远补不上封面（表现为详情页 / 左侧栏
      // 空白，列表却有封面）。
      final (currentBaseId, _) = MusicSourceManager.splitSourceId(
        currentSong.source ?? '',
      );
      final (songBaseId, _) = MusicSourceManager.splitSourceId(
        song.source ?? '',
      );
      if (currentBaseId != songBaseId) return;

      // 已有封面就不动，避免把列表里可用的封面换成解析结果里的坏地址。
      if (currentSong.coverUrl?.isNotEmpty ?? false) {
        return;
      }
      if (currentSong.coverUrl == coverUrl) return;

      final enrichedSong = currentSong.copyWith(coverUrl: coverUrl);
      if (index >= 0 &&
          index < state.queue.length &&
          state.queue[index].id == currentSong.id) {
        _replaceSongInQueue(index, enrichedSong);
      }
      // Song 的相等性只看 id，copyWith 默认会把「同 id 的新歌」当成没变化
      // 直接丢弃；这里必须强制替换，否则补出来的封面只进了队列、播放页
      // 拿到的 currentSong 仍然没有封面（只有本来就没封面的歌会中招）。
      state = state.copyWith(currentSong: enrichedSong, forceCurrentSong: true);
      _audioHandler.updateCurrentMediaItem(enrichedSong);
    } catch (error) {
      debugPrint('[PlaybackController] cover resolution failed: $error');
    }
  }

  /// 播放失败时的提示语。
  ///
  /// * **平台音源**：平台上一个已启用的插件都没有时，提示用户去安装对应
  ///   平台的音源；装了插件但解析失败（如接口 412 风控、大会员专享），
  ///   则显示「解析失败」并带上接口返回的具体错误；
  /// * **插件绑定音源**（`平台@插件`）：直接说明当前音源播放失败，
  ///   并尽量附上接口返回的具体错误。
  String _playbackFailureReason(Song song) {
    final source = song.source ?? '';
    String withDetail(String base) {
      final detail = _lastResolveError?.trim() ?? '';
      return detail.isEmpty ? base : '$base：$detail';
    }

    if (source == 'local') return tr('本地文件无法播放');
    // 数据源（只提供元数据）的失败提示本身就是完整说明（含「请在插件管理中
    // 设置其他音源」），不要再套一层「当前音源播放失败」。
    // 注意：数据源的歌 source 仍记平台 id（如 wy），数据源绑定在
    // preferredSource 上，所以这里按「整首歌」判断。
    if (_musicSourceManager.dataSourcePluginIdForSong(song) != null) {
      final detail = _lastResolveError?.trim() ?? '';
      return detail.isEmpty ? tr('此数据源未指定可用的播放源，请在插件管理中设置其他音源。') : detail;
    }
    if (source.isNotEmpty && !source.contains('@')) {
      final (baseId, _) = MusicSourceManager.splitSourceId(source);
      if (baseId.isNotEmpty &&
          _musicSourceManager.hasPluginForPlatform(baseId)) {
        // 装了插件（如 bilibili 插件）但接口失败 → 不是「没装插件」，
        // 提示里带上接口返回的真实错误（HTTP 状态码 / 响应内容）。
        final name =
            _sourceIdToChineseName[baseId] ??
            _getSourceName(source, _musicSourceManager);
        return withDetail(tr('$name音源解析失败'));
      }
      return _missingSourceMessage(source);
    }
    return withDetail(tr('当前音源播放失败'));
  }

  /// 平台没有已安装的插件音源时的提示。
  String _missingSourceMessage(String source) {
    final (baseId, _) = MusicSourceManager.splitSourceId(source);
    final name =
        _sourceIdToChineseName[baseId] ??
        _getSourceName(source, _musicSourceManager);
    return tr('没有第三方对应$name音源，请先安装$name音源');
  }

  /// 播放失败后的统一收尾：停止播放并提示，绝不自动播放下一首。
  Future<void> _stopPlaybackOnFailure(String reason) async {
    debugPrint('[PlaybackController] 播放失败，停止播放：$reason');

    // 播放异常停止：先把这一段收听时长结算掉。
    _finalizeListenSession();

    _cancelPendingAutoNext();
    _needsSourceLoad = true;
    unawaited(_errorListenerSub?.cancel());
    _errorListenerSub = null;
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _stallBaselinePosition = null;
    if (mounted) {
      final song = state.currentSong;
      final index = _currentIndex;
      if (song != null && !song.isLocal && index >= 0) {
        final retrySong = song.copyWith(
          clearSourceUrl: true,
          clearSourceHeaders: true,
          clearSourceQuality: true,
        );
        final queue = List<Song>.from(state.queue)..[index] = retrySong;
        state = state.copyWith(currentSong: retrySong, queue: queue);
      }
      state = state.copyWith(isPlaying: false, isLoading: false);
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
    // 数据源（只提供元数据）的失败原因本身就是一整句完整说明
    // （「此 xxx数据源指定的 xxx音源失效… 请在插件管理中设置其他音源。」），
    // 原样展示，不再加「播放失败：」前缀。
    final isDataSourceFailure =
        reason.startsWith('此') && reason.contains('数据源');
    onMessage?.call(
      isDataSourceFailure
          ? reason
          : (isRateLimited
                ? tr('播放失败：$reason，请稍后重试')
                : tr('播放失败：$reason，已停止播放')),
      backgroundColor: Colors.red,
    );
  }

  /// 一次性错误监听器（照搬 CeruMusic 的 error listener 机制）
  ///
  /// CeruMusic 使用 HTML5 Audio 元素的原生 error 事件（{ once: true }），
  /// 一次性检测播放错误并尝试恢复播放。这里用 just_audio 的 playerStateStream
  /// 模拟相同的语义：
  ///
  /// 1. 监听异常 processingState 过渡：ready/loading/buffering → idle
  /// 2. 至少播放 minPlayDuration 后才激活（避免启动阶段的误判）
  /// 3. 一次性：触发一次后自动取消订阅
  ///
  /// 失败处理逻辑（对齐 CeruMusic error handler，但失败后不自动跳歌）：
  /// - 按当前音质重新获取 URL（可能只是 URL 过期），失败则停止播放。
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

      // 自然完成 → 不算播放错误
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

      debugPrint('[PlaybackController] 检测到播放错误: $lastState → idle, 尝试恢复播放');

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
            .resolveSingleSongUrl(
              song,
              quality: state.currentQuality,
              excludedUrls: excludedUrls,
              onResolveError: (message) {
                if (_currentPlayRequestId == requestId) {
                  _lastResolveError = message;
                }
              },
            )
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
            await _startPlayback();
            await _resumeFromPosition(resumePosition);
            state = state.copyWith(currentSong: resolved, isLoading: false);
            onMessage?.call(
              tr(
                '已重新获取 ${_getSourceName(resolved.source ?? '', _musicSourceManager)} 源 URL，继续播放',
              ),
            );
            return;
          } catch (_) {
            debugPrint('[PlaybackController] 原源新 URL 播放失败');
          }
        }

        // 2) 本音源已无可用地址 → 停止播放（不跨音源换源、不自动跳歌）
        if (_currentPlayRequestId != requestId) return;
        await _stopPlaybackOnFailure(_playbackFailureReason(song));
      } catch (e) {
        debugPrint('[PlaybackController] 处理播放错误时出错: $e');
        if (_currentPlayRequestId != requestId) return;
        // 用统一的失败提示：数据源（只提供元数据）的「指定的 xxx音源失效」
        // 说明会由 _playbackFailureReason 原样带出，不能退化成「播放出错」。
        await _stopPlaybackOnFailure(_playbackFailureReason(song));
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
    // 退出前结算当前歌曲的收听时长（否则最后一段统计会丢）。
    _finalizeListenSession();
    _audioSessionSub?.cancel();
    _loadingTimer?.cancel();
    _loadingTimer = null;
    _clearSeekTarget();
    _positionSub?.cancel();
    _bufferedSub?.cancel();
    _durationSub?.cancel();
    _playerStateSub?.cancel();
    _errorListenerSub?.cancel();
    super.dispose();
  }
}
