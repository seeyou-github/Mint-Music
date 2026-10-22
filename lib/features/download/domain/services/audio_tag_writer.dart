import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// 纯 Dart 实现的音频标签写入器。
///
/// Android 端通过 MethodChannel（`com.mintmusic/tag_writer`）调用原生代码写
/// 标签，但 Windows 等桌面平台没有原生实现，下载完成的歌曲会缺少封面、
/// 基本信息和歌词。这里直接改写文件里的标签，行为与原生实现保持一致：
///
/// * MP3 → 写入 ID3v2.3 标签（TIT2/TPE1/TALB/TPE2/USLT/APIC）；
/// * FLAC → 写入 Vorbis Comment（TITLE/ARTIST/ALBUM/ALBUMARTIST/LYRICS）
///   与 PICTURE 元数据块。
///
/// 已存在的标签会被读取后再覆盖，未管理的帧（例如 TCON 流派）会保留。
///
/// 注意：**不会写入「流派」**。下载歌曲只写标题 / 歌手 / 专辑 / 专辑歌手 /
/// 歌词 / 封面，流派（TCON / GENRE）既不写入也不会从网络信息里带过来。
class AudioTagWriter {
  AudioTagWriter._();

  /// 写入标签，返回是否成功。
  static Future<bool> write(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? lyrics,
    Uint8List? artwork,
  }) async {
    final ext = _extOf(filePath);
    try {
      if (ext == '.mp3') {
        return await _writeId3(
          filePath,
          title: title,
          artist: artist,
          album: album,
          albumArtist: albumArtist,
          lyrics: lyrics,
          artwork: artwork,
        );
      }
      if (ext == '.flac') {
        return await _writeFlac(
          filePath,
          title: title,
          artist: artist,
          album: album,
          albumArtist: albumArtist,
          lyrics: lyrics,
          artwork: artwork,
        );
      }
      debugPrint('[AudioTagWriter] 不支持的格式，跳过: $ext');
    } catch (e) {
      debugPrint('[AudioTagWriter] 写入标签失败 ($ext): $e');
    }
    return false;
  }

  static String _extOf(String filePath) {
    final dot = filePath.lastIndexOf('.');
    if (dot < 0) return '';
    // 路径里可能混用 '/' 和 '\'（Windows 上尤其如此），两种都要判断。
    final lastSlash = filePath.lastIndexOf('/');
    final lastBackslash = filePath.lastIndexOf('\\');
    final sep = lastSlash > lastBackslash ? lastSlash : lastBackslash;
    if (dot < sep) return '';
    return filePath.substring(dot).toLowerCase();
  }

  // ==================== MP3 / ID3v2.3 ====================

  static Future<bool> _writeId3(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? lyrics,
    Uint8List? artwork,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return false;

    final raf = await file.open(mode: FileMode.read);
    List<int> audioBytes;
    final frames = <String, Uint8List>{};
    try {
      final fileLength = await raf.length();
      final header = await raf.read(10);
      var audioStart = 0;
      if (header.length == 10 && _isId3Header(header)) {
        final version = header[3];
        final flags = header[5];
        final tagSize = _synchSafeToInt(header, 6);
        final tagBytes = await raf.read(tagSize);
        // 扩展头（v2.3 的长度不含自身，v2.4 的长度含自身）
        var frameStart = 0;
        if ((flags & 0x40) != 0 && tagBytes.length >= 4) {
          frameStart = version >= 4
              ? _synchSafeToInt(tagBytes, 0)
              : 4 + _be32(tagBytes, 0);
        }
        frames.addAll(_parseId3Frames(tagBytes, frameStart, version));
        audioStart = 10 + tagSize;
      }
      await raf.setPosition(audioStart);
      final remaining = fileLength - audioStart;
      audioBytes = remaining > 0 ? await raf.read(remaining) : <int>[];
    } finally {
      await raf.close();
    }

    _putText(frames, 'TIT2', title);
    _putText(frames, 'TPE1', artist);
    _putText(frames, 'TALB', album);
    _putText(frames, 'TPE2', albumArtist);
    if (lyrics != null && lyrics.isNotEmpty) {
      frames['USLT'] = _buildUsltFrame(lyrics);
    }
    if (artwork != null && artwork.isNotEmpty) {
      frames['APIC'] = _buildApicFrame(artwork);
    }

    final body = _buildId3Body(frames);
    final out = BytesBuilder();
    out.add(_buildId3Header(body.length));
    out.add(body);
    out.add(audioBytes);

    final temp = File('$filePath.tagtmp');
    await temp.writeAsBytes(out.toBytes(), flush: true);
    await _replaceFile(temp, file);
    return true;
  }

  static bool _isId3Header(List<int> header) {
    return header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33;
  }

  static void _putText(
    Map<String, Uint8List> frames,
    String id,
    String? value,
  ) {
    if (value == null || value.isEmpty) return;
    frames[id] = _buildTextFrame(value);
  }

  /// 文本帧：编码 1（UTF-16 带 BOM），ID3v2.3 兼容性最好。
  static Uint8List _buildTextFrame(String value) {
    final text = _utf16LeWithBom(value);
    final bytes = Uint8List(1 + text.length);
    bytes[0] = 1;
    bytes.setRange(1, 1 + text.length, text);
    return bytes;
  }

  /// USLT 帧：[编码][语言 3 字节][描述符（空）][歌词文本]
  static Uint8List _buildUsltFrame(String value) {
    final text = _utf16LeWithBom(value);
    final bytes = Uint8List(1 + 3 + 2 + text.length);
    bytes[0] = 1;
    bytes.setRange(1, 4, ascii.encode('chi'));
    // 描述符为空：UTF-16 的终止符是两个 0 字节
    bytes[4] = 0;
    bytes[5] = 0;
    bytes.setRange(6, 6 + text.length, text);
    return bytes;
  }

  /// APIC 帧：[编码][MIME][0][图片类型][描述符][0][图片数据]
  static Uint8List _buildApicFrame(Uint8List image) {
    final mime = ascii.encode(_detectImageMime(image));
    final bytes = Uint8List(1 + mime.length + 1 + 1 + 1 + image.length);
    var offset = 0;
    bytes[offset++] = 0; // 编码：ISO-8859-1
    bytes.setRange(offset, offset + mime.length, mime);
    offset += mime.length;
    bytes[offset++] = 0; // MIME 结束符
    bytes[offset++] = 3; // 图片类型：3 = 封面（正面）
    bytes[offset++] = 0; // 描述符结束符
    bytes.setRange(offset, offset + image.length, image);
    return bytes;
  }

  static String _detectImageMime(Uint8List data) {
    if (data.length >= 4 &&
        data[0] == 0x89 &&
        data[1] == 0x50 &&
        data[2] == 0x4E &&
        data[3] == 0x47) {
      return 'image/png';
    }
    // RIFF....WEBP
    if (data.length >= 12 &&
        data[0] == 0x52 &&
        data[1] == 0x49 &&
        data[2] == 0x46 &&
        data[3] == 0x46 &&
        data[8] == 0x57 &&
        data[9] == 0x45 &&
        data[10] == 0x42 &&
        data[11] == 0x50) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  static Map<String, Uint8List> _parseId3Frames(
    Uint8List tag,
    int start,
    int version,
  ) {
    final frames = <String, Uint8List>{};
    var offset = start;
    while (offset + 10 <= tag.length) {
      if (tag[offset] == 0) break; // 填充区
      final id = String.fromCharCodes(tag.sublist(offset, offset + 4));
      final size = version >= 4
          ? _synchSafeToInt(tag, offset + 4)
          : _be32(tag, offset + 4);
      if (size <= 0 || offset + 10 + size > tag.length) break;
      frames[id] = Uint8List.fromList(
        tag.sublist(offset + 10, offset + 10 + size),
      );
      offset += 10 + size;
    }
    return frames;
  }

  static Uint8List _buildId3Body(Map<String, Uint8List> frames) {
    final out = BytesBuilder();
    frames.forEach((id, content) {
      if (id.length != 4) return;
      final header = Uint8List(10);
      for (var i = 0; i < 4; i++) {
        header[i] = id.codeUnitAt(i) & 0xFF;
      }
      _writeBe32At(header, 4, content.length);
      out.add(header);
      out.add(content);
    });
    return out.toBytes();
  }

  static Uint8List _buildId3Header(int bodyLength) {
    final header = Uint8List(10);
    header[0] = 0x49; // I
    header[1] = 0x44; // D
    header[2] = 0x33; // 3
    header[3] = 3; // ID3v2.3
    header[4] = 0; // 修订号
    header[5] = 0; // 标志位
    _writeSynchSafe(header, 6, bodyLength);
    return header;
  }

  static Uint8List _utf16LeWithBom(String value) {
    final units = <int>[];
    for (final rune in value.runes) {
      if (rune > 0xFFFF) {
        final v = rune - 0x10000;
        final high = 0xD800 + (v >> 10);
        final low = 0xDC00 + (v & 0x3FF);
        units.add(high);
        units.add(low);
      } else {
        units.add(rune);
      }
    }
    final bytes = Uint8List(2 + units.length * 2);
    bytes[0] = 0xFF; // BOM
    bytes[1] = 0xFE;
    for (var i = 0; i < units.length; i++) {
      bytes[2 + i * 2] = units[i] & 0xFF;
      bytes[3 + i * 2] = (units[i] >> 8) & 0xFF;
    }
    return bytes;
  }

  // ==================== FLAC ====================

  static Future<bool> _writeFlac(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? lyrics,
    Uint8List? artwork,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return false;

    final bytes = await file.readAsBytes();
    if (bytes.length < 8) return false;
    if (bytes[0] != 0x66 ||
        bytes[1] != 0x4C ||
        bytes[2] != 0x61 ||
        bytes[3] != 0x43) {
      return false; // 不是 fLaC
    }

    final blocks = <_FlacBlock>[];
    var offset = 4;
    var isLast = false;
    while (!isLast && offset + 4 <= bytes.length) {
      final headerByte = bytes[offset];
      isLast = (headerByte & 0x80) != 0;
      final type = headerByte & 0x7F;
      final length =
          (bytes[offset + 1] << 16) | (bytes[offset + 2] << 8) | bytes[offset + 3];
      final dataStart = offset + 4;
      if (dataStart + length > bytes.length) return false;
      blocks.add(_FlacBlock(type, bytes.sublist(dataStart, dataStart + length)));
      offset = dataStart + length;
    }
    final audioStart = offset;

    final newBlocks = <_FlacBlock>[];
    for (final block in blocks) {
      if (block.type == 4) continue; // 旧的 Vorbis Comment，稍后重建
      if (block.type == 6 && artwork != null && artwork.isNotEmpty) {
        continue; // 旧的图片，稍后重建
      }
      newBlocks.add(block);
    }
    newBlocks.add(
      _FlacBlock(
        4,
        _buildVorbisComment(
          title: title,
          artist: artist,
          album: album,
          albumArtist: albumArtist,
          lyrics: lyrics,
        ),
      ),
    );
    if (artwork != null && artwork.isNotEmpty) {
      newBlocks.add(_FlacBlock(6, _buildFlacPicture(artwork)));
    }

    final out = BytesBuilder();
    out.add(<int>[0x66, 0x4C, 0x61, 0x43]); // fLaC
    for (var i = 0; i < newBlocks.length; i++) {
      final block = newBlocks[i];
      final last = i == newBlocks.length - 1;
      out.add(<int>[(last ? 0x80 : 0) | block.type]);
      final len = block.data.length;
      out.add(<int>[(len >> 16) & 0xFF, (len >> 8) & 0xFF, len & 0xFF]);
      out.add(block.data);
    }
    out.add(bytes.sublist(audioStart));

    final temp = File('$filePath.tagtmp');
    await temp.writeAsBytes(out.toBytes(), flush: true);
    await _replaceFile(temp, file);
    return true;
  }

  static Uint8List _buildVorbisComment({
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? lyrics,
  }) {
    final entries = <String>[];
    void add(String key, String? value) {
      if (value == null || value.isEmpty) return;
      entries.add('$key=$value');
    }

    add('TITLE', title);
    add('ARTIST', artist);
    add('ALBUM', album);
    add('ALBUMARTIST', albumArtist);
    add('LYRICS', lyrics);

    final vendor = utf8.encode('Mint Music');
    final out = BytesBuilder();
    _writeLe32(out, vendor.length);
    out.add(vendor);
    _writeLe32(out, entries.length);
    for (final entry in entries) {
      final bytes = utf8.encode(entry);
      _writeLe32(out, bytes.length);
      out.add(bytes);
    }
    return out.toBytes();
  }

  /// FLAC PICTURE 元数据块。
  static Uint8List _buildFlacPicture(Uint8List image) {
    final mime = utf8.encode(_detectImageMime(image));
    final description = utf8.encode('Cover');
    final size = _detectImageSize(image);

    final out = BytesBuilder();
    _writeBe32(out, 3); // 图片类型：封面（正面）
    _writeBe32(out, mime.length);
    out.add(mime);
    _writeBe32(out, description.length);
    out.add(description);
    _writeBe32(out, size.width); // 宽
    _writeBe32(out, size.height); // 高
    _writeBe32(out, 24); // 颜色深度
    _writeBe32(out, 0); // 使用的颜色数
    _writeBe32(out, image.length);
    out.add(image);
    return out.toBytes();
  }

  /// 读取图片尺寸；解析失败时宽高都是 0。
  static ({int width, int height}) _detectImageSize(Uint8List data) {
    try {
      if (data.length >= 24 &&
          data[0] == 0x89 &&
          data[1] == 0x50 &&
          data[2] == 0x4E &&
          data[3] == 0x47) {
        final width =
            (data[16] << 24) | (data[17] << 16) | (data[18] << 8) | data[19];
        final height =
            (data[20] << 24) | (data[21] << 16) | (data[22] << 8) | data[23];
        return (width: width, height: height);
      }
      // JPEG：遍历段标记找 SOFn
      var i = 2;
      while (i + 9 < data.length) {
        if (data[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = data[i + 1];
        if (marker == 0xD8 ||
            marker == 0x01 ||
            (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        final segLength = (data[i + 2] << 8) | data[i + 3];
        final isSof = marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC;
        if (isSof) {
          final height = (data[i + 5] << 8) | data[i + 6];
          final width = (data[i + 7] << 8) | data[i + 8];
          return (width: width, height: height);
        }
        i += 2 + segLength;
      }
    } catch (_) {}
    return (width: 0, height: 0);
  }

  // ==================== 公共工具 ====================

  static Future<void> _replaceFile(File temp, File target) async {
    try {
      await temp.rename(target.path);
    } catch (_) {
      // 某些平台上 rename 不能覆盖已存在的文件，退化为先删后改名
      if (await target.exists()) {
        await target.delete();
      }
      await temp.rename(target.path);
    }
  }

  static int _synchSafeToInt(List<int> bytes, [int offset = 0]) {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      value = (value << 7) | (bytes[offset + i] & 0x7F);
    }
    return value;
  }

  static void _writeSynchSafe(Uint8List target, int offset, int value) {
    target[offset] = (value >> 21) & 0x7F;
    target[offset + 1] = (value >> 14) & 0x7F;
    target[offset + 2] = (value >> 7) & 0x7F;
    target[offset + 3] = value & 0x7F;
  }

  static int _be32(List<int> bytes, [int offset = 0]) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static void _writeBe32(BytesBuilder out, int value) {
    out.add(<int>[
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ]);
  }

  /// 以大端序写入 32 位整数到指定偏移。
  static void _writeBe32At(Uint8List target, int offset, int value) {
    target[offset] = (value >> 24) & 0xFF;
    target[offset + 1] = (value >> 16) & 0xFF;
    target[offset + 2] = (value >> 8) & 0xFF;
    target[offset + 3] = value & 0xFF;
  }

  static void _writeLe32(BytesBuilder out, int value) {
    out.add(<int>[
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ]);
  }
}

/// FLAC 元数据块。
class _FlacBlock {
  final int type;
  final List<int> data;

  const _FlacBlock(this.type, this.data);
}
