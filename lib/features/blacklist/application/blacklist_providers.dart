import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/domain/models/song.dart';
import '../data/blacklist_store.dart';
import '../domain/models/blacklist_entry.dart';

export '../domain/models/blacklist_data.dart';
export '../data/blacklist_store.dart' show BlacklistStore;
export '../domain/models/blacklist_entry.dart'
    show BlacklistEntry, blacklistNormalize;

final blacklistStoreProvider = Provider<BlacklistStore>((ref) {
  return BlacklistStore();
});

/// 黑名单（歌曲 / 歌手 / 白名单）。
///
/// 状态是同步可读的：界面需要在每一行判断「这首歌是不是被拉黑了」，所以先
/// 返回空数据、启动后异步从设置文件补齐，读完再刷新界面。
final blacklistProvider = NotifierProvider<BlacklistNotifier, BlacklistData>(
  BlacklistNotifier.new,
);

class BlacklistNotifier extends Notifier<BlacklistData> {
  bool _loaded = false;

  @override
  BlacklistData build() {
    if (!_loaded) unawaited(_load());
    return const BlacklistData();
  }

  Future<void> _load() async {
    final data = await ref.read(blacklistStoreProvider).load();
    _loaded = true;
    try {
      state = data;
    } catch (_) {
      // provider 已经销毁（应用退出）：后台读到的数据直接丢弃。
    }
  }

  Future<void> _persist() async {
    await ref.read(blacklistStoreProvider).save(state);
  }

  // ------------------------------------------------------------ 判定

  bool isBlocked(Song song) => state.isBlocked(song);

  bool isSongListed(Song song) => state.isSongListed(song);

  bool isArtistListed(String artist) => state.isArtistListed(artist);

  // ------------------------------------------------------------ 歌曲黑名单

  /// 加入黑名单：同时把这首歌从白名单里拿掉（白名单优先于歌手黑名单）。
  Future<void> addSong(Song song) async {
    final entry = BlacklistEntry(title: song.title, artist: song.artist);
    final songs = [...state.songs];
    if (!songs.any((e) => e.key == entry.key)) songs.add(entry);
    final whitelist = state.whitelist
        .where((e) => e.key != entry.key)
        .toList(growable: false);
    state = state.copyWith(songs: songs, whitelist: whitelist);
    await _persist();
  }

  /// 移出黑名单。
  ///
  /// 只移除「歌曲黑名单」里的这条；如果歌手还在黑名单里，就把这首歌加进
  /// 白名单，让它不再被歌手黑名单拦住（歌手本身仍然保持拉黑）。
  Future<void> removeSong(Song song) async {
    final entry = BlacklistEntry(title: song.title, artist: song.artist);
    final songs = state.songs
        .where((e) => e.key != entry.key)
        .toList(growable: false);
    var whitelist = state.whitelist;
    if (state.isArtistListed(song.artist) &&
        !whitelist.any((e) => e.key == entry.key)) {
      whitelist = [...whitelist, entry];
    }
    state = state.copyWith(songs: songs, whitelist: whitelist);
    await _persist();
  }

  /// 把歌曲加入白名单（只影响歌手黑名单，不影响歌曲黑名单）。
  Future<void> addToWhitelist(Song song) async {
    final entry = BlacklistEntry(title: song.title, artist: song.artist);
    if (state.whitelist.any((e) => e.key == entry.key)) return;
    state = state.copyWith(whitelist: [...state.whitelist, entry]);
    await _persist();
  }

  Future<void> removeFromWhitelist(Song song) async {
    final entry = BlacklistEntry(title: song.title, artist: song.artist);
    final whitelist = state.whitelist
        .where((e) => e.key != entry.key)
        .toList(growable: false);
    if (whitelist.length == state.whitelist.length) return;
    state = state.copyWith(whitelist: whitelist);
    await _persist();
  }

  // ------------------------------------------------------------ 歌手黑名单

  Future<void> addArtist(String artist) async {
    final value = artist.trim();
    if (value.isEmpty) return;
    if (state.artists.any(
      (e) => blacklistNormalize(e) == blacklistNormalize(value),
    )) {
      return;
    }
    state = state.copyWith(artists: [...state.artists, value]);
    await _persist();
  }

  Future<void> removeArtist(String artist) async {
    final target = blacklistNormalize(artist);
    final artists = state.artists
        .where((e) => blacklistNormalize(e) != target)
        .toList(growable: false);
    if (artists.length == state.artists.length) return;
    // 歌手解禁后，为它记录的豁免（白名单）也就没用了。
    final whitelist = state.whitelist
        .where((e) => !blacklistArtistMatches(artist, e.artist))
        .toList(growable: false);
    state = state.copyWith(artists: artists, whitelist: whitelist);
    await _persist();
  }

  // ------------------------------------------------------------ 管理页：增删改

  Future<void> addSongEntry(BlacklistEntry entry) async {
    if (entry.title.trim().isEmpty) return;
    if (state.songs.any((e) => e.key == entry.key)) return;
    state = state.copyWith(songs: [...state.songs, entry]);
    await _persist();
  }

  Future<void> updateSongEntry(BlacklistEntry old, BlacklistEntry next) async {
    if (next.title.trim().isEmpty) return;
    final songs = [
      for (final entry in state.songs)
        if (entry.key == old.key) next else entry,
    ];
    state = state.copyWith(songs: songs);
    await _persist();
  }

  Future<void> removeSongEntry(BlacklistEntry entry) async {
    final songs = state.songs
        .where((e) => e.key != entry.key)
        .toList(growable: false);
    if (songs.length == state.songs.length) return;
    state = state.copyWith(songs: songs);
    await _persist();
  }

  Future<void> updateArtist(String old, String next) async {
    final value = next.trim();
    if (value.isEmpty) return;
    final target = blacklistNormalize(old);
    final artists = [
      for (final artist in state.artists)
        if (blacklistNormalize(artist) == target) value else artist,
    ];
    state = state.copyWith(artists: artists);
    await _persist();
  }

  Future<void> removeWhitelistEntry(BlacklistEntry entry) async {
    final whitelist = state.whitelist
        .where((e) => e.key != entry.key)
        .toList(growable: false);
    if (whitelist.length == state.whitelist.length) return;
    state = state.copyWith(whitelist: whitelist);
    await _persist();
  }
}
