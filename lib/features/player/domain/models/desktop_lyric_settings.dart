import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

/// 桌面歌词(悬浮歌词窗)的完整配置。
///
/// 字段与取值区间参考 lx-music 的 `desktopLyric.*` 设置项:
/// - `enable` / `isLock`:开关
/// - `maxLineNum`:窗口最多显示的行数
/// - `fontSize`:歌词字号(px)
/// - `opacityPercent`:整体不透明度
/// - `positionX` / `positionY`:窗口位置,以「可移动空间」的百分比存储,
///   这样屏幕尺寸/方向变化后位置依旧保持相对一致。
/// - `playedColor` / `unplayColor` / `shadowColor`:已播放、未播放、描边阴影颜色
///
/// 之前还有「单行显示」「歌词切换动画」「窗口宽度」「水平/垂直对齐」几项，
/// 现在都由固定规则决定，不再暴露给用户：
/// - 行数只由「显示行数」控制；
/// - 歌词切换动画固定开启；
/// - 窗口宽度 Android 为屏幕宽度 100%，Windows 为工作区宽度 80%；
/// - 文字居中对齐（水平 + 垂直）。
class DesktopLyricSettings {
  const DesktopLyricSettings({
    required this.enable,
    required this.isLock,
    required this.maxLineNum,
    required this.fontSize,
    required this.opacityPercent,
    required this.positionX,
    required this.positionY,
    required this.playedColor,
    required this.unplayColor,
    required this.shadowColor,
  });

  /// 默认配置。
  ///
  /// Windows 与手机差别较大：桌面歌词是独立窗口，字号更大、默认靠近屏幕
  /// 底部；手机是悬浮窗，默认在顶部状态栏下方。
  static DesktopLyricSettings get defaults => DesktopLyricSettings(
    enable: false,
    isLock: false,
    // 默认显示当前行与下一行
    maxLineNum: 2,
    // Windows 上桌面歌词是独立窗口，字号比手机大得多。
    fontSize: Platform.isWindows ? 45 : 18,
    opacityPercent: 85,
    // 水平居中；Windows 靠近底部（不贴边），Android 在顶部状态栏下方。
    positionX: 50,
    positionY: Platform.isWindows ? 85 : 0,
    playedColor: 0xFF07C556,
    unplayColor: 0xFFFFFFFF,
    shadowColor: 0x99000000,
  );

  /// 是否启用桌面歌词。
  final bool enable;

  /// 锁定后歌词窗不再响应触摸(点击穿透到下层页面),且隐藏背景与拖动把手。
  final bool isLock;

  /// 窗口最多显示的行数,1 ~ 8。
  final int maxLineNum;

  /// 歌词字号(px),12 ~ 80。
  final double fontSize;

  /// 整体不透明度百分比,10 ~ 100。
  final int opacityPercent;

  /// 窗口左上角在可移动空间中的横向百分比位置,0 ~ 100。
  final double positionX;

  /// 窗口左上角在可移动空间中的纵向百分比位置,0 ~ 100。
  final double positionY;

  /// 已播放(当前行)歌词颜色,ARGB。
  final int playedColor;

  /// 未播放歌词颜色,ARGB。
  final int unplayColor;

  /// 歌词描边/阴影颜色,ARGB。
  final int shadowColor;

  /// 实际生效的不透明度,0.1 ~ 1.0。
  double get opacity => (opacityPercent / 100).clamp(0.05, 1.0);

  /// 桌面歌词固定居中显示（水平 + 垂直）。
  TextAlign get textAlign => TextAlign.center;

  MainAxisAlignment get verticalAlignment => MainAxisAlignment.center;

  DesktopLyricSettings copyWith({
    bool? enable,
    bool? isLock,
    int? maxLineNum,
    double? fontSize,
    int? opacityPercent,
    double? positionX,
    double? positionY,
    int? playedColor,
    int? unplayColor,
    int? shadowColor,
  }) {
    return DesktopLyricSettings(
      enable: enable ?? this.enable,
      isLock: isLock ?? this.isLock,
      maxLineNum: maxLineNum ?? this.maxLineNum,
      fontSize: fontSize ?? this.fontSize,
      opacityPercent: opacityPercent ?? this.opacityPercent,
      positionX: positionX ?? this.positionX,
      positionY: positionY ?? this.positionY,
      playedColor: playedColor ?? this.playedColor,
      unplayColor: unplayColor ?? this.unplayColor,
      shadowColor: shadowColor ?? this.shadowColor,
    );
  }

  Map<String, dynamic> toJson() => {
    // 配置版本：字号 / 不透明度 / 位置的默认值改过，旧版本需要重新取默认值。
    'v': 2,
    'enable': enable,
    'isLock': isLock,
    'maxLineNum': maxLineNum,
    'fontSize': fontSize,
    'opacityPercent': opacityPercent,
    'positionX': positionX,
    'positionY': positionY,
    'playedColor': playedColor,
    'unplayColor': unplayColor,
    'shadowColor': shadowColor,
  };

  static DesktopLyricSettings fromJson(Map<String, dynamic> json) {
    num? readNum(dynamic v) => v is num ? v : null;

    // 旧版本（v < 2）保存的字号 / 不透明度 / 位置是按老默认值算的，
    // 这里按新的默认值重新给（颜色与行数保留用户的选择）。
    final isLegacy = json['v'] != 2;

    return DesktopLyricSettings(
      enable: json['enable'] as bool? ?? defaults.enable,
      isLock: json['isLock'] as bool? ?? defaults.isLock,
      maxLineNum: (readNum(json['maxLineNum'])?.toInt() ?? defaults.maxLineNum)
          .clamp(1, 8),
      fontSize: isLegacy
          ? defaults.fontSize
          : (readNum(json['fontSize'])?.toDouble() ?? defaults.fontSize)
                .clamp(12.0, 80.0),
      opacityPercent: isLegacy
          ? defaults.opacityPercent
          : (readNum(json['opacityPercent'])?.toInt() ??
                    defaults.opacityPercent)
                .clamp(10, 100),
      positionX: isLegacy
          ? defaults.positionX
          : (readNum(json['positionX'])?.toDouble() ?? defaults.positionX)
                .clamp(0.0, 100.0),
      positionY: isLegacy
          ? defaults.positionY
          : (readNum(json['positionY'])?.toDouble() ?? defaults.positionY)
                .clamp(0.0, 100.0),
      playedColor: readNum(json['playedColor'])?.toInt() ?? defaults.playedColor,
      unplayColor: readNum(json['unplayColor'])?.toInt() ?? defaults.unplayColor,
      shadowColor: readNum(json['shadowColor'])?.toInt() ?? defaults.shadowColor,
    );
  }

  /// 从持久化的 JSON 字符串还原,失败时回退到默认配置。
  static DesktopLyricSettings decode(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return fromJson(decoded);
      return fromJson(decoded.cast<String, dynamic>());
    } catch (_) {
      return defaults;
    }
  }

  String encode() => jsonEncode(toJson());

  @override
  bool operator ==(Object other) {
    return other is DesktopLyricSettings &&
        other.enable == enable &&
        other.isLock == isLock &&
        other.maxLineNum == maxLineNum &&
        other.fontSize == fontSize &&
        other.opacityPercent == opacityPercent &&
        other.positionX == positionX &&
        other.positionY == positionY &&
        other.playedColor == playedColor &&
        other.unplayColor == unplayColor &&
        other.shadowColor == shadowColor;
  }

  @override
  int get hashCode => Object.hash(
    enable,
    isLock,
    maxLineNum,
    fontSize,
    opacityPercent,
    positionX,
    positionY,
    playedColor,
    unplayColor,
    shadowColor,
  );
}
