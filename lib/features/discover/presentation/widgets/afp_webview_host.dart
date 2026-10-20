import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../data/audio_fingerprint_desktop_service.dart';

/// 桌面端 AFP 指纹模块的宿主组件。
///
/// 桌面端没有 `webview_flutter`，改用 [InAppWebView] 承载 afp.js + afp.wasm。
/// WebView 需要真实存在于组件树里，因此由本组件创建并把控制器交给
/// [DesktopFingerprintBridge]。
///
/// 组件本身不可见（放在屏幕外的位置），只用来跑 JS 指纹计算。
class AfpWebViewHost extends StatefulWidget {
  const AfpWebViewHost({super.key, required this.bridge});

  final DesktopFingerprintBridge bridge;

  @override
  State<AfpWebViewHost> createState() => _AfpWebViewHostState();
}

class _AfpWebViewHostState extends State<AfpWebViewHost> {
  late final Future<String> _htmlFuture = DesktopFingerprintBridge.buildHtml();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _htmlFuture,
      builder: (context, snapshot) {
        final html = snapshot.data;
        if (html == null) {
          return const SizedBox(width: 1, height: 1);
        }
        return SizedBox(
          width: 200,
          height: 200,
          child: InAppWebView(
            initialSettings: InAppWebViewSettings(
              javaScriptEnabled: true,
              transparentBackground: true,
              supportZoom: false,
            ),
            initialData: InAppWebViewInitialData(
              data: html,
              mimeType: 'text/html',
              encoding: 'utf8',
              baseUrl: WebUri('https://afp.local/'),
            ),
            onWebViewCreated: (controller) {
              widget.bridge.attach(controller);
            },
            onLoadStop: (controller, url) {
              unawaited(widget.bridge.onPageLoaded());
            },
          ),
        );
      },
    );
  }
}
