import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/shared/widgets/music_cover_image.dart';

/// 回归：部分封面接口返回的不是图片，而是一行纯文本的图片地址。
///
/// 典型例子是酷我 `artistpicserver.kuwo.cn/pic.web`：响应体就是
/// `http://img1.kwcdn.kuwo.cn/star/albumcover/700/xxx.jpg`。
/// 之前直接当图片用，60~70 字节的文本被判定为「响应过小 → 加载失败」，
/// 表现就是播放详情页封面空白。
void main() {
  Uint8List bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

  group('MusicCoverImage.extractImageUrlFromBody', () {
    test('纯文本的图片地址能取出来', () {
      const body = 'http://img1.kwcdn.kuwo.cn/star/albumcover/700/s4s81/95/2497366108.jpg';
      expect(
        MusicCoverImage.extractImageUrlFromBody(bytesOf(body)),
        body,
      );
    });

    test('https 地址同样支持', () {
      const body = 'https://img4.kuwo.cn/star/albumcover/1080/s3s94/93/211513640.jpg';
      expect(
        MusicCoverImage.extractImageUrlFromBody(bytesOf(body)),
        body,
      );
    });

    test('前后有换行 / 空格也能取出来', () {
      const body = '\r\n  http://a.b/c.jpg  \n';
      expect(MusicCoverImage.extractImageUrlFromBody(bytesOf(body)), 'http://a.b/c.jpg');
    });

    test('HTML 错误页不会被当成地址', () {
      const body = '<!DOCTYPE html><html><body>403 Forbidden</body></html>';
      expect(MusicCoverImage.extractImageUrlFromBody(bytesOf(body)), isNull);
    });

    test('JSON 错误响应不会被当成地址', () {
      const body = '{"success":false,"message":"The request is illegal!"}';
      expect(MusicCoverImage.extractImageUrlFromBody(bytesOf(body)), isNull);
    });

    test('二进制图片字节不会被误判', () {
      // JPEG 头 + 随机字节
      final jpeg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 74, 70, 73, 70, 0, 1]);
      expect(MusicCoverImage.extractImageUrlFromBody(jpeg), isNull);
    });

    test('空响应返回 null', () {
      expect(MusicCoverImage.extractImageUrlFromBody(Uint8List(0)), isNull);
    });

    test('过长文本不当作地址', () {
      final body = 'http://a.b/${'x' * 600}.jpg';
      expect(MusicCoverImage.extractImageUrlFromBody(bytesOf(body)), isNull);
    });
  });
}
