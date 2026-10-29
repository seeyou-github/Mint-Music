import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

/// 本地音乐文件的元信息。
class LocalAudioMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final int? year;
  final int? durationSeconds;
  final Uint8List? artwork;

  /// 文件里内嵌的歌词（ID3 的 USLT / FLAC 的 LYRICS / MP4 的 ©lyr）。
  final String? lyrics;

  /// 流派（ID3 的 TCON / Vorbis 的 GENRE / MP4 的 ©gen / WAV 的 IGNR）。
  final String? genre;

  /// 注释 / 备注（ID3 的 COMM / Vorbis 的 COMMENT / MP4 的 ©cmt）。
  final String? comment;

  const LocalAudioMetadata({
    this.title,
    this.artist,
    this.album,
    this.year,
    this.durationSeconds,
    this.artwork,
    this.lyrics,
    this.genre,
    this.comment,
  });

  bool get isEmpty =>
      (title == null || title!.isEmpty) &&
      (artist == null || artist!.isEmpty) &&
      (album == null || album!.isEmpty) &&
      (genre == null || genre!.isEmpty) &&
      (comment == null || comment!.isEmpty) &&
      durationSeconds == null;
}

/// 纯 Dart 的音频元信息读取器。
///
/// 桌面端（Windows/macOS/Linux）没有 MediaStore，`on_audio_query` 插件不可用，
/// 这里直接解析文件里的标签，拿到标题 / 歌手 / 专辑 / 时长 / 内嵌封面：
///
/// * MP3 → ID3v2.2/2.3/2.4 标签 + MPEG 帧头计算时长；
/// * FLAC → STREAMINFO 时长 + Vorbis Comment + PICTURE 封面；
/// * M4A/MP4 → `moov/udta/meta/ilst` 标签 + `mvhd` 时长；
/// * WAV → `fmt `/`data` 块计算时长 + `LIST/INFO` 标签；
/// * OGG → Vorbis Comment + 末页 granule 计算时长。
class LocalMetadataReader {
  LocalMetadataReader._();

  static const Set<String> audioExtensions = {
    '.mp3',
    '.flac',
    '.m4a',
    '.aac',
    '.mp4',
    '.wav',
    '.ogg',
    '.oga',
    '.wma',
    '.ape',
  };

  static bool isAudioFile(String path) {
    final ext = extensionOf(path);
    return ext.isNotEmpty && audioExtensions.contains(ext);
  }

  static String extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) return '';
    final sep = path.lastIndexOf(Platform.pathSeparator);
    if (dot < sep) return '';
    return path.substring(dot).toLowerCase();
  }

  /// 读取音频文件的元信息；解析失败时返回空结果。
  static Future<LocalAudioMetadata> read(String filePath) async {
    try {
      final ext = extensionOf(filePath);
      final file = File(filePath);
      if (!await file.exists()) return const LocalAudioMetadata();
      final raf = await file.open(mode: FileMode.read);
      try {
        final length = await raf.length();
        switch (ext) {
          case '.mp3':
            return await _readMp3(raf, length);
          case '.flac':
            return await _readFlac(raf, length);
          case '.m4a':
          case '.mp4':
          case '.aac':
            return await _readMp4(raf, length);
          case '.wav':
            return await _readWav(raf, length);
          case '.ogg':
          case '.oga':
            return await _readOgg(raf, length);
          default:
            return const LocalAudioMetadata();
        }
      } finally {
        await raf.close();
      }
    } catch (e) {
      debugPrint('[LocalMetadata] 读取失败 $filePath: $e');
    }
    return const LocalAudioMetadata();
  }

  // ==================== MP3 ====================

  static Future<LocalAudioMetadata> _readMp3(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    String? title;
    String? artist;
    String? album;
    String? albumArtist;
    String? lyrics;
    String? genre;
    String? comment;
    int? year;
    Uint8List? artwork;
    int? durationMs;

    await raf.setPosition(0);
    final header = await raf.read(10);
    var audioStart = 0;
    if (header.length == 10 &&
        header[0] == 0x49 &&
        header[1] == 0x44 &&
        header[2] == 0x33) {
      final version = header[3];
      final flags = header[5];
      final tagSize = _synchSafeToInt(header, 6);
      final tagBytes = await raf.read(tagSize);
      var frameStart = 0;
      if ((flags & 0x40) != 0 && tagBytes.length >= 4) {
        frameStart = version >= 4
            ? _synchSafeToInt(tagBytes, 0)
            : 4 + _be32(tagBytes, 0);
      }
      var offset = frameStart;
      while (offset + 10 <= tagBytes.length) {
        if (tagBytes[offset] == 0) break; // 填充
        final id = String.fromCharCodes(tagBytes.sublist(offset, offset + 4));
        final size = version >= 4
            ? _synchSafeToInt(tagBytes, offset + 4)
            : _be32(tagBytes, offset + 4);
        if (size <= 0 || offset + 10 + size > tagBytes.length) break;
        final content = tagBytes.sublist(offset + 10, offset + 10 + size);
        switch (id) {
          case 'TIT2':
            title = _decodeTextFrame(content);
            break;
          case 'TPE1':
            artist = _decodeTextFrame(content);
            break;
          case 'TALB':
            album = _decodeTextFrame(content);
            break;
          case 'TPE2':
            albumArtist = _decodeTextFrame(content);
            break;
          case 'TDRC': // ID3v2.4 录制时间
          case 'TYER': // ID3v2.3 年份
          case 'TDRL': // ID3v2.4 发布时间
            year = _parseYear(_decodeTextFrame(content));
            break;
          case 'USLT': // 未同步歌词
            lyrics = _decodeUsltFrame(content);
            break;
          case 'TCON': // 流派
            genre = _decodeTextFrame(content);
            break;
          case 'COMM': // 注释（结构与 USLT 一致：编码 + 语言 + 描述 + 文本）
            comment = _decodeUsltFrame(content);
            break;
          case 'TLEN':
            durationMs = int.tryParse((_decodeTextFrame(content) ?? '').trim());
            break;
          case 'APIC':
            artwork = _decodeApicFrame(content);
            break;
        }
        offset += 10 + size;
      }
      audioStart = 10 + tagSize;
    }

    if (durationMs == null) {
      durationMs = await _readMp3Duration(raf, audioStart, fileLength);
    }

    return LocalAudioMetadata(
      title: title,
      artist: artist ?? albumArtist,
      album: album,
      year: year,
      durationSeconds: durationMs == null ? null : durationMs ~/ 1000,
      artwork: artwork,
      lyrics: lyrics,
      genre: genre,
      comment: comment,
    );
  }

  /// 通过 MPEG 帧头估算时长（优先读 Xing/Info 帧数）。
  static Future<int?> _readMp3Duration(
    RandomAccessFile raf,
    int audioStart,
    int fileLength,
  ) async {
    if (audioStart >= fileLength) return null;
    await raf.setPosition(audioStart);
    final buffer = await raf.read(
      fileLength - audioStart > 65536 ? 65536 : fileLength - audioStart,
    );
    if (buffer.length < 4) return null;

    for (var i = 0; i + 4 <= buffer.length; i++) {
      if (buffer[i] != 0xFF || (buffer[i + 1] & 0xE0) != 0xE0) continue;
      final frame = _parseMpegFrameHeader(buffer, i);
      if (frame == null) continue;

      // Xing / Info 头（VBR 精确时长）
      final sideInfo = frame.version == 1
          ? (frame.channelMode == 3 ? 17 : 32)
          : (frame.channelMode == 3 ? 9 : 17);
      final xingOffset = i + 4 + sideInfo;
      if (xingOffset + 12 <= buffer.length) {
        final tag = String.fromCharCodes(
          buffer.sublist(xingOffset, xingOffset + 4),
        );
        if (tag == 'Xing' || tag == 'Info') {
          final flags = _be32(buffer, xingOffset + 4);
          if ((flags & 0x01) != 0) {
            final frames = _be32(buffer, xingOffset + 8);
            if (frames > 0 && frame.sampleRate > 0) {
              final total =
                  frames * frame.samplesPerFrame * 1000 ~/ frame.sampleRate;
              return total;
            }
          }
        }
      }

      // 退化为按平均码率估算
      if (frame.bitrate > 0) {
        final audioBytes = fileLength - audioStart;
        return (audioBytes * 8 * 1000) ~/ frame.bitrate;
      }
      return null;
    }
    return null;
  }

  /// 解析 MPEG 帧头，返回码率（bps）/采样率/每帧采样数等信息。
  static ({
    int bitrate,
    int sampleRate,
    int samplesPerFrame,
    int version,
    int channelMode,
  })?
  _parseMpegFrameHeader(Uint8List buffer, int offset) {
    if (offset + 4 > buffer.length) return null;
    final b1 = buffer[offset + 1];
    final b2 = buffer[offset + 2];
    final b3 = buffer[offset + 3];

    final versionBits = (b1 >> 3) & 0x03; // 0=2.5, 1=保留, 2=2, 3=1
    final layerBits = (b1 >> 1) & 0x03; // 0=保留, 1=LayerIII, 2=LayerII, 3=LayerI
    if (versionBits == 1 || layerBits == 0) return null;

    final bitrateIndex = (b2 >> 4) & 0x0F;
    final sampleRateIndex = (b2 >> 2) & 0x03;
    if (bitrateIndex == 0 || bitrateIndex == 15 || sampleRateIndex == 3) {
      return null;
    }

    final isVersion1 = versionBits == 3;
    final isLayer1 = layerBits == 3;

    // 码率表（kbps）
    const v1l1 = [
      0,
      32,
      64,
      96,
      128,
      160,
      192,
      224,
      256,
      288,
      320,
      352,
      384,
      416,
      448,
      0,
    ];
    const v1l2 = [
      0,
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
      384,
      0,
    ];
    const v1l3 = [
      0,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      160,
      192,
      224,
      256,
      320,
      0,
    ];
    const v2l1 = [
      0,
      32,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
      176,
      192,
      224,
      256,
      0,
    ];
    const v2l23 = [
      0,
      8,
      16,
      24,
      32,
      40,
      48,
      56,
      64,
      80,
      96,
      112,
      128,
      144,
      160,
      0,
    ];

    int kbps;
    if (isVersion1) {
      kbps = isLayer1
          ? v1l1[bitrateIndex]
          : (layerBits == 2 ? v1l2[bitrateIndex] : v1l3[bitrateIndex]);
    } else {
      kbps = isLayer1 ? v2l1[bitrateIndex] : v2l23[bitrateIndex];
    }
    if (kbps <= 0) return null;

    const sampleRatesV1 = [44100, 48000, 32000];
    const sampleRatesV2 = [22050, 24000, 16000];
    const sampleRatesV25 = [11025, 12000, 8000];
    final sampleRate = isVersion1
        ? sampleRatesV1[sampleRateIndex]
        : (versionBits == 2
              ? sampleRatesV2[sampleRateIndex]
              : sampleRatesV25[sampleRateIndex]);

    int samplesPerFrame;
    if (isLayer1) {
      samplesPerFrame = 384;
    } else if (layerBits == 2) {
      samplesPerFrame = 1152;
    } else {
      samplesPerFrame = isVersion1 ? 1152 : 576;
    }

    final channelMode = (b3 >> 6) & 0x03;

    return (
      bitrate: kbps * 1000,
      sampleRate: sampleRate,
      samplesPerFrame: samplesPerFrame,
      version: isVersion1 ? 1 : 2,
      channelMode: channelMode,
    );
  }

  // ==================== FLAC ====================

  static Future<LocalAudioMetadata> _readFlac(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    await raf.setPosition(0);
    final magic = await raf.read(4);
    if (magic.length < 4 ||
        magic[0] != 0x66 ||
        magic[1] != 0x4C ||
        magic[2] != 0x61 ||
        magic[3] != 0x43) {
      return const LocalAudioMetadata();
    }

    String? title;
    String? artist;
    String? album;
    String? lyrics;
    String? genre;
    String? comment;
    int? year;
    Uint8List? artwork;
    int? durationSeconds;

    var offset = 4;
    var isLast = false;
    while (!isLast && offset + 4 <= fileLength) {
      await raf.setPosition(offset);
      final header = await raf.read(4);
      if (header.length < 4) break;
      final headerByte = header[0];
      isLast = (headerByte & 0x80) != 0;
      final type = headerByte & 0x7F;
      final length = (header[1] << 16) | (header[2] << 8) | header[3];
      final dataStart = offset + 4;
      if (dataStart + length > fileLength) break;

      if (type == 0 && length >= 18) {
        final info = await raf.read(18);
        if (info.length >= 18) {
          final sampleRate =
              (info[10] << 12) | (info[11] << 4) | (info[12] >> 4);
          final totalSamples =
              ((info[13] & 0x0F) << 32) |
              (info[14] << 24) |
              (info[15] << 16) |
              (info[16] << 8) |
              info[17];
          if (sampleRate > 0 && totalSamples > 0) {
            durationSeconds = (totalSamples / sampleRate).round();
          }
        }
      } else if (type == 4) {
        final data = await raf.read(length);
        final comments = _parseVorbisComments(data);
        title ??= comments['TITLE'];
        artist ??= comments['ARTIST'];
        album ??= comments['ALBUM'];
        year ??= _parseYear(
          comments['DATE'] ?? comments['YEAR'] ?? comments['ORIGINALDATE'],
        );
        lyrics ??= comments['LYRICS'] ?? comments['UNSYNCEDLYRICS'];
        genre ??= comments['GENRE'];
        comment ??=
            comments['COMMENT'] ??
            comments['DESCRIPTION'] ??
            comments['COMMENTS'];
      } else if (type == 6) {
        final data = await raf.read(length);
        artwork ??= _parseFlacPicture(data);
      } else {
        await raf.setPosition(dataStart + length);
      }
      offset = dataStart + length;
    }

    return LocalAudioMetadata(
      title: title,
      artist: artist,
      album: album,
      year: year,
      durationSeconds: durationSeconds,
      artwork: artwork,
      lyrics: lyrics,
      genre: genre,
      comment: comment,
    );
  }

  // ==================== MP4 / M4A ====================

  static Future<LocalAudioMetadata> _readMp4(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    var offset = 0;
    Uint8List? moov;
    while (offset + 8 <= fileLength) {
      await raf.setPosition(offset);
      final header = await raf.read(8);
      if (header.length < 8) break;
      var size = _be32(header, 0);
      final type = String.fromCharCodes(header.sublist(4, 8));
      var headerSize = 8;
      if (size == 1) {
        final ext = await raf.read(8);
        if (ext.length < 8) break;
        size = _be64(ext, 0);
        headerSize = 16;
      } else if (size == 0) {
        size = fileLength - offset;
      }
      if (size < headerSize) break;
      if (type == 'moov') {
        if (size - headerSize > 0) {
          moov = await raf.read(size - headerSize);
        }
        break;
      }
      offset += size;
    }
    if (moov == null) return const LocalAudioMetadata();

    String? title;
    String? artist;
    String? album;
    int? year;
    String? lyrics;
    String? genre;
    String? comment;
    Uint8List? artwork;
    int? durationSeconds;

    // 遍历 moov 的子块
    var pos = 0;
    while (pos + 8 <= moov.length) {
      final size = _be32(moov, pos);
      final type = String.fromCharCodes(moov.sublist(pos + 4, pos + 8));
      if (size < 8 || pos + size > moov.length) break;
      if (type == 'mvhd') {
        final data = moov.sublist(pos + 8, pos + size);
        durationSeconds = _parseMvhdDuration(data);
      } else if (type == 'udta') {
        final data = moov.sublist(pos + 8, pos + size);
        final parsed = _parseMp4Udta(data);
        title = parsed.title;
        artist = parsed.artist;
        album = parsed.album;
        year = parsed.year;
        lyrics = parsed.lyrics;
        artwork = parsed.artwork;
        genre = parsed.genre;
        comment = parsed.comment;
      }
      pos += size;
    }

    return LocalAudioMetadata(
      title: title,
      artist: artist,
      album: album,
      year: year,
      durationSeconds: durationSeconds,
      artwork: artwork,
      lyrics: lyrics,
      genre: genre,
      comment: comment,
    );
  }

  static int? _parseMvhdDuration(Uint8List data) {
    if (data.length < 20) return null;
    final version = data[0];
    if (version == 1) {
      if (data.length < 32) return null;
      final timescale = _be32(data, 20);
      final duration = _be64(data, 24);
      if (timescale <= 0) return null;
      return (duration / timescale).round();
    }
    final timescale = _be32(data, 12);
    final duration = _be32(data, 16);
    if (timescale <= 0) return null;
    return (duration / timescale).round();
  }

  static ({
    String? title,
    String? artist,
    String? album,
    int? year,
    String? lyrics,
    Uint8List? artwork,
    String? genre,
    String? comment,
  })
  _parseMp4Udta(Uint8List udta) {
    String? title;
    String? artist;
    String? album;
    int? year;
    String? lyrics;
    Uint8List? artwork;
    String? genre;
    String? comment;

    // udta > meta > ilst
    var pos = 0;
    while (pos + 8 <= udta.length) {
      final size = _be32(udta, pos);
      final type = String.fromCharCodes(udta.sublist(pos + 4, pos + 8));
      if (size < 8 || pos + size > udta.length) break;
      if (type == 'meta') {
        // meta 是 full atom：前 4 字节是版本/标志
        final meta = udta.sublist(pos + 8, pos + size);
        var mpos = 4;
        while (mpos + 8 <= meta.length) {
          final msize = _be32(meta, mpos);
          final mtype = String.fromCharCodes(meta.sublist(mpos + 4, mpos + 8));
          if (msize < 8 || mpos + msize > meta.length) break;
          if (mtype == 'ilst') {
            final items = meta.sublist(mpos + 8, mpos + msize);
            final parsed = _parseMp4Ilst(items);
            title = parsed.title;
            artist = parsed.artist;
            album = parsed.album;
            year = parsed.year;
            lyrics = parsed.lyrics;
            artwork = parsed.artwork;
            genre = parsed.genre;
            comment = parsed.comment;
          }
          mpos += msize;
        }
      }
      pos += size;
    }

    return (
      title: title,
      artist: artist,
      album: album,
      year: year,
      lyrics: lyrics,
      artwork: artwork,
      genre: genre,
      comment: comment,
    );
  }

  static ({
    String? title,
    String? artist,
    String? album,
    int? year,
    String? lyrics,
    Uint8List? artwork,
    String? genre,
    String? comment,
  })
  _parseMp4Ilst(Uint8List ilst) {
    String? title;
    String? artist;
    String? album;
    int? year;
    String? lyrics;
    Uint8List? artwork;
    String? genre;
    String? comment;

    var pos = 0;
    while (pos + 8 <= ilst.length) {
      final size = _be32(ilst, pos);
      if (size < 8 || pos + size > ilst.length) break;
      // atom 名可能是 '©nam'（0xA9 开头），去掉版权符号后比较
      final nameBytes = ilst.sublist(pos + 4, pos + 8);
      final isCopyright = nameBytes[0] == 0xA9;
      final name = isCopyright
          ? String.fromCharCodes(nameBytes.sublist(1))
          : String.fromCharCodes(nameBytes);

      // atom 内容里是 data atom
      var dpos = pos + 8;
      final dend = pos + size;
      while (dpos + 8 <= dend) {
        final dsize = _be32(ilst, dpos);
        final dtype = String.fromCharCodes(ilst.sublist(dpos + 4, dpos + 8));
        if (dsize < 8 || dpos + dsize > dend) break;
        if (dtype == 'data' && dsize >= 16) {
          final payload = ilst.sublist(dpos + 16, dpos + dsize);
          switch (name) {
            case 'nam': // ©nam
              title = utf8.decode(payload, allowMalformed: true);
              break;
            case 'ART': // ©ART
              artist = utf8.decode(payload, allowMalformed: true);
              break;
            case 'alb': // ©alb
              album = utf8.decode(payload, allowMalformed: true);
              break;
            case 'aART': // aART
              artist ??= utf8.decode(payload, allowMalformed: true);
              break;
            case 'day': // ©day
              year = _parseYear(utf8.decode(payload, allowMalformed: true));
              break;
            case 'lyr': // ©lyr
              lyrics = utf8.decode(payload, allowMalformed: true);
              break;
            case 'gen': // ©gen 流派
              genre = utf8.decode(payload, allowMalformed: true);
              break;
            case 'cmt': // ©cmt 注释
              comment = utf8.decode(payload, allowMalformed: true);
              break;
            case 'covr': // covr
              if (artwork == null && payload.isNotEmpty) {
                artwork = Uint8List.fromList(payload);
              }
              break;
          }
        }
        dpos += dsize;
      }
      pos += size;
    }

    return (
      title: title,
      artist: artist,
      album: album,
      year: year,
      lyrics: lyrics,
      artwork: artwork,
      genre: genre,
      comment: comment,
    );
  }

  // ==================== WAV ====================

  static Future<LocalAudioMetadata> _readWav(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    await raf.setPosition(0);
    final riff = await raf.read(12);
    if (riff.length < 12) return const LocalAudioMetadata();

    var byteRate = 0;
    int? durationSeconds;
    String? title;
    String? artist;
    String? album;
    String? genre;
    String? comment;
    int? year;

    var offset = 12;
    while (offset + 8 <= fileLength) {
      await raf.setPosition(offset);
      final header = await raf.read(8);
      if (header.length < 8) break;
      final id = String.fromCharCodes(header.sublist(0, 4));
      final size = _le32(header, 4);
      final dataStart = offset + 8;
      if (size < 0 || dataStart + size > fileLength) break;

      if (id == 'fmt ') {
        final data = await raf.read(size >= 16 ? 16 : size);
        if (data.length >= 16) {
          byteRate = _le32(data, 8);
        }
      } else if (id == 'data') {
        if (byteRate > 0) {
          durationSeconds = (size * 1000) ~/ byteRate ~/ 1000;
        }
      } else if (id == 'LIST') {
        final data = await raf.read(size);
        final parsed = _parseWavInfo(data);
        title ??= parsed.$1;
        artist ??= parsed.$2;
        album ??= parsed.$3;
        year ??= _parseYear(parsed.$4);
        genre ??= parsed.$5;
        comment ??= parsed.$6;
      } else {
        await raf.setPosition(dataStart + size);
      }
      offset = dataStart + size + (size.isOdd ? 1 : 0);
    }

    return LocalAudioMetadata(
      title: title,
      artist: artist,
      album: album,
      year: year,
      durationSeconds: durationSeconds,
      genre: genre,
      comment: comment,
    );
  }

  static (String?, String?, String?, String?, String?, String?) _parseWavInfo(
    Uint8List list,
  ) {
    String? title;
    String? artist;
    String? album;
    String? date;
    String? genre;
    String? comment;
    if (list.length < 4) return (null, null, null, null, null, null);
    var pos = 4; // 跳过 'INFO'
    while (pos + 8 <= list.length) {
      final id = String.fromCharCodes(list.sublist(pos, pos + 4));
      final size = _le32(list, pos + 4);
      final dataStart = pos + 8;
      if (size < 0 || dataStart + size > list.length) break;
      final value = utf8
          .decode(
            list.sublist(dataStart, dataStart + size),
            allowMalformed: true,
          )
          .replaceAll('\u0000', '')
          .trim();
      switch (id) {
        case 'INAM':
          title = value;
          break;
        case 'IART':
          artist = value;
          break;
        case 'IPRD':
          album = value;
          break;
        case 'ICRD':
          date = value;
          break;
        case 'IGNR':
          genre = value;
          break;
        case 'ICMT':
          comment = value;
          break;
      }
      pos = dataStart + size + (size.isOdd ? 1 : 0);
    }
    return (title, artist, album, date, genre, comment);
  }

  // ==================== OGG ====================

  static Future<LocalAudioMetadata> _readOgg(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    String? title;
    String? artist;
    String? album;
    String? lyrics;
    String? genre;
    String? comment;
    int? year;
    int? sampleRate;
    int? lastGranule;

    // 首页：识别头（采样率）与注释头
    final headLength = fileLength > 65536 ? 65536 : fileLength;
    await raf.setPosition(0);
    final head = await raf.read(headLength);
    if (head.length < 4) return const LocalAudioMetadata();

    // 找第一个 Vorbis 识别头
    for (var i = 0; i + 16 < head.length; i++) {
      if (head[i] == 0x01 &&
          head[i + 1] == 0x76 &&
          head[i + 2] == 0x6F &&
          head[i + 3] == 0x72 &&
          head[i + 4] == 0x62 &&
          head[i + 5] == 0x69 &&
          head[i + 6] == 0x73) {
        sampleRate = _le32(head, i + 12);
        break;
      }
    }

    // 注释头：0x03 'vorbis'
    for (var i = 0; i + 7 < head.length; i++) {
      if (head[i] == 0x03 &&
          head[i + 1] == 0x76 &&
          head[i + 2] == 0x6F &&
          head[i + 3] == 0x72 &&
          head[i + 4] == 0x62 &&
          head[i + 5] == 0x69 &&
          head[i + 6] == 0x73) {
        final comments = _parseVorbisComments(
          head.sublist(i + 7),
          allowTruncated: true,
        );
        title = comments['TITLE'];
        artist = comments['ARTIST'];
        album = comments['ALBUM'];
        year = _parseYear(
          comments['DATE'] ?? comments['YEAR'] ?? comments['ORIGINALDATE'],
        );
        lyrics = comments['LYRICS'] ?? comments['UNSYNCEDLYRICS'];
        genre = comments['GENRE'];
        comment = comments['COMMENT'] ?? comments['DESCRIPTION'];
        break;
      }
    }

    // 末页的 granule 位置 → 时长
    if (fileLength > 65536) {
      await raf.setPosition(fileLength - 65536);
      final tail = await raf.read(65536);
      for (var i = tail.length - 27; i >= 0; i--) {
        if (tail[i] == 0x4F &&
            tail[i + 1] == 0x67 &&
            tail[i + 2] == 0x67 &&
            tail[i + 3] == 0x53) {
          lastGranule = _le64(tail, i + 6);
          break;
        }
      }
    }

    int? durationSeconds;
    if (sampleRate != null &&
        sampleRate > 0 &&
        lastGranule != null &&
        lastGranule > 0) {
      durationSeconds = (lastGranule * 1000 ~/ sampleRate) ~/ 1000;
    }

    return LocalAudioMetadata(
      title: title,
      artist: artist,
      album: album,
      year: year,
      durationSeconds: durationSeconds,
      lyrics: lyrics,
      genre: genre,
      comment: comment,
    );
  }

  // ==================== 公共解析 ====================

  /// 解析 Vorbis Comment 块（FLAC / OGG）。
  static Map<String, String> _parseVorbisComments(
    Uint8List data, {
    bool allowTruncated = false,
  }) {
    final result = <String, String>{};
    var offset = 0;
    if (data.length < 8) return result;

    final vendorLength = _le32(data, offset);
    offset += 4;
    if (offset + vendorLength > data.length) return result;
    offset += vendorLength;
    if (offset + 4 > data.length) return result;

    final count = _le32(data, offset);
    offset += 4;
    for (var i = 0; i < count; i++) {
      if (offset + 4 > data.length) break;
      final length = _le32(data, offset);
      offset += 4;
      if (offset + length > data.length) {
        if (!allowTruncated) break;
        break;
      }
      final comment = utf8.decode(
        data.sublist(offset, offset + length),
        allowMalformed: true,
      );
      offset += length;
      final eq = comment.indexOf('=');
      if (eq <= 0) continue;
      final key = comment.substring(0, eq).toUpperCase();
      final value = comment.substring(eq + 1);
      result.putIfAbsent(key, () => value);
    }
    return result;
  }

  /// 解析 FLAC PICTURE 元数据块，取出图片数据。
  static Uint8List? _parseFlacPicture(Uint8List data) {
    if (data.length < 32) return null;
    var pos = 4; // 图片类型
    final mimeLength = _be32(data, pos);
    pos += 4;
    if (pos + mimeLength > data.length) return null;
    pos += mimeLength;
    final descLength = _be32(data, pos);
    pos += 4;
    if (pos + descLength > data.length) return null;
    pos += descLength;
    pos += 16; // 宽/高/色深/颜色数
    if (pos + 4 > data.length) return null;
    final dataLength = _be32(data, pos);
    pos += 4;
    if (pos + dataLength > data.length) return null;
    return Uint8List.fromList(data.sublist(pos, pos + dataLength));
  }

  /// 解析 ID3 文本帧。
  static String? _decodeTextFrame(List<int> content) {
    if (content.isEmpty) return null;
    return _decodeTextByEncoding(content[0], content.sublist(1));
  }

  /// 按 ID3 文本编码解码内容。
  static String? _decodeTextByEncoding(int encoding, List<int> data) {
    if (data.isEmpty) return '';
    try {
      switch (encoding) {
        case 0:
          return latin1.decode(data).replaceAll('\u0000', '').trim();
        case 1:
          return _decodeUtf16(data);
        case 2:
          return _decodeUtf16Be(data);
        case 3:
          return utf8.decode(data, allowMalformed: true).trim();
        default:
          return utf8.decode(data, allowMalformed: true).trim();
      }
    } catch (_) {
      return null;
    }
  }

  /// 解析 ID3 USLT 帧（未同步歌词）。
  ///
  /// 结构：[编码 1 字节][语言 3 字节][描述符（以 0 结尾）][歌词文本]
  static String? _decodeUsltFrame(List<int> content) {
    if (content.length < 5) return null;
    final encoding = content[0];
    var pos = 4; // 跳过编码 + 语言（3 字节）
    if (encoding == 1 || encoding == 2) {
      // UTF-16：两个 0 字节结束描述符
      while (pos + 1 < content.length) {
        if (content[pos] == 0 && content[pos + 1] == 0) {
          pos += 2;
          break;
        }
        pos += 2;
      }
    } else {
      while (pos < content.length && content[pos] != 0) {
        pos++;
      }
      pos++; // 跳过结束符
    }
    if (pos >= content.length) return null;
    final text = _decodeTextByEncoding(encoding, content.sublist(pos));
    if (text == null || text.trim().isEmpty) return null;
    return text;
  }

  /// 从日期 / 年份文本里解析出年份（`2023`、`2023-05-01` 都取前 4 位）。
  static int? _parseYear(String? value) {
    if (value == null) return null;
    final match = RegExp(r'(\d{4})').firstMatch(value);
    if (match == null) return null;
    final year = int.tryParse(match.group(1)!);
    if (year == null || year < 1000 || year > 9999) return null;
    return year;
  }

  static String _decodeUtf16(List<int> data) {
    var bytes = data;
    var littleEndian = true;
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        bytes = bytes.sublist(2);
      } else if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        bytes = bytes.sublist(2);
        littleEndian = false;
      }
    }
    final value = littleEndian ? _decodeUtf16Le(bytes) : _decodeUtf16Be(bytes);
    // v2.4 允许多个以 0 分隔的字符串，只取第一个
    final index = value.indexOf('\u0000');
    final first = index >= 0 ? value.substring(0, index) : value;
    return first.trim();
  }

  static String _decodeUtf16Le(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add(bytes[i] | (bytes[i + 1] << 8));
    }
    return String.fromCharCodes(units);
  }

  static String _decodeUtf16Be(List<int> bytes) {
    final units = <int>[];
    for (var i = 0; i + 1 < bytes.length; i += 2) {
      units.add((bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }

  /// 解析 ID3 APIC 帧，取出图片数据。
  static Uint8List? _decodeApicFrame(List<int> content) {
    if (content.length < 4) return null;
    final encoding = content[0];
    var pos = 1;
    while (pos < content.length && content[pos] != 0) {
      pos++;
    }
    pos++; // 跳过 MIME 结束符
    if (pos >= content.length) return null;
    pos++; // 图片类型
    if (encoding == 1 || encoding == 2) {
      while (pos + 1 < content.length) {
        if (content[pos] == 0 && content[pos + 1] == 0) {
          pos += 2;
          break;
        }
        pos += 2;
      }
    } else {
      while (pos < content.length && content[pos] != 0) {
        pos++;
      }
      pos++;
    }
    if (pos >= content.length) return null;
    return Uint8List.fromList(content.sublist(pos));
  }

  // ==================== 字节工具 ====================

  static int _synchSafeToInt(List<int> bytes, [int offset = 0]) {
    var value = 0;
    for (var i = 0; i < 4; i++) {
      value = (value << 7) | (bytes[offset + i] & 0x7F);
    }
    return value;
  }

  static int _be32(List<int> bytes, [int offset = 0]) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  static int _be64(List<int> bytes, [int offset = 0]) {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }

  static int _le32(List<int> bytes, [int offset = 0]) {
    return bytes[offset] |
        (bytes[offset + 1] << 8) |
        (bytes[offset + 2] << 16) |
        (bytes[offset + 3] << 24);
  }

  static int _le64(List<int> bytes, [int offset = 0]) {
    var value = 0;
    for (var i = 7; i >= 0; i--) {
      value = (value << 8) | bytes[offset + i];
    }
    return value;
  }
}
