import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
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
  /// 取色 / 测光只需要缩略图：128px 解码成 RGBA 只有 64KB，而 1024px 原图
  /// 要 4MB，解码本身也慢一个数量级。
  static const int _decodeSize = 128;

  /// 取色结果缓存：同一张封面在切歌、返回页面、背景层重建时会被反复取色，
  /// 命中缓存可以连解码都省掉。键由调用方给（歌单 id / 封面地址）。
  static const int _resultCacheLimit = 96;
  static final LinkedHashMap<String, CoverColorResult> _resultCache =
      LinkedHashMap();

  static CoverColorResult? _cached(String? key) {
    if (key == null) return null;
    final result = _resultCache.remove(key);
    if (result != null) _resultCache[key] = result; // 最近使用
    return result;
  }

  static void _store(String? key, CoverColorResult result) {
    if (key == null) return;
    _resultCache.remove(key);
    _resultCache[key] = result;
    while (_resultCache.length > _resultCacheLimit) {
      _resultCache.remove(_resultCache.keys.first);
    }
  }

  /// 把图片解码成原始 RGBA 字节；解码失败 / 超时返回 null。
  static Future<Uint8List?> _rgbaBytes(ImageProvider imageProvider) async {
    // 调用方已经缩过图就不要再套一层（ResizeImage 不能相互叠加）。
    final provider = imageProvider is ResizeImage
        ? imageProvider
        : ResizeImage(
            imageProvider,
            width: _decodeSize,
            height: _decodeSize,
            allowUpscaling: false,
          );
    final imageStream = provider.resolve(const ImageConfiguration());
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

  static Future<CoverColorResult> extract(
    ImageProvider imageProvider, {
    String? cacheKey,
  }) async {
    final cached = _cached(cacheKey);
    if (cached != null) return cached;
    try {
      final rgbaBytes = await _rgbaBytes(imageProvider);
      if (rgbaBytes == null) {
        return CoverColorResult.defaultResult;
      }

      final (dominantArgb, colorfulness) = await _ColorWorker.instance.extract(
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

      final result = CoverColorResult(
        dominantColor: dominantColor,
        lightColor: lightColor,
        useDarkText: useDarkText,
        colorfulness: colorfulness,
      );
      _store(cacheKey, result);
      return result;
    } catch (e) {
      // 失败结果不缓存：图片可能只是暂时没加载出来，下次还要能重试。
      return CoverColorResult.defaultResult;
    }
  }

  /// 歌曲取色缓存的键：换封面 / 换文件（mtime 变化）时自动失效。
  static String _songCacheKey(Song song) =>
      'song:${song.id}:${song.coverUrl ?? ''}:${song.fileModified ?? 0}';

  static Future<CoverColorResult> extractFromSong(
    Song song, {
    OnAudioQuery? audioQuery,
  }) async {
    final cacheKey = _songCacheKey(song);
    final cached = _cached(cacheKey);
    if (cached != null) return cached;

    final coverUrl = song.coverUrl;

    if (song.isLocal) {
      // 与播放页封面组件保持同一条链路：封面缓存（MediaStore）→ 音频文件内嵌
      // 封面。不少 Android 设备的 MediaStore 没有 artwork，界面上的封面是现场
      // 从文件里提取的；取色只查 MediaStore / 缓存会一直得到默认灰，表现为
      // 「本地歌有封面，主界面和播放栏却不变色」。
      final bytes = await _localArtworkBytes(song, audioQuery: audioQuery);
      if (bytes != null && bytes.isNotEmpty) {
        final result = await extract(MemoryImage(bytes));
        _store(cacheKey, result);
        return result;
      }
      // 本地确实没有封面时，再试匹配到的在线封面地址。
      if (coverUrl != null && coverUrl.isNotEmpty) {
        final result = await extractFromUrl(coverUrl);
        _store(cacheKey, result);
        return result;
      }
      return CoverColorResult.defaultResult;
    }

    if (coverUrl != null && coverUrl.isNotEmpty) {
      final result = await extractFromUrl(coverUrl);
      _store(cacheKey, result);
      return result;
    }

    if (song.mediaStoreId != null) {
      final bytes = await _localArtworkBytes(song, audioQuery: audioQuery);
      if (bytes != null && bytes.isNotEmpty) {
        final result = await extract(MemoryImage(bytes));
        _store(cacheKey, result);
        return result;
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
    if (url == null || url.isEmpty) return CoverColorResult.defaultResult;
    final key = 'url:$url';
    final cached = _cached(key);
    if (cached != null) return cached;
    final provider = await _providerForUrl(url);
    if (provider == null) return CoverColorResult.defaultResult;
    return extract(provider, cacheKey: key);
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

// ---------------------------------------------------------------- 取色 isolate

class _ColorExtractionRequest {
  const _ColorExtractionRequest(this.id, this.rgba);

  final int id;
  final Uint8List rgba;
}

class _ColorExtractionResponse {
  const _ColorExtractionResponse(this.id, this.argb, this.colorfulness);

  final int id;
  final int argb;
  final double colorfulness;
}

/// 常驻的取色 isolate。
///
/// 取色在切歌、返回页面、背景层重建时很频繁，`compute()` 每次都要新起一个
/// isolate（一次完整堆拷贝），开销比算色本身还大；这里让 isolate 一直活着，
/// 只把 RGBA 字节发进去算。
class _ColorWorker {
  _ColorWorker._();

  static final _ColorWorker instance = _ColorWorker._();

  final ReceivePort _responses = ReceivePort();
  final Map<int, Completer<(int, double)>> _pending = {};

  Isolate? _isolate;
  SendPort? _requests;
  Completer<void>? _ready;
  int _nextId = 0;

  Future<(int, double)> extract(Uint8List rgba) async {
    final requests = await _ensureStarted();
    if (requests == null) {
      // isolate 不可用（Web / 启动失败）：退回当前线程直接算，
      // 128px 的图最多几十毫秒，总比拿不到颜色好。
      return _extractDominantColor(rgba);
    }

    final id = _nextId++;
    final completer = Completer<(int, double)>();
    _pending[id] = completer;
    try {
      requests.send(_ColorExtractionRequest(id, rgba));
      return await completer.future.timeout(const Duration(seconds: 10));
    } catch (_) {
      return _extractDominantColor(rgba);
    } finally {
      _pending.remove(id);
    }
  }

  Future<SendPort?> _ensureStarted() async {
    final existing = _requests;
    if (existing != null) return existing;

    final pendingReady = _ready;
    if (pendingReady != null) {
      await pendingReady.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () {},
      );
      return _requests;
    }

    final ready = Completer<void>();
    _ready = ready;
    try {
      _responses.listen(_handleResponse);
      _isolate = await Isolate.spawn(
        _colorWorkerMain,
        _responses.sendPort,
        debugName: 'cover-color',
      );
    } catch (_) {
      _ready = null;
      return null;
    }

    try {
      await ready.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      // 端口没送回来：下次调用重新起一个。
      _ready = null;
      _isolate?.kill(priority: Isolate.immediate);
      _isolate = null;
      return null;
    }
    return _requests;
  }

  void _handleResponse(dynamic message) {
    if (message is SendPort) {
      _requests = message;
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    if (message is _ColorExtractionResponse) {
      _pending
          .remove(message.id)
          ?.complete((message.argb, message.colorfulness));
    }
  }
}

void _colorWorkerMain(SendPort responses) {
  final requests = ReceivePort();
  responses.send(requests.sendPort);
  requests.listen((message) {
    if (message is! _ColorExtractionRequest) return;
    final (argb, colorfulness) = _extractDominantColor(message.rgba);
    responses.send(_ColorExtractionResponse(message.id, argb, colorfulness));
  });
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
