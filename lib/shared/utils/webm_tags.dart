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
  static const int idSeek = 0x4DBB;
  static const int idSeekId = 0x53AB;
  static const int idSeekPosition = 0x53AC;
  static const int idInfo = 0x1549A966;
  static const int idTracks = 0x1654AE6B;
  static const int idCluster = 0x1F43B675;
  static const int idCues = 0x1C53BB6B;
  static const int idCuePoint = 0xBB;
  static const int idCueTrackPositions = 0xB7;
  static const int idCueClusterPosition = 0xF1;
  static const int idChapters = 0x1043A770;
  static const int idTags = 0x1254C367;
  static const int idTag = 0x7373;
  static const int idTargets = 0x63C0;
  static const int idTargetTypeValue = 0x68CA;
  static const int idSimpleTag = 0x67C8;
  static const int idTagName = 0x45A3;
  static const int idTagString = 0x4487;
  static const int idVoid = 0xEC;
  static const int idAttachments = 0x1941A469;
  static const int idAttachedFile = 0x61A7;
  static const int idFileName = 0x466E;
  static const int idFileMimeType = 0x4660;
  static const int idFileData = 0x465C;
  static const int idFileDescription = 0x467E;
  static const int idFileUid = 0x46AE;

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

  /// 元素 ID 的字节形式（EBML 的 ID 本身带长度标志位，按有效位数直接展开）。
  static Uint8List idBytes(int id) {
    var length = 1;
    while (length < 4 && (id >> (length * 8)) != 0) {
      length++;
    }
    final out = Uint8List(length);
    for (var i = length - 1; i >= 0; i--) {
      out[i] = id & 0xFF;
      id >>= 8;
    }
    return out;
  }

  /// 按 int ID 拼元素（[element] 的便捷包装）。
  static Uint8List elementById(int id, Uint8List payload) =>
      element(idBytes(id), payload);

  /// 无符号整数字段（EBML 的 uint 是大端、长度可变，取最省字节）。
  static Uint8List uintBytes(int value) {
    if (value <= 0) return Uint8List(0);
    var length = 1;
    while (length < 8 && (value >> (length * 8)) != 0) {
      length++;
    }
    final out = Uint8List(length);
    var v = value;
    for (var i = length - 1; i >= 0; i--) {
      out[i] = v & 0xFF;
      v >>= 8;
    }
    return out;
  }

  /// 读无符号整数字段。
  static int uintFrom(Uint8List data, int start, int end) {
    var value = 0;
    for (var i = start; i < end && i < data.length; i++) {
      value = (value << 8) | data[i];
    }
    return value;
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

  /// 同 [toMap]，但**同名的后者覆盖前者**。
  ///
  /// 读取时用这个：mkvmerge 会写多个 `Tag`（专辑级 50 / 音轨级 30），音轨级的
  /// 更具体；本程序旧版本追加在文件尾的标签也比文件中间的更新。
  static Map<String, String> toMapLast(List<(String, String)> tags) {
    final map = <String, String>{};
    for (final tag in tags) {
      map[tag.$1.toUpperCase()] = tag.$2;
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

  /// 把标签拼成一个完整的 Tags 元素。
  ///
  /// 结构必须符合 Matroska 规范：`Tags > Tag > (Targets + SimpleTag…)`。
  /// 之前直接把 SimpleTag 挂在 Tags 下，本程序自己扫得出来，但 ffmpeg / mpv
  /// 这类严格解析器会整段忽略（属性页里看不到标签），所以这里补上 Tag 与
  /// Targets（TargetTypeValue = 50，即整张专辑 / 整条音轨一级）。
  static Uint8List build(List<(String, String)> tags) {
    final simpleTags = BytesBuilder(copy: false);
    for (final tag in tags) {
      final name = tag.$1.trim().toUpperCase();
      if (name.isEmpty) continue;
      final simple = BytesBuilder(copy: false);
      simple.add(
        WebmEbml.elementById(
          WebmEbml.idTagName,
          Uint8List.fromList(utf8.encode(name)),
        ),
      );
      simple.add(
        WebmEbml.elementById(
          WebmEbml.idTagString,
          Uint8List.fromList(utf8.encode(tag.$2)),
        ),
      );
      simpleTags.add(
        WebmEbml.elementById(WebmEbml.idSimpleTag, simple.toBytes()),
      );
    }
    final targets = WebmEbml.elementById(
      WebmEbml.idTargets,
      WebmEbml.elementById(
        WebmEbml.idTargetTypeValue,
        Uint8List.fromList(const [50]),
      ),
    );
    final tagPayload = BytesBuilder(copy: false)
      ..add(targets)
      ..add(simpleTags.toBytes());
    return WebmEbml.elementById(
      WebmEbml.idTags,
      WebmEbml.elementById(WebmEbml.idTag, tagPayload.toBytes()),
    );
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

/// 一个待写入的附件（WebM 的封面就是 `Attachments > AttachedFile`）。
class WebmAttachmentData {
  final String name;
  final String mime;
  final String description;
  final Uint8List data;

  const WebmAttachmentData({
    required this.name,
    required this.mime,
    this.description = '',
    required this.data,
  });

  bool get isImage => WebmAttachments.isImage(name, mime);
}

/// 从文件里读到的附件（只记位置，图片本体按需再读）。
class WebmAttachmentRef {
  final String name;
  final String mime;
  final String description;
  final int dataPos;
  final int dataSize;

  const WebmAttachmentRef({
    required this.name,
    required this.mime,
    required this.description,
    required this.dataPos,
    required this.dataSize,
  });

  bool get isImage => WebmAttachments.isImage(name, mime);
}

/// WebM / Matroska 的附件（封面图）读写。
///
/// 规范的 WebM 文档类型里没有附件，但 Matroska 有，ffmpeg / mpv / mkvmerge
/// 都按 `Attachments > AttachedFile` 读封面（mpv 属性页里的
/// `Cover / Cover description / Attachments` 就是它）。写封面只能在容器里
/// 放一个图片附件，不支持「随便塞进某段音频数据」。
class WebmAttachments {
  WebmAttachments._();

  static const Set<String> _imageExts = {
    '.jpg',
    '.jpeg',
    '.png',
    '.webp',
    '.bmp',
    '.gif',
  };

  /// 判断某个附件是不是封面图（按 MIME，其次按文件名后缀）。
  static bool isImage(String name, String mime) {
    if (mime.toLowerCase().startsWith('image/')) return true;
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    return _imageExts.contains(name.substring(dot).toLowerCase());
  }

  /// 读 Attachments 元素里的所有 AttachedFile。
  static Future<List<WebmAttachmentRef>> read(
    RandomAccessFile raf,
    int dataPos,
    int size,
  ) async {
    final out = <WebmAttachmentRef>[];
    final end = dataPos + size;
    var pos = dataPos;
    var guard = 0;
    while (pos < end && guard++ < 128) {
      final file = await WebmEbml.headAt(raf, pos);
      if (file == null) break;
      if (file.id == WebmEbml.idAttachedFile && !file.unknownSize) {
        final ref = await _readAttachedFile(raf, file.dataPos, file.end);
        if (ref != null) out.add(ref);
      }
      final next = file.unknownSize ? end : file.end;
      if (next <= pos) break;
      pos = next;
    }
    return out;
  }

  static String _decodeText(Uint8List bytes) {
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes, allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static Future<WebmAttachmentRef?> _readAttachedFile(
    RandomAccessFile raf,
    int start,
    int end,
  ) async {
    String name = '';
    String mime = '';
    String description = '';
    int? dataPos;
    int dataSize = 0;
    var pos = start;
    var guard = 0;
    while (pos < end && guard++ < 16) {
      final item = await WebmEbml.headAt(raf, pos);
      if (item == null) break;
      switch (item.id) {
        case WebmEbml.idFileName:
          final bytes = await WebmEbml.readAt(raf, item.dataPos, item.size);
          if (bytes != null) name = _decodeText(bytes);
        case WebmEbml.idFileMimeType:
          final bytes = await WebmEbml.readAt(raf, item.dataPos, item.size);
          if (bytes != null) mime = _decodeText(bytes);
        case WebmEbml.idFileDescription:
          final bytes = await WebmEbml.readAt(raf, item.dataPos, item.size);
          if (bytes != null) description = _decodeText(bytes);
        case WebmEbml.idFileData:
          dataPos = item.dataPos;
          dataSize = item.size;
      }
      final next = item.unknownSize ? end : item.end;
      if (next <= pos) break;
      pos = next;
    }
    if (dataPos == null || dataSize <= 0) return null;
    return WebmAttachmentRef(
      name: name,
      mime: mime,
      description: description,
      dataPos: dataPos,
      dataSize: dataSize,
    );
  }

  /// 把若干附件拼成一个完整的 Attachments 元素。
  static Uint8List build(List<WebmAttachmentData> files) {
    final payload = BytesBuilder(copy: false);
    var uid = 1;
    for (final file in files) {
      final item = BytesBuilder(copy: false);
      if (file.description.isNotEmpty) {
        item.add(
          WebmEbml.elementById(
            WebmEbml.idFileDescription,
            Uint8List.fromList(utf8.encode(file.description)),
          ),
        );
      }
      item.add(
        WebmEbml.elementById(
          WebmEbml.idFileName,
          Uint8List.fromList(utf8.encode(file.name)),
        ),
      );
      item.add(
        WebmEbml.elementById(
          WebmEbml.idFileUid,
          WebmEbml.uintBytes(uid++),
        ),
      );
      item.add(
        WebmEbml.elementById(
          WebmEbml.idFileMimeType,
          Uint8List.fromList(utf8.encode(file.mime)),
        ),
      );
      item.add(WebmEbml.elementById(WebmEbml.idFileData, file.data));
      payload.add(WebmEbml.elementById(WebmEbml.idAttachedFile, item.toBytes()));
    }
    return WebmEbml.elementById(WebmEbml.idAttachments, payload.toBytes());
  }

  /// 依据图片内容判断封面文件名与 MIME。
  static (String, String) coverNameAndMime(Uint8List bytes) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return ('cover.png', 'image/png');
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return ('cover.jpg', 'image/jpeg');
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return ('cover.webp', 'image/webp');
    }
    if (bytes.length >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D) {
      return ('cover.bmp', 'image/bmp');
    }
    return ('cover.jpg', 'image/jpeg');
  }
}

/// WebM / Matroska 文件的只读索引。
///
/// 只读元素头（ID + 长度），不读数据区：先扫 Segment 开头到第一个 Cluster
/// 之间的元数据区，顺手解析 SeekHead（`SeekID → 元素位置`）；真要找的元素
/// 不在元数据区时，才按需走一遍顶层元素（`deep`）。
class WebmDocument {
  WebmDocument._({
    required this.segmentOffset,
    required this.segmentDataPos,
    required this.segmentEnd,
    required this.fileLength,
    required this.segmentUnknownSize,
    required this.headElements,
    required this.seekStarts,
  });

  /// Segment 元素起始（ID 第一字节）。
  final int segmentOffset;
  final int segmentDataPos;
  final int segmentEnd;
  final int fileLength;
  final bool segmentUnknownSize;

  /// 元数据区（Segment 开头 → 第一个 Cluster）里的直接子元素。
  final List<WebmElementHead> headElements;

  /// SeekHead 里的 `元素 ID → 元素起始绝对位置`。
  final Map<int, int> seekStarts;

  /// 元数据区最多扫多少个元素（SeekHead / Info / Tracks / Cues 就几个）。
  static const int _maxHeadScan = 64;

  /// 全量遍历时最多看多少个顶层元素（防御损坏文件死循环）。
  static const int _maxWalk = 200000;

  static Future<WebmDocument?> open(
    RandomAccessFile raf,
    int fileLength,
  ) async {
    // 顶层一般是 EBML 头 + Segment；也容忍缺 EBML 头 / 中间夹别的元素的文件
    // （老版本解析器就是这么扫的，别让这种文件突然读不出时长）。
    WebmElementHead? segment;
    var topPos = 0;
    var topGuard = 0;
    while (topPos < fileLength && topGuard++ < 8) {
      final head = await WebmEbml.headAt(raf, topPos);
      if (head == null) break;
      if (head.id == WebmEbml.idSegment) {
        segment = head;
        break;
      }
      final next = head.unknownSize ? fileLength : head.end;
      if (next <= topPos) break;
      topPos = next;
    }
    if (segment == null) return null;
    final segmentOffset = topPos;
    final segmentEnd = segment.unknownSize
        ? fileLength
        : (segment.end <= fileLength ? segment.end : fileLength);
    if (segmentEnd <= segment.dataPos) return null;

    final head = <WebmElementHead>[];
    final seek = <int, int>{};
    var pos = segment.dataPos;
    var guard = 0;
    while (pos < segmentEnd && guard++ < _maxHeadScan) {
      final child = await WebmEbml.headAt(raf, pos);
      if (child == null) break;
      if (child.id == WebmEbml.idCluster) break;
      head.add(child);
      if (child.id == WebmEbml.idSeekHead && !child.unknownSize) {
        await _readSeekHead(raf, child, segment.dataPos, seek);
      }
      final next = child.unknownSize ? segmentEnd : child.end;
      if (next <= pos) break;
      pos = next;
    }

    return WebmDocument._(
      segmentOffset: segmentOffset,
      segmentDataPos: segment.dataPos,
      segmentEnd: segmentEnd,
      fileLength: fileLength,
      segmentUnknownSize: segment.unknownSize,
      headElements: head,
      seekStarts: seek,
    );
  }

  /// 按 ID 找元素（元数据区 + SeekHead 指向的位置）。
  Future<List<WebmElementHead>> findAll(
    RandomAccessFile raf,
    int id, {
    bool deep = false,
  }) async {
    final out = <WebmElementHead>[];
    void add(WebmElementHead? head) {
      if (head == null || head.id != id || head.unknownSize) return;
      if (out.any((item) => item.dataPos == head.dataPos)) return;
      out.add(head);
    }

    for (final head in headElements) {
      add(head);
    }
    final seekStart = seekStarts[id];
    if (seekStart != null) {
      final head = await WebmEbml.headAt(raf, seekStart);
      add(head);
    }
    if (deep) {
      var pos = segmentDataPos;
      var guard = 0;
      while (pos < segmentEnd && guard++ < _maxWalk) {
        final head = await WebmEbml.headAt(raf, pos);
        if (head == null) break;
        add(head);
        final next = head.unknownSize ? segmentEnd : head.end;
        if (next <= pos) break;
        pos = next;
      }
    }
    return out;
  }

  /// 按 ID 找第一个元素。
  Future<WebmElementHead?> find(RandomAccessFile raf, int id) async {
    final list = await findAll(raf, id);
    return list.isEmpty ? null : list.first;
  }

  static Future<void> _readSeekHead(
    RandomAccessFile raf,
    WebmElementHead seekHead,
    int segmentDataPos,
    Map<int, int> out,
  ) async {
    var pos = seekHead.dataPos;
    var guard = 0;
    while (pos < seekHead.end && guard++ < 64) {
      final seek = await WebmEbml.headAt(raf, pos);
      if (seek == null) break;
      if (seek.id == WebmEbml.idSeek && !seek.unknownSize) {
        int? elementId;
        int? elementPos;
        var itemPos = seek.dataPos;
        var itemGuard = 0;
        while (itemPos < seek.end && itemGuard++ < 8) {
          final item = await WebmEbml.headAt(raf, itemPos);
          if (item == null) break;
          if (item.id == WebmEbml.idSeekId ||
              item.id == WebmEbml.idSeekPosition) {
            final bytes = await WebmEbml.readAt(
              raf,
              item.dataPos,
              item.size,
            );
            if (bytes != null) {
              var value = 0;
              for (final byte in bytes) {
                value = (value << 8) | byte;
              }
              if (item.id == WebmEbml.idSeekId) {
                elementId = value;
              } else {
                elementPos = value;
              }
            }
          }
          final next = item.unknownSize ? seek.end : item.end;
          if (next <= itemPos) break;
          itemPos = next;
        }
        if (elementId != null && elementPos != null) {
          final absolute = segmentDataPos + elementPos;
          out.putIfAbsent(elementId, () => absolute);
        }
      }
      final next = seek.unknownSize ? seekHead.end : seek.end;
      if (next <= pos) break;
      pos = next;
    }
  }
}
