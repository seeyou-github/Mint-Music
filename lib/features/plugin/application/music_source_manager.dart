import 'dart:convert';
import '../../../shared/pagination/page_result.dart';
import '../../player/domain/models/song.dart';
import '../../player/domain/models/lyric_line.dart';
import '../../discover/domain/models/playlist.dart';
import '../../discover/domain/models/playlist_page.dart';
import '../../discover/domain/models/leaderboard.dart';
import '../domain/plugin_types.dart';
import '../domain/song_year.dart';
import '../../discover/domain/models/search_collection.dart';
import '../domain/source_id_mapping.dart';
import '../domain/plugin_source_states.dart';
import '../data/plugin_source_preferences.dart';
import '../data/plugin_service.dart';
import '../data/plugin_host.dart';

class _CacheEntry<T> {
  final T data;
  final DateTime timestamp;
  final Duration ttl;

  _CacheEntry(this.data, this.ttl) : timestamp = DateTime.now();

  bool get isValid => DateTime.now().difference(timestamp) < ttl;
}

class MusicSourceManager {
  final PluginService _pluginService;

  final Map<String, _CacheEntry<List<Playlist>>> _hotPlaylistsCache = {};
  final Map<String, _CacheEntry<Playlist?>> _playlistDetailCache = {};
  final Map<String, _CacheEntry<List<String>>> _searchSuggestionsCache = {};
  final Map<String, _CacheEntry<PageResult<Song>>> _searchPageCache = {};
  final Map<String, _CacheEntry<String?>> _coverCache = {};
  final Map<String, _CacheEntry<Map<String, List<Song>>>> _searchResultsCache =
      {};

  int _suggestRequestId = 0;
  int _searchRequestId = 0;

  static const _hotPlaylistsTTL = Duration(minutes: 5);
  static const _playlistDetailTTL = Duration(minutes: 5);
  static const _searchSuggestionsTTL = Duration(hours: 1);
  static const _searchResultsTTL = Duration(minutes: 5);
  static const _maxConcurrentSources = 5;
  static const _perSourceTimeout = Duration(seconds: 4);

  void clearSearchCache() {
    _searchPageCache.clear();
    _playlistSearchCache = null;
    _coverCache.clear();
    _searchResultsCache.clear();
  }

  void clearAllCaches() {
    _hotPlaylistsCache.clear();
    _playlistDetailCache.clear();
    _searchSuggestionsCache.clear();
    _searchPageCache.clear();
    _playlistSearchCache = null;
    _coverCache.clear();
    _searchResultsCache.clear();
  }

  static const Map<String, String> _sourceIdToName = SourceIdMapping.idToName;

  bool _isValidAudioUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    return uri != null &&
        (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  /// 判断 URL 是否为酷我不可播放地址（提示音或加密格式）。
  ///
  /// 玉宁熙等 LX 插件走 `nmobi.kuwo.cn` 车机端，正常情况下返回真实音频；
  /// 仅当响应中包含 `kw_promo` 等标记、或返回 `.mflac` / `.mgg` 加密封装
  /// 时才需要丢弃。不再因 host 是 `nmobi.kuwo.cn` 就全盘拒绝，避免误杀
  /// 可用的车机地址。
  bool _isKuwoPromptUrl(String url) {
    final lower = url.toLowerCase();
    if (lower.contains('kw_promo')) return true;
    if (lower.contains('kuwo_promo')) return true;
    if (lower.contains('/promo/')) return true;
    if (lower.contains('permission_prompt')) return true;
    if (lower.contains('trial')) return true;
    final pathWithoutQuery = lower.split('?').first;
    if (pathWithoutQuery.endsWith('.mflac')) return true;
    if (pathWithoutQuery.endsWith('.mgg')) return true;
    return false;
  }

  MusicSourceManager(this._pluginService);

  /* ------------------------------------------------------------------ *
   * 插件自带音源的启用/关闭状态
   *
   * 一个插件文件可能同时提供多个音源，用户可以在插件管理页逐个开关。
   * ------------------------------------------------------------------ */

  final PluginSourcePreferences _pluginSourcePreferences =
      PluginSourcePreferences();
  PluginSourceStates _pluginSourceStates = const PluginSourceStates();
  bool _pluginSourceStatesLoaded = false;

  PluginSourceStates get pluginSourceStates => _pluginSourceStates;

  bool get pluginSourceStatesLoaded => _pluginSourceStatesLoaded;

  /// 插件的某个音源是否启用（未记录过时默认启用）。
  bool isPluginSourceEnabled(String? pluginId, String sourceId) {
    if (pluginId == null || pluginId.isEmpty) return true;
    return _pluginSourceStates.isEnabled(pluginId, sourceId);
  }

  Future<void> loadPluginSourceStates() async {
    if (_pluginSourceStatesLoaded) return;
    _pluginSourceStates = await _pluginSourcePreferences.load();
    _pluginSourceStatesLoaded = true;
  }

  /// 开启/关闭插件自带的某个音源。
  Future<void> setPluginSourceEnabled(
    String pluginId,
    String sourceId,
    bool enabled,
  ) async {
    await loadPluginSourceStates();
    final disabled = <String>{..._pluginSourceStates.disabled};
    final key = PluginSourceStates.key(pluginId, sourceId);
    if (enabled) {
      disabled.remove(key);
    } else {
      disabled.add(key);
    }
    await _applyPluginSourceStates(
      _pluginSourceStates.copyWith(disabled: disabled),
    );
  }

  /// 清空某个插件的全部音源开关（恢复默认：全部启用）。
  Future<void> resetPluginSources(String pluginId) async {
    await loadPluginSourceStates();
    final disabled = <String>{..._pluginSourceStates.disabled}
      ..removeWhere((key) => key.startsWith('$pluginId:'));
    await _applyPluginSourceStates(
      _pluginSourceStates.copyWith(disabled: disabled),
    );
  }

  Future<void> _applyPluginSourceStates(PluginSourceStates next) async {
    _pluginSourceStates = next;
    _pluginSourceStatesLoaded = true;
    // 音源集合变了，之前缓存的搜索结果/歌单可能包含已关闭的音源，直接丢弃。
    clearAllCaches();
    await _pluginSourcePreferences.save(next);
  }

  void dispose() {}

  /// 插件提供的音源列表（发现页 / 搜索页共用同一份 id 与名称）。
  ///
  /// * 名称取插件声明的 platform（音源平台名，例如「网易云音乐」），不再追加
  ///   插件名——插件名通常就包含平台名，追加会重复；
  /// * 同名同平台（不同作者）的插件都能显示，每个插件的音源用
  ///   `平台id@插件id` 作为唯一 id。
  List<SourceInfo> getPluginSupportedSources() {
    final sources = <SourceInfo>[];
    final seenIds = <String>{};
    final plugins = _pluginService.enabledPlugins;
    final orderedPlugins = [
      ...plugins.where((host) => host.isDataSource),
      ...plugins.where((host) => !host.isDataSource),
    ];

    for (final host in orderedPlugins) {
      final pluginId = _pluginService.getPluginIdForHost(host);
      // 只有插件自带多个音源时才把插件名加上：
      // 单音源插件（MusicFree 常见）的 platform 本身就是插件名，再加一次
      // 会变成「platform - platform」，又长又重复。
      final pluginName = host.sources.length > 1
          ? _pluginDisplayName(host)
          : '';
      for (final source in host.sources) {
        // 名称 → id 的推导与 MusicFree 适配器保持一致（见 SourceIdMapping）。
        // 注意要用插件原始的 platform 名推导，附加的插件名不能参与推导。
        final baseId = SourceIdMapping.deriveId(source.name);
        // 用户在插件管理页关掉的音源不再出现在音源列表里。
        if (!isPluginSourceEnabled(pluginId, baseId)) continue;
        final id = _uniqueSourceId(baseId, pluginId, seenIds);
        seenIds.add(id);
        final displayName = _sourceDisplayName(source.name, pluginName);
        sources.add(
          SourceInfo(
            id: id,
            // 数据源只提供元数据，名字上标出来，避免和同名插件音源混淆。
            name: host.isDataSource ? '$displayName（数据源）' : displayName,
          ),
        );
      }
    }
    return sources;
  }

  /// 平台是否已有已启用（且未在插件管理页关闭）的插件音源。
  ///
  /// 用于区分两种播放失败：真的没装插件（提示去安装）和装了插件但接口
  /// 解析失败（如 bilibili 风控 412，应显示接口返回的具体错误）。
  bool hasPluginForPlatform(String baseId) {
    if (baseId.isEmpty) return false;
    for (final source in getPluginSupportedSources()) {
      if (source.id == baseId || source.id.startsWith('$baseId@')) {
        return true;
      }
    }
    return false;
  }

  /// 插件名（多音源插件用来区分各平台的来源）。
  String _pluginDisplayName(PluginHost host) {
    final name = host.pluginInfo?.name?.trim() ?? '';
    if (name.isEmpty) return '';
    return name.length <= 12 ? name : '${name.substring(0, 12)}…';
  }

  /// 音源展示名。
  ///
  /// * 单音源插件：直接用平台名（平台名本身就是插件名，再加会重复）；
  /// * 多音源插件：平台名 + 插件名（如「酷我音乐-星海音乐源」）。
  String _sourceDisplayName(String sourceName, String pluginName) {
    if (pluginName.isEmpty) return sourceName;
    return '$sourceName-$pluginName';
  }

  /// 插件音源在应用层的 id（`平台id@插件id`）。
  ///
  /// 插件内部只认自己的音源 id（`wy` / `kw` …），应用层要用带插件 id 的
  /// 变体 id 才能区分是哪个插件提供的。
  String _pluginSourceAppId(PluginHost host, String pluginSourceId) {
    final pluginId = _pluginService.getPluginIdForHost(host);
    if (pluginId == null || pluginId.isEmpty) return pluginSourceId;
    if (pluginSourceId.contains('@')) return pluginSourceId;
    return '$pluginSourceId@$pluginId';
  }

  /// 插件音源的唯一 id。
  ///
  /// 插件音源始终使用「平台id@插件id」，避免同名同平台的插件（作者、版本
  /// 完全相同）在音源切换列表里互相覆盖。
  static String _uniqueSourceId(
    String baseId,
    String? pluginId,
    Set<String> seenIds,
  ) {
    if (pluginId != null && pluginId.isNotEmpty) {
      var id = '$baseId@$pluginId';
      var counter = 2;
      while (seenIds.contains(id)) {
        id = '$baseId@$pluginId$counter';
        counter++;
      }
      return id;
    }
    if (!seenIds.contains(baseId)) return baseId;
    var id = '$baseId@${seenIds.length}';
    var counter = 2;
    while (seenIds.contains(id)) {
      id = '$baseId@${pluginId ?? 'plugin'}$counter';
      counter++;
    }
    return id;
  }

  /// 某个音源实际由哪个插件提供服务。
  ///
  /// 歌曲的音源字段可能只记平台 id（例如从搜索结果直接播放时），这里给出
  /// 真正提供地址的插件音源 id（`平台id@插件id`）。
  String? resolvingSourceIdFor(String sourceId, {String? preferredPlugin}) {
    if (sourceId.isEmpty) return null;
    // 已经是插件音源就直接用它。
    final (_, pluginId) = splitSourceId(sourceId);
    if (pluginId != null) return sourceId;
    // 平台 id：找提供该平台的插件。按「优先音源」排序后取第一个，
    // 这样解析播放地址时用的就是真正会被优先使用的那个音源。
    for (final host in _orderedHostsForSource(
      sourceId,
      preferredPlugin: preferredPlugin,
    )) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId == null) continue;
      return _pluginSourceAppId(host, pluginSourceId);
    }
    return null;
  }

  /// 音源的展示名。
  ///
  /// * 平台 id（歌曲只记了平台时）：平台名；
  /// * 单音源插件：插件声明的平台名；
  /// * 多音源插件：平台名 + 插件名（如「酷我音乐-星海音乐源」）。
  String sourceDisplayName(String sourceId) {
    final (baseId, pluginId) = splitSourceId(sourceId);
    if (pluginId == null) {
      return _sourceIdToName[baseId] ?? sourceId;
    }
    for (final host in _pluginService.enabledPlugins) {
      if (_pluginService.getPluginIdForHost(host) != pluginId) continue;
      final pluginName = host.sources.length > 1
          ? _pluginDisplayName(host)
          : '';
      for (final source in host.sources) {
        if (SourceIdMapping.deriveId(source.name) == baseId) {
          final displayName = _sourceDisplayName(source.name, pluginName);
          return host.isDataSource ? '$displayName（数据源）' : displayName;
        }
      }
    }
    final platformName = _sourceIdToName[baseId];
    return platformName ?? baseId;
  }

  /// 已启用的插件音源 id 列表（`平台id@插件id`）。
  List<String> get pluginSourceIds =>
      getPluginSupportedSources().map((source) => source.id).toList();

  List<SourceInfo> getSearchSupportedSources() {
    final sources = <SourceInfo>[];
    final seenIds = <String>{};

    // 音源全部来自插件，各自成条（同名同平台也各显示一条）。
    for (final source in getPluginSupportedSources()) {
      if (seenIds.contains(source.id)) continue;
      // 插件要么能解析播放地址，要么能搜索，否则既搜不到也放不了。
      if (!_pluginSourceCanResolveUrls(source.id) &&
          !_pluginSourceSupportsSearch(source.id)) {
        continue;
      }
      seenIds.add(source.id);
      sources.add(source);
    }

    return sources;
  }

  /// 这个音源是不是落雪（LX）格式插件提供的。
  ///
  /// 落雪脚本只解析播放地址（`musicUrl` / `lyric` / `pic`），没有歌单与榜单，
  /// 多数连搜索都没有；列在音源切换列表里，用户选中后只能得到空结果。
  /// 界面上的切换按钮据此把它们过滤掉（播放地址仍然照常由这个插件解析）。
  ///
  /// 这里按 [getPluginSupportedSources] 的同一套顺序 / 去重规则反推 id 归属，
  /// 避免「同一个平台既有 MF 插件又有落雪插件时把两个都当成落雪」。
  bool isLxFormatSource(String sourceId) {
    if (sourceId.trim().isEmpty) return false;
    final plugins = _pluginService.enabledPlugins;
    final orderedPlugins = [
      ...plugins.where((host) => host.isDataSource),
      ...plugins.where((host) => !host.isDataSource),
    ];
    final seenIds = <String>{};
    for (final host in orderedPlugins) {
      final pluginId = _pluginService.getPluginIdForHost(host);
      for (final source in host.sources) {
        final baseId = SourceIdMapping.deriveId(source.name);
        if (!isPluginSourceEnabled(pluginId, baseId)) continue;
        final id = _uniqueSourceId(baseId, pluginId, seenIds);
        seenIds.add(id);
        if (id != sourceId) continue;
        // 数据源插件（只提供元数据、播放交给别的音源）不参与过滤：
        // 它的价值就是搜索 / 浏览，藏起来反而没法用。
        if (host.isDataSource) return false;
        // 安装时记下的格式 + 运行时识别（混淆脚本靠后者兜底）。
        if (host.isLxAdapter) return true;
        return pluginId != null && _pluginService.isLxPlugin(pluginId);
      }
    }
    return false;
  }

  /// 插件音源是否支持搜索。
  ///
  /// 变体 id（`wy@插件id`）只认对应插件提供的音源。
  bool _pluginSourceSupportsSearch(String sourceId) {
    final (baseId, pluginId) = splitSourceId(sourceId);
    for (final host in _pluginService.enabledPlugins) {
      if (pluginId != null &&
          _pluginService.getPluginIdForHost(host) != pluginId) {
        continue;
      }
      final pluginSourceId = _getSourceIdForHost(host, baseId);
      if (pluginSourceId == null) continue;
      final actions = host.sourceActions[pluginSourceId] ?? const <String>[];
      if (actions
          .map((action) => action.toLowerCase())
          .any((action) => action == 'musicsearch' || action == 'search')) {
        return true;
      }
    }
    return false;
  }

  /// 插件音源是否能够解析播放链接（action 里带 musicUrl）。
  ///
  /// 落雪脚本通常只提供链接解析（没有搜索接口），这类插件接管平台后，
  /// 搜索只能由插件自己的搜索能力决定，播放地址由插件解析。
  bool _pluginSourceCanResolveUrls(String sourceId) {
    final (baseId, pluginId) = splitSourceId(sourceId);
    for (final host in _pluginService.enabledPlugins) {
      if (pluginId != null &&
          _pluginService.getPluginIdForHost(host) != pluginId) {
        continue;
      }
      final pluginSourceId = _getSourceIdForHost(host, baseId);
      if (pluginSourceId == null) continue;
      final actions = host.sourceActions[pluginSourceId] ?? const <String>[];
      if (actions
          .map((action) => action.toLowerCase())
          .any((action) => action == 'musicurl')) {
        return true;
      }
    }
    return false;
  }

  List<String> getSupportedQualitiesForSourceId(String sourceId) {
    final (baseId, _) = splitSourceId(sourceId);
    // 插件优先：返回 JS 插件定义的 qualities 列表
    final host = _findPluginForSource(sourceId);
    if (host != null) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId != null) {
        for (final source in host.sources) {
          final effectiveId = SourceIdMapping.deriveId(source.name);
          if (effectiveId == pluginSourceId && source.qualities.isNotEmpty) {
            return source.qualities;
          }
        }
        // 插件有该源的 action 但没有 source info，尝试通过 host.actionKeys 查找
        for (final entry in host.sourceActions.entries) {
          if (entry.key == pluginSourceId) {
            final actions = entry.value;
            if (actions
                .map((action) => action.toLowerCase())
                .any((action) => action == 'musicurl')) {
              return _defaultQualities[baseId] ?? ['128k', '320k', 'flac'];
            }
          }
        }
      }
    }
    // 插件没声明音质时按平台默认档位。
    return _defaultQualities[baseId] ?? ['128k', '320k', 'flac'];
  }

  static const Map<String, List<String>> _defaultQualities = {
    'wy': ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos'],
    'tx': ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'],
    'kg': ['128k', '320k', 'flac', 'flac24bit', 'hires'],
    'kw': ['128k', '320k', 'flac', 'flac24bit', 'hires'],
    'mg': ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'],
  };

  /// 插件测试：返回指定插件宿主声明的音源与各源音质列表。
  ///
  /// 音源名规范化为平台 id（如"酷我音乐"→kw），未声明的源沿用插件
  /// 原名作为 id；插件未声明音质时回退到该平台的默认音质。
  List<PluginSourceSpec> getHostSourceSpecs(PluginHost host) {
    final specs = <PluginSourceSpec>[];
    final seenIds = <String>{};
    for (final source in host.sources) {
      final id = SourceIdMapping.deriveId(source.name);
      if (id.isEmpty || seenIds.contains(id)) continue;
      seenIds.add(id);
      final qualities = source.qualities.isNotEmpty
          ? source.qualities
          : (_defaultQualities[id] ?? const ['128k', '320k', 'flac']);
      specs.add(
        PluginSourceSpec(id: id, name: source.name, qualities: qualities),
      );
    }
    return specs;
  }

  /// 插件测试：优先通过指定插件宿主搜索。
  ///
  /// 与插件启用后的实际播放路径保持一致：插件自己的搜索结果携带完整
  /// LX 元数据（songmid/hash/songId 等），供后续 musicUrl 解析使用；
  /// 宿主不支持搜索或无结果时回退常规插件搜索。
  Future<List<Song>> searchViaHost(
    PluginHost host,
    String query, {
    required String sourceId,
    int limit = 15,
  }) async {
    if (query.isEmpty) return [];

    final effectiveSourceId = _canonicalSourceId(sourceId);
    final pluginSourceId = _getSourceIdForHost(host, effectiveSourceId);
    // Some LX sources expose a usable search method but omit `musicSearch`
    // from their source action metadata. Keep the method-level check as a
    // compatibility fallback; sources that truly do not support search simply
    // return an empty result and continue to the normal fallback path.
    final canTryPluginSearch =
        pluginSourceId != null &&
        (host.supportsSearch(pluginSourceId) || host.hasMethod('search'));
    if (canTryPluginSearch) {
      try {
        final resultJson = await host.search(
          pluginSourceId,
          query,
          limit: limit,
        );
        if (resultJson != null && resultJson.isNotEmpty) {
          final results = _parsePluginSearchResult(
            resultJson,
            effectiveSourceId,
          );
          if (results.isNotEmpty) return results;
        }
      } catch (e) {
        print('[MusicSourceManager] searchViaHost search失败: $e');
      }

      try {
        final resultJson = await host.searchWithHandler(
          pluginSourceId,
          query,
          limit: limit,
        );
        if (resultJson != null && resultJson.isNotEmpty) {
          final results = _parsePluginSearchResult(
            resultJson,
            effectiveSourceId,
          );
          if (results.isNotEmpty) return results;
        }
      } catch (e) {
        print('[MusicSourceManager] searchViaHost searchWithHandler失败: $e');
      }
    }

    // 插件宿主没给出结果时，让同一个音源的其它宿主再试一次。
    return search(query, sourceId: effectiveSourceId, limit: limit);
  }

  PluginHost? _findPluginForSource(String sourceId) {
    final hosts = _findPluginHostsForSource(sourceId);
    return hosts.isEmpty ? null : hosts.first;
  }

  String _canonicalSourceId(String sourceId) {
    final normalized = sourceId.trim().toLowerCase();

    for (final entry in SourceIdMapping.aliases.entries) {
      if (entry.key.toLowerCase() == normalized || entry.value == normalized) {
        return entry.value;
      }
    }

    for (final host in _pluginService.enabledPlugins) {
      for (final pluginSourceId in host.sourceActions.keys) {
        final pluginId = pluginSourceId.trim().toLowerCase();
        if (pluginId == normalized) return pluginSourceId;
        if (SourceIdMapping.knownId(pluginSourceId) == normalized) {
          return normalized;
        }
      }
    }

    return sourceId;
  }

  /// 平台 id → 优先插件音源。
  ///
  /// 由播放控制器在设置变化时同步进来：解析裸平台 id 时优先使用用户指定
  /// 的插件音源，失败后再按原顺序尝试其它音源。
  Map<String, String> _preferredSources = const {};

  void setPreferredSources(Map<String, String> map) {
    _preferredSources = Map<String, String>.from(map);
  }

  /// 「隐藏B站会员专属歌曲」开关（默认开启）。
  ///
  /// 由设置页在启动加载 / 用户切换时同步进来：开启时插件音源返回的
  /// 会员专属歌曲（`isVipExclusive`，如 bilibili 充电专属）在解析搜索 /
  /// 详情 / 榜单结果时直接过滤掉。已收藏的歌单由收藏详情页按同一开关
  /// 过滤展示（歌曲仍保留在歌单数据里）。
  bool hideVipExclusiveSongs = true;

  /// 用户已安装、且能解析播放地址的插件音源（绑定切换 / 播放详情页的
  /// 手动音源列表都用它）。
  List<SourceInfo> playbackPluginSources() {
    return [
      for (final source in getPluginSupportedSources())
        if (_pluginSourceCanResolveUrls(source.id)) source,
    ];
  }

  // ---------------------------------------------------------------------
  // 数据源（只提供元数据、不解析播放地址的插件）
  // ---------------------------------------------------------------------

  /// 已启用且声明自己是「数据源」的插件 id。
  Set<String> get dataSourcePluginIds {
    final ids = <String>{};
    for (final host in _pluginService.enabledPlugins) {
      if (!host.isDataSource) continue;
      final pluginId = _pluginService.getPluginIdForHost(host);
      if (pluginId != null && pluginId.isNotEmpty) ids.add(pluginId);
    }
    return ids;
  }

  /// 插件是否是数据源。
  bool isDataSourcePlugin(String pluginId) {
    if (pluginId.isEmpty) return false;
    for (final host in _pluginService.enabledPlugins) {
      if (_pluginService.getPluginIdForHost(host) != pluginId) continue;
      return host.isDataSource;
    }
    return false;
  }

  /// 音源 id（`平台id@插件id`）是否由数据源插件提供。
  bool isDataSourceSource(String sourceId) {
    final (baseId, pluginId) = splitSourceId(sourceId.trim());
    if (baseId.isEmpty || pluginId == null) return false;
    return isDataSourcePlugin(pluginId);
  }

  /// 歌曲实际归属的数据源插件 id（不是数据源的歌返回 null）。
  ///
  /// 优先看歌曲级绑定（收藏 / 歌单记下的 `preferredSource`），再看音源本身。
  String? dataSourcePluginIdForSong(Song song) {
    final preferred = song.preferredSource?.trim() ?? '';
    if (preferred.isNotEmpty) {
      final (preferredBase, preferredPlugin) = splitSourceId(preferred);
      if (preferredPlugin != null && isDataSourcePlugin(preferredPlugin)) {
        return preferredPlugin;
      }
      // 插件卸载 / 重装会换 id：老歌曲记的还是旧数据源 id。找一个同平台、
      // 已经在用（配了播放源）的数据源插件顶上，否则这批老歌会直接放不了。
      if (preferredPlugin != null && !_isPluginIdLive(preferredPlugin)) {
        final replacement = _liveDataSourcePluginFor(preferredBase);
        if (replacement != null) return replacement;
      }
    }
    final source = song.source?.trim() ?? '';
    final (sourceBase, pluginId) = splitSourceId(source);
    if (pluginId != null && isDataSourcePlugin(pluginId)) return pluginId;
    if (pluginId != null &&
        sourceBase.isNotEmpty &&
        !_isPluginIdLive(pluginId)) {
      return _liveDataSourcePluginFor(sourceBase);
    }
    return null;
  }

  /// 同一平台上仍在用（并且配了播放源）的数据源插件。
  ///
  /// 只用于「歌曲里记着的数据源插件已经不在了」这种兜底场景。
  String? _liveDataSourcePluginFor(String baseId) {
    if (baseId.isEmpty) return null;
    for (final host in _pluginService.enabledPlugins) {
      if (!host.isDataSource) continue;
      final pluginId = _pluginService.getPluginIdForHost(host);
      if (pluginId == null || pluginId.isEmpty) continue;
      // 得支持这个平台，而且用户给它指定了播放源，换过去才有意义。
      if (_getSourceIdForHost(host, baseId) == null) continue;
      if (dataSourcePlaybackSource(pluginId) == null) continue;
      return pluginId;
    }
    return null;
  }

  /// 数据源的展示名（用于「此 xxx数据源…」提示）。
  ///
  /// 插件名本身可能已经带「数据源」后缀，避免出现「xx数据源数据源」。
  String dataSourceDisplayName(String pluginId) {
    for (final host in _pluginService.enabledPlugins) {
      if (_pluginService.getPluginIdForHost(host) != pluginId) continue;
      final name = (host.pluginInfo?.name ?? '').trim();
      if (name.isEmpty) break;
      final stripped = name.endsWith('数据源')
          ? name.substring(0, name.length - 3).trim()
          : name;
      return stripped.isEmpty ? name : '$stripped数据源';
    }
    return '数据源';
  }

  /// 数据源 → 指定播放源（`平台id@插件id`）。
  ///
  /// 由设置页 / 插件管理页维护：数据源只提供元数据，播放地址由这里指定的
  /// 播放源解析。
  Map<String, String> _dataSourcePlaybackSources = const {};

  void setDataSourcePlaybackSources(Map<String, String> map) {
    _dataSourcePlaybackSources = Map<String, String>.from(map);
  }

  /// 某个数据源当前指定的播放源 id（未指定返回 null）。
  String? dataSourcePlaybackSource(String pluginId) {
    final value = _dataSourcePlaybackSources[pluginId]?.trim() ?? '';
    return value.isEmpty ? null : value;
  }

  /// 把一个音源 id 落成「能真正解析播放地址」的具体插件音源。
  ///
  /// 收藏歌曲 / 歌单 / 专辑 / 作者时用它记下「以后优先用哪个插件播放」：
  /// 搜索结果（尤其是聚合搜索）里的歌往往只带平台 id（`wy`），直接存进收藏
  /// 的话，以后播放只能临时靠「优先音源」或回退去猜，容易失败。
  ///
  /// * 数据源（只提供元数据）→ 原样返回，收藏继续绑定数据源插件；
  /// * 已经带插件（`平台id@插件id`）且插件仍可用 → 原样返回；
  /// * 否则先看该平台的「优先音源」，再取第一个能解析地址的插件；
  /// * 一个插件都没有 → 原样返回（播放时提示安装对应音源）。
  String concretePlaybackSource(
    String sourceId, {
    Map<String, String>? preferredSources,
  }) {
    final trimmed = sourceId.trim();
    if (trimmed.isEmpty || trimmed == 'local') return sourceId;
    final (baseId, pluginId) = splitSourceId(trimmed);
    if (baseId.isEmpty) return sourceId;
    // 数据源只提供元数据：不能改写成别的插件，否则收藏就丢了「数据源绑定」。
    if (pluginId != null && isDataSourcePlugin(pluginId)) return trimmed;
    // 已经指定了插件：插件还支持解析地址就保持不变。
    if (pluginId != null && _pluginSourceCanResolveUrls(trimmed)) {
      return trimmed;
    }

    final preferred =
        (preferredSources ?? _preferredSources)[baseId]?.trim() ?? '';
    if (preferred.isNotEmpty && _pluginSourceCanResolveUrls(preferred)) {
      return preferred;
    }

    for (final host in _findPluginHostsForSource(baseId)) {
      final pluginSourceId = _getSourceIdForHost(host, baseId);
      if (pluginSourceId == null) continue;
      final appId = _pluginSourceAppId(host, pluginSourceId);
      if (!_pluginSourceCanResolveUrls(appId)) continue;
      return appId;
    }
    // 没有可用插件：保留原 id，播放时会提示安装对应音源。
    return sourceId;
  }

  /// 这个插件 id 是否还对得上一个已启用的插件。
  ///
  /// 插件 id 是安装时间戳：卸载 / 重装（哪怕文件只改了名字）就会换一个新的，
  /// 老的 id 从此不存在。
  bool _isPluginIdLive(String pluginId) {
    if (pluginId.isEmpty) return false;
    for (final host in _pluginService.enabledPlugins) {
      if (_pluginService.getPluginIdForHost(host) == pluginId) return true;
    }
    return false;
  }

  /// 清理音源 id 里已经失效的插件后缀。
  ///
  /// 歌曲（尤其是收藏 / 播放队列里存下来的老歌）会记住 `平台id@插件id`，
  /// 插件卸载重装换了 id 之后，直接按这个 id 找插件会一个都找不到，
  /// 表现为「该音源不可用（插件未启用或已卸载）」。这里退回平台 id，
  /// 让解析走「任意可用插件」。
  String _liveSourceId(String sourceId) {
    final trimmed = sourceId.trim();
    if (trimmed.isEmpty) return trimmed;
    final (baseId, pluginId) = splitSourceId(trimmed);
    if (pluginId == null || baseId.isEmpty) return trimmed;
    return _isPluginIdLive(pluginId) ? trimmed : baseId;
  }

  /// 取 `平台id@插件id` 里的插件部分（没有返回空串）。
  String _pluginIdOf(String sourceId) {
    final (_, pluginId) = splitSourceId(sourceId);
    return pluginId ?? '';
  }

  /// 指定的播放源失效时的兜底：当前可用的同平台音源。
  ///
  /// 优先用设置里的「优先音源」，其次任意能解析播放地址的同平台插件。
  String? _fallbackPlaybackSource(Song song, {String? exclude}) {
    final (baseId, _) = splitSourceId(song.source ?? '');
    if (baseId.isEmpty) return null;

    final preferred = _preferredSources[baseId]?.trim() ?? '';
    if (preferred.isNotEmpty &&
        preferred != exclude &&
        _pluginSourceCanResolveUrls(preferred)) {
      return preferred;
    }
    for (final host in _findPluginHostsForSource(baseId)) {
      final pluginSourceId = _getSourceIdForHost(host, baseId);
      if (pluginSourceId == null) continue;
      final appId = _pluginSourceAppId(host, pluginSourceId);
      if (appId == exclude) continue;
      if (!_pluginSourceCanResolveUrls(appId)) continue;
      return appId;
    }
    return null;
  }

  /// 解析播放地址时使用的 host 顺序：优先插件排在最前面。
  ///
  /// 优先级（从高到低）：
  /// 1. [preferredPlugin] ——「这首歌自己记住的插件」（收藏时记下的绑定）；
  /// 2. 设置里每个平台的「优先音源」。
  ///
  /// 只影响「取播放地址」，不影响搜索结果的顺序。
  List<PluginHost> _orderedHostsForSource(
    String sourceId, {
    String? preferredPlugin,
  }) {
    final hosts = _findPluginHostsForSource(sourceId);
    if (hosts.length <= 1) return hosts;
    final (baseId, pluginId) = splitSourceId(sourceId);
    // 已经指定了具体插件（`平台id@插件id`）时不需要再排序。
    if (pluginId != null) return hosts;

    String? preferred;
    for (final candidate in [
      preferredPlugin?.trim() ?? '',
      _preferredSources[baseId] ?? '',
    ]) {
      if (candidate.isNotEmpty) {
        preferred = candidate;
        break;
      }
    }
    if (preferred == null) return hosts;
    final (preferredBase, preferredPluginId) = splitSourceId(preferred);

    bool matches(PluginHost host) {
      final hostPluginId = _pluginService.getPluginIdForHost(host);
      if (preferredPluginId != null) return hostPluginId == preferredPluginId;
      return _getSourceIdForHost(host, preferredBase) != null;
    }

    final preferredHosts = hosts.where(matches).toList(growable: false);
    if (preferredHosts.isEmpty) return hosts;
    return <PluginHost>[
      ...preferredHosts,
      ...hosts.where((host) => !matches(host)),
    ];
  }

  List<PluginHost> _findPluginHostsForSource(String sourceId) {
    final (baseId, pluginId) = splitSourceId(sourceId);
    final hosts = <PluginHost>[];
    for (final host in _pluginService.enabledPlugins) {
      // 指定了插件（同名同平台的变体）时只使用该插件提供的音源。
      final hostPluginId = _pluginService.getPluginIdForHost(host);
      if (pluginId != null && hostPluginId != pluginId) {
        continue;
      }
      final pluginSourceId = _getSourceIdForHost(host, baseId);
      if (pluginSourceId == null) continue;
      // 用户在插件管理页关掉的音源不再参与解析。
      final sourceKey = _pluginSourceKey(host, pluginSourceId);
      if (!isPluginSourceEnabled(hostPluginId, sourceKey)) {
        continue;
      }
      hosts.add(host);
    }
    return hosts;
  }

  /// 插件音源开关使用的键。
  ///
  /// 统一按音源的展示名推导（与 [getPluginSupportedSources] 一致），
  /// 这样插件管理页的开关与运行时解析用的是同一个键。
  String _pluginSourceKey(PluginHost host, String pluginSourceId) {
    for (final source in host.sources) {
      if (source.id == pluginSourceId) {
        return SourceIdMapping.deriveId(source.name);
      }
    }
    return SourceIdMapping.deriveId(pluginSourceId);
  }

  String? _getSourceIdForHost(PluginHost host, String sourceId) {
    // 变体 id（'wy@插件id'）按平台部分匹配。
    final (baseId, _) = splitSourceId(sourceId);
    print('[MusicSourceManager] _getSourceIdForHost: 查找 sourceId=$baseId');
    print(
      '[MusicSourceManager] sourceActions keys: ${host.sourceActions.keys.toList()}',
    );

    if (host.sourceActions.containsKey(baseId)) {
      print('[MusicSourceManager] 直接匹配: $baseId');
      return baseId;
    }

    for (final entry in host.sourceActions.entries) {
      final pluginSourceId = entry.key;
      final knownId = SourceIdMapping.knownId(pluginSourceId);
      if (knownId == baseId) {
        print('[MusicSourceManager] 通过名称映射匹配: $pluginSourceId -> $baseId');
        return pluginSourceId;
      }

      final normalizedName = pluginSourceId.toLowerCase().replaceAll(
        RegExp(r'[^a-z0-9]'),
        '',
      );
      if (normalizedName == baseId) {
        print(
          '[MusicSourceManager] 通过规范化匹配: $pluginSourceId -> $normalizedName',
        );
        return pluginSourceId;
      }
    }

    for (final source in host.sources) {
      final knownId = SourceIdMapping.knownId(source.name);
      if (knownId == baseId) {
        print('[MusicSourceManager] 通过sources匹配: ${source.name} -> $baseId');
        return baseId;
      }
    }

    print('[MusicSourceManager] 未找到匹配');
    return null;
  }

  /// 拆分音源 id：'平台id' / '平台id@插件id'。
  ///
  /// 同名同平台（不同作者）的插件会得到带插件 id 的变体 id，
  /// 这样它们可以同时出现在音源列表里并被分别选中。
  static (String baseId, String? pluginId) splitSourceId(String sourceId) {
    final index = sourceId.indexOf('@');
    if (index <= 0 || index >= sourceId.length - 1) {
      return (sourceId, null);
    }
    return (sourceId.substring(0, index), sourceId.substring(index + 1));
  }

  String _resolvePluginSourceId(String sourceId) {
    return sourceId;
  }

  Future<List<Song>> search(
    String query, {
    String sourceId = 'wy',
    int page = 1,
    int limit = 30,
  }) async {
    return (await searchPage(
      query,
      sourceId: sourceId,
      page: page,
      limit: limit,
    )).items;
  }

  Future<PageResult<Song>> searchPage(
    String query, {
    String sourceId = 'wy',
    int page = 1,
    int limit = 30,
  }) async {
    if (query.isEmpty) return const PageResult(total: 0, isEnd: true);

    // 记录最后一次失败原因：全部音源都失败时抛给上层，
    // 让「加载下一页」能区分「确实没有更多」和「这次请求失败了」。
    Object? lastError;

    final effectiveSourceId = _canonicalSourceId(sourceId);
    final cacheKey = '$effectiveSourceId:$query:$page:$limit';
    final cached = _searchPageCache[cacheKey];
    if (cached != null && cached.isValid) return cached.data;

    final hosts = _findPluginHostsForSource(effectiveSourceId);
    for (final host in hosts) {
      final pluginSourceId = _getSourceIdForHost(host, effectiveSourceId);
      if (pluginSourceId != null) {
        final resolvedSourceId = _resolvePluginSourceId(pluginSourceId);

        if (host.supportsSearch(resolvedSourceId)) {
          try {
            print(
              '[MusicSourceManager] 尝试插件搜索: source=$sourceId, query=$query',
            );
            final resultJson = await host.search(
              resolvedSourceId,
              query,
              page: page,
              limit: limit,
            );
            if (resultJson != null && resultJson.isNotEmpty) {
              final results = _parsePluginSearchPage(
                resultJson,
                effectiveSourceId,
              );
              if (results != null) {
                _searchPageCache[cacheKey] = _CacheEntry(
                  results,
                  _searchResultsTTL,
                );
                return results;
              }
            }
          } catch (e) {
            print(
              '[MusicSourceManager] Plugin search failed for $sourceId: $e',
            );
            lastError = e;
          }

          try {
            final resultJson = await host.searchWithHandler(
              resolvedSourceId,
              query,
              page: page,
              limit: limit,
            );
            if (resultJson != null && resultJson.isNotEmpty) {
              final results = _parsePluginSearchPage(
                resultJson,
                effectiveSourceId,
              );
              if (results != null) {
                _searchPageCache[cacheKey] = _CacheEntry(
                  results,
                  _searchResultsTTL,
                );
                return results;
              }
            }
          } catch (e) {
            print(
              '[MusicSourceManager] Plugin searchWithHandler failed for $sourceId: $e',
            );
            lastError = e;
          }
        }
      }
    }

    if (lastError != null) {
      // 有音源尝试过但都失败了：抛出真实原因，界面据此显示「加载失败 + 重试」。
      throw lastError;
    }
    print('[MusicSourceManager] 没有找到可用的搜索源: $sourceId');
    return const PageResult();
  }

  PageResult<Song>? _parsePluginSearchPage(String raw, String sourceId) {
    final decoded = _decodePluginPage(raw);
    final total = _pluginTotalOf(decoded);
    final isEnd = decoded is Map && decoded['isEnd'] is bool
        ? decoded['isEnd'] as bool
        : null;
    final items = _parsePluginSearchResult(raw, sourceId);
    if (items.isEmpty && total != 0 && isEnd != true) return null;
    return PageResult(items: items, total: total, isEnd: isEnd);
  }

  static int? _nonNegativeInt(dynamic value) {
    if (value is num &&
        value.isFinite &&
        value >= 0 &&
        value == value.truncateToDouble()) {
      return value.toInt();
    }
    return null;
  }

  static int? _pluginTotalOf(dynamic decoded) =>
      decoded is Map ? _nonNegativeInt(decoded['total']) : null;

  static dynamic _decodePluginPage(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      throw const FormatException('音源返回了空数据，请稍后重试');
    }
    var decoded = jsonDecode(raw);
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map && decoded is! List) {
      throw const FormatException('音源返回结构不是列表或对象');
    }
    if (decoded is Map) {
      final error = decoded['error'];
      if (error != null && error != false && '$error'.trim().isNotEmpty) {
        throw Exception('$error');
      }
    }
    return decoded;
  }

  Future<Map<String, List<Song>>> aggregateSearch(
    String query, {
    List<String>? sourceIds,
    int page = 1,
    int limit = 20,
  }) async {
    if (query.isEmpty) return {};

    final ids =
        sourceIds ?? getSearchSupportedSources().map((s) => s.id).toList();
    final cacheKey = 'all:${ids.join(",")}:$query:$page:$limit';
    final cached = _searchResultsCache[cacheKey];
    if (cached != null && cached.isValid) {
      print('[MusicSourceManager] 搜索结果缓存命中: $cacheKey');
      return cached.data;
    }

    final requestId = ++_searchRequestId;

    final results = <String, List<Song>>{};
    final remainingIds = List<String>.from(ids);
    final sourceOrder = ['wy', 'kg', 'tx', 'kw', 'mg'];
    remainingIds.sort((a, b) {
      final ai = sourceOrder.indexOf(a);
      final bi = sourceOrder.indexOf(b);
      if (ai == -1 && bi == -1) return 0;
      if (ai == -1) return 1;
      if (bi == -1) return -1;
      return ai.compareTo(bi);
    });

    while (remainingIds.isNotEmpty) {
      if (requestId != _searchRequestId) {
        print('[MusicSourceManager] 搜索查询已变更，取消聚合搜索');
        return results;
      }

      final batch = remainingIds.take(_maxConcurrentSources).toList();
      remainingIds.removeRange(0, batch.length);

      final futures = batch.map((id) async {
        try {
          final songs = await search(
            query,
            sourceId: id,
            page: page,
            limit: limit,
          ).timeout(_perSourceTimeout);
          if (requestId == _searchRequestId) {
            results[id] = songs;
          }
        } catch (e) {
          print('[MusicSourceManager] 聚合搜索超时或失败: $id, $e');
          if (requestId == _searchRequestId) {
            results[id] = [];
          }
        }
      });

      await Future.wait(futures);
    }

    _searchResultsCache[cacheKey] = _CacheEntry(results, _searchResultsTTL);
    return results;
  }

  Future<List<String>> getSearchSuggestions(
    String query, {
    String sourceId = 'wy',
  }) async {
    if (query.isEmpty) return [];

    final cacheKey = '$sourceId:$query';
    final cached = _searchSuggestionsCache[cacheKey];
    if (cached != null && cached.isValid) {
      print('[MusicSourceManager] 搜索建议缓存命中: $cacheKey');
      return cached.data;
    }

    final requestId = ++_suggestRequestId;

    final result = await _getSearchSuggestionsInternal(
      query,
      sourceId: sourceId,
      requestId: requestId,
    );
    _searchSuggestionsCache[cacheKey] = _CacheEntry(
      result,
      _searchSuggestionsTTL,
    );
    return result;
  }

  Future<List<String>> _getSearchSuggestionsInternal(
    String query, {
    String sourceId = 'wy',
    int requestId = 0,
  }) async {
    if (sourceId == 'all') {
      final suggestions = <String>[];
      final seen = <String>{};

      void addSuggestion(String item) {
        final normalized = item.trim();
        if (normalized.isEmpty || seen.contains(normalized)) return;
        seen.add(normalized);
        suggestions.add(normalized);
      }

      final sources = getSearchSupportedSources()
          .where((s) => s.id != 'all')
          .toList();
      final futures = sources.map((source) async {
        if (requestId != _suggestRequestId) return;
        try {
          final sourceSuggestions = await _getSearchSuggestionsForSource(
            query,
            sourceId: source.id,
          );
          if (requestId != _suggestRequestId) return;
          for (final item in sourceSuggestions) {
            addSuggestion(item);
            if (suggestions.length >= 10) return;
          }
        } catch (_) {}
      });

      await Future.wait(futures);

      if (suggestions.isEmpty && requestId == _suggestRequestId) {
        try {
          final aggregated = await aggregateSearch(query, limit: 5);
          for (final songs in aggregated.values) {
            for (final song in songs) {
              addSuggestion('${song.title} - ${song.artist}');
              if (suggestions.length >= 10) break;
            }
            if (suggestions.length >= 10) break;
          }
        } catch (_) {}
      }

      return suggestions;
    }

    return _getSearchSuggestionsForSource(query, sourceId: sourceId);
  }

  Future<List<String>> _getSearchSuggestionsForSource(
    String query, {
    String sourceId = 'wy',
  }) async {
    final effectiveSourceId = _canonicalSourceId(sourceId);
    final hosts = _findPluginHostsForSource(effectiveSourceId);
    for (final host in hosts) {
      final pluginSourceId =
          _getSourceIdForHost(host, effectiveSourceId) ?? effectiveSourceId;
      try {
        final hasMethod = host.hasMethod('search');
        if (hasMethod) {
          final result = await host.search(
            pluginSourceId,
            query,
            page: 1,
            limit: 8,
          );
          if (result != null) {
            final songs = _parsePluginSearchResult(result, effectiveSourceId);
            final suggestions = songs
                .map((s) => '${s.title} - ${s.artist}')
                .where((s) => s.trim().isNotEmpty)
                .toList();
            if (suggestions.isNotEmpty) return suggestions;
          }
        }
      } catch (_) {}

      try {
        final result = await host.searchWithHandler(
          pluginSourceId,
          query,
          page: 1,
          limit: 8,
        );
        if (result != null && result.isNotEmpty) {
          final songs = _parsePluginSearchResult(result, effectiveSourceId);
          final suggestions = songs
              .map((s) => '${s.title} - ${s.artist}')
              .where((s) => s.trim().isNotEmpty)
              .toList();
          if (suggestions.isNotEmpty) return suggestions;
        }
      } catch (_) {}
    }

    // 插件没有独立联想接口时，用普通搜索的前几条结果当联想。
    try {
      final songs = await search(
        query,
        sourceId: effectiveSourceId,
        page: 1,
        limit: 8,
      );
      final suggestions = songs
          .map((s) => '${s.title} - ${s.artist}')
          .where((s) => s.trim().isNotEmpty)
          .toList();
      if (suggestions.isNotEmpty) return suggestions;
    } catch (_) {}

    return [];
  }

  Future<List<String>> getHotSearchTags({String sourceId = 'wy'}) async {
    final effective = _canonicalSourceId(sourceId);
    final host = _findPluginForSource(effective);
    if (host == null) return const <String>[];
    try {
      final raw = await host.getHotSearchTags();
      final tags = _pluginHotSearchTags(raw);
      if (tags.isNotEmpty) return tags;
    } catch (e) {
      print('[MusicSourceManager] 插件热门搜索获取失败 source=$sourceId: $e');
    }
    return const <String>[];
  }

  /// 解析插件返回的热门搜索词。
  ///
  /// 兼容 `["晴天", ...]`、`[{name:"晴天"}]`、`{tags:[...]}` 三种写法。
  List<String> _pluginHotSearchTags(String? raw) {
    final decoded = _decodePluginJson(raw);
    final list = decoded is List
        ? decoded
        : (decoded is Map
              ? (decoded['tags'] ?? decoded['data'] ?? decoded['list'])
              : null);
    if (list is! List) return const <String>[];
    final tags = <String>[];
    for (final item in list) {
      String? text;
      if (item is String) {
        text = _nonEmptyText(item);
      } else if (item is Map) {
        text = _nonEmptyText(
          item['name'] ?? item['keyword'] ?? item['query'] ?? item['word'],
        );
      }
      if (text == null) continue;
      if (tags.contains(text)) continue;
      tags.add(text);
      if (tags.length >= 12) break;
    }
    return tags;
  }

  List<Song> _parsePluginSearchResult(String resultJson, String sourceId) {
    // 变体 id（'wy@插件id'）只用于路由到具体插件，歌曲的 source 仍记平台 id，
    // 这样播放 / 歌词等逻辑依旧按平台处理。
    final (baseSourceId, _) = splitSourceId(sourceId);
    try {
      var decoded = jsonDecode(resultJson);

      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {}
      }

      List<dynamic> findItems(dynamic value, int depth) {
        if (depth > 4 || value == null) return const [];
        if (value is String) {
          try {
            return findItems(jsonDecode(value), depth + 1);
          } catch (_) {
            return const [];
          }
        }
        if (value is List) return value;
        if (value is! Map) return const [];

        // Different LX/CeruMusic adapters wrap the same list under different
        // names. Read the common envelopes before treating the result as
        // unsupported. `list` remains first because it is the canonical form.
        for (final key in const [
          'list',
          'songs',
          'items',
          'records',
          'data',
          'result',
          'body',
        ]) {
          final nested = findItems(value[key], depth + 1);
          if (nested.isNotEmpty) return nested;
        }
        return const [];
      }

      final items = findItems(decoded, 0)
          .whereType<Map>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList();
      if (items.isNotEmpty) {
        // 变体 id（插件音源）记到 preferredSource：播放时优先用「歌曲来源的
        // 那个插件」解析——没有这层绑定的话，多平台插件（或播放页手动选的
        // 音源）会把这些歌曲劫走，表现为「插件-酷我歌单的歌用插件-qq 播放」。
        // source 仍记平台 id，跨插件兜底 / 歌词等逻辑保持原样。
        final boundPlugin = sourceId.contains('@') ? sourceId : null;
        final songs = items.map((item) {
          final song = _musicInfoToSong(item, baseSourceId);
          return boundPlugin == null
              ? song
              : song.copyWith(preferredSource: boundPlugin);
        }).toList();
        // 「隐藏B站会员专属歌曲」开启时，插件列表里的会员专属歌曲直接过滤
        // （搜索 / 专辑 / 作者 / 榜单详情都走这里；已收藏的歌单由收藏详情页
        // 按同一开关过滤展示）。
        if (hideVipExclusiveSongs) {
          return songs.where((song) => !song.isVipExclusive).toList();
        }
        return songs;
      }

      print('[MusicSourceManager] 无法识别的搜索结果格式: ${decoded.runtimeType}');
      return [];
    } catch (e) {
      print('[MusicSourceManager] Failed to parse plugin search result: $e');
      return [];
    }
  }

  Song _musicInfoToSong(Map<String, dynamic> info, String sourceId) {
    String? songId;
    final pluginSongId = info['songId'] ?? info['songid'];
    if (info['songmid'] != null) {
      songId = info['songmid'].toString();
    } else if (info['hash'] != null) {
      songId = info['hash'].toString();
    } else if (info['id'] != null) {
      songId = info['id'].toString();
    } else if (info['songId'] != null) {
      songId = info['songId'].toString();
    }

    String? artist;
    if (info['singer'] != null) {
      artist = info['singer'].toString();
    } else if (info['artist'] != null) {
      if (info['artist'] is List) {
        artist = (info['artist'] as List).map((e) => e.toString()).join('/');
      } else {
        artist = info['artist'].toString();
      }
    } else if (info['artists'] != null) {
      if (info['artists'] is List) {
        artist = (info['artists'] as List)
            .map((e) {
              if (e is Map) return e['name']?.toString() ?? e.toString();
              return e.toString();
            })
            .join('/');
      } else {
        artist = info['artists'].toString();
      }
    }

    String? album;
    if (info['albumName'] != null) {
      album = info['albumName'].toString();
    } else if (info['album'] != null) {
      if (info['album'] is Map) {
        album = info['album']['name']?.toString();
      } else {
        album = info['album'].toString();
      }
    } else if (info['album_name'] != null) {
      album = info['album_name'].toString();
    }

    String? coverUrl;
    // MusicFree 适配器总会输出 artwork / picUrl / img 等字段（插件没给
    // 封面时是**空字符串**而不是缺失），必须按「非空文本」取值，后面的
    // 兜底分支（酷我 songmid 封面直链等）才有机会生效——否则酷我插件的
    // 歌曲会封面为空，列表首次进入靠逐首 getPic 兜底（慢 / 易被风控），
    // 播放页则完全不显示封面。
    for (final key in const [
      'artwork',
      'picUrl',
      'pic',
      'cover',
      'img',
      'albumImg',
    ]) {
      coverUrl = _nonEmptyText(info[key]);
      if (coverUrl != null) break;
    }
    if (coverUrl == null && info['album'] != null && info['album'] is Map) {
      final album = info['album'] as Map;
      coverUrl =
          _nonEmptyText(album['picUrl']) ??
          _nonEmptyText(album['pic']) ??
          _nonEmptyText(album['artwork']);
    }
    if (coverUrl == null && info['al'] != null && info['al'] is Map) {
      final al = info['al'] as Map;
      coverUrl = _nonEmptyText(al['picUrl']) ?? _nonEmptyText(al['artwork']);
    }
    if (coverUrl == null && info['pic_id'] != null) {
      final picId = info['pic_id'].toString();
      if (sourceId == 'wy') {
        coverUrl = 'https://p3.music.126.net/$picId/${picId}_300x300.jpg';
      }
    }
    if (coverUrl == null && info['img3'] != null) {
      coverUrl = info['img3'].toString();
      if (!coverUrl.startsWith('http')) {
        coverUrl = 'http://d.musicapp.migu.cn$coverUrl';
      }
    }
    if (coverUrl == null && info['img2'] != null) {
      coverUrl = info['img2'].toString();
      if (!coverUrl.startsWith('http')) {
        coverUrl = 'http://d.musicapp.migu.cn$coverUrl';
      }
    }
    if (coverUrl == null && info['img1'] != null) {
      coverUrl = info['img1'].toString();
      if (!coverUrl.startsWith('http')) {
        coverUrl = 'http://d.musicapp.migu.cn$coverUrl';
      }
    }
    // 没有 artwork 时保持 coverUrl 为空，交给插件 getPic 去取图。

    String? title;
    if (info['name'] != null) {
      title = info['name'].toString();
    } else if (info['songname'] != null) {
      title = info['songname'].toString();
    } else if (info['title'] != null) {
      title = info['title'].toString();
    } else if (info['songName'] != null) {
      title = info['songName'].toString();
    }

    final lxMeta = Map<String, dynamic>.from(info);
    lxMeta.addAll({
      'songmid': info['songmid']?.toString() ?? songId,
      'songId': pluginSongId,
      'songid': pluginSongId,
      'hash': info['hash']?.toString(),
      'albumName': album ?? '',
      'albumId': info['albumId']?.toString() ?? info['albumid']?.toString(),
      'img': coverUrl,
      'name': title ?? '',
      'singer': artist ?? '',
      'source': sourceId,
    });

    return Song(
      id: songId ?? '${DateTime.now().millisecondsSinceEpoch}',
      title: title ?? '未知歌曲',
      artist: artist ?? '未知艺术家',
      album: album ?? '',
      coverUrl: coverUrl,
      source: sourceId,
      lyricUrl: sourceId == 'tx' ? pluginSongId?.toString() : null,
      duration: info['duration'] != null
          ? _parseDurationSeconds(info['duration'])
          : 0,
      hash: info['hash']?.toString(),
      year: parseSongYear(
        info['year'] ?? info['publishTime'] ?? info['pubtime'],
      ),
      lx: lxMeta,
      isVipExclusive: info['vipExclusive'] == true,
      partsCount: info['parts'] is num ? (info['parts'] as num).toInt() : 0,
    );
  }

  int _parseDurationSeconds(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.round();
    final text = value.toString();
    final direct = int.tryParse(text);
    if (direct != null) return direct;
    final parts = text.split(':').map((e) => int.tryParse(e) ?? 0).toList();
    if (parts.length == 2) return parts[0] * 60 + parts[1];
    if (parts.length == 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
    return 0;
  }

  Future<List<Song>> resolveSongUrls(List<Song> songs) async {
    // Remote LX URLs are short-lived and some plugins use one JS request
    // context. Keep explicit eager resolution sequential; normal playback
    // resolves only the current song.
    final resolved = <Song>[];
    for (final song in songs) {
      if (song.source == null ||
          song.source == 'local' ||
          song.sourceUrl != null) {
        resolved.add(song);
        continue;
      }

      try {
        final result = await getMusicUrlResult(song);
        resolved.add(
          result == null
              ? song.copyWith(sourceUrl: '')
              : _applyMusicUrlResult(song, result),
        );
      } catch (_) {
        resolved.add(song.copyWith(sourceUrl: ''));
      }
    }
    return resolved;
  }

  Future<Song> resolveSingleSongUrl(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    void Function(String message)? onResolveError,
  }) async {
    if (song.source == null || song.source == 'local') return song;
    final result = await getMusicUrlResult(
      song,
      quality: quality,
      excludedUrls: excludedUrls,
      onResolveError: onResolveError,
    );
    if (result != null && result.url.isNotEmpty) {
      return _applyMusicUrlResult(song, result, requestedQuality: quality);
    }
    return song;
  }

  Song _applyMusicUrlResult(
    Song song,
    PluginMusicUrlResult result, {
    String? requestedQuality,
  }) {
    final quality = result.quality.isEmpty ? requestedQuality : result.quality;
    return song.copyWith(
      sourceUrl: result.url,
      sourceHeaders: result.headers.isEmpty ? null : result.headers,
      sourceQuality: quality,
      clearSourceHeaders: result.headers.isEmpty,
      clearSourceQuality: quality == null || quality.isEmpty,
    );
  }

  Future<List<String>> getMusicUrlCandidates(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
  }) async {
    final results = await getMusicUrlResultCandidates(
      song,
      quality: quality,
      excludedUrls: excludedUrls,
    );
    return results.map((result) => result.url).toList();
  }

  /// 解析一首歌在指定音质下的播放链接候选（与真实播放完全一致的路径）。
  ///
  /// 播放链接由插件解析。
  /// [pluginHosts] 供插件测试传入被测宿主（隔离或共享），缺省时使用当前
  /// 已启用的插件宿主，保证测试结果与实际播放一致。
  Future<List<PluginMusicUrlResult>> getMusicUrlResultCandidates(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    List<PluginHost>? pluginHosts,
    void Function(String message)? onResolveError,
  }) async {
    // 插件重装后 id 会变：歌曲里存的旧插件 id 直接丢掉，退回平台 id，
    // 否则会被判成「该音源不可用（插件未启用或已卸载）」。
    final sourceId = _liveSourceId(song.source ?? '');
    if (sourceId.isEmpty) return const <PluginMusicUrlResult>[];

    // 数据源（只提供元数据）的歌曲：播放地址交给用户为它指定的播放源解析。
    final dataSourcePluginId = dataSourcePluginIdForSong(song);
    if (dataSourcePluginId != null) {
      return _resolveViaDataSourcePlayback(
        song,
        dataSourcePluginId: dataSourcePluginId,
        quality: quality,
        excludedUrls: excludedUrls,
        onResolveError: onResolveError,
      );
    }

    final musicInfo = _buildPluginMusicInfo(song, sourceId);
    final results = <PluginMusicUrlResult>[];

    // An enabled LX plugin is the authoritative resolver because it receives
    // the provider-specific song metadata and requested quality. In
    // particular, Kuwo's legacy endpoint can return HTTP 200 for its
    // free-listening permission prompt instead of the requested song.
    //
    // 数据源插件没有 musicUrl，取地址时必须排除：否则会拿「musicUrl 不是函数」
    // 这类无关错误盖掉真正的原因（只装了数据源时尤其明显）。
    final hosts =
        (pluginHosts ??
                _orderedHostsForSource(
                  sourceId,
                  preferredPlugin: song.preferredSource,
                ))
            .where((host) => !host.isDataSource)
            .toList(growable: false);
    for (final host in hosts) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId == null) continue;

      try {
        final result = await host.getMusicUrlResult(
          pluginSourceId,
          musicInfo,
          quality,
        );
        if (result.quality.trim().isNotEmpty &&
            musicQualityKey(result.quality) != musicQualityKey(quality)) {
          throw Exception('音质不匹配：请求 $quality，插件返回 ${result.quality}，已拒绝替换音质');
        }
        final url = result.url.trim();
        final normalized = PluginMusicUrlResult(
          url: url,
          quality: quality,
          headers: result.headers,
          // 记录实际提供地址的音源（插件），界面上据此显示当前使用的音源。
          source: _pluginSourceAppId(host, pluginSourceId),
        );
        print(
          '[MusicSourceManager] LX URL candidate: source=$sourceId '
          'requested=$quality reported=${result.quality} host=${_urlHost(url)}',
        );
        // 拒绝酷我提示音 / 加密格式 URL
        if (musicInfo.source == 'kw' && _isKuwoPromptUrl(url)) {
          print('[MusicSourceManager] 拒绝酷我无效 URL: $url');
          continue;
        }
        if (url.isNotEmpty &&
            _isValidAudioUrl(url) &&
            !excludedUrls.contains(url) &&
            !results.any((item) => item.url == url)) {
          results.add(normalized);
        }
      } catch (e) {
        print(
          '[MusicSourceManager] LX URL failed: '
          'source=$sourceId quality=$quality error=$e',
        );
        // 接口的具体错误（如 HTTP 412 风控）带回调用方，用于播放失败提示。
        onResolveError?.call(
          e.toString().replaceFirst(RegExp(r'^Exception:\s*'), ''),
        );
      }
    }

    return results;
  }

  // 同平台共享歌曲标识，只有跨平台才需要搜索匹配。
  Future<List<PluginMusicUrlResult>> _resolveViaDataSourcePlayback(
    Song song, {
    required String dataSourcePluginId,
    required String quality,
    required Set<String> excludedUrls,
    void Function(String message)? onResolveError,
  }) async {
    final dataSourceName = dataSourceDisplayName(dataSourcePluginId);
    final playbackSourceId = dataSourcePlaybackSource(dataSourcePluginId);

    String fail(String playbackName, Object? error) {
      var detail = error == null ? '' : '$error';
      detail = detail
          .replaceFirst(RegExp(r'^Exception:\s*'), '')
          .replaceAll('"', "'")
          .replaceAll('\n', ' ')
          .trim();
      if (detail.isEmpty) detail = '未知错误';
      return '此$dataSourceName指定的 $playbackName音源失效，错误："$detail" '
          '请在插件管理中设置其他音源。';
    }

    if (playbackSourceId == null) {
      final message =
          '此$dataSourceName未指定播放源，错误："未设置播放源" '
          '请在插件管理中设置其他音源。';
      onResolveError?.call(message);
      throw DataSourcePlaybackException(message);
    }

    if (isDataSourceSource(playbackSourceId)) {
      final message = fail(
        sourceDisplayName(playbackSourceId),
        '指定的播放源本身也是数据源，无法解析播放地址',
      );
      onResolveError?.call(message);
      throw DataSourcePlaybackException(message);
    }

    // 指定的播放源必须仍然可用（插件没被卸载 / 关闭）。
    //
    // 插件卸载后重装会换一个新的 id，老歌曲里记的还是旧 id：这种情况不能直接
    // 判「音源不可用」，否则收藏里那批老歌永远放不了。退一步用当前可用的同平台
    // 音源继续解析，实在没有才报错。
    var effectivePlaybackId = _liveSourceId(playbackSourceId);
    var hosts = _findPluginHostsForSource(effectivePlaybackId);
    // 只有「插件已经不在了」（卸载 / 重装换 id）才自动换一个音源兜底；
    // 插件还在、只是这个音源被用户关掉了，仍然如实报错，不偷偷换。
    if (hosts.isEmpty && !_isPluginIdLive(_pluginIdOf(playbackSourceId))) {
      final fallback = _fallbackPlaybackSource(
        song,
        exclude: effectivePlaybackId,
      );
      if (fallback != null) {
        print(
          '[MusicSourceManager] 数据源指定的播放源 $playbackSourceId 已失效，'
          '改用 $fallback',
        );
        effectivePlaybackId = fallback;
        hosts = _findPluginHostsForSource(effectivePlaybackId);
      }
    }
    final playbackName = sourceDisplayName(effectivePlaybackId);
    if (hosts.isEmpty) {
      final message = fail(playbackName, '该音源不可用（插件未启用或已卸载）');
      onResolveError?.call(message);
      throw DataSourcePlaybackException(message);
    }

    final (dataBaseId, _) = splitSourceId(song.source ?? '');
    final (playbackBaseId, _) = splitSourceId(effectivePlaybackId);
    Song? matched;
    if (dataBaseId.isNotEmpty && dataBaseId == playbackBaseId) {
      if (song.id.trim().isEmpty) {
        final message = fail(playbackName, '歌曲缺少同平台解析所需的标识');
        onResolveError?.call(message);
        throw DataSourcePlaybackException(message);
      }
      // 清掉数据源绑定，避免递归进入数据源委托；原歌曲仍保留该绑定。
      matched = song.copyWith(
        source: effectivePlaybackId,
        clearPreferredSource: true,
      );
    } else {
      try {
        final keyword = '${song.title} ${song.artist}'.trim();
        final candidates = await search(
          keyword,
          sourceId: effectivePlaybackId,
          page: 1,
          limit: 20,
        );
        for (final item in candidates) {
          if (_isSameSong(song, item)) {
            matched = item;
            break;
          }
        }
        matched ??= _bestTitleMatch(song, candidates);
      } catch (e) {
        final message = fail(playbackName, e);
        onResolveError?.call(message);
        throw DataSourcePlaybackException(message);
      }

      if (matched == null) {
        final message = fail(playbackName, '在$playbackName里没有搜到这首歌');
        onResolveError?.call(message);
        throw DataSourcePlaybackException(message);
      }
    }

    final resolved = <PluginMusicUrlResult>[];
    String? lastError;
    try {
      final results = await getMusicUrlResultCandidates(
        matched,
        quality: quality,
        excludedUrls: excludedUrls,
        onResolveError: (message) => lastError = message,
      );
      for (final result in results) {
        if (result.url.isEmpty) continue;
        // 不写 result.source：歌曲仍然归属数据源，收藏 / 队列继续绑定数据源插件。
        resolved.add(
          PluginMusicUrlResult(
            url: result.url,
            quality: result.quality,
            headers: result.headers,
          ),
        );
      }
    } catch (e) {
      lastError = '$e';
    }

    if (resolved.isEmpty) {
      final message = fail(playbackName, lastError ?? '播放源未返回可用的播放地址');
      onResolveError?.call(message);
      throw DataSourcePlaybackException(message);
    }
    return resolved;
  }

  /// 歌名完全一致（忽略大小写 / 空白）的候选中取第一个；没有则返回 null。
  ///
  /// 只按歌名放宽（允许歌手写法不同，例如「A、B」与「A/B」），不做模糊匹配，
  /// 避免把别的歌的地址用到当前歌曲上。
  static Song? _bestTitleMatch(Song target, List<Song> candidates) {
    String norm(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final title = norm(target.title);
    if (title.isEmpty) return null;
    for (final item in candidates) {
      if (norm(item.title) == title) return item;
    }
    return null;
  }

  String _urlHost(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return 'invalid';
    return uri.host;
  }

  Future<PluginMusicUrlResult?> getMusicUrlResult(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    void Function(String message)? onResolveError,
  }) async {
    final candidates = await getMusicUrlResultCandidates(
      song,
      quality: quality,
      excludedUrls: excludedUrls,
      onResolveError: onResolveError,
    );
    return candidates.isEmpty ? null : candidates.first;
  }

  Future<String?> getMusicUrl(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
  }) async {
    final candidates = await getMusicUrlCandidates(
      song,
      quality: quality,
      excludedUrls: excludedUrls,
    );
    return candidates.isEmpty ? null : candidates.first;
  }

  String _stripSourcePrefix(String songId, String sourceId) {
    final prefix = '${sourceId}_';
    if (songId.startsWith(prefix)) {
      return songId.substring(prefix.length);
    }
    return songId;
  }

  MusicInfoForPlugin _buildPluginMusicInfo(Song song, String sourceId) {
    final (baseSourceId, _) = splitSourceId(sourceId);
    final cleanId = _stripSourcePrefix(song.id, baseSourceId);
    final lx = song.lx ?? const <String, dynamic>{};

    dynamic read(List<String> keys) {
      for (final key in keys) {
        final value = lx[key];
        if (value != null && value.toString().isNotEmpty) return value;
      }
      return null;
    }

    String? readString(List<String> keys) {
      final value = read(keys);
      return value == null ? null : value.toString();
    }

    Map<String, dynamic>? readMap(String key) {
      final value = lx[key];
      return value is Map ? Map<String, dynamic>.from(value) : null;
    }

    List<dynamic>? readList(String key) {
      final value = lx[key];
      return value is List ? List<dynamic>.from(value) : null;
    }

    final songId =
        read(['songId', 'songid', 'copyrightId']) ??
        (baseSourceId == 'tx' ? song.lyricUrl : null);
    final songmid = readString(['songmid', 'mid']) ?? cleanId;
    final interval = readString(['interval']) ?? _formatInterval(song.duration);

    return MusicInfoForPlugin(
      songmid: songmid,
      songId: songId,
      hash: readString(['hash']) ?? song.hash ?? cleanId,
      name: readString(['name', 'songName', 'title']) ?? song.title,
      singer: readString(['singer', 'artist']) ?? song.artist,
      albumName: readString(['albumName', 'album_name']) ?? song.album,
      albumId: read(['albumId', 'albumid']),
      albumMid: read(['albumMid', 'albummid']),
      strMediaMid: read(['strMediaMid']),
      copyrightId:
          readString(['copyrightId']) ??
          // 咪咕的 copyrightId 就是歌曲 id（插件搜索结果里没有 lx 元数据）。
          (baseSourceId == 'mg' ? cleanId : null),
      source: baseSourceId,
      interval: interval,
      img: readString(['img', 'pic', 'picUrl', 'cover']) ?? song.coverUrl,
      lrc: song.lrc,
      lrcUrl: readString(['lrcUrl']),
      mrcUrl: readString(['mrcUrl']),
      trcUrl: readString(['trcUrl']),
      types: readList('types'),
      typeMap: readMap('_types'),
      typeUrl: readMap('typeUrl') ?? <String, dynamic>{},
      // MusicFree 插件解析播放地址 / 歌词时需要原始 musicItem，这里原样回传。
      extra: readMap('extra'),
    );
  }

  String _formatInterval(int durationSeconds) {
    if (durationSeconds <= 0) return '';
    final minutes = durationSeconds ~/ 60;
    final seconds = durationSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Future<String?> getLyric(Song song) async {
    // 歌词跟随「当前使用的音源」：插件变体（含歌曲绑定的优先插件）直接
    // 找那个插件取词，换音源后不会拿到别的音源的歌词。
    final sourceId = song.lyricSourceId;
    if (sourceId.isEmpty) {
      print('[MusicSourceManager] getLyric: source is empty');
      return null;
    }

    print(
      '[MusicSourceManager] getLyric: source=$sourceId, songId=${song.id}, title=${song.title}',
    );

    // 对齐 CeruMusic：插件优先
    final host = _findPluginForSource(sourceId);
    if (host != null) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId != null) {
        final musicInfo = _buildPluginMusicInfo(song, sourceId);
        try {
          print('[MusicSourceManager] getLyric: calling plugin getLyric');
          final result = await host.getLyric(pluginSourceId, musicInfo);
          print(
            '[MusicSourceManager] getLyric: plugin result: ${result != null ? "has ${result.length} chars" : "null"}',
          );
          if (result != null && result.isNotEmpty) {
            return result;
          }
        } catch (e) {
          print('[MusicSourceManager] getLyric: plugin error: $e');
        }
      }
    }

    print('[MusicSourceManager] getLyric: no source available');
    // 同名插件没给到歌词时，再用其它已安装的插件找同一首歌的歌词。
    final otherLyric = await _lyricFromOtherPlugins(song);
    if (otherLyric == null) return null;
    final lrc = (otherLyric.lrc ?? '').trim();
    if (lrc.isNotEmpty) return lrc;
    final wordLrc = (otherLyric.crlyric ?? '').trim();
    return wordLrc.isEmpty ? null : wordLrc;
  }

  /// 其它已安装插件的歌词（只有完全匹配的歌才采用）。
  ///
  /// 同名插件拿不到歌词时，就换其它已安装的插件重新找同一首歌；歌名 / 歌手
  /// 对不上时不用它的歌词，避免显示错歌的词。
  Future<LyricResult?> _lyricFromOtherPlugins(Song song) async {
    final source = song.source;
    if (source == null || source.isEmpty || source.contains('@')) return null;
    final others = pluginSourceIds
        .where((id) => !id.startsWith('$source@'))
        .toList();
    if (others.isEmpty) return null;

    for (final candidate in await matchSongsInSources(song, others)) {
      try {
        final result = await getLyricResult(candidate);
        if (result != null && _hasLyric(result)) return result;
      } catch (e) {
        print('[MusicSourceManager] 其它插件歌词获取失败: $e');
      }
    }
    return null;
  }

  /// 在指定音源里找与 [song] 完全匹配的歌（用于换源 / 换歌词）。
  ///
  /// 只保留歌名与歌手都一致的结果，避免把别的歌的地址 / 歌词用过来。
  Future<List<Song>> matchSongsInSources(
    Song song,
    List<String> sourceIds,
  ) async {
    final keyword = '${song.title} ${song.artist}'.trim();
    final matched = <Song>[];
    for (final sourceId in sourceIds) {
      try {
        final songs = await search(
          keyword,
          sourceId: sourceId,
          page: 1,
          limit: 15,
        );
        for (final item in songs) {
          if (_isSameSong(song, item)) matched.add(item);
        }
      } catch (e) {
        print('[MusicSourceManager] 匹配歌曲失败 source=$sourceId: $e');
      }
    }
    return matched;
  }

  /// 两首歌是否完全一致（歌名 + 歌手，忽略大小写与空白）。
  static bool _isSameSong(Song a, Song b) {
    String norm(String value) =>
        value.trim().toLowerCase().replaceAll(RegExp(r'\s+'), '');
    return norm(a.title) == norm(b.title) && norm(a.artist) == norm(b.artist);
  }

  /// 解析下载用的播放地址。
  ///
  /// 平台歌曲没有安装任何可用的插件音源：保留原 id，下载时同样由插件解析。
  Future<({String url, String source})?> getMusicUrlForDownload(
    Song song, {
    String quality = '320k',
  }) async {
    final candidates = await getMusicUrlResultCandidates(
      song,
      quality: quality,
    );
    for (final candidate in candidates) {
      if (candidate.url.isEmpty) continue;
      return (
        url: candidate.url,
        source: candidate.source ?? song.source ?? '',
      );
    }

    final source = song.source;
    if (source == null || source.isEmpty) return null;
    final others = playbackFallbackSourceIds(source);
    if (others.isEmpty) return null;

    for (final candidate in await matchSongsInSources(song, others)) {
      final urls = await getMusicUrlResultCandidates(
        candidate,
        quality: quality,
      );
      for (final url in urls) {
        if (url.url.isEmpty) continue;
        return (url: url.url, source: url.source ?? candidate.source ?? '');
      }
    }
    return null;
  }

  /// 播放失败 / 需要换源时要尝试的插件音源 id（按优先级排列）。
  ///
  /// * 同平台优先：`酷狗1 → 酷狗2 → …`；
  /// * 其它平台：按插件音源列表顺序；
  /// * **只含用户安装的插件音源**：所有插件都失败即停止换源。
  List<String> playbackFallbackSourceIds(String currentSource) {
    final current = currentSource.trim();
    if (current.isEmpty) return const <String>[];
    final (baseId, _) = splitSourceId(current);
    final result = <String>[];
    final seen = <String>{current};

    void add(String id) {
      if (id.isEmpty || !seen.add(id)) return;
      result.add(id);
    }

    // 1. 同平台的其它插件音源。
    for (final id in pluginSourceIds) {
      if (splitSourceId(id).$1 == baseId) add(id);
    }
    // 2. 其它平台的插件音源。
    for (final id in pluginSourceIds) {
      if (splitSourceId(id).$1 == baseId) continue;
      add(id);
    }
    return result;
  }

  // ---------------------------------------------------------------- 专辑 / 作者

  /// 某个音源是否支持搜索专辑 / 作者。
  bool sourceSupportsCollectionSearch(String sourceId, CollectionType type) {
    if (sourceId.isEmpty) return false;
    final effective = _canonicalSourceId(sourceId);
    final wantAlbum = type == CollectionType.album;
    for (final host in _findPluginHostsForSource(effective)) {
      if (wantAlbum ? host.supportsAlbumSearch : host.supportsArtistSearch) {
        return true;
      }
    }
    return false;
  }

  /// 搜索专辑 / 作者（支持分页）。
  ///
  /// 插件明确返回 `isEnd: false` 才认为还有下一页；抛出的异常（网络 / 插件
  /// 报错）原样传给上层，界面据此显示「加载失败 + 重试」。
  Future<CollectionSearchPage> searchCollections(
    String keyword, {
    required String sourceId,
    required CollectionType type,
    int page = 1,
    int limit = 30,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) return const CollectionSearchPage();

    final effective = _canonicalSourceId(sourceId);

    final wantAlbum = type == CollectionType.album;
    final results = <SearchCollection>[];
    final seen = <String>{};
    var isEnd = true;
    var successfulHosts = 0;
    int? total;
    Object? lastError;
    for (final host in _findPluginHostsForSource(effective)) {
      if (!(wantAlbum ? host.supportsAlbumSearch : host.supportsArtistSearch)) {
        continue;
      }
      final pluginSourceId = _getSourceIdForHost(host, effective);
      if (pluginSourceId == null) continue;
      try {
        final raw = await host.searchTyped(
          _resolvePluginSourceId(pluginSourceId),
          query,
          page: page,
          type: type.id,
          limit: limit,
        );
        final resultSource = _pluginSourceAppId(host, pluginSourceId);
        final parsed = _parseCollectionList(raw, resultSource, type);
        successfulHosts++;
        total = parsed.total;
        if (!parsed.isEnd) isEnd = false;
        for (final item in parsed.items) {
          if (seen.add('${item.source}:${item.id}')) results.add(item);
        }
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null) throw lastError;
    return CollectionSearchPage(
      items: results,
      isEnd: isEnd,
      total: successfulHosts == 1 ? total : null,
    );
  }

  /// 解析 `{list, isEnd, total}` 形式的专辑 / 作者搜索结果。
  CollectionSearchPage _parseCollectionList(
    String? rawJson,
    String sourceId,
    CollectionType type,
  ) {
    final decoded = _decodePluginPage(rawJson);
    final list = decoded is List ? decoded : decoded['list'] ?? decoded['data'];
    if (list is! List) {
      throw const FormatException('音源没有返回专辑 / 作者列表');
    }
    final items = <SearchCollection>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final json = entry.map((k, v) => MapEntry('$k', v));
      final item = SearchCollection.fromJson(
        json,
        source: sourceId,
        type: type,
      );
      if (item.id.isEmpty || item.title.isEmpty) continue;
      items.add(item);
    }
    return CollectionSearchPage(
      items: items,
      isEnd: _pluginResultIsEnd(decoded),
      total: _pluginTotalOf(decoded),
    );
  }

  /// 专辑 / 作者详情（含歌曲列表），支持分页。
  ///
  /// 失败时抛 [CollectionDetailException]：调用方需要区分「这次加载失败了」
  /// 和「这个专辑 / 作者确实没有作品」，前者要显示重试按钮。
  Future<CollectionDetail> getCollectionDetail(
    SearchCollection item, {
    int page = 1,
  }) async {
    final effective = _canonicalSourceId(item.source);
    final hosts = _findPluginHostsForSource(effective);
    if (hosts.isEmpty) {
      throw CollectionDetailException(
        '没有找到提供该${item.type.label}的音源，请在插件管理里检查是否已启用',
      );
    }
    final host = hosts.first;
    final pluginSourceId = _getSourceIdForHost(host, effective) ?? effective;

    String? raw;
    try {
      raw = item.type == CollectionType.album
          ? await host.getAlbumInfo(
              _resolvePluginSourceId(pluginSourceId),
              item.raw,
              page: page,
            )
          : await host.getArtistWorks(
              _resolvePluginSourceId(pluginSourceId),
              item.raw,
              page: page,
            );
    } catch (e) {
      throw CollectionDetailException('音源返回异常：$e');
    }

    if (raw == null) {
      throw CollectionDetailException('该音源没有提供${item.type.label}详情接口');
    }
    if (raw.isEmpty) {
      throw CollectionDetailException('音源返回了空数据，请稍后重试');
    }

    Map<String, dynamic> map;
    try {
      var decoded = jsonDecode(raw);
      if (decoded is String) {
        try {
          decoded = jsonDecode(decoded);
        } catch (_) {}
      }
      if (decoded is! Map) {
        throw const FormatException('返回结构不是对象');
      }
      map = decoded.map((k, v) => MapEntry('$k', v));
    } catch (e) {
      throw CollectionDetailException('解析${item.type.label}详情失败：$e');
    }

    final pluginError = map['error'];
    if (pluginError is String && pluginError.trim().isNotEmpty) {
      throw CollectionDetailException(pluginError.trim());
    }

    // MusicFree 的专辑 / 歌单详情用 musicList，作者作品用 data / list，
    // 以前只读 list / data，导致 musicList 的专辑详情永远是「没有获取到歌曲」。
    final list = map['musicList'] ?? map['list'] ?? map['data'];
    final songs = list is List
        ? _parsePluginSearchResult(jsonEncode({'list': list}), effective)
        : const <Song>[];

    var merged = item;
    final detailItem =
        map['albumItem'] ?? map['artistItem'] ?? map['sheetItem'];
    if (detailItem is Map) {
      final json = detailItem.map((k, v) => MapEntry('$k', v));
      final parsed = SearchCollection.fromJson(
        json,
        source: effective,
        type: item.type,
      );
      merged = SearchCollection(
        id: parsed.id.isEmpty ? item.id : parsed.id,
        title: parsed.title.isEmpty ? item.title : parsed.title,
        type: item.type,
        source: effective,
        coverUrl: (parsed.coverUrl?.isNotEmpty ?? false)
            ? parsed.coverUrl
            : item.coverUrl,
        artist: parsed.artist ?? item.artist,
        worksNum: parsed.worksNum > 0 ? parsed.worksNum : item.worksNum,
        date: (parsed.date?.isNotEmpty ?? false) ? parsed.date : item.date,
        description: (parsed.description?.isNotEmpty ?? false)
            ? parsed.description
            : item.description,
        raw: item.raw,
      );
    }
    return CollectionDetail(
      item: merged,
      songs: songs,
      isEnd: map['isEnd'] != false,
      total: _pluginTotalOf(map),
    );
  }

  /// 专辑发行年份缓存：`音源|专辑id → 年份`。
  ///
  /// 「歌曲信息对比」会随着切换候选反复问年份，同一张专辑只查一次。
  static final Map<String, int?> _albumYearCache = <String, int?>{};

  /// 取一首歌的发行年份。
  ///
  /// * 歌曲自带年份（插件搜索里给了）直接用；
  /// * 否则用插件给的专辑 id 拉一次专辑详情，从发行日期里取年份（有缓存）；
  /// * 拿不到（没有专辑 id / 请求超时 / 插件不支持专辑详情）返回 null。
  Future<int?> resolveSongYear(Song song) async {
    final own = song.year;
    if (own != null && own > 0) return own;
    final albumId = (song.lx?['albumId'] ?? '').toString().trim();
    final sourceId = (song.displaySource ?? song.source ?? '').trim();
    if (albumId.isEmpty || sourceId.isEmpty) return null;
    final key = '$sourceId|$albumId';
    if (_albumYearCache.containsKey(key)) return _albumYearCache[key];
    try {
      final detail = await getCollectionDetail(
        SearchCollection(
          id: albumId,
          title: song.album,
          type: CollectionType.album,
          source: sourceId,
          artist: song.artist,
          raw: {
            'id': albumId,
            'albumid': albumId,
            'albumMID': albumId,
            'mid': albumId,
            'title': song.album,
            'artist': song.artist,
          },
        ),
      ).timeout(const Duration(seconds: 6));
      final year = yearFromDateText(detail.item.date);
      if (year != null) _albumYearCache[key] = year;
      return year;
    } catch (e) {
      // 失败不缓存：网络恢复后再问一次还能拿到。
      print('[MusicSourceManager] 取专辑年份失败（$key）: $e');
      return null;
    }
  }

  Future<LyricResult?> getLyricResult(Song song) async {
    // 与歌词缓存键使用同一个音源身份（见 [Song.lyricSourceId]）。
    final sourceId = song.lyricSourceId;
    if (sourceId.isEmpty) return null;

    // 插件优先（逐字歌词只有插件可能提供）。
    final host = _findPluginForSource(sourceId);
    if (host != null) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId != null) {
        final musicInfo = _buildPluginMusicInfo(song, sourceId);
        try {
          final result = await host.getLyricResult(pluginSourceId, musicInfo);
          if (_hasLyric(result)) return result;
        } catch (e) {
          print('[MusicSourceManager] getLyricResult: plugin error: $e');
        }
      }
    }

    // 其它已安装插件的歌词（完全匹配才采用）
    final otherPluginLyric = await _lyricFromOtherPlugins(song);
    if (otherPluginLyric != null) return otherPluginLyric;

    // 纯文本回退
    final rawLyric = await getLyric(song);
    if (rawLyric == null || rawLyric.isEmpty) return null;
    return LyricResult(lrc: rawLyric);
  }

  bool _hasLyric(LyricResult? result) {
    return (result?.lrc?.trim().isNotEmpty ?? false) ||
        (result?.crlyric?.trim().isNotEmpty ?? false);
  }

  Future<String?> getPic(
    Song song, {
    Set<String> excludedUrls = const <String>{},
    bool refresh = false,
  }) async {
    final sourceId = song.source;
    if (sourceId == null) return null;

    final cacheKey = '$sourceId:${song.id}';
    final cached = _coverCache[cacheKey];
    // refresh 用于「上一次只是插件 / 网络抖动」的重试：绕过缓存的空结果，
    // 否则重试会直接拿到 null，列表里的封面就再也补不上了。
    if (!refresh &&
        cached != null &&
        cached.isValid &&
        (cached.data == null || !excludedUrls.contains(cached.data))) {
      return cached.data;
    }

    final host = _findPluginForSource(sourceId);
    if (host != null) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId != null) {
        final musicInfo = _buildPluginMusicInfo(song, sourceId);
        try {
          final result = await host.getPic(pluginSourceId, musicInfo);
          if (result != null &&
              result.isNotEmpty &&
              !excludedUrls.contains(result)) {
            _coverCache[cacheKey] = _CacheEntry(result, _searchResultsTTL);
            return result;
          }
        } catch (_) {}
      }
    }

    _coverCache[cacheKey] = _CacheEntry(null, _searchResultsTTL);
    return null;
  }

  /* ------------------------------------------------------------------ *
   * 发现页：插件（MusicFree）榜单与推荐歌单
   *
   * MusicFree 插件只按「歌单/榜单的原始 id」工作，而本项目的歌单详情页只有一
   * 个路由参数，所以插件来源的歌单 id 需要带上音源前缀：
   *   mf:sheet:<sourceId>:<encoded rawId>
   *   mf:board:<sourceId>:<encoded rawId>
   * ------------------------------------------------------------------ */

  static const String _pluginSheetIdPrefix = 'mf:sheet:';
  static const String _pluginBoardIdPrefix = 'mf:board:';

  static String pluginSheetId(String sourceId, String rawId) =>
      '$_pluginSheetIdPrefix$sourceId:${Uri.encodeComponent(rawId)}';

  static String pluginBoardId(String sourceId, String rawId) =>
      '$_pluginBoardIdPrefix$sourceId:${Uri.encodeComponent(rawId)}';

  static bool isPluginSheetId(String id) => id.startsWith(_pluginSheetIdPrefix);

  static bool isPluginBoardId(String id) => id.startsWith(_pluginBoardIdPrefix);

  /// 解析插件来源的歌单/榜单 id（非插件 id 返回 null）。
  static ({String sourceId, String rawId})? parsePluginDiscoveryId(String id) {
    for (final prefix in const [_pluginSheetIdPrefix, _pluginBoardIdPrefix]) {
      if (!id.startsWith(prefix)) continue;
      final rest = id.substring(prefix.length);
      final index = rest.indexOf(':');
      if (index <= 0) return null;
      final sourceId = rest.substring(0, index);
      final encoded = rest.substring(index + 1);
      if (sourceId.isEmpty || encoded.isEmpty) return null;
      String rawId;
      try {
        rawId = Uri.decodeComponent(encoded);
      } catch (_) {
        rawId = encoded;
      }
      return (sourceId: sourceId, rawId: rawId);
    }
    return null;
  }

  /// 找到能处理 [sourceId] 且具备所需发现能力的插件宿主。
  ///
  /// 只有插件自己的变体 id（`平台id@插件id`）才带发现内容：裸平台 id
  /// 不借用任何插件的浏览内容。
  PluginHost? _findDiscoverHost(
    String sourceId, {
    bool needTopList = false,
    bool needSheets = false,
    bool needSheetDetail = false,
  }) {
    final (baseId, pluginId) = splitSourceId(sourceId);
    if (pluginId == null) return null;
    for (final host in _findPluginHostsForSource(sourceId)) {
      if (!host.supportsDiscover) continue;
      if (needTopList && !host.supportsTopLists) continue;
      if (needSheets && !host.supportsRecommendSheets) continue;
      if (needSheetDetail && !host.supportsSheetDetail) continue;
      return host;
    }
    return null;
  }

  dynamic _decodePluginJson(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      return jsonDecode(raw.trim());
    } catch (_) {
      return null;
    }
  }

  String? _nonEmptyText(dynamic value) {
    if (value == null) return null;
    final text = value.toString().trim();
    return text.isEmpty ? null : text;
  }

  List<Playlist> _pluginPlaylistsFromJson(String sourceId, dynamic decoded) {
    final playlists = <Playlist>[];
    final list = decoded is List
        ? decoded
        : (decoded is Map ? decoded['playlists'] : null);
    if (list is! List) return playlists;

    for (final entry in list) {
      if (entry is! Map) continue;
      final rawId = _nonEmptyText(entry['id']);
      if (rawId == null) continue;
      playlists.add(
        Playlist(
          id: pluginSheetId(sourceId, rawId),
          title: _nonEmptyText(entry['title']) ?? rawId,
          description: _nonEmptyText(entry['description']) ?? '',
          coverUrl: _nonEmptyText(entry['coverUrl']),
          songCount: int.tryParse('${entry['songCount']}') ?? 0,
          playCount: _nonEmptyText(entry['playCount']),
          author: _nonEmptyText(entry['author']),
          source: sourceId,
        ),
      );
    }
    return playlists;
  }

  List<Leaderboard> _pluginLeaderboardsFromJson(
    String sourceId,
    dynamic decoded,
  ) {
    final boards = <Leaderboard>[];
    if (decoded is! List) return boards;

    for (final entry in decoded) {
      if (entry is! Map) continue;
      final rawId = _nonEmptyText(entry['id']);
      if (rawId == null) continue;
      final name = _nonEmptyText(entry['name']) ?? rawId;
      boards.add(
        Leaderboard(
          id: pluginBoardId(sourceId, rawId),
          name: name,
          // 榜单分类（巅峰榜/地区榜/特色榜/全球榜…），无分组为 null
          group: _nonEmptyText(entry['group']),
          coverUrl: _nonEmptyText(entry['coverUrl']),
          // 榜单卡片的播放量与更新时间（由插件给出已格式化的文本，
          // 例如「65.2亿」「刚刚更新」「每周四更新」「更新20首」）。
          playCount: _nonEmptyText(entry['playCount']),
          updateFrequency: _nonEmptyText(entry['updateFrequency']),
          source: sourceId,
        ),
      );
    }
    return boards;
  }

  /// 插件返回的热门标签：`[{id,name}]` 或 `{tags:[{id,name}]}`。
  List<PlaylistTag> _pluginHotTagsFromJson(String sourceId, dynamic decoded) {
    final tags = <PlaylistTag>[];
    final list = decoded is List
        ? decoded
        : (decoded is Map ? decoded['tags'] : null);
    if (list is! List) return tags;
    for (final entry in list) {
      if (entry is! Map) continue;
      final id = _nonEmptyText(entry['id']);
      if (id == null) continue;
      tags.add(
        PlaylistTag(
          id: id,
          name: _nonEmptyText(entry['name']) ?? id,
          source: sourceId,
        ),
      );
    }
    return tags;
  }

  List<PlaylistTagGroup> _pluginTagGroupsFromJson(
    String sourceId,
    dynamic decoded,
  ) {
    final groups = <PlaylistTagGroup>[];
    if (decoded is! List) return groups;

    for (final entry in decoded) {
      if (entry is! Map) continue;
      final tags = <PlaylistTag>[];
      final rawTags = entry['tags'];
      if (rawTags is List) {
        for (final tag in rawTags) {
          if (tag is! Map) continue;
          final id = _nonEmptyText(tag['id']);
          if (id == null) continue;
          tags.add(
            PlaylistTag(
              id: id,
              name: _nonEmptyText(tag['name']) ?? id,
              source: sourceId,
            ),
          );
        }
      }
      if (tags.isEmpty) continue;
      groups.add(
        PlaylistTagGroup(
          name: _nonEmptyText(entry['name']) ?? '分类',
          tags: tags,
        ),
      );
    }
    return groups;
  }

  /// 用插件推荐歌单的第一页数据充当「热门歌单」。
  Future<List<Playlist>> _getPluginHotPlaylists(String sourceId) async {
    final host = _findDiscoverHost(sourceId, needSheets: true);
    if (host == null) return const [];

    try {
      final groups = _pluginTagGroupsFromJson(
        sourceId,
        _decodePluginJson(await host.getRecommendSheetTags()),
      );
      final candidates = <String>[''];
      for (final group in groups) {
        for (final tag in group.tags) {
          if (!candidates.contains(tag.id)) candidates.add(tag.id);
        }
        if (candidates.length >= 3) break;
      }

      for (final tagId in candidates) {
        final playlists = _pluginPlaylistsFromJson(
          sourceId,
          _decodePluginJson(await host.getRecommendSheetsByTag(tagId)),
        );
        if (playlists.isNotEmpty) return playlists;
      }
    } catch (e) {
      print('[MusicSourceManager] 插件热门歌单获取失败 source=$sourceId: $e');
    }
    return const [];
  }

  /// 插件来源的歌单/榜单详情（单页）。
  Future<PlaylistPage> _getPluginDiscoveryDetail(
    String appId,
    String sourceId,
    String rawId, {
    required bool isBoard,
    int page = 1,
  }) async {
    final host = isBoard
        ? _findDiscoverHost(sourceId, needTopList: true)
        : _findDiscoverHost(sourceId, needSheetDetail: true);
    if (host == null) return const PlaylistPage();

    try {
      final raw = isBoard
          ? await host.getTopListDetail(rawId, page: page)
          : await host.getMusicSheetInfo(rawId, page: page);
      final decoded = _decodePluginPage(raw);
      final songs = _parsePluginSearchResult(raw!, sourceId);
      final sheetValue = decoded is Map ? decoded['sheet'] : null;
      final meta = sheetValue is Map ? sheetValue : const <String, dynamic>{};
      final total = _pluginTotalOf(decoded);
      final songCount = _nonNegativeInt(meta['songCount']);
      final isEnd = _pluginResultIsEnd(decoded);

      return PlaylistPage(
        playlist: Playlist(
          id: appId,
          title: _nonEmptyText(meta['title']) ?? '',
          description: _nonEmptyText(meta['description']) ?? '',
          coverUrl: _nonEmptyText(meta['coverUrl']),
          songCount: songCount ?? total ?? 0,
          songs: songs,
          author: _nonEmptyText(meta['author']),
          source: sourceId,
        ),
        isEnd: isEnd,
        total: total,
      );
    } catch (e) {
      print('[MusicSourceManager] 插件发现详情获取失败 id=$appId: $e');
      rethrow;
    }
  }

  Future<List<Playlist>> getHotPlaylists({String sourceId = 'wy'}) async {
    final cached = _hotPlaylistsCache[sourceId];
    if (cached != null && cached.isValid) {
      print('[MusicSourceManager] 热门歌单缓存命中: $sourceId');
      return cached.data;
    }

    // 插件（MusicFree）音源：用推荐歌单第一页数据充当热门歌单。
    final pluginHot = await _getPluginHotPlaylists(sourceId);
    if (pluginHot.isNotEmpty) {
      _hotPlaylistsCache[sourceId] = _CacheEntry(pluginHot, _hotPlaylistsTTL);
    }
    return pluginHot;
  }

  Future<List<PlaylistTagGroup>> getPlaylistTags({
    String sourceId = 'wy',
  }) async {
    // 分类由插件提供（例如网易云插件的「推荐」歌单）。
    final host = _findDiscoverHost(sourceId, needSheets: true);
    if (host != null) {
      try {
        final groups = _pluginTagGroupsFromJson(
          sourceId,
          _decodePluginJson(await host.getRecommendSheetTags()),
        );
        if (groups.isNotEmpty) return groups;
      } catch (e) {
        print('[MusicSourceManager] 插件歌单分类获取失败 source=$sourceId: $e');
      }
    }

    return [];
  }

  Future<List<PlaylistTag>> getHotPlaylistTags({String sourceId = 'wy'}) async {
    // 用插件的推荐分类当标签栏。
    final host = _findDiscoverHost(sourceId, needSheets: true);
    if (host != null) {
      // 插件可选地单独提供「热门标签」：这样顶部标签栏是 热门/华语/流行/摇滚…，
      // 而不是把「语种」分类的标签拿来顶替。
      try {
        final hot = _pluginHotTagsFromJson(
          sourceId,
          _decodePluginJson(await host.getHotPlaylistTags()),
        );
        if (hot.isNotEmpty) return hot;
      } catch (e) {
        print('[MusicSourceManager] 插件热门标签获取失败 source=$sourceId: $e');
      }
      try {
        final groups = _pluginTagGroupsFromJson(
          sourceId,
          _decodePluginJson(await host.getRecommendSheetTags()),
        );
        if (groups.isNotEmpty) {
          return groups.expand((group) => group.tags).take(8).toList();
        }
      } catch (e) {
        print('[MusicSourceManager] 插件歌单分类获取失败 source=$sourceId: $e');
      }
    }

    return [];
  }

  /// 分类歌单分页。
  ///
  /// 保留插件的页大小和结束标记，由调用方缓冲并切分 UI 页。
  Future<PageResult<Playlist>> getCategoryPlaylists({
    required String sortId,
    required String tagId,
    required int page,
    required int limit,
    String sourceId = 'wy',
  }) async {
    final host = _findDiscoverHost(sourceId, needSheets: true);
    if (host == null) return const PageResult(isEnd: true);
    final raw = await host.getRecommendSheetsByTag(tagId, page: page);
    return _parsePluginPlaylistPage(raw, sourceId);
  }

  PageResult<Playlist> _parsePluginPlaylistPage(String? raw, String sourceId) {
    final decoded = _decodePluginPage(raw);
    if (decoded is! List && decoded['playlists'] is! List) {
      throw const FormatException('音源没有返回歌单列表');
    }
    return PageResult(
      items: _pluginPlaylistsFromJson(sourceId, decoded),
      isEnd: _pluginResultIsEnd(decoded),
      total: _pluginTotalOf(decoded),
    );
  }

  /// 插件返回结果里的结束标记（缺省视为已到底）。
  static bool _pluginResultIsEnd(dynamic decoded) {
    if (decoded is Map) {
      final value = decoded['isEnd'];
      if (value is bool) return value;
    }
    return true;
  }

  Future<List<Leaderboard>> getLeaderboards({String sourceId = 'wy'}) async {
    // 插件（MusicFree）音源：getTopLists 的扁平化结果。
    final host = _findDiscoverHost(sourceId, needTopList: true);
    if (host != null) {
      try {
        return _pluginLeaderboardsFromJson(
          sourceId,
          _decodePluginJson(await host.getTopLists()),
        );
      } catch (e) {
        print('[MusicSourceManager] 插件榜单获取失败 source=$sourceId: $e');
      }
    }
    return [];
  }

  /// 歌单 / 榜单详情分页。
  ///
  /// - 插件（MusicFree）源：首屏结果进缓存，第 2 页起每次实时请求
  ///   `getMusicSheetInfo` / `getTopListDetail`，由插件的 `isEnd` 决定是否到底。
  Future<PlaylistPage> getPlaylistDetailPage(
    String playlistId, {
    int page = 1,
    String sourceId = 'wy',
  }) async {
    final pluginTarget = parsePluginDiscoveryId(playlistId);
    if (pluginTarget != null) {
      final result = await _getPluginDiscoveryDetail(
        playlistId,
        pluginTarget.sourceId,
        pluginTarget.rawId,
        isBoard: isPluginBoardId(playlistId),
        page: page,
      );
      if (page <= 1 && result.playlist != null) {
        _playlistDetailCache[playlistId] = _CacheEntry(
          result.playlist,
          _playlistDetailTTL,
        );
      }
      return result;
    }

    if (page > 1) return const PlaylistPage();

    final detail = await getPlaylistDetail(playlistId, sourceId: sourceId);
    return PlaylistPage(playlist: detail, isEnd: true);
  }

  Future<Playlist?> getPlaylistDetail(
    String playlistId, {
    String sourceId = 'wy',
  }) async {
    final cached = _playlistDetailCache[playlistId];
    if (cached != null && cached.isValid) {
      print('[MusicSourceManager] 歌单详情缓存命中: $playlistId');
      return cached.data;
    }

    // 插件（MusicFree）来源的歌单 / 榜单：id 自带音源前缀，直接路由到插件。
    final pluginTarget = parsePluginDiscoveryId(playlistId);
    if (pluginTarget != null) {
      final pluginPage = await getPlaylistDetailPage(playlistId, page: 1);
      return pluginPage.playlist;
    }

    return null;
  }

  Future<Playlist?> getLeaderboardDetail(
    String boardId, {
    int page = 1,
    String sourceId = 'wy',
  }) async {
    final pluginTarget = parsePluginDiscoveryId(boardId);
    if (pluginTarget != null) {
      final result = await _getPluginDiscoveryDetail(
        boardId,
        pluginTarget.sourceId,
        pluginTarget.rawId,
        isBoard: true,
        page: page,
      );
      return result.playlist;
    }
    return null;
  }

  /// 该音源是否支持「自定义歌单」。
  ///
  /// 插件声明 `customSheets: true` 后，App 可以自己建歌单（封面 / 名称 /
  /// 搜索关键字），歌单内容用插件自己的搜索接口按关键字分页获取；
  /// 插件本身不需要实现任何歌单接口。
  bool sourceSupportsCustomSheets(String sourceId) {
    final (baseId, _) = splitSourceId(sourceId);
    if (baseId.isEmpty) return false;
    for (final host in _findPluginHostsForSource(sourceId)) {
      if (!host.supportsCustomSheets) continue;
      if (_getSourceIdForHost(host, baseId) == null) continue;
      return true;
    }
    return false;
  }

  /// 该音源是否提供歌单 / 榜单内容。
  ///
  /// 插件只提供搜索与播放地址（落雪脚本就是这样）时没有浏览内容，发现页会
  /// 给出「该音源不提供歌单和榜单」的提示。
  bool sourceHasDiscoverContent(String sourceId) {
    return _findDiscoverHost(sourceId) != null;
  }

  List<SourceInfo> getDiscoverSupportedSources() {
    final sources = <SourceInfo>[];
    final seenIds = <String>{};

    // 插件没有浏览接口（榜单 / 推荐歌单）时，发现页的榜单 / 歌单会是空的，
    // 但这个音源依然可以用于搜索与播放，所以要出现在切换音源列表里，
    // 否则用户在主页就选不到它。
    for (final source in getPluginSupportedSources()) {
      if (seenIds.contains(source.id)) continue;
      seenIds.add(source.id);
      sources.add(source);
    }

    return sources;
  }

  /// 搜索歌单：通过指定音源的 searchPlaylist API 获取真实的歌单搜索结果。
  ///
  /// 搜索页只使用单个音源（默认是发现页正在用的那个），因此这里不再支持
  /// 聚合多个音源的模式。
  Future<List<Playlist>> searchPlaylists(
    String query, {
    required String sourceId,
    int page = 1,
    int limit = 30,
  }) async {
    return (await searchPlaylistsPage(
      query,
      sourceId: sourceId,
      page: page,
      limit: limit,
    )).items;
  }

  Future<PageResult<Playlist>> searchPlaylistsPage(
    String query, {
    required String sourceId,
    int page = 1,
    int limit = 30,
  }) async {
    if (query.isEmpty) return const PageResult(total: 0, isEnd: true);
    return _searchPlaylistsFromPlugins(
      query,
      _canonicalSourceId(sourceId),
      page: page,
      limit: limit,
    );
  }

  /// 插件音源的歌单搜索。
  ///
  /// 参考 [searchCollections] 的插件链路：按音源找到宿主、调用适配器的
  /// `searchPlaylists`、复用推荐歌单的解析（`{isEnd, playlists}` 结构）。
  ///
  /// 插件自己的页大小和 App 的每页条数（[limit]）不一定相同，直接把
  /// 「插件第 N 页」当「App 第 N 页」会在插件页偏小时提前判成没有下一页
  /// （表现为「歌单搜索只有第一页」）。这里按 (sourceId, query) 聚合插件的
  /// 多页结果，保证取满 `page * limit` 条（或插件已到底）再切片，与每页
  /// 固定条数的行为一致。
  Future<PageResult<Playlist>> _searchPlaylistsFromPlugins(
    String query,
    String sourceId, {
    int page = 1,
    int limit = 30,
  }) async {
    final cache = _playlistSearchCache;
    if (cache == null || cache.sourceId != sourceId || cache.query != query) {
      _playlistSearchCache = _PluginPlaylistSearchCache(sourceId, query);
    }
    final c = _playlistSearchCache!;
    final hosts = _findPluginHostsForSource(
      sourceId,
    ).where((host) => host.supportsPlaylistSearch).toList();

    while (!c.isEnd && c.items.length < page * limit) {
      final pageResults = <Playlist>[];
      var anyHostReportedMore = false;
      int? total;
      for (final host in hosts) {
        final pluginSourceId = _getSourceIdForHost(host, sourceId)!;
        final raw = await host
            .searchPlaylists(query, page: c.pluginPage + 1)
            .timeout(const Duration(seconds: 20));
        final appId = _pluginSourceAppId(host, pluginSourceId);
        final result = _parsePluginPlaylistPage(raw, appId);
        pageResults.addAll(result.items);
        total = result.total;
        if (result.isEnd == false) anyHostReportedMore = true;
      }
      // 整轮成功后再推进页码，失败重试仍请求同一插件页。
      c.pluginPage++;
      c.total = hosts.length == 1 ? total ?? c.total : null;
      final before = c.items.length;
      for (final p in pageResults) {
        c.add(p);
      }
      // 终止条件：所有宿主都没报告还有下一页，或这一轮没有新增（接口忽略
      // offset 反复返回同一页 / 真的没数据了）。
      if (!anyHostReportedMore || c.items.length == before) {
        c.isEnd = true;
      }
    }

    final start = (page - 1) * limit;
    final end = c.items.length < page * limit ? c.items.length : page * limit;
    return PageResult(
      items: start >= c.items.length ? const [] : c.items.sublist(start, end),
      total: c.total,
      isEnd: c.isEnd && end >= c.items.length,
    );
  }

  /// 插件歌单搜索的分页聚合缓存（只保留最近一次搜索的）。
  _PluginPlaylistSearchCache? _playlistSearchCache;

  /// 歌单搜索单页直取：只请求插件的第 [page] 页，不做多页聚合。
  ///
  /// 搜索页跳页直达用——点第 N 页只发一次请求，即使插件页比界面页小、
  /// 返回不满一页也接受，绝不把中间页逐页拉一遍。
  Future<PageResult<Playlist>> searchPlaylistsSinglePage(
    String query, {
    required String sourceId,
    int page = 1,
    int limit = 30,
  }) async {
    if (query.isEmpty) return const PageResult(total: 0, isEnd: true);
    final effective = _canonicalSourceId(sourceId);
    final hosts = _findPluginHostsForSource(
      effective,
    ).where((host) => host.supportsPlaylistSearch).toList();

    final items = <Playlist>[];
    final seen = <String>{};
    var isEnd = true;
    int? total;
    Object? lastError;
    for (final host in hosts) {
      final pluginSourceId = _getSourceIdForHost(host, effective);
      if (pluginSourceId == null) continue;
      try {
        final raw = await host
            .searchPlaylists(query, page: page)
            .timeout(const Duration(seconds: 20));
        final appId = _pluginSourceAppId(host, pluginSourceId);
        final result = _parsePluginPlaylistPage(raw, appId);
        for (final p in result.items) {
          if (seen.add(p.id)) items.add(p);
        }
        total = result.total;
        if (result.isEnd == false) isEnd = false;
      } catch (e) {
        lastError = e;
      }
    }
    if (lastError != null && items.isEmpty) throw lastError;
    return PageResult(
      items: items,
      // 插件页不足一页且没报告还有更多时才算到底
      isEnd: isEnd && items.length < limit,
      total: hosts.length == 1 ? total : null,
    );
  }
}

/// 按 (音源, 关键词) 聚合插件歌单搜索的多页结果。
class _PluginPlaylistSearchCache {
  _PluginPlaylistSearchCache(this.sourceId, this.query);

  final String sourceId;
  final String query;

  /// 聚合后的歌单（按 id 去重，保持顺序）。
  final List<Playlist> items = [];
  final Set<String> _ids = <String>{};

  /// 已经取到插件的第几页。
  int pluginPage = 0;

  /// 插件侧是否已经没有更多。
  bool isEnd = false;
  int? total;

  void add(Playlist playlist) {
    if (_ids.add(playlist.id)) items.add(playlist);
  }
}
