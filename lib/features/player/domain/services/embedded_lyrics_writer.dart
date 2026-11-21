import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// 把歌词写回**本地音频文件**（覆盖原有的内嵌歌词）。
///
/// 支持：
/// * `.mp3` → ID3v2 的 `USLT`（无标签时新建 v2.3 标签）；
/// * `.flac` → Vorbis comment 的 `LYRICS`。
///
/// 其它容器（m4a / ogg / ape / wav …）暂不支持，返回 false 由调用方提示。
///
/// 写入策略：
/// 1. **原地覆盖**（首选）：新标签能塞进原来的标签空间时只改文件头部，
///    音频数据一个字节都不动——这样文件正被播放器占用时也能写。
/// 2. 塞不下 / 原地写失败 → 复制到临时文件再原子替换（要求文件未被占用）。
class EmbeddedLyricsWriter {
  const EmbeddedLyricsWriter._();

  /// 返回 true 表示已经成功写进文件。
  static Future<bool> write(String filePath, String lyric) async {
    final text = lyric.trim();
    if (text.isEmpty) return false;
    final file = File(filePath);
    if (!await file.exists()) return false;

    final lower = filePath.toLowerCase();
    try {
      if (lower.endsWith('.flac')) {
        return _writeFlac(file, text);
      }
      if (lower.endsWith('.mp3')) {
        return _writeId3(file, text);
      }
      debugPrint('[EmbeddedLyricsWriter] 不支持的格式: $filePath');
      return false;
    } catch (e) {
      debugPrint('[EmbeddedLyricsWriter] 写入失败: $e');
      return false;
    }
  }

  // ---------------------------------------------------------------- MP3 / ID3

  static Future<bool> _writeId3(File file, String lyric) async {
    var versionMajor = 3;
    var hasTag = false;
    var tagSize = 0;
    var tagTotalSize = 0;
    var frames = <Uint8List>[];

    // 先只读取元信息，读完立刻关闭——Windows 下文件被占用时无法重命名。
    final source = await file.open(mode: FileMode.read);
    try {
      final header = await source.read(10);
      if (header.length == 10 && _ascii(header.sublist(0, 3)) == 'ID3') {
        hasTag = true;
        versionMajor = header[3] == 4 ? 4 : 3;
        tagSize = _synchsafeToInt(header.sublist(6, 10));
        final flags = header[5];
        // v2.4 的 footer 会多占 10 字节
        final footerSize = (versionMajor == 4 && (flags & 0x10) != 0) ? 10 : 0;
        tagTotalSize = 10 + tagSize + footerSize;

        final body = await source.read(tagSize);
        frames = _collectFrames(body, versionMajor);
      }
    } finally {
      await source.close();
    }

    final content = BytesBuilder();
    for (final frame in frames) {
      content.add(frame);
    }
    content.add(_buildUsltFrame(lyric, versionMajor));
    var contentBytes = content.takeBytes();

    // 1) 原地覆盖：把标签补零到原来的大小，只重写文件头
    if (hasTag && contentBytes.length <= tagSize) {
      if (contentBytes.length < tagSize) {
        final padded = Uint8List(tagSize)
          ..setRange(0, contentBytes.length, contentBytes);
        contentBytes = padded;
      }
      final header = BytesBuilder();
      header.add([0x49, 0x44, 0x33, versionMajor, 0x00, 0x00]);
      header.add(_intToSynchsafe(tagSize));
      header.add(contentBytes);
      if (await _overwriteInPlace(file, header.takeBytes())) return true;
      // 原地写失败（只读 / 被独占）就落到下面的重写流程
    }

    // 2) 复制重写
    final header = BytesBuilder();
    header.add([0x49, 0x44, 0x33, versionMajor, 0x00, 0x00]);
    header.add(_intToSynchsafe(contentBytes.length));
    header.add(contentBytes);
    return _rewrite(
      file: file,
      newPrefix: header.takeBytes(),
      copyFrom: hasTag ? tagTotalSize : 0,
    );
  }

  /// 把原标签里的帧原样搬过来（跳过旧的 USLT）。
  static List<Uint8List> _collectFrames(Uint8List body, int versionMajor) {
    final frames = <Uint8List>[];
    var offset = 0;
    while (offset + 10 <= body.length) {
      if (body[offset] == 0) break; // 进入 padding
      final id = _ascii(body.sublist(offset, offset + 4));
      if (!RegExp(r'^[A-Z0-9]{4}$').hasMatch(id)) break;

      final size = versionMajor >= 4
          ? _synchsafeToInt(body.sublist(offset + 4, offset + 8))
          : _bytesToInt(body.sublist(offset + 4, offset + 8));
      if (size < 0 || offset + 10 + size > body.length) break;

      final end = offset + 10 + size;
      if (id != 'USLT') {
        frames.add(Uint8List.sublistView(body, offset, end));
      }
      offset = end;
    }
    return frames;
  }

  static Uint8List _buildUsltFrame(String lyric, int versionMajor) {
    final payload = BytesBuilder();
    if (versionMajor >= 4) {
      // ID3v2.4 支持 UTF-8（编码 3）
      payload.addByte(0x03);
      payload.add(ascii.encode('und'));
      payload.addByte(0x00); // 空描述符
      payload.add(utf8.encode(lyric));
    } else {
      // ID3v2.3 用 UTF-16 + BOM
      payload.addByte(0x01);
      payload.add(ascii.encode('und'));
      payload.add([0xFF, 0xFE, 0x00, 0x00]); // BOM + 空描述符终止符
      payload.add([0xFF, 0xFE]); // 正文的 BOM
      payload.add(_utf16LeBytes(lyric));
    }
    final data = payload.takeBytes();

    final frame = BytesBuilder();
    frame.add(ascii.encode('USLT'));
    frame.add(
      versionMajor >= 4
          ? _intToSynchsafe(data.length)
          : _intToBytes(data.length, 4),
    );
    frame.add([0x00, 0x00]); // flags
    frame.add(data);
    return frame.takeBytes();
  }

  static List<int> _utf16LeBytes(String text) {
    final units = text.codeUnits;
    final bytes = <int>[];
    for (final unit in units) {
      bytes.add(unit & 0xFF);
      bytes.add((unit >> 8) & 0xFF);
    }
    return bytes;
  }

  // -------------------------------------------------------------------- FLAC

  static Future<bool> _writeFlac(File file, String lyric) async {
    final blocks = <_FlacBlock>[];
    var audioStart = 0;

    final source = await file.open(mode: FileMode.read);
    try {
      final magic = await source.read(4);
      if (magic.length < 4 || _ascii(magic) != 'fLaC') return false;

      var lastBlock = false;
      while (!lastBlock) {
        final header = await source.read(4);
        if (header.length < 4) return false;
        lastBlock = (header[0] & 0x80) != 0;
        final type = header[0] & 0x7F;
        final size = (header[1] << 16) | (header[2] << 8) | header[3];
        final data = await source.read(size);
        if (data.length < size) return false;
        blocks.add(_FlacBlock(type: type, data: Uint8List.fromList(data)));
      }
      audioStart = await source.position();
    } finally {
      await source.close();
    }

    final oldMetaLength = audioStart - 4; // 去掉 'fLaC'

    // 组装新块：替换 Vorbis comment（没有就新建），丢掉旧 padding
    final kept = <_FlacBlock>[];
    Uint8List? newComment;
    for (final block in blocks) {
      if (block.type == 4 && newComment == null) {
        newComment = _rebuildVorbisComment(block.data, lyric);
        continue;
      }
      if (block.type == 1) continue; // 旧 padding
      kept.add(block);
    }
    newComment ??= _buildVorbisComment(lyric);

    // 1) 原地覆盖：用 padding 把总长度补回原来的元数据长度
    final fixedLength = kept.fold<int>(0, (sum, b) => sum + 4 + b.data.length);
    final paddingLength = oldMetaLength - fixedLength - 4 - newComment.length - 4;
    if (paddingLength >= 0) {
      final out = <_FlacBlock>[...kept, _FlacBlock(type: 4, data: newComment)];
      if (paddingLength > 0) {
        out.add(_FlacBlock(type: 1, data: Uint8List(paddingLength)));
      }
      final prefix = _encodeFlacMeta(out);
      if (prefix.length == audioStart) {
        if (await _overwriteInPlace(file, prefix)) return true;
      }
    }

    // 2) 复制重写：末尾补 512 字节 padding，方便以后再改
    final out = <_FlacBlock>[
      ...kept,
      _FlacBlock(type: 4, data: newComment),
      _FlacBlock(type: 1, data: Uint8List(512)),
    ];
    return _rewrite(
      file: file,
      newPrefix: _encodeFlacMeta(out),
      copyFrom: audioStart,
    );
  }

  static Uint8List _encodeFlacMeta(List<_FlacBlock> blocks) {
    final header = BytesBuilder();
    header.add(ascii.encode('fLaC'));
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      final isLast = i == blocks.length - 1;
      header.addByte((isLast ? 0x80 : 0x00) | block.type);
      header.add([
        (block.data.length >> 16) & 0xFF,
        (block.data.length >> 8) & 0xFF,
        block.data.length & 0xFF,
      ]);
      header.add(block.data);
    }
    return header.takeBytes();
  }

  /// 在已有 Vorbis comment 里替换 / 追加 LYRICS（其它字段原样保留）。
  static Uint8List _rebuildVorbisComment(Uint8List data, String lyric) {
    var offset = 0;
    if (data.length < 8) return _buildVorbisComment(lyric);

    final vendorLength = _readLE32(data, offset);
    offset += 4;
    if (vendorLength < 0 || offset + vendorLength + 4 > data.length) {
      return _buildVorbisComment(lyric);
    }
    final vendor = Uint8List.sublistView(data, offset, offset + vendorLength);
    offset += vendorLength;
    final count = _readLE32(data, offset);
    offset += 4;

    final comments = <String>[];
    for (var i = 0; i < count && offset + 4 <= data.length; i++) {
      final length = _readLE32(data, offset);
      offset += 4;
      if (length < 0 || offset + length > data.length) break;
      final bytes = Uint8List.sublistView(data, offset, offset + length);
      offset += length;
      try {
        final text = utf8.decode(bytes);
        final lower = text.toLowerCase();
        // 旧的歌词字段全部丢掉，等会儿统一写一条
        if (lower.startsWith('lyrics=') ||
            lower.startsWith('unsyncedlyrics=') ||
            lower.startsWith('lyrics-')) {
          continue;
        }
        comments.add(text);
      } catch (_) {
        // 非 UTF-8 的字段直接丢弃
      }
    }
    comments.add('LYRICS=$lyric');
    return _encodeVorbisComment(vendor, comments);
  }

  static Uint8List _buildVorbisComment(String lyric) =>
      _encodeVorbisComment(utf8.encode('MintMusic'), ['LYRICS=$lyric']);

  static Uint8List _encodeVorbisComment(
    List<int> vendor,
    List<String> comments,
  ) {
    final builder = BytesBuilder();
    builder.add(_intToLE32(vendor.length));
    builder.add(vendor);
    builder.add(_intToLE32(comments.length));
    for (final comment in comments) {
      final bytes = utf8.encode(comment);
      builder.add(_intToLE32(bytes.length));
      builder.add(bytes);
    }
    return builder.takeBytes();
  }

  // ------------------------------------------------------------------ 公共

  /// 从文件开头原地覆盖（不截断），用于标签大小不变的场景。
  ///
  /// 只有 Windows 需要这条路：那边不允许重命名「正被播放器打开」的文件，
  /// 但只要句柄允许共享写，覆盖前几个字节是没问题的。
  /// 其它平台直接走「复制 + 原子替换」——POSIX 允许重命名打开中的文件。
  ///
  /// 注意：`FileMode.writeOnly` 会截断文件，必须用 `append` 打开再 seek 回去。
  static Future<bool> _overwriteInPlace(File file, Uint8List prefix) async {
    if (!Platform.isWindows) return false;
    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.append);
      await raf.setPosition(0);
      await raf.writeFrom(prefix);
      await raf.flush();
      return true;
    } catch (e) {
      debugPrint('[EmbeddedLyricsWriter] 原地写入失败: $e');
      return false;
    } finally {
      try {
        await raf?.close();
      } catch (_) {}
    }
  }

  /// 用 [newPrefix] + 原文件 [copyFrom] 之后的内容替换原文件。
  static Future<bool> _rewrite({
    required File file,
    required Uint8List newPrefix,
    required int copyFrom,
  }) async {
    final temp = File('${file.path}.lyrictmp');
    final backup = File('${file.path}.lyricbak');
    RandomAccessFile? out;
    RandomAccessFile? source;
    try {
      if (await temp.exists()) await temp.delete();
      source = await file.open(mode: FileMode.read);
      await source.setPosition(copyFrom);
      out = await temp.open(mode: FileMode.write);
      await out.writeFrom(newPrefix);

      while (true) {
        final chunk = await source.read(1 << 20);
        if (chunk.isEmpty) break;
        await out.writeFrom(chunk);
      }
      await out.flush();
      await out.close();
      out = null;
      // Windows 下必须先关闭原文件才能重命名
      await source.close();
      source = null;

      // 原文件 → 备份，临时文件 → 原文件；失败时还原
      if (await backup.exists()) await backup.delete();
      await file.rename(backup.path);
      try {
        await temp.rename(file.path);
      } catch (e) {
        await backup.rename(file.path);
        rethrow;
      }
      try {
        await backup.delete();
      } catch (_) {}
      return true;
    } catch (e) {
      debugPrint('[EmbeddedLyricsWriter] 重写文件失败: $e');
      if (out != null) {
        try {
          await out.close();
        } catch (_) {}
      }
      if (source != null) {
        try {
          await source.close();
        } catch (_) {}
      }
      if (await temp.exists()) {
        try {
          await temp.delete();
        } catch (_) {}
      }
      if (!await file.exists() && await backup.exists()) {
        try {
          await backup.rename(file.path);
        } catch (_) {}
      }
      return false;
    }
  }

  static String _ascii(List<int> bytes) {
    try {
      return ascii.decode(bytes, allowInvalid: true);
    } catch (_) {
      return '';
    }
  }

  static int _synchsafeToInt(List<int> bytes) {
    var value = 0;
    for (final byte in bytes) {
      value = (value << 7) | (byte & 0x7F);
    }
    return value;
  }

  static int _bytesToInt(List<int> bytes) {
    var value = 0;
    for (final byte in bytes) {
      value = (value << 8) | byte;
    }
    return value;
  }

  static int _readLE32(Uint8List data, int offset) {
    if (offset + 4 > data.length) return 0;
    return data[offset] |
        (data[offset + 1] << 8) |
        (data[offset + 2] << 16) |
        (data[offset + 3] << 24);
  }

  static Uint8List _intToSynchsafe(int value) {
    return Uint8List.fromList([
      (value >> 21) & 0x7F,
      (value >> 14) & 0x7F,
      (value >> 7) & 0x7F,
      value & 0x7F,
    ]);
  }

  static Uint8List _intToBytes(int value, int length) {
    final bytes = Uint8List(length);
    for (var i = 0; i < length; i++) {
      bytes[i] = (value >> (8 * (length - 1 - i))) & 0xFF;
    }
    return bytes;
  }

  static Uint8List _intToLE32(int value) {
    return Uint8List.fromList([
      value & 0xFF,
      (value >> 8) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 24) & 0xFF,
    ]);
  }
}

class _FlacBlock {
  final int type;
  final Uint8List data;
  const _FlacBlock({required this.type, required this.data});
}
