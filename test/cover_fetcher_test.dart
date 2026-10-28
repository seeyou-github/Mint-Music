import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/shared/services/cover_fetcher.dart';

/// 歌曲列表加载封面时会用到候选地址 / 请求头，这里锁住这两条规则：
/// 网易封面强制 https 并换缩略图，酷我降级成 http，普通 CDN 重试时补 UA。
void main() {
  group('CoverFetcher.candidatesOf', () {
    test('网易封面改成 https 并换指定尺寸的缩略图', () {
      final candidates = CoverFetcher.candidatesOf(
        'http://p1.music.126.net/abc.jpg?param=130y130',
        netEaseThumbSize: 200,
      );
      expect(candidates.first, 'https://p1.music.126.net/abc.jpg?param=200y200');
      expect(candidates, contains('https://p1.music.126.net/abc.jpg?param=130y130'));
    });

    test('默认缩略图尺寸仍是 400（写标签等需要清晰的场景）', () {
      final candidates = CoverFetcher.candidatesOf(
        'https://p1.music.126.net/abc.jpg',
      );
      expect(candidates.first, 'https://p1.music.126.net/abc.jpg?param=400y400');
    });

    test('酷我封面不支持 https，降级成 http', () {
      final candidates = CoverFetcher.candidatesOf(
        'https://img1.kwcdn.kuwo.cn/a.jpg',
      );
      expect(candidates.first, 'http://img1.kwcdn.kuwo.cn/a.jpg');
      expect(candidates, contains('https://img1.kwcdn.kuwo.cn/a.jpg'));
    });

    test('本地路径 / 空地址没有候选地址', () {
      expect(CoverFetcher.candidatesOf('/data/cover.jpg'), isEmpty);
      expect(CoverFetcher.candidatesOf(''), isEmpty);
    });
  });

  group('CoverFetcher.headersFor', () {
    test('普通 CDN 第一次不带额外请求头，重试时补 User-Agent', () {
      expect(CoverFetcher.headersFor('https://y.gtimg.cn/a.jpg'), isNull);
      expect(
        CoverFetcher.headersFor('https://y.gtimg.cn/a.jpg', retry: true),
        contains('User-Agent'),
      );
    });

    test('网易封面始终带 Referer 和 User-Agent', () {
      for (final retry in [false, true]) {
        final headers = CoverFetcher.headersFor(
          'https://p1.music.126.net/a.jpg',
          retry: retry,
        );
        expect(headers, containsPair('Referer', 'https://music.163.com'));
        expect(headers, contains('User-Agent'));
      }
    });
  });
}
