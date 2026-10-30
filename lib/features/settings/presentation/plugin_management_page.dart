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
import '../../plugin/data/source_health_store.dart';
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/domain/plugin_source_states.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../plugin/domain/source_health.dart';
import '../../plugin/domain/source_login_state.dart';
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

  /// 数据源卡片里的「播放源」区：自动匹配的同平台播放源**有序列表**。
  ///
  /// 用户不需要手动挑播放源——列表由「已启用 + 能解析地址 + 支持该数据源平台」
  /// 自动得出，按插件安装时间升序（先装的在前）。拖动调整后覆盖自动顺序，
  /// 靠上的优先使用；播放失败自动切到下一个，全部失败才停止播放。
  Widget _buildDataSourcePlaybackRow(
    ThemeColors colors,
    PluginInfo plugin, {
    required WidgetRef ref,
  }) {
    final manager = ref.read(musicSourceManagerProvider);
    ref.watch(dataSourcePlaybackSourcesProvider);
    ref.watch(pluginSupportedSourcesProvider);
    ref.watch(pluginSourceStateProvider);

    final sources = manager.dataSourcePlaybackSourcesFor(plugin.id);

    if (sources.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(
          left: AppSpacing.md,
          right: AppSpacing.md,
          bottom: AppSpacing.xs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 14, color: colors.error),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                context.tr('没有可用的同平台播放源，请安装或启用对应的洛雪格式音源插件'),
                style: TextStyle(fontSize: 12, color: colors.error),
              ),
            ),
          ],
        ),
      );
    }

    final customized = manager
        .configuredPlaybackSourcesFor(plugin.id)
        .isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        bottom: AppSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.play_circle_outline,
                size: 16,
                color: colors.textHint,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  context.tr('播放源（自动匹配，按优先级）'),
                  style: TextStyle(fontSize: 12, color: colors.textSecondary),
                ),
              ),
              if (customized)
                InkWell(
                  onTap: () => _resetDataSourcePlaybackSources(plugin),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    child: Text(
                      context.tr('恢复自动'),
                      style: TextStyle(fontSize: 11, color: colors.primary),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: sources.length,
            onReorder: (oldIndex, newIndex) =>
                _reorderDataSourcePlaybackSources(
                  plugin,
                  sources,
                  oldIndex,
                  newIndex,
                ),
            itemBuilder: (context, index) {
              final sourceId = sources[index];
              return _buildPlaybackSourceTile(
                colors,
                manager,
                sourceId: sourceId,
                index: index,
                key: ValueKey('${plugin.id}_$sourceId'),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.only(left: 22, top: 2),
            child: Text(
              context.tr(
                '拖动调整顺序，靠上优先；全部失败则停止播放（只统计洛雪格式音源）',
              ),
              style: TextStyle(fontSize: 11, color: colors.textHint),
            ),
          ),
        ],
      ),
    );
  }

  /// 单个播放源条目：序号 + 名称 + 登录态 + 可用音质 + 拖动手柄。
  Widget _buildPlaybackSourceTile(
    ThemeColors colors,
    MusicSourceManager manager, {
    required String sourceId,
    required int index,
    required Key key,
  }) {
    final name = manager.sourceDisplayName(sourceId);
    final loginState = manager.loginStateForSourceId(sourceId);
    final qualities = manager.getQualitiesForSourceId(sourceId);
    final playable = [
      for (final quality in qualities)
        if (!manager
            .getLoginGatedQualities(sourceId)
            .contains(quality))
          quality,
    ];
    final qualityText = qualities.isEmpty
        ? context.tr('音质未声明')
        : (playable.length == qualities.length
              ? qualities.join(' · ')
              : '${playable.join(' · ')}（需登录：'
                    '${qualities.length - playable.length} 档）');

    final (Color? badgeColor, String? badgeText) = switch (loginState) {
      SourceLoginState.loggedIn => (colors.primary, context.tr('已登录')),
      SourceLoginState.loggedOut => (colors.textHint, context.tr('未登录')),
      SourceLoginState.expired => (colors.error, context.tr('登录已失效')),
      SourceLoginState.unknown => (null, null),
    };

    return Padding(
      key: key,
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              '${index + 1}',
              style: TextStyle(fontSize: 11, color: colors.textHint),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.textPrimary,
                        ),
                      ),
                    ),
                    if (badgeText != null) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: badgeColor!.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          badgeText,
                          style: TextStyle(fontSize: 9, color: badgeColor),
                        ),
                      ),
                    ],
                  ],
                ),
                Text(
                  qualityText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10, color: colors.textHint),
                ),
              ],
            ),
          ),
          ReorderableDragStartListener(
            index: index,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Icon(
                Icons.drag_handle,
                size: 16,
                color: colors.textHint,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 拖动排序：保存完整顺序（覆盖自动发现结果）。
  ///
  /// 保存前过滤掉拖拽期间被卸载 / 关闭的插件，避免把失效 id 写进配置。
  Future<void> _reorderDataSourcePlaybackSources(
    PluginInfo plugin,
    List<String> current,
    int oldIndex,
    int newIndex,
  ) async {
    if (oldIndex == newIndex) return;
    final list = List<String>.from(current);
    final target = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final item = list.removeAt(oldIndex);
    list.insert(target.clamp(0, list.length), item);

    final manager = ref.read(musicSourceManagerProvider);
    final cleaned = [
      for (final id in list)
        // 只保留「还能用 + 落雪格式」的源：拖动期间被卸载 / 关闭的、以及
        // 历史配置里混进来的 MusicFree / 澜音 源都要剔掉。
        if (manager.isAutoSwitchEligible(id)) id,
    ];
    if (cleaned.isEmpty) return;
    await setDataSourcePlaybackSources(
      ref,
      pluginId: plugin.id,
      sourceIds: cleaned,
    );
  }

  /// 恢复自动顺序（清掉用户手动排序）。
  Future<void> _resetDataSourcePlaybackSources(PluginInfo plugin) async {
    await setDataSourcePlaybackSources(
      ref,
      pluginId: plugin.id,
      sourceIds: const [],
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
    // 音源健康红标：数据存在 SourceHealthStore（不是 Riverpod 状态），
    // watch 版本号才能在标记变化后重建这张卡片。
    ref.watch(pluginSourceHealthRevisionProvider);
    final healthEntries = SourceHealthStore.entriesForPlugin(plugin.id);
    final healthTimeouts = [
      for (final entry in healthEntries)
        if (entry.status == SourceHealthStatus.timeout) entry,
    ];
    final healthFailures = [
      for (final entry in healthEntries)
        if (entry.status == SourceHealthStatus.failed) entry,
    ];
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
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Wrap：名称太长时红标自动换到下一行，不会挤出屏幕。
                          Flexible(
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  plugin.name,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: colors.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
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
                                if (updateResult != null)
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
                                if (healthTimeouts.isNotEmpty)
                                  _buildSourceHealthChip(
                                    plugin,
                                    SourceHealthStatus.timeout,
                                    healthTimeouts,
                                  ),
                                if (healthFailures.isNotEmpty)
                                  _buildSourceHealthChip(
                                    plugin,
                                    SourceHealthStatus.failed,
                                    healthFailures,
                                  ),
                              ],
                            ),
                          ),
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
          // 登录 / 凭据：插件声明了 credentials 或 login 时才出现。
          _PluginCredentialSection(plugin: plugin, colors: colors),
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

  /// 音源健康红标（「失败」/「超时」）。
  ///
  /// 同一状态的音源合并成一个标，超过 1 个时带数量；点击弹窗列出明细并
  /// 支持一键清除（用户要求「可手动清除」）。
  Widget _buildSourceHealthChip(
    PluginInfo plugin,
    SourceHealthStatus status,
    List<SourceHealthEntry> entries,
  ) {
    const red = Color(0xFFE53935);
    final text = entries.length > 1
        ? '${context.tr(status.label)} ${entries.length}'
        : context.tr(status.label);
    return GestureDetector(
      onTap: () => _showSourceHealthDialog(plugin, status, entries),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: red.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: red.withValues(alpha: 0.35), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              status == SourceHealthStatus.timeout
                  ? Icons.timer_off_outlined
                  : Icons.error_outline,
              size: 10,
              color: red,
            ),
            const SizedBox(width: 2),
            Text(
              text,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: red,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 红标明细弹窗：说清「哪个音源 + 什么时候 + 为什么」，可一键清除。
  Future<void> _showSourceHealthDialog(
    PluginInfo plugin,
    SourceHealthStatus status,
    List<SourceHealthEntry> entries,
  ) async {
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        title: Text(
          ctx.tr('清除「${status.label}」标记'),
          style: TextStyle(color: colors.textPrimary, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ctx.tr('这些音源在自动换源时失败了，标记只是提示，不影响继续尝试：'),
              style: TextStyle(color: colors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: AppSpacing.sm),
            ...entries.map((entry) {
              final at = entry.at;
              final time =
                  '${at.month}/${at.day} '
                  '${at.hour.toString().padLeft(2, '0')}:'
                  '${at.minute.toString().padLeft(2, '0')}';
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• ${_healthSourceLabel(plugin, entry)}（$time）'
                  '${entry.reason == null ? '' : '：${entry.reason}'}',
                  style: TextStyle(fontSize: 12, color: colors.textHint),
                ),
              );
            }),
            const SizedBox(height: AppSpacing.sm),
            Text(
              ctx.tr('测试音源通过或后续播放成功后也会自动清除。'),
              style: TextStyle(fontSize: 11, color: colors.textHint),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              ctx.tr('清除标记'),
              style: TextStyle(color: colors.primary),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    for (final entry in entries) {
      await SourceHealthStore.clear(entry.sourceId);
    }
  }

  /// 红标里显示的音源名：优先用插件自己声明的名字，其次平台名。
  String _healthSourceLabel(PluginInfo plugin, SourceHealthEntry entry) {
    for (final source in plugin.supportedSources) {
      final id = source.id ?? SourceIdMapping.deriveId(source.name);
      if (id != entry.baseId) continue;
      if (source.name.trim().isNotEmpty) return source.name;
    }
    return SourceIdMapping.idToName[entry.baseId] ?? entry.baseId;
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

      // 插件 id 是安装时间戳，更新后必然换一个新 id：把旧的「数据源 → 播放源」
      // 配置搬到新插件上（并清掉旧的那条），否则更新完数据源就变成「未设置」，
      // 收藏里的歌直接放不了。
      final oldMapping =
          ref.read(dataSourcePlaybackSourcesProvider)[result.plugin.id] ??
          const <String>[];
      if (oldMapping.isNotEmpty) {
        await setDataSourcePlaybackSources(
          ref,
          pluginId: newPlugin.id,
          sourceIds: oldMapping,
        );
        await setDataSourcePlaybackSources(
          ref,
          pluginId: result.plugin.id,
          sourceIds: const [],
        );
      }

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

/// 插件「登录 / 凭据」区（需求 1）。
///
/// 只有在插件声明了 `credentials`（要用户填的 cookie / api key / 卡密）或
/// `login`（高音质需要登录）时才渲染。字段完全由插件声明驱动：
///
/// ```js
/// credentials: [{ key: 'MUSIC_U', label: 'MUSIC_U', secret: true, hint: '…' }]
/// ```
///
/// 保存后立刻通过 `lx.getUserVariables()` 注入正在运行的插件（不用重启 App），
/// 并自动检测一次登录态。
class _PluginCredentialSection extends ConsumerStatefulWidget {
  const _PluginCredentialSection({required this.plugin, required this.colors});

  final PluginInfo plugin;
  final ThemeColors colors;

  @override
  ConsumerState<_PluginCredentialSection> createState() =>
      _PluginCredentialSectionState();
}

class _PluginCredentialSectionState
    extends ConsumerState<_PluginCredentialSection> {
  final Map<String, TextEditingController> _controllers = {};
  bool _loading = true;
  bool _saving = false;
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final values = await ref
        .read(pluginServiceProvider)
        .loadCredentials(widget.plugin.id);
    if (!mounted) return;
    setState(() {
      values.forEach((key, value) {
        _controllers
                .putIfAbsent(key, () => TextEditingController())
                .text =
            value;
      });
      _loading = false;
    });
  }

  /// 这个插件所有音源声明的凭据字段（按 key 去重）。
  ///
  /// 优先读运行时声明（插件更新后立即生效），退回持久化的元数据。
  List<SourceCredentialSpec> get _specs {
    final manager = ref.read(musicSourceManagerProvider);
    final result = <String, SourceCredentialSpec>{};
    for (final source in widget.plugin.supportedSources) {
      final key = source.id ?? SourceIdMapping.deriveId(source.name);
      final sourceId = '$key@${widget.plugin.id}';
      var declared = manager.credentialsForSource(sourceId);
      if (declared.isEmpty) declared = source.credentials;
      for (final spec in declared) {
        result.putIfAbsent(spec.key, () => spec);
      }
    }
    return result.values.toList();
  }

  /// 是否有音源声明「高音质需要登录」。
  bool get _needsLogin =>
      widget.plugin.supportedSources.any((s) => s.login?.required == true);

  Future<void> _save() async {
    final values = <String, String>{};
    for (final spec in _specs) {
      final text = _controllers[spec.key]?.text.trim() ?? '';
      if (text.isNotEmpty) values[spec.key] = text;
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(pluginServiceProvider)
          .saveCredentials(widget.plugin.id, values);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            values.isEmpty
                ? context.tr('已清空凭据')
                : context.tr('凭据已保存，并已重新注入插件'),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      await _checkLoginStatus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr('保存凭据失败：$e')),
          backgroundColor: widget.colors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// 主动检测登录态（只有把 `loginStatus` 写进 actions 的插件能真正检测）。
  Future<void> _checkLoginStatus() async {
    setState(() => _checking = true);
    try {
      final service = ref.read(pluginServiceProvider);
      for (final source in widget.plugin.supportedSources) {
        final key = source.id ?? SourceIdMapping.deriveId(source.name);
        await service.requestLoginStatus(widget.plugin.id, key);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final specs = _specs;
    if (!_needsLogin && specs.isEmpty) return const SizedBox.shrink();

    // 登录态变化（自动检测 / 手动检测）时重建，刷出新徽标。
    ref.watch(pluginLoginStateRevisionProvider);
    final service = ref.read(pluginServiceProvider);
    final states = <String, SourceLoginState>{
      for (final source in widget.plugin.supportedSources)
        if (source.login != null || source.credentials.isNotEmpty)
          (source.id ?? SourceIdMapping.deriveId(source.name)): service
              .loginStateOf(
                widget.plugin.id,
                source.id ?? SourceIdMapping.deriveId(source.name),
              ),
    };

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.key_outlined, size: 14, color: colors.textHint),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  context.tr('登录 / 凭据'),
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
              ),
              if (_checking)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6),
                )
              else
                GestureDetector(
                  onTap: _checkLoginStatus,
                  child: Text(
                    context.tr('检测登录态'),
                    style: TextStyle(fontSize: 11, color: colors.primary),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 2),
          for (final entry in states.entries)
            if (entry.value != SourceLoginState.unknown)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Text(
                  '${SourceIdMapping.idToName[entry.key] ?? entry.key}：'
                  '${entry.value.label}',
                  style: TextStyle(
                    fontSize: 11,
                    color: entry.value == SourceLoginState.loggedIn
                        ? colors.primary
                        : (entry.value == SourceLoginState.expired
                              ? colors.error
                              : colors.textHint),
                  ),
                ),
              ),
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                context.tr('正在读取凭据…'),
                style: TextStyle(fontSize: 11, color: colors.textHint),
              ),
            )
          else ...[
            for (final spec in specs) ...[
              const SizedBox(height: 6),
              TextField(
                controller: _controllers.putIfAbsent(
                  spec.key,
                  () => TextEditingController(),
                ),
                obscureText: spec.secret,
                style: TextStyle(fontSize: 12, color: colors.textPrimary),
                decoration: InputDecoration(
                  isDense: true,
                  labelText: spec.label,
                  labelStyle: TextStyle(fontSize: 12, color: colors.textHint),
                  helperText: spec.hint,
                  helperMaxLines: 2,
                  helperStyle: TextStyle(
                    fontSize: 10,
                    color: colors.textHint,
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.tr('凭据会包含在备份文件中，请勿分享备份'),
                    style: TextStyle(
                      fontSize: 10,
                      color: colors.textHint.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _saving ? null : _save,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _saving ? context.tr('保存中…') : context.tr('保存'),
                    style: TextStyle(fontSize: 12, color: colors.primary),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
