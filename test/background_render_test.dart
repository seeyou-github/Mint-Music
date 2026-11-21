import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/app/background_blur_renderer.dart';

/// 背景烘焙（模糊 + 饱和度 + 亮度 / 遮罩 → 位图）的回归测试。
///
/// 这段代码决定了整个界面的底色：算错了不是崩，而是「背景发白 / 发黑 / 糊成
/// 一团」，很难从界面上一眼看出来是哪一步错。这里用纯色图 + 单参数逐项验证。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<ui.Image> solidImage(ui.Color color) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      const ui.Rect.fromLTWH(0, 0, 64, 64),
      ui.Paint()..color = color,
    );
    final picture = recorder.endRecording();
    try {
      return await picture.toImage(64, 64);
    } finally {
      picture.dispose();
    }
  }

  Future<List<int>> rgba(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    return data!.buffer.asUint8List().toList();
  }

  List<int> pixelAt(List<int> bytes, int width, int x, int y) {
    final i = (y * width + x) * 4;
    return [bytes[i], bytes[i + 1], bytes[i + 2], bytes[i + 3]];
  }

  BackdropStyle style({
    double sigma = 0,
    double brightness = 1,
    double saturation = 1,
    bool lighten = false,
    double autoDarken = 0,
  }) => BackdropStyle(
    sigma: sigma,
    brightness: brightness,
    saturation: saturation,
    lighten: lighten,
    autoDarken: autoDarken,
  );

  test('按请求尺寸输出，纯色图保持原色（不模糊 / 不调色）', () async {
    final source = await solidImage(const ui.Color(0xFF3060A0));
    final image = await renderBackdrop(
      source: source,
      width: 96,
      height: 48,
      style: style(),
      pixelScale: 0.5,
    );
    expect(image.width, 96);
    expect(image.height, 48);
    final bytes = await rgba(image);
    final center = pixelAt(bytes, 96, 48, 24);
    expect(center[0], closeTo(0x30, 3));
    expect(center[1], closeTo(0x60, 3));
    expect(center[2], closeTo(0xA0, 3));
    expect(center[3], 255);
    image.dispose();
    source.dispose();
  });

  test('亮度 50% 压暗叠加；提亮走白纱', () async {
    final source = await solidImage(const ui.Color(0xFF808080));
    final dark = await renderBackdrop(
      source: source,
      width: 32,
      height: 32,
      style: style(brightness: 0.5),
      pixelScale: 0.5,
    );
    final darkPixel = pixelAt(await rgba(dark), 32, 16, 16);
    expect(darkPixel[0], closeTo(0x40, 3));

    final bright = await renderBackdrop(
      source: source,
      width: 32,
      height: 32,
      style: style(brightness: 1.4),
      pixelScale: 0.5,
    );
    final brightPixel = pixelAt(await rgba(bright), 32, 16, 16);
    // 1.4 → 白纱 alpha = 0.4 * 0.6 = 0.24
    expect(brightPixel[0], closeTo(0x80 + (0xFF - 0x80) * 0.24, 4));

    dark.dispose();
    bright.dispose();
    source.dispose();
  });

  test('饱和度 0 输出灰度', () async {
    final source = await solidImage(const ui.Color(0xFFC03010));
    final image = await renderBackdrop(
      source: source,
      width: 32,
      height: 32,
      style: style(saturation: 0),
      pixelScale: 0.5,
    );
    final pixel = pixelAt(await rgba(image), 32, 16, 16);
    expect((pixel[0] - pixel[1]).abs(), lessThanOrEqualTo(1));
    expect((pixel[1] - pixel[2]).abs(), lessThanOrEqualTo(1));
    image.dispose();
    source.dispose();
  });

  test('模糊不会在边缘留下透明 / 发黑的虚边', () async {
    final source = await solidImage(const ui.Color(0xFF205020));
    final image = await renderBackdrop(
      source: source,
      width: 64,
      height: 64,
      style: style(sigma: 40),
      pixelScale: 0.5,
    );
    final bytes = await rgba(image);
    for (final p in [
      pixelAt(bytes, 64, 0, 0),
      pixelAt(bytes, 64, 63, 0),
      pixelAt(bytes, 64, 0, 63),
      pixelAt(bytes, 64, 63, 63),
    ]) {
      expect(p[3], 255, reason: '模糊后边角仍应不透明');
      expect(p[0], closeTo(0x20, 6), reason: '模糊后边角颜色应接近原色');
      expect(p[1], closeTo(0x50, 6));
      expect(p[2], closeTo(0x20, 6));
    }
    image.dispose();
    source.dispose();
  });

  group('共享烘焙结果（主界面 + 二级页同一组参数只烤一次）', () {
    tearDown(debugClearBakedGallery);

    test('同一 key 并发取用只渲染一次，串行再取直接命中', () async {
      var renders = 0;
      var loads = 0;
      Future<ui.Image> render() async {
        renders++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return solidImage(const ui.Color(0xFF4080C0));
      }

      Future<ui.Image?> load() async {
        loads++;
        return null;
      }

      final both = await Future.wait([
        debugAcquireBaked(key: 'k', load: load, render: render),
        debugAcquireBaked(key: 'k', load: load, render: render),
      ]);
      expect(renders, 1, reason: '两路并发只应该烤一次');
      expect(loads, 1, reason: '同一 key 的磁盘查询也复用同一次');
      expect(both[0], isNotNull);
      expect(both[1], isNotNull);

      final third = await debugAcquireBaked(
        key: 'k',
        load: load,
        render: render,
      );
      expect(renders, 1, reason: '之后取用命中内存，不再渲染');
      for (final image in [...both, third]) {
        image?.dispose();
      }
    });

    test('一个句柄 dispose 后另一个仍可用（clone 各自计引用）', () async {
      final a = await debugAcquireBaked(
        key: 'k2',
        load: () async => null,
        render: () => solidImage(const ui.Color(0xFF102030)),
      );
      final b = await debugAcquireBaked(
        key: 'k2',
        load: () async => null,
        render: () => solidImage(const ui.Color(0xFF102030)),
      );
      expect(a, isNotNull);
      expect(b, isNotNull);

      a!.dispose();
      // b 还在：能正常读取像素。
      final bytes = await rgba(b!);
      expect(bytes[3], 255);
      b.dispose();
    });

    test('不同 key 各自渲染', () async {
      var renders = 0;
      Future<ui.Image> render() async {
        renders++;
        return solidImage(const ui.Color(0xFF203040));
      }

      final one = await debugAcquireBaked(
        key: 'a',
        load: () async => null,
        render: render,
      );
      final two = await debugAcquireBaked(
        key: 'b',
        load: () async => null,
        render: render,
      );
      expect(renders, 2);
      one?.dispose();
      two?.dispose();
    });

    // 二级页首帧靠 peek 同步拿到主界面烤好的那张，拿不到就会先露一张未处理
    // 原图再变糊（用户看到的「打开二级页时原始背景一闪而过」）。
    test('peek 同步命中已烤好的位图，不触发 load / render', () async {
      var renders = 0;
      var loads = 0;
      final baked = await debugAcquireBaked(
        key: 'p',
        load: () async {
          loads++;
          return null;
        },
        render: () async {
          renders++;
          return solidImage(const ui.Color(0xFF506070));
        },
      );
      expect(baked, isNotNull);
      expect(renders, 1);
      expect(loads, 1);

      final peeked = debugPeekBaked('p');
      expect(peeked, isNotNull, reason: '同一 key 应该能同步取到');
      expect(renders, 1, reason: 'peek 不应该再渲染');
      expect(loads, 1, reason: 'peek 不应该再查磁盘');
      // peek 给的是独立句柄：先释放原句柄，peek 出来的仍可读。
      baked!.dispose();
      final bytes = await rgba(peeked!);
      expect(bytes[3], 255);
      peeked.dispose();
    });

    test('peek 未命中返回 null 且什么都不做', () {
      expect(debugPeekBaked('nope'), isNull);
    });

    // 封面糊化背景随歌变：只在内存共享，不读写磁盘（否则每次切歌都往
    // temp\background_render 写一张，把用户背景图的成品从淘汰池里挤掉）。
    test('persist=false 不查磁盘、只在内存共享', () async {
      var renders = 0;
      var loads = 0;
      Future<ui.Image> render() async {
        renders++;
        return solidImage(const ui.Color(0xFF607080));
      }

      final first = await debugAcquireBaked(
        key: 'np',
        persist: false,
        load: () async {
          loads++;
          return null;
        },
        render: render,
      );
      expect(first, isNotNull);
      expect(renders, 1);
      expect(loads, 0, reason: 'persist=false 不应该查磁盘');

      final second = await debugAcquireBaked(
        key: 'np',
        persist: false,
        load: () async {
          loads++;
          return null;
        },
        render: render,
      );
      expect(renders, 1, reason: '第二取命中内存，不再渲染');
      expect(loads, 0);
      first?.dispose();
      second?.dispose();
    });
  });
}
