import 'package:flutter/foundation.dart';

import '../../library/domain/models/recently_played.dart';

/// 「这次播放是从哪里点开的」——歌单 / 专辑 / 榜单 / 搜索结果。
///
/// 播放动作散落在各个页面（歌单详情、搜索、榜单、本地列表…），播放控制器
/// 拿不到页面上下文，所以由这些页面在开始播放前调用 [set] 记录一下，
/// 播放控制器在真正开始播放时读取，写进「最近播放」。
///
/// 只在内存里，切歌 / 播放失败都不会清掉：下一次播放会重新 set。
/// 侧边栏播放器的来源标签监听本对象，来源变化时立即刷新。
class PlaybackContext extends ChangeNotifier {
  PlaybackContext._();

  static final PlaybackContext instance = PlaybackContext._();

  PlaybackSourceType type = PlaybackSourceType.unknown;
  String? id;
  String? name;

  /// 来源的完整信息（专辑 / 作者主页），用于「最近播放」里再次打开。
  Map<String, dynamic>? sourceMeta;

  /// 设置当前播放来源。[id] 为歌单 / 专辑 / 榜单的 id。
  void set(
    PlaybackSourceType type, {
    String? id,
    String? name,
    Map<String, dynamic>? sourceMeta,
  }) {
    this.type = type;
    this.id = id;
    this.name = name;
    this.sourceMeta = sourceMeta;
    notifyListeners();
  }

  /// 从本地列表等没有来源的场景播放时调用。
  void clear() {
    type = PlaybackSourceType.unknown;
    id = null;
    name = null;
    sourceMeta = null;
    notifyListeners();
  }
}
