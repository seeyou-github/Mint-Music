
import '../../../core/storage/app_preferences.dart';
import '../domain/builtin_source_states.dart';

/// 内置音源启用/卸载状态的持久化。
class BuiltInSourcePreferences {
  static const String _disabledKey = 'disabled_builtin_sources';
  static const String _removedKey = 'removed_builtin_sources';

  Future<BuiltInSourceStates> load() async {
    final prefs = await AppPreferences.getInstance();
    return BuiltInSourceStates(
      disabled: (prefs.getStringList(_disabledKey) ?? const <String>[]).toSet(),
      removed: (prefs.getStringList(_removedKey) ?? const <String>[]).toSet(),
    );
  }

  Future<void> save(BuiltInSourceStates states) async {
    final prefs = await AppPreferences.getInstance();
    await prefs.setStringList(_disabledKey, states.disabled.toList());
    await prefs.setStringList(_removedKey, states.removed.toList());
  }
}
