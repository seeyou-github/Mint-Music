import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../settings/application/settings_providers.dart';
import '../domain/models/desktop_lyric_settings.dart';
import '../domain/models/lyric_line.dart';
import '../domain/models/song.dart';
import 'lyric_controller.dart';
import 'playback_controller.dart';

/// 当前播放进度对应的歌词行下标。
///
/// 播放进度每 200ms 才会推一次,这里把它收敛成一个 `int`:
/// 只有「当前行真的变了」时才通知监听者重建,避免悬浮歌词窗每 200ms 重绘。
final desktopLyricActiveIndexProvider = Provider<int>((ref) {
  // 未开启时不订阅歌词,避免为桌面歌词提前拉取歌词。
  final enabled = ref.watch(
    desktopLyricSettingsProvider.select((s) => s.enable),
  );
  if (!enabled) return -1;
  final lines = ref.watch(desktopLyricLinesProvider);
  if (lines.isEmpty) return -1;
  final positionMs = ref.watch(
    playbackControllerProvider.select((s) => s.position.inMilliseconds),
  );
  final index = lines.lastIndexWhere((line) => line.startTimeMs <= positionMs);
  // 进度早于第一行的起始时间时,仍然展示第一行。
  return index < 0 ? 0 : index;
});

/// 桌面歌词使用的歌词行。
///
/// 关键：**不能直接透传 `LyricController.state.lines`**。切歌时
/// [LyricController] 会刻意保留上一首的歌词行（避免切歌瞬间歌词区域整屏
/// 闪烁），所以"lines 非空"并不代表这些歌词属于当前播放的歌曲。这里按
/// 「已加载完成 + 属于当前歌曲」过滤，未就绪时返回空，由调用方先清空悬浮窗。
///
/// 同时只在开启时才订阅 [lyricControllerProvider]:歌词控制器一旦被监听
/// 就会在切歌时主动拉取歌词,未开启桌面歌词时不应产生这些请求。
final desktopLyricLinesProvider = Provider<List<LyricLine>>((ref) {
  final enabled = ref.watch(
    desktopLyricSettingsProvider.select((s) => s.enable),
  );
  if (!enabled) return const [];
  final song = ref.watch(
    playbackControllerProvider.select((s) => s.currentSong),
  );
  // 监听整个 state 而不是只 select(lines)：加载开始/结束都要触发重算。
  final lyric = ref.watch(lyricControllerProvider);
  if (!areLyricsReadyForSong(song, lyric)) return const [];
  return lyric.lines;
});

/// 判断歌词状态是否可以展示给桌面歌词（纯函数，便于测试）。
bool areLyricsReadyForSong(Song? song, LyricState lyric) {
  if (song == null) return false;
  // 加载中：lines 仍是上一首的旧歌词
  if (lyric.isLoading) return false;
  // 歌词不属于当前播放的歌曲
  if (lyric.currentSongId != song.id) return false;
  // 来源不一致（例如本地 vs 在线、不同插件音源）时同样不可用；任一侧为空则不比较
  final source = song.lyricSourceId;
  if (lyric.currentSongSource != null &&
      source.isNotEmpty &&
      lyric.currentSongSource != source) {
    return false;
  }
  return true;
}

/// 读取 provider 的函数类型。
///
/// Riverpod 的 `Ref`(非 UI 场景)与 `WidgetRef`(UI 场景)没有公共父类型,
/// 但两者的 `read` 签名一致,因此用这个函数类型做桥接,调用处传 `ref.read`。
typedef ProviderReader = T Function<T>(ProviderListenable<T> provider);

/// 更新桌面歌词配置:先更新内存态,再异步落盘。
void updateDesktopLyricSettings(
  ProviderReader read,
  DesktopLyricSettings Function(DesktopLyricSettings current) update,
) {
  final current = read(desktopLyricSettingsProvider);
  final next = update(current);
  if (next == current) return;
  read(desktopLyricSettingsProvider.notifier).state = next;
  unawaited(_saveDesktopLyricSettings(read, next));
}

Future<void> _saveDesktopLyricSettings(
  ProviderReader read,
  DesktopLyricSettings settings,
) async {
  try {
    final svc = await read(settingsServiceProvider.future);
    await svc.setDesktopLyricSettings(settings.encode());
  } catch (_) {
    // 持久化失败不影响本次会话内的显示。
  }
}
