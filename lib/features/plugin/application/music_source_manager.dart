import 'dart:convert';
import '../../player/domain/models/song.dart';
import '../../player/domain/models/lyric_line.dart';
import '../../discover/domain/models/playlist.dart';
import '../../discover/domain/models/playlist_page.dart';
import '../../discover/domain/models/leaderboard.dart';
import '../domain/music_source_provider.dart';
import '../domain/plugin_types.dart';
import '../domain/source_id_mapping.dart';
import '../domain/builtin_source_states.dart';
import '../data/builtin_source_preferences.dart';
import '../data/plugin_service.dart';
import '../data/plugin_host.dart';
import '../data/netease_music_source.dart';
import '../data/kugou_music_source.dart';
import '../data/kw_music_source.dart';
import '../data/tx_music_source.dart';
import '../data/mg_music_source.dart';

class _CacheEntry<T> {
  final T data;
  final DateTime timestamp;
  final Duration ttl;

  _CacheEntry(this.data, this.ttl) : timestamp = DateTime.now();

  bool get isValid => DateTime.now().difference(timestamp) < ttl;
}

class MusicSourceManager {
  final PluginService _pluginService;
  final Map<String, MusicSourceProvider> _builtInSources = {};

  final Map<String, _CacheEntry<List<Playlist>>> _hotPlaylistsCache = {};
  final Map<String, _CacheEntry<Playlist?>> _playlistDetailCache = {};
  final Map<String, _CacheEntry<List<String>>> _searchSuggestionsCache = {};
  final Map<String, _CacheEntry<List<Song>>> _searchPageCache = {};
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
    _coverCache.clear();
    _searchResultsCache.clear();
  }

  void clearAllCaches() {
    _hotPlaylistsCache.clear();
    _playlistDetailCache.clear();
    _searchSuggestionsCache.clear();
    _searchPageCache.clear();
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

  MusicSourceManager(this._pluginService) {
    _builtInSources['wy'] = NeteaseMusicSource();
    _builtInSources['kg'] = KugouMusicSource();
    _builtInSources['kw'] = KuwoMusicSource();
    _builtInSources['tx'] = QQMusicSource();
    _builtInSources['mg'] = MiguMusicSource();
  }

  /* ------------------------------------------------------------------ *
   * 内置音源的启用/卸载状态
   * ------------------------------------------------------------------ */

  final BuiltInSourcePreferences _builtInSourcePreferences =
      BuiltInSourcePreferences();
  BuiltInSourceStates _builtInSourceStates = const BuiltInSourceStates();
  bool _builtInSourceStatesLoaded = false;

  BuiltInSourceStates get builtInSourceStates => _builtInSourceStates;

  bool get builtInSourceStatesLoaded => _builtInSourceStatesLoaded;

  /// 内置音源是否出现在音源选择器 / 聚合搜索中。
  bool isBuiltInSourceAvailable(String sourceId) {
    return _builtInSourceStates.isAvailable(sourceId);
  }

  /// 所有内置音源的 id 与展示名（不受启用/卸载状态影响，供管理页展示）。
  static List<SourceInfo> get allBuiltInSourceInfos => SourceIdMapping.idToName
      .entries
      .where((entry) => entry.key != 'qsvip')
      .map((entry) => SourceInfo(id: entry.key, name: entry.value))
      .toList();

  /// 当前参与搜索/发现的音源（按内置源定义顺序过滤）。
  List<SourceInfo> get enabledBuiltInSourceInfos {
    return _builtInSources.keys
        .where(isBuiltInSourceAvailable)
        .map(
          (id) => SourceInfo(
            id: id,
            name: _sourceIdToName[id] ?? id,
          ),
        )
        .toList();
  }

  Iterable<MapEntry<String, MusicSourceProvider>> get _availableBuiltInSources =>
      _builtInSources.entries.where(
        (entry) => isBuiltInSourceAvailable(entry.key),
      );

  Future<void> loadBuiltInSourceStates() async {
    if (_builtInSourceStatesLoaded) return;
    _builtInSourceStates = await _builtInSourcePreferences.load();
    _builtInSourceStatesLoaded = true;
  }

  /// 关闭/开启某个内置音源。
  Future<void> setBuiltInSourceEnabled(String sourceId, bool enabled) async {
    await loadBuiltInSourceStates();
    final disabled = <String>{..._builtInSourceStates.disabled};
    if (enabled) {
      disabled.remove(sourceId);
    } else {
      disabled.add(sourceId);
    }
    await _applyBuiltInSourceStates(
      _builtInSourceStates.copyWith(disabled: disabled),
    );
  }

  /// 「卸载」内置音源：从列表移除（可通过 [restoreBuiltInSources] 找回）。
  Future<void> removeBuiltInSource(String sourceId) async {
    await loadBuiltInSourceStates();
    final removed = <String>{..._builtInSourceStates.removed, sourceId};
    final disabled = <String>{..._builtInSourceStates.disabled}..remove(sourceId);
    await _applyBuiltInSourceStates(
      _builtInSourceStates.copyWith(removed: removed, disabled: disabled),
    );
  }

  /// 恢复所有被卸载的内置音源。
  Future<void> restoreBuiltInSources() async {
    await loadBuiltInSourceStates();
    await _applyBuiltInSourceStates(const BuiltInSourceStates());
  }

  Future<void> _applyBuiltInSourceStates(BuiltInSourceStates next) async {
    _builtInSourceStates = next;
    _builtInSourceStatesLoaded = true;
    // 音源集合变了，之前缓存的搜索结果/歌单可能包含已关闭的音源，直接丢弃。
    clearAllCaches();
    await _builtInSourcePreferences.save(next);
  }

  void dispose() {
    for (final entry in _builtInSources.entries) {
      final source = entry.value;
      try {
        if (source is NeteaseMusicSource) source.dispose();
        if (source is KugouMusicSource) source.dispose();
      } catch (_) {}
    }
    _builtInSources.clear();
  }

  MusicSourceProvider? getBuiltInSource(String sourceId) {
    return _builtInSourceFor(sourceId);
  }

  List<SourceInfo> getAvailableSources() {
    final sources = getPluginSupportedSources();
    if (sources.isEmpty) {
      return SourceInfo.builtInSources;
    }
    return sources;
  }

  /// 插件提供的音源列表（发现页 / 搜索页共用同一份 id 与名称）。
  ///
  /// * 名称取插件声明的 platform（音源平台名，例如「网易云音乐」），并
  ///   在后面附上插件名，方便区分接管同一平台的多个插件；
  /// * 同名同平台（不同作者）的插件都能显示，第二个及之后的用
  ///   `平台id@插件id` 作为唯一 id。
  List<SourceInfo> getPluginSupportedSources() {
    final sources = <SourceInfo>[];
    final seenIds = <String>{};

    for (final host in _pluginService.enabledPlugins) {
      final pluginId = _pluginService.getPluginIdForHost(host);
      final pluginName = _pluginDisplayName(host);
      for (final source in host.sources) {
        // 名称 → id 的推导与 MusicFree 适配器保持一致（见 SourceIdMapping）。
        // 注意要用插件原始的 platform 名推导，附加的插件名不能参与推导。
        final baseId = SourceIdMapping.deriveId(source.name);
        final id = _uniqueSourceId(baseId, pluginId, seenIds);
        seenIds.add(id);
        sources.add(
          SourceInfo(id: id, name: _sourceDisplayName(source.name, pluginName)),
        );
      }
    }
    return sources;
  }

  /// 插件名（用于区分接管同一平台的多个插件）。
  String _pluginDisplayName(PluginHost host) {
    final name = host.pluginInfo?.name?.trim() ?? '';
    if (name.isEmpty) return '';
    return name.length <= 12 ? name : '${name.substring(0, 12)}…';
  }

  /// 音源展示名：平台名 + 插件名。
  String _sourceDisplayName(String sourceName, String pluginName) {
    if (pluginName.isEmpty) return sourceName;
    // MusicFree 插件的插件名往往就是平台名（如「元力KW」），重复拼接没有意义。
    if (pluginName == sourceName) return sourceName;
    return '$sourceName · $pluginName';
  }

  /// 在列表里查找同 id 的音源下标。
  static int _indexOfSource(List<SourceInfo> sources, String id) {
    for (var i = 0; i < sources.length; i++) {
      if (sources[i].id == id) return i;
    }
    return -1;
  }

  /// 同名同平台（不同作者）的插件需要唯一的 id。
  static String _uniqueSourceId(
    String baseId,
    String? pluginId,
    Set<String> seenIds,
  ) {
    if (!seenIds.contains(baseId)) return baseId;
    var id =
        pluginId != null ? '$baseId@$pluginId' : '$baseId@${seenIds.length}';
    var counter = 2;
    while (seenIds.contains(id)) {
      id = '$baseId@${pluginId ?? 'plugin'}$counter';
      counter++;
    }
    return id;
  }

  List<SourceInfo> getSearchSupportedSources() {
    final sources = <SourceInfo>[];
    final seenIds = <String>{};

    // 内置音源（与发现页顺序一致：内置在前）。
    for (final entry in _availableBuiltInSources) {
      if (seenIds.add(entry.key)) {
        sources.add(
          SourceInfo(
            id: entry.key,
            name: _sourceIdToName[entry.key] ?? entry.key,
          ),
        );
      }
    }

    // 插件音源：与发现页共用同一份 id / 名称。
    for (final source in getPluginSupportedSources()) {
      final existing = _indexOfSource(sources, source.id);
      if (existing >= 0) {
        // 插件接管了同一个平台：浏览 / 搜索内容仍然来自内置源，播放地址由
        // 插件解析；列表里换成插件的条目，方便看出当前是哪个插件在服务。
        if (_pluginSourceCanResolveUrls(source.id)) {
          sources[existing] = source;
        }
        continue;
      }
      // 新平台：插件必须自己实现搜索，否则搜不出东西。
      if (!_pluginSourceSupportsSearch(source.id)) continue;
      seenIds.add(source.id);
      sources.add(source);
    }

    return sources;
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
  /// 搜索依然走内置源，播放地址由插件解析。
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
              return _defaultQualities[sourceId] ?? ['128k', '320k', 'flac'];
            }
          }
        }
      }
    }
    // 无插件时回退到内置默认
    return _defaultQualities[sourceId] ?? ['128k', '320k', 'flac'];
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
  /// 音源名规范化为内置源 id（如"酷我音乐"→kw），未声明的源沿用插件
  /// 原名作为 id；插件未声明音质时回退到该源的内置默认音质。
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
  /// 宿主不支持搜索或无结果时回退常规搜索（插件优先，再内置源）。
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

    final builtInResults = await searchBuiltIn(
      query,
      sourceId: effectiveSourceId,
      limit: limit,
    );
    if (builtInResults.isNotEmpty) return builtInResults;

    // Unknown/custom sources have no built-in adapter. Give another enabled
    // host for the same source a chance to provide provider-compatible data.
    if (!_builtInSources.containsKey(effectiveSourceId)) {
      return search(query, sourceId: effectiveSourceId, limit: limit);
    }
    return const [];
  }

  /// Search only the built-in adapter for [sourceId].
  ///
  /// Resolver-only LX plugins still require provider-specific IDs such as
  /// `songmid`, `hash`, or `copyrightId`. A result from another provider is not
  /// interchangeable even when its title and artist match, so plugin tests use
  /// this path to obtain metadata from the same provider.
  Future<List<Song>> searchBuiltIn(
    String query, {
    required String sourceId,
    int page = 1,
    int limit = 15,
  }) async {
    if (query.isEmpty) return const [];
    final effectiveSourceId = _canonicalSourceId(sourceId);
    final builtIn = _builtInSourceFor(effectiveSourceId);
    if (builtIn == null) return const [];
    try {
      return await builtIn.search(query, page: page, limit: limit);
    } catch (e) {
      print(
        '[MusicSourceManager] built-in direct search failed: '
        'source=$effectiveSourceId error=$e',
      );
      return const [];
    }
  }

  PluginHost? _findPluginForSource(String sourceId) {
    final hosts = _findPluginHostsForSource(sourceId);
    return hosts.isEmpty ? null : hosts.first;
  }

  String _canonicalSourceId(String sourceId) {
    final normalized = sourceId.trim().toLowerCase();
    if (_builtInSources.containsKey(normalized)) return normalized;

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

  List<PluginHost> _findPluginHostsForSource(String sourceId) {
    final (baseId, pluginId) = splitSourceId(sourceId);
    final hosts = <PluginHost>[];
    for (final host in _pluginService.enabledPlugins) {
      // 指定了插件（同名同平台的变体）时只使用该插件提供的音源。
      if (pluginId != null &&
          _pluginService.getPluginIdForHost(host) != pluginId) {
        continue;
      }
      if (_getSourceIdForHost(host, baseId) != null) hosts.add(host);
    }
    return hosts;
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

  /// 取内置音源；指定了插件的变体 id 时不回落内置音源。
  MusicSourceProvider? _builtInSourceFor(String sourceId) {
    final (baseId, pluginId) = splitSourceId(sourceId);
    if (pluginId != null) return null;
    return _builtInSources[baseId];
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
    if (query.isEmpty) return [];

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
              print(
                '[MusicSourceManager] 插件搜索成功: source=$sourceId, 结果长度=${resultJson.length}',
              );
              final results = _parsePluginSearchResult(
                resultJson,
                effectiveSourceId,
              );
              if (results.isNotEmpty) {
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
          }

          try {
            final resultJson = await host.searchWithHandler(
              resolvedSourceId,
              query,
              page: page,
              limit: limit,
            );
            if (resultJson != null && resultJson.isNotEmpty) {
              print(
                '[MusicSourceManager] 插件searchWithHandler成功: source=$sourceId',
              );
              final results = _parsePluginSearchResult(
                resultJson,
                effectiveSourceId,
              );
              if (results.isNotEmpty) {
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
          }
        }
      }
    }

    final builtIn = _builtInSourceFor(effectiveSourceId);
    if (builtIn != null) {
      try {
        print('[MusicSourceManager] 使用内置源搜索: source=$sourceId, query=$query');
        final results = await builtIn.search(query, page: page, limit: limit);
        print(
          '[MusicSourceManager] 内置源搜索完成: source=$sourceId, 结果数量=${results.length}',
        );
        _searchPageCache[cacheKey] = _CacheEntry(results, _searchResultsTTL);
        return results;
      } catch (e) {
        print('[MusicSourceManager] Built-in search failed for $sourceId: $e');
        return [];
      }
    }

    print('[MusicSourceManager] 没有找到可用的搜索源: $sourceId');
    return [];
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

    final builtIn = _builtInSourceFor(effectiveSourceId);
    if (builtIn != null) {
      try {
        final suggestions = await builtIn.getSearchSuggestions(query);
        if (suggestions.isNotEmpty) return suggestions;
      } catch (_) {}

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
    }

    return [];
  }

  Future<List<String>> getHotSearchTags({String sourceId = 'wy'}) async {
    // The search menu may contain a plugin's display/name ID instead of the
    // canonical built-in ID. Resolve it before looking up the built-in source
    // so hot search follows the same source mapping as search itself.
    final effectiveSourceId = _canonicalSourceId(sourceId);
    final builtIn = _builtInSourceFor(effectiveSourceId);
    if (builtIn != null) {
      try {
        final result = await builtIn.getHotSearchTags();
        print(
          '[MusicSourceManager] 热门搜索: source=$sourceId -> $effectiveSourceId, count=${result.length}',
        );
        return result;
      } catch (_) {}
    }

    // Do not show hard-coded keywords when the selected source is unavailable.
    // Returning an empty list lets the UI represent the actual source state.
    return const <String>[];
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
        return items
            .map((item) => _musicInfoToSong(item, baseSourceId))
            .toList();
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
    if (info['artwork'] != null) {
      // MusicFree 插件的封面字段是 artwork。
      coverUrl = info['artwork'].toString();
    } else if (info['picUrl'] != null) {
      coverUrl = info['picUrl'].toString();
    } else if (info['pic'] != null) {
      coverUrl = info['pic'].toString();
    } else if (info['cover'] != null) {
      coverUrl = info['cover'].toString();
    } else if (info['img'] != null) {
      coverUrl = info['img'].toString();
    } else if (info['albumImg'] != null) {
      coverUrl = info['albumImg'].toString();
    } else if (info['album'] != null && info['album'] is Map) {
      final album = info['album'] as Map;
      if (album['picUrl'] != null) {
        coverUrl = album['picUrl'].toString();
      } else if (album['pic'] != null) {
        coverUrl = album['pic'].toString();
      } else if (album['artwork'] != null) {
        coverUrl = album['artwork'].toString();
      }
    } else if (info['al'] != null && info['al'] is Map) {
      final al = info['al'] as Map;
      if (al['picUrl'] != null) {
        coverUrl = al['picUrl'].toString();
      } else if (al['artwork'] != null) {
        coverUrl = al['artwork'].toString();
      }
    } else if (info['pic_id'] != null) {
      final picId = info['pic_id'].toString();
      if (sourceId == 'wy') {
        coverUrl = 'https://p3.music.126.net/$picId/${picId}_300x300.jpg';
      }
    } else if (info['img3'] != null) {
      coverUrl = info['img3'].toString();
      if (!coverUrl.startsWith('http')) {
        coverUrl = 'http://d.musicapp.migu.cn$coverUrl';
      }
    } else if (info['img2'] != null) {
      coverUrl = info['img2'].toString();
      if (!coverUrl.startsWith('http')) {
        coverUrl = 'http://d.musicapp.migu.cn$coverUrl';
      }
    } else if (info['img1'] != null) {
      coverUrl = info['img1'].toString();
      if (!coverUrl.startsWith('http')) {
        coverUrl = 'http://d.musicapp.migu.cn$coverUrl';
      }
    } else if (info['songmid'] != null && sourceId == 'kw') {
      final songmid = info['songmid'].toString();
      coverUrl =
          'http://artistpicserver.kuwo.cn/pic.web?corp=kuwo&type=rid_pic&pictype=500&size=500&rid=$songmid';
    }

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
      lx: lxMeta,
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
    Set<String> excludedUrls = const <String>{},
  }) async {
    if (song.source == null || song.source == 'local') return song;
    final result = await getMusicUrlResult(song, excludedUrls: excludedUrls);
    if (result != null && result.url.isNotEmpty) {
      return _applyMusicUrlResult(song, result);
    }
    return song;
  }

  Song _applyMusicUrlResult(Song song, PluginMusicUrlResult result) {
    return song.copyWith(
      sourceUrl: result.url,
      sourceHeaders: result.headers.isEmpty ? null : result.headers,
      sourceQuality: result.quality.isEmpty ? null : result.quality,
      clearSourceHeaders: result.headers.isEmpty,
      clearSourceQuality: result.quality.isEmpty,
    );
  }

  List<String> _qualityFallbackChain(
    String requested, {
    List<String>? supported,
  }) {
    const order = <String>[
      '128k',
      '192k',
      '320k',
      'flac',
      'flac24bit',
      'hires',
      'atmos',
      'master',
      '24bit',
    ];
    final allowed = supported == null || supported.isEmpty
        ? order.toSet()
        : supported.toSet();
    final result = <String>[];

    void add(String value) {
      if (allowed.contains(value) && !result.contains(value)) {
        result.add(value);
      }
    }

    add(requested);
    final index = order.indexOf(requested);
    if (index >= 0) {
      for (var i = index - 1; i >= 0; i--) {
        add(order[i]);
      }
    }
    if (index < 0) {
      add('320k');
      add('128k');
    }
    return result.isEmpty ? <String>[requested] : result;
  }

  List<String> _getPluginQualities(PluginHost host, String sourceId) {
    for (final source in host.sources) {
      final effectiveId = SourceIdMapping.deriveId(source.name);
      if (effectiveId == sourceId && source.qualities.isNotEmpty) {
        return source.qualities;
      }
    }
    return const <String>[];
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
  /// 播放链接由插件解析，其它内置源负责搜索等元数据。
  /// [pluginHosts] 供插件测试传入被测宿主（隔离或共享），缺省时使用当前
  /// 已启用的插件宿主，保证测试结果与实际播放一致。
  Future<List<PluginMusicUrlResult>> getMusicUrlResultCandidates(
    Song song, {
    String quality = '320k',
    Set<String> excludedUrls = const <String>{},
    bool includeQualityFallbacks = false,
    List<PluginHost>? pluginHosts,
  }) async {
    final sourceId = song.source;
    if (sourceId == null) return const <PluginMusicUrlResult>[];

    final musicInfo = _buildPluginMusicInfo(song, sourceId);
    final results = <PluginMusicUrlResult>[];

    // An enabled LX plugin is the authoritative resolver because it receives
    // the provider-specific song metadata and requested quality. In
    // particular, Kuwo's legacy endpoint can return HTTP 200 for its
    // free-listening permission prompt instead of the requested song.
    final hosts = pluginHosts ?? _findPluginHostsForSource(sourceId);
    for (final host in hosts) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId == null) continue;

      final qualities = includeQualityFallbacks
          ? _qualityFallbackChain(
              quality,
              supported: _getPluginQualities(host, pluginSourceId),
            )
          : <String>[quality];
      for (final candidateQuality in qualities) {
        try {
          final result = await host.getMusicUrlResult(
            pluginSourceId,
            musicInfo,
            candidateQuality,
          );
          final url = result.url.trim();
          final normalized = PluginMusicUrlResult(
            url: url,
            quality: result.quality.isEmpty ? candidateQuality : result.quality,
            headers: result.headers,
          );
          print(
            '[MusicSourceManager] LX URL candidate: source=$sourceId '
            'requested=$quality quality=$candidateQuality '
            'resolved=${normalized.quality} host=${_urlHost(url)}',
          );
          // 拒绝酷我提示音 / 加密格式 URL
          if (sourceId == 'kw' && _isKuwoPromptUrl(url)) {
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
            'source=$sourceId quality=$candidateQuality error=$e',
          );
        }
      }
    }

    return results;
  }

  /// Quality order used after the current quality is rejected by the real
  /// audio player. The initial URL lookup intentionally does not use this.
  List<String> getMusicQualityFallbacks(Song song, String requested) {
    final sourceId = song.source;
    if (sourceId == null || sourceId == 'local') return <String>[requested];

    final host = _findPluginForSource(sourceId);
    final pluginSourceId = host == null
        ? null
        : _getSourceIdForHost(host, sourceId);
    final builtInQualities = _defaultQualities[sourceId];
    return _qualityFallbackChain(
      requested,
      supported: host == null || pluginSourceId == null
          ? builtInQualities
          : _getPluginQualities(host, pluginSourceId),
    );
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
  }) async {
    final candidates = await getMusicUrlResultCandidates(
      song,
      quality: quality,
      excludedUrls: excludedUrls,
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
    final cleanId = _stripSourcePrefix(song.id, sourceId);
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
        (sourceId == 'tx' ? song.lyricUrl : null);
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
      copyrightId: readString(['copyrightId']) ??
          // 咪咕的 copyrightId 就是歌曲 id（内置源搜索结果里没有 lx 元数据）。
          (sourceId == 'mg' ? cleanId : null),
      source: sourceId,
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
    final sourceId = song.source;
    if (sourceId == null) {
      print('[MusicSourceManager] getLyric: source is null');
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

    final builtIn = _builtInSourceFor(sourceId);
    print(
      '[MusicSourceManager] getLyric: using built-in source: ${builtIn != null}',
    );
    if (builtIn != null) {
      try {
        print('[MusicSourceManager] getLyric: calling built-in getLyric');
        final result = await builtIn.getLyric(song.id);
        print(
          '[MusicSourceManager] getLyric: built-in result: ${result != null ? "has ${result.length} chars" : "null"}',
        );
        return result;
      } catch (e) {
        print('[MusicSourceManager] getLyric: built-in error: $e');
      }
    }

    print('[MusicSourceManager] getLyric: no source available');
    return null;
  }

  Future<LyricResult?> getLyricResult(Song song) async {
    final sourceId = song.source;
    if (sourceId == null) return null;

    final builtIn = _builtInSourceFor(sourceId);
    LyricResult? pluginFallback;
    LyricResult? builtInFallback;

    // 0. 对齐 CeruMusic：插件优先于内建源
    final host = _findPluginForSource(sourceId);
    if (host != null) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId != null) {
        final musicInfo = _buildPluginMusicInfo(song, sourceId);
        try {
          final result = await host.getLyricResult(pluginSourceId, musicInfo);
          if (_hasWordLyric(result)) return result;
          if (_hasLyric(result)) {
            // 对于所有源，如果有逐字歌词的可能，继续尝试内建源
            // 只有 TX 源需要特殊处理 numeric ID
            pluginFallback = result;
          }
        } catch (e) {
          print('[MusicSourceManager] getLyricResult: plugin error: $e');
        }
      }
    }

    // 1. 内建源（可能有 crlyric 逐字歌词）
    if (builtIn != null) {
      try {
        final result = await builtIn.getLyricResult(song.id);
        if (_hasWordLyric(result)) return result;
        if (_hasLyric(result)) builtInFallback = result;

        // tx 单独处理 numeric ID
        if (sourceId == 'tx' && song.lyricUrl?.trim().isNotEmpty == true) {
          final numericResult = await builtIn.getLyricResult(
            'tx_${song.lyricUrl}',
          );
          if (_hasWordLyric(numericResult)) return numericResult;
          if (builtInFallback == null && _hasLyric(numericResult)) {
            builtInFallback = numericResult;
          }
        }
      } catch (e) {
        print(
          '[MusicSourceManager] getLyricResult: $sourceId built-in error: $e',
        );
      }
    }

    // 2. 原生 fallback
    if (pluginFallback != null) return pluginFallback;
    if (builtInFallback != null) return builtInFallback;

    // 3. 纯文本回退
    final rawLyric = await getLyric(song);
    if (rawLyric == null || rawLyric.isEmpty) return null;
    return LyricResult(lrc: rawLyric);
  }

  bool _hasLyric(LyricResult? result) {
    return (result?.lrc?.trim().isNotEmpty ?? false) ||
        (result?.crlyric?.trim().isNotEmpty ?? false);
  }

  bool _hasWordLyric(LyricResult? result) {
    return result?.crlyric?.trim().isNotEmpty ?? false;
  }

  /// Promotes a Kuwo search thumbnail to its original-artwork CDN variant.
  ///
  /// This is synchronous so playback can display the sharp cover immediately,
  /// rather than waiting until audio URL resolution has completed.
  String? getHighResolutionCoverUrl(Song song) {
    if (song.source != 'kw') return null;
    final raw = song.coverUrl?.trim() ?? '';
    if (raw.isEmpty) return null;
    final match = RegExp(r'/(albumcover|starheads)/(\d+)/').firstMatch(raw);
    if (match == null) return null;
    if (match.group(2) == '1500') return raw;
    return raw.replaceFirstMapped(
      RegExp(r'/(albumcover|starheads)/\d+/'),
      (match) => '/${match.group(1)}/1500/',
    );
  }

  Future<String?> getPic(
    Song song, {
    Set<String> excludedUrls = const <String>{},
    bool preferBuiltIn = false,
    bool bypassCache = false,
  }) async {
    final sourceId = song.source;
    if (sourceId == null) return null;

    final cacheKey = '$sourceId:${song.id}';
    final cached = _coverCache[cacheKey];
    if (!bypassCache &&
        cached != null &&
        cached.isValid &&
        (cached.data == null || !excludedUrls.contains(cached.data))) {
      return cached.data;
    }

    String? result;

    Future<String?> resolveBuiltIn() async {
      final builtIn = _builtInSourceFor(sourceId);
      if (builtIn == null) return null;
      try {
        final cover = await builtIn.getCoverUrl(song.id);
        if (cover != null &&
            cover.isNotEmpty &&
            !excludedUrls.contains(cover)) {
          _coverCache[cacheKey] = _CacheEntry(cover, _searchResultsTTL);
          return cover;
        }
      } catch (_) {}
      return null;
    }

    // Built-in search results and an imported LX plugin may share the `kw`
    // source ID, but their song IDs are not interchangeable. Use Kuwo's own
    // cover resolver first for built-in Kuwo playback.
    if (preferBuiltIn || sourceId == 'kw') {
      final existingKuwoCover = getHighResolutionCoverUrl(song);
      if (existingKuwoCover != null &&
          !excludedUrls.contains(existingKuwoCover)) {
        _coverCache[cacheKey] = _CacheEntry(
          existingKuwoCover,
          _searchResultsTTL,
        );
        return existingKuwoCover;
      }
      final cover = await resolveBuiltIn();
      if (cover != null) return cover;
    }

    final host = _findPluginForSource(sourceId);
    if (host != null) {
      final pluginSourceId = _getSourceIdForHost(host, sourceId);
      if (pluginSourceId != null) {
        final musicInfo = _buildPluginMusicInfo(song, sourceId);
        try {
          result = await host.getPic(pluginSourceId, musicInfo);
          if (result != null &&
              result.isNotEmpty &&
              !excludedUrls.contains(result)) {
            _coverCache[cacheKey] = _CacheEntry(result, _searchResultsTTL);
            return result;
          }
        } catch (_) {}
      }
    }

    if (!preferBuiltIn && sourceId != 'kw') {
      final cover = await resolveBuiltIn();
      if (cover != null) return cover;
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
  PluginHost? _findDiscoverHost(
    String sourceId, {
    bool needTopList = false,
    bool needSheets = false,
    bool needSheetDetail = false,
  }) {
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
      final group = _nonEmptyText(entry['group']);
      boards.add(
        Leaderboard(
          id: pluginBoardId(sourceId, rawId),
          name: (group == null || group == name) ? name : '$group · $name',
          coverUrl: _nonEmptyText(entry['coverUrl']),
          source: sourceId,
        ),
      );
    }
    return boards;
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
      if (raw == null) return const PlaylistPage();

      final decoded = _decodePluginJson(raw);
      final songs = _parsePluginSearchResult(raw, sourceId);
      final sheetValue = decoded is Map ? decoded['sheet'] : null;
      final meta = sheetValue is Map ? sheetValue : const <String, dynamic>{};
      // 插件通过 isEnd 告知是否还有下一页；字段缺失时按「已到末页」处理，
      // 避免未知插件被无限翻页。
      final isEnd = decoded is Map ? decoded['isEnd'] == true : true;

      return PlaylistPage(
        playlist: Playlist(
          id: appId,
          title: _nonEmptyText(meta['title']) ?? '',
          description: _nonEmptyText(meta['description']) ?? '',
          coverUrl: _nonEmptyText(meta['coverUrl']),
          songCount: songs.length,
          songs: songs,
          author: _nonEmptyText(meta['author']),
          source: sourceId,
        ),
        isEnd: isEnd,
      );
    } catch (e) {
      print('[MusicSourceManager] 插件发现详情获取失败 id=$appId: $e');
      return const PlaylistPage();
    }
  }

  Future<List<Playlist>> getHotPlaylists({String sourceId = 'wy'}) async {
    final cached = _hotPlaylistsCache[sourceId];
    if (cached != null && cached.isValid) {
      print('[MusicSourceManager] 热门歌单缓存命中: $sourceId');
      return cached.data;
    }

    final builtIn = _builtInSourceFor(sourceId);
    if (builtIn != null && isBuiltInSourceAvailable(sourceId)) {
      try {
        final hot = await builtIn.getHotPlaylists();
        if (hot.isNotEmpty) {
          _hotPlaylistsCache[sourceId] = _CacheEntry(hot, _hotPlaylistsTTL);
          return hot;
        }
      } catch (e) {
        print('[MusicSourceManager] getHotPlaylists failed for $sourceId: $e');
      }

      try {
        final categoryHot = await builtIn.getCategoryPlaylists(
          sortId: 'hot',
          tagId: '',
          page: 1,
          limit: 30,
        );
        if (categoryHot.isNotEmpty) {
          _hotPlaylistsCache[sourceId] = _CacheEntry(
            categoryHot,
            _hotPlaylistsTTL,
          );
          return categoryHot;
        }
      } catch (e) {
        print('[MusicSourceManager] 热门歌单分类兜底失败 source=$sourceId: $e');
      }

      try {
        final tags = await builtIn.getHotPlaylistTags();
        for (final tag in tags.take(3)) {
          final tagged = await builtIn.getCategoryPlaylists(
            sortId: 'hot',
            tagId: tag.id,
            page: 1,
            limit: 30,
          );
          if (tagged.isNotEmpty) {
            _hotPlaylistsCache[sourceId] = _CacheEntry(
              tagged,
              _hotPlaylistsTTL,
            );
            return tagged;
          }
        }
      } catch (e) {
        print('[MusicSourceManager] 热门歌单标签兜底失败 source=$sourceId: $e');
      }
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
    final builtIn = _builtInSourceFor(sourceId);
    if (builtIn != null && isBuiltInSourceAvailable(sourceId)) {
      try {
        return await builtIn.getPlaylistTags();
      } catch (e) {
        print('[MusicSourceManager] getPlaylistTags failed for $sourceId: $e');
        return [];
      }
    }

    final host = _findDiscoverHost(sourceId, needSheets: true);
    if (host != null) {
      try {
        return _pluginTagGroupsFromJson(
          sourceId,
          _decodePluginJson(await host.getRecommendSheetTags()),
        );
      } catch (e) {
        print('[MusicSourceManager] 插件歌单分类获取失败 source=$sourceId: $e');
      }
    }
    return [];
  }

  Future<List<PlaylistTag>> getHotPlaylistTags({String sourceId = 'wy'}) async {
    final builtIn = _builtInSourceFor(sourceId);
    if (builtIn != null && isBuiltInSourceAvailable(sourceId)) {
      try {
        return await builtIn.getHotPlaylistTags();
      } catch (e) {
        print(
          '[MusicSourceManager] getHotPlaylistTags failed for $sourceId: $e',
        );
        return [];
      }
    }

    // 插件音源没有单独的「热门标签」接口，取推荐分类里的前几个当作标签栏。
    final groups = await getPlaylistTags(sourceId: sourceId);
    return groups.expand((group) => group.tags).take(8).toList();
  }

  Future<List<Playlist>> getCategoryPlaylists({
    required String sortId,
    required String tagId,
    required int page,
    required int limit,
    String sourceId = 'wy',
  }) async {
    final builtIn = _builtInSourceFor(sourceId);
    if (builtIn != null && isBuiltInSourceAvailable(sourceId)) {
      try {
        final playlists = await builtIn.getCategoryPlaylists(
          sortId: sortId,
          tagId: tagId,
          page: page,
          limit: limit,
        );
        if (playlists.isNotEmpty) return playlists;
      } catch (e) {
        print(
          '[MusicSourceManager] getCategoryPlaylists failed for $sourceId: $e',
        );
      }

      if (page == 1 && tagId.isEmpty && sortId == 'hot') {
        try {
          final hot = await builtIn.getHotPlaylists();
          if (hot.isNotEmpty) return hot.take(limit).toList();
        } catch (e) {
          print('[MusicSourceManager] 分类热门歌单直接兜底失败 source=$sourceId: $e');
        }

        try {
          final tags = await builtIn.getHotPlaylistTags();
          for (final tag in tags.take(3)) {
            final tagged = await builtIn.getCategoryPlaylists(
              sortId: sortId,
              tagId: tag.id,
              page: page,
              limit: limit,
            );
            if (tagged.isNotEmpty) return tagged;
          }
        } catch (e) {
          print('[MusicSourceManager] 分类热门歌单标签兜底失败 source=$sourceId: $e');
        }
      }
    }

    // 插件（MusicFree）音源：按推荐歌单分类取歌单。
    final host = _findDiscoverHost(sourceId, needSheets: true);
    if (host != null) {
      try {
        final playlists = _pluginPlaylistsFromJson(
          sourceId,
          _decodePluginJson(
            await host.getRecommendSheetsByTag(tagId, page: page),
          ),
        );
        if (playlists.isNotEmpty) {
          return playlists.length > limit
              ? playlists.take(limit).toList()
              : playlists;
        }
      } catch (e) {
        print('[MusicSourceManager] 插件分类歌单获取失败 source=$sourceId: $e');
      }
    }
    return [];
  }

  Future<List<Leaderboard>> getLeaderboards({String sourceId = 'wy'}) async {
    final builtIn = _builtInSourceFor(sourceId);
    if (builtIn != null && isBuiltInSourceAvailable(sourceId)) {
      try {
        return await builtIn.getLeaderboards();
      } catch (e) {
        print('[MusicSourceManager] getLeaderboards failed for $sourceId: $e');
        return [];
      }
    }

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
  ///   `getMusicSheetInfo` / `getTopListDetail`，由插件的 `isEnd` 决定是否到底；
  /// - 内置源：一次性返回全量歌曲（`isEnd == true`），不参与翻页。
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

    String actualSourceId = sourceId;

    if (playlistId.startsWith('wy_')) {
      actualSourceId = 'wy';
    } else if (playlistId.startsWith('kg_')) {
      actualSourceId = 'kg';
    } else if (playlistId.startsWith('kw_')) {
      actualSourceId = 'kw';
    } else if (playlistId.startsWith('tx_')) {
      actualSourceId = 'tx';
    } else if (playlistId.startsWith('mg_')) {
      actualSourceId = 'mg';
    }

    print(
      '[MusicSourceManager] getPlaylistDetail: playlistId=$playlistId, sourceId=$sourceId, actualSourceId=$actualSourceId',
    );

    Playlist? result;
    final builtIn = _builtInSourceFor(actualSourceId);
    if (builtIn != null) {
      try {
        result = await builtIn.getPlaylistDetail(playlistId);
        if (result != null && result.songs.isNotEmpty) {
          print(
            '[MusicSourceManager] getPlaylistDetail success: ${result.songs.length} songs',
          );
          _playlistDetailCache[playlistId] = _CacheEntry(
            result,
            _playlistDetailTTL,
          );
          return result;
        }

        if (actualSourceId != 'wy') {
          final boardResult = await builtIn.getLeaderboardDetail(playlistId);
          if (boardResult != null && boardResult.songs.isNotEmpty) {
            print(
              '[MusicSourceManager] getPlaylistDetail fallback leaderboard success: ${boardResult.songs.length} songs',
            );
            _playlistDetailCache[playlistId] = _CacheEntry(
              boardResult,
              _playlistDetailTTL,
            );
            return boardResult;
          }
        }

        if (result != null) {
          print(
            '[MusicSourceManager] getPlaylistDetail returned empty playlist for $actualSourceId',
          );
          _playlistDetailCache[playlistId] = _CacheEntry(
            result,
            _playlistDetailTTL,
          );
          return result;
        } else {
          print(
            '[MusicSourceManager] getPlaylistDetail returned null for $actualSourceId',
          );
        }
        return null;
      } catch (e) {
        print(
          '[MusicSourceManager] getPlaylistDetail failed for $actualSourceId: $e',
        );
        return null;
      }
    }
    print('[MusicSourceManager] no built-in source found for $actualSourceId');
    return null;
  }

  Future<Playlist?> getLeaderboardDetail(
    String boardId, {
    int page = 1,
    String sourceId = 'wy',
  }) async {
    final builtIn = _builtInSourceFor(sourceId);
    if (builtIn != null && isBuiltInSourceAvailable(sourceId)) {
      try {
        return await builtIn.getLeaderboardDetail(boardId, page: page);
      } catch (e) {
        print(
          '[MusicSourceManager] getLeaderboardDetail failed for $sourceId: $e',
        );
        return null;
      }
    }

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

  List<SourceInfo> getDiscoverSupportedSources() {
    final sources = <SourceInfo>[];
    final seenIds = <String>{};

    for (final source in enabledBuiltInSourceInfos) {
      if (seenIds.add(source.id)) sources.add(source);
    }

    // 插件音源：复用搜索音源列表的 id 推导（与适配器保持一致）。
    for (final source in getPluginSupportedSources()) {
      final existing = _indexOfSource(sources, source.id);
      if (existing >= 0) {
        // 插件接管了同一个平台：浏览内容仍然来自内置源，播放地址由插件
        // 解析；列表里换成插件的条目，方便看出当前是哪个插件在服务。
        if (_pluginSourceCanResolveUrls(source.id)) {
          sources[existing] = source;
        }
        continue;
      }
      // 新平台：只有实现了榜单 / 推荐歌单的插件才有浏览内容，没有浏览
      // 接口的音源出现在这里只会是空页面。
      if (_findDiscoverHost(source.id) == null) continue;
      seenIds.add(source.id);
      sources.add(source);
    }

    return sources;
  }

  /// 搜索歌单：通过各内置源的 searchPlaylist API 获取真实的歌单搜索结果。
  ///
  /// 聚合模式（sourceId == 'all'）会并发请求所有内置源，去重后返回；
  /// 指定源时只请求对应源。
  Future<List<Playlist>> searchPlaylists(
    String query, {
    String sourceId = 'all',
    int limit = 30,
  }) async {
    if (query.isEmpty) return [];

    final results = <Playlist>[];
    final seenIds = <String>{};

    void addUnique(Playlist playlist) {
      if (!seenIds.contains(playlist.id)) {
        seenIds.add(playlist.id);
        results.add(playlist);
      }
    }

    if (sourceId == 'all') {
      // 并发搜索所有「仍启用」的内置源
      final futures = _availableBuiltInSources.map((entry) async {
        try {
          final playlists = await entry.value
              .searchPlaylists(query, limit: limit)
              .timeout(_perSourceTimeout);
          return playlists;
        } catch (_) {
          return <Playlist>[];
        }
      });
      final allResults = await Future.wait(futures);
      for (final sourceResults in allResults) {
        for (final p in sourceResults) {
          addUnique(p);
        }
      }
    } else {
      // 搜索指定源
      final effectiveSourceId = _canonicalSourceId(sourceId);
      final builtIn = _builtInSourceFor(effectiveSourceId);
      if (builtIn != null) {
        try {
          final playlists = await builtIn
              .searchPlaylists(query, limit: limit)
              .timeout(_perSourceTimeout);
          for (final p in playlists) {
            addUnique(p);
          }
        } catch (_) {}
      }
    }

    return results.take(limit).toList();
  }
}
