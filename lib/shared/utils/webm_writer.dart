import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'webm_tags.dart';

/// 重建 WebM / WebA 文件，把标签与封面放在**播放器真的会去读的位置**。
///
/// 背景：早期版本只往文件末尾追加一个 `Tags` 元素（并把 SimpleTag 直接挂在
/// `Tags` 下、不加 `Tag` 包裹）。本程序自己全量扫描能读出来，但 ffmpeg / mpv
/// 只顺着文件开头的 `SeekHead` 找元数据，而且严格按 `Tags > Tag > SimpleTag`
/// 解析——结果就是「播放器属性页里看不到标题 / 歌手 / 歌词」，封面也放不进去。
///
/// 这里改成规范写法（也是 mkvmerge / TagLib 的做法）：
///
/// ```text
/// EBML 头
/// Segment
///   SeekHead      （Info / Tracks / Tags / Attachments / Cues 的位置）
///   Info
///   Tracks
///   Tags          （Tag > Targets + SimpleTag…）
///   Attachments   （AttachedFile：cover.jpg + image/jpeg + 图片数据）
///   Cluster…      （原样按字节复制，不重新编码）
///   Cues          （Cluster 位置按新布局整体平移）
/// ```
///
/// 只有元数据区与 Cues 是重新生成的，音频数据一个字节都不改，时长 / 音质
/// 不变；代价是整文件复制一次（十几 MB 的文件百毫秒级）。
class WebmRewriter {
  WebmRewriter._();

  /// 复制音频数据时的块大小。
  static const int _copyChunk = 1 << 20;

  /// 用新的 Tags / Attachments 重建文件，返回临时文件（由调用方改名替换），
  /// 失败返回 null。
  ///
  /// [tagsBytes] / [attachmentsBytes] 为 null 表示不写对应元素（原有的会被
  /// 丢弃，标签合并与封面去留由调用方决定）。
  static Future<File?> rewrite({
    required String filePath,
    required Uint8List? tagsBytes,
    required Uint8List? attachmentsBytes,
  }) async {
    RandomAccessFile? source;
    RandomAccessFile? output;
    File? temp;
    try {
      final file = File(filePath);
      source = await file.open(mode: FileMode.read);
      final fileLength = await source.length();

      final ebml = await WebmEbml.headAt(source, 0);
      if (ebml == null ||
          ebml.id != WebmEbml.idEbmlHeader ||
          ebml.unknownSize) {
        debugPrint('[WebmRewriter] 不是 WebM / EBML 文件: $filePath');
        return null;
      }
      final ebmlBytes = await WebmEbml.readAt(source, 0, ebml.end);
      if (ebmlBytes == null || ebmlBytes.length != ebml.end) return null;

      final segment = await WebmEbml.headAt(source, ebml.end);
      if (segment == null || segment.id != WebmEbml.idSegment) return null;
      final segmentDataPos = segment.dataPos;
      final segmentEnd = segment.unknownSize
          ? fileLength
          : (segment.end <= fileLength ? segment.end : fileLength);
      if (segmentEnd <= segmentDataPos) return null;

      // 收集 Segment 的直接子元素（只读元素头，不读数据）。
      final children = <WebmElementHead>[];
      var pos = segmentDataPos;
      var guard = 0;
      while (pos < segmentEnd && guard++ < 200000) {
        final head = await WebmEbml.headAt(source, pos);
        if (head == null) break;
        final next = head.unknownSize ? segmentEnd : head.end;
        if (next <= pos || next > segmentEnd) break;
        children.add(head);
        pos = next;
      }
      if (children.isEmpty) return null;

      WebmElementHead? info;
      WebmElementHead? tracks;
      WebmElementHead? cues;
      final clusters = <WebmElementHead>[];
      final others = <WebmElementHead>[];
      for (final child in children) {
        if (child.id == WebmEbml.idInfo) {
          info ??= child;
        } else if (child.id == WebmEbml.idTracks) {
          tracks ??= child;
        } else if (child.id == WebmEbml.idCues) {
          cues ??= child;
        } else if (child.id == WebmEbml.idCluster) {
          clusters.add(child);
        } else if (child.id == WebmEbml.idTags ||
            child.id == WebmEbml.idAttachments ||
            child.id == WebmEbml.idSeekHead) {
          // 旧的标签 / 封面 / 索引：丢弃，按新布局重建。
          continue;
        } else {
          others.add(child);
        }
      }

      // Cues 先读出来、试着重写一遍结构：解析不了就整段丢掉——留着旧位置
      // 会让播放器跳转到错误的地方，没有 Cues 只是跳转慢一点。
      Uint8List? rawCues;
      if (cues != null) {
        rawCues = await WebmEbml.readAt(
          source,
          cues.dataPos - cues.headerSize,
          cues.headerSize + cues.size,
        );
        if (rawCues == null || _rewriteCues(rawCues, const {}) == null) {
          rawCues = null;
          cues = null;
        }
      }

      // ---- 布局：先算大小，再算位置（SeekHead 的位置字段固定 8 字节，
      //      所以它的长度不依赖具体位置，不存在「先有鸡还是先有蛋」）。
      final seekIds = <int>[
        if (info != null) WebmEbml.idInfo,
        if (tracks != null) WebmEbml.idTracks,
        if (tagsBytes != null) WebmEbml.idTags,
        if (attachmentsBytes != null) WebmEbml.idAttachments,
        for (final other in others)
          if (other.id == WebmEbml.idChapters) other.id,
        if (cues != null) WebmEbml.idCues,
      ];
      final seek = _buildSeekHead(seekIds);
      final newSegmentData = ebmlBytes.length + 4 + 8;
      var cursor = newSegmentData;
      final positions = <int, int>{};

      void place(WebmElementHead head, int id) {
        positions[id] = cursor;
        cursor += head.headerSize + head.size;
      }

      cursor += seek.bytes.length;
      if (info != null) place(info, WebmEbml.idInfo);
      if (tracks != null) place(tracks, WebmEbml.idTracks);
      if (tagsBytes != null) {
        positions[WebmEbml.idTags] = cursor;
        cursor += tagsBytes.length;
      }
      if (attachmentsBytes != null) {
        positions[WebmEbml.idAttachments] = cursor;
        cursor += attachmentsBytes.length;
      }
      for (final other in others) {
        if (other.id == WebmEbml.idChapters) {
          positions[other.id] = cursor;
        }
        cursor += other.headerSize + other.size;
      }

      // Cluster：原样复制，位置整体后移；Cues 里的 Cluster 位置要跟着平移。
      final clusterStarts = <int>[];
      for (final cluster in clusters) {
        clusterStarts.add(cursor);
        cursor += cluster.headerSize + cluster.size;
      }

      Uint8List? cuesBytes;
      if (rawCues != null) {
        final clusterMap = <int, int>{};
        for (var i = 0; i < clusters.length; i++) {
          final oldStart = clusters[i].dataPos - clusters[i].headerSize;
          clusterMap[oldStart - segmentDataPos] =
              clusterStarts[i] - newSegmentData;
        }
        cuesBytes = _rewriteCues(rawCues, clusterMap) ?? rawCues;
      }
      if (cuesBytes != null) {
        positions[WebmEbml.idCues] = cursor;
        cursor += cuesBytes.length;
      }

      final segmentSize = cursor - newSegmentData;
      if (segmentSize <= 0 || segmentSize >= (1 << 56)) return null;

      // ---- 回填 SeekHead 里的绝对位置（相对 Segment 数据区起点）。
      final seekHeadBytes = Uint8List.fromList(seek.bytes);
      for (var i = 0; i < seekIds.length; i++) {
        final absolute = positions[seekIds[i]];
        if (absolute == null) continue;
        final relative = absolute - newSegmentData;
        final offset = seek.payloadOffset + seek.entryOffsets[i];
        for (var b = 0; b < 8; b++) {
          seekHeadBytes[offset + b] = (relative >> ((7 - b) * 8)) & 0xFF;
        }
      }

      // ---- 写新文件。
      final target = File('$filePath.webmtmp');
      temp = target;
      output = await target.open(mode: FileMode.write);
      await output.writeFrom(ebmlBytes);
      await output.writeFrom(WebmEbml.idBytes(WebmEbml.idSegment));
      await output.writeFrom(_encodeSegmentSize(segmentSize));
      await output.writeFrom(seekHeadBytes);
      if (info != null) await _copyRange(source, output, info);
      if (tracks != null) await _copyRange(source, output, tracks);
      if (tagsBytes != null) await output.writeFrom(tagsBytes);
      if (attachmentsBytes != null) await output.writeFrom(attachmentsBytes);
      for (final other in others) {
        await _copyRange(source, output, other);
      }
      for (final cluster in clusters) {
        await _copyRange(source, output, cluster);
      }
      if (cuesBytes != null) await output.writeFrom(cuesBytes);
      await output.flush();
      await output.close();
      output = null;
      await source.close();
      source = null;

      debugPrint(
        '[WebmRewriter] 重建完成: $filePath '
        '(原 ${fileLength}B → 新 ${await target.length()}B, '
        '${clusters.length} 个 Cluster, 标签 ${tagsBytes?.length ?? 0}B, '
        '封面 ${attachmentsBytes?.length ?? 0}B)',
      );
      return temp;
    } catch (e) {
      debugPrint('[WebmRewriter] 重建失败 ($filePath): $e');
      try {
        if (temp != null && await temp.exists()) await temp.delete();
      } catch (_) {}
      return null;
    } finally {
      await output?.close();
      await source?.close();
    }
  }

  /// Segment 长度字段固定 8 字节（`0x01` + 7 字节大端），与 mkvmerge 一致。
  static Uint8List _encodeSegmentSize(int size) {
    final out = Uint8List(8);
    out[0] = 0x01;
    var value = size;
    for (var i = 7; i >= 1; i--) {
      out[i] = value & 0xFF;
      value >>= 8;
    }
    return out;
  }

  /// SeekHead 位置字段统一 8 字节：长度固定，布局可以先算后填。
  static ({Uint8List bytes, int payloadOffset, List<int> entryOffsets})
  _buildSeekHead(List<int> ids) {
    final entries = BytesBuilder(copy: false);
    final entryOffsets = <int>[];
    var payloadLength = 0;
    for (final id in ids) {
      final seekId = WebmEbml.elementById(
        WebmEbml.idSeekId,
        WebmEbml.idBytes(id),
      );
      final seekPosition = WebmEbml.elementById(
        WebmEbml.idSeekPosition,
        Uint8List(8),
      );
      final content = Uint8List(seekId.length + seekPosition.length)
        ..setAll(0, seekId)
        ..setAll(seekId.length, seekPosition);
      final entry = WebmEbml.elementById(WebmEbml.idSeek, content);
      // 位置字段就是条目最后 8 字节。
      entryOffsets.add(payloadLength + entry.length - 8);
      entries.add(entry);
      payloadLength += entry.length;
    }
    final bytes = WebmEbml.elementById(
      WebmEbml.idSeekHead,
      entries.toBytes(),
    );
    return (
      bytes: bytes,
      payloadOffset: bytes.length - payloadLength,
      entryOffsets: entryOffsets,
    );
  }

  /// 按块复制一段原始字节（Cluster 可能几十 MB，不能整段读进内存）。
  static Future<void> _copyRange(
    RandomAccessFile source,
    RandomAccessFile output,
    WebmElementHead head,
  ) async {
    await source.setPosition(head.dataPos - head.headerSize);
    var remaining = head.headerSize + head.size;
    final buffer = Uint8List(math.min(_copyChunk, remaining));
    while (remaining > 0) {
      final want = math.min(buffer.length, remaining);
      final read = await source.readInto(buffer, 0, want);
      if (read <= 0) break;
      await output.writeFrom(buffer, 0, read);
      remaining -= read;
    }
  }

  /// 重写 Cues：把 `CueClusterPosition`（相对 Segment 数据区起点）换成新位置，
  /// 其余字段原样保留。
  static Uint8List? _rewriteCues(
    Uint8List data,
    Map<int, int> clusterMap,
  ) {
    return _rewriteCueNode(data, 0, data.length, clusterMap);
  }

  static Uint8List? _rewriteCueNode(
    Uint8List data,
    int start,
    int end,
    Map<int, int> clusterMap,
  ) {
    final head = WebmEbml.headFromBytes(data, start);
    if (head == null || head.unknownSize) return null;
    if (head.end > end || head.dataPos > end) return null;

    final isMaster =
        head.id == WebmEbml.idCues ||
        head.id == WebmEbml.idCuePoint ||
        head.id == WebmEbml.idCueTrackPositions;
    if (!isMaster) {
      if (head.id == WebmEbml.idCueClusterPosition) {
        final value = WebmEbml.uintFrom(data, head.dataPos, head.end);
        final mapped = clusterMap[value] ?? value;
        return WebmEbml.elementById(
          WebmEbml.idCueClusterPosition,
          WebmEbml.uintBytes(mapped),
        );
      }
      return Uint8List.sublistView(data, start, end);
    }

    final payload = BytesBuilder(copy: false);
    var pos = head.dataPos;
    var guard = 0;
    while (pos < end && guard++ < 8192) {
      final child = WebmEbml.headFromBytes(data, pos);
      if (child == null) return null;
      final childEnd = child.unknownSize ? end : child.end;
      if (childEnd > end || childEnd <= pos) return null;
      final rewritten = _rewriteCueNode(data, pos, childEnd, clusterMap);
      if (rewritten == null) return null;
      payload.add(rewritten);
      pos = childEnd;
    }
    return WebmEbml.elementById(head.id, payload.toBytes());
  }
}
