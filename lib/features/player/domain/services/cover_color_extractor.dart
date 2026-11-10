import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
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

/// 候选主色最多留几个：够覆盖封面上的主要色系，又不把零碎杂色算进来。
const int _kMaxCandidates = 4;

/// 色相分桶宽度（度）：30° 一档，正好对应红 / 橙 / 黄 / 绿 / 青 / 蓝 / 紫 / 品红。
const double _kHueBucketWidth = 30;

/// 按色相统计封面像素的一个桶。
class _ColorBucket {
  double weight = 0;
  int count = 0;
  double r = 0;
  double g = 0;
  double b = 0;
}

/// 从封面像素里挑出几个候选主色（按权重从高到低）。
///
/// 不能直接对所有像素求 RGB 平均：彩色封面一平均就糊成一片灰褐色（人像的
/// 肤色、暖色灯光、木色背景叠在一起必然往棕黄跑），这就是「取色出来总是
/// 棕色系」的根源。这里改成：
///   - 按 30° 色相分桶，只统计**够鲜艳**的像素（饱和度 < 0.16 的算无彩色，
///     只留作纯灰封面的兜底）；
///   - 权重 = 饱和度² × 明度，鲜艳且明亮的颜色更算数，灰蒙蒙的背景压不住它；
///   - 每个桶取该桶像素的加权平均色，再提一档饱和度；
///   - 返回权重最高的几个桶，色系因此比单一平均值丰富得多。
///
/// 返回的是 ARGB 整数列表；解析失败时返回空列表。
List<int> _extractColorCandidates(Uint8List rgbaBytes) {
  final pixelCount = rgbaBytes.length ~/ 4;
  if (pixelCount == 0) return const [];
  final step = pixelCount > 6000 ? (pixelCount / 3000).floor().clamp(1, 24) : 1;

  final buckets = <int, _ColorBucket>{};
  // 无彩色（黑白灰）封面的兜底平均色。
  double grayR = 0, grayG = 0, grayB = 0;
  var grayCount = 0;

  for (var i = 0; i < pixelCount; i += step) {
    final offset = i * 4;
    if (rgbaBytes[offset + 3] < 128) continue;
    final r = rgbaBytes[offset];
    final g = rgbaBytes[offset + 1];
    final b = rgbaBytes[offset + 2];
    final max = math.max(r, math.max(g, b));
    final min = math.min(r, math.min(g, b));
    final value = max / 255.0;
    // 近乎纯黑 / 纯白没有色相信息，参与平均只会把结果往灰里拉。
    if (value <= 0.12 || value >= 0.98) continue;

    final chroma = max - min;
    final saturation = max == 0 ? 0.0 : chroma / max;
    if (saturation < 0.16) {
      grayR += r;
      grayG += g;
      grayB += b;
      grayCount++;
      continue;
    }

    final key = (_hueDegrees(r, g, b, max, chroma) / _kHueBucketWidth).floor();
    final bucket = buckets.putIfAbsent(key, () => _ColorBucket());
    final weight = saturation * saturation * (0.35 + 0.65 * value);
    bucket.weight += weight;
    bucket.count += 1;
    bucket.r += r * weight;
    bucket.g += g * weight;
    bucket.b += b * weight;
  }

  final ranked = buckets.values.toList()
    ..sort((a, b) => b.weight.compareTo(a.weight));
  final candidates = <int>[];
  if (ranked.isEmpty) {
    if (grayCount > 0) {
      candidates.add(
        _vividColor(
          (grayR / grayCount).round(),
          (grayG / grayCount).round(),
          (grayB / grayCount).round(),
        ),
      );
    }
    return candidates;
  }
  // 权重不到第一名 5% 的色相基本是角落杂色 / JPEG 噪点，留着只会让「随机
  // 换个色系」换出跟封面无关的颜色。
  final minWeight = ranked.first.weight * 0.05;
  for (final bucket in ranked.take(_kMaxCandidates)) {
    // 只有零星几个像素的色相不算「主色」，否则封面角落一个水印就能定色。
    if (bucket.count < 3 || bucket.weight < minWeight) continue;
    candidates.add(
      _vividColor(
        (bucket.r / bucket.weight).round(),
        (bucket.g / bucket.weight).round(),
        (bucket.b / bucket.weight).round(),
      ),
    );
  }
  if (candidates.isEmpty && grayCount > 0) {
    candidates.add(
      _vividColor(
        (grayR / grayCount).round(),
        (grayG / grayCount).round(),
        (grayB / grayCount).round(),
      ),
    );
  }
  return candidates;
}

/// 像素的色相（0~360 度）。
double _hueDegrees(int r, int g, int b, int max, int chroma) {
  if (chroma == 0) return 0;
  double hue;
  if (max == r) {
    hue = ((g - b) / chroma) % 6;
  } else if (max == g) {
    hue = (b - r) / chroma + 2;
  } else {
    hue = (r - g) / chroma + 4;
  }
  hue *= 60;
  return hue < 0 ? hue + 360 : hue;
}

/// 把候选色提一档饱和度。
///
/// 桶内平均之后饱和度会被稀释（同一色相里既有亮部也有阴影），提一档才能让
/// 派生出的背景看得出是「那个颜色」。接近无彩色的不动，否则会把灰色硬掰
/// 成偏红 / 偏蓝。
int _vividColor(int r, int g, int b) {
  final color = Color.fromARGB(255, r, g, b);
  final hsl = HSLColor.fromColor(color);
  if (hsl.saturation < 0.12) return color.toARGB32();
  final saturation = (hsl.saturation * 1.45 + 0.06).clamp(0.0, 0.92);
  return hsl.withSaturation(saturation).toColor().toARGB32();
}

/// 从候选里挑一个作为封面主色。
///
/// [seed] 为 0 表示不需要随机（设置里「从图片取色」这种手选场景）；
/// 播放时用歌曲信息做种子：同一首歌每次都挑到同一个色（切换页面 / 重进
/// 播放页不会变色），不同歌之间则可以在相近的主色里落在不同色系上。
///
/// 候选第一名偏棕 / 橙（15°~55°，也就是最常见的肤色 / 暖光色）时，给其它
/// 候选更多机会 —— 直接后果就是整体背景不再一片棕。
int _pickAccent(List<int> candidates, int seed) {
  if (candidates.isEmpty) return 0xFF333333;
  if (seed == 0 || candidates.length == 1) return candidates.first;

  final random = math.Random(seed);
  final topHue = HSLColor.fromColor(Color(candidates.first)).hue;
  final warm = topHue >= 15 && topHue <= 55;
  final roll = random.nextDouble();
  var index = 0;
  // 暖色封面（棕 / 橙最容易撞色）：六成概率换到封面上的其它色系。
  if (candidates.length > 1 && roll > (warm ? 0.40 : 0.75)) index = 1;
  if (candidates.length > 2 && roll > (warm ? 0.78 : 0.92)) index = 2;
  // 再抖一点色相（±10°）：同一色系的封面不会得到完全一样的背景。
  return _shiftHue(candidates[index], (random.nextDouble() * 2 - 1) * 10);
}

/// 只改色相、保留饱和度与明度。
int _shiftHue(int argb, double degrees) {
  final hsl = HSLColor.fromColor(Color(argb));
  return hsl.withHue((hsl.hue + degrees) % 360).toColor().toARGB32();
}

class CoverColorExtractor {
  /// 从图片里取主色。
  ///
  /// [seed] 为 0（默认）时完全按权重取第一名，结果稳定，适合设置里「从图片
  /// 取色」这类手选场景；播放时传歌曲信息算出的种子（见 [extractFromSong]），
  /// 同一首歌结果固定、不同歌之间能在多个候选色系里分散。
  static Future<CoverColorResult> extract(
    ImageProvider imageProvider, {
    int seed = 0,
  }) async {
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
      final candidates = await compute(_extractColorCandidates, rgbaBytes);
      final dominantColor = Color(_pickAccent(candidates, seed));
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

  /// 每首歌固定的取色随机种子。
  ///
  /// 同一首歌每次都取到同一个色系（切歌再切回来、重启应用都不变色），
  /// 不同歌之间则分散到封面上的不同色系 —— 这就是「加一点随机性」的来源。
  ///
  /// 用自己算的 FNV-1a（而不是 `Object.hash`）：后者跨进程可能变，
  /// 同一首歌重启后颜色就跟着变了。
  static int _seedOf(Song song) {
    var hash = 0x811C9DC5;
    for (final unit in '${song.id}|${song.title}|${song.artist}'.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0x7FFFFFFF;
    }
    // 0 在 [_pickAccent] 里表示「不随机」，撞上了挪一位。
    return hash == 0 ? 1 : hash;
  }

  static Future<CoverColorResult> extractFromSong(
    Song song, {
    OnAudioQuery? audioQuery,
  }) async {
    final coverUrl = song.coverUrl;
    final seed = _seedOf(song);

    if (song.isLocal) {
      // 与播放页封面组件保持同一条链路：封面缓存（MediaStore）→ 音频文件内嵌
      // 封面。不少 Android 设备的 MediaStore 没有 artwork，界面上的封面是现场
      // 从文件里提取的；取色只查 MediaStore / 缓存会一直得到默认灰，表现为
      // 「本地歌有封面，主界面和播放栏却不变色」。
      final bytes = await _localArtworkBytes(song, audioQuery: audioQuery);
      if (bytes != null && bytes.isNotEmpty) {
        return extract(MemoryImage(bytes), seed: seed);
      }
      // 本地确实没有封面时，再试匹配到的在线封面地址。
      if (coverUrl != null && coverUrl.isNotEmpty) {
        return extractFromUrl(coverUrl, seed: seed);
      }
      return CoverColorResult.defaultResult;
    }

    if (coverUrl != null && coverUrl.isNotEmpty) {
      return extractFromUrl(coverUrl, seed: seed);
    }

    if (song.mediaStoreId != null) {
      final bytes = await _localArtworkBytes(song, audioQuery: audioQuery);
      if (bytes != null && bytes.isNotEmpty) {
        return extract(MemoryImage(bytes), seed: seed);
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

  /// 从封面地址（网络 URL / 本地文件路径）提取主色。
  ///
  /// 歌单 / 专辑 / 作者 / 榜单详情页的顶栏背景用它，取色算法与播放页相同。
  /// [seed] 见 [extract]：传歌曲种子时，同一张封面在不同歌里可能落在不同
  /// 色系上。
  static Future<CoverColorResult> extractFromUrl(
    String? url, {
    int seed = 0,
  }) async {
    if (url == null || url.isEmpty) return CoverColorResult.defaultResult;
    final lower = url.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return extract(
        CachedNetworkImageProvider(url, cacheManager: AppImageCache.manager),
        seed: seed,
      );
    }
    try {
      final file = File(url);
      if (await file.exists()) return extract(FileImage(file), seed: seed);
    } catch (_) {}
    return CoverColorResult.defaultResult;
  }

  static Color _blendWithWhite(Color color, double factor) {
    return Color.lerp(Colors.white, color, 1 - factor)!;
  }
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
