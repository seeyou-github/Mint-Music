import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../../core/platform/app_paths.dart';
import '../../../core/storage/app_preferences.dart';
import '../platform/js_engine_service.dart';
import '../data/plugin_host.dart';
import '../data/lx_plugin_converter.dart';
import '../domain/source_id_mapping.dart';
import '../../settings/domain/models/plugin_info.dart';

class PluginService {
  static const String _prefsKey = 'installed_plugins';

  /// MusicFree 适配器资源路径。
  ///
  /// MusicFree 插件不需要按插件生成代码：适配器在运行时通过
  /// `module.exports` 捕获器读取插件元数据，所以所有 MusicFree 插件共用同一个
  /// 适配器脚本，存储时也保存这一份（升级 App 后会自动刷新）。
  static const String _musicFreeAdapterAsset =
      'assets/plugin_modules/musicfree_adapter.js';

  /// 插件类型 → 展示名。
  static String pluginTypeLabel(String type) {
    switch (type) {
      case 'lx':
        return '洛雪';
      case 'mf':
        return 'MusicFree';
      default:
        return '澜音';
    }
  }
  final Map<String, PluginHost> _loadedPlugins = {};
  final Map<String, JsEngineService> _engines = {};

  /// Broadcast stream that merges update notices from ALL loaded plugin engines.
  final _updateNoticeController =
      StreamController<Map<String, dynamic>>.broadcast();

  /// Stream of update notices emitted by any loaded plugin.
  /// Each event is a map with keys: `type`, `data`, `pluginName`, `pluginVersion`.
  Stream<Map<String, dynamic>> get updateNoticeStream =>
      _updateNoticeController.stream;

  final List<StreamSubscription<Map<String, dynamic>>> _noticeSubscriptions = [];

  /// Buffered update notices from plugin scripts (persists across stream
  /// subscribers being added/removed). The UI reads this when the plugin
  /// management page opens to catch notices that arrived earlier.
  final List<Map<String, dynamic>> _bufferedUpdateNotices = [];

  /// Retrieve all buffered plugin-initiated update notices.
  /// The buffer is NOT cleared so that repeated opens of the plugin
  /// management page still show the update notification.
  List<Map<String, dynamic>> getBufferedUpdateNotices() {
    return List<Map<String, dynamic>>.from(_bufferedUpdateNotices);
  }

  /// Clear a specific plugin's buffered update notice (e.g. after the
  /// user updates or dismisses it).
  void clearBufferedUpdateNotice(String pluginId) {
    _bufferedUpdateNotices.removeWhere((n) => n['pluginId'] == pluginId);
  }

  /// Clear all buffered update notices.
  void clearAllBufferedUpdateNotices() {
    _bufferedUpdateNotices.clear();
  }

  Future<List<PluginInfo>> loadPlugins() async {
    final prefs = await AppPreferences.getInstance();
    final data = prefs.getString(_prefsKey);
    if (data == null) return [];
    final list = jsonDecode(data) as List<dynamic>;
    return list
        .map((e) => PluginInfo.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> savePlugins(List<PluginInfo> plugins) async {
    final prefs = await AppPreferences.getInstance();
    final data = jsonEncode(plugins.map((p) => p.toJson()).toList());
    await prefs.setString(_prefsKey, data);
  }

  Future<String> _getPluginsDir() async {
    final pluginsDir = await AppPaths.pluginDirectory();
    await _migrateLegacyPlugins(pluginsDir);
    return pluginsDir.path;
  }

  /// 把旧版插件目录（`文档\plugins`）里的插件文件复制到新的插件目录。
  ///
  /// 插件列表存在设置里（会随设置一起迁移），文件也要一起搬过去，否则插件
  /// 会被标记为已安装却加载失败。文件名带插件 id，复制后无需改动设置。
  Future<void> _migrateLegacyPlugins(Directory target) async {
    if (!Platform.isWindows) return;
    try {
      final legacyRoot = await getApplicationDocumentsDirectory();
      final legacyDir = Directory(
        p.join(legacyRoot.path, AppPaths.pluginFolderName),
      );
      if (!await legacyDir.exists()) return;
      if (legacyDir.path == target.path) return;

      final files = legacyDir
          .listSync(followLinks: false)
          .whereType<File>()
          .toList();
      if (files.isEmpty) return;
      for (final file in files) {
        final dest = File(p.join(target.path, p.basename(file.path)));
        if (await dest.exists()) continue;
        await file.copy(dest.path);
      }
      print('[PluginService] 已迁移旧插件目录: ${legacyDir.path}');
    } catch (e) {
      print('[PluginService] 迁移旧插件目录失败: $e');
    }
  }

  Future<PluginInfo> selectAndAddPlugin(String type) async {
    final result = await FilePicker.platform.pickFiles(
      dialogTitle: '请选择你的 ${pluginTypeLabel(type)} js插件',
      type: FileType.custom,
      allowedExtensions: ['js'],
    );

    if (result == null || result.files.isEmpty) {
      throw Exception('未选择文件');
    }

    final filePath = result.files.single.path;
    if (filePath == null) {
      throw Exception('无法获取文件路径');
    }

    final file = File(filePath);
    final fileName = file.uri.pathSegments.last;
    String pluginCode = await file.readAsString();
    String? originalPluginCode;

    _validatePluginCode(pluginCode, type);

    if (type == 'lx') {
      originalPluginCode = pluginCode;
      final converter = LxPluginConverter();
      pluginCode = converter.convert(pluginCode);
    } else if (type == 'mf') {
      originalPluginCode = pluginCode;
      pluginCode = await _loadMusicFreeAdapter();
    }

    return await addPlugin(
      pluginCode,
      fileName,
      type,
      originalPluginCode: originalPluginCode,
    );
  }

  Future<PluginInfo> downloadAndAddPlugin(String url, String type) async {
    // Normalize URL (e.g., convert GitHub blob URLs to raw URLs)
    url = _normalizePluginUrl(url);

    final dio = Dio();
    String pluginCode;
    try {
      // Use ResponseType.bytes to guarantee raw bytes — Dio with
      // ResponseType.plain may still parse JSON bodies, which breaks
      // when the server returns a JSON-wrapped plugin download.
      final response = await dio.get(
        url,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {
            'User-Agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
            'Accept': '*/*',
          },
          receiveTimeout: const Duration(seconds: 30),
          followRedirects: true,
          maxRedirects: 10,
        ),
      );

      if (response.statusCode != 200) {
        throw Exception('下载失败: HTTP ${response.statusCode}');
      }

      pluginCode = _decodeResponseBody(response.data);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout) {
        throw Exception('下载超时，请检查网络连接后重试');
      }
      if (e.type == DioExceptionType.connectionError) {
        throw Exception('无法连接到服务器，请检查网络连接');
      }
      throw Exception('下载失败: ${e.message}');
    }

    // Strip UTF-8 BOM if present
    if (pluginCode.startsWith('\uFEFF')) {
      pluginCode = pluginCode.substring(1);
    }

    if (pluginCode.trim().isEmpty) {
      throw Exception('下载的文件内容为空');
    }

    _validatePluginCode(pluginCode, type);

    String? originalPluginCode;
    if (type == 'lx') {
      originalPluginCode = pluginCode;
      final converter = LxPluginConverter();
      pluginCode = converter.convert(pluginCode);
    } else if (type == 'mf') {
      originalPluginCode = pluginCode;
      pluginCode = await _loadMusicFreeAdapter();
    }

    final fileName = 'downloaded_${DateTime.now().millisecondsSinceEpoch}.js';
    return await addPlugin(
      pluginCode,
      fileName,
      type,
      originalPluginCode: originalPluginCode,
      sourceUrl: url,
    );
  }

  /// Decode raw response bytes to a plugin script string.
  ///
  /// Some LX plugin download APIs return the JS code directly, while
  /// others wrap it in a JSON response (e.g. `{"data": "..."}` or
  /// `["..."]`). This method handles both cases:
  /// 1. If the bytes decode to raw JS code, return it directly.
  /// 2. If they look like JSON, parse and try to extract the JS content
  ///    from common wrapper patterns.
  String _decodeResponseBody(dynamic data) {
    // data should be List<int> from ResponseType.bytes
    if (data is! List<int>) {
      return data.toString();
    }
    final text = utf8.decode(data, allowMalformed: true);
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';

    // If it starts with /\* or looks like JS, return as-is
    if (trimmed.startsWith('/*') ||
        trimmed.startsWith('//') ||
        trimmed.startsWith('function') ||
        trimmed.startsWith('var ') ||
        trimmed.startsWith('const ') ||
        trimmed.startsWith('let ') ||
        trimmed.startsWith('class ') ||
        trimmed.startsWith('"use strict"') ||
        trimmed.startsWith("'use strict'")) {
      return text;
    }

    // Try to extract JS from JSON wrapper
    try {
      final json = jsonDecode(trimmed);
      return _extractScriptFromJson(json);
    } catch (_) {
      // Not JSON — return raw text as-is (may be JS that doesn't
      // start with a common prefix)
      return text;
    }
  }

  /// Recursively search a parsed JSON value for a string that looks
  /// like a JavaScript plugin script.
  String _extractScriptFromJson(dynamic json) {
    // String that looks like JS code
    if (json is String) {
      return json;
    }
    // Array — try each element
    if (json is List) {
      for (final item in json) {
        if (item is String && item.length > 50) {
          return item;
        }
        if (item is Map || item is List) {
          final result = _extractScriptFromJson(item);
          if (result.isNotEmpty) return result;
        }
      }
      // Fallback: join string elements
      final strings = json.whereType<String>();
      if (strings.isNotEmpty) return strings.first;
    }
    // Object — look for common keys first, then recurse
    if (json is Map) {
      for (final key in ['data', 'code', 'content', 'script', 'body',
          'result', 'response']) {
        if (json.containsKey(key)) {
          final value = json[key];
          if (value is String && value.length > 50) return value;
          if (value is Map || value is List) {
            final result = _extractScriptFromJson(value);
            if (result.isNotEmpty) return result;
          }
        }
      }
      // Generic: search all values
      for (final value in json.values) {
        if (value is String && value.length > 100) return value;
        if (value is Map || value is List) {
          final result = _extractScriptFromJson(value);
          if (result.isNotEmpty) return result;
        }
      }
    }
    return '';
  }

  /// Normalize plugin URLs to handle common patterns.
  ///
  /// Converts GitHub blob URLs to raw content URLs so users can paste either
  /// format and it will work:
  /// - `https://github.com/{owner}/{repo}/blob/{branch}/{path}`
  /// - `https://github.com/{owner}/{repo}/raw/{branch}/{path}`
  ///
  /// Also handles Gitee blob URLs similarly.
  String _normalizePluginUrl(String url) {
    // Convert GitHub blob URLs to raw content URLs
    // https://github.com/{owner}/{repo}/blob/{branch}/{path}
    // → https://raw.githubusercontent.com/{owner}/{repo}/{branch}/{path}
    final githubBlobPattern = RegExp(
      r'^https?://github\.com/([^/]+/[^/]+)/blob/([^?#]+)',
    );
    final blobMatch = githubBlobPattern.firstMatch(url);
    if (blobMatch != null) {
      final repoPath = blobMatch.group(1);
      final branchAndPath = blobMatch.group(2);
      return 'https://raw.githubusercontent.com/$repoPath/$branchAndPath';
    }

    // Convert Gitee blob URLs to raw content URLs
    // https://gitee.com/{owner}/{repo}/blob/{branch}/{path}
    // → https://gitee.com/{owner}/{repo}/raw/{branch}/{path}
    final giteeBlobPattern = RegExp(
      r'^https?://gitee\.com/([^/]+/[^/]+)/blob/([^?#]+)',
    );
    final giteeMatch = giteeBlobPattern.firstMatch(url);
    if (giteeMatch != null) {
      final repoPath = giteeMatch.group(1);
      final branchAndPath = giteeMatch.group(2);
      return 'https://gitee.com/$repoPath/raw/$branchAndPath';
    }

    return url;
  }

  /// 插件代码的静态粗筛。
  ///
  /// 真正的格式判定放在运行时（执行脚本后检查导出的插件对象），与
  /// MusicFree 官方一致。这里只做非常宽松的筛查：混淆过的插件不会把
  /// `module.exports`、`platform` 之类的关键字原样写出来（可能写成
  /// `module['exports']`，甚至经由变量间接赋值），只靠关键字判断会把
  /// 能正常运行的插件挡在门外。
  void _validatePluginCode(String code, String type) {
    final lower = code.toLowerCase();
    final looksLikeJsModule =
        lower.contains('module') ||
        lower.contains('exports') ||
        lower.contains('require(');

    if (type == 'cr') {
      if (!lower.contains('cerumusic') && !looksLikeJsModule) {
        throw Exception('澜音插件格式校验失败：代码中未找到cerumusic或exports');
      }
    } else if (type == 'lx') {
      // LX plugins typically contain lx-related identifiers.
      // Check multiple common patterns to be more lenient.
      final hasLxKeyword = lower.contains('lx');
      final hasModuleExports = lower.contains('module.exports');
      final hasLxComment = RegExp(r'/\*[\s\S]*@name[\s\S]*\*/').hasMatch(code);
      if (!hasLxKeyword && !hasModuleExports && !hasLxComment && !looksLikeJsModule) {
        throw Exception(
          '洛雪插件格式校验失败：代码中未找到lx关键字或module.exports',
        );
      }
    } else if (type == 'mf') {
      // MusicFree 插件是打包后的 CommonJS 模块。混淆后的插件不会把
      // `module.exports` 原样写出来，因此不再要求出现该字面量，能不能用
      // 由运行时的插件对象检查决定（找不到导出的插件对象会直接报错）。
      final hasPluginFeature =
          lower.contains('platform') ||
          lower.contains('getmediasource') ||
          lower.contains('supportedsearchtype') ||
          lower.contains('gettoplists') ||
          lower.contains('getmusicinfo');
      if (!hasPluginFeature && !looksLikeJsModule) {
        throw Exception(
          'MusicFree 插件格式校验失败：代码中未找到platform/getMediaSource等插件特征',
        );
      }
    }
  }

  /// 读取 MusicFree 适配器脚本（所有 MusicFree 插件共用）。
  Future<String> _loadMusicFreeAdapter() async {
    final adapter = await rootBundle.loadString(_musicFreeAdapterAsset);
    if (adapter.trim().isEmpty) {
      throw Exception('MusicFree 适配器资源缺失，请重新安装应用');
    }
    return adapter;
  }

  Future<PluginInfo> addPlugin(
    String pluginCode,
    String pluginName,
    String type, {
    String? originalPluginCode,
    String? sourceUrl,
  }) async {
    final engine = JsEngineService();
    await engine.init();

    try {
      final host = PluginHost(engine);
      await host.loadPlugin(pluginCode, originalPluginCode: originalPluginCode);

      final pluginInfo = host.pluginInfo;
      if (pluginInfo == null) {
        throw Exception('插件信息不完整');
      }

      final plugins = await loadPlugins();
      final duplicate = plugins.where(
        (p) => p.name == pluginInfo.name && p.version == pluginInfo.version,
      );
      if (duplicate.isNotEmpty) {
        engine.dispose();
        throw Exception(
          '插件 "${pluginInfo.name} v${pluginInfo.version}" 已存在，不能重复添加',
        );
      }

      final pluginId = DateTime.now().millisecondsSinceEpoch.toRadixString(16);
      final safeName = pluginName.replaceAll(RegExp(r'[^\w\d-]'), '_');
      final pluginsDir = await _getPluginsDir();
      final destPath = '$pluginsDir/${pluginId}_$safeName';
      final destFile = File(destPath);
      await destFile.writeAsString(pluginCode);
      if (originalPluginCode != null && originalPluginCode.trim().isNotEmpty) {
        await File('$destPath.source.js').writeAsString(originalPluginCode);
      }

      final sources = host.sources
          .map(
            (s) => PluginSource(
              id: s.id,
              name: s.name,
              qualities: s.qualities,
            ),
          )
          .toList();

      final plugin = PluginInfo(
        id: pluginId,
        name: pluginInfo.name,
        version: pluginInfo.version,
        author: pluginInfo.author,
        description: pluginInfo.description ?? '',
        type: type,
        installTime: DateTime.now(),
        supportedSources: sources,
        filePath: destPath,
        // 新添加的插件默认启用（用户可在插件管理里随时关闭）。
        isEnabled: true,
        updateUrl: pluginInfo.homepage ?? sourceUrl,
      );

      plugins.add(plugin);
      await savePlugins(plugins);

      if (plugin.isEnabled) {
        _loadedPlugins[pluginId] = host;
        _engines[pluginId] = engine;
      } else {
        engine.dispose();
      }
      return plugin;
    } catch (e) {
      engine.dispose();
      rethrow;
    }
  }

  Future<void> initializePlugins() async {
    final plugins = await _normalizeEnabledPlugins(await loadPlugins());
    _unloadAllPlugins();
    print('[PluginService] 开始初始化插件，共 ${plugins.length} 个插件');

    for (final plugin in plugins) {
      print(
        '[PluginService] 检查插件: ${plugin.name}, isEnabled: ${plugin.isEnabled}',
      );
      if (!plugin.isEnabled || plugin.filePath == null) continue;

      try {
        print('[PluginService] 加载插件文件: ${plugin.filePath}');
        final host = await _loadPlugin(plugin);

        print(
          '[PluginService] 插件 ${plugin.name} 加载成功，源数量: ${host.sources.length}',
        );
        for (final source in host.sources) {
          print(
            '[PluginService]   - 源: ${source.name}, 音质: ${source.qualities.join(", ")}',
          );
        }
      } catch (e, stackTrace) {
        print('[PluginService] Failed to load plugin ${plugin.name}: $e');
        print('[PluginService] StackTrace: $stackTrace');
      }
    }

    print('[PluginService] 插件初始化完成，已加载 ${_loadedPlugins.length} 个插件');
  }

  PluginHost? getPluginById(String pluginId) {
    final host = _loadedPlugins[pluginId];
    if (host != null && !host.isRuntimeHealthy) {
      print('[PluginService] 插件运行时已故障，隔离并卸载: $pluginId');
      _unloadPlugin(pluginId);
      return null;
    }
    return host;
  }

  /// 插件测试专用：为指定插件创建运行时。
  ///
  /// 已启用的插件直接复用全局宿主（不持有引擎）；未启用的插件临时加载
  /// 独立 JS 引擎与宿主，不影响全局启用状态。隔离运行时使用完毕后必须
  /// 调用 [PluginTestRuntime.dispose] 释放引擎。
  Future<PluginTestRuntime> createTestRuntime(PluginInfo plugin) async {
    final loaded = getPluginById(plugin.id);
    if (loaded != null) {
      return PluginTestRuntime._shared(loaded);
    }

    final filePath = plugin.filePath;
    if (filePath == null) {
      throw Exception('插件文件路径不存在');
    }
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('插件文件不存在: $filePath');
    }
    final prepared = await _prepareStoredPluginCode(plugin, file);

    final engine = JsEngineService();
    try {
      await engine.init();
      final host = PluginHost(engine);
      await host.loadPlugin(
        prepared.code,
        originalPluginCode: prepared.originalCode,
      );
      return PluginTestRuntime._isolated(host, engine);
    } on StackOverflowError catch (e) {
      engine.dispose();
      throw Exception('插件加载失败：${_friendlyPluginError(e)}');
    } catch (_) {
      engine.dispose();
      rethrow;
    }
  }

  Future<void> uninstallPlugin(String id) async {
    final plugins = await loadPlugins();
    final plugin = plugins.where((p) => p.id == id).firstOrNull;

    if (plugin?.filePath != null) {
      final file = File(plugin!.filePath!);
      if (await file.exists()) {
        await file.delete();
      }
      final sourceFile = File('${file.path}.source.js');
      if (await sourceFile.exists()) {
        await sourceFile.delete();
      }
    }

    _unloadPlugin(id);

    plugins.removeWhere((p) => p.id == id);
    await savePlugins(plugins);
  }

  Future<void> togglePlugin(String id, bool isEnabled) async {
    final plugins = await loadPlugins();
    final index = plugins.indexWhere((p) => p.id == id);
    if (index == -1) return;

    if (!isEnabled) {
      plugins[index] = plugins[index].copyWith(isEnabled: false);
      await savePlugins(plugins);
      _unloadPlugin(id);
      return;
    }

    final selectedPlugin = plugins[index];
    final wasAlreadyLoaded = getPluginById(id) != null;
    try {
      // Validate and prepare the new runtime before turning off the active
      // plugin, so a corrupt plugin cannot leave music sources unavailable.
      await _loadPlugin(selectedPlugin);
    } catch (e) {
      print(
        '[PluginService] Failed to enable plugin ${selectedPlugin.name}: $e',
      );
      rethrow;
    }

    // 多个插件可以同时启用，这里只更新目标插件的状态，不再影响其它插件。
    final updatedPlugins = plugins
        .map(
          (plugin) => plugin.id == id
              ? plugin.copyWith(isEnabled: true)
              : plugin,
        )
        .toList();
    try {
      await savePlugins(updatedPlugins);
    } catch (_) {
      // Do not leave a newly-created runtime host active when persistence
      // fails, otherwise the in-memory state would disagree with the switch.
      if (!wasAlreadyLoaded) {
        _unloadPlugin(id);
      }
      rethrow;
    }
  }

  /// 允许多个插件同时启用。
  ///
  /// 早期版本只允许启用一个插件（澜音/洛雪插件通常覆盖全部音源，互相冲突），
  /// 但 MusicFree 插件往往是「单平台」的（例如一个 bilibili 插件 + 一个网易
  /// 插件），只允许启用一个会让用户无法同时使用。多个插件声明同一个音源时，
  /// 由 [MusicSourceManager] 按插件列表顺序取第一个匹配的宿主。
  Future<List<PluginInfo>> _normalizeEnabledPlugins(
    List<PluginInfo> plugins,
  ) async {
    return plugins;
  }

  Future<PluginHost> _loadPlugin(PluginInfo plugin) async {
    final existingHost = _loadedPlugins[plugin.id];
    if (existingHost != null) {
      if (existingHost.isRuntimeHealthy) return existingHost;
      _unloadPlugin(plugin.id);
    }

    final filePath = plugin.filePath;
    if (filePath == null) {
      throw Exception('插件文件路径不存在');
    }

    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('插件文件不存在: $filePath');
    }

    final prepared = await _prepareStoredPluginCode(plugin, file);
    print('[PluginService] 插件代码长度: ${prepared.code.length} 字符');

    final engine = JsEngineService();
    try {
      await engine.init();
      final host = PluginHost(engine);

      // Subscribe to update notices BEFORE loading the plugin, because
      // LX plugins call lx.send('updateAlert', ...) during initialization
      // (inside loadPlugin). If we subscribe after, the broadcast stream
      // drops the event since there are no subscribers yet.
      final subscription = host.updateNotices.listen((notice) {
        final enriched = {
          ...notice,
          'pluginName': plugin.name,
          'pluginVersion': plugin.version,
          'pluginId': plugin.id,
        };
        _updateNoticeController.add(enriched);
        // Buffer the notice so the UI can retrieve it even if the page
        // is not currently open.
        _bufferedUpdateNotices.add(enriched);
      });
      _noticeSubscriptions.add(subscription);

      await host.loadPlugin(
        prepared.code,
        originalPluginCode: prepared.originalCode,
      );
      _loadedPlugins[plugin.id] = host;
      _engines[plugin.id] = engine;

      return host;
    } on StackOverflowError catch (e) {
      engine.dispose();
      throw Exception('插件加载失败：${_friendlyPluginError(e)}');
    } catch (_) {
      engine.dispose();
      rethrow;
    }
  }

  /// 把底层 JS/Dart 异常转成用户可读的失败原因，避免 UI 直接展示晦涩的
  /// "Stack Overflow" 原始文本。
  String _friendlyPluginError(Object error) {
    final text = error.toString();
    if (text.contains('stack overflow') || text.contains('Stack Overflow')) {
      return '插件脚本过大或递归过深，JS 引擎栈溢出，请更换精简版插件';
    }
    if (text.startsWith('Exception: ')) {
      return text.substring('Exception: '.length);
    }
    return text;
  }

  void _unloadPlugin(String id) {
    _loadedPlugins.remove(id);
    _engines.remove(id)?.dispose();
    // Cancel notice subscriptions for this plugin.
    // Subscriptions are not tracked per-plugin ID, so we cancel all
    // and re-subscribe surviving plugins if needed. In practice,
    // _unloadAllPlugins is called before re-initialization.
  }

  void _unloadAllPlugins() {
    for (final sub in _noticeSubscriptions) {
      sub.cancel();
    }
    _noticeSubscriptions.clear();
    for (final engine in _engines.values) {
      engine.dispose();
    }
    _engines.clear();
    _loadedPlugins.clear();
  }

  /// Rebuild old LX converter output after an app update. Installed plugins
  /// are stored as converted JavaScript, so otherwise an app update would
  /// leave users running the old adapter forever.
  Future<_PreparedPluginCode> _prepareStoredPluginCode(
    PluginInfo plugin,
    File file,
  ) async {
    final code = await file.readAsString();

    if (plugin.type == 'mf') {
      // MusicFree 插件存储的是「适配器 + .source.js 原始插件源码」。适配器随
      // App 升级更新，所以每次加载都从资源里重新读取，避免用户永久停留在旧
      // 适配器上。
      final sourceFile = File('${file.path}.source.js');
      String? originalCode;
      if (await sourceFile.exists()) {
        originalCode = await sourceFile.readAsString();
      }
      if (originalCode == null || originalCode.trim().isEmpty) {
        // 适配器本身没有任何音源，只有配合原始插件源码才有意义。缺少源码时
        // 明确报错，比加载出一个「0 个音源」的插件更容易让用户理解。
        throw Exception(
          'MusicFree 插件 ${plugin.name} 缺少原始源码文件（.source.js），请删除后重新添加',
        );
      }

      final adapterCode = await _loadMusicFreeAdapter();
      if (adapterCode != code) {
        await file.writeAsString(adapterCode);
        print('[PluginService] refreshed MusicFree adapter: ${plugin.name}');
      }
      return _PreparedPluginCode(
        code: adapterCode,
        originalCode: originalCode,
      );
    }

    if (plugin.type != 'lx') {
      return _PreparedPluginCode(code: code);
    }

    final sourceFile = File('${file.path}.source.js');
    String? originalCode;
    if (await sourceFile.exists()) {
      originalCode = await sourceFile.readAsString();
    } else {
      originalCode = _extractEmbeddedOriginalCode(code);
    }
    if (originalCode == null || originalCode.trim().isEmpty) {
      return _PreparedPluginCode(code: code);
    }

    final convertedCode = LxPluginConverter().convert(originalCode);
    if (convertedCode != code) {
      await file.writeAsString(convertedCode);
      print('[PluginService] migrated legacy LX plugin: ${plugin.name}');
    }
    if (!await sourceFile.exists()) {
      await sourceFile.writeAsString(originalCode);
    }
    return _PreparedPluginCode(code: convertedCode, originalCode: originalCode);
  }

  String? _extractEmbeddedOriginalCode(String code) {
    final match = RegExp(
      r'''(?:var|let|const)\s+originalPluginCode\s*=\s*("(?:\\.|[^"\\])*")\s*;''',
    ).firstMatch(code);
    if (match == null) return null;

    try {
      final value = jsonDecode(match.group(1)!);
      return value is String ? value : null;
    } catch (_) {
      return null;
    }
  }

  List<PluginHost> get enabledPlugins {
    final faultedIds = _loadedPlugins.entries
        .where((entry) => !entry.value.isRuntimeHealthy)
        .map((entry) => entry.key)
        .toList();
    for (final id in faultedIds) {
      print('[PluginService] 自动隔离故障插件运行时: $id');
      _unloadPlugin(id);
    }
    return _loadedPlugins.values.toList();
  }

  /// 返回某个插件宿主对应的插件 id。
  ///
  /// 不同作者的插件可能提供同名同平台的音源，需要靠插件 id 区分它们。
  String? getPluginIdForHost(PluginHost host) {
    for (final entry in _loadedPlugins.entries) {
      if (identical(entry.value, host)) return entry.key;
    }
    return null;
  }

  List<String> getSupportedSourceIds() {
    final sourceIds = <String>{};
    for (final host in enabledPlugins) {
      for (final source in host.sources) {
        final id = SourceIdMapping.knownId(source.name);
        if (id != null) sourceIds.add(id);
      }
    }
    return sourceIds.toList();
  }

  void dispose() {
    _unloadAllPlugins();
    _updateNoticeController.close();
  }
}

class _PreparedPluginCode {
  const _PreparedPluginCode({required this.code, this.originalCode});

  final String code;
  final String? originalCode;
}

/// 插件测试运行时：包装 [PluginHost]，区分复用全局宿主与隔离临时宿主。
class PluginTestRuntime {
  PluginTestRuntime._shared(this._host) : _engine = null;
  PluginTestRuntime._isolated(this._host, JsEngineService engine)
    : _engine = engine;

  final PluginHost _host;
  final JsEngineService? _engine;

  PluginHost get host => _host;

  /// 是否复用全局已加载宿主（此时 dispose 不做任何事）。
  bool get isShared => _engine == null;

  /// 释放隔离运行时的 JS 引擎；共享运行时无操作。
  void dispose() {
    _engine?.dispose();
  }
}
