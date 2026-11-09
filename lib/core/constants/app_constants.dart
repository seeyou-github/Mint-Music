abstract class AppConstants {
  AppConstants._();

  static const String appName = 'Music';

  /// 语义化版本号。
  ///
  /// Windows 的「我的」页面显示的是编译时间（见 `appVersionProvider`），这个
  /// 常量在那边只用于更新检查；Android 上仍然直接显示它。
  static const String appVersion = '2.0.0';

  static const int defaultPageSize = 30;
  static const int maxRetryCount = 3;
  static const Duration connectTimeout = Duration(seconds: 15);
  static const Duration receiveTimeout = Duration(seconds: 30);

  static const String defaultMusicSource = 'wy';
  static const String defaultQuality = '128k';

  static const int maxDownloadConcurrent = 3;
  static const String downloadDirName = 'MintMusic';
}
