import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'theme_provider.dart';

/// 把系统亮/暗变化同步到 [platformBrightnessProvider]。
///
/// 「跟随系统」主题依赖它才能在系统切换亮/暗时实时跟随，而不是等到下次启动。
/// 单独抽成 widget 是为了让这条链路可以被 widget 测试覆盖。
class SystemBrightnessSync extends ConsumerStatefulWidget {
  const SystemBrightnessSync({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<SystemBrightnessSync> createState() =>
      _SystemBrightnessSyncState();
}

class _SystemBrightnessSyncState extends ConsumerState<SystemBrightnessSync>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // 通过当前 View 取亮度：它跟随所在的 FlutterView，
    // 比直接用 PlatformDispatcher.instance 更贴近实际渲染到的窗口。
    final dispatcher = View.maybeOf(context)?.platformDispatcher;
    ref.read(platformBrightnessProvider.notifier).state =
        dispatcher?.platformBrightness ??
        PlatformDispatcher.instance.platformBrightness;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
