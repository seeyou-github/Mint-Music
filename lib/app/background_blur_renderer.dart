import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../core/platform/app_paths.dart';
import '../core/theme/background_mode.dart';
import '../shared/widgets/background_dither_layer.dart';

/// 背景烘焙算法版本。
///
/// 叠色顺序、模糊换算这些改了就 +1：`temp\background_render` 里按旧算法烤出来
/// 的图会直接失效重算，否则用户会一直看到改动前的效果。
const int kBackdropRenderVersion = 1;

/// 一次背景烘焙的「除原图以外」的参数。
///
/// 全部来自「设置 → 外观设置」：模糊 / 亮度两个滑条、全局饱和度、浅色主题的
/// 白纱、亮图自动压暗。这些值加上原图，唯一决定最终画面。
@immutable
class BackdropStyle {
  const BackdropStyle({
    required this.sigma,
    required this.brightness,
    required this.saturation,
    required this.lighten,
    required this.autoDarken,
  });

  /// 视觉模糊半径（窗口逻辑像素）。
  final double sigma;

  /// 1 = 原图；小于 1 压暗，大于 1 提亮。
  final double brightness;

  /// 饱和度：1 = 原图，0 = 灰度。
  final double saturation;

  /// 浅色主题额外盖一层白纱（深色文字压在暗背景上看不清）。
  final bool lighten;

  /// 亮图自动压暗的黑色不透明度。
  final double autoDarken;

  /// 进缓存 key 的字符串（保留小数位，避免浮点尾数把同一档参数拆成多份）。
  String get signature =>
      's${sigma.toStringAsFixed(1)}'
      'b${brightness.toStringAsFixed(2)}'
      't${saturation.toStringAsFixed(2)}'
      'l${lighten ? 1 : 0}'
      'd${autoDarken.toStringAsFixed(3)}';

  /// 需要叠在图片上的颜色，从下到上（与旧的 `_BlurBackground` 完全一致）。
  ///
  /// 不模糊的路径直接把这几层画成 [ColoredBox]；烘焙路径用同一份列表往画布上
  /// 填色。两条路共用一个来源，不会出现「模糊和不模糊差了 5% 亮度」。
  List<Color> get overlays {
    final normalized = brightness.clamp(0.2, 1.4);
    final darken = normalized < 1 ? (1 - normalized) : 0.0;
    final whiten = normalized > 1 ? (normalized - 1) * 0.6 : 0.0;
    return [
      if (lighten) const Color(0x59FFFFFF),
      if (darken > 0) Color.fromRGBO(0, 0, 0, darken),
      if (whiten > 0) Color.fromRGBO(255, 255, 255, whiten),
      if (autoDarken > 0) Color.fromRGBO(0, 0, 0, autoDarken.clamp(0.0, 1.0)),
    ];
  }
}

/// 把「原图 → 覆盖率裁剪 → 模糊 → 饱和度 → 亮度 / 白纱 / 自动压暗」一次性
/// 烤成一张位图。
///
/// 为什么不在树上直接 `ImageFiltered`：它的代价与窗口像素数成正比，而窗口被
/// 拖动 / 缩放时尺寸每帧都在变，等于每帧重算一张整窗模糊（`mint_music.log`
/// 的 `[Perf] 掉帧` 里单次 **250~410ms** 的 raster 峰值就是它）。烤成位图之后，
/// 拖动期间只是把这张贴图缩放一下，模糊照旧在，代价接近 0。
///
/// [pixelScale] 是「位图宽度 / 目标逻辑宽度」：sigma 是按逻辑像素给的，位图
/// 分辨率更低，模糊半径要按同一比例换算，否则画面尺寸一变模糊程度就跟着变。
/// 目标逻辑宽度取的是**显示器**宽（见 `_BakedBlurBackdropState._bakeTargetSize`），
/// 所以全屏时模糊量与设置值一致，窗口更小时整张图（含模糊）等比缩小。
Future<ui.Image> renderBackdrop({
  required ui.Image source,
  required int width,
  required int height,
  required BackdropStyle style,
  required double pixelScale,
}) async {
  final recorder = ui.PictureRecorder();
  final bounds = ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble());
  // cullRect 只是裁剪提示，真正的输出尺寸由 toImage 决定。
  final canvas = ui.Canvas(recorder, bounds);

  final sigma = (style.sigma * pixelScale).clamp(0.0, 120.0);
  // 模糊会把图片边缘向内发虚：图片必须比画布大出至少几个 σ，否则四边会透出
  // 一圈「虚边」（也就是模糊采样到了画布外面）。
  final margin = sigma <= 0.5 ? 0.0 : sigma * 4;
  final zoom = 1 + (2 * margin) / math.min(width, height);

  final srcW = source.width.toDouble();
  final srcH = source.height.toDouble();
  if (srcW <= 0 || srcH <= 0) {
    throw StateError('原图尺寸异常: ${source.width}x${source.height}');
  }
  // BoxFit.cover：取较大的缩放比，短边铺满，长边溢出后由画布裁掉。
  final scale = math.max(width * zoom / srcW, height * zoom / srcH);
  final dst = ui.Rect.fromCenter(
    center: bounds.center,
    width: srcW * scale,
    height: srcH * scale,
  );

  final paint = ui.Paint()..filterQuality = ui.FilterQuality.low;
  if (sigma > 0.5) {
    // tileMode.clamp：模糊采样越过图片边缘时沿用边缘像素，不会出现透明 / 发黑
    // 的虚边（图片本来就是放大后才铺满的，正常也看不到边缘）。
    paint.imageFilter = ui.ImageFilter.blur(
      sigmaX: sigma,
      sigmaY: sigma,
      tileMode: ui.TileMode.clamp,
    );
  }
  final saturation = style.saturation.clamp(0.0, 2.0);
  if ((saturation - 1.0).abs() > 0.01) {
    // 饱和度矩阵和模糊都是线性运算，先后顺序不影响结果，放在同一个 Paint 里
    // 一次画完最省事（不必额外开一层 saveLayer）。
    paint.colorFilter = ColorFilter.matrix(blurSaturationMatrix(saturation));
  }

  canvas.drawImageRect(source, ui.Rect.fromLTWH(0, 0, srcW, srcH), dst, paint);
  for (final color in style.overlays) {
    canvas.drawRect(bounds, ui.Paint()..color = color);
  }

  final picture = recorder.endRecording();
  try {
    return await picture.toImage(width, height);
  } finally {
    picture.dispose();
  }
}

/// 烘焙结果的磁盘缓存（`AppData\temp\background_render`）。
///
/// 目的只有一个：**下次启动不用再算一遍**。命中时读一张 PNG 直接显示，比重新
/// 解码原图 + 模糊快；用户改背景图 / 调滑条后 key 变了自然重算。
///
/// 目录里**始终只保留一张**：key 变了就重烤并立刻清掉旧文件，不搞淘汰池
/// （这个目录是给用户看的，里面堆一堆历史参数的旧图没有意义）。
///
/// 放在 temp 下不给用户看：它纯粹是派生数据，删掉也只是下次启动多算一次。
class BackdropDiskCache {
  const BackdropDiskCache._();

  static const String _folderName = 'background_render';

  static Future<Directory?> _dir() async {
    try {
      final temp = await AppPaths.tempDirectory();
      final dir = Directory(p.join(temp.path, _folderName));
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _fileFor(String key) async {
    final dir = await _dir();
    if (dir == null) return null;
    return File(p.join(dir.path, 'v$kBackdropRenderVersion-${_hash(key)}.png'));
  }

  /// 读缓存；没有 / 读坏了都返回 null（当作没命中）。
  static Future<ui.Image?> load(String key) async {
    try {
      final file = await _fileFor(key);
      if (file == null || !await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(bytes);
      try {
        final frame = await codec.getNextFrame();
        return frame.image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      // 半截文件 / 版本不匹配：删掉重算，不要让坏缓存一直挂着。
      unawaited(_deleteFor(key));
      return null;
    }
  }

  /// 写缓存（后台进行，失败静默）。**接管 [image] 的生命周期**，写完自己
  /// dispose：编码是异步的，期间这张图可能已被淘汰，调用方给一个 clone 最安全。
  static Future<void> save(String key, ui.Image image) async {
    try {
      final file = await _fileFor(key);
      if (file == null) return;
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
      unawaited(_evictOthers(file));
    } finally {
      image.dispose();
    }
  }

  static Future<void> _deleteFor(String key) async {
    try {
      final file = await _fileFor(key);
      if (file != null && await file.exists()) await file.delete();
    } catch (_) {}
  }

  /// 写完新成品后清场：删掉目录里**其它所有**文件（旧 key 的历史成品），
  /// 保证这个目录里始终只有当前参数的那一张。
  static Future<void> _evictOthers(File newest) async {
    try {
      final dir = await _dir();
      if (dir == null) return;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (entity.path == newest.path) continue;
        try {
          await entity.delete();
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 文件名用的短 hash（FNV-1a 32 位）：key 里有中文路径 / 浮点，直接当文件名
  /// 不合法也太长；碰撞概率在「几十份缓存」这个量级下可以忽略。
  static String _hash(String key) {
    var hash = 0x811c9dc5;
    for (final unit in key.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xffffffff;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }

  /// 清掉所有缓存（备份还原 / 换主题色这类会大量改参数的操作后可用）。
  static Future<void> clear() async {
    try {
      final dir = await _dir();
      if (dir == null) return;
      await dir.delete(recursive: true);
    } catch (_) {}
  }

  /// 调试用：当前缓存占了多少字节。
  @visibleForTesting
  static Future<int> totalBytes() async {
    try {
      final dir = await _dir();
      if (dir == null) return 0;
      var total = 0;
      await for (final entity in dir.list()) {
        if (entity is File) total += await entity.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }
}

/// 进程内共享的烘焙结果。
///
/// 主界面那层背景和每个二级页的 `AppPageBackground` 各有一个
/// [BakedBlurBackdrop]，参数（图 / 窗口尺寸 / 模糊 / 亮度）完全一样。以前它们
/// 会各烤一张：一次渲染 + 一份 2~3MB 位图，切歌时再各烤一次。这里按 key 共享
/// 一份位图，各实例拿 [ui.Image.clone] 的独立句柄——clone 共享底层像素，各自
/// dispose 互不影响，谁先销毁都不会把别人的图弄没。
class _BakedGallery {
  const _BakedGallery._();

  /// 最多留几份：用户背景图 + 当前封面（+ 上一张）就够覆盖常见组合。
  static const int _maxEntries = 3;

  /// key → 位图。Map 的迭代顺序就是插入顺序，`keys.first` 即「最久没用到」。
  static final Map<String, ui.Image> _entries = <String, ui.Image>{};

  /// key → 正在进行的那次烘焙：主界面和二级页同时切到新封面时只算一次。
  static final Map<String, Future<ui.Image?>> _inflight =
      <String, Future<ui.Image?>>{};

  /// 取一张：命中内存直接 clone；否则复用（或发起）一次烘焙再 clone。
  ///
  /// 返回值必须由调用方 dispose —— 它是独立句柄，不影响缓存里的那份。
  /// [persist] 为 false 时跳过磁盘读写，只在内存里共享。
  static Future<ui.Image?> acquire(
    String key, {
    required bool persist,
    required Future<ui.Image?> Function() load,
    required Future<ui.Image> Function() render,
  }) async {
    final hit = _take(key);
    if (hit != null) return _clone(hit);
    final future = _inflight[key] ??= _produce(key, persist, load, render)
        // 注意要写成块：`whenComplete` 会把回调返回的 Future 也 await 掉，
        // 而 `remove` 返回的正是这个正在完成的 Future —— 直接返回会自等死锁。
        .whenComplete(() {
          _inflight.remove(key);
        });
    final image = await future;
    return image == null ? null : _clone(image);
  }

  static Future<ui.Image?> _produce(
    String key,
    bool persist,
    Future<ui.Image?> Function() load,
    Future<ui.Image> Function() render,
  ) async {
    if (persist) {
      final loaded = await load();
      if (loaded != null) {
        _store(key, loaded);
        return loaded;
      }
    }
    final image = await render();
    _store(key, image);
    // 只有现算出来的才需要落盘；磁盘 / 内存命中的本来就在盘上。
    // 传 clone：编码在后台跑，这期间缓存里的那份可能已经被淘汰。
    if (persist) unawaited(BackdropDiskCache.save(key, image.clone()));
    return image;
  }

  /// copy 一个句柄；原图刚被淘汰（极端时序）时退化为 null，走空白背景。
  static ui.Image? _clone(ui.Image image) {
    try {
      return image.clone();
    } catch (_) {
      return null;
    }
  }

  /// 同步看一眼有没有已经烤好的同一张（clone 一个独立句柄，没有就 null）。
  ///
  /// 给「新开的背景层首帧」用：主界面那层通常早就烤好了，二级页打开时直接
  /// 拿来画，第一帧就是模糊背景，不会先露一张没压暗、没饱和的原图再变糊。
  static ui.Image? peek(String key) {
    final hit = _take(key);
    return hit == null ? null : _clone(hit);
  }

  static ui.Image? _take(String key) {
    final image = _entries.remove(key);
    if (image == null) return null;
    _entries[key] = image; // 挪到末尾 = 最近使用
    return image;
  }

  static void _store(String key, ui.Image image) {
    final previous = _entries.remove(key);
    _entries[key] = image;
    // 同一 key 并发烘焙的后到者：旧的那份没人用了（clone 持有者不受影响）。
    if (previous != null && !identical(previous, image)) previous.dispose();
    while (_entries.length > _maxEntries) {
      final evicted = _entries.remove(_entries.keys.first);
      evicted?.dispose();
    }
  }

  static void clear() {
    for (final image in _entries.values) {
      image.dispose();
    }
    _entries.clear();
  }
}

/// 测试入口：直接走一遍共享逻辑（不经过 Widget）。
@visibleForTesting
Future<ui.Image?> debugAcquireBaked({
  required String key,
  bool persist = true,
  required Future<ui.Image?> Function() load,
  required Future<ui.Image> Function() render,
}) => _BakedGallery.acquire(key, persist: persist, load: load, render: render);

/// 测试入口：同步 peek。
@visibleForTesting
ui.Image? debugPeekBaked(String key) => _BakedGallery.peek(key);

/// 测试入口：清空共享缓存。
@visibleForTesting
void debugClearBakedGallery() => _BakedGallery.clear();

/// 背景层：把模糊背景烤成位图再显示。
///
/// * 模糊半径 > 0.5 时走烘焙：窗口拖动 / 缩放期间只是缩放一张贴图，模糊不会
///   消失，也不会每帧重算（这是「拖窗口时背景变成原图」那个降级的替代方案）；
/// * 不模糊（sigma ≤ 0.5）时直接用原图 + 叠色，不降分辨率——那条路径本来就
///   不贵，烤成小图反而会糊。
class BakedBlurBackdrop extends StatefulWidget {
  const BakedBlurBackdrop({
    super.key,
    required this.image,
    required this.sourceKey,
    required this.style,
    this.baseColor,
    this.errorBuilder,
    this.persist = true,
  });

  /// 原图（用户选的背景图 / 当前歌曲封面字节）。
  final ImageProvider image;

  /// 原图标识，进缓存 key：换图（路径 / 字节不同）必然换 key。
  final String sourceKey;

  final BackdropStyle style;

  /// 烘焙结果出来之前铺的底色；为 null 表示「下面还有兜底背景」。
  final Color? baseColor;

  /// 原图解码失败时显示什么（不模糊路径会用到；烘焙路径直接留空）。
  final ImageErrorWidgetBuilder? errorBuilder;

  /// 成品要不要落盘到 `temp\background_render`。
  ///
  /// 只有「用户背景图」这类跨会话不变的图才值得落盘（下次启动直接读）；
  /// 封面糊化背景随歌变，落盘只会污染淘汰池（每次切歌挤掉一张），传 false
  /// 就只在内存共享。传 false 时启动也不会读盘。
  final bool persist;

  @override
  State<BakedBlurBackdrop> createState() => _BakedBlurBackdropState();
}

class _BakedBlurBackdropState extends State<BakedBlurBackdrop> {
  /// 烘焙分辨率相对**显示器**逻辑宽度的比例。背景是糊的，0.55 放大回去看不出
  /// 区别，像素数只有全分辨率的 30%，渲染 + PNG 编码都便宜一截。
  static const double _renderScale = 0.55;

  /// 宽高都按 64 取整：多显示器切换 / 系统缩放变化时尺寸会有 1px 抖动，不取整
  /// 会白烤一张一模一样的图。
  static const int _sizeBucket = 64;

  /// 单张位图的像素上限（约 6.4MB RGBA）。4K 屏按 0.55 直接烤会有 2.5M 像素，
  /// 对一张糊背景来说太奢侈，超出这个上限就等比缩小（1080p / 2K 屏都碰不到）。
  static const double _maxPixels = 1600000;

  /// 参数变化后等这么久再烤：拖滑条的中间状态不烤。
  static const Duration _settleDelay = Duration(milliseconds: 350);

  /// 第一次烘焙（屏幕上还只有底色）用更短的等待，尽早把背景铺上。
  static const Duration _firstBakeDelay = Duration(milliseconds: 80);

  /// 原图（由 Flutter 图片缓存持有，这里只借用，不能 dispose）。
  ui.Image? _source;

  /// 当前显示的烘焙结果（自己烤的，要 dispose）。
  ui.Image? _baked;
  String? _bakedKey;

  /// 正在等的目标 key（参数变了就以最新的为准）。
  String _wantKey = '';

  Timer? _settleTimer;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _listen();
  }

  @override
  void didUpdateWidget(covariant BakedBlurBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    final imageChanged = oldWidget.image != widget.image;
    if (imageChanged) {
      _detach();
      _source = null;
      _listen();
    }
    if (imageChanged ||
        oldWidget.sourceKey != widget.sourceKey ||
        oldWidget.style.signature != widget.style.signature) {
      _schedule();
    }
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    _detach();
    // 显示中的那张是我们自己创建的，必须释放（原图不归我们管）。
    _baked?.dispose();
    super.dispose();
  }

  void _listen() {
    if (_stream != null) return;
    final listener = ImageStreamListener(
      _onImage,
      onError: (Object error, StackTrace? stack) {},
    );
    _stream = widget.image.resolve(createLocalImageConfiguration(context))
      ..addListener(listener);
    _listener = listener;
  }

  void _detach() {
    final stream = _stream;
    final listener = _listener;
    if (stream != null && listener != null) stream.removeListener(listener);
    _stream = null;
    _listener = null;
  }

  void _onImage(ImageInfo info, bool synchronousCall) {
    if (!mounted) return;
    if (identical(_source, info.image)) return;
    if (synchronousCall) {
      // 图已经在缓存里：addListener 会同步回调，此时正处在 didChangeDependencies
      // / didUpdateWidget 里，直接赋值即可（紧接着就要 build），不要 setState。
      _source = info.image;
    } else {
      setState(() => _source = info.image);
    }
    _schedule();
  }

  /// 烘焙目标尺寸：按**所在显示器的逻辑尺寸**定，与窗口大小无关。
  ///
  /// 以前是按窗口尺寸算（每 64px 一档）：拖动窗口每跨一档就得重烤一次整屏
  /// 模糊，正是「调整窗口大小时在 background_render 里重新生成图片」。背景
  /// 本来就是糊的，把位图按窗口缩放肉眼看不出来，所以这里一次算到显示器
  /// 大小，之后窗口怎么拖都只是缩放这张贴图；只有换显示器 / 系统缩放变了
  /// 才会换 key 重烤一次。
  ///
  /// 取不到显示器尺寸（个别平台 / 测试环境）时退回窗口尺寸，至少不会因为
  /// 拿不到尺寸而永远不烤。
  Size? _bakeTargetSize() {
    try {
      final view = View.maybeOf(context);
      final display = view?.display;
      if (view != null && display != null) {
        final dpr = view.devicePixelRatio;
        final size = display.size;
        if (dpr > 0 && size.width > 0 && size.height > 0) {
          return Size(size.width / dpr, size.height / dpr);
        }
      }
    } catch (_) {}
    return MediaQuery.maybeSizeOf(context);
  }

  /// 按当前目标尺寸排一次烘焙（防抖）。可以从 build 里调：只动定时器，不 setState。
  void _schedule() {
    final target = _bakeTargetSize();
    if (target == null || target.width <= 0 || target.height <= 0) return;
    final key = _keyFor(target);
    if (key == _bakedKey) return;
    if (key == _wantKey && _settleTimer != null) return;
    _wantKey = key;
    _settleTimer?.cancel();
    final delay = _baked == null ? _firstBakeDelay : _settleDelay;
    _settleTimer = Timer(delay, () => unawaited(_bake(key, target)));
  }

  /// 先看看同参数的位图是不是已经烤好了（主界面那层烤的）。
  ///
  /// 直接赋值、不 setState：build 里紧接着就要用它。这一步是「打开二级页时
  /// 闪一下未处理原图」的根因修复——二级页是新创建的一层，`_baked` 为空，以前
  /// 只能先画原图等 80ms。换图 / 改参数时同样受益：另一层已经烤好就直接换上，
  /// 不用再等一次磁盘读 + 烘焙。
  void _adoptSharedBackdrop() {
    final target = _bakeTargetSize();
    if (target == null || target.width <= 0 || target.height <= 0) return;
    final key = _keyFor(target);
    if (key == _bakedKey) return;
    final ready = _BakedGallery.peek(key);
    if (ready == null) return;
    final previous = _baked;
    _baked = ready;
    _bakedKey = key;
    _wantKey = key;
    _settleTimer?.cancel();
    _settleTimer = null;
    if (previous != null && !identical(previous, ready)) {
      // 旧图这一帧还会被画一次，等画完再释放。
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  String _keyFor(Size target) {
    final size = _bitmapSizeFor(target);
    return '${widget.sourceKey}|${size.width}x${size.height}|'
        '${widget.style.signature}|v$kBackdropRenderVersion';
  }

  /// 目标尺寸 → 实际位图尺寸（按 [_renderScale] 缩放、按桶取整、限像素上限）。
  ({int width, int height}) _bitmapSizeFor(Size target) {
    var width = _quantize(target.width * _renderScale).toDouble();
    var height = _quantize(target.height * _renderScale).toDouble();
    final pixels = width * height;
    if (pixels > _maxPixels) {
      final scale = math.sqrt(_maxPixels / pixels);
      width *= scale;
      height *= scale;
    }
    return (width: width.round(), height: height.round());
  }

  static int _quantize(double value) {
    final rounded = (value / _sizeBucket).round() * _sizeBucket;
    return rounded.clamp(_sizeBucket * 2, 2560);
  }

  Future<void> _bake(String key, Size target) async {
    _settleTimer = null;
    final source = _source;
    if (source == null) return;
    final size = _bitmapSizeFor(target);
    try {
      final image = await _BakedGallery.acquire(
        key,
        // 磁盘缓存：上次已经烤过的同一组参数直接用。封面这类随会话变的图
        // 不落盘也不读盘（persist = false）。
        persist: widget.persist,
        load: () => BackdropDiskCache.load(key),
        // 现算（一次几十毫秒，只在切图 / 调参数 / 换显示器时发生）。
        render: () => renderBackdrop(
          source: source,
          width: size.width,
          height: size.height,
          style: widget.style,
          pixelScale: size.width / target.width,
        ),
      );
      // acquire 返回的是 clone，参数已经变了就丢掉，避免留下无主句柄。
      if (!mounted || key != _wantKey) {
        image?.dispose();
        return;
      }
      if (image != null) _apply(key, image);
    } catch (_) {}
  }

  void _apply(String key, ui.Image image) {
    final previous = _baked;
    setState(() {
      _baked = image;
      _bakedKey = key;
    });
    if (previous != null && !identical(previous, image)) {
      // 下一帧才会换成新图：旧图等这一帧画完再释放。
      WidgetsBinding.instance.addPostFrameCallback((_) => previous.dispose());
    }
  }

  Widget _rawImage() => Image(
    image: widget.image,
    fit: BoxFit.cover,
    width: double.infinity,
    height: double.infinity,
    gaplessPlayback: true,
    filterQuality: FilterQuality.low,
    errorBuilder: widget.errorBuilder,
  );

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    // 不模糊：直接用原图 + 叠色，不烘焙（否则降分辨率再放大反而糊）。
    if (style.sigma <= 0.5) {
      final saturation = style.saturation.clamp(0.0, 2.0);
      final raw = _rawImage();
      return RepaintBoundary(
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (widget.baseColor != null) ColoredBox(color: widget.baseColor!),
            if ((saturation - 1.0).abs() > 0.01)
              ColorFiltered(
                colorFilter: ColorFilter.matrix(
                  blurSaturationMatrix(saturation),
                ),
                child: raw,
              )
            else
              raw,
            for (final color in style.overlays) ColoredBox(color: color),
            const BackgroundDitherLayer(),
          ],
        ),
      );
    }

    _adoptSharedBackdrop();
    _schedule();
    final baked = _baked;
    // 单独一层：背景几乎不变，隔离开之后上层内容重绘不会带着它一起重绘。
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.baseColor != null) ColoredBox(color: widget.baseColor!),
          // 还没有可用的模糊位图：只留底色，不画原图。
          //
          // 以前这里画的是未处理的原图（清晰、没压暗、没饱和、没白纱），等
          // 80ms 烤好再换成模糊版——打开二级页时看到的就是「一张原始背景图
          // 一闪而过」。现在首帧会先从共享缓存同步拿主界面烤好的那张
          // （[_adoptSharedBackdrop]），拿不到就等这一下，宁可短暂留白也不
          // 闪一张效果不对的图。
          // 之后换图时 _baked 会一直留着上一张，画面不会空掉。
          if (baked != null)
            RawImage(
              image: baked,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
              filterQuality: FilterQuality.low,
            ),
          const BackgroundDitherLayer(),
        ],
      ),
    );
  }
}
