import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/backup_service.dart';
import '../../../core/backup/webdav_service.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../application/settings_providers.dart';
import '../data/settings_service.dart';
import 'settings_page.dart';

/// 「备份还原」设置页。
///
/// * 一键备份 / 一键还原：本地压缩包（系统文件对话框选择位置）
/// * WebDAV 备份 / 还原：上传压缩包 / 拉取备份列表
/// * 歌单实时同步开关
class BackupRestoreContent extends ConsumerStatefulWidget {
  const BackupRestoreContent({super.key});

  @override
  ConsumerState<BackupRestoreContent> createState() =>
      _BackupRestoreContentState();
}

class _BackupRestoreContentState extends ConsumerState<BackupRestoreContent> {
  final _urlController = TextEditingController();
  final _userController = TextEditingController();
  final _passwordController = TextEditingController();
  final _deviceController = TextEditingController();

  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadConfig());
  }

  @override
  void dispose() {
    _urlController.dispose();
    _userController.dispose();
    _passwordController.dispose();
    _deviceController.dispose();
    super.dispose();
  }

  WebDavConfig get _config => ref.read(webDavConfigProvider);

  void _loadConfig() {
    final config = _config;
    _urlController.text = config.url;
    _userController.text = config.user;
    _passwordController.text = config.password;
    _deviceController.text = config.deviceName;
  }

  void _saveConfig({
    String? url,
    String? user,
    String? password,
    String? deviceName,
    bool? playlistSyncEnabled,
  }) {
    final next = _config.copyWith(
      url: url,
      user: user,
      password: password,
      deviceName: deviceName,
      playlistSyncEnabled: playlistSyncEnabled,
    );
    ref.read(webDavConfigProvider.notifier).state = next;
    final container = ProviderScope.containerOf(context);
    unawaited(
      _persist(container, (s) => s.setWebDavConfigJson(jsonEncode(next.toJson()))),
    );
  }

  Future<void> _persist(
    ProviderContainer container,
    Future<void> Function(SettingsService svc) action,
  ) async {
    try {
      final svc = await container.read(settingsServiceProvider.future);
      await action(svc);
    } catch (e) {
      debugPrint('[BackupRestore] 保存 WebDAV 配置失败: $e');
    }
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 3),
        backgroundColor: error ? Colors.red : null,
      ),
    );
  }

  // ---------------------------------------------------------------- 本地备份

  Future<void> _backupToFile() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await BackupService.createBackup();
      final fileName = BackupService.buildBackupFileName();
      final path = await FilePicker.platform.saveFile(
        dialogTitle: tr('保存备份文件'),
        fileName: fileName,
        type: FileType.any,
        bytes: bytes,
      );
      if (path == null) return; // 用户取消
      _toast(tr('备份完成'));
    } catch (e) {
      _toast(tr('备份失败：$e'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromFile() async {
    if (_busy) return;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      Uint8List? bytes = file.bytes;
      if (bytes == null && file.path != null) {
        final f = File(file.path!);
        if (await f.exists()) bytes = await f.readAsBytes();
      }
      if (bytes == null) {
        _toast(tr('无法读取所选文件'), error: true);
        return;
      }
      if (!await _confirmRestore()) return;
      setState(() => _busy = true);
      await BackupService.restoreBackup(bytes);
      _toast(tr('还原完成，请重启应用'));
    } catch (e) {
      _toast(tr('还原失败：$e'), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirmRestore() async {
    final colors = ref.read(themeColorsProvider);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(tr('确认还原'), style: TextStyle(color: colors.textPrimary)),
        content: Text(
          tr('还原会覆盖当前的应用设置、插件文件与收藏歌单，并清空临时数据，确定继续吗？'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('确定还原'), style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  // ---------------------------------------------------------------- WebDAV

  Future<void> _backupToWebDav() async {
    final config = _config;
    if (!config.isConfigured) {
      _toast(tr('请先填写 WebDAV 地址'), error: true);
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    _showProgress(tr('正在备份并上传到 WebDAV...'));
    try {
      final bytes = await BackupService.createBackup();
      final fileName = BackupService.buildBackupFileName();
      await WebDavService(config).uploadBackup(bytes, fileName);
      _closeProgress();
      _toast(tr('备份上传成功'));
    } catch (e) {
      _closeProgress();
      if (!mounted) return;
      // 失败可以重试
      final retry = await _showRetryDialog(tr('备份上传失败：$e'));
      // 延后到当前流程收尾之后再重试，避免 busy 状态被 finally 提前清掉。
      if (retry) unawaited(Future.microtask(_backupToWebDav));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromWebDav() async {
    final config = _config;
    if (!config.isConfigured) {
      _toast(tr('请先填写 WebDAV 地址'), error: true);
      return;
    }
    if (_busy) return;
    setState(() => _busy = true);
    _showProgress(tr('正在读取 WebDAV 备份列表...'));
    List<RemoteBackupFile> files;
    try {
      files = await WebDavService(config).listBackups();
    } catch (e) {
      _closeProgress();
      if (!mounted) return;
      final retry = await _showRetryDialog(tr('读取备份列表失败：$e'));
      if (retry) unawaited(Future.microtask(_restoreFromWebDav));
      if (mounted) setState(() => _busy = false);
      return;
    }
    _closeProgress();
    if (!mounted) return;
    if (files.isEmpty) {
      _toast(tr('远端没有备份文件'), error: true);
      setState(() => _busy = false);
      return;
    }

    final picked = await _pickRemoteFile(files);
    if (picked == null) {
      setState(() => _busy = false);
      return;
    }

    if (!await _confirmRestore()) {
      setState(() => _busy = false);
      return;
    }
    setState(() => _busy = true);
    _showProgress(tr('正在下载并还原...'));
    try {
      final bytes = await WebDavService(config).downloadBackup(picked.path);
      await BackupService.restoreBackup(bytes);
      _closeProgress();
      _toast(tr('还原完成，请重启应用'));
    } catch (e) {
      _closeProgress();
      if (!mounted) return;
      final retry = await _showRetryDialog(tr('还原失败：$e'));
      if (retry) unawaited(Future.microtask(_restoreFromWebDav));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 弹出远端备份列表让用户选择。
  Future<RemoteBackupFile?> _pickRemoteFile(List<RemoteBackupFile> files) async {
    final colors = ref.read(themeColorsProvider);
    return showModalBottomSheet<RemoteBackupFile>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  ctx.tr('选择一个备份文件'),
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: colors.textPrimary,
                  ),
                ),
              ),
              ...files.map(
                (f) => ListTile(
                  title: Text(
                    f.name,
                    style: TextStyle(color: colors.textPrimary, fontSize: 14),
                  ),
                  subtitle: Text(
                    [
                      if (f.modified != null)
                        '${f.modified!.year}-${f.modified!.month.toString().padLeft(2, '0')}-${f.modified!.day.toString().padLeft(2, '0')} '
                            '${f.modified!.hour.toString().padLeft(2, '0')}:${f.modified!.minute.toString().padLeft(2, '0')}',
                      _formatSize(f.size),
                    ].join(' · '),
                    style: TextStyle(color: colors.textHint, fontSize: 12),
                  ),
                  onTap: () => Navigator.pop(ctx, f),
                ),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 辅助 UI

  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _progressController;

  /// 显示一个不会自动消失的进度提示（上传 / 下载过程中用）。
  void _showProgress(String message) {
    final colors = ref.read(themeColorsProvider);
    _closeProgress();
    _progressController = ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        // 一直显示，直到任务结束主动关闭。
        persist: true,
        backgroundColor: colors.surface,
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.textPrimary, fontSize: 13),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 关闭进度提示。
  void _closeProgress() {
    _progressController?.close();
    _progressController = null;
  }

  Future<bool> _showRetryDialog(String message) async {
    final colors = ref.read(themeColorsProvider);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.surface,
        title: Text(tr('操作失败'), style: TextStyle(color: colors.textPrimary)),
        content: Text(message, style: TextStyle(color: colors.textSecondary)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('重试'), style: TextStyle(color: colors.primary)),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  static String _formatSize(int bytes) {
    if (bytes <= 0) return '';
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  // ---------------------------------------------------------------- 构建

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final config = ref.watch(webDavConfigProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SettingGroup(
          title: tr('本地备份'),
          subtitle: tr('把应用设置、插件与收藏歌单打包备份'),
          colors: colors,
          children: [
            SettingRow(
              icon: Icons.backup_outlined,
              title: tr('一键备份'),
              subtitle: tr('生成压缩包并选择保存位置'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              colors: colors,
              onTap: _busy ? null : _backupToFile,
            ),
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.settings_backup_restore,
              title: tr('一键还原'),
              subtitle: tr('选择备份压缩包，覆盖当前配置'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              colors: colors,
              onTap: _busy ? null : _restoreFromFile,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SettingGroup(
          title: tr('WebDAV 备份'),
          subtitle: tr('把备份上传到自己的 WebDAV 服务器'),
          colors: colors,
          children: [
            SettingRow(
              icon: Icons.cloud_outlined,
              title: tr('WebDAV 地址'),
              subtitle: tr('例如 https://dav.example.com/back'),
              colors: colors,
              trailing: SizedBox(
                width: 200,
                child: TextField(
                  controller: _urlController,
                  onChanged: (v) => _saveConfig(url: v),
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: 'https://dav.example.com/back',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
            ),
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.person_outline,
              title: tr('用户名'),
              colors: colors,
              trailing: SizedBox(
                width: 200,
                child: TextField(
                  controller: _userController,
                  onChanged: (v) => _saveConfig(user: v),
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
            ),
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.key_outlined,
              title: tr('密码'),
              subtitle: tr('密码输入后无法查看'),
              colors: colors,
              trailing: SizedBox(
                width: 200,
                child: TextField(
                  controller: _passwordController,
                  obscureText: true,
                  onChanged: (v) => _saveConfig(password: v),
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
            ),
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.devices_outlined,
              title: tr('设备名称'),
              subtitle: tr('备份文件保存在远端的该设备文件夹下'),
              colors: colors,
              trailing: SizedBox(
                width: 200,
                child: TextField(
                  controller: _deviceController,
                  onChanged: (v) => _saveConfig(deviceName: v),
                  style: TextStyle(fontSize: 13, color: colors.textPrimary),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
            ),
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.cloud_upload_outlined,
              title: tr('备份到 WebDAV'),
              subtitle: tr('打包后上传到远端设备目录'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              colors: colors,
              onTap: _busy ? null : _backupToWebDav,
            ),
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.cloud_download_outlined,
              title: tr('从 WebDAV 还原'),
              subtitle: tr('从远端选择一个备份文件还原'),
              trailing: const Icon(Icons.chevron_right, size: 18),
              colors: colors,
              onTap: _busy ? null : _restoreFromWebDav,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SettingGroup(
          title: tr('歌单同步'),
          subtitle: tr('多设备之间实时同步收藏的歌单'),
          colors: colors,
          children: [
            SettingRow(
              icon: Icons.sync,
              title: tr('歌单实时同步'),
              subtitle: tr('开启后每次进入应用都会与远端同步一次歌单'),
              trailing: Switch(
                value: config.playlistSyncEnabled,
                onChanged: (v) => _saveConfig(playlistSyncEnabled: v),
                activeTrackColor: colors.primary.withValues(alpha: 0.3),
                activeThumbColor: colors.primary,
              ),
              colors: colors,
            ),
          ],
        ),
        if (_busy)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.md),
            child: LinearProgressIndicator(color: colors.primary),
          ),
      ],
    );
  }
}
