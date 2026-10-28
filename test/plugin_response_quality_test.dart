import 'dart:convert';
import 'dart:io';

import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/plugin/data/lx_plugin_converter.dart';
import 'package:mintmusic/features/plugin/data/plugin_host.dart';
import 'package:mintmusic/features/plugin/domain/plugin_types.dart';
import 'package:mintmusic/features/plugin/platform/js_engine_service.dart';

const _url = 'https://audio.example/song';
const _music = MusicInfoForPlugin(
  songId: '1',
  singer: 'artist',
  name: 'song',
  albumName: 'album',
  source: 'wy',
);
const _groups = [
  ['low', '64k'],
  ['standard', '128k'],
  ['high', 'hq', '320k'],
  ['super', 'lossless', 'flac'],
];

class _Case {
  const _Case(
    this.name,
    this.response, {
    this.requested = '320k',
    this.reported,
    this.error,
    this.headers = const {},
  });

  final String name;
  final Object? response;
  final String requested;
  final String? reported;
  final String? error;
  final Map<String, String> headers;
}

Object _wrapJson(Object value, int depth) {
  for (var i = 0; i < depth; i++) {
    value = jsonEncode(value);
  }
  return value;
}

List<_Case> _cases() => [
  for (final format in ['mp3', 'aac', 'ogg', 'audio/mpeg', 'flac', '128k'])
    _Case('format-only $format inherits request', {
      'url': _url,
      'format': format,
    }),
  for (final type in ['mp3', 'aac', 'ogg', 'audio/mpeg', 'wav', 'audio'])
    _Case('codec type $type is not a bitrate', {'url': _url, 'type': type}),
  const _Case('hires quality with flac container', {
    'url': _url,
    'quality': 'hires',
    'format': 'flac',
  }, requested: 'hires'),
  const _Case('hires level with flac container and audio type', {
    'data': {'url': _url, 'level': 'hires', 'format': 'flac', 'type': 'audio'},
  }, requested: 'hires'),
  for (final label in [null, '', '  '])
    _Case('empty labels $label inherit request', {
      'url': _url,
      'quality': label,
      'level': label,
      'type': label,
      'format': 'mp3',
    }),
  const _Case('bare URL inherits request', '  $_url  ', requested: 'hires'),
  _Case('multiply encoded bare URL', _wrapJson(_url, 5)),
  const _Case('LX type 128k cannot replace 320k', {
    'url': _url,
    'type': '128k',
  }, error: '音质不匹配：请求 320k，插件返回 128k'),
  const _Case('level conflicts with matching quality', {
    'url': _url,
    'quality': '320k',
    'level': '128k',
  }, error: '音质不匹配：请求 320k，插件返回 128k'),
  const _Case('type conflicts with matching quality', {
    'url': _url,
    'quality': '320k',
    'type': '128k',
  }, error: '音质不匹配：请求 320k，插件返回 128k'),
  for (final requested in ['128k', '320k'])
    for (final wrapper in ['data', 'body', 'result', 'response'])
      for (final reverse in [false, true])
        _Case(
          '$requested $wrapper conflict (reverse: $reverse)',
          {
            'url': _url,
            'quality': reverse
                ? (requested == '128k' ? '320k' : '128k')
                : requested,
            wrapper: {
              'quality': reverse
                  ? requested
                  : (requested == '128k' ? '320k' : '128k'),
            },
          },
          requested: requested,
          error:
              '音质不匹配：请求 $requested，插件返回 ${requested == '128k' ? '320k' : '128k'}',
        ),
  _Case('encoded wrapper cannot hide a conflict', {
    'quality': '320k',
    'data': _wrapJson({'url': _url, 'quality': '128k'}, 5),
  }, error: '音质不匹配：请求 320k，插件返回 128k'),
  _Case(
    'encoded root cannot hide a conflict',
    _wrapJson({
      'quality': '320k',
      'body': {'url': _url, 'level': '128k'},
    }, 5),
    error: '音质不匹配：请求 320k，插件返回 128k',
  ),
  const _Case('later response branch cannot be ignored', {
    'data': {'url': _url, 'quality': '320k'},
    'body': {'level': '128k'},
  }, error: '音质不匹配：请求 320k，插件返回 128k'),
  for (final reverse in [false, true])
    _Case(
      'list labels before or after URL (reverse: $reverse)',
      {
        'quality': '320k',
        'data': [
          if (reverse) {'type': '128k'},
          {'url': _url, 'quality': '320k'},
          if (!reverse) {'type': '128k'},
        ],
      },
      error: '音质不匹配：请求 320k，插件返回 128k',
    ),
  _Case('encoded nested list cannot hide a conflict', {
    'quality': '320k',
    'response': _wrapJson([
      _url,
      {
        'body': [
          {'level': '128k'},
        ],
      },
    ], 3),
  }, error: '音质不匹配：请求 320k，插件返回 128k'),
  const _Case('URL object cannot hide a conflict', {
    'quality': '320k',
    'src': {'url': _url, 'type': '128k'},
  }, error: '音质不匹配：请求 320k，插件返回 128k'),
  for (final group in _groups)
    for (final requested in group)
      for (final reported in [...group, ' ${group.first.toUpperCase()} '])
        _Case(
          '$requested accepts equivalent $reported throughout response',
          {
            'quality': reported,
            'data': [
              {'level': group.first},
              {'url': _url, 'type': group.last},
            ],
          },
          requested: requested,
          reported: reported.trim(),
        ),
  for (final label in [
    '192k',
    'flac24bit',
    'hires',
    'atmos',
    'master',
    '24bit',
    'custom',
    'mp3',
  ])
    for (final key in ['quality', 'level'])
      _Case('$key $label is explicit and not 320k', {
        'url': _url,
        key: label,
      }, error: '音质不匹配：请求 320k，插件返回 $label'),
  for (final type in ['192k', 'flac24bit', 'hires', 'atmos', 'master', '24bit'])
    _Case(
      'known type $type is not flac',
      {'url': _url, 'type': type},
      requested: 'flac',
      error: '音质不匹配：请求 flac，插件返回 $type',
    ),
  const _Case(
    'flac24bit and hires are distinct',
    {'url': _url, 'quality': 'flac24bit'},
    requested: 'hires',
    error: '音质不匹配：请求 hires，插件返回 flac24bit',
  ),
  const _Case('unknown explicit label may match exactly', {
    'url': _url,
    'quality': 'custom',
    'level': 'CUSTOM',
  }, requested: 'custom'),
  _Case(
    'headers survive wrappers and lists',
    {
      'quality': '320k',
      'headers': {'Referer': 'outer', 'Omit': null},
      'data': _wrapJson({
        'response': [
          {
            'url': _url,
            'type': 'hq',
            'requestHeaders': {'Referer': 'inner'},
          },
          {
            'httpHeaders': {'Count': 1},
          },
        ],
      }, 2),
    },
    headers: const {'Referer': 'inner', 'Count': '1'},
  ),
  const _Case(
    'header names are not quality metadata',
    {
      'url': _url,
      'headers': {'quality': '128k', 'type': '128k'},
    },
    headers: {'quality': '128k', 'type': '128k'},
  ),
  for (final wrapper in ['src', 'result', 'response'])
    _Case('success message with URL in $wrapper', {
      'message': 'success',
      wrapper: {'url': _url, 'quality': '320k'},
    }),
  const _Case('retain plugin URL error detail', {
    'error': 'HTTP 403: token expired',
  }, error: 'HTTP 403: token expired'),
  const _Case('retain nested URL error detail', {
    'quality': '128k',
    'data': {'message': 'requested quality unavailable'},
  }, error: 'requested quality unavailable'),
  const _Case('invalid URL remains an error', {
    'url': 'file:///song.mp3',
    'quality': '320k',
  }, error: 'invalid musicUrl result'),
];

// Fake only the engine bridge; loadPlugin and getMusicUrlResult are real.
class _Engine implements JsEngineService {
  Object? response;
  final calls = <String>[];
  final timeouts = <Duration>[];

  @override
  bool get isRuntimeHealthy => true;

  @override
  JsEvalResult injectCeruMusicApi() => JsEvalResult('undefined', null);

  @override
  void executePendingJob() {}

  @override
  JsEvalResult evaluate(String code) {
    if (code.contains('Object.keys(module.exports.sources).length')) {
      return JsEvalResult('1', null);
    }
    if (code.contains('typeof __lxInited')) return JsEvalResult('0', null);
    if (code.contains('supportedSearchTypes')) return JsEvalResult('[]', null);
    if (code.startsWith('JSON.stringify((function()')) {
      return JsEvalResult(
        jsonEncode({
          'pluginInfo': {
            'name': 'quality test',
            'version': '1',
            'author': 'test',
          },
          'sources': {
            'wy': {
              'name': '网易云音乐',
              'qualities': ['128k', '320k', 'hires'],
            },
          },
        }),
        null,
      );
    }
    return JsEvalResult('undefined', null);
  }

  @override
  Future<String?> callPluginMethod(
    String methodExpression, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    calls.add(methodExpression);
    timeouts.add(timeout);
    return response is String ? response as String : jsonEncode(response);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _lxSource = '''
lx.on(lx.EVENT_NAMES.request, function(payload) {
  testCalls.push(payload);
  return testResponse;
});
lx.send(lx.EVENT_NAMES.inited, {
  sources: { wy: { actions: ['musicUrl'], qualitys: ['128k', '320k', 'hires'] } }
});
''';

// Execute the actual Dart converter output, not a copied normalization helper.
const _nodeRunner = r'''
const vm = require('node:vm');
let input = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', async () => {
  try {
    const { converted, original, cases } = JSON.parse(input);
    let networkCalls = 0;
    const context = vm.createContext({
      module: { exports: {} }, Buffer, console: { log() {} },
      cerumusic: { request() { networkCalls++; throw new Error('unexpected network request'); } },
      testCalls: [], testResponse: null,
    });
    vm.runInContext(converted, context);
    vm.runInContext(original, context);
    vm.runInContext('__lxFinalizePluginInitialization()', context);
    const results = [];
    for (const item of cases) {
      context.testCalls = [];
      context.testResponse = item.response;
      let result;
      try {
        const value = await context.module.exports.musicUrl('wy', { songId: '1' }, item.requested);
        result = { url: value.data.url, quality: value.data.type, headers: value.headers || {} };
      } catch (error) {
        result = { error: error.message };
      }
      result.calls = context.testCalls.map(call => [call.source, call.action, call.info.type]);
      results.push(result);
    }
    process.stdout.write(JSON.stringify({ results, networkCalls }));
  } catch (error) {
    process.stderr.write(String(error.stack || error));
    process.exitCode = 1;
  }
});
''';

Future<List<dynamic>> _runLxCases(List<_Case> cases) async {
  final process = await Process.start('node', ['-e', _nodeRunner]);
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(
    jsonEncode({
      'converted': LxPluginConverter().convert(_lxSource),
      'original': _lxSource,
      'cases': [
        for (final fixture in cases)
          {'requested': fixture.requested, 'response': fixture.response},
      ],
    }),
  );
  await process.stdin.close();
  expect(await process.exitCode, 0, reason: await errors);
  final result = jsonDecode(await output) as Map<String, dynamic>;
  expect(result['networkCalls'], 0);
  return result['results'] as List<dynamic>;
}

void main() {
  final cases = _cases();
  group('PluginHost response quality', () {
    final engine = _Engine();
    final host = PluginHost(engine);
    setUpAll(() => host.loadPlugin('module.exports = {};'));
    setUp(() {
      engine.calls.clear();
      engine.timeouts.clear();
    });
    for (final fixture in cases) {
      test(fixture.name, () async {
        engine.response = fixture.response;
        final future = host.getMusicUrlResult(
          'wy',
          _music,
          fixture.requested,
          timeout: const Duration(seconds: 7),
        );
        if (fixture.error != null) {
          await expectLater(
            future,
            throwsA(
              predicate<Object>(
                (error) => error.toString().contains(fixture.error!),
              ),
            ),
          );
        } else {
          final result = await future;
          expect(result.url, _url);
          expect(result.quality, fixture.reported ?? fixture.requested);
          expect(result.headers, fixture.headers);
        }
        expect(engine.calls, hasLength(1));
        expect(
          engine.calls.single,
          startsWith("module.exports.musicUrl('wy',"),
        );
        expect(engine.calls.single, endsWith(", '${fixture.requested}')"));
        expect(engine.timeouts, [const Duration(seconds: 7)]);
      });
    }
  });

  group('LX converted musicUrl response quality', () {
    late List<dynamic> results;
    setUpAll(() async {
      results = await _runLxCases(cases);
    });
    for (var i = 0; i < cases.length; i++) {
      final index = i;
      final fixture = cases[index];
      test(fixture.name, () {
        final result = results[index] as Map<String, dynamic>;
        expect(result['calls'], [
          ['wy', 'musicUrl', fixture.requested],
        ]);
        if (fixture.error != null) {
          expect(result['error'], contains(fixture.error));
          expect(result.containsKey('url'), isFalse);
        } else {
          expect(result['error'], isNull);
          expect(result['url'], _url);
          expect(result['quality'], fixture.reported ?? fixture.requested);
          expect(result['headers'], fixture.headers);
        }
      });
    }
  });
}
