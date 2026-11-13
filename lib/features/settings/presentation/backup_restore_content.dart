import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/backup_service.dart';
import '../../../core/backup/sync_timeout.dart';
import '../../../core/backup/webdav_service.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/widgets/playlist_sync_button.dart';
import '../../library/application/playlist_providers.dart';
import '../../local/application/local_providers.dart';
import '../application/backup_restore_apply.dart';
import '../application/settings_providers.dart';
import '../data/settings_service.dart';
import 'settings_page.dart';

/// 「备份还原」设置页。
///
/// * 一键备份 / 一键还原：本地压缩包（系统文件对话框选择位置）
/// * WebDAV 备份 / 还原：上传压缩包 / 拉取备份列表
/// * 自动同步开关（收藏增删改 → 歌单同步；设置变更 → 备份配置）
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

  /// 备份上传 / 远端还原的第几次尝试：首次与重试都是 2 分钟超时。
  int _backupAttempt = 0;
  int _restoreAttempt = 0;

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
    _progressText.dispose();
    // 页面在还原过程中被关掉（用户切走）时，persist 的进度条不会自己消失，
    // 这里补一刀，免得它一直挂在底部。
    try {
      _messenger?.clearSnackBars();
    } catch (_) {}
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
      _persist(
        container,
        (s) => s.setWebDavConfigJson(jsonEncode(next.toJson())),
      ),
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
    // 先用掉 context：后面有文件对话框 / 确认框等异步等待，再取容器就晚了。
    final container = ProviderScope.containerOf(context);
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
      _showProgress(tr('正在还原备份...'));
      await stopPlaybackForRestore(container);
      // 目录要在覆盖 settings.json 之前记下来（见 [_snapshotScannedDirectories]）。
      final previousDirs = await _snapshotScannedDirectories(container);
      await BackupService.restoreBackup(bytes);
      final message = await _applyRestoredBackup(
        container,
        previousDirectories: previousDirs,
      );
      _closeProgress();
      _toast(message);
    } catch (e) {
      _closeProgress();
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
        backgroundColor: colors.dialogSurface,
        title: Text(tr('确认还原'), style: TextStyle(color: colors.textPrimary)),
        content: Text(
          tr('还原会覆盖当前的应用设置、插件文件与收藏歌单，确定继续吗？'),
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
    if (_busy) return;
    _backupAttempt = 0;
    await _runBackupToWebDav();
  }

  /// 真正执行一次「备份并上传」（首次与重试都是 2 分钟超时）。
  Future<void> _runBackupToWebDav() async {
    final config = _config;
    if (!config.isConfigured) {
      _toast(tr('请先填写 WebDAV 地址'), error: true);
      return;
    }
    if (_busy) return;
    _backupAttempt += 1;
    setState(() => _busy = true);
    _showProgress(tr('正在备份并上传到 WebDAV...'));
    try {
      final bytes = await BackupService.createBackup();
      final fileName = BackupService.buildBackupFileName();
      // 服务器「连上了但一直不回」时不能让进度条无限转，整次上传套 2 分钟超时；
      // 超时会连带取消这次 PUT 请求，并把具体失败原因写进提示。
      final op = SyncAttempt(_backupAttempt);
      final webdav = WebDavService(config, cancelToken: op.cancelToken);
      op.attachDiagnosis(() => webdav.diagnosis);
      await op.run(webdav.uploadBackup(bytes, fileName));
      _closeProgress();
      _toast(tr('备份上传成功'));
    } catch (e) {
      _closeProgress();
      if (!mounted) return;
      // 失败可以重试
      final retry = await _showRetryDialog(
        tr('备份上传失败：${describeWebDavError(e)}'),
      );
      // 延后到当前流程收尾之后再重试，避免 busy 状态被 finally 提前清掉。
      if (retry) unawaited(Future.microtask(_runBackupToWebDav));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restoreFromWebDav() async {
    if (_busy) return;
    _restoreAttempt = 0;
    await _runRestoreFromWebDav();
  }

  /// 真正执行一次「读取列表 → 下载还原」（超时按 [_restoreAttempt]）。
  Future<void> _runRestoreFromWebDav() async {
    final config = _config;
    if (!config.isConfigured) {
      _toast(tr('请先填写 WebDAV 地址'), error: true);
      return;
    }
    if (_busy) return;
    // 同 [_restoreFromFile]：后面有一串异步等待，先取好容器。
    final container = ProviderScope.containerOf(context);
    _restoreAttempt += 1;
    setState(() => _busy = true);
    _showProgress(tr('正在读取 WebDAV 备份列表...'));
    List<RemoteBackupFile> files;
    try {
      final listOp = SyncAttempt(_restoreAttempt);
      final webdav = WebDavService(config, cancelToken: listOp.cancelToken);
      listOp.attachDiagnosis(() => webdav.diagnosis);
      files = await listOp.run(webdav.listBackups());
    } catch (e) {
      _closeProgress();
      if (!mounted) return;
      final retry = await _showRetryDialog(
        tr('读取备份列表失败：${describeWebDavError(e)}'),
      );
      if (retry) unawaited(Future.microtask(_runRestoreFromWebDav));
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
    _resetDownloadSpeed();
    _showProgress(tr('正在下载并还原...'));
    try {
      // 下载耗时与包体积成正比：备份里连插件目录一起打，几十 MB 很常见，
      // 固定总超时会让「慢但没断」的下载被判失败。按体积估一个
      // 下限（40KB/s），最少 3 分钟、最多 15 分钟。
      final downloadOp = SyncAttempt(
        _restoreAttempt,
        overwriteTimeout: _downloadTimeoutFor(picked.size),
      );
      final webdav = WebDavService(config, cancelToken: downloadOp.cancelToken);
      downloadOp.attachDiagnosis(() => webdav.diagnosis);
      final bytes = await downloadOp.run(
        webdav.downloadBackup(
          picked.path,
          expectedSize: picked.size > 0 ? picked.size : null,
          onProgress: _paintDownloadProgress,
        ),
      );
      await stopPlaybackForRestore(container);
      // 同上：还原前先把扫描目录记下来，还原后拿它和备份里的比较。
      final previousDirs = await _snapshotScannedDirectories(container);
      await BackupService.restoreBackup(bytes);
      final message = await _applyRestoredBackup(
        container,
        previousDirectories: previousDirs,
      );
      _closeProgress();
      _toast(message);
    } catch (e) {
      _closeProgress();
      if (!mounted) return;
      final retry = await _showRetryDialog(
        tr('还原失败：${describeWebDavError(e)}'),
      );
      if (retry) unawaited(Future.microtask(_runRestoreFromWebDav));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 弹出远端备份列表让用户选择（可删除远端备份）。
  Future<RemoteBackupFile?> _pickRemoteFile(List<RemoteBackupFile> files) {
    return showModalBottomSheet<RemoteBackupFile>(
      useRootNavigator: true,
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) =>
          _RemoteBackupSheet(files: files, service: WebDavService(_config)),
    );
  }

  // ---------------------------------------------------------------- 辅助 UI

  /// 最近一次显示进度用的 messenger：关闭进度 / 页面销毁时要靠它清队列。
  ScaffoldMessengerState? _messenger;

  /// 进度提示里的当前文字。
  ///
  /// 做成可监听的值：下载几十 MB 的备份时按已下字节数刷新，否则底部那条
  /// 「正在下载并还原...」会一动不动挂上几分钟，看着像卡死。
  final ValueNotifier<String> _progressText = ValueNotifier<String>('');

  /// 进度文字上一次刷新的时间：分片回调每秒可达数百次，节流到 200ms。
  DateTime _lastProgressPaint = DateTime.fromMillisecondsSinceEpoch(0);

  /// 本次下载的速度计时：从第一个数据块开始算，用于「平均每秒多少」。
  final Stopwatch _downloadWatch = Stopwatch();

  /// 速度基准字节数：断点续传时从续传点起算，不把已落盘的部分算成本次流量。
  int _downloadSpeedBase = 0;

  /// 是否已经在计时（第一次收到数据块时置位）。
  bool _downloadCounting = false;

  /// 开始一次新的下载：把速度基准清掉，避免上一次还原的数字被继承。
  void _resetDownloadSpeed() {
    _downloadWatch
      ..reset()
      ..stop();
    _downloadSpeedBase = 0;
    _downloadCounting = false;
  }

  /// 下载备份的超时时长：按 40KB/s 估，最少 3 分钟、最多 15 分钟。
  ///
  /// 体积未知（服务器 PROPFIND 没给 size）时按 5 分钟算，够下一个几十 MB 的包。
  static Duration _downloadTimeoutFor(int bytes) {
    if (bytes <= 0) return const Duration(minutes: 5);
    final estimate = Duration(
      milliseconds: (bytes / (40 * 1024) * 1000).round(),
    );
    final total = const Duration(minutes: 3) + estimate;
    if (total > const Duration(minutes: 15)) return const Duration(minutes: 15);
    return total;
  }

  /// 把下载进度写进底部提示（节流，见 [_lastProgressPaint]）。
  void _paintDownloadProgress(int received, int total) {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastProgressPaint).inMilliseconds < 200) return;
    _lastProgressPaint = now;

    // 第一次回调 / 服务端忽略 Range 从头重下（字节数回退）时重置基准，
    // 否则算出来的是负数或把上一轮的字节算进这一轮。
    if (!_downloadCounting || received < _downloadSpeedBase) {
      _downloadSpeedBase = received;
      _downloadWatch
        ..reset()
        ..start();
      _downloadCounting = true;
    }
    // 不足 1 秒的读数会被第一个分片带飞，先不显示，等窗口够长再说。
    final elapsedMs = _downloadWatch.elapsedMilliseconds;
    final speed = elapsedMs >= 1000
        ? (received - _downloadSpeedBase) * 1000 / elapsedMs
        : 0.0;
    final speedLabel = _formatSpeed(speed);
    final got = _formatSize(received);

    if (total <= 0) {
      _progressText.value = speedLabel.isEmpty
          ? tr('正在下载备份 $got...')
          : tr('正在下载备份 $got · $speedLabel');
      return;
    }
    final percent = (received * 100 / total).clamp(0, 100).toStringAsFixed(0);
    final sizeLabel = '$got / ${_formatSize(total)}（$percent%）';
    _progressText.value = speedLabel.isEmpty
        ? tr('正在下载备份 $sizeLabel')
        : tr('正在下载备份 $sizeLabel · $speedLabel');
  }

  /// 速度文案（如 `1.2 MB/s`）：还看不出速度时返回空串，不显示占位的 `-`。
  static String _formatSpeed(double bytesPerSec) {
    if (bytesPerSec <= 0) return '';
    if (bytesPerSec < 1024) return '${bytesPerSec.toStringAsFixed(0)} B/s';
    final kb = bytesPerSec / 1024;
    // 四舍五入后可能到 1024.0，提前进位到 MB/s，避免出现「1024.0 KB/s」。
    if (kb < 1023.95) return '${kb.toStringAsFixed(1)} KB/s';
    return '${(bytesPerSec / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  /// 显示一个不会自动消失的进度提示（上传 / 下载过程中用）。
  void _showProgress(String message) {
    if (!mounted) return;
    _progressText.value = message;
    final colors = ref.read(themeColorsProvider);
    final messenger = ScaffoldMessenger.of(context);
    _messenger = messenger;
    // 先清掉所有旧提示再显示新的。
    //
    // 这些进度条是 `persist: true`（不会自己消失），而 showSnackBar 是排队
    // 显示的：之前只 close 自己手里那个，前面几条还在队列里没来得及显示，
    // 等最后一条关掉后它们又会顶上来，于是「还原已完成，底部还挂着一句
    // 正在应用还原的电台 / 黑名单 / 本地目录…」。clearSnackBars 能连队列
    // 一起清干净。
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        // 一直显示，直到任务结束主动关闭。
        persist: true,
        backgroundColor: colors.dialogSurface,
        content: Row(
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: ValueListenableBuilder<String>(
                valueListenable: _progressText,
                builder: (_, text, _) => Text(
                  text,
                  style: TextStyle(color: colors.textPrimary, fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 关闭进度提示。
  void _closeProgress() {
    // 同样用 clearSnackBars：队列里剩下的旧进度条一并清掉，不会留下一条
    // persist 的提示永远停在底部。
    final messenger = _messenger;
    if (messenger != null) {
      try {
        messenger.clearSnackBars();
      } catch (_) {}
    }
  }

  /// 还原后的热应用：设置 / 字体 / 歌单 / 进度立即生效，插件重新加载。
  ///
  /// 返回要提示给用户的那句话：插件没能重载（超时 / 失败）时如实说明要先重启，
  /// 不要假装一切都好了。
  Future<String> _applyRestoredBackup(
    ProviderContainer container, {
    List<String>? previousDirectories,
  }) async {
    var pluginsReloaded = true;
    try {
      pluginsReloaded = await applyRestoredBackup(
        container,
        previousDirectories: previousDirectories,
        onProgress: (message) {
          if (!mounted) return;
          _showProgress(tr(message));
        },
      );
    } finally {
      // 还原出的 WebDAV 配置可能和输入框里的不一样，同步一次，免得之后
      // 随手改一个字段又把旧值写回去。
      if (mounted) _loadConfig();
    }
    return pluginsReloaded ? tr('还原完成，已重新加载音源') : tr('还原完成；音源重载超时，重启应用后生效');
  }

  /// 记录还原前的扫描目录。
  ///
  /// 还原会把 settings.json 整个换掉，之后就查不到「原来扫的是哪些目录」了；
  /// 拿它和备份里的目录比较，不一致就说明本地歌曲索引已经过期（还是旧目录的
  /// 歌），需要补一次自动扫描。
  Future<List<String>?> _snapshotScannedDirectories(
    ProviderContainer container,
  ) async {
    try {
      return await container
          .read(localMusicRepositoryProvider)
          .readConfiguredDirectories();
    } catch (e) {
      debugPrint('[BackupRestore] 读取还原前扫描目录失败: $e');
      return null;
    }
  }

  Future<bool> _showRetryDialog(String message) async {
    final colors = ref.read(themeColorsProvider);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
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

  // ---------------------------------------------------------------- 布局组件

  /// 左侧图标 + 标题，下面一个整行宽度的输入框（截图里的 WebDAV 配置样式）。
  Widget _labeledField({
    required ThemeColors colors,
    required IconData icon,
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
    bool obscure = false,
    String? hintText,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 18, color: colors.textSecondary),
            const SizedBox(width: AppSpacing.sm),
            Text(
              label,
              style: TextStyle(fontSize: 14, color: colors.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          obscureText: obscure,
          onChanged: onChanged,
          style: TextStyle(fontSize: 13, color: colors.textPrimary),
          decoration: InputDecoration(
            isDense: true,
            hintText: hintText,
            hintStyle: TextStyle(fontSize: 13, color: colors.textHint),
            filled: true,
            // 比卡片底色更暗，输入框边界一眼能看出来。
            fillColor: colors.background,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: BorderSide(
                color: colors.primary.withValues(alpha: 0.6),
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: 11,
            ),
          ),
        ),
      ],
    );
  }

  /// 并排的两个胶囊按钮（同一套中性描边样式）。
  Widget _pairButtons({
    required ThemeColors colors,
    required String leftLabel,
    required IconData leftIcon,
    required VoidCallback? onLeft,
    required String rightLabel,
    required IconData rightIcon,
    required VoidCallback? onRight,
  }) {
    return Row(
      children: [
        Expanded(
          child: _pairButton(
            colors: colors,
            icon: leftIcon,
            label: leftLabel,
            onTap: onLeft,
          ),
        ),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: _pairButton(
            colors: colors,
            icon: rightIcon,
            label: rightLabel,
            onTap: onRight,
          ),
        ),
      ],
    );
  }

  Widget _pairButton({
    required ThemeColors colors,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
  }) {
    return _PairButton(colors: colors, icon: icon, label: label, onTap: onTap);
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
          colors: colors,
          children: [
            _pairButtons(
              colors: colors,
              leftLabel: tr('一键备份'),
              leftIcon: Icons.cloud_upload_outlined,
              onLeft: _busy ? null : _backupToFile,
              rightLabel: tr('一键还原'),
              rightIcon: Icons.settings_backup_restore,
              onRight: _busy ? null : _restoreFromFile,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SettingGroup(
          title: tr('WebDAV 备份'),
          colors: colors,
          children: [
            _labeledField(
              colors: colors,
              icon: Icons.cloud_outlined,
              label: tr('WebDAV 地址'),
              controller: _urlController,
              onChanged: (v) => _saveConfig(url: v),
              hintText: 'https://dav.example.com/back',
            ),
            const SizedBox(height: AppSpacing.md),
            _labeledField(
              colors: colors,
              icon: Icons.person_outline,
              label: tr('用户名'),
              controller: _userController,
              onChanged: (v) => _saveConfig(user: v),
            ),
            const SizedBox(height: AppSpacing.md),
            _labeledField(
              colors: colors,
              icon: Icons.key_outlined,
              label: tr('密码'),
              controller: _passwordController,
              onChanged: (v) => _saveConfig(password: v),
              obscure: true,
            ),
            const SizedBox(height: AppSpacing.md),
            _labeledField(
              colors: colors,
              icon: Icons.devices_outlined,
              label: tr('设备名称'),
              controller: _deviceController,
              onChanged: (v) => _saveConfig(deviceName: v),
            ),
            const SizedBox(height: AppSpacing.lg),
            _pairButtons(
              colors: colors,
              leftLabel: tr('备份到 WebDAV'),
              leftIcon: Icons.cloud_upload_outlined,
              onLeft: _busy ? null : _backupToWebDav,
              rightLabel: tr('从 WebDAV 还原'),
              rightIcon: Icons.cloud_download_outlined,
              onRight: _busy ? null : _restoreFromWebDav,
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SettingGroup(
          title: tr('自动同步'),
          colors: colors,
          children: [
            SettingRow(
              icon: Icons.sync,
              title: tr('自动同步'),
              trailing: Switch(
                value: config.playlistSyncEnabled,
                onChanged: (v) {
                  _saveConfig(playlistSyncEnabled: v);
                  // 开启后立刻同步一次（窗口底部会显示同步提示）。
                  if (v) unawaited(syncPlaylistsNow(ref));
                },
                activeTrackColor: colors.primary.withValues(alpha: 0.3),
                activeThumbColor: colors.primary,
              ),
              colors: colors,
            ),
            SettingDivider(colors: colors),
            SettingRow(
              icon: Icons.sync,
              title: tr('立即同步'),
              trailing: const PlaylistSyncButton(alsoBackup: true),
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

/// 远端备份选择列表：点击条目还原，右侧按钮删除远端文件。
class _RemoteBackupSheet extends ConsumerStatefulWidget {
  const _RemoteBackupSheet({required this.files, required this.service});

  final List<RemoteBackupFile> files;
  final WebDavService service;

  @override
  ConsumerState<_RemoteBackupSheet> createState() => _RemoteBackupSheetState();
}

class _RemoteBackupSheetState extends ConsumerState<_RemoteBackupSheet> {
  late final List<RemoteBackupFile> _files;
  final Set<String> _deleting = {};

  @override
  void initState() {
    super.initState();
    _files = List.of(widget.files);
  }

  Future<void> _confirmDelete(RemoteBackupFile file) async {
    if (_deleting.contains(file.path)) return;
    final colors = ref.read(themeColorsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: colors.dialogSurface,
        title: Text(tr('删除远端备份'), style: TextStyle(color: colors.textPrimary)),
        content: Text(
          tr('确定删除「${file.name}」吗？删除后无法恢复。'),
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('取消'), style: TextStyle(color: colors.textHint)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('删除'), style: TextStyle(color: colors.error)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _deleting.add(file.path));
    try {
      await widget.service.deleteBackup(file.path);
      if (!mounted) return;
      setState(() => _files.removeWhere((f) => f.path == file.path));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('已删除远端备份')),
          duration: const Duration(seconds: 2),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      final message = describeWebDavError(e);
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: colors.dialogSurface,
          title: Text(tr('删除失败'), style: TextStyle(color: colors.textPrimary)),
          content: SingleChildScrollView(
            child: Text(
              tr('删除远端备份失败：\n$message'),
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(tr('确定'), style: TextStyle(color: colors.primary)),
            ),
          ],
        ),
      );
    } finally {
      if (mounted) setState(() => _deleting.remove(file.path));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = ref.watch(themeColorsProvider);
    final maxHeight = MediaQuery.of(context).size.height * 0.7;

    return Container(
      constraints: BoxConstraints(maxHeight: maxHeight),
      decoration: BoxDecoration(
        color: colors.dialogSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppSpacing.lg,
                AppSpacing.md,
                AppSpacing.sm,
                0,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tr('选择一个备份文件'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, size: 20, color: colors.textHint),
                  ),
                ],
              ),
            ),
            if (_files.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text(
                  tr('远端没有备份文件'),
                  style: TextStyle(color: colors.textHint, fontSize: 13),
                ),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _files.length,
                  itemBuilder: (context, index) {
                    final file = _files[index];
                    final deleting = _deleting.contains(file.path);
                    return ListTile(
                      title: Text(
                        file.name,
                        style: TextStyle(
                          color: colors.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                      subtitle: Text(
                        [
                          if (file.modified != null)
                            '${file.modified!.year}-${file.modified!.month.toString().padLeft(2, '0')}-${file.modified!.day.toString().padLeft(2, '0')} '
                                '${file.modified!.hour.toString().padLeft(2, '0')}:${file.modified!.minute.toString().padLeft(2, '0')}',
                          _BackupRestoreContentState._formatSize(file.size),
                        ].join(' · '),
                        style: TextStyle(color: colors.textHint, fontSize: 12),
                      ),
                      trailing: deleting
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : IconButton(
                              tooltip: tr('删除远端备份'),
                              onPressed: () => _confirmDelete(file),
                              icon: Icon(
                                Icons.delete_outline,
                                size: 20,
                                color: colors.error,
                              ),
                            ),
                      onTap: deleting
                          ? null
                          : () => Navigator.pop(context, file),
                    );
                  },
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
      ),
    );
  }
}

/// 备份 / 还原胶囊按钮：桌面端悬浮时给背景加一层淡色，明确可点击。
class _PairButton extends StatefulWidget {
  final ThemeColors colors;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _PairButton({
    required this.colors,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_PairButton> createState() => _PairButtonState();
}

class _PairButtonState extends State<_PairButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final enabled = widget.onTap != null;
    final color = enabled ? colors.textPrimary : colors.textHint;
    final borderColor = enabled
        ? colors.divider
        : colors.divider.withValues(alpha: 0.5);
    final hoverColor = colors.textPrimary;

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) {
        if (enabled && !_hovered) setState(() => _hovered = true);
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(AppRadius.full),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          height: 34,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hovered && enabled
                ? hoverColor.withValues(alpha: 0.07)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.full),
            border: Border.all(color: borderColor),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 13, color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
