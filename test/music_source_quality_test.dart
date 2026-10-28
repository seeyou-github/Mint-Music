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
  });

  final String id;
  final List<String> qualities;
  final calls = <(String, String, String)>[];
  final searchCalls = <String>[];
  PluginMusicUrlResult Function(String, MusicInfoForPlugin) reply =
      (quality, info) => PluginMusicUrlResult(url: _url, quality: quality);

  @override
  final bool isDataSource;

  @override
  PluginMetadata? get pluginInfo => null;

  @override
  List<PluginSourceInfo> get sources => [
    PluginSourceInfo(id: 'wy', name: '网易云音乐', qualities: qualities),
  ];

  @override
  Map<String, List<String>> get sourceActions => const {
    'wy': ['musicUrl', 'musicSearch'],
  };

  @override
  Future<PluginMusicUrlResult> getMusicUrlResult(
    String source,
    MusicInfoForPlugin musicInfo,
    String quality, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add((source, musicInfo.id, quality));
    return reply(quality, musicInfo);
  }

  @override
  bool supportsSearch(String sourceId) => true;

  @override
  Future<String?> search(
    String source,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    searchCalls.add(source);
    return jsonEncode({
      'list': [
        {'id': 'matched', 'title': 'song', 'artist': 'artist'},
      ],
      'isEnd': true,
    });
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

  for (final searchRequired in [false, true]) {
    test(
      'data-source delegation retains quality (search: $searchRequired)',
      () async {
        final data = _Host('data', isDataSource: true);
        final playback = _Host('playback')
          ..reply = (quality, info) {
            if (searchRequired && info.id == '1') throw Exception('unknown id');
            return PluginMusicUrlResult(
              url: _url,
              quality: quality,
              headers: const {'Referer': 'playback'},
            );
          };
        final manager = MusicSourceManager(_Service([data, playback]))
          ..setDataSourcePlaybackSources({'data': 'wy@playback'});
        final result = await manager.getMusicUrlResult(
          _song.copyWith(source: 'wy@data', preferredSource: 'wy@data'),
          quality: 'hires',
        );
        expect(result?.url, _url);
        expect(result?.quality, 'hires');
        expect(result?.headers, {'Referer': 'playback'});
        expect(result?.source, isNull);
        expect(data.calls, isEmpty);
        expect(playback.calls, [
          ('wy', '1', 'hires'),
          if (searchRequired) ('wy', 'matched', 'hires'),
        ]);
        expect(playback.searchCalls, searchRequired ? ['wy'] : isEmpty);
      },
    );
  }

  test(
    'data-source direct and searched mismatches fail without downgrading',
    () async {
      final data = _Host('data', isDataSource: true);
      final playback = _Host('playback')
        ..reply = (_, _) =>
            const PluginMusicUrlResult(url: _url, quality: '128k');
      final manager = MusicSourceManager(_Service([data, playback]))
        ..setDataSourcePlaybackSources({'data': 'wy@playback'});
      final errors = <String>[];
      await expectLater(
        manager.getMusicUrlResult(
          _song.copyWith(source: 'wy@data'),
          quality: '320k',
          onResolveError: errors.add,
        ),
        throwsA(isA<DataSourcePlaybackException>()),
      );
      expect(errors.single, contains('音质不匹配'));
      expect(playback.calls, [('wy', '1', '320k'), ('wy', 'matched', '320k')]);
      expect(data.calls, isEmpty);
    },
  );
}
