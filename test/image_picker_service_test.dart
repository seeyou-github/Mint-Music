import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mintmusic/shared/services/image_picker_service.dart';

/// 记录调用参数的 file_picker 假实现。
class _RecordingFilePicker extends FilePicker {
  String? dialogTitle;
  FileType? type;
  bool? allowCompression;
  bool? allowMultiple;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    this.dialogTitle = dialogTitle;
    this.type = type;
    this.allowCompression = allowCompression;
    this.allowMultiple = allowMultiple;
    return FilePickerResult([
      PlatformFile(name: 'cover.jpg', size: 1, path: '/tmp/cover.jpg'),
    ]);
  }
}

void main() {
  test('选图统一关闭 file_picker 的 Android 默认压缩', () async {
    final picker = _RecordingFilePicker();
    FilePicker.platform = picker;

    final file = await pickImageFile(dialogTitle: '选择封面');

    expect(file?.path, '/tmp/cover.jpg');
    expect(picker.dialogTitle, '选择封面');
    expect(picker.type, FileType.image);
    // Android 上 allowCompression=true 会把压缩副本写进公共 Pictures 目录。
    expect(picker.allowCompression, isFalse);
    expect(picker.allowMultiple, isFalse);
  });
}
