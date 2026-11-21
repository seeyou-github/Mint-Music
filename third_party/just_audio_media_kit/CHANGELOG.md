## 2.1.0+mint.4 (Mint Music 本地补丁)

mpv / ffmpeg 详细日志接入桌面端日志文件（`mint_music.log`），用于在用户侧 release 包上定位播放问题；同时修正 mint.3 的 fastseek 写入方式：

- mpv 请求日志级别从 `error` 提到 `debug`（`JustAudioMediaKit.mpvLogLevel` 默认值）。
  debug 级别覆盖 mpv 的 `v`（命令 / seek 执行 / 缓存决策）与 ffmpeg 协议层
  （http 请求与响应头、重连），不含 trace 级逐包刷屏。Android 不注册此播放器，
  不受影响。
- `stream.log` 的每条消息经限流后走 `debugPrint`（→ 宿主 main.dart 钩子 →
  exe 同目录 `mint_music.log`，release 也落盘）。限流为每 10s 最多 80 行，
  超量条数在窗口结束时汇总一行（坏帧 / 重连风暴实测一秒几十条，不能逐条落盘）；
  字符串插值只在真正写入时才做。原先只在 debug 构建输出。
- mpv 的 error 级事件照旧单独进 `stream.error`（错误处理白名单逻辑不变），
  提高日志级别不会引入新的错误事件。
- 修正 mint.3：fastseek 不能「读 `demuxer-lavf-o` 现值再追加」——mpv 读属性
  会剥掉 `protocol_whitelist=[a,b,c]` 的方括号，回写后追加的 fflags 被吞进
  垃圾键（`Could not set AVOption rtp,...,fflags='+fastseek'`），修复完全
  失效。改为按 media_kit 1.2.6 real.dart 的默认值整体重建后一次写入。

## 2.1.0+mint.3 (Mint Music 本地补丁)

- mpv 请求日志级别从 `error` 提到 `debug`（`JustAudioMediaKit.mpvLogLevel` 默认值）。
  debug 级别覆盖 mpv 的 `v`（命令 / seek 执行 / 缓存决策）与 ffmpeg 协议层
  （http 请求与响应头、重连），不含 trace 级逐包刷屏。Android 不注册此播放器，
  不受影响。
- `stream.log` 的每条消息经限流后走 `debugPrint`（→ 宿主 main.dart 钩子 →
  exe 同目录 `mint_music.log`，release 也落盘）。限流为每 10s 最多 80 行，
  超量条数在窗口结束时汇总一行（坏帧 / 重连风暴实测一秒几十条，不能逐条落盘）；
  字符串插值只在真正写入时才做。原先只在 debug 构建输出。
- mpv 的 error 级事件照旧单独进 `stream.error`（错误处理白名单逻辑不变），
  提高日志级别不会引入新的错误事件。

## 2.1.0+mint.3 (Mint Music 本地补丁)

修复 Windows 端「暂停状态拖动进度条，mpv 按下载速度把目标位置之前的数据全部拉完（极端情况整首歌），且点播放 / 再拖动又会重新下载」：

- 根因在 mpv（ffmpeg）的 MP3 seek 路径：mp3 demuxer 没有 `read_timestamp`，
  `mp3_seek` 在无 Xing TOC 且未开 `AVFMT_FLAG_FAST_SEEK` 时直接返回 -1，
  `av_seek_frame` 落到 `seek_frame_generic` —— 从已索引的最后一帧起**顺序
  读取数据包**直到目标时间戳，中间的字节全部从 HTTP 连接下载后丢弃
  （libmpv 实测：拖到 11 分钟全程 0 个新 Range 请求，AVIO 统计 `0 seeks`）。
- 已下载的数据不会保留：demuxer 缓存上限只有 `demuxer-max-bytes`（本项目
  4MB），读到的其余部分读后即弃，点播放 / 再拖动仍要重新下载。
- 修复：创建 player 时往 media_kit 写入的 `demuxer-lavf-o` 追加
  `fflags=+fastseek`。mp3_seek 随即走「CBR 字节估算 + mp3_sync 帧同步
  （目标 ±4KB 扫描）」，底层 `avio_seek` 触发 `mp_seek` → 真正的 Range 请求
  （libmpv 实测：拖到 11 分钟时 Range 请求起点 = 11 分钟对应的字节位置）。
  拖动只下载目标位置起的一小段（配合 `demuxer-max-bytes=4MB` 即「拖动仅
  缓存 4MB」），缓存完成后再点播放 / 在缓存窗口内拖动均不再触发下载。
- 代价：VBR 文件的 seek 位置按平均码率估算可能有偏差；在线音乐
  （128k/320k CBR）不受影响。Android（ExoPlayer）不走此路径，行为不变。

上游仓库：https://github.com/Pato05/just_audio_media_kit （上游修复后可移除 `dependency_overrides` 恢复官方包）

## 2.1.0+mint.2 (Mint Music 本地补丁)

修复 Windows 端「整首播完不自动切下一首，进度停在最后一秒且仍显示播放中」：

- 酷我车机 CDN 的转码 FLAC 普遍存在最后一帧坏帧，mpv 曲末打
  `[ffmpeg/audio:error] flac: decode_frame() failed` / `[ad:error] Error decoding audio`，
  但只丢那一帧、播放正常走到 eof（`eof-reached=true`，已用 libmpv 实测验证）。
- media_kit 会把 `ad` / `cplayer` / `stream` 前缀的 error 日志原样转成 `stream.error`；
  mint.1 版的处理逻辑把所有未豁免的错误都当成加载失败、把处理状态改成 `idle`。
- just_audio 收到「非 idle → idle」跳变时会调用 `_setPlatformActive(false)`（等同
  `stop()`）：真实播放器被替换为 idle 平台、事件订阅取消，随后正常发出的
  `completed` 永远送不到宿主，自动切歌（依赖 `ProcessingState.completed`）失效。
- 修复：错误处理改为白名单 —— 只有 `Failed to open` / `No protocol handler` /
  `tcp:` / `http:` 开头（确定表示加载失败）的错误才置 idle，保留「加载失败 →
  上层换源」行为；解码类错误一律忽略。

上游仓库：https://github.com/Pato05/just_audio_media_kit （上游修复后可移除 `dependency_overrides` 恢复官方包）

## 2.1.0+mint.1 (Mint Music 本地补丁)

基于 2.1.0 的本地补丁，未发布上游。修复带同名 `.lrc` 侧栏歌词的本地歌曲无法播放（报「播放歌曲失败」）：

- mpv 默认会自动加载同目录同名文件当外部字幕 / 封面（`sub-auto` 把 `.lrc` 当字幕、`cover-art-auto` 把 `.jpg` 当封面）。`.lrc` 不是 mpv 能解析的字幕格式，mpv 报 `Can not open external file`；media_kit 把 `cplayer` 的 error 日志一律当致命错误，正在加载的媒体被改回 idle 并判成加载失败，同时 `_loadCompleter` 永远不完成，`setAudioSource` 只能靠上层超时。
- 修复：创建 player 时关闭 `sub-auto` 与 `cover-art-auto`（歌词由 App 自己解析，不依赖 mpv）；同时让 `stream.error` 忽略「外部文件打不开」这类错误，兜底旧版 mpv 不认这两个属性的情况。

上游仓库：https://github.com/Pato05/just_audio_media_kit （上游修复后可移除 `dependency_overrides` 恢复官方包）

## 2.1.0

- Implement just_audio_platform_interface 4.5.0 and fix media playing when it's not supposed to ([#23](https://github.com/Pato05/just_audio_media_kit/pull/23), thanks [@ryanheise](https://github.com/ryanheise))
- Fix `setProperty` not available for web causing unable to compile to a web target ([#15](https://github.com/Pato05/just_audio_media_kit/issues/15))
- Bump up media-kit to v1.2.0

## 2.0.6

- Add `ClippingAudioSource` support ([#19](https://github.com/Pato05/just_audio_media_kit/pull/19), thanks [@AyaseFile](https://github.com/AyaseFile))
- Fix InvalidRangeError when there's no `Media` in `Playlist` ([#17](https://github.com/Pato05/just_audio_media_kit/pull/17), thanks [@lvyueyang](https://github.com/lvyueyang) and [@2shrestha22](https://github.com/2shrestha22))

## 2.0.5

- Override duration for [SilenceAudioSource]
- Fix desync issue when entry is removed from [ConcatenatingAudioSource] (Fixes [#12](https://github.com/Pato05/just_audio_media_kit/issues/12))

## 2.0.4

- Support `--prefetch-playlist` for gapless playback (fixes [#11](https://github.com/Pato05/just_audio_media_kit/issues/11))
- Reset `Duration` on track change (fixes [#10](https://github.com/Pato05/just_audio_media_kit/issues/10))
- Set `pitch` to `true` by default (fix `setPitch` not working)

## 2.0.3

- Add `libmpv` parameter to `ensureInitialized` ([#9](https://github.com/Pato05/just_audio_media_kit/issues/9))

## 2.0.2

- Fix: defer setting initial position to when the track starts loading (fixes seeking before loading the track, which seems not to be currently supported by `media_kit`): see [related issue](https://github.com/Pato05/just_audio_media_kit/issues/6) and [`media_kit` related issue](https://github.com/media-kit/media-kit/issues/228)
- Add `SilenceAudioSource` support via anullsrc ([taken from just_audio_mpv](https://github.com/bleonard252/just_audio_mpv/blob/main/lib/src/mpv_player.dart#L137))

## 2.0.1

- Fix issues regarding disposal of current players

## 2.0.0

- **BREAKING: Removed hard dependencies** (Read the installation steps in README to comply!)
- Fix queue insert with index
- Fix moving items in ConcatenatingAudioSource

## 1.0.0

- Make private methods private, as they should've been
- Set position and index on load (and reset bufferedPosition)
- Fix disposePlayer() failing by making it so that if the player was already disposed, it won't throw, since `just_audio` can send out two identical dispose requests.
- More settings
- Update `media_kit` to `^1.1.9`

## 0.0.1

- Initial release
- Linux and Windows support
