import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/desktop_lyric_settings.dart';

void main() {
  group('DesktopLyricSettings', () {
    test('默认值', () {
      final s = DesktopLyricSettings.defaults;
      expect(s.enable, false);
      expect(s.fontSize, Platform.isWindows ? 42 : 18);
      expect(s.positionX, 50);
      expect(s.positionY, Platform.isWindows ? 85 : 0);
      expect(s.playedColor, 0xFF07C556);
      expect(s.unplayColor, 0xFFFFFFFF);
      expect(s.shadowColor, 0x99000000);
    });

    test('显示行数与不透明度固定', () {
      expect(DesktopLyricSettings.lineCount, 2);
      expect(DesktopLyricSettings.opacity, 0.8);
    });

    test('encode/decode 往返保持全部字段', () {
      final s = DesktopLyricSettings.defaults.copyWith(
        enable: true,
        fontSize: 24,
        positionX: 12.5,
        positionY: 87.5,
        playedColor: 0xFFEC4899,
        unplayColor: 0xFFBDBDBD,
        shadowColor: 0x66000000,
      );
      expect(DesktopLyricSettings.decode(s.encode()), s);
    });

    test('非法或空数据回退到默认配置', () {
      expect(
        DesktopLyricSettings.decode('not json'),
        DesktopLyricSettings.defaults,
      );
      expect(DesktopLyricSettings.decode(''), DesktopLyricSettings.defaults);
      expect(DesktopLyricSettings.decode(null), DesktopLyricSettings.defaults);
    });

    test('越界数值被夹紧到合法区间', () {
      final s = DesktopLyricSettings.fromJson({
        'v': 3,
        'fontSize': 999,
        'positionX': 150,
        'positionY': -30,
      });
      expect(s.fontSize, 80);
      expect(s.positionX, 100);
      expect(s.positionY, 0);
    });

    test('旧版本配置重新使用新的默认字号与位置', () {
      final s = DesktopLyricSettings.fromJson({
        'v': 2,
        'fontSize': 20,
        'positionX': 10,
        'positionY': 10,
        'playedColor': 0xFFEC4899,
      });
      expect(s.fontSize, DesktopLyricSettings.defaults.fontSize);
      expect(s.positionX, DesktopLyricSettings.defaults.positionX);
      expect(s.positionY, DesktopLyricSettings.defaults.positionY);
      // 颜色保留用户此前的选择。
      expect(s.playedColor, 0xFFEC4899);
    });
  });
}
