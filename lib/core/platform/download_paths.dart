import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../constants/app_constants.dart';
import 'app_paths.dart';

/// Android 公共音乐目录（MediaStore 可见）。
const String _androidMusicDir = '/storage/emulated/0/Music';

/// 旧版本在所有平台都使用的默认下载目录。
///
/// 在 Windows 上以 `/` 开头属于「当前盘符」的相对路径，会被解析成
/// `<当前盘符>:\storage\emulated\0\Music\MintMusic`。仅用于识别/迁移旧数据。
const String legacyAndroidDownloadDir = '/storage/emulated/0/Music/MintMusic';

/// 同步可用的默认下载目录。
///
/// 只用于 provider / repository 的初始占位值，真正的默认目录由
/// [defaultDownloadDir] 通过 path_provider 解析。
String defaultDownloadDirSync() {
  if (Platform.isAndroid) {
    return p.posix.join(_androidMusicDir, AppConstants.downloadDirName);
  }
  if (Platform.isWindows) {
    // Windows：默认下载目录放在应用自己的 AppData\music 下。
    final base = AppPaths.executableDirectory;
    if (base != null && base.isNotEmpty) {
      return p.join(base, AppPaths.rootFolderName, AppPaths.musicFolderName);
    }
  }
  final home =
      Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    return p.join(home, 'Downloads', AppConstants.downloadDirName);
  }
  return p.join(Directory.systemTemp.path, AppConstants.downloadDirName);
}

/// 当前平台的默认歌曲下载目录。
///
/// - Android：`/storage/emulated/0/Music/MintMusic`
/// - iOS：应用 Documents 下的 `MintMusic`
/// - Windows：`<exe 所在目录>\AppData\music`
/// - macOS/Linux：系统「下载」目录下的 `MintMusic`
Future<String> defaultDownloadDir() async {
  if (Platform.isAndroid) return defaultDownloadDirSync();

  if (Platform.isWindows) {
    try {
      final dir = await AppPaths.musicDirectory();
      return dir.path;
    } catch (_) {}
  }

  try {
    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      return p.join(docs.path, AppConstants.downloadDirName);
    }
    final downloads = await getDownloadsDirectory();
    if (downloads != null && downloads.path.isNotEmpty) {
      return p.join(downloads.path, AppConstants.downloadDirName);
    }
  } catch (_) {}

  try {
    final docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, AppConstants.downloadDirName);
  } catch (_) {}

  return defaultDownloadDirSync();
}
