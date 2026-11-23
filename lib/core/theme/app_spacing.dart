class AppSpacing {
  AppSpacing._();

  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double xxxl = 32.0;
  static const double huge = 48.0;

  /// 桌面端一级页面（发现 / 收藏 / 本地 / 我的）顶部的垂直留白。
  ///
  /// 原来是 [md]（12）：窗口顶部到页面标题那一条空白太厚，按「减少 90%」
  /// 压到 1.2。Android 顶部有状态栏，仍用 [md]。
  static const double pageTopTight = 1.2;

  /// 桌面端紧跟在顶部标题下面的行间距（原 [sm] 8，减少 90%）。
  static const double gapTight = 0.8;

  /// 侧栏 Logo 区上下的留白（原上下 16 / 24，减少 90%）。
  static const double sidebarTopTight = 2.0;

  static const double miniPlayerHeight = 64.0;
  static const double bottomNavHeight = 56.0;
  static const double albumArtSmall = 48.0;
  static const double albumArtMedium = 200.0;
  static const double albumArtLarge = 280.0;
}

class AppRadius {
  AppRadius._();

  static const double xs = 4.0;
  static const double sm = 8.0;
  static const double md = 12.0;
  static const double lg = 16.0;
  static const double xl = 20.0;
  static const double xxl = 24.0;
  static const double full = 999.0;
}

class AppElevation {
  AppElevation._();

  static const double none = 0.0;
  static const double low = 2.0;
  static const double medium = 4.0;
  static const double high = 8.0;
  static const double glass = 1.0;
}
