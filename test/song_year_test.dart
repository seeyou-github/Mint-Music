import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/plugin/domain/song_year.dart';

void main() {
  group('插件年份字段解析', () {
    test('四位年份直接返回', () {
      expect(parseSongYear(2020), 2020);
      expect(parseSongYear('2020'), 2020);
      expect(parseSongYear(' 1998 '), 1998);
    });

    test('日期字符串取前四位', () {
      expect(parseSongYear('2020-05-01'), 2020);
      expect(parseSongYear('1999/12/31'), 1999);
    });

    test('秒级时间戳（QQ pubtime）', () {
      // 1059580800 → 2003-07-31（UTC+8 是 2003-07-31）
      expect(parseSongYear(1059580800), 2003);
    });

    test('毫秒级时间戳（网易 publishTime）', () {
      expect(parseSongYear(1733068800000), 2024);
    });

    test('取不到时返回 null', () {
      expect(parseSongYear(null), isNull);
      expect(parseSongYear(0), isNull);
      expect(parseSongYear(''), isNull);
      expect(parseSongYear('未知'), isNull);
      expect(parseSongYear(-1), isNull);
    });
  });

  group('发行日期文本取年份', () {
    test('常见格式', () {
      expect(yearFromDateText('2020-05-01'), 2020);
      expect(yearFromDateText('2020/5/1'), 2020);
      expect(yearFromDateText('2020年5月'), 2020);
      expect(yearFromDateText('2020'), 2020);
    });

    test('空 / 无年份', () {
      expect(yearFromDateText(null), isNull);
      expect(yearFromDateText(''), isNull);
      expect(yearFromDateText('未知日期'), isNull);
    });
  });
}
