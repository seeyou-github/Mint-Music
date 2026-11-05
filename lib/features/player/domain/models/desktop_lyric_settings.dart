import 'dart:convert';
import 'dart:io';

/// 桌面歌词(悬浮歌词窗)的完整配置。
///
/// 字段与取值区间参考 lx-music 的 `desktopLyric.*` 设置项:
/// - `enable`:开关
/// - `fontSize`:歌词字号(px)
/// - `positionX` / `positionY`:窗口位置,以「可移动空间」的百分比存储,
///   这样屏幕尺寸/方向变化后位置依旧保持相对一致。
/// - `playedColor` / `unplayColor` / `shadowColor`:已播放、未播放、阴影颜色
/// - `strokeColor` / `strokeWidth`:文字描边颜色与宽度（宽度按字号比例存，
///   换算成像素后各平台字号不同也能保持同样的观感）
///
/// 显示行数、透明度、锁定歌词窗都已固定下来，不再暴露给用户：
/// - 固定显示 2 行（上下两个固定槽位，按当前行奇偶交替）；
/// - 控件背景完全透明（Android 原生悬浮窗与 Flutter 回退层都不画底色），
///   文字可读性由阴影与描边保证；
/// - 始终不锁定（可拖动、可点击）。
class DesktopLyricSettings {
  const DesktopLyricSettings({
    required this.enable,
    required this.fontSize,
    required this.positionX,
    required this.positionY,
    required this.playedColor,
    required this.unplayColor,
    required this.shadowColor,
    required this.strokeColor,
    required this.strokeWidth,
    this.customColors = const <String>[],
  });

  /// 桌面歌词固定显示的行数。
  static const int lineCount = 2;

  /// 内容整体不透明度：背景透明后不再压暗文字。
  static const double opacity = 1.0;

  /// 默认配置。
  ///
  /// Windows 与手机差别较大：桌面歌词是独立窗口，字号更大、默认靠近屏幕
  /// 底部；手机是悬浮窗，默认在顶部状态栏下方。
  static DesktopLyricSettings get defaults => DesktopLyricSettings(
    enable: false,
    // Windows 上桌面歌词是独立窗口，字号比手机大得多。
    fontSize: Platform.isWindows ? 50 : 18,
    // 水平居中；Windows 靠近底部（不贴边），Android 在顶部状态栏下方。
    positionX: 50,
    positionY: Platform.isWindows ? 85 : 0,
    playedColor: 0xFF07C556,
    unplayColor: 0xFFFFFFFF,
    shadowColor: 0x99000000,
    // 默认不描边：老用户升级后观感不变，想要描边在设置里选颜色即可。
    // 描边宽度按「字号的比例」存，Windows 50px 与手机 18sp 都能得到同样粗细。
    strokeColor: 0x00000000,
    strokeWidth: 0.06,
  );

  /// 当前配置版本。
  ///
  /// 1 → 2 → 3 改过字号 / 位置的默认值；4 把 Windows 字号默认值改成 50。
  static const int configVersion = 4;

  /// 是否启用桌面歌词。
  final bool enable;

  /// 歌词字号(px),12 ~ 80。
  final double fontSize;

  /// 窗口左上角在可移动空间中的横向百分比位置,0 ~ 100。
  final double positionX;

  /// 窗口左上角在可移动空间中的纵向百分比位置,0 ~ 100。
  final double positionY;

  /// 已播放(当前行)歌词颜色,ARGB。
  final int playedColor;

  /// 未播放歌词颜色,ARGB。
  final int unplayColor;

  /// 歌词阴影颜色,ARGB。
  final int shadowColor;

  /// 文字描边颜色,ARGB。完全透明（alpha=0）表示不描边。
  final int strokeColor;

  /// 文字描边宽度,占歌词字号的比例（0 ~ 0.2）。
  ///
  /// 原生侧按 `字号 × 比例` 换算成像素线宽；存比例而不是像素，是为了让
  /// Windows（默认 50px）与 Android（默认 18sp）的描边看起来一样粗。
  final double strokeWidth;

  /// 「新增颜色」保存的自定义色板（ARGB hex：`#AARRGGBB` 或 `#RRGGBB`）。
  /// 四个颜色设置共用一份，随桌面歌词设置一起持久化。
  final List<String> customColors;

  DesktopLyricSettings copyWith({
    bool? enable,
    double? fontSize,
    double? positionX,
    double? positionY,
    int? playedColor,
    int? unplayColor,
    int? shadowColor,
    int? strokeColor,
    double? strokeWidth,
    List<String>? customColors,
  }) {
    return DesktopLyricSettings(
      enable: enable ?? this.enable,
      fontSize: fontSize ?? this.fontSize,
      positionX: positionX ?? this.positionX,
      positionY: positionY ?? this.positionY,
      playedColor: playedColor ?? this.playedColor,
      unplayColor: unplayColor ?? this.unplayColor,
      shadowColor: shadowColor ?? this.shadowColor,
      strokeColor: strokeColor ?? this.strokeColor,
      strokeWidth: strokeWidth ?? this.strokeWidth,
      customColors: customColors ?? this.customColors,
    );
  }

  Map<String, dynamic> toJson() => {
    // 配置版本：字号 / 位置的默认值改过，旧版本需要重新取默认值。
    'v': configVersion,
    'enable': enable,
    'fontSize': fontSize,
    'positionX': positionX,
    'positionY': positionY,
    'playedColor': playedColor,
    'unplayColor': unplayColor,
    'shadowColor': shadowColor,
    'strokeColor': strokeColor,
    'strokeWidth': strokeWidth,
    'customColors': customColors,
  };

  static DesktopLyricSettings fromJson(Map<String, dynamic> json) {
    num? readNum(dynamic v) => v is num ? v : null;

    final version = json['v'] is num ? (json['v'] as num).toInt() : 0;
    // 字号默认值改过（42 → 50）：旧版本保存的是按老默认值算出来的字号，
    // 这里直接换成新的默认值，用户改过的大小也只能放弃（否则看不出变化）。
    final legacyFontSize = version < configVersion;
    // 位置：v3 之前的默认值与布局都不同，一并重置；v3 起保留用户拖动的位置。
    final legacyPosition = version < 3;

    return DesktopLyricSettings(
      enable: json['enable'] as bool? ?? defaults.enable,
      fontSize: legacyFontSize
          ? defaults.fontSize
          : (readNum(json['fontSize'])?.toDouble() ?? defaults.fontSize).clamp(
              12.0,
              80.0,
            ),
      positionX: legacyPosition
          ? defaults.positionX
          : (readNum(json['positionX'])?.toDouble() ?? defaults.positionX)
                .clamp(0.0, 100.0),
      positionY: legacyPosition
          ? defaults.positionY
          : (readNum(json['positionY'])?.toDouble() ?? defaults.positionY)
                .clamp(0.0, 100.0),
      playedColor:
          readNum(json['playedColor'])?.toInt() ?? defaults.playedColor,
      unplayColor:
          readNum(json['unplayColor'])?.toInt() ?? defaults.unplayColor,
      shadowColor:
          readNum(json['shadowColor'])?.toInt() ?? defaults.shadowColor,
      // 老配置没有描边字段：回落到「透明 = 不描边」，保持原有观感。
      strokeColor:
          readNum(json['strokeColor'])?.toInt() ?? defaults.strokeColor,
      strokeWidth:
          (readNum(json['strokeWidth'])?.toDouble() ?? defaults.strokeWidth)
              .clamp(0.0, 0.2)
              .toDouble(),
      customColors: json['customColors'] is List
          ? (json['customColors'] as List).whereType<String>().toList()
          : const <String>[],
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
        other.fontSize == fontSize &&
        other.positionX == positionX &&
        other.positionY == positionY &&
        other.playedColor == playedColor &&
        other.unplayColor == unplayColor &&
        other.shadowColor == shadowColor &&
        other.strokeColor == strokeColor &&
        other.strokeWidth == strokeWidth &&
        _sameColors(other.customColors, customColors);
  }

  static bool _sameColors(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].toUpperCase() != b[i].toUpperCase()) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    enable,
    fontSize,
    positionX,
    positionY,
    playedColor,
    unplayColor,
    shadowColor,
    strokeColor,
    strokeWidth,
    Object.hashAll([for (final c in customColors) c.toUpperCase()]),
  );
}
