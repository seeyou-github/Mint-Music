import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/backup/webdav_service.dart';
import '../../../core/storage/app_preferences.dart';
import '../../../core/l10n/app_locale.dart';
import '../../../core/l10n/l10n.dart';
import '../../../core/platform/download_paths.dart';
import '../../../core/theme/theme_provider.dart';
import '../../plugin/application/plugin_providers.dart';
import '../../plugin/domain/plugin_types.dart';
import '../../player/domain/models/desktop_lyric_settings.dart';
import '../data/settings_service.dart';

final settingsServiceProvider = FutureProvider<SettingsService>((ref) async {
  final prefs = await AppPreferences.getInstance();
  return SettingsService(prefs);
});

// -- audio quality --
final audioQualityProvider = StateProvider<String>((ref) => '128k');
final autoQualityDowngradeProvider = StateProvider<bool>((ref) => false);

// -- equalizer --
final equalizerEnabledProvider = StateProvider<bool>((ref) => false);

// -- playback --
final playbackSpeedProvider = StateProvider<double>((ref) => 1.0);
final autoPlayProvider = StateProvider<bool>((ref) => false);
final rememberProgressProvider = StateProvider<bool>((ref) => false);

/// 当前音源播放失败时是否自动切换到其他音源（默认关闭）。
/// 无论开关如何，播放失败都不会自动播放下一首。
final autoSwitchSourceProvider = StateProvider<bool>((ref) => false);

/// 是否记录并显示「已听 / 已听 N%」标记（默认开启）。
///
/// 开启后播放过的歌曲会按 1% 粒度把进度写进临时库，
/// 歌曲列表在时长左侧显示已听进度；关闭后不再记录也不再显示。
final markPlayedStatusProvider = StateProvider<bool>((ref) => true);

// -- download --
final downloadDirProvider = StateProvider<String>(
  (ref) => defaultDownloadDirSync(),
);
final wifiOnlyDownloadProvider = StateProvider<bool>((ref) => false);

// -- notification --
// 播放通知默认开启（不再提供开关；Android 端播放时缺少通知权限会提示用户）。
final notificationEnabledProvider = StateProvider<bool>((ref) => true);

const kSourceNameToId = <String, String>{
  '网易云': 'wy',
  'QQ音乐': 'tx',
  '酷狗': 'kg',
  '酷我': 'kw',
  '咪咕': 'mg',
};

const kSourceIdToName = <String, String>{
  'wy': '网易云',
  'tx': 'QQ音乐',
  'kg': '酷狗',
  'kw': '酷我',
  'mg': '咪咕',
};

/// 用户最后切换的音源 id（持久化）。
///
/// 为空时表示用户还没有手动切换过音源，默认音源取「插件管理里第一个
/// 启用的音源」。
final defaultSourceIdSettingProvider = StateProvider<String>((ref) => '');

/// 当前生效的默认音源 id。
///
/// 优先使用用户最后切换过的音源；没有记录时使用插件管理里第一个启用的
/// 音源（插件就绪后会自动切换过去）。
final defaultSourceIdProvider = Provider<String>((ref) {
  final persisted = ref.watch(defaultSourceIdSettingProvider);
  if (persisted.isNotEmpty) return persisted;
  return ref.watch(firstEnabledSourceIdProvider);
});

/// 记录用户最后切换的音源，作为默认音源。
Future<void> persistDefaultSourceId(
  ProviderContainer container,
  String sourceId,
) async {
  container.read(defaultSourceIdSettingProvider.notifier).state = sourceId;
  try {
    final svc = await container.read(settingsServiceProvider.future);
    await svc.setDefaultSourceId(sourceId);
  } catch (_) {}
}

/// 记录用户最后切换的音质：同步「默认音质」与「全局音质」。
Future<void> persistUserQuality(
  Ref ref, {
  required String quality,
  String? sourceId,
}) async {
  ref.read(globalQualityProvider.notifier).state = quality;
  final sourceQuality = Map<String, String>.from(
    ref.read(sourceQualityProvider),
  );
  // 同名插件的变体 id（'wy@插件id'）按平台部分匹配。
  final name = sourceId == null
      ? null
      : kSourceIdToName[SourceInfo.baseIdOf(sourceId)];
  if (name != null) {
    sourceQuality[name] = quality;
    ref.read(sourceQualityProvider.notifier).state = sourceQuality;
  }
  try {
    final svc = await ref.read(settingsServiceProvider.future);
    await svc.setGlobalQuality(quality);
    if (name != null) {
      await svc.setSourceQuality(sourceQuality);
    }
  } catch (_) {}
}

const kQualityDisplayName = <String, String>{
  '128k': '标准 128K',
  '192k': '高品质 192K',
  '320k': '超高品质 320K',
  'flac': '无损 FLAC',
  'flac24bit': '高解析度无损',
  'hires': '高清臻音',
  'atmos': '沉浸环绕声',
  'master': '超清母带',
};

const kQualityDescription = <String, String>{
  '128k': '基础音质，文件较小',
  '192k': '良好音质，适合大多数场景',
  '320k': '高品质音质，接近CD品质',
  'flac': '无损音质，完美还原原始录音',
  'flac24bit': '高解析度无损，最高192kHz/24bit',
  'hires': '声音听感加强，96kHz/24bit',
  'atmos': '沉浸式空间环绕音感',
  'master': '母带级音质，192kHz/24bit',
};

const kSourceSupportedQualities = <String, List<String>>{
  'wy': ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos'],
  'tx': ['128k', '320k', 'flac', 'hires', 'atmos', 'master'],
  'kg': ['128k', '320k', 'flac', 'flac24bit', 'hires'],
  'kw': ['128k', '320k', 'flac', 'flac24bit', 'hires'],
  'mg': ['128k', '320k', 'flac', 'flac24bit', 'hires', 'atmos', 'master'],
};

List<String> getSupportedQualitiesForSource(String sourceName) {
  final id = kSourceNameToId[sourceName];
  if (id == null) return ['128k', '320k', 'flac'];
  return kSourceSupportedQualities[id] ?? ['128k', '320k', 'flac'];
}

String getQualityDisplayName(String qualityId) {
  return kQualityDisplayName[qualityId] ?? qualityId;
}

final sourceQualityProvider = StateProvider<Map<String, String>>(
  (ref) => {
    '网易云': '128k',
    'QQ音乐': '128k',
    '酷狗': '128k',
    '酷我': '128k',
    '咪咕': '128k',
  },
);

final globalQualityProvider = StateProvider<String>((ref) => '128k');

// -- cache --
/// 最大缓存大小（MB），范围 100 MB ~ 10 GB（10240 MB）。
final maxCacheSizeMbProvider = StateProvider<int>((ref) => 2048);

// -- filename template（固定为「歌手名 - 歌曲名」） --
final filenameTemplateProvider = StateProvider<String>((ref) => '%s - %t');

// -- tag write --
final tagWriteBasicInfoProvider = StateProvider<bool>((ref) => true);
final tagWriteCoverProvider = StateProvider<bool>((ref) => true);
final tagWriteLyricsProvider = StateProvider<bool>((ref) => true);
final tagWriteDownloadLyricsProvider = StateProvider<bool>((ref) => false);
final tagWriteLyricFormatProvider = StateProvider<String>(
  (ref) => 'word-by-word',
);

// -- audio effects --
final audioEffectEnabledProvider = StateProvider<bool>((ref) => false);
final audioVisualizerEnabledProvider = StateProvider<bool>((ref) => false);

// -- bass boost --
final bassBoostEnabledProvider = StateProvider<bool>((ref) => false);
final bassBoostGainProvider = StateProvider<double>((ref) => 6.0);
final bassBoostPresetProvider = StateProvider<String>((ref) => 'medium');

// -- surround --
final surroundEnabledProvider = StateProvider<bool>((ref) => false);
final surroundModeProvider = StateProvider<String>((ref) => 'small');

// -- balance --
final balanceEnabledProvider = StateProvider<bool>((ref) => false);
final balanceValueProvider = StateProvider<double>((ref) => 0.0);

// -- equalizer preset --
final equalizerPresetProvider = StateProvider<String>((ref) => '流行');
final equalizerBandsProvider = StateProvider<List<double>>(
  (ref) => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
);
final equalizerCustomPresetsProvider =
    StateProvider<List<Map<String, dynamic>>>((ref) => []);

// -- lyric display --
//
// 这些开关已经从「歌词设置」里去掉了，行为固定下来：
// 显示翻译=开、显示罗马音=关、模糊=关、缩放=关、歌词居中=开、
// Apple Music 风格歌词=关。
final lyricFontSizeProvider = StateProvider<double>((ref) => 1.0);
final lyricShowTranslationProvider = StateProvider<bool>((ref) => true);
final lyricShowRomanProvider = StateProvider<bool>((ref) => false);
final lyricEnableBlurProvider = StateProvider<bool>((ref) => false);
final lyricEnableScaleProvider = StateProvider<bool>((ref) => false);
final lyricCenterAlignProvider = StateProvider<bool>((ref) => true);
final lyricImmersiveColorProvider = StateProvider<bool>((ref) => true);

/// 固定的歌词显示行为（不再由用户设置）。
class LyricDisplayDefaults {
  const LyricDisplayDefaults._();

  static const bool showTranslation = true;
  static const bool showRoman = false;
  static const bool enableBlur = false;
  static const bool enableScale = false;
  static const bool centerAlign = true;
}

// -- lyric font --
// 默认：思源宋体 / 90% / 字重 500。
final lyricFontFamilyProvider = StateProvider<String>(
  (ref) => 'SourceHanSerif',
);
final lyricFontRateProvider = StateProvider<double>((ref) => 0.9);
final lyricFontWeightProvider = StateProvider<int>((ref) => 500);

/// 内置音源 → 优先音源（平台 id → 音源 id）。
///
/// 内置音源（wy / tx / kg / kw / mg）自己没有地址接口，播放时由插件解析。
/// 这里记录用户为每个内置源指定的「优先音源」：解析播放地址时先试它，
/// 失败再按原有顺序尝试其它音源。
///
/// 例：`{'wy': 'wy@luoxue', 'kg': 'kg@musicfree'}`
final preferredSourceMapProvider = StateProvider<Map<String, String>>(
  (ref) => const {},
);

/// 解析持久化的优先音源 JSON。
Map<String, String> _decodePreferredSources(String raw) {
  if (raw.trim().isEmpty) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) return const {};
    final result = <String, String>{};
    decoded.forEach((key, value) {
      final k = '$key'.trim();
      final v = '$value'.trim();
      if (k.isNotEmpty && v.isNotEmpty) result[k] = v;
    });
    return result;
  } catch (_) {
    return const {};
  }
}

/// 设置某个内置源的优先音源（[sourceId] 为空表示清除）。
Future<void> setPreferredSource(
  WidgetRef ref, {
  required String baseSourceId,
  required String sourceId,
}) async {
  final base = baseSourceId.trim();
  if (base.isEmpty) return;
  final current = Map<String, String>.from(
    ref.read(preferredSourceMapProvider),
  );
  if (sourceId.trim().isEmpty) {
    current.remove(base);
  } else {
    current[base] = sourceId.trim();
  }
  ref.read(preferredSourceMapProvider.notifier).state = current;
  try {
    final svc = await ref.read(settingsServiceProvider.future);
    await svc.setPreferredSourceMap(jsonEncode(current));
  } catch (e) {
    debugPrint('[Settings] 保存优先音源失败: $e');
  }
}

/// 歌词字体颜色（hex ARGB 字符串，空表示使用默认/沉浸色）
final lyricFontColorProvider = StateProvider<String>((ref) => '');

// -- 备份还原 / WebDAV --

/// WebDAV 备份配置（地址 / 账号 / 设备名 / 歌单同步开关）。
final webDavConfigProvider = StateProvider<WebDavConfig>((ref) {
  return const WebDavConfig();
});

// -- appearance --
final appearanceBgAnimationProvider = StateProvider<bool>((ref) => false);

/// 「主题色 / 字体颜色 / 第二字体颜色 / 背景颜色」里用户新增的自定义颜色列表。
///
/// 颜色以 `#RRGGBB` 形式保存；选择面板里长按可以编辑或删除。
/// 主题色深浅色共用，其余颜色各保存一套。
final customThemeColorsProvider = StateProvider<List<String>>(
  (ref) => const [],
);
final customFontColorsLightProvider = StateProvider<List<String>>(
  (ref) => const [],
);
final customFontColorsDarkProvider = StateProvider<List<String>>(
  (ref) => const [],
);
final customSecondaryFontColorsLightProvider = StateProvider<List<String>>(
  (ref) => const [],
);
final customSecondaryFontColorsDarkProvider = StateProvider<List<String>>(
  (ref) => const [],
);
final customBackgroundColorsLightProvider = StateProvider<List<String>>(
  (ref) => const [],
);
final customBackgroundColorsDarkProvider = StateProvider<List<String>>(
  (ref) => const [],
);

/// 桌面歌词(悬浮歌词窗)的完整配置。
///
/// 整体作为一个对象持久化(见 [SettingsService.setDesktopLyricSettings]),
/// 避免为每个子项各建一个 provider 与 prefs key。
final desktopLyricSettingsProvider = StateProvider<DesktopLyricSettings>(
  (ref) => DesktopLyricSettings.defaults,
);

// -- auto cache music --
final autoCacheMusicProvider = StateProvider<bool>((ref) => true);

// -- auto update（默认关闭） --
final autoUpdateProvider = StateProvider<bool>((ref) => false);
final closeToTrayProvider = StateProvider<bool>((ref) => true);
final cacheDirProvider = StateProvider<String>((ref) => '');

/// 插件自动检测更新（默认关闭）。
///
/// 关闭时：进入插件管理页不会自动检查更新，应用启动时也不会自动检查
/// 插件更新（用户仍可手动点击「检查更新」）。
final pluginAutoCheckUpdateProvider = StateProvider<bool>((ref) => false);

// -- app language (界面语言) --
// 参考 Mio-Music 的 AppLocale 设置:默认简体中文,可切换繁体中文。
final appLocaleProvider = StateProvider<AppLocale>((ref) => AppLocale.zhCn);

/// 歌词语言模式:
/// - 'follow' 跟随界面语言(默认)
/// - 'zh-CN' 始终简体
/// - 'zh-TW' 始终繁体
final lyricLocaleModeProvider = StateProvider<String>((ref) => 'follow');

/// 实际生效的歌词语言。
final effectiveLyricLocaleProvider = Provider<AppLocale>((ref) {
  final mode = ref.watch(lyricLocaleModeProvider);
  if (mode == 'zh-TW') return AppLocale.zhTw;
  if (mode == 'zh-CN') return AppLocale.zhCn;
  return ref.watch(appLocaleProvider);
});

final downloadDirSizeProvider = FutureProvider<String>((ref) async {
  final svc = await ref.watch(settingsServiceProvider.future);
  final dir = ref.watch(downloadDirProvider);
  return svc.getDirectorySize(dir);
});

final cacheDirSizeProvider = FutureProvider<String>((ref) async {
  final svc = await ref.watch(settingsServiceProvider.future);
  final dir = ref.watch(cacheDirProvider);
  if (dir.isEmpty) return '0 B';
  return svc.getDirectorySize(dir);
});

enum FullScreenBackgroundMode { theme, cover, dark }

final fullScreenBackgroundModeProvider =
    StateProvider<FullScreenBackgroundMode>(
      (ref) => FullScreenBackgroundMode.theme,
    );

// -- app version (loaded once) --
final appVersionProvider = FutureProvider<String>((ref) async {
  return '1.1.1';
});

class EqPreset {
  final String name;
  final List<double> gains;
  final List<double>? originalGains;
  const EqPreset({required this.name, required this.gains, this.originalGains});
  Map<String, dynamic> toJson() => {
    'name': name,
    'gains': gains,
    'originalGains': originalGains,
  };
  factory EqPreset.fromJson(Map<String, dynamic> json) => EqPreset(
    name: json['name'] as String,
    gains: (json['gains'] as List).cast<double>(),
    originalGains: (json['originalGains'] as List?)?.cast<double>(),
  );
}

const kEqFrequencies = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

const kBuiltInPresets = <EqPreset>[
  EqPreset(name: 'Flat(原声)', gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
  EqPreset(name: 'Pop(流行)', gains: [1, 3, 4, 3, 1, -1, -1, 1, 2, 3]),
  EqPreset(name: 'Rock(摇滚)', gains: [4, 3, 1, 0, -1, -1, 0, 2, 3, 4]),
  EqPreset(name: 'Jazz(爵士)', gains: [3, 2, 1, 2, -1, -1, 0, 1, 2, 3]),
  EqPreset(name: 'Classical(古典)', gains: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4]),
  EqPreset(name: 'Bass Boost(低音增强)', gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
  EqPreset(name: 'Vocal Boost(人声增强)', gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1]),
  EqPreset(name: 'Treble Boost(高音增强)', gains: [0, 0, 0, 0, 0, 1, 3, 5, 6, 6]),
];

// -- init: load all persisted settings into providers --
final settingsInitProvider = FutureProvider<void>((ref) async {
  final svc = await ref.watch(settingsServiceProvider.future);

  // 界面语言固定简体中文、歌词语言固定简体中文（设置项已移除）。
  const locale = AppLocale.zhCn;
  ref.read(appLocaleProvider.notifier).state = locale;
  currentLocale = locale;
  ref.read(lyricLocaleModeProvider.notifier).state = 'zh-CN';

  // 'light' / 'dark' / 'system'，未设置时默认跟随系统
  ref.read(themeModeProvider.notifier).state = themeModeFromPref(
    svc.getThemeMode(),
  );
  ref.read(themePrimaryColorProvider.notifier).state = svc
      .getThemePrimaryColor();
  ref.read(lightThemeFontColorProvider.notifier).state = svc
      .getThemeFontColorLight();
  ref.read(darkThemeFontColorProvider.notifier).state = svc
      .getThemeFontColorDark();
  ref.read(lightThemeSecondaryFontColorProvider.notifier).state = svc
      .getThemeSecondaryFontColorLight();
  ref.read(darkThemeSecondaryFontColorProvider.notifier).state = svc
      .getThemeSecondaryFontColorDark();
  ref.read(lightThemeBackgroundColorProvider.notifier).state = svc
      .getThemeBackgroundColorLight();
  ref.read(darkThemeBackgroundColorProvider.notifier).state = svc
      .getThemeBackgroundColorDark();
  ref.read(customThemeColorsProvider.notifier).state = svc
      .getCustomThemeColors();
  ref.read(customFontColorsLightProvider.notifier).state = svc
      .getCustomFontColorsLight();
  ref.read(customFontColorsDarkProvider.notifier).state = svc
      .getCustomFontColorsDark();
  ref.read(customSecondaryFontColorsLightProvider.notifier).state = svc
      .getCustomSecondaryFontColorsLight();
  ref.read(customSecondaryFontColorsDarkProvider.notifier).state = svc
      .getCustomSecondaryFontColorsDark();
  ref.read(customBackgroundColorsLightProvider.notifier).state = svc
      .getCustomBackgroundColorsLight();
  ref.read(customBackgroundColorsDarkProvider.notifier).state = svc
      .getCustomBackgroundColorsDark();

  ref.read(audioQualityProvider.notifier).state = svc.getAudioQuality();
  ref.read(autoQualityDowngradeProvider.notifier).state = svc
      .getAutoQualityDowngrade();
  ref.read(equalizerEnabledProvider.notifier).state = svc.getEqualizerEnabled();
  ref.read(equalizerPresetProvider.notifier).state = svc.getEqualizerPreset();
  final bandsStr = svc.getEqualizerBands();
  if (bandsStr.isNotEmpty) {
    try {
      final list = (jsonDecode(bandsStr) as List)
          .map((value) => (value as num).toDouble())
          .toList();
      ref.read(equalizerBandsProvider.notifier).state = list;
    } catch (_) {}
  }
  final customPresetsStr = svc.getEqualizerCustomPresets();
  try {
    final list = (jsonDecode(customPresetsStr) as List)
        .cast<Map<String, dynamic>>();
    ref.read(equalizerCustomPresetsProvider.notifier).state = list;
  } catch (_) {}
  ref.read(playbackSpeedProvider.notifier).state = svc.getPlaybackSpeed();
  ref.read(downloadDirProvider.notifier).state = await svc.getDownloadDir();
  // 下载网络不再受限制（仅WiFi下载设置项已移除）。
  ref.read(wifiOnlyDownloadProvider.notifier).state = false;
  ref.read(autoPlayProvider.notifier).state = svc.getAutoPlay();
  ref.read(rememberProgressProvider.notifier).state = svc.getRememberProgress();
  ref.read(autoSwitchSourceProvider.notifier).state = svc.getAutoSwitchSource();
  ref.read(markPlayedStatusProvider.notifier).state = svc.getMarkPlayedStatus();
  ref.read(notificationEnabledProvider.notifier).state = svc
      .getNotificationEnabled();
  ref.read(defaultSourceIdSettingProvider.notifier).state = svc
      .getDefaultSourceId();
  ref.read(sourceQualityProvider.notifier).state = svc.getSourceQuality();
  ref.read(globalQualityProvider.notifier).state = svc.getGlobalQuality();
  ref.read(maxCacheSizeMbProvider.notifier).state = svc.getMaxCacheSizeMb();
  // 文件名格式固定为「歌手名 - 歌曲名」。
  ref.read(filenameTemplateProvider.notifier).state = svc.getFilenameTemplate();
  // 下载标签写入固定为：基础信息 + 封面 + 歌词（优先逐字，其次标准 LRC）。
  ref.read(tagWriteBasicInfoProvider.notifier).state = true;
  ref.read(tagWriteCoverProvider.notifier).state = true;
  ref.read(tagWriteLyricsProvider.notifier).state = true;
  ref.read(tagWriteDownloadLyricsProvider.notifier).state = false;
  ref.read(tagWriteLyricFormatProvider.notifier).state = 'word-by-word';
  ref.read(audioEffectEnabledProvider.notifier).state = svc
      .getAudioEffectEnabled();
  ref.read(audioVisualizerEnabledProvider.notifier).state = svc
      .getAudioVisualizerEnabled();
  ref.read(bassBoostEnabledProvider.notifier).state = svc.getBassBoostEnabled();
  ref.read(bassBoostGainProvider.notifier).state = svc.getBassBoostGain();
  ref.read(bassBoostPresetProvider.notifier).state = svc.getBassBoostPreset();
  ref.read(surroundEnabledProvider.notifier).state = svc.getSurroundEnabled();
  ref.read(surroundModeProvider.notifier).state = svc.getSurroundMode();
  ref.read(balanceEnabledProvider.notifier).state = svc.getBalanceEnabled();
  ref.read(balanceValueProvider.notifier).state = svc.getBalanceValue();
  ref.read(lyricFontSizeProvider.notifier).state = svc.getLyricFontSize();
  // 这些开关已从「歌词设置」移除，行为固定（不再读取用户旧设置）。
  ref.read(lyricShowTranslationProvider.notifier).state =
      LyricDisplayDefaults.showTranslation;
  ref.read(lyricShowRomanProvider.notifier).state =
      LyricDisplayDefaults.showRoman;
  ref.read(lyricEnableBlurProvider.notifier).state =
      LyricDisplayDefaults.enableBlur;
  ref.read(lyricEnableScaleProvider.notifier).state =
      LyricDisplayDefaults.enableScale;
  ref.read(lyricCenterAlignProvider.notifier).state =
      LyricDisplayDefaults.centerAlign;
  ref.read(lyricImmersiveColorProvider.notifier).state = svc
      .getLyricImmersiveColor();
  ref.read(lyricFontFamilyProvider.notifier).state =
      await _migrateLyricFontFamily(svc);
  ref.read(lyricFontRateProvider.notifier).state = await _migrateLyricFontRate(
    svc,
  );
  ref.read(lyricFontWeightProvider.notifier).state =
      await _migrateLyricFontWeight(svc);

  ref.read(lyricFontColorProvider.notifier).state = svc.getLyricFontColor();
  // 内置音源 → 优先音源（每个内置源可单独指定）
  ref.read(preferredSourceMapProvider.notifier).state = _decodePreferredSources(
    svc.getPreferredSourceMap(),
  );
  ref.read(appearanceBgAnimationProvider.notifier).state = svc
      .getAppearanceBgAnimation();
  // WebDAV / 备份配置
  try {
    final raw = svc.getWebDavConfigJson();
    if (raw.isNotEmpty) {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        ref.read(webDavConfigProvider.notifier).state = WebDavConfig.fromJson(
          decoded.map((k, v) => MapEntry('$k', v)),
        );
      }
    }
  } catch (e) {
    debugPrint('[SettingsProviders] 读取 WebDAV 配置失败: $e');
  }
  ref.read(desktopLyricSettingsProvider.notifier).state =
      DesktopLyricSettings.decode(svc.getDesktopLyricSettings());
  ref.read(autoCacheMusicProvider.notifier).state = true;
  ref.read(autoUpdateProvider.notifier).state = svc.getAutoUpdate();
  ref.read(closeToTrayProvider.notifier).state = svc.getCloseToTray();
  ref.read(pluginAutoCheckUpdateProvider.notifier).state = svc
      .getPluginAutoCheckUpdate();
  ref.read(cacheDirProvider.notifier).state = await svc.getCacheDir();
  final bgMode = svc.getFullScreenBgMode();
  ref
      .read(fullScreenBackgroundModeProvider.notifier)
      .state = FullScreenBackgroundMode.values.firstWhere(
    (e) => e.name == bgMode,
    orElse: () => FullScreenBackgroundMode.theme,
  );
});

Future<void> persistSetting(
  Ref ref,
  Future<void> Function(SettingsService svc) saveFn,
) async {
  final svc = await ref.read(settingsServiceProvider.future);
  await saveFn(svc);
}

// ---------------------------------------------------------------------------
// 歌词字体默认值迁移
//
// 歌词字体三项（字体 / 字号 / 字重）已经移进「歌词设置」，默认值改成
// 思源宋体 / 90% / 500。老用户本地存的还是旧默认值（system / 100% / 700），
// 直接读会一直沿用旧值，这里做一次性迁移。
// ---------------------------------------------------------------------------

const String _oldLyricFontFamily = 'system';
const String _defaultLyricFontFamily = 'SourceHanSerif';
const double _oldLyricFontRate = 1.0;
const double _defaultLyricFontRate = 0.9;
const int _oldLyricFontWeight = 700;
const int _defaultLyricFontWeight = 500;

Future<String> _migrateLyricFontFamily(SettingsService svc) async {
  final value = svc.getLyricFontFamily();
  if (value != _oldLyricFontFamily) return value;
  await svc.setLyricFontFamily(_defaultLyricFontFamily);
  return _defaultLyricFontFamily;
}

Future<double> _migrateLyricFontRate(SettingsService svc) async {
  final value = svc.getLyricFontRate();
  if (value != _oldLyricFontRate) return value;
  await svc.setLyricFontRate(_defaultLyricFontRate);
  return _defaultLyricFontRate;
}

Future<int> _migrateLyricFontWeight(SettingsService svc) async {
  final value = svc.getLyricFontWeight();
  if (value != _oldLyricFontWeight) return value;
  await svc.setLyricFontWeight(_defaultLyricFontWeight);
  return _defaultLyricFontWeight;
}
