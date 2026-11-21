import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../core/theme/theme_provider.dart';
import '../features/player/application/playback_controller.dart';
import '../features/player/domain/models/song.dart';
import '../features/player/domain/services/cover_color_extractor.dart';
import '../features/settings/application/appearance_providers.dart';
import '../shared/widgets/background_dither_layer.dart';
import '../shared/widgets/background_glow_layer.dart';
import '../shared/widgets/music_cover_image.dart';
import 'background_blur_renderer.dart';

/// 背景层上一次真正显示出来的封面（歌曲 + 原始图片字节）。
///
/// 只记「哪首歌」不够：切歌时新封面还没下来，背景要保持画面完全不动，就得
/// 把上一张图的字节直接留着画，而不是让各层再去磁盘 / 网络取一遍。
/// 放在全局 provider 里还顺便解决了主界面、二级页转场副本各有一份背景层、
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
      final image = ref.watch(blurBackgroundImagePathProvider).valueOrNull;
      // 取色结果（主色 + 色彩浓度）直接从 FutureProvider 读：启动时等它
      // 就绪再建烘焙层，保证第一次烘焙用的就是最终参数（自动压暗 / 饱和度
      // 衰减），temp\background_render 里不会出现「先按过渡参数烤一张、
      // 几十毫秒后再重烤一张」的中间产物。
      final tintAsync = ref.watch(blurBackgroundTintProvider);
      final tint = tintAsync.valueOrNull;
      // 模糊程度 / 亮度就是「设置 → 外观设置 → 高斯模糊背景图」里那两个滑条
      // （没动过时是默认值 40 / 0.3）。封面糊化背景也用这两个值，用户在设置里
      // 调完能直接看到主界面跟着变。
      final sigma = ref.watch(blurBackgroundSigmaProvider);
      final brightness = ref.watch(blurBackgroundBrightnessProvider);
      // 饱和度是「外观设置 → 背景颜色」里的全局滑条（渐变模式也生效），
      // 用户图与封面糊化背景共用（封面糊化本质也是同一张图铺满）。
      final saturation = ref.watch(backgroundSaturationProvider);
      // 图片本身很灰 / 很暗（黑白图、暗图）时饱和度调整自动减弱：这类图上
      // 硬拉饱和度只会把压缩噪点、色斑放大。封面那层按自己那张图的浓度算
      // （随图记录在 [_CoverBackdrop] 里），这里只算兜底背景（用户图）。
      final imageSaturation = effectiveBlurSaturation(
        saturation,
        tint?.colorfulness ?? 1,
      );
      // 浅色主题下正文是深色，照片太暗就看不清字，额外盖一层白纱。
      final lighten = ref.watch(isLightThemeActiveProvider);
      // 亮图自动压暗：按当前背景图的平均亮度补一层黑，越亮压得越多。
      // 用取色结果的亮度（取色算法给的就是跳过极暗 / 极亮像素后的平均色）。
      final autoDarkenStrength = ref.watch(blurBackgroundAutoDarkenProvider);
      // 兜底背景铺的是用户自己的模糊图，压暗也按那张图的亮度算（不能拿封面
      // 主色来压，两张图亮度可能差很远）。
      final tintColor = tint?.color;
      // 浅色主题不压暗：它的正文是深色，压暗会和上面那层白纱互相抵消，
      // 把「亮度 100%」直接吃掉。深色主题才需要压暗来保住白字。
      final autoDarken = (lighten || tintColor == null)
          ? 0.0
          : blurAutoDarkenAlpha(
              luminance: tintColor.computeLuminance(),
              strength: autoDarkenStrength,
            );

      // 没有图时退回渐变：主界面不能空着。
      final Widget fallback;
      if (image == null) {
        fallback = const _GradientBackground();
      } else if (tintAsync is AsyncLoading) {
        // 取色还没算完：只铺底色，不建烘焙层。等它就绪后key/参数都是
        // 最终值，直接读盘上的成品图（没有就现烤一张最终效果）。
        fallback = const ColoredBox(color: Color(0xFF101012));
      } else {
        final path = image.path;
        // 背景图（用户选的 / 内置的）连同模糊、亮度、饱和度、白纱一起烤成
        // 位图：拖动 / 缩放窗口时只是缩放这张贴图，不必每帧重算整窗模糊。
        // 成品留在 `temp\background_render`，下次启动直接读。
        fallback = BakedBlurBackdrop(
          image: ResizeImage(
            FileImage(File(path)),
            width: _kBlurDecodeWidth,
            allowUpscaling: false,
          ),
          // 相对路径标识（文件名 + 修改时间）：换安装目录后同一张图的
          // key 不变；同名替换 / 编辑图片后 key 变，旧成品图不会误命中。
          sourceKey: 'file:${p.basename(path)}|${image.modifiedMs}',
          style: BackdropStyle(
            sigma: sigma,
            brightness: brightness,
            saturation: imageSaturation,
            lighten: lighten,
            autoDarken: autoDarken,
          ),
          baseColor: const Color(0xFF101012),
          // 图片坏了就当没有：底下铺的纯色还在，不会白屏。
          errorBuilder: (_, error, _) => const SizedBox.shrink(),
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
/// 「上一张封面」记在 provider 里而不是本组件的 State 里：主界面 / 二级页
/// 转场副本任意一层背景重建，都能立刻拿到同一张图，不用重新加载。
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
  /// 主界面 / 二级页转场副本各有一层背景，同一份字节会被回调好几次；按
  /// 「封面 key + 字节身份」缓存，编辑标签换了封面字节也能重新算。
  static const int _maxCoverAnalyses = 96;
  static final Map<String, Future<CoverColorResult>> _coverAnalyses = {};

  /// 取色结果按 key 复用；命中时挪到末尾，超过上限淘汰最久没用的，
  /// 避免长听后这张表只增不减（底层取色器自己有 96 条 LRU，这层以前没有）。
  static Future<CoverColorResult> _coverAnalysis(String key, Uint8List bytes) {
    final cached = _coverAnalyses.remove(key);
    if (cached != null) {
      _coverAnalyses[key] = cached;
      return cached;
    }
    final future = CoverColorExtractor.extract(
      ResizeImage(
        MemoryImage(bytes),
        width: _kCoverAnalysisWidth,
        allowUpscaling: false,
      ),
    );
    _coverAnalyses[key] = future;
    while (_coverAnalyses.length > _maxCoverAnalyses) {
      _coverAnalyses.remove(_coverAnalyses.keys.first);
    }
    return future;
  }

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

    final analysis = _coverAnalysis('$key#${identityHashCode(bytes)}', bytes);
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

  /// 封面字节 → 烘焙好的背景（模糊 + 饱和度 + 自动压暗一起烤）。
  ///
  /// `sourceKey` 带字节身份：编辑标签换了封面字节时 key 也会变，不会拿旧图。
  /// `persist: false`：封面随歌变，成品图只在内存里共享，不写
  /// `temp\background_render`（那个目录只放用户背景图的成品，启动直接读）。
  Widget _coverBackdrop(
    _CoverBackdrop record, {
    required double saturation,
    required double autoDarken,
  }) {
    return BakedBlurBackdrop(
      key: const ValueKey<String>('cover-backdrop'),
      image: ResizeImage(
        MemoryImage(record.bytes),
        width: _kCoverDecodeWidth,
        allowUpscaling: false,
      ),
      sourceKey:
          'cover:${_coverKey(record.song)}#${identityHashCode(record.bytes)}',
      style: BackdropStyle(
        sigma: widget.sigma,
        brightness: widget.brightness,
        saturation: saturation,
        lighten: widget.lightenForLightTheme,
        autoDarken: autoDarken,
      ),
      // 底下已经有兜底背景了，不要再铺一层不透明底色。
      persist: false,
    );
  }

  /// 当前歌的封面：只负责加载，算好色彩参数写进记录后才露出来。
  Widget _loadCurrentCover(Song song) {
    return MusicCoverImage(
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
    );
  }

  /// 上一张封面：字节直接画。和 [MusicCoverImage] 里那张共用同一份解码缓存，
  /// 不会出现「重新解码 / 重新下载」的空窗，切歌瞬间画面是静止的。
  ///
  /// 饱和度和自动压暗按这张图自己的色彩浓度 / 平均亮度算，用的都是记录里
  /// 早就备好的值，所以它一露出来就是最终效果。
  Widget _frozenCover(_CoverBackdrop record) {
    return _coverBackdrop(
      record,
      saturation: effectiveBlurSaturation(
        ref.watch(backgroundSaturationProvider),
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
        // 冻结的封面已经铺满整屏时，兜底背景被整块盖住，索性不建：兜底往往
        // 也是一整屏背景（用户的模糊图），建出来就多烤一张、多占一份内存。
        if (record == null) widget.fallback,
        // 当前歌的封面在下面悄悄加载 + 算色彩参数：写进记录后才由冻结层
        // 按最终效果画出来。这层本身始终不绘制，省一次整屏绘制。
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
