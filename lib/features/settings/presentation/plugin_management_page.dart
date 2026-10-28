import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../../core/constants/app_routes.dart';
import '../../../../core/l10n/l10n.dart';
import '../../../../core/theme/app_spacing.dart';
import '../../../../core/theme/theme_provider.dart';
import '../../plugin/data/plugin_service.dart';
import '../../plugin/domain/plugin_source_states.dart';
import '../../plugin/domain/source_id_mapping.dart';
import '../application/plugin_providers.dart';
import '../application/settings_providers.dart';
import '../data/plugin_repository.dart';
import '../domain/models/plugin_info.dart';
import 'plugin_test_dialog.dart';

class PluginManagementPage extends ConsumerStatefulWidget {
  const PluginManagementPage({super.key, this.embedded = false});

  /// 嵌入「设置 - 插件管理」标签时使用：不渲染自己的 Scaffold / 标题栏，
  /// 直接铺满设置页的内容区域。
  final bool embedded;

  /// 把插件加载/操作异常转成用户可读的提示，避免直接展示晦涩的
  /// "Stack Overflow" 原始错误文本（大型洛雪插件脚本递归过深时常见）。
  static String pluginErrorMessage(Object error) {
    final text = error.toString().replaceFirst('Exception: ', '');
    if (text.contains('Stack Overflow') || text.contains('stack overflow')) {
      return tr('插件加载失败：插件脚本过大导致 JS 引擎栈溢出，请更换精简版插件');
    }
    return text;
  }

  @override
  ConsumerState<PluginManagementPage> createState() =>
      _PluginManagementPageState();
}

class _PluginManagementPageState extends ConsumerState<PluginManagementPage> {
  bool _isCheckingUpdates = false;
  bool _isSavingPluginOrder = false;

  /// 正在单独检查更新的插件 id（卡片上的「更新」按钮显示转圈）。
  final Set<String> _checkingPluginUpdateIds = {};

  /// 数据源卡片里「设置播放源」那一行的锚点（弹出菜单用它定位）。
  final Map<String, GlobalKey> _dataSourcePlaybackKeys = {};

  StreamSubscription<Map<String, dynamic>>? _updateNoticeSubscription;

  @override
  void initState() {
    super.initState();
    // Subscribe to plugin-initiated update notices (from lx.send('updateAlert')).
    _subscribeToUpdateNotices();
    // Auto-check for updates when the page loads.
    // 默认关闭「自动检测更新」：只有用户主动打开开关后，进入本页才会
    // 自动检查更新（否则仍可点右上角刷新按钮手动检查）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!ref.read(pluginAutoCheckUpdateProvider)) return;
      // 嵌入设置页时每次切标签都会重建本页，避免重复请求：
      // 已有检查结果就不再自动检查，用户仍可点右上角刷新。
      if (ref.read(pluginUpdateResultsProvider).isEmpty) {
        _checkAllUpdates();
      }
    });
  }

  @override
  void dispose() {
    _updateNoticeSubscription?.cancel();
    super.dispose();
  }

  void _subscribeToUpdateNotices() {
    final pluginService = ref.read(pluginServiceProvider);
    _updateNoticeSubscription = pluginService.updateNoticeStream.listen((
      notice,
    ) {
      if (!mounted) return;
      final pluginName = notice['pluginName'] as String? ?? tr('未知插件');
      final pluginVersion = notice['pluginVersion'] as String? ?? '';
      final pluginId = notice['pluginId'] as String? ?? '';
      final data = notice['data'];
      String log = '';
      String? updateUrl;
      if (data is Map) {
        log = data['log']?.toString() ?? '';
        updateUrl = data['updateUrl']?.toString();
      } else if (data is String) {
        log = data;
      }

      // Store the notice in the provider so the UI can show update badges.
      final existing = ref.read(pluginScriptUpdateNoticesProvider);
      if (!existing.any((n) => n['pluginId'] == pluginId)) {
        ref.read(pluginScriptUpdateNoticesProvider.notifier).state = [
          ...existing,
          notice,
        ];
      }

      _showPluginUpdateNoticeDialog(
        pluginName: pluginName,
        pluginVersion: pluginVersion,
        log: log,
        updateUrl: updateUrl,
      );
    });
  }

  void _showPluginUpdateNoticeDialog({
    required String pluginName,
    required String pluginVersion,
    required String log,
    String? updateUrl,
  }) {
    final colors = ref.read(themeColorsProvider);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF4CAF50), size: 24),
            const SizedBox(width: AppSpacing.sm),
            Text(
              ctx.tr('插件更新'),
              style: TextStyle(color: colors.textPrimary, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Icon(Icons.extension, color: colors.primary, size: 20),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          pluginName,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          ctx.tr('当前版本 v$pluginVersion'),
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textHint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (log.isNotEmpty) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                log,
                style: TextStyle(color: colors.textSecondary, fontSize: 14),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.tr('关闭'), style: TextStyle(color: colors.textHint)),
          ),
          if (updateUrl != null && updateUrl.isNotEmpty)
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _openUpdateUrl(updateUrl);
              },
              child: Text(
                ctx.tr('前往更新'),
                style: const TextStyle(
                  color: Color(0xFF4CAF50),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openUpdateUrl(String url) async {
    try {
      await launchUrl(Uri.parse(url));
    } catch (e) {
      debugPrint('Failed to open update URL: $e');
    }
  }

  Future<void> _checkAllUpdates() async {
    if (_isCheckingUpdates) return;
    setState(() => _isCheckingUpdates = true);
    try {
      await ref.read(pluginsProvider.notifier).checkForUpdates();
    } catch (e) {
      // Silently handle update check errors
      debugPrint('Plugin update check failed: $e');
    } finally {
      if (mounted) setState(() => _isCheckingUpdates = false);
    }

    // Show any pending plugin-initiated update notices that arrived
    // during plugin initialization (before this page was opened).
    _showPendingPluginUpdateNotices();
  }

  void _showPendingPluginUpdateNotices() {
    // Retrieve buffered notices that arrived during plugin initialization
    // (before this page was opened). After showing, clear the buffer so
    // the dialog is only shown once per app session — repeated opens of
    // the page won't re-trigger the update alert.
    final pluginService = ref.read(pluginServiceProvider);
    final pending = pluginService.getBufferedUpdateNotices();
    if (pending.isEmpty) return;
    debugPrint(
      '[PluginManagementPage] Showing ${pending.length} buffered update notices',
    );
    // Clear buffer immediately to prevent re-showing on subsequent visits.
    pluginService.clearAllBufferedUpdateNotices();
    // Show dialogs sequentially with a small delay between each.
    for (final notice in pending) {
      final pluginName = notice['pluginName'] as String? ?? tr('未知插件');
      final pluginVersion = notice['pluginVersion'] as String? ?? '';
      final data = notice['data'];
      String log = '';
      String? updateUrl;
      if (data is Map) {
        log = data['log']?.toString() ?? '';
        updateUrl = data['updateUrl']?.toString();
      } else if (data is String) {
        log = data;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _showPluginUpdateNoticeDialog(
            pluginName: pluginName,
            pluginVersion: pluginVersion,
            log: log,
            updateUrl: updateUrl,
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final pluginsAsync = ref.watch(pluginsProvider);
    final updateResults = ref.watch(pluginUpdateResultsProvider);
    final scriptNotices = ref.watch(pluginScriptUpdateNoticesProvider);

    // Merge script-initiated update notices into the update results so
    // plugin cards show update badges for ALL plugin types (lx and cr).
    final mergedResults = List<PluginUpdateResult>.from(updateResults);
    for (final notice in scriptNotices) {
      final pluginId = notice['pluginId'] as String? ?? '';
      // Skip if already detected by the manual check.
      if (mergedResults.any((r) => r.plugin.id == pluginId && r.available))
        continue;
      final pluginName = notice['pluginName'] as String? ?? '';
      final pluginVersion = notice['pluginVersion'] as String? ?? '';
      final data = notice['data'];
      String log = '';
      String? updateUrl;
      if (data is Map) {
        log = data['log']?.toString() ?? '';
        updateUrl = data['updateUrl']?.toString();
      } else if (data is String) {
        log = data;
      }
      // Find the matching PluginInfo from the loaded plugins list.
      final pluginInfo = pluginsAsync.valueOrNull
          ?.where((p) => p.id == pluginId)
          .firstOrNull;
      if (pluginInfo != null && log.isNotEmpty) {
        // Use updateUrl from the script notice if available, fallback to plugin's stored URL.
        final effectiveUpdateUrl = updateUrl?.isNotEmpty == true
            ? updateUrl
            : pluginInfo.updateUrl;
        if (effectiveUpdateUrl != null && effectiveUpdateUrl.isNotEmpty) {
          mergedResults.add(
            PluginUpdateResult(
              plugin: pluginInfo,
              available: true,
              remoteVersion: pluginVersion.isNotEmpty
                  ? pluginVersion
                  : 'latest',
              remoteCode: log,
              updateUrl: effectiveUpdateUrl,
            ),
          );
        }
      }
    }

    final content = pluginsAsync.when(
      data: (plugins) {
        // 数据源插件单独成组，普通插件列表里不再重复出现。
        final dataSources = plugins.where((p) => p.isDataSource).toList();
        final normalPlugins = plugins.where((p) => !p.isDataSource).toList();
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              sliver: SliverMainAxisGroup(
                slivers: [
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildAutoUpdateSection(colors),
                        const SizedBox(height: AppSpacing.lg),
                        _buildDataSourceSection(colors, dataSources),
                      ],
                    ),
                  ),
                  _buildReorderablePluginSliver(
                    colors,
                    dataSources,
                    mergedResults,
                    isDataSource: true,
                  ),
                  SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: AppSpacing.lg),
                        _buildPluginSectionHeader(colors, normalPlugins.length),
                        const SizedBox(height: AppSpacing.sm),
                      ],
                    ),
                  ),
                  if (normalPlugins.isEmpty)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.xxl,
                        ),
                        child: _buildEmptyState(colors),
                      ),
                    )
                  else
                    _buildReorderablePluginSliver(
                      colors,
                      normalPlugins,
                      mergedResults,
                      isDataSource: false,
                    ),
                ],
              ),
            ),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: colors.textHint),
            const SizedBox(height: AppSpacing.md),
            Text(context.tr('加载失败'), style: TextStyle(color: colors.textHint)),
            const SizedBox(height: AppSpacing.sm),
            TextButton(
              onPressed: () => ref.invalidate(pluginsProvider),
              child: Text(
                context.tr('重试'),
                style: TextStyle(color: colors.primary),
              ),
            ),
          ],
        ),
      ),
    );

    if (widget.embedded) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.sm,
              AppSpacing.sm,
              0,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    context.tr('插件管理'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: colors.textPrimary,
                    ),
                  ),
                ),
                if (_isCheckingUpdates)
                  const Padding(
                    padding: EdgeInsets.all(12.0),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  IconButton(
                    icon: Icon(Icons.refresh, color: colors.primary),
                    onPressed: _checkAllUpdates,
                    tooltip: context.tr('检查更新'),
                  ),
                IconButton(
                  icon: Icon(Icons.add, color: colors.primary),
                  onPressed: () => _showAddPluginSheet(colors),
                  tooltip: context.tr('添加插件'),
                ),
              ],
            ),
          ),
          Expanded(child: content),
        ],
      );
    }

    return Scaffold(
      backgroundColor: colors.background,
      appBar: AppBar(
        backgroundColor: colors.background,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: colors.textPrimary),
          onPressed: () {
            // 正常情况下直接返回上一页；若当前分支里没有可返回的页面
            // （例如从启动弹窗直接进入），则回到「我的」页面。
            if (context.canPop()) {
              context.pop();
            } else {
              context.go(AppRoutes.mine);
            }
          },
        ),
        title: Text(
          context.tr('插件管理'),
          style: TextStyle(
            color: colors.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        actions: [
          if (_isCheckingUpdates)
            const Padding(
              padding: EdgeInsets.all(12.0),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: Icon(Icons.refresh, color: colors.primary),
              onPressed: _checkAllUpdates,
              tooltip: context.tr('检查更新'),
            ),
          IconButton(
            icon: Icon(Icons.add, color: colors.primary),
            onPressed: () => _showAddPluginSheet(colors),
          ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildReorderablePluginSliver(
    ThemeColors colors,
    List<PluginInfo> plugins,
    List<PluginUpdateResult> updateResults, {
    required bool isDataSource,
  }) {
    return SliverReorderableList(
      key: ValueKey(isDataSource),
      itemCount: plugins.length,
      itemBuilder: (context, index) {
        final plugin = plugins[index];
        return Consumer(
          key: ValueKey(plugin.id),
          builder: (context, ref, _) => _buildPluginCard(
            colors,
            plugin,
            updateResults,
            ref: ref,
            reorderIndex: index,
            footer: isDataSource
                ? _buildDataSourcePlaybackRow(colors, plugin, ref: ref)
                : null,
          ),
        );
      },
      onReorder: (oldIndex, newIndex) => unawaited(
        _reorderPlugins(
          isDataSource: isDataSource,
          oldIndex: oldIndex,
          newIndex: newIndex,
        ),
      ),
      proxyDecorator: (child, index, animation) =>
          Material(type: MaterialType.transparency, child: child),
    );
  }

  Future<void> _reorderPlugins({
    required bool isDataSource,
    required int oldIndex,
    required int newIndex,
  }) async {
    if (_isSavingPluginOrder ||
        oldIndex == newIndex ||
        oldIndex + 1 == newIndex) {
      return;
    }
    setState(() => _isSavingPluginOrder = true);
    try {
      await ref
          .read(pluginsProvider.notifier)
          .reorderPlugins(
            isDataSource: isDataSource,
            oldIndex: oldIndex,
            newIndex: newIndex,
          );
    } catch (error) {
      if (!mounted) return;
      final colors = ref.read(themeColorsProvider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr(
              '排序保存失败：${PluginManagementPage.pluginErrorMessage(error)}',
            ),
          ),
          backgroundColor: colors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSavingPluginOrder = false);
    }
  }

  /// 「自动检测更新」开关（默认关闭）。
  ///
  /// 关闭时进入本页不会自动检查插件更新，需要用户点击右上角的刷新按钮。
  Widget _buildAutoUpdateSection(ThemeColors colors) {
    final enabled = ref.watch(pluginAutoCheckUpdateProvider);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: colors.divider.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(Icons.system_update_alt, size: 18, color: colors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              context.tr('自动检测更新'),
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (value) {
              ref.read(pluginAutoCheckUpdateProvider.notifier).state = value;
              final container = ProviderScope.containerOf(context);
              unawaited(
                container
                    .read(settingsServiceProvider.future)
                    .then((svc) => svc.setPluginAutoCheckUpdate(value)),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildPluginSourceRow(
    PluginInfo plugin,
    PluginSource source,
    ThemeColors colors,
    PluginSourceStates states,
  ) {
    // 开关的键统一按音源展示名推导（与运行时解析保持一致）。
    final sourceId = SourceIdMapping.deriveId(source.name);
    final enabled = states.isEnabled(plugin.id, sourceId);
    final qualities = source.qualities.isNotEmpty
        ? ' · ${source.qualities.join("/")}'
        : '';

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Icon(
            enabled ? Icons.check_circle : Icons.remove_circle_outline,
            size: 14,
            color: enabled ? colors.primary : colors.textHint,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${source.name}$qualities',
              style: TextStyle(
                fontSize: 12,
                color: enabled ? colors.textSecondary : colors.textHint,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Switch(
            value: enabled,
            activeThumbColor: colors.primary,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) =>
                _setPluginSourceEnabled(plugin, source, sourceId, value),
          ),
        ],
      ),
    );
  }

  Future<void> _setPluginSourceEnabled(
    PluginInfo plugin,
    PluginSource source,
    String sourceId,
    bool enabled,
  ) async {
    // 开关本身就是反馈，不再弹提示。
    await ref
        .read(pluginSourceStateProvider.notifier)
        .setEnabled(plugin.id, sourceId, enabled);
  }

  Widget _buildPluginSectionHeader(ThemeColors colors, int pluginCount) {
    return Text(
      context.tr('插件音源（$pluginCount）'),
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: colors.textPrimary,
      ),
    );
  }

  /* ---------------------------------------------------------------- *
   * 数据源（只提供元数据、不解析播放地址的插件）
   * ---------------------------------------------------------------- */

  /// 「数据源」分类：只列脚本里声明了 `isDataSource` 的插件。
  ///
  /// 数据源本身没有播放接口，所以每个插件都要指定一个「播放源」：播放数据源
  /// 里的歌曲时，用这个播放源重新找歌并解析地址。
  Widget _buildDataSourceSection(
    ThemeColors colors,
    List<PluginInfo> dataSources,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.tr('数据源'),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (dataSources.isNotEmpty)
              Text(
                context.tr('${dataSources.length} 个'),
                style: TextStyle(fontSize: 12, color: colors.textHint),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          context.tr('只提供搜索 / 歌单 / 榜单等数据，播放时使用下面指定的播放源'),
          style: TextStyle(fontSize: 12, color: colors.textHint),
        ),
        const SizedBox(height: AppSpacing.md),
        if (dataSources.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: colors.divider),
            ),
            child: Text(
              context.tr(
                '还没有数据源插件。添加的 JS 插件如果在 pluginInfo 里声明了 isDataSource: true，就会出现在这里。',
              ),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ),
      ],
    );
  }

  /// 数据源卡片里的「设置播放源」入口。
  ///
  /// 用和发现页音源切换一致的弹出菜单（`showMenu`）而不是 `DropdownButton`：
  /// 卡片里可用宽度有限，DropdownButton 在窄容器里弹出的菜单经常渲染不出内容，
  /// 而且「已失效」提示会把下拉框挤到中间。
  Widget _buildDataSourcePlaybackRow(
    ThemeColors colors,
    PluginInfo plugin, {
    required WidgetRef ref,
  }) {
    final manager = ref.read(musicSourceManagerProvider);
    final map = ref.watch(dataSourcePlaybackSourcesProvider);
    ref.watch(pluginSupportedSourcesProvider);
    final configuredId = map[plugin.id]?.trim() ?? '';

    // 可选的播放源：已安装、能解析播放地址的插件音源（数据源自己不参与）。
    final options = manager.playbackPluginSources();
    final available = options.any((source) => source.id == configuredId);
    final configuredName = configuredId.isEmpty
        ? null
        : manager.sourceDisplayName(configuredId);
    final invalid = configuredId.isNotEmpty && !available;

    final key = _dataSourcePlaybackKeys.putIfAbsent(
      plugin.id,
      () => GlobalKey(),
    );

    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            key: key,
            borderRadius: BorderRadius.circular(AppRadius.sm),
            onTap: () =>
                _showDataSourcePlaybackMenu(colors, plugin, configuredId),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Icon(
                    Icons.play_circle_outline,
                    size: 16,
                    color: colors.textHint,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    context.tr('设置播放源'),
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  // Expanded + 右对齐：名字占满剩余宽度，箭头始终贴在最右边，
                  // 有没有「已失效」提示都不会让下拉框左右乱跑。
                  Expanded(
                    child: Text(
                      configuredName ?? context.tr('未设置'),
                      textAlign: TextAlign.right,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: configuredId.isEmpty
                            ? colors.textHint
                            : (invalid ? colors.error : colors.primary),
                      ),
                    ),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: colors.textHint),
                ],
              ),
            ),
          ),
          if (invalid)
            Padding(
              padding: const EdgeInsets.only(left: 22, bottom: 2),
              child: Text(
                context.tr('已失效，请重新选择播放源'),
                style: TextStyle(fontSize: 11, color: colors.error),
              ),
            ),
        ],
      ),
    );
  }

  /// 弹出「选择播放源」菜单（与发现页切换音源的菜单一致）。
  Future<void> _showDataSourcePlaybackMenu(
    ThemeColors colors,
    PluginInfo plugin,
    String currentId,
  ) async {
    // 播放源列表在点击时才取：刚装完插件时页面不会因为插件引擎重载而重建，
    // build 时缓存的列表会一直缺新插件。
    if (ref.read(pluginInitializedProvider).isLoading) {
      // 安装插件后会整体卸载重载插件引擎，期间列表是残缺的，等重载完成。
      try {
        await ref.read(pluginInitializedProvider.future);
      } catch (_) {
        // 初始化失败时仍用当前已加载的插件弹菜单。
      }
      if (!mounted) return;
    }

    final anchor =
        _dataSourcePlaybackKeys[plugin.id]?.currentContext?.findRenderObject()
            as RenderBox?;
    if (anchor == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    // 定位矩形取行右下角的一个窄条：left > right 时 showMenu 会向左生长、
    // 右边缘对齐箭头（整行做锚点时 left < right，菜单会从行左侧弹出）。
    // top 取行底部，让菜单在行的下方展开，而不是盖住整行。
    final overlaySize = Offset.zero & overlay.size;
    final rightEdge = anchor.localToGlobal(
      Offset(anchor.size.width, anchor.size.height),
      ancestor: overlay,
    );
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        rightEdge - const Offset(1, 0),
        rightEdge + const Offset(0, 1),
      ),
      overlaySize,
    );

    final manager = ref.read(musicSourceManagerProvider);
    final options = manager.playbackPluginSources();
    final selected = await showMenu<String>(
      context: context,
      position: position,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      color: colors.surface,
      elevation: 8,
      items: [
        PopupMenuItem<String>(
          value: '',
          height: 42,
          child: Row(
            children: [
              Icon(Icons.block, size: 16, color: colors.textHint),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  context.tr('未设置'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: colors.textHint),
                ),
              ),
              if (currentId.isEmpty)
                Icon(Icons.check, size: 16, color: colors.primary),
            ],
          ),
        ),
        if (options.isEmpty)
          PopupMenuItem<String>(
            enabled: false,
            height: 42,
            child: Text(
              context.tr('还没有可用的播放源，请先安装能播放的音源插件'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ),
        for (final source in options)
          PopupMenuItem<String>(
            value: source.id,
            height: 42,
            child: Row(
              children: [
                Icon(
                  Icons.music_note,
                  size: 16,
                  color: source.id == currentId
                      ? colors.primary
                      : colors.textHint,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    manager.sourceDisplayName(source.id),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: source.id == currentId
                          ? colors.primary
                          : colors.textPrimary,
                      fontWeight: source.id == currentId
                          ? FontWeight.w500
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (source.id == currentId)
                  Icon(Icons.check, size: 16, color: colors.primary),
              ],
            ),
          ),
      ],
    );
    if (selected == null) return;
    if (selected == currentId) return;
    await _setDataSourcePlaybackSource(plugin, selected);
  }

  Future<void> _setDataSourcePlaybackSource(
    PluginInfo plugin,
    String sourceId,
  ) async {
    await setDataSourcePlaybackSource(
      ref,
      pluginId: plugin.id,
      sourceId: sourceId,
    );
    if (!mounted) return;
    final manager = ref.read(musicSourceManagerProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          sourceId.isEmpty
              ? context.tr('已清除「${plugin.name}」的播放源')
              : context.tr(
                  '「${plugin.name}」的播放源已设为 ${manager.sourceDisplayName(sourceId)}',
                ),
        ),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildEmptyState(ThemeColors colors) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              Icons.extension,
              size: 40,
              color: colors.primary.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            context.tr('暂无插件'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: colors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            context.tr('点击右上角 + 添加音源插件'),
            style: TextStyle(fontSize: 13, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.lg),
          GestureDetector(
            onTap: () => _showAddPluginSheet(colors),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                color: colors.primary,
                borderRadius: BorderRadius.circular(AppRadius.full),
              ),
              child: Text(
                context.tr('添加插件'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: colors.textOnPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPluginCard(
    ThemeColors colors,
    PluginInfo plugin,
    List<PluginUpdateResult> updateResults, {
    required WidgetRef ref,
    required int reorderIndex,
    Widget? footer,
  }) {
    final sourceStates = ref.watch(pluginSourceStateProvider);
    final typeLabel = PluginService.pluginTypeLabel(plugin.type);
    final typeColor = switch (plugin.type) {
      'lx' => const Color(0xFF4FC3F7),
      'mf' => const Color(0xFF80CBC4),
      _ => const Color(0xFFCE93D8),
    };

    // Find update result for this plugin
    final updateResult = updateResults
        .where((r) => r.plugin.id == plugin.id && r.available)
        .firstOrNull;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: updateResult != null
              ? const Color(0xFF4CAF50).withValues(alpha: 0.5)
              : plugin.isEnabled
              ? colors.primary.withValues(alpha: 0.2)
              : colors.divider,
          width: updateResult != null ? 1.5 : (plugin.isEnabled ? 1 : 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.sm,
              0,
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: updateResult != null
                        ? const Color(0xFF4CAF50).withValues(alpha: 0.12)
                        : colors.primary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Icon(
                    updateResult != null
                        ? Icons.system_update
                        : Icons.extension,
                    color: updateResult != null
                        ? const Color(0xFF4CAF50)
                        : colors.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              plugin.name,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: colors.textPrimary,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: typeColor.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              context.tr(typeLabel),
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w500,
                                color: typeColor,
                              ),
                            ),
                          ),
                          if (updateResult != null) ...[
                            const SizedBox(width: AppSpacing.sm),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF4CAF50,
                                ).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                context.tr(
                                  '可更新 v${updateResult.remoteVersion}',
                                ),
                                style: const TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w500,
                                  color: Color(0xFF4CAF50),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${plugin.author} · v${plugin.version}',
                        style: TextStyle(fontSize: 12, color: colors.textHint),
                      ),
                    ],
                  ),
                ),
                Switch(
                  value: plugin.isEnabled,
                  onChanged: (value) {
                    _togglePlugin(plugin.id, value, colors);
                  },
                  activeTrackColor: colors.primary.withValues(alpha: 0.3),
                  activeThumbColor: colors.primary,
                ),
                ReorderableDragStartListener(
                  index: reorderIndex,
                  enabled: !_isSavingPluginOrder,
                  child: MouseRegion(
                    cursor: _isSavingPluginOrder
                        ? SystemMouseCursors.basic
                        : SystemMouseCursors.grab,
                    child: Tooltip(
                      message: context.tr('拖动排序'),
                      child: SizedBox(
                        width: 40,
                        height: 48,
                        child: Icon(
                          Icons.drag_handle,
                          size: 22,
                          color: _isSavingPluginOrder
                              ? colors.textHint.withValues(alpha: 0.4)
                              : colors.textHint,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (plugin.description.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.md,
                AppSpacing.xs,
                AppSpacing.md,
                0,
              ),
              child: Text(
                plugin.description,
                style: TextStyle(fontSize: 12, color: colors.textHint),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          // 只有一个音源时不需要单独开关（插件总开关已经够用）。
          if (plugin.supportedSources.length > 1) ...[
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('插件自带音源（可单独开关）'),
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                  const SizedBox(height: 2),
                  ...plugin.supportedSources.map(
                    (source) => _buildPluginSourceRow(
                      plugin,
                      source,
                      colors,
                      sourceStates,
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.sm),
          ?footer,
          Divider(height: 1, color: colors.divider),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: AppSpacing.md),
                Icon(Icons.access_time, size: 14, color: colors.textHint),
                const SizedBox(width: 4),
                // Expanded：日期占满剩余宽度，右侧按钮再多也不会挤出屏幕。
                Expanded(
                  child: Text(
                    context.tr(
                      '${plugin.installTime.year}/${plugin.installTime.month.toString().padLeft(2, '0')}/${plugin.installTime.day.toString().padLeft(2, '0')} 安装',
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: colors.textHint),
                  ),
                ),
                // 每个插件都提供「更新」：已经检测到新版本时直接弹更新框，
                // 否则先单独检查这个插件，有新版本再弹框。
                GestureDetector(
                  onTap: () => _handleUpdateTap(colors, plugin, updateResult),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: 8,
                    ),
                    child: _checkingPluginUpdateIds.contains(plugin.id)
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: Color(0xFF4CAF50),
                            ),
                          )
                        : Text(
                            context.tr('更新'),
                            style: const TextStyle(
                              fontSize: 12,
                              color: Color(0xFF4CAF50),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
                // 插件测试仅对已启用插件显示：未启用的插件未加载运行时，
                // 测试服务无法解析其音源与音质，展示按钮只会误导用户。
                // 数据源没有播放接口，测试没有意义，同样不显示。
                if (plugin.isEnabled && !plugin.isDataSource)
                  GestureDetector(
                    onTap: () => _showPluginTestDialog(plugin),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      child: Text(
                        context.tr('插件测试'),
                        style: TextStyle(fontSize: 12, color: colors.primary),
                      ),
                    ),
                  ),
                GestureDetector(
                  onTap: () => _showUninstallDialog(colors, plugin),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                    ),
                    child: Text(
                      context.tr('卸载'),
                      style: TextStyle(fontSize: 12, color: colors.error),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _togglePlugin(
    String pluginId,
    bool isEnabled,
    ThemeColors colors,
  ) async {
    try {
      await ref
          .read(pluginsProvider.notifier)
          .togglePlugin(pluginId, isEnabled);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(PluginManagementPage.pluginErrorMessage(error)),
          backgroundColor: colors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  void _showAddPluginSheet(ThemeColors colors) {
    showModalBottomSheet(
      context: context,
      backgroundColor: colors.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _AddPluginSheet(colors: colors, ref: ref),
    );
  }

  void _showPluginTestDialog(PluginInfo plugin) {
    showDialog(
      context: context,
      builder: (ctx) => PluginTestDialog(plugin: plugin),
    );
  }

  void _showUninstallDialog(ThemeColors colors, PluginInfo plugin) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text(
          ctx.tr('卸载插件'),
          style: TextStyle(color: colors.textPrimary, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ctx.tr('确定要卸载以下插件吗？'),
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Icon(Icons.extension, color: colors.primary, size: 20),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          plugin.name,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: colors.textPrimary,
                          ),
                        ),
                        Text(
                          'v${plugin.version} · ${plugin.author}',
                          style: TextStyle(
                            fontSize: 12,
                            color: colors.textHint,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              ctx.tr('卸载后将删除插件文件，此操作不可撤销。'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              ref.read(pluginsProvider.notifier).uninstallPlugin(plugin.id);
              // 卸载成功不再弹提示。
              Navigator.pop(ctx);
            },
            child: Text(
              ctx.tr('卸载'),
              style: TextStyle(
                color: colors.error,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个插件的「更新」按钮。
  ///
  /// 已经检查出新版本（[updateResult] 非空）时直接弹更新框；否则先只检查
  /// 这一个插件，有新版本再弹框，已是最新则提示一下。
  Future<void> _handleUpdateTap(
    ThemeColors colors,
    PluginInfo plugin,
    PluginUpdateResult? updateResult,
  ) async {
    if (updateResult != null) {
      _showUpdateDialog(colors, updateResult);
      return;
    }
    if (_checkingPluginUpdateIds.contains(plugin.id)) return;

    final updateUrl = plugin.updateUrl;
    if (updateUrl == null || updateUrl.trim().isEmpty) {
      _toast(context.tr('该插件没有配置更新地址，无法检查更新'));
      return;
    }

    setState(() => _checkingPluginUpdateIds.add(plugin.id));
    try {
      final repo = ref.read(pluginRepositoryProvider);
      final result = await repo.checkPluginUpdate(plugin);
      if (!mounted) return;
      if (result.available) {
        // 同步到全局结果：卡片上的「可更新 vX」徽标也会一起出现。
        final current = ref.read(pluginUpdateResultsProvider);
        ref.read(pluginUpdateResultsProvider.notifier).state = [
          ...current.where((r) => r.plugin.id != plugin.id),
          result,
        ];
        _showUpdateDialog(colors, result);
      } else {
        _toast(context.tr('已是最新版本'));
      }
    } catch (e) {
      if (mounted) {
        _toast(
          context.tr('检查更新失败: ${PluginManagementPage.pluginErrorMessage(e)}'),
        );
      }
    } finally {
      if (mounted) setState(() => _checkingPluginUpdateIds.remove(plugin.id));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  void _showUpdateDialog(ThemeColors colors, PluginUpdateResult result) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Row(
          children: [
            const Icon(Icons.system_update, color: Color(0xFF4CAF50), size: 24),
            const SizedBox(width: AppSpacing.sm),
            Text(
              ctx.tr('插件更新'),
              style: TextStyle(color: colors.textPrimary, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Row(
                children: [
                  Icon(Icons.extension, color: colors.primary, size: 20),
                  const SizedBox(width: AppSpacing.sm),
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
                          result.remoteVersion != null &&
                                  result.remoteVersion != 'latest'
                              ? 'v${result.plugin.version} → v${result.remoteVersion}'
                              : ctx.tr('v${result.plugin.version} → 可更新'),
                          style: TextStyle(
                            fontSize: 12,
                            color: const Color(0xFF4CAF50),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (result.remoteCode != null &&
                result.remoteCode!.isNotEmpty &&
                result.remoteCode != result.remoteVersion) ...[
              const SizedBox(height: AppSpacing.sm),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: colors.surfaceVariant,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Text(
                  result.remoteCode!,
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              result.remoteVersion != null && result.remoteVersion != 'latest'
                  ? ctx.tr('发现新版本 v${result.remoteVersion}，是否更新？')
                  : ctx.tr('插件有新版本可用，是否更新？'),
              style: TextStyle(color: colors.textSecondary, fontSize: 14),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(ctx.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _applyUpdate(result);
            },
            child: Text(
              ctx.tr('更新'),
              style: const TextStyle(
                color: Color(0xFF4CAF50),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyUpdate(PluginUpdateResult result) async {
    if (!mounted) return;
    final colors = ref.read(themeColorsProvider);

    // Show loading
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(context.tr('正在更新 ${result.plugin.name}...')),
        backgroundColor: colors.primary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
      ),
    );

    try {
      // Uninstall old plugin
      await ref
          .read(pluginsProvider.notifier)
          .uninstallPlugin(result.plugin.id);

      // Determine plugin type from the updateUrl or the existing plugin
      final type = result.plugin.type;

      // Download and install the new version from the updateUrl.
      // Use result.updateUrl (from script notice or manual check) first,
      // fallback to plugin.updateUrl.
      final downloadUrl = result.updateUrl ?? result.plugin.updateUrl;
      if (downloadUrl == null || downloadUrl.isEmpty) {
        throw Exception(context.tr('无法获取插件更新地址'));
      }

      final pluginService = ref.read(pluginServiceProvider);
      final newPlugin = await pluginService.downloadAndAddPlugin(
        downloadUrl,
        type: type,
      );

      ref.invalidate(pluginInitializedProvider);
      ref.invalidate(pluginsProvider);

      // Clear buffered update notice for this plugin so it doesn't
      // show again after the page is reopened.
      ref
          .read(pluginServiceProvider)
          .clearBufferedUpdateNotice(result.plugin.id);

      // Also clear the script-initiated update notice so the UI
      // stops showing the update badge after the plugin is updated.
      final currentNotices = ref.read(pluginScriptUpdateNoticesProvider);
      final updatedNotices = currentNotices
          .where((n) => n['pluginId'] != result.plugin.id)
          .toList();
      ref.read(pluginScriptUpdateNoticesProvider.notifier).state =
          updatedNotices;

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('"${newPlugin.name} v${newPlugin.version}" 更新成功'),
              style: TextStyle(color: colors.textOnPrimary),
            ),
            backgroundColor: const Color(0xFF4CAF50),
            behavior: SnackBarBehavior.floating,
          ),
        );
        // Refresh update results
        _checkAllUpdates();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('更新失败: ${PluginManagementPage.pluginErrorMessage(e)}'),
            ),
            backgroundColor: colors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }
}

class _AddPluginSheet extends StatefulWidget {
  final ThemeColors colors;
  final WidgetRef ref;

  const _AddPluginSheet({required this.colors, required this.ref});

  @override
  State<_AddPluginSheet> createState() => _AddPluginSheetState();
}

class _AddPluginSheetState extends State<_AddPluginSheet> {
  int _selectedTab = 0;
  final _urlController = TextEditingController();
  bool _isLoading = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: AppSpacing.md),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: colors.divider,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              context.tr('添加插件'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              context.tr('支持澜音(cr)、洛雪(lx) 和 MusicFree(mf) 格式的JS插件'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
            const SizedBox(height: AppSpacing.md),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedTab = 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _selectedTab == 0
                              ? colors.primary.withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadius.full),
                          border: Border.all(
                            color: _selectedTab == 0
                                ? colors.primary
                                : colors.divider,
                          ),
                        ),
                        child: Text(
                          context.tr('从文件导入'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: _selectedTab == 0
                                ? colors.primary
                                : colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => setState(() => _selectedTab = 1),
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: _selectedTab == 1
                              ? colors.primary.withValues(alpha: 0.1)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(AppRadius.full),
                          border: Border.all(
                            color: _selectedTab == 1
                                ? colors.primary
                                : colors.divider,
                          ),
                        ),
                        child: Text(
                          context.tr('从URL下载'),
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: _selectedTab == 1
                                ? colors.primary
                                : colors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            if (_selectedTab == 0)
              _buildFileImportTab(colors)
            else
              _buildUrlDownloadTab(colors),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }

  Widget _buildFileImportTab(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              color: colors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(
                color: colors.divider,
                style: BorderStyle.solid,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.upload_file,
                  size: 40,
                  color: colors.primary.withValues(alpha: 0.6),
                ),
                const SizedBox(height: AppSpacing.md),
                Text(
                  context.tr('选择 .js 插件文件，格式将自动识别'),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  context.tr('支持澜音 / 洛雪 / MusicFree，识别失败时会让你选择类型'),
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _handleFileImport,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(context.tr('选择文件')),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.textOnPrimary,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUrlDownloadTab(ThemeColors colors) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      child: Column(
        children: [
          TextField(
            controller: _urlController,
            style: TextStyle(fontSize: 14, color: colors.textPrimary),
            decoration: InputDecoration(
              hintText: context.tr('输入插件JS文件的URL地址'),
              hintStyle: TextStyle(fontSize: 13, color: colors.textHint),
              prefixIcon: Icon(Icons.link, color: colors.textHint, size: 20),
              suffixIcon: _urlController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, color: colors.textHint, size: 18),
                      onPressed: () {
                        _urlController.clear();
                        setState(() {});
                      },
                    )
                  : IconButton(
                      icon: Icon(
                        Icons.content_paste,
                        color: colors.primary,
                        size: 18,
                      ),
                      tooltip: context.tr('粘贴链接'),
                      onPressed: _pasteFromClipboard,
                    ),
              filled: true,
              fillColor: colors.surfaceVariant,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.full),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.full),
                borderSide: BorderSide(color: colors.primary),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            context.tr('支持 HTTP/HTTPS 链接和 GitHub 仓库链接，将自动下载并校验插件格式'),
            style: TextStyle(fontSize: 11, color: colors.textHint),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _isLoading ? null : _handleUrlDownload,
              icon: _isLoading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.cloud_download, size: 18),
              label: Text(
                _isLoading ? context.tr('下载中...') : context.tr('下载并安装'),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.primary,
                foregroundColor: colors.textOnPrimary,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadius.full),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleFileImport() async {
    setState(() => _isLoading = true);
    try {
      await widget.ref.read(pluginsProvider.notifier).selectAndAddPlugin();
      if (mounted) {
        // 安装成功不再弹提示（插件卡片上就能看到）。
        Navigator.pop(context);
      }
    } on PluginTypeUnknownException catch (e) {
      // 自动识别失败：弹框让用户选类型，选完续装（不用重选文件）。
      final type = mounted ? await _promptPluginType() : null;
      if (type == null) return;
      try {
        await e.resume(type);
        if (mounted) Navigator.pop(context);
      } catch (err) {
        _showInstallError(err);
      }
    } catch (e) {
      _showInstallError(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pasteFromClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text!.isNotEmpty) {
        _urlController.text = data.text!;
        setState(() {});
      }
    } catch (_) {
      // Ignore clipboard access errors
    }
  }

  Future<void> _handleUrlDownload() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('请输入URL地址')),
          backgroundColor: widget.colors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Basic URL format validation
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('请输入有效的HTTP/HTTPS链接')),
          backgroundColor: widget.colors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isLoading = true);
    try {
      await widget.ref.read(pluginsProvider.notifier).downloadAndAddPlugin(url);
      if (mounted) {
        // 安装成功不再弹提示（插件卡片上就能看到）。
        Navigator.pop(context);
      }
    } on PluginTypeUnknownException catch (e) {
      // 自动识别失败：弹框让用户选类型，选完续装（不用重新下载）。
      final type = mounted ? await _promptPluginType() : null;
      if (type == null) return;
      try {
        await e.resume(type);
        if (mounted) Navigator.pop(context);
      } catch (err) {
        _showInstallError(err);
      }
    } catch (e) {
      _showInstallError(e);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// 自动识别插件类型失败时，让用户手动选择；取消返回 null。
  Future<String?> _promptPluginType() {
    final colors = widget.colors;
    Widget option(String label, String type, IconData icon) {
      return SimpleDialogOption(
        onPressed: () => Navigator.of(context).pop(type),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.primary),
            const SizedBox(width: AppSpacing.md),
            Text(
              context.tr(label),
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
            ),
          ],
        ),
      );
    }

    return showDialog<String>(
      context: context,
      builder: (ctx) => SimpleDialog(
        backgroundColor: colors.surface,
        title: Text(
          ctx.tr('无法识别插件类型'),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Text(
              ctx.tr('请手动选择该插件的格式：'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          option('澜音 (cr)', 'cr', Icons.graphic_eq),
          option('洛雪 (lx)', 'lx', Icons.music_note),
          option('MusicFree (mf)', 'mf', Icons.extension),
        ],
      ),
    );
  }

  void _showInstallError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(PluginManagementPage.pluginErrorMessage(error)),
        backgroundColor: widget.colors.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
