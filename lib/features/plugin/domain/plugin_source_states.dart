/// 插件自带音源的启用/关闭状态。
///
/// 一个插件文件可能同时提供多个音源（例如落雪脚本会同时提供网易 / QQ /
/// 酷狗 / 酷我 / 咪咕 / 汽水），用户可以逐个开关，只保留需要的音源。
///
/// 关闭某个音源后：
/// * 该音源不再出现在发现页 / 搜索页的音源切换列表里；
/// * 插件不再为该平台解析播放地址（没有其它可用音源时播放会失败）。
class PluginSourceStates {
  const PluginSourceStates({this.disabled = const <String>{}});

  /// 被关闭的音源，键为 `插件id:音源id`。
  final Set<String> disabled;

  /// 组合键。
  static String key(String pluginId, String sourceId) => '$pluginId:$sourceId';

  /// 指定插件的指定音源是否启用。
  bool isEnabled(String pluginId, String sourceId) {
    return !disabled.contains(key(pluginId, sourceId));
  }

  PluginSourceStates copyWith({Set<String>? disabled}) {
    return PluginSourceStates(disabled: disabled ?? this.disabled);
  }
}
