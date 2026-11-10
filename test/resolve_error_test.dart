import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/plugin/domain/quality_ladder.dart';

void main() {
  group('isQualityUnavailableError', () {
    test('只认「服务器明确说这个音质没有」的文案', () {
      for (final message in [
        '不支持 flac 音质',
        '该音质不存在',
        '音质不可用',
        '没有该音质',
        '酷我音乐：《好心分手》没有 128k mp3 版本，所有接口最高只给到 100k aac。'
            '请把音质切到对应档位，或换用其它音源。',
        'HD 渠道(备用主机)：只给了 100k aac',
        'unsupported quality',
        'quality is not supported',
        'no such quality',
      ]) {
        expect(isQualityUnavailableError(message), isTrue, reason: message);
      }
    });

    test('服务器 / 鉴权 / 网络错误都不算音质缺失', () {
      for (final message in [
        '',
        'code 401：该音源仅对认证用户开放（未授权不可访问）',
        'code 403：无权限',
        'code 429：请求过于频繁',
        'code 503：服务暂时不可用',
        'HTTP 500',
        'TimeoutError: request timeout',
        'RequestError: connection reset',
      ]) {
        expect(isQualityUnavailableError(message), isFalse, reason: message);
      }
    });
  });

  group('qualityFallbackFromError', () {
    test('从「只给到 100k aac」里取实际能给的档位', () {
      const message =
          '酷我音乐：《好心分手》没有 128k mp3 版本，所有接口最高只给到 100k aac。'
          '请把音质切到对应档位，或换用其它音源。 · HD 渠道(备用主机)：只给了 100k aac';
      expect(qualityFallbackFromError(message, '128k'), '100k');
      // 请求 lossless 时也不能把「没有」里的 128k 当成可用档位。
      expect(qualityFallbackFromError(message, 'flac'), '100k');
    });

    test('只接受比请求更低的档位', () {
      expect(qualityFallbackFromError('没有 320k 音质，最高 128k', '128k'), isNull);
      expect(qualityFallbackFromError('音质不存在，请切换到 320k', '128k'), isNull);
      expect(qualityFallbackFromError('没有该音质', '128k'), isNull);
    });

    test('非音质错误不会被当成降级目标', () {
      expect(
        qualityFallbackFromError('code 503：服务暂时不可用（192k 地址过期）', '320k'),
        isNull,
      );
    });

    test('不会把 48kHz 采样率当成 48k 音质', () {
      expect(qualityFallbackFromError('音质不存在 48kHz', '128k'), isNull);
    });
  });

  group('isQualityDowngrade', () {
    test('非标准比特率也能比较高低', () {
      expect(isQualityDowngrade('128k', '100k'), isTrue);
      expect(isQualityDowngrade('100k', '128k'), isFalse);
      expect(isQualityDowngrade('flac', '100k'), isTrue);
      expect(isQualityDowngrade('128k', 'flac'), isFalse);
    });
  });

  group('isNonRetryableResolveError', () {
    test('鉴权 / 限流 / 4xx 不再重试', () {
      for (final message in [
        'code 401：未授权',
        'code 403：无权限',
        'code 429：请求过于频繁',
        'HTTP 400',
        'HTTP 404',
        '该音源仅对认证用户开放',
        '请求过于频繁',
        '不支持 flac 音质',
      ]) {
        expect(isNonRetryableResolveError(message), isTrue, reason: message);
      }
    });

    test('5xx / 408 / 超时 / 空错误仍允许同音质再试一次', () {
      for (final message in [
        '',
        'code 500',
        'code 503：服务暂时不可用',
        'code 408：请求超时',
        'TimeoutError: request timeout',
        'RequestError: connection reset',
      ]) {
        expect(isNonRetryableResolveError(message), isFalse, reason: message);
      }
    });
  });
}
