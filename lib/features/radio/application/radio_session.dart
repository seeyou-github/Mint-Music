import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../blacklist/application/blacklist_providers.dart';
import '../../discover/application/discover_providers.dart';
import '../../library/domain/models/recently_played.dart';
import '../../player/application/playback_context.dart';
import '../../player/application/playback_controller.dart';
import '../../player/domain/models/playback_state.dart';
import '../../plugin/application/plugin_providers.dart';
import '../domain/models/radio_station.dart';
import 'radio_engine.dart';

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
    this.playlistId,
    this.playlistSource,
    this.songIds = const {},
  });

  final String stationId;
  final String name;
  final String cover;

  /// 是否是内置的「随机电台」（没有配置，完全随机）。
  final bool isRandom;

  /// 随机电台开始时快照的音源：主页切音源不影响电台。
  final String randomSourceId;

  /// 电台自定义的配置（随机电台为 null）。
  final RadioStation? station;

  /// 当前用来补歌的歌单（随机电台会一直从同一个歌单续歌）。
  final String? playlistId;
  final String? playlistSource;

  /// 本次电台加进队列的歌曲 id：当前播放的歌不在里面说明用户已经切走，
  /// 电台模式自动结束。
  final Set<String> songIds;

  RadioSession copyWith({
    String? name,
    String? cover,
    String? playlistId,
    String? playlistSource,
    Set<String>? songIds,
  }) {
    return RadioSession(
      stationId: stationId,
      name: name ?? this.name,
      cover: cover ?? this.cover,
      isRandom: isRandom,
      station: station,
      randomSourceId: randomSourceId,
      playlistId: playlistId ?? this.playlistId,
      playlistSource: playlistSource ?? this.playlistSource,
      songIds: songIds ?? this.songIds,
    );
  }
}

final radioSessionProvider =
    NotifierProvider<RadioSessionController, RadioSession?>(
      RadioSessionController.new,
    );

/// 电台的播放会话：负责起播、补歌、退出。
///
/// 补歌规则：队列里未播放的歌少于 10 首时，再随机补至少 20 首（受黑名单过滤）。
class RadioSessionController extends Notifier<RadioSession?> {
  /// 未播放歌曲少于此数时补歌。
  static const int refillThreshold = 10;

  /// 每次补歌的条数。
  static const int refillCount = 20;

  bool _refilling = false;

  @override
  RadioSession? build() {
    ref.listen<PlaybackState>(playbackControllerProvider, (previous, next) {
      _onPlaybackChanged(next);
    });
    return null;
  }

  RadioEngine get _engine => RadioEngine(
    manager: ref.read(musicSourceManagerProvider),
    isBlocked: (song) => ref.read(blacklistProvider).isBlocked(song),
  );

  /// 开始一个自定义电台。
  Future<void> startStation(RadioStation station) async {
    if (!station.hasSongSource) {
      throw const RadioException('这个电台还没有设置歌单分类或搜索关键词');
    }
    final engine = _engine;
    final sources = engine.usableSources(
      configured: station.sourceIds,
      fallback: [ref.read(discoverSourceIdProvider)],
    );
    if (sources.isEmpty) {
      throw const RadioException('电台配置的音源都不可用，请重新选择音源');
    }
    final batch = await engine.nextBatch(
      sourceIds: sources,
      tags: station.tags,
      keywords: station.keywords,
      minCount: refillCount,
    );
    if (batch.isEmpty) {
      throw const RadioException('没有随机到可播放的歌曲，请稍后重试');
    }
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
      playlistId: batch.playlistId,
      playlistSource: batch.playlistSource,
      songIds: batch.songs.map((s) => s.id).toSet(),
    );
    await ref.read(playbackControllerProvider.notifier).setQueue(batch.songs);
  }

  /// 开始内置的「随机电台」。
  ///
  /// [sourceId] 由调用方快照传入（发现页当前音源），之后主页切音源不影响它。
  Future<void> startRandom({required String sourceId}) async {
    final engine = _engine;
    final sources = engine.usableSources(
      configured: const [],
      fallback: [sourceId],
    );
    if (sources.isEmpty) {
      throw const RadioException('当前没有可用的音源，无法开始随机电台');
    }
    final source = sources.first;
    // 先来 3 首开始播放，后面按「未播放 < 10 就补 20 首」继续。
    final batch = await engine.randomSongs(sourceId: source, minCount: 3);
    if (batch.isEmpty) {
      throw const RadioException('随机不到可播放的歌曲，请稍后重试');
    }
    // 记成「电台」来源：最近播放里会显示「电台」标签（点击不跳转）。
    PlaybackContext.instance.set(
      PlaybackSourceType.radio,
      id: RadioStation.randomId,
      name: '随机电台',
    );
    state = RadioSession(
      stationId: RadioStation.randomId,
      name: '随机电台',
      cover: '',
      isRandom: true,
      randomSourceId: source,
      playlistId: batch.playlistId,
      playlistSource: batch.playlistSource,
      songIds: batch.songs.map((s) => s.id).toSet(),
    );
    await ref.read(playbackControllerProvider.notifier).setQueue(batch.songs);
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
    final unplayed = playback.queue.length - index - 1;
    if (unplayed >= refillThreshold || _refilling) return;
    unawaited(_refill(session));
  }

  Future<void> _refill(RadioSession session) async {
    if (_refilling) return;
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
        // 随机电台：每个歌单只取 3 首，取完就换下一个随机歌单，
        // 直到凑够 20 首（引擎内部循环）。
        batch = await engine.randomSongs(
          sourceId: session.randomSourceId,
          minCount: refillCount,
          excludeIds: existing,
        );
      } else {
        final station = session.station;
        if (station == null) return;
        final sources = engine.usableSources(
          configured: station.sourceIds,
          fallback: [ref.read(discoverSourceIdProvider)],
        );
        if (sources.isEmpty) return;
        batch = await engine.nextBatch(
          sourceIds: sources,
          tags: station.tags,
          keywords: station.keywords,
          minCount: refillCount,
          preferPlaylistId: session.playlistId,
          preferPlaylistSource: session.playlistSource,
          excludeIds: existing,
        );
      }
      if (batch.isEmpty) return;

      // 再兜一层去重（防止引擎和队列之间刚好错开）。
      final controller = ref.read(playbackControllerProvider.notifier);
      final fresh = batch.songs
          .where((song) => !existing.contains(song.id))
          .toList(growable: false);
      if (fresh.isEmpty) return;

      final current = state;
      if (current == null || current.stationId != session.stationId) return;
      state = current.copyWith(
        playlistId: batch.playlistId ?? session.playlistId,
        playlistSource: batch.playlistSource ?? session.playlistSource,
        songIds: {...current.songIds, ...fresh.map((s) => s.id)},
      );
      await controller.appendToQueue(fresh);
    } catch (e) {
      // 补歌失败不打断当前播放，下次检查时再试。
      debugPrint('[RadioSession] 补歌失败: $e');
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
