import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:on_audio_query/on_audio_query.dart';
import '../../../../shared/services/app_image_cache.dart';
import '../../../../shared/services/cover_cache_service.dart';
import '../models/song.dart';
import '../../application/playback_controller.dart';

class CoverColorResult {
  final Color dominantColor;
  final Color lightColor;
  final bool useDarkText;

  const CoverColorResult({
    required this.dominantColor,
    required this.lightColor,
    required this.useDarkText,
  });

  static const CoverColorResult defaultResult = CoverColorResult(
    dominantColor: Color(0xFF333333),
    lightColor: Color(0xE6FFFFFF),
    useDarkText: false,
  );
}

int _extractDominantColor(Uint8List rgbaBytes) {
  final pixelCount = rgbaBytes.length ~/ 4;
  int rSum = 0, gSum = 0, bSum = 0;
  int count = 0;
  final step = pixelCount > 8000 ? (pixelCount / 4000).floor().clamp(1, 20) : 1;

  for (int i = 0; i < pixelCount; i += step) {
    final offset = i * 4;
    final r = rgbaBytes[offset];
    final g = rgbaBytes[offset + 1];
    final b = rgbaBytes[offset + 2];
    final a = rgbaBytes[offset + 3];
    if (a < 128) continue;
    final brightness = (r * 299 + g * 587 + b * 114) ~/ 1000;
    if (brightness < 25 || brightness > 245) continue;
    rSum += r;
    gSum += g;
    bSum += b;
    count++;
  }

  if (count == 0) return 0xFF333333;
  return 0xFF000000 |
      ((rSum ~/ count) << 16) |
      ((gSum ~/ count) << 8) |
      (bSum ~/ count);
}

class CoverColorExtractor {
  static Future<CoverColorResult> extract(ImageProvider imageProvider) async {
    try {
      final imageStream = imageProvider.resolve(const ImageConfiguration());
      final completer = Completer<ui.Image>();
      late ImageStreamListener listener;
      listener = ImageStreamListener(
        (ImageInfo info, bool _) {
          imageStream.removeListener(listener);
          completer.complete(info.image);
        },
        onError: (error, stackTrace) {
          imageStream.removeListener(listener);
          completer.completeError(error, stackTrace);
        },
      );
      imageStream.addListener(listener);

      final image = await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          imageStream.removeListener(listener);
          throw TimeoutException('Image decode timeout');
        },
      );

      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      image.dispose();

      if (byteData == null) {
        return CoverColorResult.defaultResult;
      }

      final rgbaBytes = byteData.buffer.asUint8List();
      final dominantArgb = await compute(_extractDominantColor, rgbaBytes);

      final dominantColor = Color(dominantArgb);
      final luminance = dominantColor.computeLuminance();
      final useDarkText = luminance > 0.5;

      Color lightColor;
      if (useDarkText) {
        lightColor = _blendWithWhite(dominantColor, 0.7);
      } else {
        lightColor = _blendWithWhite(dominantColor, 0.85);
      }

      return CoverColorResult(
        dominantColor: dominantColor,
        lightColor: lightColor,
        useDarkText: useDarkText,
      );
    } catch (e) {
      return CoverColorResult.defaultResult;
    }
  }

  static Future<CoverColorResult> extractFromSong(
    Song song, {
    OnAudioQuery? audioQuery,
  }) async {
    final coverUrl = song.coverUrl;
    if (coverUrl != null && coverUrl.isNotEmpty) {
      return extractFromUrl(coverUrl);
    }

    if (song.mediaStoreId != null) {
      final query = audioQuery ?? OnAudioQuery();
      try {
        final Uint8List? bytes = await query.queryArtwork(
          song.mediaStoreId!,
          ArtworkType.AUDIO,
          quality: 100,
          size: 400,
        );
        if (bytes == null || bytes.isEmpty) {
          return CoverColorResult.defaultResult;
        }
        return extract(MemoryImage(bytes));
      } catch (_) {
        return CoverColorResult.defaultResult;
      }
    }

    // 桌面端没有 MediaStore，本地歌曲的封面在封面缓存里。
    if (song.isLocal) {
      try {
        final bytes = await CoverCacheService().getArtwork(song.id);
        if (bytes != null && bytes.isNotEmpty) {
          return extract(MemoryImage(bytes));
        }
      } catch (_) {}
    }

    return CoverColorResult.defaultResult;
  }

  /// 从封面地址（网络 URL / 本地文件路径）提取主色。
  ///
  /// 歌单 / 专辑 / 作者 / 榜单详情页的顶栏背景用它，取色算法与播放页相同。
  static Future<CoverColorResult> extractFromUrl(String? url) async {
    if (url == null || url.isEmpty) return CoverColorResult.defaultResult;
    final lower = url.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return extract(
        CachedNetworkImageProvider(url, cacheManager: AppImageCache.manager),
      );
    }
    try {
      final file = File(url);
      if (await file.exists()) return extract(FileImage(file));
    } catch (_) {}
    return CoverColorResult.defaultResult;
  }

  static Color _blendWithWhite(Color color, double factor) {
    return Color.lerp(Colors.white, color, 1 - factor)!;
  }
}

/// 「跟随主题」播放背景用的封面暗色。
///
/// 只保留封面的色相：亮度固定压进暗色区间，白色 / 浅灰封面不会生成
/// 浅色背景；饱和度封顶，亮黄 / 亮蓝 / 亮红 / 亮紫等鲜艳封面也不会留下
/// 刺眼的高饱和色块。接近无彩色的封面按纯灰处理，避免出现奇怪的偏色。
Color coverDarkBackgroundColor(Color color, {required double lightness}) {
  final hsl = HSLColor.fromColor(color);
  final saturation = hsl.saturation < 0.08
      ? 0.0
      : hsl.saturation.clamp(0.12, 0.32);
  return hsl.withSaturation(saturation).withLightness(lightness).toColor();
}

/// CeruMusic-style eager pre-computation: watches current song and
/// computes cover colors in background isolate as soon as the song changes.
/// This runs BEFORE the user opens FullPlayerPage, so colors are cached/ready.
final currentCoverColorProvider = FutureProvider<CoverColorResult?>((
  ref,
) async {
  ref.watch(currentSongIdentityProvider);
  final song = ref.read(playbackControllerProvider).currentSong;
  if (song == null) return null;
  return CoverColorExtractor.extractFromSong(song);
});

/// 详情页顶栏背景用的封面主色（按封面地址缓存，页面离开即释放）。
///
/// 返回 null 表示没有封面 / 提取失败，调用方回退到主题色渐变。
final coverTintColorProvider = FutureProvider.autoDispose
    .family<Color?, String>((ref, url) async {
      if (url.isEmpty) return null;
      final result = await CoverColorExtractor.extractFromUrl(url);
      // 提取失败会拿到默认的 0xFF333333，这个值也当作「没有主色」处理。
      if (result.dominantColor ==
          CoverColorResult.defaultResult.dominantColor) {
        return null;
      }
      return result.dominantColor;
    });

/// 详情页顶栏的「封面主色 → 页面背景」渐变。
///
/// 取色与播放页一致（[coverDarkBackgroundColor]）：深色主题把封面色压进暗色
/// 区间，不会出现刺眼的高饱和色块；浅色主题则把主色淡化后使用，避免浅色
/// 页面顶部突然出现一块深色。没有封面主色时沿用原来的主题色渐变。
List<Color> detailHeaderGradient({
  required Color? coverColor,
  required Color primary,
  required Color background,
  required bool light,
}) {
  if (coverColor == null) {
    return [primary.withValues(alpha: 0.15), background];
  }
  if (light) {
    return [Color.lerp(background, coverColor, 0.30)!, background];
  }
  return [coverDarkBackgroundColor(coverColor, lightness: 0.22), background];
}
