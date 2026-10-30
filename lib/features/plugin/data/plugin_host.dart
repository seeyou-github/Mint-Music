import 'dart:convert';
import '../../player/domain/models/lyric_line.dart';
import '../platform/js_engine_service.dart';
import '../domain/plugin_types.dart';
import '../domain/source_login_state.dart';
import '../../../shared/utils/display_name_sanitizer.dart';

class PluginHost {
  final JsEngineService _engine;
  PluginMetadata? _pluginInfo;

  /// 运行时是否识别为落雪（LX）适配器（适配器会暴露 `__lxInited`）。
  ///
  /// 混淆过的落雪脚本无法靠静态关键字判断，安装时记下的 `PluginInfo.type`
  /// 万一不准，这里还能兜住；音源切换列表据此把落雪音源过滤掉。
  bool _isLxAdapter = false;
  List<PluginSourceInfo> _sources = [];
  Map<String, List<String>> _sourceActions = {};
  Map<String, bool> _capabilities = const {};

  /// 插件支持的搜索类型（music / album / artist）。
  List<String> _searchTypes = const ['music'];

  /// 是否是「数据源」插件（只提供元数据、不解析播放地址）。
  ///
  /// 由插件自己声明：`pluginInfo.isDataSource === true`（也兼容顶层
  /// `isDataSource` / `dataSource` 与 `pluginInfo.type === 'dataSource'`）。
  bool _isDataSource = false;

  /// 每个音源最近一次的登录态检测结果（key = 插件内的源 id，如 `wy`）。
  ///
  /// 来源优先级：`loginStatus` action 的返回值 > `lx.send('loginStatus')`
  /// 上报 > 插件 `sources[x].login.state` 静态声明。宿主只缓存，不做推断。
  final Map<String, SourceLoginState> _loginStates = {};

  /// 每个音源的账号信息（插件上报的昵称之类，可空），仅用于界面展示。
  final Map<String, String> _loginAccounts = {};

  bool _loaded = false;
  bool _apiInjected = false;

  PluginHost(this._engine);

  bool get isLoaded => _loaded;
  bool get isRuntimeHealthy => _engine.isRuntimeHealthy;
  PluginMetadata? get pluginInfo => _pluginInfo;

  /// 运行时是否识别为落雪（LX）格式的适配器。
  bool get isLxAdapter => _isLxAdapter;
  List<PluginSourceInfo> get sources => _sources;
  Map<String, List<String>> get sourceActions => _sourceActions;
  Map<String, bool> get capabilities => _capabilities;

  /// 音源的登录态；没检测过、或插件不支持检测时返回 `unknown`。
  SourceLoginState loginStateOf(String sourceId) =>
      _loginStates[sourceId] ?? SourceLoginState.unknown;

  /// 插件上报的账号昵称（没上报则为 null）。
  String? loginAccountOf(String sourceId) => _loginAccounts[sourceId];

  /// 宿主侧写入登录态（例如插件返回 401 后标记 `expired`）。
  void setLoginState(String sourceId, SourceLoginState state, {String? account}) {
    _loginStates[sourceId] = state;
    if (account != null && account.trim().isNotEmpty) {
      _loginAccounts[sourceId] = account.trim();
    }
  }

  /// 把插件 `sources[x].login.state` 的静态声明灌进缓存（不覆盖已有结果）。
  void _seedLoginStatesFromSources() {
    for (final source in _sources) {
      final id = source.id;
      final login = source.login;
      if (id == null || login == null) continue;
      if (login.state == SourceLoginState.unknown) continue;
      _loginStates.putIfAbsent(id, () => login.state);
    }
  }

  /// 插件是否声明自己是「数据源」。
  bool get isDataSource => _isDataSource;

  /// 插件是否提供榜单（getTopLists + getTopListDetail）。
  bool get supportsTopLists => _capabilities['topList'] == true;

  /// 插件是否提供推荐歌单分类与歌单列表（getRecommendSheetTags + ...ByTag）。
  bool get supportsRecommendSheets => _capabilities['sheets'] == true;

  /// 插件是否提供歌单详情（getMusicSheetInfo）。
  bool get supportsSheetDetail => _capabilities['sheetDetail'] == true;

  /// 插件是否支持搜索歌单（MusicFree 的 sheet 类型搜索）。
  bool get supportsPlaylistSearch => _capabilities['playlistSearch'] == true;

  /// 插件是否声明支持「自定义歌单」（歌单内容由它的搜索接口提供）。
  bool get supportsCustomSheets =>
      _capabilities['customSheets'] == true ||
      (_pluginInfo?.customSheets ?? false);

  /// 插件支持的搜索类型（music / album / artist）。
  List<String> get supportedSearchTypes => _searchTypes;

  /// 是否支持搜索专辑 / 作者（MusicFree 插件的 supportedSearchType 决定）。
  bool get supportsAlbumSearch => _searchTypes.contains('album');
  bool get supportsArtistSearch => _searchTypes.contains('artist');

  /// 插件是否能在发现页提供内容（榜单 / 推荐歌单 / 自定义歌单）。
  bool get supportsDiscover =>
      supportsTopLists ||
      supportsRecommendSheets ||
      supportsSheetDetail ||
      supportsCustomSheets;

  /// Stream of update notices emitted by this plugin's JS engine.
  /// Each event is the raw notice map from the engine (with `type` and `data`).
  Stream<Map<String, dynamic>> get updateNotices =>
      _engine.pluginNoticeStream.where((e) => e['type'] == 'update');

  /// Convenience getter for the engine's raw notice stream.
  JsEngineService get engine => _engine;

  Future<void> loadPlugin(
    String pluginCode, {
    String? originalPluginCode,
    Map<String, String> userVariables = const {},
  }) async {
    try {
      // 用户凭据必须在插件脚本执行前注入：不少插件在初始化阶段就会用
      // cookie 换 token，晚一步注入只能等下次重启生效。
      _injectUserVariables(userVariables);

      if (!_apiInjected) {
        final apiEvalResult = _engine.injectCeruMusicApi();
        if (apiEvalResult.isError) {
          throw Exception('引擎 API 注入失败: ${apiEvalResult.stringResult}');
        }
        _apiInjected = true;
      }

      // MusicFree 格式插件：适配器依赖 require()，需要在执行插件代码前把兼容
      // 运行时与它声明用到的第三方模块注入到同一个 JS 运行时。
      if (JsEngineService.isMusicFreeAdapterCode(pluginCode)) {
        final modules = JsEngineService.detectRequiredModules(
          originalPluginCode ?? pluginCode,
        );
        await _engine.ensurePluginModules(modules);
      }

      // 落雪格式插件：原脚本同样会 require('crypto-js') / require('axios') 之类
      // 的依赖（例如酷狗源用 crypto-js 签名、酷我源用 axios 发请求）。也把运行时
      // 与所需模块注入进来，否则脚本在初始化或请求时会因为拿不到模块而报错。
      final lxOriginalCode = originalPluginCode?.trim();
      if (lxOriginalCode != null && lxOriginalCode.isNotEmpty) {
        final modules = JsEngineService.detectRequiredModules(lxOriginalCode);
        await _engine.ensurePluginModules(modules);
      }

      print('[PluginHost] 开始加载插件...');
      _engine.evaluate('var module = { exports: {} };');
      _engine.evaluate('var exports = module.exports;');

      print('[PluginHost] 执行插件代码...');
      // Force an undefined completion value. This prevents flutter_js from
      // recursively converting a large module.exports object through FFI.
      final pluginEvalResult = _engine.evaluate('$pluginCode\n;void 0;');
      if (pluginEvalResult.isError) {
        // 例如大型插件超出 JS 栈上限时 QuickJS 返回
        // "InternalError: stack overflow"。此处直接暴露真实原因，
        // 而不是让后续 exports 解析失败产生误导性的提示。
        throw Exception('插件代码执行失败: ${pluginEvalResult.stringResult}');
      }

      if (originalPluginCode != null && originalPluginCode.trim().isNotEmpty) {
        print('[PluginHost] 单独执行原始 LX 脚本...');
        // The LX adapter has already installed its globals and event bridge.
        // Use a block scope so top-level `const` declarations in an LX script
        // (for example `const { EVENT_NAMES } = globalThis.lx`) cannot collide
        // with adapter globals. This is still a direct evaluate: the source is
        // not embedded in a string passed to new Function.
        final originalEvalResult = _engine.evaluate(
          '{\n$originalPluginCode\n}\n;void 0;',
        );
        if (originalEvalResult.isError) {
          // MusicFree 插件的原脚本也走这里，报错别一律写成「LX」误导排查。
          final kind = JsEngineService.isMusicFreeAdapterCode(pluginCode)
              ? '插件脚本'
              : '原始 LX 插件';
          throw Exception('$kind 执行失败: ${originalEvalResult.stringResult}');
        }
        // Keep the mobile LX contract intact without putting the large source
        // back into the adapter or a nested Function constructor. The result
        // is forced to a boolean so flutter_js never converts the source back
        // through the Dart bridge.
        final scriptInfoResult = _engine.evaluate(
          'if (typeof mockLx !== "undefined" && mockLx.currentScriptInfo) {'
          ' mockLx.currentScriptInfo.rawScript = ${jsonEncode(originalPluginCode)};'
          ' true; } else { false; }',
        );
        if (scriptInfoResult.isError) {
          throw Exception('LX 运行时信息初始化失败: ${scriptInfoResult.stringResult}');
        }
        final finalizeResult = _engine.evaluate(
          'typeof __lxFinalizePluginInitialization === "function"'
          ' ? (__lxFinalizePluginInitialization(), true) : true',
        );
        if (finalizeResult.isError) {
          throw Exception('LX 插件初始化失败: ${finalizeResult.stringResult}');
        }
      }

      // Older converted LX files kept a usable handler but left a late,
      // non-critical init error set. Normalize that runtime state so already
      // installed plugins receive the same compatibility behavior as newly
      // imported files.
      _engine.evaluate('''
(function() {
  if (typeof __lxRequestHandler === 'function') {
    if (typeof requestHandler !== 'function') requestHandler = __lxRequestHandler;
    if (typeof __lxInitError !== 'undefined') __lxInitError = null;
  }
  return true;
})()
''');

      print('[PluginHost] 等待插件异步初始化...');
      final initDeadline = DateTime.now().add(const Duration(seconds: 30));
      // 落雪适配器会先用静态推断的音源占位，真正的音源列表要等插件上报
      // inited 事件。这里最多只等 [lxSourceWait] 秒，避免插件的音源服务器
      // 不可达时，导入插件要干等满 30 秒。
      final lxSourceWait = DateTime.now().add(const Duration(seconds: 3));
      // 普通插件的音源是静态声明的，等不到就是没有，不必空等 30 秒。
      final staticSourceWait = DateTime.now().add(const Duration(seconds: 5));
      var sourceCount = 0;
      var isLxAdapter = false;
      while (DateTime.now().isBefore(initDeadline)) {
        _engine.executePendingJob();
        final countResult = _engine.evaluate(
          'module.exports && module.exports.sources ? Object.keys(module.exports.sources).length : 0',
        );
        if (!countResult.isError) {
          sourceCount = int.tryParse(countResult.stringResult) ?? 0;
        }
        // 落雪适配器暴露 __lxInited：插件上报过 inited 事件后就可以结束等待。
        final lxResult = _engine.evaluate(
          'typeof __lxInited === "undefined" ? 0 : 1',
        );
        if (!lxResult.isError) {
          isLxAdapter = lxResult.stringResult.trim() == '1';
          if (isLxAdapter) {
            final initedResult = _engine.evaluate('__lxInited ? 1 : 0');
            if (!initedResult.isError &&
                initedResult.stringResult.trim() == '1') {
              break;
            }
          }
        }
        final now = DateTime.now();
        if (isLxAdapter) {
          if (now.isAfter(lxSourceWait)) break;
        } else {
          if (sourceCount > 0) break;
          if (now.isAfter(staticSourceWait)) break;
        }
        await Future.delayed(const Duration(milliseconds: 100));
      }
      _isLxAdapter = isLxAdapter;
      print('[PluginHost] 插件初始化完成，解析到 $sourceCount 个源');

      // 洛雪脚本必须在运行时注册 request 事件，否则无法解析播放地址。
      // 混淆过的洛雪脚本无法靠静态关键字判断，只能在这里检查运行时状态。
      if (isLxAdapter) {
        final handlerResult = _engine.evaluate(
          'typeof __lxRequestHandler === "function" ? 1 : 0',
        );
        if (!handlerResult.isError &&
            handlerResult.stringResult.trim() == '0') {
          throw Exception('洛雪脚本没有注册 request 事件，无法解析播放地址');
        }
      }

      print('[PluginHost] 获取插件导出...');
      final exportsResult = _engine.evaluate('''
JSON.stringify((function() {
  var value = module.exports || {};
  return {
    pluginInfo: value.pluginInfo,
    sources: value.sources,
    sourceActions: value.sourceActions,
    capabilities: value.capabilities,
    isDataSource: value.isDataSource,
    dataSource: value.dataSource
  };
})())
''');
      if (exportsResult.isError) {
        throw Exception(
          'Plugin code execution failed: ${exportsResult.stringResult}',
        );
      }

      final exportsStr = exportsResult.stringResult;
      print('[PluginHost] 导出结果长度: ${exportsStr.length}');

      if (exportsStr == 'undefined' || exportsStr == 'null') {
        throw Exception('Plugin did not export anything');
      }

      try {
        final exports = jsonDecode(exportsStr) as Map<String, dynamic>;

        _pluginInfo = _parsePluginInfo(exports['pluginInfo']);
        _isDataSource = _detectDataSource(exports);
        final sourcesResult = _parseSourcesWithActions(exports['sources']);
        _sources = sourcesResult['sources'] as List<PluginSourceInfo>;
        _sourceActions = sourcesResult['actions'] as Map<String, List<String>>;
        _capabilities = _parseCapabilities(exports['capabilities']);
        _searchTypes = _detectSearchTypes();

        // 插件必须真的导出了内容：既没有插件信息也没有音源，说明这根本不是
        // 一个可用的插件脚本（混淆插件无法靠静态关键字判断，只能运行时查）。
        if (_pluginInfo == null && _sources.isEmpty && _sourceActions.isEmpty) {
          throw Exception('插件没有导出任何内容（module.exports 缺失或为空）');
        }

        if (_sources.isEmpty && _sourceActions.isNotEmpty) {
          for (final entry in _sourceActions.entries) {
            final sourceId = entry.key;
            _sources.add(
              PluginSourceInfo(
                id: sourceId,
                name: _getSourceDisplayName(sourceId),
                qualities: ['128k', '320k', 'flac'],
              ),
            );
          }
        }

        // 插件静态声明的登录态（运行时检测结果会通过 setLoginState 覆盖）。
        _seedLoginStatesFromSources();
        _pullRuntimeLoginStates();

        print('[PluginHost] 解析插件信息: ${_pluginInfo?.name ?? "null"}');
        print('[PluginHost] 解析源数量: ${_sources.length}');
        for (final entry in _sourceActions.entries) {
          print('[PluginHost] 源 ${entry.key} 支持的操作: ${entry.value}');
        }

        if (_pluginInfo == null) {
          _pluginInfo = PluginMetadata(
            name: '未知插件',
            version: '1.0',
            author: '未知',
          );
        }

        _loaded = true;
        print('[PluginHost] 插件加载成功');
      } catch (e) {
        if (e is Exception) rethrow;
        throw Exception('Failed to parse plugin exports: $e');
      }
    } catch (e) {
      _loaded = false;
      _isDataSource = false;
      final message = _friendlyPluginError(e);
      print('[PluginHost] 插件加载失败: $e');
      _pluginInfo = PluginMetadata(
        name: '加载失败',
        version: '0.0',
        author: '',
        description: message,
      );
      throw Exception(message);
    }
  }

  /// 插件是否声明自己是「数据源」。
  ///
  /// 兼容几种写法（按顺序判断）：
  /// * `pluginInfo.isDataSource === true`（推荐）
  /// * 顶层 `module.exports.isDataSource === true`
  /// * 顶层 `module.exports.dataSource === true`
  /// * `pluginInfo.type === 'dataSource'`
  static bool _detectDataSource(Map<String, dynamic> exports) {
    final info = exports['pluginInfo'];
    final infoMap = info is Map ? info : const {};
    bool truthy(dynamic value) =>
        value == true || '$value'.toLowerCase() == 'true';
    if (truthy(infoMap['isDataSource'])) return true;
    if (truthy(exports['isDataSource'])) return true;
    if (truthy(exports['dataSource'])) return true;
    final type = '${infoMap['type'] ?? ''}'.toLowerCase().replaceAll('_', '');
    return type == 'datasource';
  }

  /// 把底层 JS/Dart 异常转成用户可读的失败原因。
  ///
  /// 大型混淆插件（如“全音质”赞助版洛雪脚本）体积大、递归深，加载时可能
  /// 触发 JS 引擎或 Dart 桥接层的栈溢出。这类错误直接抛给 UI 只会显示
  /// 一句晦涩的 "Stack Overflow"，这里统一翻译成可执行的提示。
  static String _friendlyPluginError(Object error) {
    final text = error.toString();
    if (text.contains('stack overflow') || text.contains('Stack Overflow')) {
      return '插件脚本过大或递归过深，JS 引擎栈溢出，请更换精简版插件';
    }
    if (text.startsWith('Exception: ')) {
      return text.substring('Exception: '.length);
    }
    return text;
  }

  String _getSourceDisplayName(String sourceId) {
    final names = {
      'wy': '网易云音乐',
      'tx': 'QQ音乐',
      'kg': '酷狗音乐',
      'kw': '酷我音乐',
      'mg': '咪咕音乐',
      'qsvip': '汽水VIP',
    };
    return names[sourceId] ?? '${sourceId.toUpperCase()}音乐';
  }

  PluginMetadata? _parsePluginInfo(dynamic data) {
    if (data == null) return null;
    if (data is! Map) return null;

    final name = _safeString(data['name']);
    final version = _safeString(data['version']);
    final author = _safeString(data['author']);

    if (name == null || version == null || author == null) return null;

    return PluginMetadata(
      // 花体 Unicode 混排的插件名（𝖧౿ᥣᥣ𝗈 Ԝ𝗈𝗋ᥣᑯ 这类）应用字体没有
      // 对应字形，界面上全是豆腐块：导入时统一清洗成常规字符。
      name: sanitizeDisplayName(name),
      version: version,
      author: author,
      description: _safeString(data['description']),
      homepage: _safeString(data['homepage']),
      isDataSource: _detectDataSource({'pluginInfo': data}),
      // 站点图标（favicon / logo）：导入插件时下载并缓存，音源列表与切换按钮用它
      iconUrl:
          _safeString(data['iconUrl']) ??
          _safeString(data['icon']) ??
          _safeString(data['logo']),
    );
  }

  /// Safely convert a dynamic value to String, handling Lists and other
  /// non-String types that LX scripts may export.
  static String? _safeString(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    if (value is List) {
      // Some LX scripts export arrays — join non-null elements
      final parts = value
          .where((e) => e != null && e.toString().isNotEmpty)
          .map((e) => e.toString())
          .toList();
      return parts.isEmpty ? null : parts.join(', ');
    }
    return value.toString();
  }

  /// 解析 `module.exports.sources`，同时收集每个源支持的 action。
  ///
  /// 兼容 LX 的两种拼写（`qualitys` / `qualities`、`downloadQualitys` /
  /// `downloadQualities`）；新字段缺失时按 [PluginSourceInfo] 的缺省规则归一，
  /// **老插件（只有 name + qualitys）的行为完全不变**。
  Map<String, dynamic> _parseSourcesWithActions(dynamic data) {
    final sources = <PluginSourceInfo>[];
    final actions = <String, List<String>>{};

    if (data == null) return {'sources': sources, 'actions': actions};

    if (data is Map) {
      data.forEach((key, value) {
        if (value is Map) {
          final name =
              _safeString(value['name']) ??
              SourceInfo.getNameById(key as String);
          final qualitys =
              _safeStringList(value['qualitys']) ??
              _safeStringList(value['qualities']) ??
              [];
          final downloadQualitys =
              _safeStringList(
                value['downloadQualitys'] ?? value['downloadQualities'],
              );
          final login = SourceLoginSpec.fromJson(value['login']);
          final credentials = SourceCredentialSpec.listFromJson(
            value['credentials'],
          );
          final sourceActions =
              (_safeStringList(value['actions']) ?? const ['musicUrl'])
                  .map((e) => e.toLowerCase())
                  .toList();

          sources.add(
            PluginSourceInfo(
              id: key.toString(),
              name: name,
              qualities: qualitys,
              downloadQualities: downloadQualitys,
              login: login,
              credentials: credentials,
            ),
          );
          actions[key.toString()] = sourceActions;
        }
      });
    }

    return {'sources': sources, 'actions': actions};
  }

  /// 读取插件通过 `lx.send('loginStatus', ...)` 主动上报的登录态。
  ///
  /// 转换器会把上报写进 `__lxLoginStates`（见 `LxPluginConverter.mockLx`），
  /// 非 LX 插件或读取失败时静默跳过，不影响插件加载。
  void _pullRuntimeLoginStates() {
    try {
      final raw = _engine.evaluate('''
JSON.stringify((function() {
  var states = (typeof __lxLoginStates === 'object' && __lxLoginStates) || {};
  return states;
})() || {})
''');
      if (raw.isError) return;
      final text = raw.stringResult;
      if (text.isEmpty || text == 'undefined' || text == 'null') return;
      final decoded = jsonDecode(text);
      if (decoded is! Map) return;
      decoded.forEach((key, value) {
        final id = key.toString();
        if (value is Map) {
          final state = SourceLoginState.fromRaw(value['state'] ?? value['login']);
          if (state != SourceLoginState.unknown) _loginStates[id] = state;
          final account = value['account'] ?? value['nickname'];
          if (account != null && '$account'.trim().isNotEmpty) {
            _loginAccounts[id] = '$account'.trim();
          }
        } else {
          final state = SourceLoginState.fromRaw(value);
          if (state != SourceLoginState.unknown) _loginStates[id] = state;
        }
      });
    } catch (_) {
      // 插件没走 LX 适配器 / 引擎已释放：静默忽略。
    }
  }

  /// 注入 / 更新用户凭据（cookie、api key 等）。
  ///
  /// 插件通过 `lx.getUserVariables()` 读取。支持两种时机：
  /// * 加载前（[loadPlugin] 的 `userVariables` 参数）—— 插件初始化就能拿到；
  /// * 运行中（用户在插件管理页保存凭据后）—— 立即生效，不必重启 App。
  void _injectUserVariables(Map<String, String> values) {
    final json = jsonEncode(_sanitizeUserVariables(values));
    try {
      // adapter 里 `var __lxUserVariables = __lxUserVariablesRaw || {}`，
      // 必须在插件代码执行前写入才会被继承。
      _engine.evaluate('var __lxUserVariablesRaw = $json;');
      _engine.evaluate(
        'if (typeof __lxSetUserVariables === "function") { __lxSetUserVariables($json); }',
      );
    } catch (_) {
      // 引擎不可用时忽略：凭据只影响高音质，不能影响插件加载。
    }
  }

  /// 公开的凭据更新入口（运行中保存凭据时调用）。
  void setUserVariables(Map<String, String> values) =>
      _injectUserVariables(values);

  /// 清理凭据里的控制字符。
  ///
  /// cookie 从浏览器复制过来常带换行 / 零宽字符，直接拼进 JS 字符串字面量会
  /// 造成语法错误；中文等内容本身是允许的（JSON 会正确转义）。
  static Map<String, String> _sanitizeUserVariables(Map<String, String> values) {
    final result = <String, String>{};
    values.forEach((key, value) {
      final cleaned = value
          .replaceAll('\r', '')
          .replaceAll('\n', '')
          .replaceAll('\u0000', '')
          .trim();
      if (key.trim().isEmpty || cleaned.isEmpty) return;
      result[key.trim()] = cleaned;
    });
    return result;
  }

  /// 主动向插件查询登录态（只在 `actions` 含 `loginStatus` 时可用）。
  ///
  /// 返回 true 表示拿到了明确状态（`loggedIn` / `loggedOut` / `expired`），
  /// false 表示插件不支持、超时或返回了无法识别的值 —— 此时登录态保持
  /// [unknown]，**绝不影响播放**，也不弹错误。
  Future<bool> requestLoginStatus(
    String sourceId, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (!_loaded) return false;
    final actions = _sourceActions[sourceId] ?? const <String>[];
    if (!actions.contains('loginstatus')) return false;
    try {
      final result = await _engine.callPluginMethod(
        "module.exports.requestLoginStatus('${_escapeForJs(sourceId)}')",
        timeout: timeout,
      );
      if (result == null || result.isEmpty) return false;
      final decoded = _decodeMaybeJson(result);
      if (decoded == null) return false;
      if (decoded is Map) {
        final state = SourceLoginState.fromRaw(
          decoded['state'] ?? decoded['status'] ?? decoded['login'],
        );
        if (state == SourceLoginState.unknown) return false;
        final account = decoded['account'] ?? decoded['nickname'];
        setLoginState(
          sourceId,
          state,
          account: account == null ? null : '$account',
        );
        return true;
      }
      final state = SourceLoginState.fromRaw(decoded);
      if (state == SourceLoginState.unknown) return false;
      setLoginState(sourceId, state);
      return true;
    } catch (_) {
      // 超时 / 插件抛错：保持 unknown。
      return false;
    }
  }

  /// 尝试把 JS 返回的字符串解析成 JSON，失败时原样返回。
  static dynamic _decodeMaybeJson(String value) {
    final text = value.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('{') || text.startsWith('[') || text == 'true' ||
        text == 'false' || text.startsWith('"')) {
      try {
        return jsonDecode(text);
      } catch (_) {
        return text;
      }
    }
    return text;
  }

  /// Safely convert a dynamic value to List<String>.
  static List<String>? _safeStringList(dynamic value) {
    if (value == null) return null;
    if (value is List) {
      return value.map((e) => e.toString()).toList();
    }
    return null;
  }

  /// MusicFree 适配器暴露的能力开关（榜单 / 推荐歌单）。
  static Map<String, bool> _parseCapabilities(dynamic data) {
    if (data is! Map) return const {};
    final result = <String, bool>{};
    data.forEach((key, value) {
      if (value is bool) {
        result[key.toString()] = value;
      } else if (value != null) {
        result[key.toString()] = value.toString() == 'true';
      }
    });
    return result;
  }

  bool supportsSearch(String sourceId) {
    final actions = _sourceActions[sourceId];
    if (actions == null) return false;
    return actions
        .map((action) => action.toLowerCase())
        .any((action) => action == 'musicsearch' || action == 'search');
  }

  Future<String> getMusicUrl(
    String source,
    MusicInfoForPlugin musicInfo,
    String quality, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final result = await getMusicUrlResult(
      source,
      musicInfo,
      quality,
      timeout: timeout,
    );
    return result.url;
  }

  Future<PluginMusicUrlResult> getMusicUrlResult(
    String source,
    MusicInfoForPlugin musicInfo,
    String quality, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    _ensureLoaded();

    final infoJson = jsonEncode(musicInfo.toJson());
    final escapedInfo = _escapeForJs(infoJson);

    // 解析播放地址是最慢的一步：不少音源的取地址接口要十几秒（尤其是走
    // 第三方中转的 VIP 脚本），而插件里写死的 timeout 常常只有 8~10 秒，
    // 会把「慢但能成功」的请求直接判成 HTTP 408。这里在解析期间把插件
    // 请求的超时下限临时抬到 30 秒；搜索 / 歌单等其它调用不受影响。
    _engine.setRequestTimeoutFloor(_playbackRequestTimeoutFloor);
    final String? result;
    try {
      result = await _engine.callPluginMethod(
        "module.exports.musicUrl('$source', JSON.parse('$escapedInfo'), '$quality')",
        timeout: timeout,
      );
    } finally {
      _engine.setRequestTimeoutFloor(Duration.zero);
    }

    if (result == null || result.isEmpty) {
      throw Exception('Plugin returned empty result for musicUrl');
    }

    return _parseMusicUrlResult(result, quality);
  }

  /// 解析播放地址时插件 HTTP 请求的超时下限。
  static const Duration _playbackRequestTimeoutFloor = Duration(seconds: 30);

  PluginMusicUrlResult _parseMusicUrlResult(String result, String quality) {
    try {
      final decoded = _decodeLooseJson(result);
      final url = _extractMusicUrl(decoded);
      if (url != null && url.isNotEmpty) {
        return PluginMusicUrlResult(
          url: url,
          quality: _validateMusicQuality(decoded, quality) ?? quality,
          headers: _extractMusicHeaders(decoded),
        );
      }
    } catch (e) {
      if (e is Exception && e.toString().startsWith('Exception:')) {
        rethrow;
      }
    }

    final fallback = result.trim();
    if (_isHttpUrl(fallback)) {
      return PluginMusicUrlResult(url: fallback, quality: quality);
    }
    throw Exception('Plugin returned an invalid musicUrl result');
  }

  dynamic _decodeLooseJson(dynamic value) {
    var current = value;
    while (current is String) {
      final trimmed = current.trim();
      if (trimmed.isEmpty) return trimmed;
      final looksJson =
          (trimmed.startsWith('{') && trimmed.endsWith('}')) ||
          (trimmed.startsWith('[') && trimmed.endsWith(']')) ||
          (trimmed.startsWith('"') && trimmed.endsWith('"'));
      if (!looksJson) return trimmed;
      current = jsonDecode(trimmed);
    }
    return current;
  }

  String? _extractMusicUrl(dynamic value) {
    if (value == null) return null;
    if (value is String) {
      final trimmed = value.trim();
      if (_isHttpUrl(trimmed)) return trimmed;
      final decoded = _decodeLooseJson(trimmed);
      if (decoded is! String) return _extractMusicUrl(decoded);
      return null;
    }
    if (value is Map) {
      for (final key in const [
        'url',
        'src',
        'playUrl',
        'play_url',
        'location',
        'audioUrl',
        'audio_url',
      ]) {
        final url = _extractMusicUrl(value[key]);
        if (url != null && url.isNotEmpty) return url;
      }

      for (final key in const ['data', 'body', 'result', 'response']) {
        final url = _extractMusicUrl(value[key]);
        if (url != null && url.isNotEmpty) return url;
      }
      final error = value['error'] ?? value['message'];
      if (error != null) throw Exception(error.toString());
    }
    if (value is List) {
      for (final item in value) {
        final url = _extractMusicUrl(item);
        if (url != null && url.isNotEmpty) return url;
      }
    }
    return null;
  }

  String? _validateMusicQuality(dynamic value, String requested) {
    final requestedKey = musicQualityKey(requested);
    String? reported;

    void read(dynamic current) {
      current = _decodeLooseJson(current);
      if (current is Map) {
        // Container formats cannot identify quality tiers (hires can use flac).
        for (final key in const ['quality', 'level', 'type']) {
          final candidate = current[key];
          if (candidate is! String && candidate is! num) continue;
          final label = candidate.toString().trim();
          if (label.isEmpty || (key == 'type' && !isMusicQualityType(label))) {
            continue;
          }
          if (musicQualityKey(label) != requestedKey) {
            throw Exception('音质不匹配：请求 $requested，插件返回 $label，已拒绝替换音质');
          }
          reported ??= label;
        }
        // Check every response branch, including labels after the first URL.
        for (final key in const [
          'url',
          'src',
          'playUrl',
          'play_url',
          'location',
          'audioUrl',
          'audio_url',
          'data',
          'body',
          'result',
          'response',
        ]) {
          read(current[key]);
        }
      } else if (current is List) {
        for (final item in current) {
          read(item);
        }
      }
    }

    read(value);
    return reported;
  }

  Map<String, String> _extractMusicHeaders(dynamic value) {
    final headers = <String, String>{};

    void read(dynamic current) {
      if (current is String) {
        final decoded = _decodeLooseJson(current.trim());
        if (decoded is! String) read(decoded);
        return;
      }
      if (current is Map) {
        for (final key in const ['requestHeaders', 'httpHeaders', 'headers']) {
          final candidate = current[key];
          if (candidate is Map) {
            candidate.forEach((header, headerValue) {
              if (headerValue == null) return;
              final name = header.toString().trim();
              final value = headerValue.toString().trim();
              if (name.isNotEmpty && value.isNotEmpty) {
                headers[name] = value;
              }
            });
          }
        }
        for (final key in const ['data', 'body', 'result', 'response']) {
          read(current[key]);
        }
      } else if (current is List) {
        for (final item in current) {
          read(item);
        }
      }
    }

    read(value);
    return headers;
  }

  bool _isHttpUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  String? _parseLyricResult(String? result) {
    final bundle = _parseLyricBundle(result);
    if (bundle == null) return null;
    return _firstNonEmpty([bundle.crlyric, bundle.lrc]);
  }

  LyricResult? _parseLyricBundle(String? result) {
    if (result == null || result.isEmpty) return null;
    if (result == 'null' || result == 'undefined') return null;

    dynamic decoded = result;
    if (result.startsWith('"') && result.endsWith('"')) {
      try {
        decoded = jsonDecode(result);
      } catch (_) {
        return LyricResult(lrc: result);
      }
    }

    if (decoded is String) {
      final trimmed = decoded.trim();
      if (trimmed.isEmpty || trimmed == 'null' || trimmed == 'undefined') {
        return null;
      }
      try {
        decoded = jsonDecode(trimmed);
      } catch (_) {
        return _looksLikeWordLyric(trimmed)
            ? LyricResult(crlyric: trimmed)
            : LyricResult(lrc: trimmed);
      }
    }

    if (decoded is Map) {
      final wordLyric = _readFirstText(decoded, const [
        'crlyric',
        'lxlyric',
        'yrc',
        'krc',
        'qrc',
        'mrc',
        'lrcx',
        'lyricx',
        'wordLyric',
        'wordlyric',
        'word',
        'words',
        'ttml',
        'ttmlLyric',
      ]);
      final plainLyric = _readFirstText(decoded, const [
        'lrc',
        'lyric',
        'text',
        'content',
        'raw',
      ]);
      final tlyric = _readFirstText(decoded, const [
        'tlyric',
        'tlrc',
        'translation',
        'translatedLyric',
        'trans',
      ]);
      final rlyric = _readFirstText(decoded, const [
        'rlyric',
        'rlrc',
        'roma',
        'romanLyric',
        'roman',
      ]);

      if ([
        wordLyric,
        plainLyric,
        tlyric,
        rlyric,
      ].any((value) => value != null && value.trim().isNotEmpty)) {
        return LyricResult(
          lrc: plainLyric,
          crlyric: wordLyric,
          tlyric: tlyric,
          rlyric: rlyric,
        );
      }

      final nested = _parseLyricBundle(_stringifyJsonValue(decoded['data']));
      if (nested != null) return nested;
    }

    return null;
  }

  String? _firstNonEmpty(List<String?> values) {
    for (final value in values) {
      if (value != null && value.trim().isNotEmpty) return value;
    }
    return null;
  }

  String? _readFirstText(Map source, List<String> keys) {
    String? readValue(dynamic value) {
      if (value == null) return null;
      if (value is String) {
        final trimmed = value.trim();
        return trimmed.isEmpty || trimmed == 'null' || trimmed == 'undefined'
            ? null
            : trimmed;
      }
      if (value is Map) {
        for (final key in keys) {
          final nested = readValue(value[key]);
          if (nested != null) return nested;
        }
        for (final fallbackKey in const [
          'data',
          'lyric',
          'lrc',
          'content',
          'text',
          'raw',
        ]) {
          final nested = readValue(value[fallbackKey]);
          if (nested != null) return nested;
        }
      }
      if (value is List) {
        final parts = value
            .map(readValue)
            .whereType<String>()
            .where((text) => text.isNotEmpty)
            .toList();
        if (parts.isNotEmpty) return parts.join('\n');
      }
      return null;
    }

    for (final key in keys) {
      final value = readValue(source[key]);
      if (value != null) return value;
    }
    final data = source['data'];
    if (data is Map) {
      for (final key in keys) {
        final value = readValue(data[key]);
        if (value != null) return value;
      }
    }
    return null;
  }

  String? _stringifyJsonValue(dynamic value) {
    if (value == null) return null;
    if (value is String) return value;
    try {
      return jsonEncode(value);
    } catch (_) {
      return null;
    }
  }

  bool _looksLikeWordLyric(String text) {
    final trimmed = text.trimLeft();
    return RegExp(r'^\[\d+,\d+\]', multiLine: true).hasMatch(text) ||
        RegExp(
          r'^\[\d{1,2}:\d{2}\.\d{2,3}\].*<\d{1,2}:\d{2}\.\d{2,3}>',
          multiLine: true,
        ).hasMatch(text) ||
        trimmed.startsWith('<tt') ||
        text.contains('LyricContent=');
  }

  /// 探测插件支持的搜索类型。
  ///
  /// MusicFree 适配器导出 `supportedSearchTypes()`（同步返回数组），
  /// LX / CeruMusic 插件没有这个方法，只支持歌曲搜索。
  List<String> _detectSearchTypes() {
    try {
      final result = _engine.evaluate(
        '(function(){try{'
        'var f=module.exports.supportedSearchTypes;'
        'if(typeof f!=="function")return "[]";'
        'var v=f();'
        'return JSON.stringify(Array.isArray(v)?v:[]);'
        '}catch(e){return "[]"}})()',
      );
      if (result.isError) return const ['music'];
      final decoded = jsonDecode(result.stringResult ?? '[]');
      if (decoded is! List) return const ['music'];
      final types = <String>['music'];
      for (final item in decoded) {
        final value = '$item'.toLowerCase();
        if (value == 'album' || value == 'artist') {
          if (!types.contains(value)) types.add(value);
        }
      }
      return types;
    } catch (_) {
      return const ['music'];
    }
  }

  /// 按类型搜索（album / artist）。仅 MusicFree 适配器支持。
  Future<String?> searchTyped(
    String source,
    String keyword, {
    required String type,
    int page = 1,
    int limit = 30,
  }) async {
    _ensureLoaded();
    final hasMethod = _engine.evaluate(
      'typeof module.exports.searchTyped === "function"',
    );
    if (hasMethod.stringResult != 'true') return null;
    // 同 [search]：异常抛出，让上层区分「没有更多」和「加载失败」。
    return await _engine.callPluginMethod(
      "module.exports.searchTyped('$source', '${_escapeForJs(keyword)}', "
      "$page, $limit, '$type')",
      timeout: const Duration(seconds: 45),
    );
  }

  /// 专辑详情（含歌曲列表）。
  ///
  /// 失败时**抛出**异常（不再吞掉返回 null）：上层需要区分「插件报错」和
  /// 「这个专辑确实没有歌曲」，前者要在界面上给「重试」。
  /// 插件没有实现该方法时返回 null。
  Future<String?> getAlbumInfo(
    String source,
    Map<String, dynamic> albumItem, {
    int page = 1,
  }) async {
    _ensureLoaded();
    final hasMethod = _engine.evaluate(
      'typeof module.exports.getAlbumInfo === "function"',
    );
    if (hasMethod.stringResult != 'true') return null;
    return _engine.callPluginMethod(
      "module.exports.getAlbumInfo('$source', ${jsonEncode(albumItem)}, $page)",
      timeout: const Duration(seconds: 45),
    );
  }

  /// 作者作品（type = music / album）。
  ///
  /// 与 [getAlbumInfo] 一样：异常直接抛出，交给上层决定是否显示重试。
  Future<String?> getArtistWorks(
    String source,
    Map<String, dynamic> artistItem, {
    int page = 1,
    String type = 'music',
  }) async {
    _ensureLoaded();
    final hasMethod = _engine.evaluate(
      'typeof module.exports.getArtistWorks === "function"',
    );
    if (hasMethod.stringResult != 'true') return null;
    return _engine.callPluginMethod(
      "module.exports.getArtistWorks('$source', "
      "${jsonEncode(artistItem)}, $page, '$type')",
      timeout: const Duration(seconds: 45),
    );
  }

  Future<String?> search(
    String source,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    _ensureLoaded();

    final hasMethod = _engine.evaluate(
      'typeof module.exports.search === "function"',
    );
    if (hasMethod.stringResult != 'true') {
      print('[PluginHost] search方法不存在');
      return null;
    }

    final escapedKeyword = _escapeForJs(keyword);

    // 异常直接抛出：上层需要区分「这个音源没有更多结果」和「这次请求失败了」，
    // 后者要在界面上给「重试」。
    print(
      '[PluginHost] 调用search: source=$source, keyword=$keyword, page=$page, limit=$limit',
    );
    final result = await _engine.callPluginMethod(
      "module.exports.search('$source', '$escapedKeyword', $page, $limit)",
      timeout: const Duration(seconds: 45),
    );
    print('[PluginHost] search结果长度: ${result?.length ?? 0}');
    return result;
  }

  Future<String?> searchWithHandler(
    String source,
    String keyword, {
    int page = 1,
    int limit = 30,
  }) async {
    _ensureLoaded();

    final hasRequestHandler = _engine.evaluate(
      'typeof requestHandler === "function" || typeof __lxRequestHandler === "function"',
    );
    if (hasRequestHandler.stringResult == 'true') {
      try {
        final escSource = _escapeForJs(source);
        final escKeyword = _escapeForJs(keyword);
        final result = await _engine.callPluginMethod(
          "(function(){" +
              "var handler=typeof requestHandler==='function'?requestHandler:__lxRequestHandler;" +
              "if(typeof handler!=='function')return JSON.stringify({list:[],total:0});" +
              "try{" +
              "var res=handler({" +
              "source:'$escSource',action:'musicSearch'," +
              "info:{keyword:'$escKeyword',page:$page,limit:$limit,pagesize:$limit}" +
              "});" +
              "if(res&&typeof res.then==='function'){" +
              "return res.then(function(r){return JSON.stringify(r||{list:[],total:0});});" +
              "}" +
              "return JSON.stringify(res||{list:[],total:0});" +
              "}catch(e){return JSON.stringify({list:[],total:0,error:e.message});}" +
              "})()",
          timeout: const Duration(seconds: 45),
        );
        return result;
      } catch (e) {
        print('[PluginHost] searchWithHandler异常: $e');
      }
    }
    return null;
  }

  /// 通用：调用适配器上一个「返回 JSON 字符串」的方法。
  ///
  /// [args] 是已经转义好的 JS 参数列表。方法不存在时返回 null。
  Future<String?> _callBrowseMethod(
    String method,
    String args, {
    Duration timeout = const Duration(seconds: 45),
  }) async {
    _ensureLoaded();
    if (!hasMethod(method)) return null;
    try {
      return await _engine.callPluginMethod(
        'module.exports.$method($args)',
        timeout: timeout,
      );
    } catch (e) {
      print('[PluginHost] $method 调用失败: $e');
      return null;
    }
  }

  /// 榜单列表；返回 `[{id,name,group,coverUrl,description}]`。
  Future<String?> getTopLists() => _callBrowseMethod('getTopLists', '');

  /// 榜单详情；返回 `{isEnd, songs}`。
  Future<String?> getTopListDetail(String id, {int page = 1}) {
    final escaped = _escapeForJs(id);
    return _callBrowseMethod('getTopListDetail', "'$escaped', $page");
  }

  /// 推荐歌单分类；返回 `[{name,tags:[{id,name}]}]`。
  Future<String?> getRecommendSheetTags() =>
      _callBrowseMethod('getRecommendSheetTags', '');

  /// 热门歌单标签（可选）；返回 `[{id,name}]`。
  ///
  /// 插件没实现时返回 null，调用方退回用推荐分类的前几个标签。
  Future<String?> getHotPlaylistTags() =>
      _callBrowseMethod('getHotPlaylistTags', '');

  /// 搜索页的「热门搜索」词（可选）；返回 `["a","b"]` 或 `[{name}]`。
  ///
  /// 插件没实现时返回 null，搜索页就不显示热门搜索这一块。
  Future<String?> getHotSearchTags() =>
      _callBrowseMethod('getHotSearchTags', '');

  /// 按分类取歌单；返回 `{isEnd, playlists}`。
  Future<String?> getRecommendSheetsByTag(String tagId, {int page = 1}) {
    final escaped = _escapeForJs(tagId);
    return _callBrowseMethod('getRecommendSheetsByTag', "'$escaped', $page");
  }

  /// 歌单详情；返回 `{isEnd, songs}`。
  Future<String?> getMusicSheetInfo(String sheetId, {int page = 1}) {
    final escaped = _escapeForJs(sheetId);
    return _callBrowseMethod('getMusicSheetInfo', "'$escaped', $page");
  }

  /// 搜索歌单（MusicFree 插件的 sheet 搜索）；返回 `{isEnd, playlists}`。
  Future<String?> searchPlaylists(String query, {int page = 1}) {
    final escaped = _escapeForJs(query);
    return _callBrowseMethod('searchPlaylists', "'$escaped', $page");
  }

  Future<String?> getPic(String source, MusicInfoForPlugin musicInfo) async {
    _ensureLoaded();

    final hasMethod = _engine.evaluate(
      'typeof module.exports.getPic === "function"',
    );
    if (hasMethod.stringResult != 'true') return null;

    final infoJson = jsonEncode(musicInfo.toJson());
    final escapedInfo = _escapeForJs(infoJson);

    try {
      final result = await _engine.callPluginMethod(
        "module.exports.getPic('$source', JSON.parse('$escapedInfo'))",
      );
      return result;
    } catch (_) {
      return null;
    }
  }

  Future<String?> getLyric(String source, MusicInfoForPlugin musicInfo) async {
    _ensureLoaded();

    final infoJson = jsonEncode(musicInfo.toJson());
    final escapedInfo = _escapeForJs(infoJson);
    final escapedSource = _escapeForJs(source);

    final hasMethod = _engine.evaluate(
      'typeof module.exports.getLyric === "function"',
    );
    if (hasMethod.stringResult == 'true') {
      try {
        final result = await _engine.callPluginMethod(
          "module.exports.getLyric('$escapedSource', JSON.parse('$escapedInfo'))",
          timeout: const Duration(seconds: 45),
        );
        final lyric = _parseLyricResult(result);
        if (lyric != null && lyric.isNotEmpty) return lyric;
      } catch (e) {
        print('[PluginHost] getLyric 方法失败: $e');
      }
    }

    return _getLyricWithHandler(escapedSource, escapedInfo);
  }

  Future<String?> _getLyricWithHandler(
    String escapedSource,
    String escapedInfo,
  ) async {
    final hasRequestHandler = _engine.evaluate(
      'typeof requestHandler === "function" || typeof __lxRequestHandler === "function"',
    );
    if (hasRequestHandler.stringResult != 'true') return null;

    for (final action in const ['lyric', 'getLyric']) {
      try {
        final result = await _engine.callPluginMethod(
          "(function(){" +
              "var handler=typeof requestHandler==='function'?requestHandler:__lxRequestHandler;" +
              "if(typeof handler!=='function')return null;" +
              "var musicInfo=JSON.parse('$escapedInfo');" +
              "var info=Object.assign({musicInfo:musicInfo,type:'lrc'},musicInfo);" +
              "var res=handler({" +
              "source:'$escapedSource',action:'$action'," +
              "info:info" +
              "});" +
              "if(res&&typeof res.then==='function'){" +
              "return res.then(function(r){return r;});" +
              "}" +
              "return res;" +
              "})()",
          timeout: const Duration(seconds: 45),
        );
        final lyric = _parseLyricResult(result);
        if (lyric != null && lyric.isNotEmpty) return lyric;
      } catch (e) {
        print('[PluginHost] requestHandler 歌词动作 $action 失败: $e');
      }
    }

    return null;
  }

  Future<LyricResult?> getLyricResult(
    String source,
    MusicInfoForPlugin musicInfo,
  ) async {
    _ensureLoaded();

    final infoJson = jsonEncode(musicInfo.toJson());
    final escapedInfo = _escapeForJs(infoJson);
    final escapedSource = _escapeForJs(source);

    final hasMethod = _engine.evaluate(
      'typeof module.exports.getLyric === "function"',
    );
    if (hasMethod.stringResult == 'true') {
      try {
        final result = await _engine.callPluginMethod(
          "module.exports.getLyric('$escapedSource', JSON.parse('$escapedInfo'))",
          timeout: const Duration(seconds: 45),
        );
        final lyric = _parseLyricBundle(result);
        if (_hasAnyLyric(lyric)) return lyric;
      } catch (e) {
        print('[PluginHost] getLyricResult failed: $e');
      }
    }

    return _getLyricResultWithHandler(escapedSource, escapedInfo);
  }

  Future<LyricResult?> _getLyricResultWithHandler(
    String escapedSource,
    String escapedInfo,
  ) async {
    final hasRequestHandler = _engine.evaluate(
      'typeof requestHandler === "function"',
    );
    if (hasRequestHandler.stringResult != 'true') return null;

    for (final action in const ['lyric', 'getLyric']) {
      try {
        final result = await _engine.callPluginMethod(
          "(function(){" +
              "if(typeof requestHandler!=='function')return null;" +
              "var musicInfo=JSON.parse('$escapedInfo');" +
              "var info=Object.assign({musicInfo:musicInfo,type:'lrc'},musicInfo);" +
              "var res=requestHandler({" +
              "source:'$escapedSource',action:'$action'," +
              "info:info" +
              "});" +
              "if(res&&typeof res.then==='function'){" +
              "return res.then(function(r){return r;});" +
              "}" +
              "return res;" +
              "})()",
          timeout: const Duration(seconds: 45),
        );
        final lyric = _parseLyricBundle(result);
        if (_hasAnyLyric(lyric)) return lyric;
      } catch (e) {
        print('[PluginHost] requestHandler lyric action $action failed: $e');
      }
    }

    return null;
  }

  bool _hasAnyLyric(LyricResult? lyric) {
    return lyric != null &&
        ((lyric.lrc?.trim().isNotEmpty ?? false) ||
            (lyric.crlyric?.trim().isNotEmpty ?? false) ||
            (lyric.tlyric?.trim().isNotEmpty ?? false) ||
            (lyric.rlyric?.trim().isNotEmpty ?? false));
  }

  bool hasMethod(String name) {
    if (!_loaded) return false;
    final result = _engine.evaluate(
      'typeof module.exports.$name === "function"',
    );
    return result.stringResult == 'true';
  }

  void _ensureLoaded() {
    if (!_loaded) {
      throw StateError('Plugin not loaded');
    }
    if (!_engine.isRuntimeHealthy) {
      _loaded = false;
      throw StateError('插件 JS 运行时已隔离，请重新加载插件');
    }
  }

  String _escapeForJs(String input) {
    return input
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', '\\n')
        .replaceAll('\r', '\\r')
        .replaceAll('\t', '\\t')
        .replaceAll('\$', '\\\$');
  }
}
