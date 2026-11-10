import 'dart:async';
import 'dart:io';

import '../../../core/platform/app_paths.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../../../core/platform/download_paths.dart';
import '../../../core/theme/theme_provider.dart';
import '../../../shared/services/cache_paths.dart';

class SettingsService {
  final AppPreferences _prefs;

  SettingsService(this._prefs);

  // -- theme --
  String getThemeMode() => _prefs.getString('theme_mode') ?? 'system';
  Future<void> setThemeMode(String v) => _prefs.setString('theme_mode', v);
  /// 旧版本的内置默认主题色（Spotify 绿）。
  static const String _legacyDefaultPrimaryColor = '#1DB954';

  /// 主题色：没保存过用默认的暖金。
  ///
  /// 早期版本的默认是 Spotify 绿，没改过主题色的用户（配置里还是这个值）
  /// 跟着新默认换成暖金；自己选过的颜色不受影响。
  String getThemePrimaryColor() {
    final saved = _prefs.getString('theme_primary_color');
    if (saved == null) return defaultThemePrimaryColor;
    if (saved.trim().toUpperCase() == _legacyDefaultPrimaryColor) {
      return defaultThemePrimaryColor;
    }
    return saved;
  }
  Future<void> setThemePrimaryColor(String v) =>
      _prefs.setString('theme_primary_color', v);

  // -- theme font colors（浅色 / 深色各一套） --
  static const _fontColorLightKey = 'theme_font_color_light';
  static const _fontColorDarkKey = 'theme_font_color_dark';
  static const _secondaryFontColorLightKey = 'theme_secondary_font_color_light';
  static const _secondaryFontColorDarkKey = 'theme_secondary_font_color_dark';

  /// 旧版本深浅色共用的键，只用于迁移读取。
  static const _legacyFontColorKey = 'theme_font_color';
  static const _legacySecondaryFontColorKey = 'theme_secondary_font_color';

  /// 浅色模式「字体颜色」。
  ///
  /// 未设置过时沿用旧版的值；旧版默认的暖米色是给深色主题用的，浅色模式
  /// 使用 [defaultLightFontColor]。
  String getThemeFontColorLight() {
    final value = _prefs.getString(_fontColorLightKey);
    if (value != null) return value;
    final legacy = _prefs.getString(_legacyFontColorKey);
    if (legacy == null) return defaultLightFontColor;
    if (legacy.toUpperCase() == defaultThemeFontColor.toUpperCase()) {
      return defaultLightFontColor;
    }
    return legacy;
  }

  Future<void> setThemeFontColorLight(String v) =>
      _prefs.setString(_fontColorLightKey, v);

  /// 深色模式「字体颜色」：为空表示使用主题默认色。
  String getThemeFontColorDark() =>
      _prefs.getString(_fontColorDarkKey) ??
      _prefs.getString(_legacyFontColorKey) ??
      defaultThemeFontColor;

  Future<void> setThemeFontColorDark(String v) =>
      _prefs.setString(_fontColorDarkKey, v);

  /// 浅色模式「第二字体颜色」：默认使用主题自带的次级文字色。
  String getThemeSecondaryFontColorLight() =>
      _prefs.getString(_secondaryFontColorLightKey) ??
      _prefs.getString(_legacySecondaryFontColorKey) ??
      defaultLightSecondaryFontColor;

  Future<void> setThemeSecondaryFontColorLight(String v) =>
      _prefs.setString(_secondaryFontColorLightKey, v);

  /// 深色模式「第二字体颜色」：默认使用 [defaultDarkSecondaryFontColor]。
  String getThemeSecondaryFontColorDark() =>
      _prefs.getString(_secondaryFontColorDarkKey) ??
      _prefs.getString(_legacySecondaryFontColorKey) ??
      defaultDarkSecondaryFontColor;

  Future<void> setThemeSecondaryFontColorDark(String v) =>
      _prefs.setString(_secondaryFontColorDarkKey, v);

  // -- theme background colors（浅色 / 深色各一套） --
  static const _backgroundColorLightKey = 'theme_background_color_light';
  static const _backgroundColorDarkKey = 'theme_background_color_dark';
  static const _backgroundColorListLightKey = 'theme_background_colors_light';
  static const _backgroundColorListDarkKey = 'theme_background_colors_dark';

  // 旧的单色键（theme_background_color_light/dark）只用于迁移：
  // 新用户直接写 theme_background_colors_*，见下面两个方法。

  /// 浅色模式「背景渐变」：从顶到底 1~3 个颜色。
  ///
  /// 旧版本只存了一个 `theme_background_color_light`，没写过新键时按单色列表
  /// 兼容，升级后背景不会跳回默认；两个键都没有时用内置渐变的第一个
  /// （见 [defaultLightBackgroundGradient]）。
  List<String> getThemeBackgroundColorsLight() {
    final list = _getColorList(_backgroundColorListLightKey);
    if (list.isNotEmpty) return list;
    final legacy = _prefs.getString(_backgroundColorLightKey);
    return (legacy == null || legacy.trim().isEmpty)
        ? defaultLightBackgroundGradient
        : [legacy];
  }

  Future<void> setThemeBackgroundColorsLight(List<String> values) =>
      _prefs.setStringList(_backgroundColorListLightKey, values);

  /// 深色模式「背景渐变」：从顶到底 1~3 个颜色。
  List<String> getThemeBackgroundColorsDark() {
    final list = _getColorList(_backgroundColorListDarkKey);
    if (list.isNotEmpty) return list;
    final legacy = _prefs.getString(_backgroundColorDarkKey);
    return (legacy == null || legacy.trim().isEmpty)
        ? defaultDarkBackgroundGradient
        : [legacy];
  }

  Future<void> setThemeBackgroundColorsDark(List<String> values) =>
      _prefs.setStringList(_backgroundColorListDarkKey, values);

  // -- 自定义颜色列表（外观设置里「新增颜色」保存的颜色） --
  static const _themeCustomColorsKey = 'theme_custom_colors';
  static const _fontCustomColorsKey = 'font_custom_colors';
  static const _secondaryFontCustomColorsKey = 'secondary_font_custom_colors';
  static const _fontCustomColorsLightKey = 'font_custom_colors_light';
  static const _fontCustomColorsDarkKey = 'font_custom_colors_dark';
  static const _secondaryFontCustomColorsLightKey =
      'secondary_font_custom_colors_light';
  static const _secondaryFontCustomColorsDarkKey =
      'secondary_font_custom_colors_dark';
  static const _backgroundCustomColorsLightKey =
      'background_custom_colors_light';
  static const _backgroundCustomColorsDarkKey = 'background_custom_colors_dark';

  List<String> _getColorList(String key) {
    final list = _prefs.getStringList(key);
    if (list == null) return const [];
    return list
        .where((value) => value.trim().isNotEmpty)
        .toList(growable: false);
  }

  /// 新键不存在时回退到旧版共用的列表，升级后不丢用户已保存的颜色。
  List<String> _getColorListWithLegacy(String key, String legacyKey) {
    if (_prefs.containsKey(key)) return _getColorList(key);
    return _getColorList(legacyKey);
  }

  /// 主题色的自定义颜色列表（深浅色共用）。
  List<String> getCustomThemeColors() => _getColorList(_themeCustomColorsKey);
  Future<void> setCustomThemeColors(List<String> values) =>
      _prefs.setStringList(_themeCustomColorsKey, values);

  /// 浅色模式「字体颜色」的自定义颜色列表。
  List<String> getCustomFontColorsLight() =>
      _getColorListWithLegacy(_fontCustomColorsLightKey, _fontCustomColorsKey);
  Future<void> setCustomFontColorsLight(List<String> values) =>
      _prefs.setStringList(_fontCustomColorsLightKey, values);

  /// 深色模式「字体颜色」的自定义颜色列表。
  List<String> getCustomFontColorsDark() =>
      _getColorListWithLegacy(_fontCustomColorsDarkKey, _fontCustomColorsKey);
  Future<void> setCustomFontColorsDark(List<String> values) =>
      _prefs.setStringList(_fontCustomColorsDarkKey, values);

  /// 浅色模式「第二字体颜色」的自定义颜色列表。
  List<String> getCustomSecondaryFontColorsLight() => _getColorListWithLegacy(
    _secondaryFontCustomColorsLightKey,
    _secondaryFontCustomColorsKey,
  );
  Future<void> setCustomSecondaryFontColorsLight(List<String> values) =>
      _prefs.setStringList(_secondaryFontCustomColorsLightKey, values);

  /// 深色模式「第二字体颜色」的自定义颜色列表。
  List<String> getCustomSecondaryFontColorsDark() => _getColorListWithLegacy(
    _secondaryFontCustomColorsDarkKey,
    _secondaryFontCustomColorsKey,
  );
  Future<void> setCustomSecondaryFontColorsDark(List<String> values) =>
      _prefs.setStringList(_secondaryFontCustomColorsDarkKey, values);

  /// 浅色模式「背景颜色」的自定义颜色列表。
  List<String> getCustomBackgroundColorsLight() =>
      _getColorList(_backgroundCustomColorsLightKey);
  Future<void> setCustomBackgroundColorsLight(List<String> values) =>
      _prefs.setStringList(_backgroundCustomColorsLightKey, values);

  /// 深色模式「背景颜色」的自定义颜色列表。
  List<String> getCustomBackgroundColorsDark() =>
      _getColorList(_backgroundCustomColorsDarkKey);
  Future<void> setCustomBackgroundColorsDark(List<String> values) =>
      _prefs.setStringList(_backgroundCustomColorsDarkKey, values);

  // -- 主界面跟随封面变色（仅深色主题） --
  static const _coverBackgroundKey = 'cover_background_dark';

  /// 主界面背景是否跟随当前歌曲封面变色（默认开启，仅深色主题生效）。
  bool getCoverBackground() => _prefs.getBool(_coverBackgroundKey) ?? true;
  Future<void> setCoverBackground(bool v) =>
      _prefs.setBool(_coverBackgroundKey, v);

  // -- 播放歌曲时动态光晕 --
  static const _coverGlowAnimationKey = 'cover_glow_animation';

  /// 播放歌曲时主界面背景光晕是否缓慢运动 + 呼吸（默认关闭）。
  bool getCoverGlowAnimation() =>
      _prefs.getBool(_coverGlowAnimationKey) ?? false;
  Future<void> setCoverGlowAnimation(bool v) =>
      _prefs.setBool(_coverGlowAnimationKey, v);

  // -- 歌曲列表不显示封面 --
  static const _songListHideCoverKey = 'song_list_hide_cover';

  /// 歌曲列表是否不显示封面（默认关闭）。
  ///
  /// 打开后列表不再加载封面，避免纯文字列表也去请求网络图片。
  bool getSongListHideCover() => _prefs.getBool(_songListHideCoverKey) ?? false;
  Future<void> setSongListHideCover(bool v) =>
      _prefs.setBool(_songListHideCoverKey, v);

  // -- 自定义背景渐变（「背景渐变 → 新增颜色」保存的三色渐变） --
  static const _backgroundGradientsLightKey = 'background_gradients_light';
  static const _backgroundGradientsDarkKey = 'background_gradients_dark';

  /// 浅色模式的自定义渐变列表：每项是 3 个颜色（内部按 `#A,#B,#C` 存一行，
  /// 省掉 JSON 解析；长度不是 3 的脏数据直接丢弃）。
  List<List<String>> getCustomBackgroundGradientsLight() =>
      _getGradientList(_backgroundGradientsLightKey);
  Future<void> setCustomBackgroundGradientsLight(List<List<String>> values) =>
      _prefs.setStringList(
        _backgroundGradientsLightKey,
        values.map(_joinGradient).toList(growable: false),
      );

  /// 深色模式的自定义渐变列表。
  List<List<String>> getCustomBackgroundGradientsDark() =>
      _getGradientList(_backgroundGradientsDarkKey);
  Future<void> setCustomBackgroundGradientsDark(List<List<String>> values) =>
      _prefs.setStringList(
        _backgroundGradientsDarkKey,
        values.map(_joinGradient).toList(growable: false),
      );

  static String _joinGradient(List<String> colors) => colors.join(',');

  List<List<String>> _getGradientList(String key) {
    final raw = _prefs.getStringList(key);
    if (raw == null) return const [];
    final result = <List<String>>[];
    for (final item in raw) {
      final tokens = item
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList(growable: false);
      // 末尾可能带 `@n` 方向标记 / `~n` 光晕标记（见 background_gradient.dart），
      // 颜色本身是 1~3 个；旧数据没有标记，按「上下、无光晕」处理。
      final colors = tokens
          .where((token) => !token.startsWith('@') && !token.startsWith('~'))
          .toList(growable: false);
      final extra = tokens
          .where((token) => token.startsWith('@') || token.startsWith('~'))
          .toList(growable: false);
      if (colors.isEmpty || colors.length > 3) continue;
      result.add([...colors, ...extra]);
    }
    return result;
  }

  // -- audio quality --
  String getAudioQuality() => _prefs.getString('audio_quality') ?? '128k';
  Future<void> setAudioQuality(String v) =>
      _prefs.setString('audio_quality', v);

  // -- equalizer enable --
  bool getEqualizerEnabled() => _prefs.getBool('equalizer_enabled') ?? false;
  Future<void> setEqualizerEnabled(bool v) =>
      _prefs.setBool('equalizer_enabled', v);

  // -- equalizer preset --
  String getEqualizerPreset() => _prefs.getString('eq_preset') ?? '流行';
  Future<void> setEqualizerPreset(String v) => _prefs.setString('eq_preset', v);

  // -- equalizer bands (10-band, JSON) --
  String getEqualizerBands() => _prefs.getString('eq_bands') ?? '';
  Future<void> setEqualizerBands(String v) => _prefs.setString('eq_bands', v);

  // -- bass boost --
  bool getBassBoostEnabled() => _prefs.getBool('bass_boost_enabled') ?? false;
  Future<void> setBassBoostEnabled(bool v) =>
      _prefs.setBool('bass_boost_enabled', v);
  double getBassBoostGain() => _prefs.getDouble('bass_boost_gain') ?? 6.0;
  Future<void> setBassBoostGain(double v) =>
      _prefs.setDouble('bass_boost_gain', v);
  String getBassBoostPreset() =>
      _prefs.getString('bass_boost_preset') ?? 'medium';
  Future<void> setBassBoostPreset(String v) =>
      _prefs.setString('bass_boost_preset', v);

  // -- surround --
  bool getSurroundEnabled() => _prefs.getBool('surround_enabled') ?? false;
  Future<void> setSurroundEnabled(bool v) =>
      _prefs.setBool('surround_enabled', v);
  String getSurroundMode() => _prefs.getString('surround_mode') ?? 'small';
  Future<void> setSurroundMode(String v) =>
      _prefs.setString('surround_mode', v);

  // -- balance --
  bool getBalanceEnabled() => _prefs.getBool('balance_enabled') ?? false;
  Future<void> setBalanceEnabled(bool v) =>
      _prefs.setBool('balance_enabled', v);
  double getBalanceValue() => _prefs.getDouble('balance_value') ?? 0.0;
  Future<void> setBalanceValue(double v) =>
      _prefs.setDouble('balance_value', v);

  // -- playback speed --
  double getPlaybackSpeed() => _prefs.getDouble('playback_speed') ?? 1.0;
  Future<void> setPlaybackSpeed(double v) =>
      _prefs.setDouble('playback_speed', v);

  // -- 播放下载超时（音频加载/下载等待上限，默认 10 秒）--
  int getPlaybackDownloadTimeout() =>
      _prefs.getInt('playback_download_timeout_seconds') ?? 10;
  Future<void> setPlaybackDownloadTimeout(int v) =>
      _prefs.setInt('playback_download_timeout_seconds', v);

  // -- download dir --
  Future<String> getDownloadDir() async {
    final persisted = _prefs.getString('download_dir');
    if (persisted != null && persisted.isNotEmpty) {
      // 老版本的默认下载目录是 `AppData\music`，现在是 `AppData\download_music`：
      // 存着旧默认值时顺手改成新路径（用户自己挑的目录不受影响）。
      final normalized = AppPaths.normalizeLegacyPath(persisted);
      if (normalized != persisted) {
        unawaited(setDownloadDir(normalized));
      }
      return normalized;
    }
    // 默认目录必须按平台区分：桌面端不能使用 Android 的公共音乐目录，
    // 否则在 Windows 上会被解析成 `<当前盘符>:\storage\emulated\...`。
    return defaultDownloadDir();
  }

  Future<void> setDownloadDir(String v) => _prefs.setString('download_dir', v);

  // -- wifi only --
  bool getWifiOnlyDownload() => _prefs.getBool('wifi_only_download') ?? false;
  Future<void> setWifiOnlyDownload(bool v) =>
      _prefs.setBool('wifi_only_download', v);

  // -- auto play --
  bool getAutoPlay() => _prefs.getBool('auto_play') ?? false;
  Future<void> setAutoPlay(bool v) => _prefs.setBool('auto_play', v);

  // -- remember progress (default off) --
  bool getRememberProgress() => _prefs.getBool('remember_progress') ?? false;
  Future<void> setRememberProgress(bool v) =>
      _prefs.setBool('remember_progress', v);

  // -- 标记歌曲播放状态（已听标签，默认开启）--
  bool getMarkPlayedStatus() => _prefs.getBool('mark_played_status') ?? true;
  Future<void> setMarkPlayedStatus(bool v) =>
      _prefs.setBool('mark_played_status', v);

  // -- 隐藏B站会员专属歌曲（默认开启）--
  bool getHideVipExclusiveSongs() =>
      _prefs.getBool('hide_vip_exclusive_songs') ?? true;
  Future<void> setHideVipExclusiveSongs(bool v) =>
      _prefs.setBool('hide_vip_exclusive_songs', v);

  // -- 备份还原 / WebDAV --
  String getWebDavConfigJson() => _prefs.getString('webdav_config') ?? '';
  Future<void> setWebDavConfigJson(String v) =>
      _prefs.setString('webdav_config', v);

  // -- notification enabled --
  bool getNotificationEnabled() =>
      _prefs.getBool('notification_enabled') ?? true;
  Future<void> setNotificationEnabled(bool v) =>
      _prefs.setBool('notification_enabled', v);

  // -- music source --
  String getMusicSource() => _prefs.getString('music_source') ?? '网易云';
  Future<void> setMusicSource(String v) => _prefs.setString('music_source', v);

  // -- source quality per platform (stored as JSON) --
  Map<String, String> getSourceQuality() {
    final raw = _prefs.getString('source_quality');
    if (raw == null)
      return {
        '网易云': '128k',
        'QQ音乐': '128k',
        '酷狗': '128k',
        '酷我': '128k',
        '咪咕': '128k',
      };
    try {
      return Map<String, String>.fromEntries(
        raw.split('|').map((e) {
          final parts = e.split('=');
          return MapEntry(parts[0], parts[1]);
        }),
      );
    } catch (_) {
      return {
        '网易云': '128k',
        'QQ音乐': '128k',
        '酷狗': '128k',
        '酷我': '128k',
        '咪咕': '128k',
      };
    }
  }

  Future<void> setSourceQuality(Map<String, String> v) => _prefs.setString(
    'source_quality',
    v.entries.map((e) => '${e.key}=${e.value}').join('|'),
  );

  String getGlobalQuality() => _prefs.getString('global_quality') ?? '128k';
  Future<void> setGlobalQuality(String v) =>
      _prefs.setString('global_quality', v);

  /// 缓存目录的最大占用（MB）。默认 2 GB，范围 100 MB ~ 10 GB。
  int getMaxCacheSizeMb() => _prefs.getInt('max_cache_size_mb') ?? 2048;
  Future<void> setMaxCacheSizeMb(int v) =>
      _prefs.setInt('max_cache_size_mb', v);

  // -- filename template (已固定为「歌手名 - 歌曲名」，仅保留读写兼容旧数据) --
  String getFilenameTemplate() => '%s - %t';
  Future<void> setFilenameTemplate(String v) =>
      _prefs.setString('filename_template', '%s - %t');

  // -- tag write --
  bool getTagWriteBasicInfo() => _prefs.getBool('tag_write_basic_info') ?? true;
  Future<void> setTagWriteBasicInfo(bool v) =>
      _prefs.setBool('tag_write_basic_info', v);
  bool getTagWriteCover() => _prefs.getBool('tag_write_cover') ?? true;
  Future<void> setTagWriteCover(bool v) => _prefs.setBool('tag_write_cover', v);
  bool getTagWriteLyrics() => _prefs.getBool('tag_write_lyrics') ?? true;
  Future<void> setTagWriteLyrics(bool v) =>
      _prefs.setBool('tag_write_lyrics', v);

  // -- audio effect --
  bool getAudioEffectEnabled() =>
      _prefs.getBool('audio_effect_enabled') ?? false;
  Future<void> setAudioEffectEnabled(bool v) =>
      _prefs.setBool('audio_effect_enabled', v);

  // -- audio visualizer --
  bool getAudioVisualizerEnabled() =>
      _prefs.getBool('audio_visualizer_enabled') ?? false;
  Future<void> setAudioVisualizerEnabled(bool v) =>
      _prefs.setBool('audio_visualizer_enabled', v);

  // -- 均衡器 + 高级音效的整段配置（导出 / 导入配置用） --
  //
  // 这些键全部落在 `settings.json`（[AppPreferences]）里：导出配置直接从这里
  // 读，导入配置写回这里，不再单独维护一份「音效专用」的配置文件。
  // 键名即 settings.json 里的原始键名，换设备 / 还原备份后照样对得上。

  /// 导出均衡器 + 高级音效的全部配置（值就是 settings.json 里的原始形态）。
  Map<String, Object> exportAudioEffectConfig() => {
    'equalizer_enabled': getEqualizerEnabled(),
    'eq_preset': getEqualizerPreset(),
    // 频段是 JSON 字符串（[0.0, 0.0, ...]），原样带出去，导入时直接写回。
    'eq_bands': getEqualizerBands(),
    'eq_custom_presets': getEqualizerCustomPresets(),
    'audio_effect_enabled': getAudioEffectEnabled(),
    'audio_visualizer_enabled': getAudioVisualizerEnabled(),
    'bass_boost_enabled': getBassBoostEnabled(),
    'bass_boost_gain': getBassBoostGain(),
    'bass_boost_preset': getBassBoostPreset(),
    'surround_enabled': getSurroundEnabled(),
    'surround_mode': getSurroundMode(),
    'balance_enabled': getBalanceEnabled(),
    'balance_value': getBalanceValue(),
  };

  /// 把 [exportAudioEffectConfig] 导出的那份配置写回 `settings.json`。
  ///
  /// 只写配置里出现的键：老版本导出的文件没有低音 / 环绕 / 平衡这些字段，
  /// 缺的项保持用户当前的值，不会被重置成默认值。
  Future<void> importAudioEffectConfig(Map<String, dynamic> data) async {
    final boolKeys = <String, Future<void> Function(bool)>{
      'equalizer_enabled': setEqualizerEnabled,
      'audio_effect_enabled': setAudioEffectEnabled,
      'audio_visualizer_enabled': setAudioVisualizerEnabled,
      'bass_boost_enabled': setBassBoostEnabled,
      'surround_enabled': setSurroundEnabled,
      'balance_enabled': setBalanceEnabled,
    };
    final stringKeys = <String, Future<void> Function(String)>{
      'eq_preset': setEqualizerPreset,
      'eq_bands': setEqualizerBands,
      'eq_custom_presets': setEqualizerCustomPresets,
      'bass_boost_preset': setBassBoostPreset,
      'surround_mode': setSurroundMode,
    };
    final doubleKeys = <String, Future<void> Function(double)>{
      'bass_boost_gain': setBassBoostGain,
      'balance_value': setBalanceValue,
    };

    for (final entry in boolKeys.entries) {
      final value = data[entry.key];
      if (value is bool) await entry.value(value);
    }
    for (final entry in stringKeys.entries) {
      final value = data[entry.key];
      if (value is String) await entry.value(value);
    }
    for (final entry in doubleKeys.entries) {
      final value = data[entry.key];
      if (value is num) await entry.value(value.toDouble());
    }
  }

  // -- appearance performance --
  bool getAppearanceBgAnimation() =>
      _prefs.getBool('appearance_bg_animation') ?? false;
  Future<void> setAppearanceBgAnimation(bool v) =>
      _prefs.setBool('appearance_bg_animation', v);

  // -- lyric settings --
  double getLyricFontSize() => _prefs.getDouble('lyric_font_size') ?? 1.0;
  Future<void> setLyricFontSize(double v) =>
      _prefs.setDouble('lyric_font_size', v);
  bool getLyricShowTranslation() =>
      _prefs.getBool('lyric_show_translation') ?? true;
  Future<void> setLyricShowTranslation(bool v) =>
      _prefs.setBool('lyric_show_translation', v);
  bool getLyricShowRoman() => _prefs.getBool('lyric_show_roman') ?? true;
  Future<void> setLyricShowRoman(bool v) =>
      _prefs.setBool('lyric_show_roman', v);
  bool getLyricEnableBlur() => _prefs.getBool('lyric_enable_blur') ?? true;
  Future<void> setLyricEnableBlur(bool v) =>
      _prefs.setBool('lyric_enable_blur', v);
  bool getLyricEnableScale() => _prefs.getBool('lyric_enable_scale') ?? true;
  Future<void> setLyricEnableScale(bool v) =>
      _prefs.setBool('lyric_enable_scale', v);
  bool getLyricCenterAlign() => _prefs.getBool('lyric_center_align') ?? true;
  Future<void> setLyricCenterAlign(bool v) =>
      _prefs.setBool('lyric_center_align', v);
  bool getLyricImmersiveColor() =>
      _prefs.getBool('lyric_immersive_color') ?? true;
  Future<void> setLyricImmersiveColor(bool v) =>
      _prefs.setBool('lyric_immersive_color', v);

  // -- lyric font settings --
  //
  // 默认：思源宋体 / 90% / 字重 500。
  // 旧默认值（system / 100% / 700）在 [SettingsProviders] 初始化时会被迁移。
  String getLyricFontFamily() =>
      _prefs.getString('lyric_font_family') ?? 'SourceHanSerif';
  Future<void> setLyricFontFamily(String v) =>
      _prefs.setString('lyric_font_family', v);
  double getLyricFontRate() => _prefs.getDouble('lyric_font_rate') ?? 0.9;
  Future<void> setLyricFontRate(double v) =>
      _prefs.setDouble('lyric_font_rate', v);
  int getLyricFontWeight() => _prefs.getInt('lyric_font_weight') ?? 500;
  Future<void> setLyricFontWeight(int v) =>
      _prefs.setInt('lyric_font_weight', v);
  String getLyricFontColor() => _prefs.getString('lyric_font_color') ?? '';
  Future<void> setLyricFontColor(String v) =>
      _prefs.setString('lyric_font_color', v);

  // -- 平台歌曲的优先插件音源（JSON 对象：平台 id → 音源 id） --
  String getPreferredSourceMap() => _prefs.getString('preferred_sources') ?? '';
  Future<void> setPreferredSourceMap(String v) =>
      _prefs.setString('preferred_sources', v);

  // -- 数据源 → 播放源（JSON 对象：数据源插件 id → 音源 id） --
  String getDataSourcePlaybackSources() =>
      _prefs.getString('data_source_playback_sources') ?? '';
  Future<void> setDataSourcePlaybackSources(String v) =>
      _prefs.setString('data_source_playback_sources', v);

  // -- equalizer custom presets (JSON array) --
  String getEqualizerCustomPresets() =>
      _prefs.getString('eq_custom_presets') ?? '[]';
  Future<void> setEqualizerCustomPresets(String v) =>
      _prefs.setString('eq_custom_presets', v);

  // -- tag write extended --
  bool getTagWriteDownloadLyrics() =>
      _prefs.getBool('tag_write_download_lyrics') ?? false;
  Future<void> setTagWriteDownloadLyrics(bool v) =>
      _prefs.setBool('tag_write_download_lyrics', v);
  String getTagWriteLyricFormat() =>
      _prefs.getString('tag_write_lyric_format') ?? 'word-by-word';
  Future<void> setTagWriteLyricFormat(String v) =>
      _prefs.setString('tag_write_lyric_format', v);

  // -- auto cache music --
  bool getAutoCacheMusic() => _prefs.getBool('auto_cache_music') ?? true;
  Future<void> setAutoCacheMusic(bool v) =>
      _prefs.setBool('auto_cache_music', v);

  // -- auto update --（默认关闭，用户可在「关于」里手动开启）
  bool getAutoUpdate() => _prefs.getBool('auto_update') ?? false;
  Future<void> setAutoUpdate(bool v) => _prefs.setBool('auto_update', v);

  // -- default source id（用户最后切换的音源） --
  String getDefaultSourceId() => _prefs.getString('default_source_id') ?? '';
  Future<void> setDefaultSourceId(String v) =>
      _prefs.setString('default_source_id', v);

  // -- close to tray --
  bool getCloseToTray() => _prefs.getBool('close_to_tray') ?? true;
  Future<void> setCloseToTray(bool v) => _prefs.setBool('close_to_tray', v);

  // -- app language (界面语言, 参考 Mio-Music 的 AppLocale 设置) --
  String getAppLocale() => _prefs.getString('app_locale') ?? 'zh-CN';
  Future<void> setAppLocale(String v) => _prefs.setString('app_locale', v);

  // -- lyric language mode ('follow' 跟随界面 | 'zh-CN' | 'zh-TW') --
  String getLyricLocaleMode() =>
      _prefs.getString('lyric_locale_mode') ?? 'follow';
  Future<void> setLyricLocaleMode(String v) =>
      _prefs.setString('lyric_locale_mode', v);

  // -- full screen background mode --
  String getFullScreenBgMode() =>
      _prefs.getString('full_screen_bg_mode') ?? 'theme';
  Future<void> setFullScreenBgMode(String v) =>
      _prefs.setString('full_screen_bg_mode', v);

  // -- desktop lyric (桌面歌词/悬浮歌词窗, JSON 配置) --
  String getDesktopLyricSettings() =>
      _prefs.getString('desktop_lyric_settings') ?? '';
  Future<void> setDesktopLyricSettings(String v) =>
      _prefs.setString('desktop_lyric_settings', v);

  // -- cache directory --
  Future<String> getCacheDir() async {
    final persisted = _prefs.getString('cache_dir');
    if (persisted != null && persisted.isNotEmpty) return persisted;
    // 默认使用应用自己的缓存目录，避免把缓存写进系统共享临时目录。
    final cache = await AppPaths.cacheRootDirectory();
    return cache.path;
  }

  Future<void> setCacheDir(String v) => _prefs.setString('cache_dir', v);

  // -- directory size calculation --
  Future<String> getDirectorySize(String path) async {
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return '0 B';
      int total = 0;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) total += await entity.length();
      }
      return _formatBytes(total);
    } catch (_) {
      return '0 B';
    }
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const suffixes = ['B', 'KB', 'MB', 'GB', 'TB'];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < suffixes.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(i == 0 ? 0 : 1)} ${suffixes[i]}';
  }

  // -- cache clearing (non-persistent action) --
  /// 清理应用缓存的子目录（不删除用户选择的目录本身）。
  ///
  /// 只清理应用自己创建的本地歌曲封面（`local_songs_image_cache`）、
  /// 图片缓存（`image_cache`）和音频缓存（`audio_cache`），不会误删用户
  /// 缓存目录里的其它文件，也不再动系统临时目录。
  Future<int> clearCache() async {
    int total = 0;
    final roots = <Directory>[];
    final configured = _prefs.getString('cache_dir');
    if (configured != null && configured.isNotEmpty) {
      roots.add(Directory(configured));
    }
    try {
      roots.add(await AppPaths.cacheRootDirectory());
    } catch (_) {}

    const subDirectories = [
      CachePaths.localSongsImageCache,
      CachePaths.imageCache,
      CachePaths.audioCache,
    ];
    for (final root in roots) {
      for (final name in subDirectories) {
        final dir = Directory('${root.path}${Platform.pathSeparator}$name');
        if (!dir.existsSync()) continue;
        try {
          await for (final entity in dir.list(recursive: true)) {
            if (entity is File) total += await entity.length();
          }
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    }
    // 歌词缓存与图片缓存索引已经放进临时库，这里一起清掉。
    await AppDatabase.clearCacheData();
    return total;
  }
}
