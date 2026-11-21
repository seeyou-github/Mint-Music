import 'dart:convert';

/// 订阅清单里的一个插件条目。
class PluginSubscriptionEntry {
  const PluginSubscriptionEntry({
    required this.name,
    required this.url,
    this.version,
  });

  /// 清单里写的名字（只用于提示，真正的插件名由脚本自己声明）。
  final String name;

  /// 插件 js 的下载地址。
  final String url;

  /// 清单里写的版本号（可能为空）。
  final String? version;

  @override
  String toString() => version == null ? name : '$name v$version';
}

/// 解析 MusicFree 的「插件订阅清单」。
///
/// 典型内容长这样（仓库里的 `main.json`）：
/// ```json
/// {
///   "desc": "常用六平台",
///   "plugins": [
///     {"name": "QQ音乐", "url": "https://.../qq-source.plugin.v1.9.26.js", "version": "1.9.26"}
///   ]
/// }
/// ```
/// 有人贴这种地址时，里面并不是插件代码，直接当插件装会报「格式校验失败」。
/// 返回 null 表示这段内容**不是**清单（可能是插件 js，或别的 JSON）。
///
/// 兼容的写法：
/// - 顶层键 `plugins` / `data` / `list` 是数组；
/// - 顶层直接是数组；
/// - 条目里的地址字段 `url` / `srcUrl` / `scriptUrl` / `link`；
/// - 只接受 `http(s)` 绝对地址，相对地址直接跳过（没法确定 base）。
List<PluginSubscriptionEntry>? parsePluginSubscription(String content) {
  final text = content.trim();
  if (text.isEmpty) return null;
  // 只可能是 JSON 的两种开头，先挡掉插件 js，避免每条都去 jsonDecode。
  if (!text.startsWith('{') && !text.startsWith('[')) return null;

  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } catch (_) {
    return null;
  }

  if (decoded is List) return _entriesOf(decoded);
  if (decoded is! Map) return null;

  for (final key in const ['plugins', 'data', 'list']) {
    final value = decoded[key];
    if (value is List) return _entriesOf(value);
  }
  return null;
}

/// 一个插件地址下载完成后的结果：单个插件代码，或一份订阅清单。
class PluginDownloadTarget {
  const PluginDownloadTarget.single({
    required String this.code,
    required String this.url,
  }) : entries = null;

  const PluginDownloadTarget.subscription(
    List<PluginSubscriptionEntry> this.entries,
  ) : code = null,
      url = null;

  /// 单个插件的代码（是清单时为 null）。
  final String? code;

  /// 单个插件的来源地址（记进插件的更新地址）。
  final String? url;

  /// 订阅清单里的条目（单个插件时为 null）。
  final List<PluginSubscriptionEntry>? entries;

  bool get isSubscription => entries != null;

  List<PluginSubscriptionEntry> get pluginEntries =>
      entries ?? const <PluginSubscriptionEntry>[];
}

List<PluginSubscriptionEntry>? _entriesOf(List list) {
  final entries = <PluginSubscriptionEntry>[];
  for (final item in list) {
    if (item is! Map) continue;
    final url = _firstHttpUrl(item);
    if (url == null) continue;
    entries.add(
      PluginSubscriptionEntry(
        name: _firstString(item, const ['name', 'title', 'desc']) ?? '',
        url: url,
        version: _firstString(item, const ['version']),
      ),
    );
  }
  return entries.isEmpty ? null : entries;
}

String? _firstHttpUrl(Map item) {
  for (final key in const ['url', 'srcUrl', 'scriptUrl', 'link']) {
    final value = item[key];
    if (value is! String) continue;
    final url = value.trim();
    if (url.startsWith('http://') || url.startsWith('https://')) return url;
  }
  return null;
}

String? _firstString(Map item, List<String> keys) {
  for (final key in keys) {
    final value = item[key];
    if (value is String && value.trim().isNotEmpty) return value.trim();
  }
  return null;
}
