// 用 Dio 测试 nmobi.kuwo.cn 接口
// 运行: dart run test/test_nmobi.dart
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';

void main() async {
  final dio = Dio(
    BaseOptions(
      followRedirects: true,
      maxRedirects: 5,
      receiveDataWhenStatusError: true,
      validateStatus: (_) => true,
    ),
  );

  // 测试真实歌曲 rid
  final tests = [
    {'rid': '228908', 'name': '晴天-周杰伦', 'br': '320kmp3'},
    {'rid': '440616', 'name': '兰亭序-周杰伦', 'br': '320kmp3'},
    {'rid': '112660998', 'name': '无效rid', 'br': '320kmp3'},
  ];

  for (final t in tests) {
    final rid = t['rid']!;
    final name = t['name']!;
    final br = t['br']!;

    final user =
        (10000000 + (DateTime.now().millisecondsSinceEpoch % 100000000))
            .toString();
    final loginUid =
        (10000000 + (DateTime.now().millisecondsSinceEpoch % 100000000 + 1000))
            .toString();

    final url =
        'https://nmobi.kuwo.cn/mobi.s'
        '?f=web'
        '&source=kwplayercar_ar_6.0.0.9_B_jiakong_vh.apk'
        '&type=convert_url_with_sign'
        '&rid=$rid'
        '&br=$br'
        '&user=$user'
        '&loginUid=$loginUid';

    print('\n=== $name (rid=$rid) ===');
    print('URL: $url');

    try {
      final response = await dio.get(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Linux; Android 6.0; Nexus 5 Build/MRA58N) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Mobile Safari/537.36',
            'Referer': 'http://www.kuwo.cn/',
          },
        ),
      );

      print('Status: ${response.statusCode}');

      final bodyBytes = response.data is List<int>
          ? List<int>.from(response.data as List<int>)
          : utf8.encode(response.data?.toString() ?? '');
      final bodyText = utf8.decode(bodyBytes, allowMalformed: true);

      print(
        'Body (first 500): ${bodyText.substring(0, bodyText.length.clamp(0, 500))}',
      );

      try {
        final parsed = jsonDecode(bodyText);
        print('Code: ${parsed['code']}, Msg: ${parsed['msg']}');
        if (parsed['data'] != null) {
          final data = parsed['data'];
          print(
            'Data.url: ${data['url']?.toString()?.substring(0, (data['url']?.toString()?.length ?? 0).clamp(0, 150))}',
          );
          print('Data.sig: ${data['sig']?.toString()?.substring(0, 60)}');
        }
      } catch (e) {
        print('JSON parse error: $e');
      }
    } catch (e) {
      print('Dio error: $e');
    }
  }
}
