import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

/// 当前生效的导航壳（StatefulNavigationShell）。
///
/// 左侧导航栏渲染在路由之外，切换一级分类时需要用到它：
/// * `goBranch(index)` 切换分支并**保留**该分支自己的页面栈
///   （分支里已打开的二级页面，切回来时自动恢复）；
/// * `goBranch(index, initialLocation: true)` 回到该分类的第一级界面。
///
/// 单独放在一个文件里，避免 `app_router.dart` 与 `app_shell.dart` 互相
/// 引用形成循环依赖。
final navigationShellProvider = StateProvider<StatefulNavigationShell?>(
  (ref) => null,
);
