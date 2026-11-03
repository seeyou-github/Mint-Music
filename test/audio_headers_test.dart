import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/platform/audio_handler.dart';

void main() {
  group('audioHeadersForUrl', () {
    test('已知音乐平台 CDN 补 UA 与 Referer', () {
      final netease = MusicAudioHandler.audioHeadersForUrl(
        'https://m7.music.126.net/2026/abc/song.mp3',
      );
      expect(netease['User-Agent'], contains('Mozilla/5.0'));
      expect(netease['Referer'], 'https://music.163.com/');

      final kugou = MusicAudioHandler.audioHeadersForUrl(
        'http://fs.youthandroid2.kugou.com/2026/song.mp3',
      );
      expect(kugou['Referer'], 'https://www.kuwo.cn/');

      final qq = MusicAudioHandler.audioHeadersForUrl(
        'https://isure.stream.qqmusic.qq.com/C400/song.m4a',
      );
      expect(qq['Referer'], 'https://y.qq.com/');
    });

    test('酷我车机 CDN 保持完全无头（否则会给试听提示音）', () {
      final headers = MusicAudioHandler.audioHeadersForUrl(
        'http://car-lv.kuwo.cn/5c24/f000.flac',
      );
      expect(headers, isEmpty);
    });

    test('第三方解析接口不塞浏览器 UA（会被 UA 防盗链 418）', () {
      // 典型：Meting 取地址接口，302 到网易 CDN。宿主以前会强行附加
      // Chrome UA，站点直接 418，播放器报 Failed to open。
      final headers = MusicAudioHandler.audioHeadersForUrl(
        'https://metingapi.nanorocky.top/?server=netease&type=url&id=1',
      );
      expect(headers, isEmpty);
      expect(MusicAudioHandler.needsDefaultHeaders('metingapi.nanorocky.top'),
          isFalse);
    });

    test('插件自带的请求头仍然生效（未知域名也照发）', () {
      final headers = MusicAudioHandler.audioHeadersForUrl(
        'https://cdn.unknown-host.example/song.mp3',
        songHeaders: const {'Referer': 'https://example.com/'},
      );
      expect(headers['Referer'], 'https://example.com/');
      expect(headers.containsKey('User-Agent'), isFalse);
    });
  });
}
