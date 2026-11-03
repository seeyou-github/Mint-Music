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
