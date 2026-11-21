import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/application/lyric_resolver.dart';
import 'package:mintmusic/features/player/domain/models/lyric_line.dart';

/// 播放详情页的取词竞速：谁先给出逐字歌词就用谁。
void main() {
  const yrc = '[0,1000](0,200,0)你(200,300,0)好';
  const plain = '[00:00.00]你好';
  const tlyric = '[00:00.00]Hello';
  const ttml =
      '<tt><body><div><p begin="00:00.000" end="00:01.000">'
      '<span begin="00:00.000" end="00:00.300">你</span>'
      '<span begin="00:00.300" end="00:01.000">好</span></p></div></body></tt>';

  test('音源先返回逐字歌词：立刻用它，不再等词库', () async {
    final ttmlRequest = Completer<String?>();
    final onlineRequest = Completer<LyricResult?>();

    final future = raceLyricSources(
      ttmlRequest: ttmlRequest.future,
      onlineRequest: onlineRequest.future,
    );

    onlineRequest.complete(const LyricResult(crlyric: yrc, tlyric: tlyric));
    final raw = await future;

    expect(raw.online?.crlyric, yrc);
    expect(raw.ttmlText, isNull, reason: '音源已经是逐字，词库结果直接丢弃');
    expect(ttmlRequest.isCompleted, isFalse, reason: '不应该等词库');

    ttmlRequest.complete(null);
  });

  test('音源先返回整行歌词：等词库，词库逐字时用词库 + 音源翻译', () async {
    final ttmlRequest = Completer<String?>();
    final onlineRequest = Completer<LyricResult?>();

    var finished = false;
    final future = raceLyricSources(
      ttmlRequest: ttmlRequest.future,
      onlineRequest: onlineRequest.future,
    )..then((_) => finished = true);

    onlineRequest.complete(const LyricResult(lrc: plain, tlyric: tlyric));
    await pumpEventQueue();
    expect(finished, isFalse, reason: '音源只有整行，要继续等词库');

    ttmlRequest.complete(ttml);
    final raw = await future;

    expect(raw.ttmlText, ttml);
    expect(raw.online?.tlyric, tlyric, reason: '翻译仍然来自音源');
  });

  test('词库先返回：等音源把翻译带回来', () async {
    final ttmlRequest = Completer<String?>();
    final onlineRequest = Completer<LyricResult?>();

    var finished = false;
    final future = raceLyricSources(
      ttmlRequest: ttmlRequest.future,
      onlineRequest: onlineRequest.future,
    )..then((_) => finished = true);

    ttmlRequest.complete(ttml);
    await pumpEventQueue();
    expect(finished, isFalse, reason: '词库只有原文，要等音源拿翻译');

    onlineRequest.complete(const LyricResult(lrc: plain, tlyric: tlyric));
    final raw = await future;

    expect(raw.ttmlText, ttml);
    expect(raw.online?.tlyric, tlyric);
  });

  test('两边都没有结果：返回空，交给调用方提示', () async {
    final raw = await raceLyricSources(
      ttmlRequest: Future<String?>.value(null),
      onlineRequest: Future<LyricResult?>.value(null),
    );

    expect(raw.ttmlText, isNull);
    expect(raw.online, isNull);
  });

  test('词库超时（抛错）时用音源整行', () async {
    final raw = await raceLyricSources(
      ttmlRequest: Future<String?>.error(TimeoutException('ttml')),
      onlineRequest: Future<LyricResult?>.value(
        const LyricResult(lrc: plain, tlyric: tlyric),
      ),
    );

    expect(raw.ttmlText, isNull);
    expect(raw.online?.lrc, plain);
  });

  group('音源逐字先到时的迟到 TTML', () {
    test('词库后到会交给回调（翻译只在 TTML 里）', () async {
      final ttmlRequest = Completer<String?>();
      final onlineRequest = Completer<LyricResult?>();
      final late = <String>[];

      final future = raceLyricSources(
        ttmlRequest: ttmlRequest.future,
        onlineRequest: onlineRequest.future,
        onTtmlLate: (text) => late.add(text),
      );

      onlineRequest.complete(const LyricResult(crlyric: yrc));
      final raw = await future;
      expect(raw.online?.crlyric, yrc);
      expect(late, isEmpty, reason: '词库还没回来，回调不该提前触发');

      ttmlRequest.complete(ttml);
      await pumpEventQueue();

      expect(late, [ttml], reason: '迟到的 TTML 要交回去补翻译');
    });

    test('词库没有内容 / 报错时不回调', () async {
      final late = <String>[];

      await raceLyricSources(
        ttmlRequest: Future<String?>.value(null),
        onlineRequest: Future<LyricResult?>.value(
          const LyricResult(crlyric: yrc),
        ),
        onTtmlLate: (text) => late.add(text),
      );
      await pumpEventQueue();
      expect(late, isEmpty);

      await raceLyricSources(
        ttmlRequest: Future<String?>.error(TimeoutException('ttml')),
        onlineRequest: Future<LyricResult?>.value(
          const LyricResult(crlyric: yrc),
        ),
        onTtmlLate: (text) => late.add(text),
      );
      await pumpEventQueue();
      expect(late, isEmpty);
    });

    test('音源是整行、最终用了词库时不触发（TTML 已经参与选词）', () async {
      final late = <String>[];

      final raw = await raceLyricSources(
        ttmlRequest: Future<String?>.value(ttml),
        onlineRequest: Future<LyricResult?>.value(
          const LyricResult(lrc: plain, tlyric: tlyric),
        ),
        onTtmlLate: (text) => late.add(text),
      );
      await pumpEventQueue();

      expect(raw.ttmlText, ttml);
      expect(late, isEmpty);
    });
  });

  group('waitTtmlForTranslation（搜索预览 / 编辑标签页）', () {
    test('音源逐字但没有翻译：继续等词库的翻译轨', () async {
      final ttmlRequest = Completer<String?>();
      final onlineRequest = Completer<LyricResult?>();

      var finished = false;
      final future = raceLyricSources(
        ttmlRequest: ttmlRequest.future,
        onlineRequest: onlineRequest.future,
        waitTtmlForTranslation: true,
      )..then((_) => finished = true);

      onlineRequest.complete(const LyricResult(crlyric: yrc));
      await pumpEventQueue();
      expect(finished, isFalse, reason: 'QQ 这类没有翻译，要等词库');

      ttmlRequest.complete(ttml);
      final raw = await future;
      expect(raw.ttmlText, ttml);
      expect(raw.online?.crlyric, yrc);
    });

    test('音源逐字且自带翻译：立刻返回，不等词库', () async {
      final ttmlRequest = Completer<String?>();

      final raw = await raceLyricSources(
        ttmlRequest: ttmlRequest.future,
        onlineRequest: Future<LyricResult?>.value(
          const LyricResult(crlyric: yrc, tlyric: tlyric),
        ),
        waitTtmlForTranslation: true,
      );

      expect(raw.online?.tlyric, tlyric);
      expect(ttmlRequest.isCompleted, isFalse, reason: '有翻译就别等词库');
      ttmlRequest.complete(null);
    });
  });
}
