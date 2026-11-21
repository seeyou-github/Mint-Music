import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart' as dio;
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/core/backup/sync_timeout.dart';
import 'package:mintmusic/core/backup/webdav_service.dart';

void main() {
  const url = 'https://dav.example.com/back';

  dio.DioException buildDioError(
    dio.DioExceptionType type, {
    int? statusCode,
    Object? cause,
  }) {
    final options = dio.RequestOptions(path: url);
    return dio.DioException(
      type: type,
      requestOptions: options,
      error: cause,
      message: 'boom',
      response: statusCode == null
          ? null
          : dio.Response(
              requestOptions: options,
              statusCode: statusCode,
              statusMessage: 'Forbidden',
            ),
    );
  }

  group('同步超时', () {
    test('首次与重试都是 2 分钟', () {
      expect(SyncAttempt.firstTimeout, const Duration(minutes: 2));
      expect(SyncAttempt.retryTimeout, const Duration(minutes: 2));
      expect(SyncAttempt.timeoutFor(1), const Duration(minutes: 2));
      expect(SyncAttempt.timeoutFor(3), const Duration(minutes: 2));
    });

    test('超时提示带类别、时长、具体步骤和最近一次错误', () async {
      final op = SyncAttempt(
        1,
        overwriteTimeout: const Duration(milliseconds: 1),
      );
      op.attachDiagnosis(() => '当前步骤：上传合并后的歌单；最近错误：服务器返回错误：HTTP 500');
      Object? caught;
      try {
        await op.run(Completer<void>().future);
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<WebDavException>());
      final message = describeWebDavError(caught!);
      expect(message, startsWith('网络超时：'));
      expect(message, contains('0 秒内没有完成'));
      expect(message, contains('当前步骤：上传合并后的歌单'));
      expect(message, contains('HTTP 500'));
      // 超时必须真的掐断底层请求，迟到的响应才不会被合并。
      expect(op.isCancelled, isTrue);
    });
  });

  group('describeWebDavError 分类', () {
    test('连不上服务器 → 网络错误，带 URL 和底层原因', () {
      final message = describeWebDavError(
        buildDioError(
          dio.DioExceptionType.connectionError,
          cause: const SocketException(
            'Failed host lookup',
            osError: OSError('Node name unknown', 11001),
          ),
        ),
      );
      expect(message, startsWith('网络错误：'));
      expect(message, contains(url));
      expect(message, contains('Failed host lookup'));
    });

    test('连接 / 发送 / 接收 / 解析超时 → 网络超时', () {
      for (final type in [
        dio.DioExceptionType.connectionTimeout,
        dio.DioExceptionType.sendTimeout,
        dio.DioExceptionType.receiveTimeout,
        dio.DioExceptionType.transformTimeout,
      ]) {
        expect(
          describeWebDavError(buildDioError(type)),
          startsWith('网络超时：'),
          reason: '$type',
        );
      }
    });

    test('服务器返回 401 → 明确写出 HTTP 状态码', () {
      final message = describeWebDavError(
        buildDioError(dio.DioExceptionType.badResponse, statusCode: 401),
      );
      expect(message, contains('服务器返回错误：HTTP 401'));
      expect(message, contains('Forbidden'));
      expect(message, contains(url));
    });

    test('响应没有状态码时不显示 HTTP null', () {
      final message = describeWebDavError(
        buildDioError(dio.DioExceptionType.badResponse),
      );
      expect(message, isNot(contains('HTTP null')));
      expect(message, contains('服务器返回了无法识别的响应'));
    });

    test('内部 WebDavException 带状态码时补类别且不重复状态码', () {
      expect(
        describeWebDavError(const WebDavException('路径无写入权限', statusCode: 403)),
        '服务器返回错误：HTTP 403：路径无写入权限',
      );
      final already = describeWebDavError(
        const WebDavException('上传失败：HTTP 403 Forbidden', statusCode: 403),
      );
      expect(already, startsWith('服务器返回错误：'));
      expect(already, contains('上传失败：HTTP 403 Forbidden'));
      expect('HTTP 403'.allMatches(already).length, 1);
    });

    test('裸 SocketException / HandshakeException 也有可读类别', () {
      expect(
        describeWebDavError(const SocketException('Connection refused')),
        startsWith('网络错误：'),
      );
      expect(
        describeWebDavError(
          const HandshakeException('CERTIFICATE_VERIFY_FAILED'),
        ),
        startsWith('证书错误：'),
      );
    });
  });
}
