import '../../../../shared/services/config_image_store.dart';

/// 电台封面缓存：把用户填的封面（本地图片 / 网络地址）落到
/// `AppData/config/radio_covers`，之后离线也能显示。
///
/// 放在配置目录而不是缓存目录：缓存目录可能被「清理缓存」清掉，封面属于
/// 用户配置，不该跟着缓存一起消失。具体实现在 [ConfigImageStore]。
class RadioCoverCache {
  const RadioCoverCache._();

  static const ConfigImageStore _store = ConfigImageStore('radio_covers');

  /// 缓存封面，返回本地路径；失败返回 null。
  static Future<String?> cache(String source) => _store.cache(source);

  /// 删除某个封面文件（电台被删 / 换封面时调用）。
  static Future<void> remove(String? path) => _store.remove(path);
}
