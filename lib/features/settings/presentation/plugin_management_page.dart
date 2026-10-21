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
import '../../plugin/application/music_source_manager.dart';
import '../../plugin/data/plugin_service.dart';
import '../../plugin/domain/builtin_source_states.dart';
import '../../plugin/domain/plugin_source_states.dart';
import '../../plugin/domain/plugin_types.dart';
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
    _updateNoticeSubscription = pluginService.updateNoticeStream.listen((notice) {
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
    debugPrint('[PluginManagementPage] Showing ${pending.length} buffered update notices');
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
      if (mergedResults.any((r) => r.plugin.id == pluginId && r.available)) continue;
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
          mergedResults.add(PluginUpdateResult(
            plugin: pluginInfo,
            available: true,
            remoteVersion: pluginVersion.isNotEmpty ? pluginVersion : 'latest',
            remoteCode: log,
            updateUrl: effectiveUpdateUrl,
          ));
        }
      }
    }

    final content = pluginsAsync.when(
      data: (plugins) => ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _buildAutoUpdateSection(colors),
          const SizedBox(height: AppSpacing.lg),
          _buildBuiltInSourcesSection(colors),
          const SizedBox(height: AppSpacing.lg),
          _buildPluginSectionHeader(colors, plugins.length),
          const SizedBox(height: AppSpacing.sm),
          if (plugins.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxl),
              child: _buildEmptyState(colors),
            )
          else
            ...plugins.map(
              (plugin) => _buildPluginCard(colors, plugin, mergedResults),
            ),
        ],
      ),
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
              child: Text(context.tr('重试'), style: TextStyle(color: colors.primary)),
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.tr('自动检测更新'),
                  style: TextStyle(fontSize: 14, color: colors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  context.tr('开启后进入插件管理页会自动检查插件更新'),
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
              ],
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

  /* ---------------------------------------------------------------- *
   * 内置音源（网易云 / 酷狗 / 酷我 / QQ / 咪咕）
   * ---------------------------------------------------------------- */

  Widget _buildBuiltInSourcesSection(ThemeColors colors) {
    final states = ref.watch(builtInSourceStateProvider);
    final all = MusicSourceManager.allBuiltInSourceInfos;
    final visible = all.where((info) => !states.isRemoved(info.id)).toList();
    final removedCount = all.length - visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                context.tr('内置音源'),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: colors.textPrimary,
                ),
              ),
            ),
            if (removedCount > 0)
              TextButton.icon(
                onPressed: _restoreBuiltInSources,
                icon: const Icon(Icons.restore, size: 16),
                label: Text(context.tr('恢复内置音源')),
                style: TextButton.styleFrom(
                  foregroundColor: colors.primary,
                  visualDensity: VisualDensity.compact,
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          context.tr('关闭后该音源不再出现在搜索与发现页；已收藏的歌曲仍可正常播放'),
          style: TextStyle(fontSize: 12, color: colors.textHint),
        ),
        const SizedBox(height: AppSpacing.md),
        ...visible.map((info) => _buildBuiltInSourceCard(colors, info, states)),
        if (removedCount > 0)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.xs),
            child: Text(
              context.tr('已卸载 $removedCount 个内置音源'),
              style: TextStyle(fontSize: 12, color: colors.textHint),
            ),
          ),
      ],
    );
  }

  Widget _buildBuiltInSourceCard(
    ThemeColors colors,
    SourceInfo info,
    BuiltInSourceStates states,
  ) {
    final enabled = !states.isDisabled(info.id);

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(AppRadius.lg),
        border: Border.all(
          color: colors.primary.withValues(alpha: enabled ? 0.25 : 0.08),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: colors.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Icon(Icons.library_music, size: 20, color: colors.primary),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.name,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: colors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  enabled ? context.tr('内置音源 · 已启用') : context.tr('内置音源 · 已关闭'),
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: context.tr('卸载'),
            icon: Icon(
              Icons.delete_outline,
              size: 20,
              color: colors.textHint,
            ),
            onPressed: () => _removeBuiltInSource(info),
          ),
          Switch(
            value: enabled,
            activeThumbColor: colors.primary,
            onChanged: (value) => _setBuiltInSourceEnabled(info, value),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          context.tr('插件音源（$pluginCount）'),
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: colors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          context.tr('可同时启用多个插件；多个插件声明同一音源时按列表顺序生效'),
          style: TextStyle(fontSize: 12, color: colors.textHint),
        ),
      ],
    );
  }

  Future<void> _setBuiltInSourceEnabled(SourceInfo info, bool enabled) async {
    // 开关本身就是反馈，不再弹提示。
    await ref
        .read(builtInSourceStateProvider.notifier)
        .setEnabled(info.id, enabled);
  }

  Future<void> _removeBuiltInSource(SourceInfo info) async {
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(
          ctx.tr('卸载内置音源'),
          style: TextStyle(color: colors.textPrimary, fontSize: 16),
        ),
        content: Text(
          ctx.tr('卸载「${info.name}」后它会从音源列表中移除，相关搜索与发现页数据不再可用。可通过「恢复内置音源」找回。'),
          style: TextStyle(color: colors.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(ctx.tr('取消')),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(ctx.tr('卸载')),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // 卸载结果在列表里直接可见，不再弹提示。
    await ref.read(builtInSourceStateProvider.notifier).remove(info.id);
  }

  Future<void> _restoreBuiltInSources() async {
    await ref.read(builtInSourceStateProvider.notifier).restoreAll();
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
    List<PluginUpdateResult> updateResults,
  ) {
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
                                color: const Color(0xFF4CAF50).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                context.tr('可更新 v${updateResult.remoteVersion}'),
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
          Divider(height: 1, color: colors.divider),
          SizedBox(
            height: 40,
            child: Row(
              children: [
                const SizedBox(width: AppSpacing.md),
                Icon(Icons.access_time, size: 14, color: colors.textHint),
                const SizedBox(width: 4),
                Text(
                  context.tr(
                    '${plugin.installTime.year}/${plugin.installTime.month.toString().padLeft(2, '0')}/${plugin.installTime.day.toString().padLeft(2, '0')} 安装',
                  ),
                  style: TextStyle(fontSize: 11, color: colors.textHint),
                ),
                const Spacer(),
                if (updateResult != null)
                  GestureDetector(
                    onTap: () => _showUpdateDialog(colors, updateResult),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                      ),
                      child: Text(
                        context.tr('更新'),
                        style: TextStyle(
                          fontSize: 12,
                          color: Color(0xFF4CAF50),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                // 插件测试仅对已启用插件显示：未启用的插件未加载运行时，
                // 测试服务无法解析其音源与音质，展示按钮只会误导用户。
                if (plugin.isEnabled)
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
                          result.remoteVersion != null && result.remoteVersion != 'latest'
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
                  style: TextStyle(
                    fontSize: 12,
                    color: colors.textHint,
                  ),
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
      await ref.read(pluginsProvider.notifier).uninstallPlugin(result.plugin.id);

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
        type,
      );

      ref.invalidate(pluginInitializedProvider);
      ref.invalidate(pluginsProvider);

      // Clear buffered update notice for this plugin so it doesn't
      // show again after the page is reopened.
      ref.read(pluginServiceProvider).clearBufferedUpdateNotice(result.plugin.id);

      // Also clear the script-initiated update notice so the UI
      // stops showing the update badge after the plugin is updated.
      final currentNotices = ref.read(pluginScriptUpdateNoticesProvider);
      final updatedNotices = currentNotices
          .where((n) => n['pluginId'] != result.plugin.id)
          .toList();
      ref.read(pluginScriptUpdateNoticesProvider.notifier).state = updatedNotices;

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
  String _pluginType = 'cr';
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
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              child: Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    context.tr('插件类型：'),
                    style: TextStyle(fontSize: 13, color: colors.textSecondary),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  _buildTypeChip(context.tr('澜音 (cr)'), 'cr', colors),
                  const SizedBox(width: AppSpacing.sm),
                  _buildTypeChip(context.tr('洛雪 (lx)'), 'lx', colors),
                  const SizedBox(width: AppSpacing.sm),
                  _buildTypeChip(context.tr('MusicFree (mf)'), 'mf', colors),
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

  Widget _buildTypeChip(String label, String type, ThemeColors colors) {
    final isSelected = _pluginType == type;
    return GestureDetector(
      onTap: () => setState(() => _pluginType = type),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected ? colors.primary : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.full),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: isSelected ? colors.textOnPrimary : colors.textSecondary,
          ),
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
                  context.tr(
                    '选择 ${PluginService.pluginTypeLabel(_pluginType)} 格式的 .js 插件文件',
                  ),
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: colors.textSecondary),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  context.tr(
                    switch (_pluginType) {
                      'lx' => '脚本需注册 request 事件（支持混淆插件）',
                      'mf' => '脚本需导出插件对象（支持混淆插件）',
                      _ => '脚本需包含 cerumusic 接口（支持混淆插件）',
                    },
                  ),
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
            context.tr(
              '支持 HTTP/HTTPS 链接和 GitHub 仓库链接，将自动下载并校验插件格式',
            ),
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
      await widget.ref
          .read(pluginsProvider.notifier)
          .selectAndAddPlugin(_pluginType);
      if (mounted) {
        // 安装成功不再弹提示（插件卡片上就能看到）。
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(PluginManagementPage.pluginErrorMessage(e)),
            backgroundColor: widget.colors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
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
      await widget.ref
          .read(pluginsProvider.notifier)
          .downloadAndAddPlugin(url, _pluginType);
      if (mounted) {
        // 安装成功不再弹提示（插件卡片上就能看到）。
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(PluginManagementPage.pluginErrorMessage(e)),
            backgroundColor: widget.colors.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
