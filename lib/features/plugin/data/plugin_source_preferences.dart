import 'package:shared_preferences/shared_preferences.dart';

import '../domain/plugin_source_states.dart';

/// 插件自带音源启用状态的持久化。
class PluginSourcePreferences {
  static const String _disabledKey = 'disabled_plugin_sources';

  Future<PluginSourceStates> load() async {
    final prefs = await SharedPreferences.getInstance();
    return PluginSourceStates(
      disabled: (prefs.getStringList(_disabledKey) ?? const <String>[]).toSet(),
    );
  }

  Future<void> save(PluginSourceStates states) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_disabledKey, states.disabled.toList());
  }
}
