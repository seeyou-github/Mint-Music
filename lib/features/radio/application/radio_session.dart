import 'dart:async';
import 'dart:math';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/l10n.dart';
import '../../blacklist/application/blacklist_providers.dart';
import '../../library/domain/models/recently_played.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/playback_state.dart';
import '../../plugin/application/plugin_providers.dart';
import 'radio_engine.dart';
import 'radio_providers.dart';

export 'radio_engine.dart' show RadioException;

/// 当前正在播放的电台。
class RadioSession {
  const RadioSession({
    required this.stationId,
    required this.name,
    required this.cover,
    required this.isRandom,
    this.station,
    this.randomSourceId = '',
    this.activeSourceIds = const <String>[],
    this.playlistId,
    this.playlistSource,
    this.usedPlaylistIds = const <String>{},
    this.songPlaylists = const {},
    this.songIds = const {},
  });

  final String stationId;
  final String name;
  final String cover;

  /// 是否是内置的「随机电台」（可以带封面 / 音源 / 分类等可选配置）。
  final bool isRandom;

  /// 随机电台开始时快照的音源：主页切音源不影响电台。
  final String randomSourceId;

  /// 自定义电台本次会话实际使用的音源。
  ///
  /// 电台没配音源时就是全部已安装的数据源（每批随机分类取歌），
  /// 配置了多个音源时就是配置里可用的那些。
  final List<String> activeSourceIds;

  /// 电台的配置（随机电台为它自己的可选配置，没配过就是 null）。
  final RadioStation? station;

  /// 当前用来补歌的歌单（界面上显示「来自哪个歌单」）。
  final String? playlistId;
  final String? playlistSource;

  /// 本次电台已经用过的歌单 id：补歌时全部避开，不再重复使用同一个歌单。
  ///
  /// 只在会话内有效（退出电台即清空），不占存储。
  final Set<String> usedPlaylistIds;

  /// 每首电台歌曲各自来自哪个歌单：播放页「更多」里按歌曲跳转来源。
  final Map<String, RadioPlaylistRef> songPlaylists;

  /// 本次电台加进队列的歌曲 id：当前播放的歌不在里面说明用户已经切走，
  /// 电台模式自动结束。
  final Set<String> songIds;

  RadioSession copyWith({
    String? name,
    String? cover,
    String? playlistId,
    String? playlistSource,
    Set<String>? usedPlaylistIds,
    Map<String, RadioPlaylistRef>? songPlaylists,
    Set<String>? songIds,
  }) {
    return RadioSession(
      stationId: stationId,
      name: name ?? this.name,
      cover: cover ?? this.cover,
      isRandom: isRandom,
      station: station,
      randomSourceId: randomSourceId,
      activeSourceIds: activeSourceIds,
      playlistId: playlistId ?? this.playlistId,
      playlistSource: playlistSource ?? this.playlistSource,
      usedPlaylistIds: usedPlaylistIds ?? this.usedPlaylistIds,
      songPlaylists: songPlaylists ?? this.songPlaylists,
      songIds: songIds ?? this.songIds,
    );
  }
}

final radioSessionProvider =
    NotifierProvider<RadioSessionController, RadioSession?>(
      RadioSessionController.new,
    );

/// 正在准备起播的电台 id（卡片上的转圈动画据此显示），null 表示没有。
///
/// 准备期间用户点其它电台 / 再点同一张卡片 / 点任意歌曲时会立即清空；
/// 已经发出的取歌请求稍后返回也会被丢弃，不会再接管播放队列。
final radioStartingStationProvider = StateProvider<String?>((ref) => null);

/// 电台的播放会话：负责起播、补歌、退出。
///
/// 起播规则：**只随机一个歌单取 3 首**，尽快开始播放；等歌曲真正出声后
/// 再继续补歌，避免起播阶段在多个歌单之间来回请求。
///
/// 补歌规则：队列里未播放的歌少于 10 首时，随机一页歌单，按返回顺序每个
/// 歌单取 3 首，最多补 30 首（受黑名单过滤）。本次电台用过的歌单、已经
/// 入队播过的歌都不会再出现（退出电台即重置）。
class RadioSessionController extends Notifier<RadioSession?> {
  /// 未播放歌曲少于此数时补歌。
  static const int refillThreshold = 10;

  /// 起播第一批的歌曲数：只取一个歌单，尽快出声。
  static const int firstPlayCount = 3;

  /// 每次补歌最多取多少首（一轮一页歌单，每个歌单取 3 首）。
  static const int refillCount = 30;

  /// 每个歌单最多取几首：取多了等于「在听某个歌单」，电台要的是多歌单混合。
  static const int songsPerPlaylist = 3;

  /// 补歌失败后的冷却截止时间。
  ///
  /// 播放状态每 200ms 会更新一次，如果失败后立刻重试会疯狂发请求；
  /// 首次起播只有 3 首，失败时队列一直低于阈值，必须靠这个冷却挡住。
  DateTime? _refillRetryAt;

  static const Duration _refillRetryDelay = Duration(seconds: 5);

  /// 补歌失败提示条的颜色。
  ///
  /// 本文件刻意不依赖 material（只需要 `Color`），而 Notifier 里没有
  /// BuildContext / Theme，取不到 `colorScheme.error`，所以用一个具名常量
  /// 代替散落的字面量；值取 Material red 600，与全局「错误提示」观感一致。
  static const Color _errorMessageColor = Color(0xFFE53935);

  bool _refilling = false;

  /// 补歌连续失败的次数：0 = 正常；1 = 失败过一次（还剩唯一一次重试）；
  /// ≥2 = 已停止本会话的自动补歌（提示用户）。
  ///
  /// 失败后每 200ms 的播放状态 tick 都会检查冷却、一到就重试，如果分类里
  /// 没歌 / 网络持续异常，后台会以 5 秒一轮的节奏反复打请求（每轮最多
  /// 10+ 个），持续整个播放期。限制为「只重试一次」掐断这个重试风暴。
  int _refillFailures = 0;

  /// 本会话的自动补歌是否已被停止（见 [_refillFailures]）。
  bool _refillStopped = false;

  /// 起播请求代号（每次开始 / 取消都会 +1）。
  ///
  /// 取歌是异步的，中途可能已经换了电台或被用户取消；请求返回时用它判断
  /// 自己是否还是「当前这次」：不是就直接丢弃，绝不改播放队列。
  int _startGeneration = 0;

  @override
  RadioSession? build() {
    // 用户点歌 / 播放列表时，播放器通过这个回调通知电台取消准备中的起播。
    ref.read(playbackControllerProvider.notifier).onUserPlaybackRequested =
        cancelPendingStart;
    // 关闭播放（通知栏 ✕ / 媒体键 stop）同样算取消：取歌还在途时若不取消，
    // 返回后会自动开播，覆盖用户刚做的关闭操作。
    ref.read(playbackControllerProvider.notifier).onPlaybackStopped =
        cancelPendingStart;
    ref.listen<PlaybackState>(playbackControllerProvider, (previous, next) {
      _onPlaybackChanged(next);
    });
    return null;
  }

  void _setStartingStation(String? stationId) {
    final notifier = ref.read(radioStartingStationProvider.notifier);
    if (notifier.state != stationId) notifier.state = stationId;
  }

  /// 开始一次新的起播，并让之前还在取歌的请求作废。
  int _beginStart(String stationId) {
    final generation = ++_startGeneration;
    // 新电台重新开始：清掉上一个电台留下的补歌冷却 / 失败计数。
    _refillRetryAt = null;
    _refillFailures = 0;
    _refillStopped = false;
    _setStartingStation(stationId);
    return generation;
  }

  bool _isStartCurrent(int generation) => generation == _startGeneration;

  void _finishStart(int generation) {
    if (!_isStartCurrent(generation)) return;
    _setStartingStation(null);
  }

  /// 立即取消正在准备的电台起播。
  ///
  /// 已经发出的取歌请求没有取消接口，但返回后会发现自己已过期：既不弹错误、
  /// 也不会修改播放队列；卡片上的转圈则马上消失。
  void cancelPendingStart() {
    _startGeneration++;
    _setStartingStation(null);
  }

  RadioEngine get _engine => RadioEngine(
    manager: ref.read(musicSourceManagerProvider),
    isBlocked: (song) => ref.read(blacklistProvider).isBlocked(song),
  );

  /// 把这一批歌用掉的歌单记进「本次已用过」，下一轮补歌不再用。
  static Set<String> _mergeUsed(Set<String> used, RadioBatch batch) {
    if (batch.usedPlaylistIds.isEmpty) return used;
    return {...used, ...batch.usedPlaylistIds};
  }

  /// 电台本次会话实际使用的音源。
  ///
  /// * 配置了音源：只用配置里仍然可用的那些；
  /// * 没配音源：从已安装的**数据源**里随机挑一个（排除 bilibili / LX 等
  ///   插件源），本次会话固定用它；
  /// * 一个可用数据源都没有：直接报错提示用户安装。
  List<String> _stationSources(RadioEngine engine, RadioStation config) {
    if (config.sourceIds.isEmpty) {
      final all = engine.dataSources();
      if (all.isEmpty) {
        throw const RadioException('没有可用的数据源，请先安装并启用数据源插件');
      }
      return [all[Random().nextInt(all.length)]];
    }
    final usable = engine.usableSources(configured: config.sourceIds);
    if (usable.isEmpty) {
      throw const RadioException('电台配置的音源都不可用，请重新选择音源');
    }
    return usable;
  }

  /// 按电台配置（音源 / 歌单分类 / 搜索关键词）取起播的第一批歌。
  Future<RadioBatch> _configuredFirstBatch(
    RadioEngine engine,
    RadioStation config, {
    required List<String> sources,
  }) async {
    final usable = engine.usableSources(configured: sources);
    if (usable.isEmpty) {
      throw const RadioException('电台配置的音源都不可用，请重新选择音源');
    }
    return engine.firstBatch(
      sourceIds: usable,
      tags: config.tags,
      keywords: config.keywords,
      count: firstPlayCount,
    );
  }

  /// 按电台配置（音源 / 歌单分类 / 搜索关键词）补一批歌。
  Future<RadioBatch> _configuredBatch(
    RadioEngine engine,
    RadioStation config, {
    required List<String> sources,
    Set<String> excludePlaylistIds = const <String>{},
    Set<String> excludeIds = const <String>{},
  }) async {
    final usable = engine.usableSources(configured: sources);
    if (usable.isEmpty) {
      throw const RadioException('电台配置的音源都不可用，请重新选择音源');
    }
    return engine.nextBatch(
      sourceIds: usable,
      tags: config.tags,
      keywords: config.keywords,
      maxCount: refillCount,
      songsPerPlaylist: songsPerPlaylist,
      excludePlaylistIds: excludePlaylistIds,
      excludeIds: excludeIds,
    );
  }

  /// 开始一个自定义电台。
  Future<void> startStation(RadioStation station) async {
    final generation = _beginStart(station.id);
    try {
      final engine = _engine;
      final sources = _stationSources(engine, station);
      // 起播只取同一个歌单的 3 首，尽快出声；后续在播放真正开始后补歌。
      final batch = await _configuredFirstBatch(
        engine,
        station,
        sources: sources,
      );
      // 取歌期间用户换了电台 / 点了歌：这次请求作废。
      if (!_isStartCurrent(generation)) return;
      if (batch.isEmpty) {
        throw const RadioException('没有随机到可播放的歌曲，请稍后重试');
      }
      // 歌已经取到，这次起播开始接管播放：清掉「准备中」，后面 setQueue
      // 引起的播放变化不会被当成用户切歌。
      _finishStart(generation);
      // 记成「电台」来源：最近播放里会显示「电台」标签（点击不跳转）。
      PlaybackContext.instance.set(
        PlaybackSourceType.radio,
        id: station.id,
        name: station.name,
      );
      state = RadioSession(
        stationId: station.id,
        name: station.name,
        cover: station.displayCover,
        isRandom: false,
        station: station,
        activeSourceIds: sources,
        playlistId: batch.playlistId,
        playlistSource: batch.playlistSource,
        usedPlaylistIds: _mergeUsed(const {}, batch),
        songPlaylists: batch.songPlaylists,
        songIds: batch.songs.map((s) => s.id).toSet(),
      );
      await ref
          .read(playbackControllerProvider.notifier)
          .setQueue(batch.songs, userInitiated: false);
    } catch (_) {
      // 已被取消的请求：安静返回，不弹「电台启动失败」。
      if (!_isStartCurrent(generation)) return;
      rethrow;
    } finally {
      _finishStart(generation);
    }
  }

  /// 开始内置的「随机电台」。
  ///
  /// [sourceId] 由调用方快照传入（发现页当前音源），之后主页切音源不影响它。
  /// 随机电台可以在设置里带封面 / 音源 / 歌单分类 / 关键词；什么都没配时
  /// 就是完全随机（所有分类里随机）。
  Future<void> startRandom({required String sourceId}) async {
    final generation = _beginStart(RadioStation.randomId);
    try {
      final engine = _engine;
      final config = ref.read(radioProvider).randomStation;
      final configured = config?.sourceIds ?? const <String>[];
      List<String> sources;
      if (configured.isEmpty) {
        // 没配音源：跟随发现页当前音源（前提是它仍是可用数据源，插件源不参与），
        // 否则从已安装的数据源里随机一个。
        final dataSources = engine.dataSources();
        if (dataSources.isEmpty) {
          throw const RadioException('没有可用的数据源，请先安装并启用数据源插件');
        }
        sources = [
          dataSources.contains(sourceId)
              ? sourceId
              : dataSources[Random().nextInt(dataSources.length)],
        ];
      } else {
        sources = engine.usableSources(configured: configured);
      }
      if (sources.isEmpty) {
        throw const RadioException('电台配置的音源都不可用，请重新选择音源');
      }
      // 每次随机挑一个可用音源，多音源时不会总是同一个。
      final source = sources[Random().nextInt(sources.length)];
      // 所有电台起播都只取一个歌单的 3 首，后续在播放真正开始后补歌。
      final batch = config != null && config.hasSongSource
          ? await _configuredFirstBatch(engine, config, sources: sources)
          : await engine.firstRandomSongs(sourceId: source);
      // 取歌期间用户换了电台 / 点了歌：这次请求作废。
      if (!_isStartCurrent(generation)) return;
      if (batch.isEmpty) {
        throw const RadioException('随机不到可播放的歌曲，请稍后重试');
      }
      // 歌已经取到，这次起播开始接管播放：清掉「准备中」，后面 setQueue
      // 引起的播放变化不会被当成用户切歌。
      _finishStart(generation);
      // 记成「电台」来源：最近播放里会显示「电台」标签（点击不跳转）。
      PlaybackContext.instance.set(
        PlaybackSourceType.radio,
        id: RadioStation.randomId,
        name: '随机电台',
      );
      state = RadioSession(
        stationId: RadioStation.randomId,
        name: '随机电台',
        cover: config?.displayCover ?? '',
        isRandom: true,
        station: config,
        randomSourceId: source,
        activeSourceIds: sources,
        playlistId: batch.playlistId,
        playlistSource: batch.playlistSource,
        usedPlaylistIds: _mergeUsed(const {}, batch),
        songPlaylists: batch.songPlaylists,
        songIds: batch.songs.map((s) => s.id).toSet(),
      );
      await ref
          .read(playbackControllerProvider.notifier)
          .setQueue(batch.songs, userInitiated: false);
    } catch (_) {
      // 已被取消的请求：安静返回，不弹「电台启动失败」。
      if (!_isStartCurrent(generation)) return;
      rethrow;
    } finally {
      _finishStart(generation);
    }
  }

  void stop() {
    state = null;
  }

  void _onPlaybackChanged(PlaybackState playback) {
    final session = state;
    if (session == null) return;

    final current = playback.currentSong;
    if (current == null) {
      // 队列被清空 / 停止播放：电台模式结束。
      if (playback.queue.isEmpty) state = null;
      return;
    }
    if (!session.songIds.contains(current.id)) {
      // 用户切到别的歌单 / 搜索播放了，退出电台模式，恢复正常控制。
      state = null;
      return;
    }

    final index = playback.currentIndex;
    if (index < 0 || index >= playback.queue.length) return;
    // 首次起播只有 3 首：必须等歌曲真正出声后再补歌。解析地址 / 缓冲期间
    // 就并发取歌会拖慢起播，也违背「开始播放后再继续添加」。
    if (!playback.isAudible) return;
    if (_refillStopped) return;
    final unplayed = playback.queue.length - index - 1;
    if (unplayed >= refillThreshold || _refilling) return;
    unawaited(_refill(session));
  }

  /// 补歌失败：冷却后由播放状态 tick 触发唯一的一次重试；再失败就停止
  /// 本会话的自动补歌并提示（掐断「每 5 秒一轮请求」的后台重试风暴）。
  void _markRefillFailure({Object? error}) {
    if (error != null) debugPrint('[RadioSession] 补歌失败: $error');
    _refillRetryAt = DateTime.now().add(_refillRetryDelay);
    if (_refillFailures >= 1) {
      _refillStopped = true;
      ref
          .read(playbackControllerProvider.notifier)
          .onMessage
          ?.call(
            tr('电台补歌失败，已停止自动补歌'),
            backgroundColor: _errorMessageColor,
          );
    }
    _refillFailures++;
  }

  Future<void> _refill(RadioSession session) async {
    if (_refillStopped) return;
    if (_refilling) return;
    // 失败后冷却一段时间再试：播放状态每 200ms 更新一次，立即重试会疯狂发请求。
    final retryAt = _refillRetryAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return;
    _refilling = true;
    try {
      final engine = _engine;
      // 队列里已有的歌不再取（同一个歌单反复补时不会一直补到重复项）。
      final existing = ref
          .read(playbackControllerProvider)
          .queue
          .map((s) => s.id)
          .toSet();
      RadioBatch batch;
      if (session.isRandom) {
        final config = session.station;
        // 配了歌单分类 / 关键词：按配置补；没配就是原来的「所有分类里随机」。
        if (config != null && config.hasSongSource) {
          batch = await _configuredBatch(
            engine,
            config,
            sources: session.activeSourceIds.isNotEmpty
                ? session.activeSourceIds
                : [session.randomSourceId],
            excludePlaylistIds: session.usedPlaylistIds,
            excludeIds: existing,
          );
        } else {
          // 随机电台：随机一页歌单，按顺序每个歌单取 3 首；
          // 本次电台用过的歌单、已经播过的歌都不再取。
          batch = await engine.randomSongs(
            sourceId: session.randomSourceId,
            maxCount: refillCount,
            songsPerPlaylist: songsPerPlaylist,
            excludePlaylistIds: session.usedPlaylistIds,
            excludeIds: existing,
          );
        }
      } else {
        final station = session.station;
        if (station == null) return;
        // 随机一页歌单，按顺序每个歌单取 3 首、最多 30 首；
        // 本次电台用过的歌单全部避开，不会一直停留在同一个歌单里。
        batch = await _configuredBatch(
          engine,
          station,
          sources: session.activeSourceIds.isNotEmpty
              ? session.activeSourceIds
              : station.sourceIds,
          excludePlaylistIds: session.usedPlaylistIds,
          excludeIds: existing,
        );
      }
      if (batch.isEmpty) {
        _markRefillFailure();
        return;
      }

      // 再兜一层去重（防止引擎和队列之间刚好错开）。
      final controller = ref.read(playbackControllerProvider.notifier);
      final fresh = batch.songs
          .where((song) => !existing.contains(song.id))
          .toList(growable: false);
      if (fresh.isEmpty) {
        _markRefillFailure();
        return;
      }

      final current = state;
      // 只有同一个会话才追加：换电台 / 用户点歌退出后，旧请求直接丢弃。
      if (current == null || !identical(current, session)) return;
      _refillRetryAt = null;
      _refillFailures = 0;
      state = current.copyWith(
        playlistId: batch.playlistId ?? session.playlistId,
        playlistSource: batch.playlistSource ?? session.playlistSource,
        usedPlaylistIds: _mergeUsed(current.usedPlaylistIds, batch),
        songPlaylists: {...current.songPlaylists, ...batch.songPlaylists},
        songIds: {...current.songIds, ...fresh.map((s) => s.id)},
      );
      await controller.appendToQueue(fresh);
    } catch (e) {
      // 补歌失败不打断当前播放，冷却后重试一次，再失败就停止并提示。
      _markRefillFailure(error: e);
    } finally {
      _refilling = false;
    }
  }
}

/// 电台模式（播放页据此禁用「播放列表 / 上一首 / 循环模式」）。
final radioModeProvider = Provider<bool>((ref) {
  return ref.watch(radioSessionProvider) != null;
});

/// 电台里的歌曲 id 集合（用于列表里标记「来自电台」等扩展场景）。
final radioSongIdsProvider = Provider<Set<String>>((ref) {
  return ref.watch(radioSessionProvider)?.songIds ?? const <String>{};
});
