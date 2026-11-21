import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// ── FFI 签名（version.dll） ─────────────────────────────────────────────────
typedef _GetFileVersionInfoSizeWNative =
    Uint32 Function(Pointer<Utf16>, Pointer<Uint32>);
typedef _GetFileVersionInfoSizeWDart =
    int Function(Pointer<Utf16>, Pointer<Uint32>);

typedef _GetFileVersionInfoWNative =
    Int32 Function(Pointer<Utf16>, Uint32, Uint32, Pointer<Void>);
typedef _GetFileVersionInfoWDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>);

typedef _VerQueryValueWNative =
    Int32 Function(
      Pointer<Void>,
      Pointer<Utf16>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint32>,
    );
typedef _VerQueryValueWDart =
    int Function(
      Pointer<Void>,
      Pointer<Utf16>,
      Pointer<Pointer<Uint8>>,
      Pointer<Uint32>,
    );

/// 读取 exe 版本资源里的 `FileVersion` 字符串。
///
/// 为什么不用文件修改时间：GitHub Actions 打的 zip 里存的是 UTC 时间，Windows
/// 解压后按本地时间解释，exe 的修改时间会整体偏 8 小时；而版本资源是**编译时
/// 写死在 exe 里的**，解压、拷贝、改名都不会变，所以它才是「这个 exe 是哪一次
/// 编译出来的」的可靠来源（写入方见 `windows/runner/Runner.rc` 与
/// `tool/win_build_stamp.dart`）。
///
/// 只在 Windows 上有意义；读不到（非 Windows、文件没有版本资源、API 失败）
/// 一律返回 null，由调用方兜底。
String? readWindowsFileVersion([String? executablePath]) {
  if (!Platform.isWindows) return null;
  final path = executablePath ?? Platform.resolvedExecutable;

  Pointer<Utf16> pathPtr = nullptr;
  Pointer<Uint8> block = nullptr;
  Pointer<Pointer<Uint8>> valuePtr = nullptr;
  Pointer<Uint32> valueLengthPtr = nullptr;
  try {
    final library = DynamicLibrary.open('version.dll');
    final getSize = library
        .lookupFunction<
          _GetFileVersionInfoSizeWNative,
          _GetFileVersionInfoSizeWDart
        >('GetFileVersionInfoSizeW');
    final getInfo = library
        .lookupFunction<_GetFileVersionInfoWNative, _GetFileVersionInfoWDart>(
          'GetFileVersionInfoW',
        );
    final queryValue = library
        .lookupFunction<_VerQueryValueWNative, _VerQueryValueWDart>(
          'VerQueryValueW',
        );

    pathPtr = path.toNativeUtf16();
    final ignored = calloc<Uint32>();
    final size = getSize(pathPtr, ignored);
    calloc.free(ignored);
    if (size == 0) return null;

    block = calloc<Uint8>(size);
    if (getInfo(pathPtr, 0, size, block.cast<Void>()) == 0) return null;

    valuePtr = calloc<Pointer<Uint8>>();
    valueLengthPtr = calloc<Uint32>();

    // 先问语言 / 代码页（不同工具链的翻译块 id 不一样），再拼出字符串块路径。
    var language = 0x0409;
    var codePage = 0x04e4;
    final translationKey = r'\VarFileInfo\Translation'.toNativeUtf16();
    try {
      if (queryValue(
            block.cast<Void>(),
            translationKey,
            valuePtr,
            valueLengthPtr,
          ) !=
          0) {
        final words = valuePtr.value.cast<Uint16>();
        language = words[0];
        codePage = words[1];
      }
    } finally {
      calloc.free(translationKey);
    }

    String hex4(int value) => value.toRadixString(16).padLeft(4, '0');
    final key =
        '\\StringFileInfo\\${hex4(language)}${hex4(codePage)}\\FileVersion';
    final keyPtr = key.toNativeUtf16();
    try {
      if (queryValue(block.cast<Void>(), keyPtr, valuePtr, valueLengthPtr) ==
          0) {
        return null;
      }
      final text = valuePtr.value.cast<Utf16>().toDartString(
        length: valueLengthPtr.value,
      );
      // VerQueryValue 给的长度把结尾的 \0 也算进去了，去掉。
      return text.replaceAll('\u0000', '').trim();
    } finally {
      calloc.free(keyPtr);
    }
  } catch (_) {
    // 任何原生调用失败都只是「没有版本信息」，交给调用方兜底。
    return null;
  } finally {
    if (pathPtr != nullptr) calloc.free(pathPtr);
    if (block != nullptr) calloc.free(block);
    if (valuePtr != nullptr) calloc.free(valuePtr);
    if (valueLengthPtr != nullptr) calloc.free(valueLengthPtr);
  }
}
