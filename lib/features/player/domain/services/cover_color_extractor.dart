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
import '../../../local/data/local_metadata_reader.dart';
import '../models/song.dart';
import '../../application/playback_controller.dart';

class CoverColorResult {
  final Color dominantColor;
  final Color lightColor;
  final bool useDarkText;

  /// 整张图的色彩浓度：0 = 黑白灰 / 暗到看不出颜色，1 = 颜色很足。
  ///
  /// 背景层用它给饱和度滑条打折（见 `effectiveBlurSaturation`）：黑白图、
  /// 暗图上硬拉饱和度只会放大噪点和色斑。取色失败时保持 1（不衰减）。
  final double colorfulness;

  const CoverColorResult({
    required this.dominantColor,
    required this.lightColor,
    required this.useDarkText,
    this.colorfulness = 1,
  });

  static const CoverColorResult defaultResult = CoverColorResult(
    dominantColor: Color(0xFF333333),
    lightColor: Color(0xE6FFFFFF),
    useDarkText: false,
  );
}

/// 平均色 + 整张图的色彩浓度。
///
/// 浓度取每像素色度（max - min，等价于 HSV 的 S × V）的平均值：纯黑 / 纯白 /
/// 灰度图是 0，暗到看不出颜色的图也很低，颜色正常的图才明显。
(int, double) _extractDominantColor(Uint8List rgbaBytes) {
  final pixelCount = rgbaBytes.length ~/ 4;
  int rSum = 0, gSum = 0, bSum = 0;
  int count = 0;
  double chromaSum = 0;
  int chromaCount = 0;
  final step = pixelCount > 8000 ? (pixelCount / 4000).floor().clamp(1, 20) : 1;

  for (int i = 0; i < pixelCount; i += step) {
    final offset = i * 4;
    final r = rgbaBytes[offset];
    final g = rgbaBytes[offset + 1];
    final b = rgbaBytes[offset + 2];
    final a = rgbaBytes[offset + 3];
    if (a < 128) continue;

    // 色彩浓度：所有不透明像素都算（含极暗 / 极亮），纯黑白灰自然是 0。
    final maxChannel = r > g ? (r > b ? r : b) : (g > b ? g : b);
    final minChannel = r < g ? (r < b ? r : b) : (g < b ? g : b);
    chromaSum += (maxChannel - minChannel) / 255;
    chromaCount++;

    final brightness = (r * 299 + g * 587 + b * 114) ~/ 1000;
    if (brightness < 25 || brightness > 245) continue;
    rSum += r;
    gSum += g;
    bSum += b;
    count++;
  }

  final colorfulness = chromaCount == 0 ? 1.0 : chromaSum / chromaCount;
  if (count == 0) return (0xFF333333, colorfulness);
  return (
    0xFF000000 |
        ((rSum ~/ count) << 16) |
        ((gSum ~/ count) << 8) |
        (bSum ~/ count),
    colorfulness,
  );
}

class CoverColorExtractor {
  /// 把图片解码成原始 RGBA 字节；解码失败 / 超时返回 null。
  static Future<Uint8List?> _rgbaBytes(ImageProvider imageProvider) async {
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

    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    return byteData?.buffer.asUint8List();
  }

  static Future<CoverColorResult> extract(ImageProvider imageProvider) async {
    try {
      final rgbaBytes = await _rgbaBytes(imageProvider);
      if (rgbaBytes == null) {
        return CoverColorResult.defaultResult;
      }

      final (dominantArgb, colorfulness) = await compute(
        _extractDominantColor,
        rgbaBytes,
      );

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
        colorfulness: colorfulness,
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

    if (song.isLocal) {
      // 与播放页封面组件保持同一条链路：封面缓存（MediaStore）→ 音频文件内嵌
      // 封面。不少 Android 设备的 MediaStore 没有 artwork，界面上的封面是现场
      // 从文件里提取的；取色只查 MediaStore / 缓存会一直得到默认灰，表现为
      // 「本地歌有封面，主界面和播放栏却不变色」。
      final bytes = await _localArtworkBytes(song, audioQuery: audioQuery);
      if (bytes != null && bytes.isNotEmpty) {
        return extract(MemoryImage(bytes));
      }
      // 本地确实没有封面时，再试匹配到的在线封面地址。
      if (coverUrl != null && coverUrl.isNotEmpty) {
        return extractFromUrl(coverUrl);
      }
      return CoverColorResult.defaultResult;
    }

    if (coverUrl != null && coverUrl.isNotEmpty) {
      return extractFromUrl(coverUrl);
    }

    if (song.mediaStoreId != null) {
      final bytes = await _localArtworkBytes(song, audioQuery: audioQuery);
      if (bytes != null && bytes.isNotEmpty) {
        return extract(MemoryImage(bytes));
      }
    }

    return CoverColorResult.defaultResult;
  }

  /// 本地封面字节：缓存 / MediaStore 优先，都没有时从音频文件里读内嵌封面。
  ///
  /// 与 [MusicCoverImage] 的兜底一致，并在读到时回填封面缓存，避免播放页
  /// 再次解析整个音频文件。
  static Future<Uint8List?> _localArtworkBytes(
    Song song, {
    OnAudioQuery? audioQuery,
  }) async {
    try {
      if (audioQuery != null && song.mediaStoreId != null) {
        final bytes = await audioQuery.queryArtwork(
          song.mediaStoreId!,
          ArtworkType.AUDIO,
          quality: 100,
          size: 400,
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      } else {
        final bytes = await CoverCacheService().getArtwork(
          song.id,
          mediaStoreId: song.mediaStoreId,
        );
        if (bytes != null && bytes.isNotEmpty) return bytes;
      }
    } catch (_) {}

    final filePath = song.filePath;
    if (filePath == null || filePath.isEmpty) return null;
    try {
      final artwork = (await LocalMetadataReader.read(filePath)).artwork;
      if (artwork == null || artwork.isEmpty) return null;
      unawaited(CoverCacheService().putArtwork(song.id, artwork));
      return artwork;
    } catch (_) {
      return null;
    }
  }

  /// 从封面地址（网络 URL / 本地文件路径）取出对应的 [ImageProvider]。
  static Future<ImageProvider?> _providerForUrl(String? url) async {
    if (url == null || url.isEmpty) return null;
    final lower = url.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return CachedNetworkImageProvider(
        url,
        cacheManager: AppImageCache.manager,
      );
    }
    try {
      final file = File(url);
      if (await file.exists()) return FileImage(file);
    } catch (_) {}
    return null;
  }

  /// 从封面地址（网络 URL / 本地文件路径）提取主色。
  ///
  /// 歌单 / 专辑 / 作者 / 榜单详情页的顶栏背景用它，取色算法与播放页相同。
  static Future<CoverColorResult> extractFromUrl(String? url) async {
    final provider = await _providerForUrl(url);
    if (provider == null) return CoverColorResult.defaultResult;
    return extract(provider);
  }

  /// 封面整体亮度（0..1）：所有不透明像素的感知亮度均值。
  ///
  /// 用于「亮色封面要不要压暗」这类视觉判断。探测时先把图缩到 [probeSize]
  /// 见方再解码，开销和原图尺寸无关；取不到时返回 null。
  static Future<double?> averageLuminanceFromUrl(
    String? url, {
    int probeSize = 96,
  }) async {
    try {
      final provider = await _providerForUrl(url);
      if (provider == null) return null;
      final rgbaBytes = await _rgbaBytes(
        ResizeImage(
          provider,
          width: probeSize,
          height: probeSize,
          allowUpscaling: false,
        ),
      );
      if (rgbaBytes == null) return null;
      return await compute(_averageLuminance, rgbaBytes);
    } catch (_) {
      return null;
    }
  }

  static Color _blendWithWhite(Color color, double factor) {
    return Color.lerp(Colors.white, color, 1 - factor)!;
  }
}

/// 所有不透明像素的平均感知亮度（0..1）；全透明图按 0 处理。
double _averageLuminance(Uint8List rgbaBytes) {
  final pixelCount = rgbaBytes.length ~/ 4;
  if (pixelCount == 0) return 0;
  double sum = 0;
  int count = 0;
  for (int i = 0; i < pixelCount; i++) {
    final offset = i * 4;
    if (rgbaBytes[offset + 3] < 128) continue;
    sum +=
        (rgbaBytes[offset] * 299 +
            rgbaBytes[offset + 1] * 587 +
            rgbaBytes[offset + 2] * 114) /
        (255 * 1000);
    count++;
  }
  return count == 0 ? 0 : sum / count;
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
