import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/song.dart';
import 'package:mintmusic/features/plugin/application/music_source_manager.dart';
import 'package:mintmusic/features/plugin/data/plugin_host.dart';
import 'package:mintmusic/features/plugin/data/plugin_service.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';

const _url = 'https://audio.example/song';
const _song = Song(
  id: '1',
  title: 'song',
  artist: 'artist',
  album: 'album',
  duration: 180,
  source: 'wy',
);
const _aliases = [
  ['low', '64k'],
  ['standard', '128k'],
  ['high', 'hq', '320k'],
  ['super', 'lossless', 'flac'],
];

class _Service implements PluginService {
  _Service(this.hosts);

  final List<_Host> hosts;

  @override
  List<PluginHost> get enabledPlugins => hosts;

  @override
  String? getPluginIdForHost(PluginHost host) => (host as _Host).id;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Host implements PluginHost {
  _Host(
    this.id, {
    this.isDataSource = false,
    this.qualities = const ['128k', '320k', 'flac'],
    this.platform = 'wy',
    this.platformName = '网易云音乐',
    this.canSearch = true,
    this.searchReply =
        '{"list":[{"id":"matched","songmid":"matched","name":"song",'
        '"singer":"artist"}],"isEnd":true}',
  });

  final String id;
  final String platform;
  final String platformName;
  final List<String> qualities;
  final bool canSearch;
  String searchReply;
  final calls = <(String, String, String)>[];
  final infos = <MusicInfoForPlugin>[];
  final searchCalls = <String>[];
  PluginMusicUrlResult Function(String, MusicInfoForPlugin) reply =
      (quality, info) => PluginMusicUrlResult(url: _url, quality: quality);

  @override
  final bool isDataSource;

  @override
  PluginMetadata? get pluginInfo => null;

  @override
  List<PluginSourceInfo> get sources => [
    PluginSourceInfo(id: platform, name: platformName, qualities: qualities),
  ];

  @override
  Map<String, List<String>> get sourceActions => {
    platform: canSearch ? ['musicUrl', 'musicSearch'] : ['musicUrl'],
  };

  @override
  Future<PluginMusicUrlResult> getMusicUrlResult(
    String source,
    MusicInfoForPlugin musicInfo,
    String quality, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((source, musicInfo.id, quality));
    infos.add(musicInfo);
    return reply(quality, musicInfo);
  }

  @override
  bool supportsSearch(String sourceId) => canSearch;

  @override
  Future<String?> search(
    String source,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    searchCalls.add(source);
    return searchReply;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('all failing hosts are requested once at the chosen quality', () async {
    final hosts = [
      _Host('throw')..reply = (_, _) => throw Exception('offline'),
      _Host('empty')..reply = (_, _) => const PluginMusicUrlResult(url: ''),
      _Host('invalid')
        ..reply = (_, _) => const PluginMusicUrlResult(url: 'file:///song.mp3'),
      _Host('unsupported', qualities: ['128k'])
        ..reply = (_, _) => throw Exception('Unsupported quality: flac24bit'),
    ];
    final errors = <String>[];
    final results = await MusicSourceManager(_Service(hosts))
        .getMusicUrlResultCandidates(
          _song,
          quality: 'flac24bit',
          onResolveError: errors.add,
        );
    expect(results, isEmpty);
    for (final host in hosts) {
      expect(host.calls, [('wy', '1', 'flac24bit')]);
    }
    expect(errors, ['offline', 'Unsupported quality: flac24bit']);
  });

  test(
    'advertised qualities do not substitute an unsupported request',
    () async {
      final host = _Host('standard-only', qualities: ['128k'])
        ..reply = (_, _) => throw Exception('Unsupported quality: hires');
      final result = await MusicSourceManager(
        _Service([host]),
      ).getMusicUrlResult(_song, quality: 'hires');
      expect(result, isNull);
      expect(host.calls, [('wy', '1', 'hires')]);
    },
  );

  for (final group in _aliases) {
    test('${group.first}: accept only equivalent quality labels', () async {
      for (final requested in group) {
        for (final reported in [...group, ' ${group.first.toUpperCase()} ']) {
          final host = _Host('alias')
            ..reply = (_, _) => PluginMusicUrlResult(
              url: _url,
              quality: reported,
              headers: const {'Referer': 'https://example.test'},
            );
          final errors = <String>[];
          final result = await MusicSourceManager(_Service([host]))
              .getMusicUrlResult(
                _song,
                quality: requested,
                onResolveError: errors.add,
              );
          expect(result?.url, _url);
          expect(result?.quality, requested);
          expect(result?.headers, {'Referer': 'https://example.test'});
          expect(result?.source, 'wy@alias');
          expect(host.calls, [('wy', '1', requested)]);
          expect(errors, isEmpty);
        }
      }
    });
  }

  test(
    'reject every cross-group substitution and report both qualities',
    () async {
      for (final requested in _aliases.map((group) => group.last)) {
        for (final group in _aliases.where(
          (group) => !group.contains(requested),
        )) {
          for (final reported in group) {
            final host = _Host('mismatch')
              ..reply = (_, _) =>
                  PluginMusicUrlResult(url: _url, quality: reported);
            final errors = <String>[];
            final result = await MusicSourceManager(_Service([host]))
                .getMusicUrlResult(
                  _song,
                  quality: requested,
                  onResolveError: errors.add,
                );
            expect(result, isNull);
            expect(errors.single, contains('音质不匹配'));
            expect(errors.single, contains(requested));
            expect(errors.single, contains(reported));
            expect(host.calls, [('wy', '1', requested)]);
          }
        }
      }
    },
  );

  for (final quality in [
    '192k',
    'flac24bit',
    'hires',
    'atmos',
    'master',
    '24bit',
    'mp3',
    'custom',
  ]) {
    test('$quality is not interchangeable with standard or lossless', () async {
      final host = _Host('exact')
        ..reply = (_, _) => PluginMusicUrlResult(url: _url, quality: quality);
      final manager = MusicSourceManager(_Service([host]));
      expect(
        (await manager.getMusicUrlResult(_song, quality: quality))?.quality,
        quality,
      );
      for (final requested in ['128k', '320k', 'flac']) {
        expect(
          await manager.getMusicUrlResult(_song, quality: requested),
          isNull,
        );
      }
      host.reply = (_, _) =>
          const PluginMusicUrlResult(url: _url, quality: 'flac');
      expect(await manager.getMusicUrlResult(_song, quality: quality), isNull);
      expect(host.calls.map((call) => call.$3), [
        quality,
        '128k',
        '320k',
        'flac',
        quality,
      ]);
    });
  }

  test(
    'unreported quality retains request without claiming URL verification',
    () async {
      for (final label in ['', '  ']) {
        final host = _Host('unreported')
          ..reply = (_, _) => PluginMusicUrlResult(url: _url, quality: label);
        final result = await MusicSourceManager(
          _Service([host]),
        ).resolveSingleSongUrl(_song, quality: 'hires');
        expect(result.sourceUrl, _url);
        expect(result.sourceQuality, 'hires');
        expect(host.calls, [('wy', '1', 'hires')]);
      }
    },
  );

  test(
    'same-quality candidates retain exclusions, deduplication and source identity',
    () async {
      final hosts = [
        _Host('excluded')
          ..reply = (_, _) =>
              const PluginMusicUrlResult(url: 'https://audio.example/excluded'),
        _Host('first')
          ..reply = (_, _) => const PluginMusicUrlResult(
            url: '  $_url  ',
            quality: 'hq',
            headers: {'User-Agent': 'first-agent'},
          ),
        _Host('duplicate'),
        _Host('last')
          ..reply = (_, _) => const PluginMusicUrlResult(
            url: 'https://audio.example/other',
            quality: 'high',
          ),
      ];
      final results = await MusicSourceManager(_Service(hosts))
          .getMusicUrlResultCandidates(
            _song,
            excludedUrls: {'https://audio.example/excluded'},
            pluginHosts: hosts,
          );
      expect(results.map((result) => result.url), [
        _url,
        'https://audio.example/other',
      ]);
      expect(results.map((result) => result.quality), ['320k', '320k']);
      expect(results.map((result) => result.source), ['wy@first', 'wy@last']);
      expect(results.first.headers, {'User-Agent': 'first-agent'});
      for (final host in hosts) {
        expect(host.calls, [('wy', '1', '320k')]);
      }
    },
  );

  test(
    'reject mismatched host while preserving the next same-quality candidate',
    () async {
      final mismatch = _Host('mismatch')
        ..reply = (_, _) =>
            const PluginMusicUrlResult(url: _url, quality: '128k');
      final same = _Host('same');
      final result = await MusicSourceManager(
        _Service([mismatch, same]),
      ).getMusicUrlResult(_song);
      expect(result?.source, 'wy@same');
      expect(result?.quality, '320k');
      expect(mismatch.calls, [('wy', '1', '320k')]);
      expect(same.calls, [('wy', '1', '320k')]);
    },
  );

  const dataPlatforms = [
    (base: 'wy', name: '网易云音乐', id: '10086'),
    (base: 'kg', name: '酷狗音乐', id: 'KGHASH0123'),
    (base: 'kw', name: '酷我音乐', id: '654321'),
    (base: 'tx', name: 'QQ音乐', id: 'TXMID0001'),
  ];

  Song dataSong(
    ({String base, String name, String id}) platform, {
    required bool boundInSource,
  }) => Song(
    id: platform.id,
    title: 'song',
    artist: 'artist',
    album: 'album',
    duration: 180,
    source: boundInSource ? '${platform.base}@data' : platform.base,
    preferredSource: boundInSource ? null : '${platform.base}@data',
  );

  MusicSourceManager delegatedManager({
    required _Host data,
    required _Host playback,
    _Host? other,
    required String base,
  }) =>
      MusicSourceManager(_Service([data, if (other != null) other, playback]))
        ..setDataSourcePlaybackSources({'data': '$base@playback'});

  for (final platform in dataPlatforms) {
    for (final boundInSource in [true, false]) {
      test(
        '${platform.base} same-platform '
        '${boundInSource ? 'source-bound' : 'preferred-bound'} song skips search',
        () async {
          final data = _Host(
            'data',
            isDataSource: true,
            platform: platform.base,
            platformName: platform.name,
          );
          final playback =
              _Host(
                  'playback',
                  platform: platform.base,
                  platformName: platform.name,
                )
                ..reply = (quality, _) => PluginMusicUrlResult(
                  url: _url,
                  quality: quality,
                  headers: const {'Referer': 'playback'},
                );
          final other = _Host(
            'other',
            platform: platform.base,
            platformName: platform.name,
          );
          final manager = delegatedManager(
            data: data,
            playback: playback,
            other: other,
            base: platform.base,
          );
          final song = dataSong(platform, boundInSource: boundInSource);

          final result = await manager.getMusicUrlResult(
            song,
            quality: 'hires',
          );

          expect(result?.url, _url);
          expect(result?.quality, 'hires');
          expect(result?.headers, {'Referer': 'playback'});
          expect(result?.source, isNull);
          expect(playback.calls, [(platform.base, platform.id, 'hires')]);
          expect(playback.searchCalls, isEmpty);
          expect(playback.infos.single.source, platform.base);
          expect(playback.infos.single.songmid, platform.id);
          expect(data.calls, isEmpty);
          expect(other.calls, isEmpty);
          expect(
            song.source,
            boundInSource ? '${platform.base}@data' : platform.base,
          );
          expect(
            song.preferredSource,
            boundInSource ? null : '${platform.base}@data',
          );
        },
      );
    }
  }

  for (final platform in dataPlatforms) {
    for (final failure in ['throws', 'empty', 'invalid']) {
      test('${platform.base} same-platform $failure reports the real failure '
          'without searching', () async {
        final data = _Host(
          'data',
          isDataSource: true,
          platform: platform.base,
          platformName: platform.name,
        );
        final playback = _Host(
          'playback',
          platform: platform.base,
          platformName: platform.name,
        );
        if (failure == 'throws') {
          playback.reply = (_, _) =>
              throw Exception('${platform.base} endpoint unavailable');
        } else if (failure == 'empty') {
          playback.reply = (_, _) => const PluginMusicUrlResult(url: '');
        } else {
          playback.reply = (_, _) =>
              const PluginMusicUrlResult(url: 'file:///blocked.mp3');
        }
        final manager = delegatedManager(
          data: data,
          playback: playback,
          base: platform.base,
        );
        final errors = <String>[];

        await expectLater(
          manager.getMusicUrlResult(
            dataSong(platform, boundInSource: true),
            quality: '320k',
            onResolveError: errors.add,
          ),
          throwsA(isA<DataSourcePlaybackException>()),
        );

        expect(playback.calls, [(platform.base, platform.id, '320k')]);
        expect(playback.searchCalls, isEmpty);
        expect(errors.single, isNot(contains('没有搜到')));
        if (failure == 'throws') {
          expect(
            errors.single,
            contains('${platform.base} endpoint unavailable'),
          );
        }
      });
    }
  }

  for (final platform in dataPlatforms) {
    test('${platform.base} same-platform mismatch fails without searching or '
        'downgrading', () async {
      final data = _Host(
        'data',
        isDataSource: true,
        platform: platform.base,
        platformName: platform.name,
      );
      final playback =
          _Host(
              'playback',
              platform: platform.base,
              platformName: platform.name,
            )
            ..reply = (_, _) =>
                const PluginMusicUrlResult(url: _url, quality: '128k');
      final manager = delegatedManager(
        data: data,
        playback: playback,
        base: platform.base,
      );
      final errors = <String>[];

      await expectLater(
        manager.getMusicUrlResult(
          dataSong(platform, boundInSource: true),
          quality: 'hires',
          onResolveError: errors.add,
        ),
        throwsA(isA<DataSourcePlaybackException>()),
      );

      expect(errors.single, contains('音质不匹配'));
      expect(playback.calls, [(platform.base, platform.id, 'hires')]);
      expect(playback.searchCalls, isEmpty);
      expect(data.calls, isEmpty);
    });
  }

  test('same-platform Kuwo prompt URL is rejected without searching', () async {
    final data = _Host(
      'data',
      isDataSource: true,
      platform: 'kw',
      platformName: '酷我音乐',
    );
    final playback = _Host('playback', platform: 'kw', platformName: '酷我音乐')
      ..reply = (quality, _) => PluginMusicUrlResult(
        url: 'https://nmobi.kuwo.cn/kw_promo/trial.mp3',
        quality: quality,
      );
    final manager = delegatedManager(
      data: data,
      playback: playback,
      base: 'kw',
    );

    await expectLater(
      manager.getMusicUrlResult(
        dataSong(dataPlatforms[2], boundInSource: true),
        quality: '320k',
      ),
      throwsA(isA<DataSourcePlaybackException>()),
    );
    expect(playback.calls, [('kw', '654321', '320k')]);
    expect(playback.searchCalls, isEmpty);
  });

  test('same-platform song without an identifier does not search', () async {
    final data = _Host(
      'data',
      isDataSource: true,
      platform: 'kg',
      platformName: '酷狗音乐',
    );
    final playback = _Host('playback', platform: 'kg', platformName: '酷狗音乐');
    final manager = delegatedManager(
      data: data,
      playback: playback,
      base: 'kg',
    );
    final errors = <String>[];
    final song = dataSong(
      dataPlatforms[1],
      boundInSource: true,
    ).copyWith(id: '');

    await expectLater(
      manager.getMusicUrlResult(
        song,
        quality: '320k',
        onResolveError: errors.add,
      ),
      throwsA(isA<DataSourcePlaybackException>()),
    );
    expect(errors.single, contains('标识'));
    expect(playback.calls, isEmpty);
    expect(playback.searchCalls, isEmpty);
  });

  test(
    'data-source kg identifiers and raw metadata reach the playback host',
    () async {
      final data =
          _Host(
              'data',
              isDataSource: true,
              platform: 'kg',
              platformName: '酷狗音乐',
            )
            ..searchReply = jsonEncode({
              'list': [
                {
                  'id': 'KGHASH',
                  'songId': 'KGHASH',
                  'songmid': 'KGHASH',
                  'albumId': 'ALB1',
                  'name': 'song',
                  'singer': 'artist',
                  'albumName': 'album',
                  'artwork': 'https://img.example/cover.jpg',
                  'duration': 201,
                  'types': ['128k', '320k'],
                  '_types': {
                    '320k': {'hash': 'HASH320'},
                  },
                  'typeUrl': {'320k': 'https://audio.example/320'},
                },
              ],
              'isEnd': true,
            });
      final playback = _Host(
        'playback',
        platform: 'kg',
        platformName: '酷狗音乐',
        canSearch: false,
      );
      final manager = delegatedManager(
        data: data,
        playback: playback,
        base: 'kg',
      );

      final songs = await manager.search('song artist', sourceId: 'kg@data');
      expect(songs, hasLength(1));
      final song = songs.single;
      expect(song.source, 'kg');
      expect(song.preferredSource, 'kg@data');
      expect(song.id, 'KGHASH');

      final result = await manager.getMusicUrlResult(song, quality: '320k');

      expect(result?.url, _url);
      expect(result?.source, isNull);
      expect(playback.calls, [('kg', 'KGHASH', '320k')]);
      expect(playback.searchCalls, isEmpty);
      expect(data.calls, isEmpty);
      final info = playback.infos.single;
      expect(info.source, 'kg');
      expect(info.songmid, 'KGHASH');
      expect(info.hash, 'KGHASH');
      expect(info.songId, 'KGHASH');
      expect(info.albumId, 'ALB1');
      expect(info.types, ['128k', '320k']);
      expect(info.typeMap, {
        '320k': {'hash': 'HASH320'},
      });
      expect(info.typeUrl, {'320k': 'https://audio.example/320'});
      expect(song.source, 'kg');
      expect(song.preferredSource, 'kg@data');
    },
  );

  for (final platform in dataPlatforms) {
    test(
      '${platform.base} identifiers survive data-source search and delegation',
      () async {
        final data =
            _Host(
                'data',
                isDataSource: true,
                platform: platform.base,
                platformName: platform.name,
              )
              ..searchReply = jsonEncode({
                'list': [
                  {
                    'id': platform.id,
                    'songId': platform.base == 'tx' ? 987654 : platform.id,
                    'songmid': platform.id,
                    'name': 'song',
                    'singer': 'artist',
                    'albumName': 'album',
                    if (platform.base == 'tx') 'interval': 205,
                  },
                ],
                'isEnd': true,
              });
        final playback = _Host(
          'playback',
          platform: platform.base,
          platformName: platform.name,
          canSearch: false,
        );
        final manager = delegatedManager(
          data: data,
          playback: playback,
          base: platform.base,
        );

        final songs = await manager.search(
          'song artist',
          sourceId: '${platform.base}@data',
        );
        final song = songs.single;
        expect(song.source, platform.base);
        expect(song.preferredSource, '${platform.base}@data');
        expect(song.id, platform.id);

        await manager.getMusicUrlResult(song, quality: '320k');

        expect(playback.searchCalls, isEmpty);
        final info = playback.infos.single;
        expect(info.source, platform.base);
        expect(info.songmid, platform.id);
        expect(info.songId, platform.base == 'tx' ? 987654 : platform.id);
        expect(info.hash, platform.id);
        expect(info.name, 'song');
        expect(info.singer, 'artist');
        if (platform.base == 'tx') expect(info.interval, '205');
      },
    );
  }

  test('legacy source prefixes are stripped before delegation', () async {
    final data = _Host(
      'data',
      isDataSource: true,
      platform: 'kg',
      platformName: '酷狗音乐',
    );
    final playback = _Host(
      'playback',
      platform: 'kg',
      platformName: '酷狗音乐',
      canSearch: false,
    );
    final manager = delegatedManager(
      data: data,
      playback: playback,
      base: 'kg',
    );
    final song = Song(
      id: 'kg_HASH9',
      title: 'song',
      artist: 'artist',
      album: 'album',
      duration: 180,
      source: 'kg@data',
      preferredSource: 'kg@data',
    );

    await manager.getMusicUrlResult(song, quality: '320k');

    final info = playback.infos.single;
    expect(info.source, 'kg');
    expect(info.songmid, 'HASH9');
    expect(info.hash, 'HASH9');
  });

  test('QQ numeric lyric id is kept as songId without lx metadata', () async {
    final data = _Host(
      'data',
      isDataSource: true,
      platform: 'tx',
      platformName: 'QQ音乐',
    );
    final playback = _Host(
      'playback',
      platform: 'tx',
      platformName: 'QQ音乐',
      canSearch: false,
    );
    final manager = delegatedManager(
      data: data,
      playback: playback,
      base: 'tx',
    );
    final song = Song(
      id: 'TXMID',
      title: 'song',
      artist: 'artist',
      album: 'album',
      duration: 180,
      lyricUrl: '987654',
      source: 'tx@data',
      preferredSource: 'tx@data',
    );

    await manager.getMusicUrlResult(song, quality: '320k');

    final info = playback.infos.single;
    expect(info.source, 'tx');
    expect(info.songmid, 'TXMID');
    expect(info.songId, '987654');
  });

  test(
    'cross-platform data-source song still searches the playback source',
    () async {
      final data = _Host(
        'data',
        isDataSource: true,
        platform: 'tx',
        platformName: 'QQ音乐',
      );
      final playback = _Host('playback', platform: 'wy', platformName: '网易云音乐')
        ..reply = (quality, _) => PluginMusicUrlResult(
          url: _url,
          quality: quality,
          headers: const {'Referer': 'playback'},
        );
      final manager = delegatedManager(
        data: data,
        playback: playback,
        base: 'wy',
      );
      final song = Song(
        id: 'TXMID',
        title: 'song',
        artist: 'artist',
        album: 'album',
        duration: 180,
        source: 'tx@data',
        preferredSource: 'tx@data',
      );

      final result = await manager.getMusicUrlResult(song, quality: 'hires');

      expect(result?.url, _url);
      expect(result?.quality, 'hires');
      expect(result?.source, isNull);
      expect(playback.searchCalls, ['wy']);
      expect(playback.calls, [('wy', 'matched', 'hires')]);
      expect(data.calls, isEmpty);
    },
  );

  test(
    'cross-platform data-source song reports a missing search match',
    () async {
      final data = _Host(
        'data',
        isDataSource: true,
        platform: 'tx',
        platformName: 'QQ音乐',
      );
      final playback = _Host(
        'playback',
        platform: 'wy',
        platformName: '网易云音乐',
        searchReply: '{"list":[],"isEnd":true}',
      );
      final manager = delegatedManager(
        data: data,
        playback: playback,
        base: 'wy',
      );
      final errors = <String>[];
      final song = Song(
        id: 'TXMID',
        title: 'song',
        artist: 'artist',
        album: 'album',
        duration: 180,
        source: 'tx@data',
      );

      await expectLater(
        manager.getMusicUrlResult(
          song,
          quality: 'hires',
          onResolveError: errors.add,
        ),
        throwsA(isA<DataSourcePlaybackException>()),
      );

      expect(errors.single, contains('没有搜到'));
      expect(playback.searchCalls, isNotEmpty);
      expect(playback.calls, isEmpty);
    },
  );

  test('cross-platform resolution failure keeps the playback error', () async {
    final data = _Host(
      'data',
      isDataSource: true,
      platform: 'tx',
      platformName: 'QQ音乐',
    );
    final playback = _Host('playback', platform: 'wy', platformName: '网易云音乐')
      ..reply = (_, _) => throw Exception('wy endpoint offline');
    final manager = delegatedManager(
      data: data,
      playback: playback,
      base: 'wy',
    );
    final errors = <String>[];
    final song = Song(
      id: 'TXMID',
      title: 'song',
      artist: 'artist',
      album: 'album',
      duration: 180,
      source: 'tx@data',
    );

    await expectLater(
      manager.getMusicUrlResult(
        song,
        quality: 'hires',
        onResolveError: errors.add,
      ),
      throwsA(isA<DataSourcePlaybackException>()),
    );

    expect(errors.single, contains('wy endpoint offline'));
    expect(playback.calls, [('wy', 'matched', 'hires')]);
  });
}
