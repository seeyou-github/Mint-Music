import 'dart:io';

import '../../../core/platform/app_paths.dart';
import '../../../core/storage/app_database.dart';
import '../../../core/storage/app_preferences.dart';
import '../../../core/platform/download_paths.dart';
import '../../../core/theme/theme_provider.dart';

class SettingsService {
  final AppPreferences _prefs;

  SettingsService(this._prefs);

  // -- theme --
  String getThemeMode() => _prefs.getString('theme_mode') ?? 'system';
  Future<void> setThemeMode(String v) => _prefs.setString('theme_mode', v);
  String getThemePrimaryColor() =>
      _prefs.getString('theme_primary_color') ?? '#1DB954';
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

  /// 深色模式「第二字体颜色」：为空表示使用主题默认色。
  String getThemeSecondaryFontColorDark() =>
      _prefs.getString(_secondaryFontColorDarkKey) ??
      _prefs.getString(_legacySecondaryFontColorKey) ??
      '';

  Future<void> setThemeSecondaryFontColorDark(String v) =>
      _prefs.setString(_secondaryFontColorDarkKey, v);

  // -- theme background colors（浅色 / 深色各一套） --
  static const _backgroundColorLightKey = 'theme_background_color_light';
  static const _backgroundColorDarkKey = 'theme_background_color_dark';

  /// 浅色模式「背景颜色」：默认使用 [defaultLightBackgroundColor]。
  String getThemeBackgroundColorLight() =>
      _prefs.getString(_backgroundColorLightKey) ?? defaultLightBackgroundColor;

  Future<void> setThemeBackgroundColorLight(String v) =>
      _prefs.setString(_backgroundColorLightKey, v);

  /// 深色模式「背景颜色」：默认使用 [defaultDarkBackgroundColor]。
  String getThemeBackgroundColorDark() =>
      _prefs.getString(_backgroundColorDarkKey) ?? defaultDarkBackgroundColor;

  Future<void> setThemeBackgroundColorDark(String v) =>
      _prefs.setString(_backgroundColorDarkKey, v);

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

  // -- audio quality --
  String getAudioQuality() => _prefs.getString('audio_quality') ?? '128k';
  Future<void> setAudioQuality(String v) =>
      _prefs.setString('audio_quality', v);

  // -- automatic quality downgrade --
  bool getAutoQualityDowngrade() =>
      _prefs.getBool('auto_quality_downgrade') ?? false;
  Future<void> setAutoQualityDowngrade(bool v) =>
      _prefs.setBool('auto_quality_downgrade', v);

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

  // -- download dir --
  Future<String> getDownloadDir() async {
    final persisted = _prefs.getString('download_dir');
    if (persisted != null && persisted.isNotEmpty) return persisted;
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

  // -- auto switch source when the current source fails (default off) --
  bool getAutoSwitchSource() => _prefs.getBool('auto_switch_source') ?? false;
  Future<void> setAutoSwitchSource(bool v) =>
      _prefs.setBool('auto_switch_source', v);

  // -- 标记歌曲播放状态（已听标签，默认开启）--
  bool getMarkPlayedStatus() => _prefs.getBool('mark_played_status') ?? true;
  Future<void> setMarkPlayedStatus(bool v) =>
      _prefs.setBool('mark_played_status', v);

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

  // -- cache size (display string, actual calculation is real-time) --
  String getCacheSize() => _prefs.getString('cache_size') ?? '128 MB';
  Future<void> setCacheSize(String v) => _prefs.setString('cache_size', v);

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

  // -- 内置音源的优先音源（JSON 对象：平台 id → 音源 id） --
  String getPreferredSourceMap() => _prefs.getString('preferred_sources') ?? '';
  Future<void> setPreferredSourceMap(String v) =>
      _prefs.setString('preferred_sources', v);

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

  // -- plugin auto check update (default off) --
  bool getPluginAutoCheckUpdate() =>
      _prefs.getBool('plugin_auto_check_update') ?? false;
  Future<void> setPluginAutoCheckUpdate(bool v) =>
      _prefs.setBool('plugin_auto_check_update', v);

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
  /// 只清理应用自己创建的 `artwork_cache` / `covers` / `image_cache` /
  /// `image_discovery_cache` / `audio_cache`（音频缓存），不会误删用户
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
      'artwork_cache',
      'covers',
      'image_cache',
      'image_discovery_cache',
      'audio_cache',
      'lyric_cache',
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
