import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme_provider.dart';
import '../../features/settings/application/plugin_providers.dart';

/// 音源图标。
///
/// 内置平台用彩色圆标 + 一个汉字标识（网易「网」、酷狗「狗」、酷我「我」、
/// QQ「Q」、咪咕「咪」），插件音源没有内置图标时用音源名称首字生成中性色圆标。
///
/// 发现页与搜索页的音源切换按钮共用本组件，保证两处样式完全一致。
class SourceIcon extends ConsumerWidget {
  const SourceIcon({
    super.key,
    required this.sourceId,
    this.size = 20,
    this.label,
  });

  /// 平台 id（wy / kg / kw / tx / mg / qsvip / all …）。
  final String sourceId;

  /// 圆标直径。
  final double size;

  /// 音源名称（插件音源取首字）。
  final String? label;

  /// 圆标里文字相对直径的比例（比常规略小一号，视觉更平衡）。
  static const double _glyphRatio = 0.45;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 圆标里的文字使用设置里的「第二字体颜色」。
    final textColor = ref.watch(themeColorsProvider).textSecondary;

    // 插件音源（`平台id@插件id`）：插件自带图标时优先显示它。
    final pluginId = _pluginIdOf(sourceId);
    if (pluginId != null) {
      final iconPath = ref.watch(pluginIconPathProvider(pluginId));
      if (iconPath != null) {
        return _buildIcon(iconPath);
      }
    }

    switch (_baseIdOf(sourceId)) {
      case 'wy':
        return _buildCircle(
          color: const Color(0xFFE60026),
          glyph: '网',
          size: size,
          textColor: textColor,
        );
      case 'kg':
        return _buildCircle(
          color: const Color(0xFF2EADFB),
          glyph: '狗',
          size: size,
          textColor: textColor,
        );
      case 'kw':
        return _buildCircle(
          color: const Color(0xFFFF8500),
          glyph: '我',
          size: size,
          textColor: textColor,
        );
      case 'tx':
        return _buildCircle(
          color: const Color(0xFF31C27C),
          glyph: 'Q',
          size: size,
          textColor: textColor,
        );
      case 'mg':
        return _buildCircle(
          color: const Color(0xFFFF7E00),
          glyph: '咪',
          size: size,
          textColor: textColor,
        );
      case 'qsvip':
        return _buildCircle(
          color: const Color(0xFFFF4081),
          glyph: '汽',
          size: size,
          textColor: textColor,
        );
      case 'all':
        return _buildCircle(
          color: const Color(0xFF6366F1),
          glyph: '聚',
          size: size,
          textColor: textColor,
        );
      default:
        final glyph = (label ?? '').trim();
        if (glyph.isEmpty) {
          return Icon(Icons.music_note, size: size, color: Colors.grey);
        }
        return _buildCircle(
          color: Colors.blueGrey.shade500,
          glyph: glyph.substring(0, 1).toUpperCase(),
          size: size,
          textColor: textColor,
        );
    }
  }

  /// 插件图标：裁成和圆标一样大小的圆形，加载失败退回下面的平台圆标。
  Widget _buildIcon(String path) {
    return ClipOval(
      child: Image.file(
        File(path),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _buildFallback(),
      ),
    );
  }

  Widget _buildFallback() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade500,
        shape: BoxShape.circle,
      ),
      child: Icon(Icons.music_note, size: size * 0.6, color: Colors.white),
    );
  }

  /// `平台id@插件id` → 插件 id；普通音源返回 null。
  static String? _pluginIdOf(String id) {
    final index = id.indexOf('@');
    if (index <= 0 || index >= id.length - 1) return null;
    return id.substring(index + 1);
  }

  /// `平台id@插件id` → 平台 id。
  static String _baseIdOf(String id) {
    final index = id.indexOf('@');
    if (index <= 0 || index >= id.length - 1) return id;
    return id.substring(0, index);
  }

  Widget _buildCircle({
    required Color color,
    required String glyph,
    required double size,
    required Color textColor,
  }) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Center(
        child: Text(
          glyph,
          style: TextStyle(
            color: textColor,
            fontSize: size * _glyphRatio,
            fontWeight: FontWeight.bold,
            // height: 1 让行高等于字号，字形在圆标里严格居中。
            height: 1.0,
          ),
        ),
      ),
    );
  }
}
