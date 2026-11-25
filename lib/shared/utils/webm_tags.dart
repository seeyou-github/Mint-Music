import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 一个 EBML 元素头。
///
/// EBML（WebM / Matroska 的容器格式）每个元素都是 `ID + 长度 + 数据`：
/// * ID 与长度都是「可变长整数」，长度字段的标志位不参与数值；
/// * 长度字段的数值位全 1 表示「大小未知」（流式封装的 Segment / Cluster）。
class WebmElementHead {
  /// 元素 ID（含其长度标志位，例如 Tags = 0x1254C367）。
  final int id;

  /// 数据区大小；[unknownSize] 为 true 时为 0。
  final int size;

  /// 数据区起始位置。
  final int dataPos;

  /// 大小未知。
  final bool unknownSize;

  /// ID + 长度字段的总字节数。
  final int headerSize;

  const WebmElementHead({
    required this.id,
    required this.size,
    required this.dataPos,
    required this.unknownSize,
    required this.headerSize,
  });

  int get end => dataPos + size;
}

/// WebM / Matroska 里用到的 EBML 元素 ID。
class WebmEbml {
  WebmEbml._();

  static const int idEbmlHeader = 0x1A45DFA3;
  static const int idSegment = 0x18538067;
  static const int idSeekHead = 0x114D9B74;
  static const int idInfo = 0x1549A966;
  static const int idTracks = 0x1654AE6B;
  static const int idCluster = 0x1F43B675;
  static const int idCues = 0x1C53BB6B;
  static const int idTags = 0x1254C367;
  static const int idTag = 0x7373;
  static const int idTargets = 0x63C0;
  static const int idSimpleTag = 0x67C8;
  static const int idTagName = 0x45A3;
  static const int idTagString = 0x4487;
  static const int idVoid = 0xEC;

  /// 支持的最大长度字段字节数。
  static const int maxVintLength = 8;

  /// EBML 可变长整数首字节 → 总字节数。
  ///
  /// 从最高位往下扫，第一个 1 的位置 p（0 起算）→ 总长 p + 1 字节：
  /// 0x80~0xFF → 1 字节、0x40~0x7F → 2 字节 …… 0x01 → 8 字节。
  static int? vintLength(int first) {
    if (first == 0) return null;
    var length = 1;
    for (var mask = 0x80; (first & mask) == 0; mask >>= 1) {
      length++;
      if (length > maxVintLength) return null;
    }
    return length;
  }

  /// 从内存里读一个元素头。
  static WebmElementHead? headFromBytes(Uint8List bytes, int pos) {
    if (pos < 0 || pos >= bytes.length) return null;
    final idLength = vintLength(bytes[pos]);
    if (idLength == null || pos + idLength >= bytes.length) return null;
    var id = 0;
    for (var i = 0; i < idLength; i++) {
      id = (id << 8) | bytes[pos + i];
    }
    final sizeOffset = pos + idLength;
    final sizeLength = vintLength(bytes[sizeOffset]);
    if (sizeLength == null || pos + idLength + sizeLength > bytes.length) {
      return null;
    }
    var size = bytes[sizeOffset] & ((1 << (8 - sizeLength)) - 1);
    for (var i = 1; i < sizeLength; i++) {
      size = (size << 8) | bytes[sizeOffset + i];
    }
    // 数值位全 1 = 大小未知。
    final unknown = size == (1 << (7 * sizeLength)) - 1;
    final headerSize = idLength + sizeLength;
    return WebmElementHead(
      id: id,
      size: unknown ? 0 : size,
      dataPos: pos + headerSize,
      unknownSize: unknown,
      headerSize: headerSize,
    );
  }

  /// 从文件里读一个元素头（只读 ID + 长度的前 12 字节）。
  static Future<WebmElementHead?> headAt(
    RandomAccessFile raf,
    int pos,
  ) async {
    if (pos < 0) return null;
    try {
      await raf.setPosition(pos);
      final head = await raf.read(12);
      if (head.isEmpty) return null;
      final parsed = headFromBytes(head, 0);
      if (parsed == null) return null;
      return WebmElementHead(
        id: parsed.id,
        size: parsed.size,
        dataPos: pos + parsed.headerSize,
        unknownSize: parsed.unknownSize,
        headerSize: parsed.headerSize,
      );
    } catch (_) {
      return null;
    }
  }

  /// 把 [value] 编码成 [length] 字节的可变长整数；放不下返回 null。
  ///
  /// 数值位全 1 是「大小未知」的保留值，所以 [length] 字节最多表示
  /// `2^(7*length) - 2`。
  static Uint8List? encodeSize(int value, int length) {
    if (length < 1 || length > maxVintLength || value < 0) return null;
    if (value >= (1 << (7 * length)) - 1) return null;
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = v & 0xFF;
      v >>= 8;
    }
    out[0] |= 1 << (8 - length);
    return out;
  }

  /// 用最省的长度字段编码 [value]。
  static int minimalSizeLength(int value) {
    for (var length = 1; length < maxVintLength; length++) {
      if (value < (1 << (7 * length)) - 1) return length;
    }
    return maxVintLength;
  }

  /// 拼一个完整元素：`ID + 长度 + 数据`（长度字段取最省字节）。
  static Uint8List element(List<int> id, Uint8List payload) {
    final sizeLength = minimalSizeLength(payload.length);
    final sizeBytes = encodeSize(payload.length, sizeLength)!;
    final out = Uint8List(id.length + sizeLength + payload.length);
    out.setRange(0, id.length, id);
    out.setRange(id.length, id.length + sizeLength, sizeBytes);
    out.setRange(id.length + sizeLength, out.length, payload);
    return out;
  }

  /// 定位读取最多 [size] 字节，返回**实际读到的**字节。
  static Future<Uint8List?> readAt(
    RandomAccessFile raf,
    int pos,
    int size,
  ) async {
    if (pos < 0 || size <= 0) return null;
    try {
      await raf.setPosition(pos);
      final bytes = await raf.read(size);
      if (bytes.isEmpty) return null;
      return bytes;
    } catch (_) {
      return null;
    }
  }
}

/// WebM 标签（`Segment > Tags > Tag > SimpleTag`）的读写。
///
/// WebM 没有 ID3 / Vorbis Comment，元数据放在标准的 `Tags` 元素里：
/// 一个 `Tag` 下挂若干 `SimpleTag`，每个 `SimpleTag` 是
/// `TagName`（如 `TITLE`）+ `TagString`（值）。
///
/// 写入策略见 `AudioTagWriter.writeWebm`：**只往文件末尾追加 + 原地改
/// Segment 长度**，一字节音频数据都不搬动。
class WebmTags {
  WebmTags._();

  /// 标签元素最多读多少字节（防御损坏文件把整段读进内存）。
  static const int _maxTagsBytes = 4 * 1024 * 1024;

  /// 尾部扫描窗口：我们追加的 Tags 就在文件最后，几百字节到几十 KB。
  static const int _tailWindow = 256 * 1024;

  /// 读 [dataPos] 处的 Tags 元素，解析成有序的（名称, 值）列表。
  static Future<List<(String, String)>> readElement(
    RandomAccessFile raf,
    int dataPos,
    int size,
  ) async {
    if (size <= 0 || size > _maxTagsBytes) return const [];
    final data = await WebmEbml.readAt(raf, dataPos, size);
    if (data == null) return const [];
    return parse(data);
  }

  /// 解析 Tags 元素的数据区。
  ///
  /// 传整段「带 Tags 元素头」的字节也可以（内部会自己下钻一层），避免调用方
  /// 因为少切一次 sublist 而静默解析出空结果。
  static List<(String, String)> parse(Uint8List data) {
    final out = <(String, String)>[];
    final head = WebmEbml.headFromBytes(data, 0);
    if (head != null &&
        head.id == WebmEbml.idTags &&
        !head.unknownSize &&
        head.end <= data.length) {
      _collect(data, head.dataPos, head.end, out);
    } else {
      _collect(data, 0, data.length, out);
    }
    return out;
  }

  /// 把（名称, 值）列表解析成「名称 → 值」，名称统一大写，同名的只留第一个。
  static Map<String, String> toMap(List<(String, String)> tags) {
    final map = <String, String>{};
    for (final tag in tags) {
      map.putIfAbsent(tag.$1.toUpperCase(), () => tag.$2);
    }
    return map;
  }

  /// 在 Segment 里找 Tags 元素：先在前段（Cluster 之前）找，找不到再扫文件尾部。
  ///
  /// 前段是 ffmpeg / mkvmerge / yt-dlp 这类工具写标签的位置（SeekHead 指得到）；
  /// 尾部是我们自己追加的位置（见 [build]）。
  static Future<WebmElementHead?> find(
    RandomAccessFile raf, {
    required int segmentDataPos,
    required int segmentEnd,
  }) async {
    var pos = segmentDataPos;
    var guard = 0;
    while (pos < segmentEnd && guard++ < 128) {
      final child = await WebmEbml.headAt(raf, pos);
      if (child == null) break;
      if (child.id == WebmEbml.idTags && !child.unknownSize) return child;
      // 进了 Cluster 就不再有元数据了（尾部另扫）。
      if (child.id == WebmEbml.idCluster) break;
      final next = child.unknownSize ? segmentEnd : child.end;
      if (next <= pos) break;
      pos = next;
    }
    return findAtTail(raf, segmentDataPos: segmentDataPos, end: segmentEnd);
  }

  /// 扫文件最后 [_tailWindow] 字节，找「紧贴文件尾」的 Tags 元素。
  ///
  /// 只认数据区正好结束在 [end] 的那个——追加写的标签就是这个形态，
  /// 而 Cluster 里偶然出现的同样字节序列不会被误判。
  static Future<WebmElementHead?> findAtTail(
    RandomAccessFile raf, {
    required int segmentDataPos,
    required int end,
  }) async {
    final start = end - _tailWindow > segmentDataPos
        ? end - _tailWindow
        : segmentDataPos;
    if (start >= end) return null;
    final data = await WebmEbml.readAt(raf, start, end - start);
    if (data == null || data.length < 8) return null;
    for (var i = data.length - 4; i >= 0; i--) {
      if (data[i] != 0x12 ||
          data[i + 1] != 0x54 ||
          data[i + 2] != 0xC3 ||
          data[i + 3] != 0x67) {
        continue;
      }
      final head = WebmEbml.headFromBytes(data, i);
      if (head == null ||
          head.id != WebmEbml.idTags ||
          head.unknownSize ||
          head.size <= 0) {
        continue;
      }
      if (i + head.headerSize + head.size != data.length) continue;
      return WebmElementHead(
        id: head.id,
        size: head.size,
        dataPos: start + head.dataPos,
        unknownSize: false,
        headerSize: head.headerSize,
      );
    }
    return null;
  }

  /// 把标签拼成一个完整的 Tags 元素（带 Targets 空元素，符合规范习惯）。
  static Uint8List build(List<(String, String)> tags) {
    final payload = BytesBuilder(copy: false);
    payload.add(WebmEbml.element(const [0x63, 0xC0], Uint8List(0)));
    for (final tag in tags) {
      final name = tag.$1.trim().toUpperCase();
      if (name.isEmpty) continue;
      final simple = BytesBuilder(copy: false);
      simple.add(
        WebmEbml.element(
          const [0x45, 0xA3],
          Uint8List.fromList(utf8.encode(name)),
        ),
      );
      simple.add(
        WebmEbml.element(
          const [0x44, 0x87],
          Uint8List.fromList(utf8.encode(tag.$2)),
        ),
      );
      payload.add(WebmEbml.element(const [0x67, 0xC8], simple.toBytes()));
    }
    return WebmEbml.element(const [0x12, 0x54, 0xC3, 0x67], payload.toBytes());
  }

  /// 拼一个 Void 元素（用来原地「擦掉」旧标签，保持后续字节位置不变）。
  ///
  /// [total] 是旧元素占用的总字节数，Void 必须**正好**这么长：长度字段在
  /// 1~8 字节里挑一个能装下剩余数据的，装不下返回 null。
  static Uint8List? buildVoid(int total) {
    if (total < 2) return null;
    for (var sizeLength = 1; sizeLength <= WebmEbml.maxVintLength; sizeLength++) {
      final payload = total - 1 - sizeLength;
      if (payload < 0) continue;
      final sizeBytes = WebmEbml.encodeSize(payload, sizeLength);
      if (sizeBytes == null) continue;
      final out = Uint8List(total);
      out[0] = WebmEbml.idVoid;
      out.setRange(1, 1 + sizeLength, sizeBytes);
      return out;
    }
    return null;
  }

  static void _collect(
    Uint8List data,
    int start,
    int end,
    List<(String, String)> out,
  ) {
    var pos = start;
    var guard = 0;
    while (pos < end && guard++ < 512) {
      final head = WebmEbml.headFromBytes(data, pos);
      if (head == null) break;
      if (head.end > end) break;
      if (head.id == WebmEbml.idTag) {
        // Tag：内含 Targets 与若干 SimpleTag。
        _collect(data, head.dataPos, head.end, out);
      } else if (head.id == WebmEbml.idSimpleTag) {
        _collectSimpleTag(data, head, out);
      }
      if (head.end <= pos) break;
      pos = head.end;
    }
  }

  static void _collectSimpleTag(
    Uint8List data,
    WebmElementHead simpleTag,
    List<(String, String)> out,
  ) {
    String? name;
    String? value;
    var pos = simpleTag.dataPos;
    var guard = 0;
    while (pos < simpleTag.end && guard++ < 16) {
      final head = WebmEbml.headFromBytes(data, pos);
      if (head == null || head.end > simpleTag.end) break;
      if (head.id == WebmEbml.idTagName) {
        name = _decodeUtf8(data, head.dataPos, head.end);
      } else if (head.id == WebmEbml.idTagString) {
        value = _decodeUtf8(data, head.dataPos, head.end);
      } else if (head.id == WebmEbml.idSimpleTag) {
        // 规范允许 SimpleTag 嵌套（如 MUSIC/ALBUM 之类），拍平收集。
        _collectSimpleTag(data, head, out);
      }
      if (head.end <= pos) break;
      pos = head.end;
    }
    if (name == null || value == null) return;
    final trimmed = name.trim();
    if (trimmed.isEmpty) return;
    out.add((trimmed.toUpperCase(), value));
  }

  static String _decodeUtf8(Uint8List data, int start, int end) {
    if (end <= start) return '';
    try {
      return utf8.decode(
        Uint8List.sublistView(data, start, end),
        allowMalformed: true,
      );
    } catch (_) {
      return '';
    }
  }
}
