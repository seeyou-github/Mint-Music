import 'dart:developer' as developer;
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

class MusicApiService {
  final Dio _dio;

  static const int _maxRetries = 2;

  /// 证书异常日志按 host:port 去重：同一个坏音源每次请求都会命中回调，
  /// 逐请求打印只会刷屏，把真正有用的日志淹掉。
  static final Set<String> _badCertLoggedHosts = <String>{};

  /// 去重表上限：接口域名本来就只有几个，这里只是防止被异常域名撑大。
  static const int _maxBadCertLoggedHosts = 64;

  MusicApiService()
    : _dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 15),
          validateStatus: (_) => true,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36',
          },
        ),
      ) {
    _setupBadCertificate();
  }

  MusicApiService._shared(Dio dio) : _dio = dio;

  static MusicApiService? _instance;
  static MusicApiService get shared {
    if (_instance == null) {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 30),
          sendTimeout: const Duration(seconds: 15),
          validateStatus: (_) => true,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36',
          },
        ),
      );
      _instance = MusicApiService._shared(dio);
      _instance!._setupBadCertificate();
    }
    return _instance!;
  }

  Future<Response> _retry(
    Future<Response> Function() request, {
    int retries = _maxRetries,
  }) async {
    for (var i = 0; i <= retries; i++) {
      try {
        return await request();
      } catch (e) {
        if (i == retries) rethrow;
        await Future.delayed(Duration(seconds: 1 << i));
      }
    }
    throw Exception('unreachable');
  }

  void _setupBadCertificate() {
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () =>
          HttpClient()
            ..badCertificateCallback = (cert, host, port) {
              // 音源站点证书链普遍不规范（自签 / 过期 / 域名不符），这里无法
              // 直接拒绝；至少把命中记录打出来，方便排查劫持 / 配错域名的源。
              // 用 developer.log 而不是 debugPrint：debugPrint 在 release 里被
              // 关掉了（见 main.dart），而证书放行是需要留痕的安全事件。
              final key = '$host:$port';
              if (!_badCertLoggedHosts.contains(key) &&
                  _badCertLoggedHosts.length < _maxBadCertLoggedHosts) {
                _badCertLoggedHosts.add(key);
                developer.log(
                  '证书校验失败（已放行）: $host:$port '
                  'subject=${cert.subject} issuer=${cert.issuer}',
                  name: 'MusicApi',
                );
              }
              return true;
            },
    );
  }

  Future<Response> get(String url, {Map<String, dynamic>? headers}) async {
    return _retry(() => _dio.get(url, options: Options(headers: headers)));
  }

  Future<String?> getPlainText(
    String url, {
    Map<String, dynamic>? headers,
  }) async {
    try {
      final response = await _retry(
        () => _dio.get<String>(
          url,
          options: Options(headers: headers, responseType: ResponseType.plain),
        ),
      );
      return response.data;
    } catch (e) {
      return null;
    }
  }

  Future<Uint8List?> getBytes(
    String url, {
    Map<String, dynamic>? headers,
  }) async {
    try {
      final response = await _retry(
        () => _dio.get<List<int>>(
          url,
          options: Options(headers: headers, responseType: ResponseType.bytes),
        ),
      );
      final data = response.data;
      if (data == null) return null;
      return Uint8List.fromList(data);
    } catch (e) {
      return null;
    }
  }

  Future<Response> post(
    String url, {
    Map<String, dynamic>? headers,
    dynamic data,
    Map<String, dynamic>? form,
  }) async {
    final options = Options(headers: headers);
    if (form != null) {
      options.contentType = Headers.formUrlEncodedContentType;
      return _retry(() => _dio.post(url, data: form, options: options));
    }
    return _retry(() => _dio.post(url, data: data, options: options));
  }

  void dispose() {
    if (identical(this, _instance)) return;
    _dio.close();
  }
}
