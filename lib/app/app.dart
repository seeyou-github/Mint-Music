import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/l10n/app_locale.dart';
import '../core/l10n/l10n.dart';
import '../core/theme/app_theme.dart';
import '../core/theme/theme_provider.dart';
import '../core/router/app_router.dart';
import '../core/theme/system_brightness_sync.dart';
import '../core/utils/responsive_layout.dart';
import '../features/player/presentation/desktop_lyric_window.dart';
import '../features/plugin/application/plugin_providers.dart';
import '../features/settings/application/plugin_providers.dart';
import '../features/settings/application/settings_providers.dart';
import '../features/settings/data/plugin_repository.dart';
import 'app_desktop_shell.dart';

class App extends ConsumerStatefulWidget {
  const App({super.key});

  @override
  ConsumerState<App> createState() => _AppState();
}

class _AppState extends ConsumerState<App> {
  bool _hasCheckedUpdates = false;

  @override
  Widget build(BuildContext context) {
    final themeMode = ref.watch(themeModeProvider);
    final appLocale = ref.watch(appLocaleProvider);
    // 同步全局语言,供非 widget 场景(如歌词控制器)使用
    currentLocale = appLocale;

    // Listen for plugin initialization completion to trigger update check
    ref.listen(pluginInitializedProvider, (previous, next) {
      next.whenData((_) {
        if (!_hasCheckedUpdates) {
          _hasCheckedUpdates = true;
          _checkPluginsForUpdates();
        }
      });
    });

    // Also check if plugins were already initialized (e.g. on hot reload)
    final pluginState = ref.watch(pluginInitializedProvider);
    if (pluginState.hasValue && !_hasCheckedUpdates) {
      _hasCheckedUpdates = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkPluginsForUpdates();
      });
    }

    // 系统亮/暗变化同步进 provider，「跟随系统」主题才能实时跟随
    return SystemBrightnessSync(
      child: L10n(
        locale: appLocale,
        child: MaterialApp.router(
          title: tr('薄荷音乐'),
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light,
          darkTheme: AppTheme.dark,
          themeMode: themeMode,
          routerConfig: appRouter,
        builder: (context, child) {
          final deviceType = ResponsiveLayout.getDeviceType(context);
          final layoutMode = ResponsiveLayout.getLayoutMode(context);
          final isLandscape = ResponsiveLayout.isLandscape(context);
          final isTablet = ResponsiveLayout.isTablet(context);
          // 桌面歌词层与路由内容同级,因此会悬浮在所有页面/弹窗之上。
          // StackFit.passthrough 保证 Navigator 依旧拿到铺满屏幕的紧约束。
          return Listener(
            // 鼠标侧键「后退」(Windows 上的 XButton1) 触发的指针事件。
            // 放在路由之上，因此所有一级/二级页面都能响应。
            behavior: HitTestBehavior.translucent,
            onPointerDown: _handleMouseBack,
            child: Stack(
              fit: StackFit.passthrough,
              children: [
                ResponsiveWrapper(
                  deviceType: deviceType,
                  layoutMode: layoutMode,
                  isLandscape: isLandscape,
                  isTablet: isTablet,
                  child: MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      textScaler: MediaQuery.of(context).textScaler,
                    ),
                    // 宽屏下左侧导航栏渲染在路由之外，二级页面不会再遮挡它。
                    child: AppDesktopShell(
                      child: child ?? const SizedBox.shrink(),
                    ),
                  ),
                ),
                const DesktopLyricLayer(),
              ],
            ),
          );
        },
        ),
      ),
    );
  }

  /// 鼠标侧键「后退」：与系统返回键等效（关闭弹窗 / 返回上一页）。
  ///
  /// 复用 [GoRouterDelegate.popRoute]，与 Android 系统返回键同一套逻辑，
  /// 因此页面里的 `PopScope` 仍然生效（多选模式先退出多选、播放页先冻结
  /// AMLL WebView 再退出）；一级页面没有可返回内容时不做任何事。
  void _handleMouseBack(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    if ((event.buttons & kBackMouseButton) == 0) return;
    final delegate = appRouter.routerDelegate;
    if (delegate.currentConfiguration.matches.isEmpty) return;
    delegate.popRoute();
  }

  Future<void> _checkPluginsForUpdates() async {
    if (!mounted) return;
    try {
      final repo = PluginRepository();
      final results = await repo.checkAllPluginUpdates();
      final available = results.where((r) => r.available).toList();

      if (available.isNotEmpty && mounted) {
        _showUpdateNotificationDialog(available);
      }
    } catch (e) {
      debugPrint('App startup plugin update check failed: $e');
    }
  }

  void _showUpdateNotificationDialog(List<PluginUpdateResult> updates) {
    if (!mounted) return;
    final colors = ref.read(themeColorsProvider);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF4CAF50), size: 24),
            const SizedBox(width: 8),
            Text(
              '插件更新',
              style: TextStyle(color: colors.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '发现 ${updates.length} 个插件可更新：',
                style: TextStyle(color: colors.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 12),
              ...updates.map((result) => Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.extension, color: colors.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.plugin.name,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: colors.textPrimary,
                            ),
                          ),
                          Text(
                            result.remoteVersion != null && result.remoteVersion != 'latest'
                                ? 'v${result.plugin.version} → v${result.remoteVersion}'
                                : 'v${result.plugin.version} → 可更新',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF4CAF50),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )),
              const SizedBox(height: 4),
              Text(
                '前往 插件管理 页面可进行更新操作。',
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('稍后', style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              // Navigate to plugin management page
              GoRouter.of(context).push('/plugin-management');
            },
            child: const Text(
              '去更新',
              style: TextStyle(
                color: Color(0xFF4CAF50),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
