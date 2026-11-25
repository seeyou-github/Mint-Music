import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../../../player/domain/models/song.dart';
import '../../../player/domain/services/lyric_text_formatter.dart';
import '../../../../shared/services/cover_fetcher.dart';
import 'audio_tag_writer.dart';

class TagWriteService {
  static const _channel = MethodChannel('com.mintmusic/tag_writer');

  /// 原生标签通道是否可用。
  ///
  /// Windows 等桌面端根本没注册这个通道，每首歌都去 invoke 一次的话会抛
  /// [MissingPluginException] 并在日志里留下一条「无原生实现」。第一次失败
  /// 后记住结果，后面直接走纯 Dart。
  static bool? _nativeChannelAvailable;

  /// 是否还值得调用原生通道（未知 = 试一次）。
  static bool get _nativeUsable => _nativeChannelAvailable != false;

  /// 原生通道在 Android 上真正写得进去、而纯 Dart 又写不了的扩展名
  /// （Android 侧用 jaudiotagger；wav 在原生里被显式跳过）。
  ///
  /// m4a / mp4 同时列在这里和 [AudioTagWriter]：纯 Dart 已能写，桌面端走
  /// 纯 Dart；Android 上仍优先用原生 jaudiotagger，失败再回落纯 Dart。
  static const Set<String> _androidNativeExts = {
    '.m4a',
    '.mp4',
    '.ogg',
    '.wma',
  };

  /// iOS 侧用 AVFoundation，只认 mp3（ID3）与 m4a / mp4 / aac（iTunes）。
  static const Set<String> _iosNativeExts = {'.m4a', '.mp4', '.aac'};

  /// 这些格式能不能把封面 / 歌词写进音频文件**本身**。
  ///
  /// 判定依据是「这台机器上真有可用的写入实现」，而不是「格式理论上支持」：
  ///
  /// * mp3（ID3）/ flac（Vorbis）/ m4a·mp4（iTunes ilst）：纯 Dart 就能写，
  ///   任何平台都算支持；
  /// * ogg / wma：只有 Android 的原生通道（jaudiotagger）能写；
  /// * iOS 只多认 aac（AVFoundation）；
  /// * wav 在原生实现里被显式跳过，也算不支持。
  ///
  /// 写不进去的格式既不该下载封面、也不该在下载目录里留一个同名 `.lrc`
  /// 和一个同名封面图 —— 那只是多两份用户用不上、删歌时还容易落下的文件。
  static bool supportsEmbeddedTags(String filePath) {
    final ext = _extOf(filePath);
    // mp3 / flac / m4a / mp4 走纯 Dart，跟平台无关。
    if (AudioTagWriter.supports(filePath)) return true;
    // 已经确认过这次运行没有原生通道（桌面端的第一次尝试就会确认）。
    if (_nativeChannelAvailable == false) return false;
    if (kIsWeb) return false;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _androidNativeExts.contains(ext);
      case TargetPlatform.iOS:
        return _iosNativeExts.contains(ext);
      default:
        return false;
    }
  }

  /// 这些格式能不能把封面写进去（是否把封面写进音频文件**本身**的另一半）。
  ///
  /// 与 [supportsEmbeddedTags] 的区别：webm / weba 能写标签和歌词（EBML 的
  /// Tags 元素），但 WebM 规范不支持附件，封面写不进去；aac / 桌面端的
  /// ogg、wma 等更是两样都不行。
  static bool supportsEmbeddedArtwork(String filePath) {
    if (AudioTagWriter.supportsArtwork(filePath)) return true;
    if (_nativeChannelAvailable == false) return false;
    if (kIsWeb) return false;
    final ext = _extOf(filePath);
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _androidNativeExts.contains(ext);
      case TargetPlatform.iOS:
        return _iosNativeExts.contains(ext);
      default:
        return false;
    }
  }

  /// 标签写入结果：true 表示封面已成功写入（或本次不要求写封面）。
  ///
  /// 封面失败时下载列表会给出提示，但歌曲本身的下载状态仍然是成功。
  Future<bool> processSongFiles(
    String songPath,
    Song songInfo, {
    required bool basicInfo,
    required bool cover,
    required bool lyrics,
    required bool downloadLyrics,
    required String lyricFormat,
    List<String> coverUrls = const <String>[],
    Uint8List? preloadedCover,
  }) async {
    final file = File(songPath);
    if (!await file.exists()) return true;
    if (!_isAudioFile(songPath)) return true;

    // 这个格式写不进封面 / 歌词（所有平台的 aac / wav，桌面端的 ogg / wma
    // 等）：不去下载封面，也不往下载目录里丢同名 .lrc / 封面图。
    // 以前会「写不进去就退化成旁挂文件」，结果下载目录里躺着一堆播放器
    // 根本不认识的伴生文件，歌里依旧没有封面和歌词。
    if (!supportsEmbeddedTags(songPath)) {
      return true;
    }

    debugPrint(
      '[TagWriteService] processSongFiles: path=$songPath, basicInfo=$basicInfo, cover=$cover, lyrics=$lyrics, downloadLyrics=$downloadLyrics, lyricFormat=$lyricFormat',
    );

    final baseName = _baseNameWithoutExt(songPath);
    final dirName = file.parent.path;
    // 这个格式能不能把封面写进文件（webm / weba 只能写标签和歌词）：
    // 写不进去就不下载、也不留一张同名单图。
    final canEmbedArtwork = supportsEmbeddedArtwork(songPath);
    String? coverPath;
    Uint8List? coverBytes;
    // 标签是否已成功写入文件（原生实现或纯 Dart 兜底）。
    bool embedded = false;

    try {
      if (cover && canEmbedArtwork) {
        // 候选地址：歌曲自带的封面 + 额外传入的地址（歌曲自带 / 高清封面），
        // 任一能下载成功即可。
        final candidates = <String>[];
        void addCandidate(String? url) {
          if (url == null || url.isEmpty) return;
          if (!candidates.contains(url)) candidates.add(url);
        }

        addCandidate(songInfo.coverUrl);
        for (final url in coverUrls) {
          addCandidate(url);
        }

        if (preloadedCover != null && preloadedCover.isNotEmpty) {
          // 列表里已经加载并缓存过这张封面，直接复用，不再走网络。
          coverBytes = preloadedCover;
          debugPrint(
            '[TagWriteService] 使用已缓存封面 (${preloadedCover.length} bytes)',
          );
        } else if (candidates.isEmpty) {
          debugPrint('[TagWriteService] 歌曲没有封面地址，跳过封面写入');
        } else {
          try {
            // 先把所有候选地址的本地缓存查一遍，都没有缓存才走网络；
            // 网络下载单张封面最多等待 30 秒。
            debugPrint('[TagWriteService] 获取封面: $candidates');
            final bytes = await CoverFetcher.fetchAny(candidates);
            if (bytes != null && bytes.isNotEmpty) {
              coverBytes = bytes;
            }
          } catch (e) {
            debugPrint('[TagWriteService] 获取封面失败: $e');
          }
        }

        if (coverBytes != null && coverBytes.isNotEmpty) {
          try {
            final coverExt = _coverExtFromBytes(
              coverBytes!,
              songInfo.coverUrl ?? '',
            );
            coverPath = '$dirName${Platform.pathSeparator}$baseName$coverExt';
            await File(coverPath).writeAsBytes(coverBytes!);
            debugPrint(
              '[TagWriteService] 封面文件已写入: $coverPath (${coverBytes!.length} bytes)',
            );
          } catch (e) {
            debugPrint('[TagWriteService] 保存封面文件失败: $e');
            coverPath = null;
          }
        } else if (candidates.isNotEmpty) {
          debugPrint('[TagWriteService] 封面获取失败: $candidates');
        }
      }

      // 平台给的「歌词」未必是歌词：网易云给纯音乐返回的常常是「作曲 : Fenty」
      // 「风格：嘻哈说唱」这类曲目信息（见日志里的 `lrc=has 14 chars`）。
      // 这种文本没有时间轴，写进标签 / 旁挂 lrc 只会让播放器显示一行莫名其
      // 妙的字，所以先确认「至少有一行带时间轴」再写。
      //
      // 顺序很重要：先把平台原文整理成「要写进文件的文本」，再判时间轴。
      // 逐字歌词的原文（QQ 的 QRC、网易的 YRC）行首是 `[起点,时长]`，没有
      // `[mm:ss]`；直接拿原文判会把它当「不是歌词」整段丢掉（日志里
      // `lrc=has 3265 / crlyric=has 10114` 却写不进文件，就是这个原因）。
      final rawLyric = songInfo.lrc ?? '';
      final lyricText = rawLyric.isEmpty
          ? ''
          : (lyricFormat == 'word-by-word'
                ? LyricTextFormatter.preferWordByWord(rawLyric)
                : LyricTextFormatter.toStandardLrc(rawLyric));
      final hasRealLyric =
          lyricText.isNotEmpty && LyricTextFormatter.hasTimeline(lyricText);
      if (downloadLyrics && hasRealLyric) {
        try {
          final lrcPath = '$dirName${Platform.pathSeparator}$baseName.lrc';
          await File(lrcPath).writeAsString(lyricText);
          debugPrint('[TagWriteService] 歌词文件已保存: $lrcPath');
        } catch (e) {
          debugPrint('[TagWriteService] 单独下载歌词文件失败: $e');
        }
      }

      final lrcToEmbed = lyrics && hasRealLyric ? lyricText : null;

      // 对齐 CeruMusic: basic info 始终写入（title, artist, album, albumArtist）
      final useBasicInfo = basicInfo;
      final useArtwork = cover && coverBytes != null;

      final titleStr = useBasicInfo
          ? (songInfo.title.isNotEmpty ? songInfo.title : '未知曲目')
          : null;
      final artistStr = useBasicInfo
          ? (songInfo.artist.isNotEmpty ? songInfo.artist : '未知艺术家')
          : null;
      final albumStr = useBasicInfo
          ? (songInfo.album.isNotEmpty ? songInfo.album : '未知专辑')
          : null;
      final albumArtistStr = useBasicInfo
          ? (songInfo.artist.isNotEmpty ? songInfo.artist : '未知艺术家')
          : null;
      // 年份：Song.year 本来就是 int，转成标签用的字符串（ID3 TYER /
      // Vorbis DATE / MP4 ©day）。为空就不写，避免把文件里原有的年份冲掉。
      final yearStr = useBasicInfo && songInfo.year != null
          ? songInfo.year.toString()
          : null;

      if (useArtwork) {
        debugPrint(
          '[TagWriteService] 写入标签+封面: title=$titleStr, artist=$artistStr, album=$albumStr, year=$yearStr, hasLyrics=${lrcToEmbed != null}, artworkSize=${coverBytes?.length}',
        );
        embedded = await _writeTagsAndArtwork(
          songPath,
          title: titleStr,
          artist: artistStr,
          album: albumStr,
          albumArtist: albumArtistStr,
          year: yearStr,
          lyrics: lrcToEmbed,
          artwork: coverBytes!,
        );
      } else if (useBasicInfo || lrcToEmbed != null) {
        debugPrint(
          '[TagWriteService] 写入标签: title=$titleStr, artist=$artistStr, album=$albumStr, year=$yearStr, hasLyrics=${lrcToEmbed != null}',
        );
        embedded = await _writeTags(
          songPath,
          title: titleStr,
          artist: artistStr,
          album: albumStr,
          albumArtist: albumArtistStr,
          year: yearStr,
          lyrics: lrcToEmbed,
        );
      } else {
        debugPrint('[TagWriteService] 无需写入标签');
      }

      // 只有「本来能写、这次写失败了」才退化为同名 .lrc（mp3 / flac 写失败
      // 时播放器仍能读到旁挂歌词）。格式本身不支持内嵌的，在入口就被拦下了，
      // 不会走到这里，下载目录里也就不会多出伴生文件。
      if (!embedded && lrcToEmbed != null && lrcToEmbed.isNotEmpty) {
        try {
          final lrcPath = '$dirName${Platform.pathSeparator}$baseName.lrc';
          await File(lrcPath).writeAsString(lrcToEmbed);
          debugPrint('[TagWriteService] 歌词已保存为独立文件: $lrcPath');
        } catch (e) {
          debugPrint('[TagWriteService] 保存歌词文件失败: $e');
        }
      }
    } catch (e) {
      debugPrint('[TagWriteService] 写入音乐元信息或LRC文件失败: $e');
    } finally {
      // 封面已内嵌进音频文件时删除临时图片；没有内嵌时保留为同名单图片。
      if (coverPath != null && embedded) {
        final coverFile = File(coverPath);
        if (await coverFile.exists()) {
          await coverFile.delete().catchError((_) {});
          debugPrint('[TagWriteService] 临时封面文件已删除: $coverPath');
        }
      } else if (coverPath != null) {
        debugPrint('[TagWriteService] 封面保留为独立文件: $coverPath');
      }
    }

    // 封面结果：没有开启封面写入时视为正常。
    // 拿到了封面图片但没能写进音频文件时同样算失败，下载列表会提示「无封面」，
    // 避免出现「看起来写入成功、文件里其实没有封面」的情况。
    if (!cover) return true;
    if (coverBytes == null || coverBytes.isEmpty) return false;
    return embedded;
  }

  /// 依据图片内容判断扩展名（URL 后缀可能不准，图片实际格式更可靠）。
  String _coverExtFromBytes(Uint8List bytes, String url) {
    if (bytes.length >= 4 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return '.png';
    }
    if (bytes.length >= 12 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return '.webp';
    }
    return _resolveCoverExt(url, null);
  }

  /// 写入基础信息与歌词。
  ///
  /// 优先走原生实现（Android）；平台没有原生实现时（Windows 等桌面端）
  /// 退化为纯 Dart 写入 ID3/FLAC 标签。返回是否写入成功。
  Future<bool> _writeTags(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? year,
    String? lyrics,
  }) async {
    final args = <String, dynamic>{
      'filePath': filePath,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (albumArtist != null) 'albumArtist': albumArtist,
      if (year != null) 'year': year,
      if (lyrics != null) 'lyrics': lyrics,
    };
    try {
      if (_nativeUsable) {
        debugPrint('[TagWriteService] _writeTags args: $args');
        await _channel.invokeMethod<bool>('writeTags', args);
        _nativeChannelAvailable = true;
        debugPrint('[TagWriteService] _writeTags 成功');
        return true;
      }
    } on PlatformException catch (e) {
      // 通道在，只是这次写失败：照样走纯 Dart 兜底。
      _nativeChannelAvailable = true;
      debugPrint(
        '[TagWriteService] writeTags PlatformException: ${e.code} - ${e.message}',
      );
    } on MissingPluginException catch (e) {
      // 桌面端没有这个通道：记住，后面不再每首歌都抛一次。
      _nativeChannelAvailable = false;
      debugPrint('[TagWriteService] writeTags 无原生实现，改用纯 Dart: ${e.message}');
    }
    return _writeTagsFallback(
      filePath,
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      year: year,
      lyrics: lyrics,
    );
  }

  Future<void> _writeArtwork(String filePath, Uint8List artwork) async {
    try {
      debugPrint(
        '[TagWriteService] _writeArtwork: path=$filePath, size=${artwork.length}',
      );
      await _channel.invokeMethod<bool>('writeArtwork', {
        'filePath': filePath,
        'artwork': artwork,
      });
      debugPrint('[TagWriteService] _writeArtwork 成功');
    } on PlatformException catch (e) {
      debugPrint(
        '[TagWriteService] writeArtwork PlatformException: ${e.code} - ${e.message}',
      );
      rethrow;
    }
  }

  /// 写入基础信息、歌词与封面。
  ///
  /// 优先走原生实现（Android）；平台没有原生实现时（Windows 等桌面端）
  /// 退化为纯 Dart 写入 ID3/FLAC 标签。返回是否写入成功。
  Future<bool> _writeTagsAndArtwork(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? year,
    String? lyrics,
    Uint8List? artwork,
  }) async {
    try {
      // 桌面端已经确认没有原生实现时直接走纯 Dart，不再逐首歌抛异常。
      if (_nativeUsable) {
        final args = <String, dynamic>{
          'filePath': filePath,
          if (title != null) 'title': title,
          if (artist != null) 'artist': artist,
          if (album != null) 'album': album,
          if (albumArtist != null) 'albumArtist': albumArtist,
          if (year != null) 'year': year,
          if (lyrics != null) 'lyrics': lyrics,
          if (artwork != null) 'artwork': artwork,
        };
        debugPrint(
          '[TagWriteService] _writeTagsAndArtwork args: filePath=$filePath, title=$title, artist=$artist, album=$album, albumArtist=$albumArtist, year=$year, hasLyrics=${lyrics != null}, hasArtwork=${artwork != null}',
        );
        await _channel.invokeMethod<bool>('writeTagsAndArtwork', args);
        _nativeChannelAvailable = true;
        debugPrint('[TagWriteService] _writeTagsAndArtwork 成功');
        return true;
      }
    } on PlatformException catch (e) {
      _nativeChannelAvailable = true;
      debugPrint(
        '[TagWriteService] writeTagsAndArtwork PlatformException: ${e.code} - ${e.message}',
      );
    } on MissingPluginException catch (e) {
      _nativeChannelAvailable = false;
      debugPrint(
        '[TagWriteService] writeTagsAndArtwork 无原生实现，改用纯 Dart: ${e.message}',
      );
    }
    return _writeTagsFallback(
      filePath,
      title: title,
      artist: artist,
      album: album,
      albumArtist: albumArtist,
      year: year,
      lyrics: lyrics,
      artwork: artwork,
    );
  }

  /// 纯 Dart 兜底实现（Windows 等没有原生标签写入能力的平台）。
  Future<bool> _writeTagsFallback(
    String filePath, {
    String? title,
    String? artist,
    String? album,
    String? albumArtist,
    String? year,
    String? lyrics,
    Uint8List? artwork,
  }) async {
    // 纯 Dart 实现了 mp3 / flac / m4a·mp4。写不进内嵌标签的格式（aac、ogg…）
    // 在 [processSongFiles] 入口就已经被拦下（不下载封面、不写伴生文件），
    // 这里只是兜底：万一还有别的调用方进来，也不要硬试一遍再打「失败」。
    if (!AudioTagWriter.supports(filePath)) {
      debugPrint('[TagWriteService] 跳过内嵌标签（${_extOf(filePath)} 不支持纯 Dart 写入）');
      return false;
    }
    try {
      final ok = await AudioTagWriter.write(
        filePath,
        title: title,
        artist: artist,
        album: album,
        albumArtist: albumArtist,
        year: year,
        lyrics: lyrics,
        artwork: artwork,
      );
      debugPrint(
        '[TagWriteService] 纯 Dart 写入标签: ${ok ? "成功" : "失败"} ($filePath)',
      );
      return ok;
    } catch (e) {
      debugPrint('[TagWriteService] 纯 Dart 写入标签失败: $e');
      return false;
    }
  }

  bool _isAudioFile(String filePath) {
    final ext = filePath.substring(filePath.lastIndexOf('.')).toLowerCase();
    return [
      '.mp3',
      '.flac',
      '.wav',
      '.aac',
      '.m4a',
      '.ogg',
      '.wma',
    ].contains(ext);
  }

  /// 取小写扩展名（含点）。路径里可能混用 '/' 和 '\'，两边都要找。
  static String _extOf(String filePath) {
    final lastSlash = filePath.lastIndexOf('/');
    final lastBackslash = filePath.lastIndexOf('\\');
    final lastSep = lastSlash > lastBackslash ? lastSlash : lastBackslash;
    final lastDot = filePath.lastIndexOf('.');
    if (lastDot <= lastSep) return '';
    return filePath.substring(lastDot).toLowerCase();
  }

  String _baseNameWithoutExt(String filePath) {
    // 路径里可能混用 '/' 和 '\'（Windows 的下载路径尤其如此），
    // 只按 Platform.pathSeparator 找会拿到多余的目录片段，
    // 导致同名封面 / 歌词文件写到非法路径。
    final lastSlash = filePath.lastIndexOf('/');
    final lastBackslash = filePath.lastIndexOf('\\');
    final lastSep = lastSlash > lastBackslash ? lastSlash : lastBackslash;
    final lastDot = filePath.lastIndexOf('.');
    if (lastDot <= lastSep) return filePath.substring(lastSep + 1);
    return filePath.substring(lastSep + 1, lastDot);
  }

  String _resolveCoverExt(String imgUrl, String? contentType) {
    final validExts = {'.jpg', '.jpeg', '.png', '.webp', '.bmp'};
    String? urlExt;
    try {
      final uri = Uri.parse(imgUrl);
      final pathname = uri.path;
      final i = pathname.lastIndexOf('.');
      if (i != -1) {
        urlExt = pathname.substring(i).toLowerCase();
      }
    } catch (_) {}

    if (urlExt != null && validExts.contains(urlExt)) {
      return urlExt == '.jpeg' ? '.jpg' : urlExt;
    }

    if (contentType != null) {
      if (contentType.contains('image/png')) return '.png';
      if (contentType.contains('image/webp')) return '.webp';
      if (contentType.contains('image/jpeg') ||
          contentType.contains('image/jpg'))
        return '.jpg';
      if (contentType.contains('image/bmp')) return '.bmp';
    }

    return '.jpg';
  }
}
