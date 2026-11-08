import 'dart:io';

/// 把 `pubspec.yaml` 里 `version: X.Y.Z+N` 的 build number 加一。
///
/// 由 `windows/runner/CMakeLists.txt` 在每次编译成功后调用（POST_BUILD），
/// 所以每编译一次，下一次构建的版本号就会 +1；构建失败不会递增。
///
/// 手动执行：`dart run tool/bump_build_number.dart`
void main() {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) {
    stderr.writeln('[bump] 找不到 pubspec.yaml（需要在仓库根目录执行）');
    exitCode = 1;
    return;
  }
  final text = file.readAsStringSync();
  final pattern = RegExp(
    r'^version:[ \t]*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)[ \t]*$',
    multiLine: true,
  );
  final match = pattern.firstMatch(text);
  if (match == null) {
    stderr.writeln('[bump] pubspec.yaml 里没有 `version: x.y.z+n` 形式的版本号');
    exitCode = 1;
    return;
  }
  final base = match.group(1)!;
  final next = int.parse(match.group(2)!) + 1;
  file.writeAsStringSync(
    text.replaceFirst(match.group(0)!, 'version: $base+$next'),
  );
  stdout.writeln('[bump] version: $base+$next');
}
