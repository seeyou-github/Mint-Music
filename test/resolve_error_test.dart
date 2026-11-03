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
