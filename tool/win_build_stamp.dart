// 生成 Windows 版本资源需要的「编译时间」，由 CMake 在配置阶段调用。
//
//   dart tool/win_build_stamp.dart <输出头文件路径>
//
// 时间固定取**北京时间（UTC+8）**，与构建机所在时区无关：
// GitHub Actions 的 windows runner 是 UTC，本地开发机一般在东八区，两边
// 生成的字符串必须是同一个口径，否则同一个提交会产出两种「编译时间」。
//
// 输出两份宏：
//   APP_BUILD_STAMP  —— 给人看的字符串，年.月日.时分（如 2026.1110.0106）；
//   APP_FILE_VERSION —— 给 FILEVERSION 用的四段数字，年,月,日,时分
//                       （每段都必须 ≤ 65535，时分用 HH*100+MM，最大 2359）。
import 'dart:io';

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln('用法: dart tool/win_build_stamp.dart <输出头文件路径>');
    exitCode = 2;
    return;
  }

  // 北京时间 = UTC + 8，不依赖构建机的本地时区设置。
  final now = DateTime.now().toUtc().add(const Duration(hours: 8));
  String two(int value) => value.toString().padLeft(2, '0');

  final stamp =
      '${now.year}.${two(now.month)}${two(now.day)}.'
      '${two(now.hour)}${two(now.minute)}';
  final number =
      '${now.year},${now.month},${now.day},${now.hour * 100 + now.minute}';

  final content =
      '// 由 tool/win_build_stamp.dart 生成，请勿手改。\n'
      '// 每次构建（CMake 配置阶段）重新生成，内容是北京时间。\n'
      '#define APP_BUILD_STAMP "$stamp"\n'
      '#define APP_FILE_VERSION $number\n';

  final target = File(args.first);
  target.parent.createSync(recursive: true);
  target.writeAsStringSync(content);
  stdout.writeln('build stamp: $stamp');
}
