import 'package:file_picker/file_picker.dart';

/// 选择一张图片（单选）。
///
/// Android 上 file_picker 默认 `allowCompression = true`：对 `FileType.image`
/// 会先按 30% 质量压缩成 JPEG，写一份到公共 Pictures 目录
/// （`JPEG_yyyyMMdd_HHmmss_xxx.jpg`），再把缓存路径返回给应用。这个 Pictures
/// 副本应用拿不到、也不会自动删除，用户只是选张封面，相册里就会多出一张副本。
///
/// 统一关闭插件压缩：需要压缩 / 缩放时由应用自己处理，避免污染相册。
Future<PlatformFile?> pickImageFile({String? dialogTitle}) async {
  final result = await FilePicker.platform.pickFiles(
    dialogTitle: dialogTitle,
    type: FileType.image,
    allowCompression: false,
  );
  if (result == null || result.files.isEmpty) return null;
  return result.files.first;
}
