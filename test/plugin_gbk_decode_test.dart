import 'package:flutter_test/flutter_test.dart';
import 'package:gbk_codec/gbk_codec.dart';
import 'package:mintmusic/features/plugin/platform/js_engine_service.dart';

void main() {
  group('decodeGbkBytes', () {
    test('按双字节解码 GBK 汉字（酷我逐字歌词）', () {
      // 酷我 newlyric 返回的 GBK 字节：稻香 + LRCX 标签
      final bytes = <int>[
        0xB5, 0xBE, 0xCF, 0xE3, // 稻香
        0x3C, 0x35, 0x32, 0x2C, 0x2D, 0x35, 0x32, 0x3E, // <52,-52>
      ];

      expect(JsEngineService.decodeGbkBytes(bytes), '稻香<52,-52>');
      // gbk_codec 的 gbk.decode 是逐字节查表，双字节汉字会原样漏出字节码，
      // 这里顺带固定住「不能用 gbk.decode」这个结论。
      expect(gbk_bytes.decode(bytes), '稻香<52,-52>');
      expect(gbk.decode(bytes), isNot('稻香<52,-52>'));
    });
  });
}
