import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/theme/theme_provider.dart';
import '../features/player/application/playback_controller.dart';
import '../features/player/domain/models/song.dart';
import '../features/player/domain/services/cover_color_extractor.dart';
import '../shared/widgets/background_dither_layer.dart';
import '../shared/widgets/background_glow_layer.dart';
import '../shared/widgets/music_cover_image.dart';

/// 背景层上一次真正显示出来的封面（歌曲 + 原始图片字节）。
///
/// 只记「哪首歌」不够：切歌时新封面还没下来，背景要保持画面完全不动，就得
/// 把上一张图的字节直接留着画，而不是让各层再去磁盘 / 网络取一遍。
/// 放在全局 provider 里还顺便解决了主界面、二级页、播放页各有一份背景层、
/// 新建的那层拿不到上一张图的问题。
class _CoverBackdrop {
  const _CoverBackdrop(
    this.song,
    this.bytes, {
    required this.colorfulness,
    required this.dominantColor,
  });

  final Song song;
  final Uint8List bytes;

  /// 这张图自身的色彩浓度（见 [effectiveBlurSaturation]）与平均主色。
  ///
  /// 在图片成为背景**之前**就算好一起带着走：切歌时饱和度和自动压暗直接
  /// 按新图的参数生效，不会先按上一首的参数铺上去再变一次。
  final double colorfulness;
  final Color dominantColor;
}

final _lastCoverBackdropProvider = StateProvider<_CoverBackdrop?>(
  (ref) => null,
);

/// 主界面背景层：按「背景颜色模式」画渐变（+ 光晕）或高斯模糊图。
///
/// 全局那层背景（`MaterialApp.builder`）和二级页面自己那份背景都用它，
/// 两边必须完全一致，否则页面滑入 / 滑出时会看出「背景在跳」。
class AppBackgroundLayer extends ConsumerWidget {
  const AppBackgroundLayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(backgroundModeProvider) == BackgroundMode.blur) {
      final path = ref.watch(blurBackgroundImagePathProvider).valueOrNull;
      // 模糊程度 / 亮度就是「设置 → 外观设置 → 高斯模糊背景图」里那两个滑条
      // （没动过时是默认值 30 / 0.85）。封面糊化背景也用这两个值，用户在设置里
      // 调完能直接看到主界面跟着变。
      final sigma = ref.watch(blurBackgroundSigmaProvider);
      final brightness = ref.watch(blurBackgroundBrightnessProvider);
      // 饱和度 / 亮度都是「设置 → 高斯模糊背景图」里的滑条，用户图与封面
      // 糊化背景共用（封面糊化本质也是同一张图铺满）。
      final saturation = ref.watch(blurBackgroundSaturationProvider);
      // 图片本身很灰 / 很暗（黑白图、暗图）时饱和度调整自动减弱：这类图上
      // 硬拉饱和度只会把压缩噪点、色斑放大。封面那层按自己那张图的浓度算
      // （随图记录在 [_CoverBackdrop] 里），这里只算兜底背景（用户图）。
      final imageSaturation = effectiveBlurSaturation(
        saturation,
        ref.watch(backgroundBlurColorfulnessProvider),
      );
      // 浅色主题下正文是深色，照片太暗就看不清字，额外盖一层白纱。
      final lighten = ref.watch(isLightThemeActiveProvider);
      // 亮图自动压暗：按当前背景图的平均亮度补一层黑，越亮压得越多。
      // 用取色结果的亮度（取色算法给的就是跳过极暗 / 极亮像素后的平均色）。
      final autoDarkenStrength = ref.watch(blurBackgroundAutoDarkenProvider);
      // 兜底背景铺的是用户自己的模糊图，压暗也按那张图的亮度算（不能拿封面
      // 主色来压，两张图亮度可能差很远）。
      final imageTint = ref.watch(backgroundBlurTintProvider);
      final autoDarken = imageTint == null
          ? 0.0
          : blurAutoDarkenAlpha(
              luminance: imageTint.computeLuminance(),
              strength: autoDarkenStrength,
            );

      // 没有图时退回渐变：主界面不能空着。
      final Widget fallback;
      if (path == null) {
        fallback = const _GradientBackground();
      } else {
        fallback = _BlurBackground(
          baseColor: const Color(0xFF101012),
          image: Image.file(
            File(path),
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            cacheWidth: _kBlurDecodeWidth,
            gaplessPlayback: true,
            // 图片坏了就当没有：底下铺的纯色还在，不会白屏。
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
          sigma: sigma,
          brightness: brightness,
          saturation: imageSaturation,
          lightenForLightTheme: lighten,
          autoDarken: autoDarken,
        );
      }

      // 「主界面跟随封面变色」在高斯模糊模式下：背景直接用当前歌曲封面糊化。
      if (ref.watch(coverBlurBackdropEnabledProvider)) {
        // 订阅身份而不是 currentSong：同一首歌换清晰度时封面地址会变，
        // 而 Song 的 == 只比 id，订阅 currentSong 收不到这次变化。
        ref.watch(currentSongIdentityProvider);
        final song = ref.read(playbackControllerProvider).currentSong;
        if (song != null) {
          return _CoverBlurBackground(
            song: song,
            sigma: sigma,
            brightness: brightness,
            lightenForLightTheme: lighten,
            // 封面还在下载 / 这首歌根本没封面时，就用它兜着。
            fallback: fallback,
          );
        }
      }
      return fallback;
    }
    return const _GradientBackground();
  }
}

/// 背景渐变那套：渐变 + 光晕 + 抖动噪点（原来的全局背景就是这个）。
class _GradientBackground extends ConsumerWidget {
  const _GradientBackground();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final gradient = ref.watch(backgroundGradientProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        // 1 秒过渡：换颜色 / 换主题时不会「啪」地跳一下。
        AnimatedContainer(
          duration: const Duration(seconds: 1),
          curve: Curves.easeInOut,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: gradient.begin,
              end: gradient.end,
              colors: gradient.colors,
            ),
          ),
        ),
        BackgroundGlowLayer(
          colors: gradient.colors,
          count: gradient.glowCount,
          seed: ref.watch(backgroundGlowSeedProvider),
        ),
        // 打散渐变 / 光晕在 8 位色深下的色带。
        const BackgroundDitherLayer(),
      ],
    );
  }
}

/// 「当前歌曲封面糊化」背景。
///
/// 封面走 [MusicCoverImage] 那条链路（在线地址 / 本地缓存 / 音频内嵌封面都
/// 能取到）。切歌时**画面不动**：新歌封面在下面悄悄加载，字节到了之后先算
/// 色彩浓度 / 主色，再整体写进 [_lastCoverBackdropProvider]，背景才换一次
/// 且饱和度、自动压暗已是最终值。从未取到过封面时退回 [fallback]（用户
/// 添加的模糊图 / 渐变）。
///
/// 「上一张封面」记在 provider 里而不是本组件的 State 里：主界面 / 二级页 /
/// 播放页任意一层背景重建，都能立刻拿到同一张图，不用重新加载。
class _CoverBlurBackground extends ConsumerStatefulWidget {
  const _CoverBlurBackground({
    required this.song,
    required this.sigma,
    required this.brightness,
    required this.lightenForLightTheme,
    required this.fallback,
  });

  final Song song;
  final double sigma;
  final double brightness;
  final bool lightenForLightTheme;

  /// 兜底背景（用户的模糊图 / 渐变）。
  final Widget fallback;

  @override
  ConsumerState<_CoverBlurBackground> createState() =>
      _CoverBlurBackgroundState();
}

class _CoverBlurBackgroundState extends ConsumerState<_CoverBlurBackground> {
  static bool _hasCoverSource(Song song) =>
      (song.coverUrl?.isNotEmpty ?? false) ||
      song.isLocal ||
      song.mediaStoreId != null ||
      // 下载下来的在线歌曲：source 还是平台名，封面存在文件 / 封面缓存里。
      (song.filePath?.isNotEmpty ?? false);

  /// 判断「是不是同一张封面」用的 key：换清晰度会换封面地址，但歌没变。
  static String _coverKey(Song song) =>
      '${song.coverUrl}|${song.mediaStoreId}|${song.filePath}|${song.id}';

  /// 已经分析过的封面：浓度 / 主色只算一次。
  ///
  /// 主界面 / 二级页 / 播放页各有一层背景，同一份字节会被回调好几次；按
  /// 「封面 key + 字节身份」缓存，编辑标签换了封面字节也能重新算。
  static final Map<String, Future<CoverColorResult>> _coverAnalyses = {};

  /// 这张封面已经真的加载出来可以显示了：从这一刻起背景才切到它。
  ///
  /// 先按字节把色彩浓度和主色算出来再写进记录：饱和度和自动压暗跟着图
  /// 一起生效。否则会先按上一首封面的参数铺上去，等取色结果回来再变一次
  /// ——切歌时肉眼能看到「先正常、再变淡」两个阶段。
  Future<void> _remember(Song song, Uint8List bytes) async {
    if (!mounted) return;
    final key = _coverKey(song);
    // 只记当前正在播的这首：切歌瞬间别的背景层可能送来上一首的迟到回调。
    final current = ref.read(playbackControllerProvider).currentSong;
    if (current == null || _coverKey(current) != key) return;
    var record = ref.read(_lastCoverBackdropProvider);
    // 同一张图、同一份字节：已经记过（编辑标签换了封面字节则继续往下走）。
    if (record != null &&
        _coverKey(record.song) == key &&
        identical(record.bytes, bytes)) {
      return;
    }

    final analysis =
        _coverAnalyses['$key#${identityHashCode(bytes)}'] ??= CoverColorExtractor
            .extract(
              ResizeImage(
                MemoryImage(bytes),
                width: _kCoverAnalysisWidth,
                allowUpscaling: false,
              ),
            );
    final result = await analysis;

    if (!mounted) return;
    // 分析期间可能已经切歌：过期结果不能盖掉更新的封面。
    final latest = ref.read(playbackControllerProvider).currentSong;
    if (latest == null || _coverKey(latest) != key) return;
    record = ref.read(_lastCoverBackdropProvider);
    // 别的背景层先记上了同一份字节：不用再写。
    if (record != null &&
        _coverKey(record.song) == key &&
        identical(record.bytes, bytes)) {
      return;
    }
    ref.read(_lastCoverBackdropProvider.notifier).state = _CoverBackdrop(
      song,
      bytes,
      colorfulness: result.colorfulness,
      dominantColor: result.dominantColor,
    );
  }

  Widget _blurImage(
    Widget image, {
    Key? key,
    required double saturation,
    required double autoDarken,
  }) {
    return _BlurBackground(
      key: key,
      // 底下已经有兜底背景了，不要再铺一层不透明底色。
      baseColor: null,
      image: image,
      sigma: widget.sigma,
      brightness: widget.brightness,
      saturation: saturation,
      lightenForLightTheme: widget.lightenForLightTheme,
      autoDarken: autoDarken,
    );
  }

  /// 当前歌的封面：只负责加载，算好色彩参数写进记录后才露出来。
  Widget _loadCurrentCover(Song song) {
    return _blurImage(
      MusicCoverImage(
        // 换封面换 key：上一首的字节不能带过来（切歌瞬间会闪一下旧封面）。
        key: ValueKey<String>(_coverKey(song)),
        url: song.coverUrl,
        songId: song.id,
        mediaStoreId: song.mediaStoreId,
        filePath: song.filePath,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: _kCoverDecodeWidth,
        filterQuality: FilterQuality.low,
        // 取不到图时不留占位图标：让下面那层兜底背景透出来。
        errorWidget: const SizedBox.shrink(),
        onLoaded: (bytes) => _remember(song, bytes),
      ),
      key: const ValueKey<String>('cover-loading'),
      // 这层只用来加载字节（始终不绘制），参数取中性值。
      saturation: 1,
      autoDarken: 0,
    );
  }

  /// 上一张封面：字节直接画。和 [MusicCoverImage] 里那张共用同一份解码缓存，
  /// 不会出现「重新解码 / 重新下载」的空窗，切歌瞬间画面是静止的。
  ///
  /// 饱和度和自动压暗按这张图自己的色彩浓度 / 平均亮度算，用的都是记录里
  /// 早就备好的值，所以它一露出来就是最终效果。
  Widget _frozenCover(_CoverBackdrop record) {
    return _blurImage(
      Image.memory(
        record.bytes,
        fit: BoxFit.cover,
        width: double.infinity,
        height: double.infinity,
        cacheWidth: _kCoverDecodeWidth,
        gaplessPlayback: true,
        filterQuality: FilterQuality.low,
      ),
      key: const ValueKey<String>('cover-frozen'),
      saturation: effectiveBlurSaturation(
        ref.watch(blurBackgroundSaturationProvider),
        record.colorfulness,
      ),
      autoDarken: blurAutoDarkenAlpha(
        luminance: record.dominantColor.computeLuminance(),
        strength: ref.watch(blurBackgroundAutoDarkenProvider),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final record = ref.watch(_lastCoverBackdropProvider);
    final showCurrent = _hasCoverSource(song);

    // 从没取到过封面：直接退回兜底（用户的图 / 渐变）。
    if (record == null && !showCurrent) return widget.fallback;

    return Stack(
      fit: StackFit.expand,
      children: [
        // 冻结的封面已经铺满整屏时，兜底背景被整块盖住，不用再画：兜底往往
        // 也是一整屏模糊（用户的模糊图），每新建一层背景就白糊一遍。
        Offstage(offstage: record != null, child: widget.fallback),
        // 当前歌的封面在下面悄悄加载 + 算色彩参数：写进记录后才由冻结层
        // 按最终效果画出来。这层本身始终不绘制，省一次全屏模糊。
        if (showCurrent) Offstage(child: _loadCurrentCover(song)),
        // 上一张封面压在最上面：新封面没处理完之前画面一动不动。
        if (record != null) _frozenCover(record),
      ],
    );
  }
}

/// 解码宽度：模糊会把细节全抹平，按屏幕宽度解一张大图纯属浪费内存。
/// 800 已经够铺满手机屏（再细的细节都被 blur 抹掉了），比 1080 省约 45%。
const int _kBlurDecodeWidth = 800;

/// 封面本来就不大（常见 500~1000），糊化后再降一档：512 只有 720 的一半内存，
/// 糊出来肉眼没有区别。
const int _kCoverDecodeWidth = 512;

/// 算封面色彩浓度 / 平均主色时解码的宽度：只要整张图的色调，96px 足够，
/// 解码代价也比原图小得多。
const int _kCoverAnalysisWidth = 96;

/// 高斯模糊背景：图片 → 模糊 → 叠亮度 → 噪点。
class _BlurBackground extends StatelessWidget {
  const _BlurBackground({
    super.key,
    required this.image,
    required this.sigma,
    required this.brightness,
    required this.saturation,
    required this.lightenForLightTheme,
    required this.autoDarken,
    required this.baseColor,
  });

  /// 要糊化的图（用户选的图片，或当前歌曲封面）。
  final Widget image;

  final double sigma;

  /// 1 = 原图；小于 1 压暗，大于 1 提亮。
  final double brightness;

  /// 饱和度：1 = 原图，0 = 灰度（见 [blurSaturationMatrix]）。
  final double saturation;

  /// 浅色主题是否额外盖一层白纱（深色文字压在暗背景上会看不清）。
  final bool lightenForLightTheme;

  /// 亮图自动压暗的黑色不透明度（见 [blurAutoDarkenAlpha]）。
  final double autoDarken;

  /// 图片下面铺的底色；为 null 表示「底下已有背景」，不铺（否则会盖住兜底背景）。
  final Color? baseColor;

  @override
  Widget build(BuildContext context) {
    final blurSigma = sigma.clamp(0.0, 60.0);
    // 模糊会让图片边缘向内发虚，稍微放大一点把发虚的边推到屏幕外。
    final scale = blurSigma <= 0.5 ? 1.0 : 1.0 + blurSigma / 120;

    final normalized = brightness.clamp(0.2, 1.4);
    final darken = normalized < 1 ? (1 - normalized) : 0.0;
    final whiten = normalized > 1 ? (normalized - 1) * 0.6 : 0.0;

    // 饱和度先作用在图上，再模糊 / 叠亮度：颜色收回来之后模糊出来的色块
    // 也不会整片过浓。1 = 原图时连滤镜都不包，省一次渲染。
    final sat = saturation.clamp(0.0, 2.0);
    final source = sat == 1.0
        ? image
        : ColorFiltered(
            colorFilter: ColorFilter.matrix(blurSaturationMatrix(sat)),
            child: image,
          );

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 图片加载出来之前、或解码失败时的底色。
          if (baseColor != null) ColoredBox(color: baseColor!),
          if (blurSigma <= 0.5)
            Transform.scale(scale: scale, child: source)
          else
            ImageFiltered(
              imageFilter: ui.ImageFilter.blur(
                sigmaX: blurSigma,
                sigmaY: blurSigma,
              ),
              child: Transform.scale(scale: scale, child: source),
            ),
          // 浅色主题：正文是深色，先把图整体提亮，否则暗照片上根本看不清字。
          if (lightenForLightTheme)
            ColoredBox(color: Colors.white.withValues(alpha: 0.35)),
          if (darken > 0)
            ColoredBox(color: Colors.black.withValues(alpha: darken)),
          if (whiten > 0)
            ColoredBox(color: Colors.white.withValues(alpha: whiten)),
          // 亮图自动压暗：放在固定亮度之后，按图片本身的亮度补压。
          if (autoDarken > 0)
            ColoredBox(color: Colors.black.withValues(alpha: autoDarken)),
          // 与渐变背景一样做一层抖动，避免大面积纯色出现色带。
          const BackgroundDitherLayer(),
        ],
      ),
    );
  }
}
