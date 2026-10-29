import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_font_manager.dart';
import '../../settings/application/font_providers.dart';
import '../../settings/application/settings_providers.dart';
import '../domain/models/desktop_lyric_settings.dart';
import '../domain/models/lyric_line.dart';
import '../domain/models/song.dart';
import '../platform/desktop_lyric_overlay.dart';
import 'desktop_lyric_controller.dart';
import 'lyric_controller.dart';
import 'playback_controller.dart';

/// 桌面歌词的运行状态。
class DesktopLyricStatus {
  const DesktopLyricStatus({
    this.supported = false,
    this.permissionGranted = false,
    this.overlayShowing = false,
  });

  /// 当前平台是否支持系统级悬浮窗(Android)。
  final bool supported;

  /// 是否已获得「在其他应用上层显示」权限。
  final bool permissionGranted;

  /// 系统悬浮窗当前是否已显示。
  final bool overlayShowing;

  /// 歌词正由系统悬浮窗渲染。为 false 时回退到应用内悬浮层。
  bool get usingNativeOverlay =>
      supported && permissionGranted && overlayShowing;

  DesktopLyricStatus copyWith({
    bool? supported,
    bool? permissionGranted,
    bool? overlayShowing,
  }) {
    return DesktopLyricStatus(
      supported: supported ?? this.supported,
      permissionGranted: permissionGranted ?? this.permissionGranted,
      overlayShowing: overlayShowing ?? this.overlayShowing,
    );
  }
}

/// 把「设置 + 播放状态 + 歌词」同步到系统悬浮窗。
///
/// 三件事:
/// 1. 权限:未授权时引导授权,从授权页返回(resumed)后自动重试;
/// 2. 歌词:桌面歌词开启时主动为当前歌曲拉取歌词(歌词页未打开时也要拉);
/// 3. 渲染:歌词行变化时整批下发,当前行变化时只下发行号。
class DesktopLyricSyncController extends StateNotifier<DesktopLyricStatus>
    with WidgetsBindingObserver {
  DesktopLyricSyncController(this._ref) : super(const DesktopLyricStatus()) {
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  final Ref _ref;
  final DesktopLyricOverlay _overlay = DesktopLyricOverlay.instance;

  String? _lastLyricSignature;
  int _lastPushedIndex = -1;

  /// 用户点了开启但还没拿到悬浮窗权限:授权成功后自动开启。
  bool _pendingEnable = false;

  /// 周期同步定时器:进度锚点 + 歌词兜底下发。
  Timer? _syncTimer;

  /// 上一次观测到的播放进度。
  ///
  /// 后台时 Dart 的进度回调可能被节流而停滞;此时若继续下发同一个进度,
  /// 会把原生侧正在自行推进的时钟反复拉回去,导致歌词卡住不更新。
  int _lastObservedPositionMs = -1;

  /// 上一次下发给原生侧的播放状态（暂停时原生侧会停止推进歌词行）。
  bool? _lastPushedPlaying;

  /// 正在加载歌词的歌曲 id(用于检测卡死的加载)。
  String? _lyricLoadingSongId;
  DateTime? _lyricLoadingSince;

  /// 单次同步是否正在进行,避免定时器回调重叠。
  bool _syncing = false;

  Future<void> _bootstrap() async {
    _overlay.setPositionListener(_onPositionChanged);
    if (!_overlay.supported) {
      state = const DesktopLyricStatus(supported: false);
      return;
    }
    await refreshPermission();
  }

  @override
  void dispose() {
    _stopSyncTimer();
    _overlay.setPositionListener(null);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 从系统授权页返回后重新检查权限。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refreshPermission());
    }
  }

  Future<void> refreshPermission() async {
    if (!_overlay.supported) return;
    final granted = await _overlay.checkPermission();
    if (!mounted) return;
    this.state = this.state.copyWith(
      supported: true,
      permissionGranted: granted,
    );
    if (!granted) {
      await _overlay.hide();
      _stopSyncTimer();
      if (mounted) this.state = this.state.copyWith(overlayShowing: false);
      return;
    }
    // 授权成功后补上之前被拦下的「开启」操作。
    if (_pendingEnable) {
      _pendingEnable = false;
      _setEnable(true);
    }
    await syncVisibility();
  }

  /// 打开系统悬浮窗授权页。
  Future<void> requestPermission() => _overlay.openPermissionSettings();

  /// 开启桌面歌词:**先取权限,拿到之后才真正开启**。
  ///
  /// 未授权时不写 `enable = true`,而是跳到系统授权页;用户授权后回到应用
  /// ([didChangeAppLifecycleState] -> [refreshPermission])再自动开启。
  Future<void> enableDesktopLyric() async {
    // 非 Android(应用内回退方案)不需要权限。
    if (!_overlay.supported) {
      _setEnable(true);
      return;
    }
    if (await _overlay.checkPermission()) {
      await refreshPermission();
      _setEnable(true);
      return;
    }
    _pendingEnable = true;
    await _overlay.openPermissionSettings();
  }

  Future<void> disableDesktopLyric() async {
    _pendingEnable = false;
    _setEnable(false);
  }

  void _setEnable(bool value) {
    updateDesktopLyricSettings(_ref.read, (s) => s.copyWith(enable: value));
  }

  // ------------------------------------------------------------------ 同步

  /// 设置变化:开关变化影响显示与否,其余样式项直接下发给原生。
  void onSettingsChanged(
    DesktopLyricSettings? previous,
    DesktopLyricSettings next,
  ) {
    if (previous?.enable != next.enable) {
      unawaited(syncVisibility());
      return;
    }
    if (!state.usingNativeOverlay) return;
    unawaited(_pushConfig(next));
  }

  /// 下发样式配置（含歌词字体设置）。
  Future<void> _pushConfig(DesktopLyricSettings settings) async {
    final font = await _lyricFont();
    final fontWeight = _ref.read(lyricFontWeightProvider).clamp(100, 900);
    final fontSizeRate = _ref.read(lyricFontRateProvider).clamp(0.5, 2.0);
    await _overlay.updateConfig(
      settings,
      fontFamily: font?.family ?? '',
      fontPath: font?.path ?? '',
      fontWeight: fontWeight,
      fontSizeRate: fontSizeRate,
    );
  }

  /// 播放页「歌词设置」里的字体（族名 + 文件路径）。
  ///
  /// Windows / Android 的系统悬浮窗是原生渲染，需要把字体文件交给原生侧；
  /// Flutter 回退层直接用族名即可。找不到对应字体文件时退回按族名使用。
  Future<({String family, String path})?> _lyricFont() async {
    final selected = _ref.read(lyricFontFamilyProvider).trim();
    if (selected.isEmpty || selected == 'system') return null;

    for (final bundled in AppFontManager.bundledFonts) {
      if (bundled.family != selected) continue;
      return (family: bundled.family, path: bundled.asset);
    }
    // pubspec 里内置的「阿里巴巴圆润体」不在 AppFontManager 的字体列表里。
    if (selected == 'lyricfont') {
      return (family: selected, path: 'assets/fonts/lyricfont.ttf');
    }

    final fonts = _ref.read(appFontsProvider);
    for (final font in fonts) {
      if (font.family != selected) continue;
      try {
        final path = await AppFontManager.instance.pathOf(font);
        return (family: font.family, path: path);
      } catch (e) {
        debugPrint('[DesktopLyricSync] 读取歌词字体路径失败: $e');
        break;
      }
    }
    // 平台自带字体（如苹方）：只传族名，让原生侧按系统字体查找。
    return (family: selected, path: '');
  }

  /// 歌词字体 / 字重 / 字号变化：把新样式下发给原生悬浮窗。
  void onLyricStyleChanged() {
    if (!state.usingNativeOverlay) return;
    unawaited(_pushConfig(_ref.read(desktopLyricSettingsProvider)));
  }

  /// 切歌:重置已下发的歌词,并为新歌主动拉取歌词。
  ///
  /// [syncVisibility] 里的 [pushLyric] 会先把悬浮窗清空,新歌词加载完成后
  /// 再由 [onLyricChanged] 下发,因此不会残留上一首的歌词。
  void onSongChanged() {
    _lastLyricSignature = null;
    _lastPushedIndex = -1;
    _lastObservedPositionMs = -1;
    ensureLyricsLoaded();
    unawaited(syncVisibility());
  }

  /// 歌词加载完成:整批下发。
  void onLyricChanged() {
    ensureLyricsLoaded();
    unawaited(pushLyric(force: true));
  }

  /// 桌面歌词开启时,即使歌词页没打开也要为当前歌曲拉取歌词。
  ///
  /// [lyricControllerProvider] 内部已经监听切歌,但它只在被监听时才存在;
  /// 这里保证「开启桌面歌词」这一路径一定会触发一次加载。
  ///
  /// 另外做了两件后台场景下必需的兜底:
  /// 1. 以「加载是否已结束」而不是「lines 是否非空」判定完成,否则无歌词的
  ///    歌曲会被每秒重复请求;
  /// 2. 同一首歌卡在 `isLoading` 超过 [_lyricStuckTimeout] 就强制重跑一次
  ///    —— 退到后台后网络/DB 请求可能长时间不返回,导致歌词一直空白。
  void ensureLyricsLoaded() {
    if (!_ref.read(desktopLyricSettingsProvider).enable) return;
    final song = _ref.read(playbackControllerProvider).currentSong;
    if (song == null) return;
    final lyric = _ref.read(lyricControllerProvider);

    if (lyric.isLoading) {
      // 正在加载：如果加载的就是当前这首歌，等它完成即可；如果还在加载的是
      // 上一首歌（旧请求还没结束），必须为新歌重新发起一次加载，否则新歌的
      // 歌词永远等不到。
      if (_lyricLoadingSongId == song.id) {
        final since = _lyricLoadingSince;
        if (since == null ||
            DateTime.now().difference(since) < _lyricStuckTimeout) {
          return;
        }
        // 卡住了:强制重跑一次。
      }
    } else if (lyric.currentSongId == song.id) {
      // 这首歌已经加载过(有歌词 / 无歌词 / 解析失败都算完成)。
      _lyricLoadingSongId = null;
      _lyricLoadingSince = null;
      return;
    }

    _lyricLoadingSongId = song.id;
    _lyricLoadingSince = DateTime.now();
    unawaited(_ref.read(lyricControllerProvider.notifier).loadLyrics(song));
  }

  /// 歌词加载的卡死阈值。
  static const Duration _lyricStuckTimeout = Duration(seconds: 20);

  /// 显示 / 隐藏请求的序号：快速暂停→播放时，较早的异步结果不能覆盖
  /// 较新的状态。
  int _visibilityRequest = 0;

  Future<void> syncVisibility() async {
    final request = ++_visibilityRequest;
    final settings = _ref.read(desktopLyricSettingsProvider);
    final playback = _ref.read(playbackControllerProvider);
    final song = playback.currentSong;

    // 暂停 / 停止时隐藏桌面歌词，恢复播放时再显示。
    if (!settings.enable || song == null || !playback.isPlaying) {
      await _overlay.hide();
      if (!mounted || request != _visibilityRequest) return;
      state = state.copyWith(overlayShowing: false);
      _lastLyricSignature = null;
      _stopSyncTimer();
      return;
    }

    ensureLyricsLoaded();

    if (!_overlay.supported || !state.permissionGranted) {
      _stopSyncTimer();
      if (mounted) state = state.copyWith(overlayShowing: false);
      return;
    }

    // 先下发样式与位置再显示：原生侧第一次显示就能直接按保存的位置摆放，
    // 不会先出现在默认位置再跳到保存的位置（Windows 上尤其明显）。
    await _pushConfig(settings);

    final shown = await _overlay.show();
    if (!mounted || request != _visibilityRequest) return;
    state = state.copyWith(overlayShowing: shown);
    if (!shown) {
      _stopSyncTimer();
      return;
    }

    await pushLyric(force: true); // 交给原生侧自行推进,并定期校准。
    await pushPlayState(force: true);
    _startSyncTimer();
  }

  /// 下发一次进度锚点。
  ///
  /// 非强制调用时,若观测到的进度与上次相同**且播放状态也没变**就跳过:这说明
  /// Dart 侧进度已停止更新(应用退到后台被节流),此时应让原生侧的时钟继续自行
  /// 推进。播放 / 暂停状态变化时必须下发,否则原生侧会一直按「正在播放」推进
  /// 歌词行,暂停后歌词仍在滚动。
  ///
  /// 这里传的是 isAudible 而不是 isPlaying:缓冲时 playing 仍为 true,但播放器
  /// 没出声、进度停在原地;若照常下发「正在播放」,原生侧会用自己的时钟继续
  /// 推进歌词(拖动进度条缓冲时歌词仍在走)。
  Future<void> pushPlayState({bool force = false}) async {
    if (!state.usingNativeOverlay) return;
    final playback = _ref.read(playbackControllerProvider);
    final positionMs = playback.position.inMilliseconds;
    final isPlaying = playback.isAudible;
    if (!force &&
        positionMs == _lastObservedPositionMs &&
        isPlaying == _lastPushedPlaying) {
      return;
    }
    _lastObservedPositionMs = positionMs;
    _lastPushedPlaying = isPlaying;
    await _overlay.setPlayState(positionMs: positionMs, isPlaying: isPlaying);
  }

  void _startSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_periodicSync());
    });
  }

  void _stopSyncTimer() {
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  /// 周期同步:确保「歌词已加载 + 已下发 + 进度已锚定」。
  ///
  /// 退到后台后,Riverpod 的监听回调、网络请求都可能延迟甚至丢失。只靠事件
  /// 驱动会出现「切歌后悬浮窗一直空白,回到应用才补上」。这里做一次兜底轮询:
  /// 每秒检查一次,内容有变化才真正下发([pushLyric] 内部按签名去重)。
  Future<void> _periodicSync() async {
    if (!mounted || !state.usingNativeOverlay) return;
    if (_syncing) return;
    _syncing = true;
    try {
      ensureLyricsLoaded();
      await pushLyric();
      await pushPlayState();
    } finally {
      _syncing = false;
    }
  }

  /// 把当前歌词整批下发给原生悬浮窗。
  ///
  /// 两个必须处理的点:
  /// 1. 切歌后新歌词还没加载出来时,**必须先下发空歌词把悬浮窗清空**,
  ///    否则会残留上一首的歌词(加载最长 10 秒,期间一直显示错的歌词)。
  /// 2. 新歌没有歌词 / 加载失败时,lines 为空,同样要下发(用占位行)而不是
  ///    直接 return —— 之前 `if (lines.isEmpty) return;` 会让上一首的歌词
  ///    永久残留在悬浮窗上。
  Future<void> pushLyric({bool force = false}) async {
    if (!state.usingNativeOverlay) return;
    final song = _ref.read(playbackControllerProvider).currentSong;
    if (song == null) return;

    final lines = _ref.read(desktopLyricLinesProvider);
    final ready = areLyricsReadyForSong(
      song,
      _ref.read(lyricControllerProvider),
    );

    // 只有内容真的变了才下发（含"是否就绪"这一维度）。
    final signature =
        '${song.id}#${ready ? 1 : 0}#${lines.length}#'
        '${identityHashCode(lines)}';
    if (!force && signature == _lastLyricSignature) return;
    _lastLyricSignature = signature;

    final payload = switch ((ready, lines.isEmpty)) {
      // 加载中 / 歌词不属于当前歌：显示歌名占位，既不残留上一首的歌词，
      // 也不会让悬浮窗整块空白（退到后台加载较慢时尤其明显）。
      (false, _) => <LyricLine>[_placeholderLine(_loadingText(song))],
      // 已就绪但这首歌没有歌词
      (true, true) => <LyricLine>[_placeholderLine(tr('暂无歌词'))],
      (true, false) => lines,
    };

    _lastPushedIndex = _ref.read(desktopLyricActiveIndexProvider);
    await _overlay.updateLyric(
      lines: payload,
      activeIndex: _lastPushedIndex < 0 ? 0 : _lastPushedIndex,
      showTranslation: _ref.read(lyricShowTranslationProvider),
      showRoman: _ref.read(lyricShowRomanProvider),
    );
    // 歌词换了之后必须重新锚定,否则原生会用上一首歌的进度去推算行号。
    _lastObservedPositionMs = -1;
    await pushPlayState(force: true);
  }

  /// 加载中显示的占位文本：优先歌名，让悬浮窗立刻有内容而不是空白。
  String _loadingText(Song song) {
    final title = song.title.trim();
    return title.isEmpty ? tr('歌词加载中') : title;
  }

  static LyricLine _placeholderLine(String text) => LyricLine(
    startTimeMs: 0,
    endTimeMs: 0,
    words: [LyricWord(word: text, startTimeMs: 0, endTimeMs: 0)],
  );

  void _onPositionChanged(double x, double y) {
    updateDesktopLyricSettings(
      _ref.read,
      (s) => s.copyWith(positionX: x, positionY: y),
    );
  }
}

final desktopLyricSyncProvider =
    StateNotifierProvider<DesktopLyricSyncController, DesktopLyricStatus>((
      ref,
    ) {
      final controller = DesktopLyricSyncController(ref);

      ref.listen(desktopLyricSettingsProvider, (previous, next) {
        controller.onSettingsChanged(previous, next);
      });
      ref.listen(playbackControllerProvider.select((s) => s.currentSong), (
        _,
        __,
      ) {
        controller.onSongChanged();
      });
      ref.listen(desktopLyricLinesProvider, (_, __) {
        controller.onLyricChanged();
      });
      // 这里**不再**周期性把行号推给原生:原生侧有自己的时钟并按“到下一行的
      // 精确剩余时间”调度。Dart 侧的 position 天生滞后(200ms 粒度 + 通道延迟),
      // 与原生时钟同时驱动会互相打架:滞后的行号把原生往回拽,表现为歌词
      // 慢半拍 + 往回跳一下的闪动。行号只在 updateLyric 时作为初值下发。
      // 播放/暂停切换：暂停或停止时隐藏桌面歌词，恢复播放时重新显示。
      ref.listen(playbackControllerProvider.select((s) => s.isPlaying), (
        _,
        __,
      ) {
        unawaited(controller.syncVisibility());
      });
      // 缓冲开始 / 结束：原生侧要马上停 / 恢复自己的时钟，不能等下一秒的
      // 周期同步，否则缓冲期间歌词已经往前走了。缓冲不改变显示与否，
      // 所以只下发播放状态，不走 syncVisibility。
      ref.listen(playbackControllerProvider.select((s) => s.isBuffering), (
        _,
        __,
      ) {
        unawaited(controller.pushPlayState());
      });
      // 播放页「歌词设置」里的字体 / 字重 / 字号：原生悬浮窗需要立即刷新，
      // 否则只有等下次切歌或修改桌面歌词设置才会生效。
      ref.listen(lyricFontFamilyProvider, (_, __) {
        controller.onLyricStyleChanged();
      });
      ref.listen(lyricFontWeightProvider, (_, __) {
        controller.onLyricStyleChanged();
      });
      ref.listen(lyricFontRateProvider, (_, __) {
        controller.onLyricStyleChanged();
      });

      ref.onDispose(controller.dispose);
      return controller;
    });
