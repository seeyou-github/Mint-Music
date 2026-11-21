import 'package:flutter/foundation.dart';

/// 根级覆盖页（播放详情 / 歌词 / 标签编辑）的登记表。
///
/// 这些页面压在根 Navigator 上、盖住整个内容区。go_router 的
/// `routerDelegate.currentConfiguration.uri` **不含任何 push() 推入的页面**
/// （ImperativeRouteMatch 不参与 uri，见 RouteMatchList.uri 的源码注释），
/// 无法用来判断「覆盖页是否开着」，因此由页面自己在 initState / dispose
/// 里登记。
///
/// 同一个页面可能被连续推入两份（上层实例关闭时下层还开着），布尔值会把
/// 状态记错，因此用「每个实例一条记录」。
class RootOverlayTracker extends ChangeNotifier {
  RootOverlayTracker._();

  static final RootOverlayTracker instance = RootOverlayTracker._();

  /// 播放详情页。
  static const String fullPlayer = 'fullPlayer';

  /// 全屏歌词页。
  static const String lyric = 'lyric';

  /// 标签编辑页。
  static const String tagEditor = 'tagEditor';

  final List<String> _stack = [];

  /// 是否有根级覆盖页盖在内容区上。
  bool get isCovered => _stack.isNotEmpty;

  /// 页面打开时登记（initState 调用）。
  void retain(String id) {
    _stack.add(id);
    notifyListeners();
  }

  /// 页面销毁时注销（dispose 调用）。重复注销是安全的。
  void release(String id) {
    final index = _stack.lastIndexOf(id);
    if (index == -1) return;
    _stack.removeAt(index);
    notifyListeners();
  }

  /// 调用方即将 pop 栈顶覆盖页：先把登记摘掉。
  ///
  /// 页面 dispose 要等出栈动画结束才触发，不先摘的话「还有没有覆盖页」
  /// 的判断会一直为真，连续 pop 的循环会把下面的页面也弹掉。
  /// 之后再触发的 [release] 只是空操作。返回被摘掉的栈顶 id。
  String? willPopTop() {
    if (_stack.isEmpty) return null;
    final id = _stack.removeLast();
    notifyListeners();
    return id;
  }
}
