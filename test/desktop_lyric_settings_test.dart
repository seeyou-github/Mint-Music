import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/features/player/domain/models/desktop_lyric_settings.dart';
import 'package:mintmusic/features/player/platform/desktop_lyric_overlay.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('DesktopLyricSettings', () {
    test('默认值', () {
      final s = DesktopLyricSettings.defaults;
      expect(s.enable, false);
      // Windows 端默认字号已从 42 调整为 50（配置版本 v4）。
      expect(s.fontSize, Platform.isWindows ? 50 : 18);
      expect(s.positionX, 50);
      expect(s.positionY, Platform.isWindows ? 85 : 0);
      expect(s.playedColor, 0xFF07C556);
      expect(s.unplayColor, 0xFFFFFFFF);
      expect(s.shadowColor, 0x99000000);
      // 描边默认关闭，老用户升级后观感不变。
      expect(s.strokeColor, 0x00000000);
      expect(s.strokeWidth, 0.06);
    });

    test('显示行数与不透明度固定', () {
      expect(DesktopLyricSettings.lineCount, 2);
      expect(DesktopLyricSettings.opacity, 1.0);
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
        strokeColor: 0xFF1E3A8A,
        strokeWidth: 0.12,
      );
      expect(DesktopLyricSettings.decode(s.encode()), s);
    });

    test('原生通道保留全部歌词颜色并使用最新设置', () async {
      const channel = MethodChannel('com.mintmusic/desktop_lyric');
      final calls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final settings = [
        DesktopLyricSettings.defaults.copyWith(
          playedColor: 0xFFEC4899,
          unplayColor: 0xFF123456,
          shadowColor: 0x66010203,
          strokeColor: 0xFF1E3A8A,
        ),
        DesktopLyricSettings.defaults.copyWith(
          playedColor: 0x80ABCDEF,
          unplayColor: 0xFF654321,
          shadowColor: 0x00000000,
          strokeColor: 0x40070809,
        ),
      ];
      for (final value in settings) {
        await DesktopLyricOverlay.instance.updateConfig(
          DesktopLyricSettings.decode(value.encode()),
          fontSizeRate: 1.25,
        );
      }
      expect(calls, hasLength(settings.length));
      for (var i = 0; i < settings.length; i++) {
        expect(calls[i].method, 'updateConfig');
        final args = calls[i].arguments as Map;
        expect(args['playedColor'], settings[i].playedColor);
        expect(args['unplayColor'], settings[i].unplayColor);
        expect(args['shadowColor'], settings[i].shadowColor);
        expect(args['strokeColor'], settings[i].strokeColor);
      }
    }, skip: !Platform.isAndroid && !Platform.isWindows);

    test('旧配置没有描边字段时回落到不描边，宽度越界被夹紧', () {
      final legacy = DesktopLyricSettings.fromJson({
        'v': DesktopLyricSettings.configVersion,
        'playedColor': 0xFFEC4899,
      });
      expect(legacy.strokeColor, 0x00000000);
      expect(legacy.strokeWidth, 0.06);
      expect(legacy.playedColor, 0xFFEC4899);

      final clamped = DesktopLyricSettings.fromJson({
        'v': DesktopLyricSettings.configVersion,
        'strokeColor': 0xFFFFFFFF,
        'strokeWidth': 5.0,
      });
      expect(clamped.strokeWidth, 0.2);
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
        // 用当前版本号，否则会被当成旧配置、字号直接回退成默认值。
        'v': DesktopLyricSettings.configVersion,
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
