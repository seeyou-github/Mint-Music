abstract class AppConstants {
  AppConstants._();

  static const String appName = 'Music';
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
