# Changelog

## [未发布]

### 新增
- 支持导入 MusicFree 格式音源插件（内置 CommonJS 运行时与 axios/cheerio/crypto-js/dayjs/he/qs/big-integer 依赖）
- MusicFree 插件音源 id 自动推导（网易/QQ/酷狗/酷我/咪咕/汽水等平台名映射到内置音源 id）
- MusicFree 音质自动回退（插件只实现部分音质时按 请求音质 → standard → high → low → super 尝试）

## [1.0.1] - 2026-08-14

### 新增
- 多音源在线音乐：网易云、QQ音乐、酷狗、酷我、咪咕
- 跨音源自动换源与音质切换
- AMLL Apple Music 风格逐字歌词
- 本地音乐扫描与播放
- 下载中心（文件名格式、标签写入、仅 WiFi 下载）
- 音效增强：均衡器、低音增强、环绕音效、声道平衡
- LX 风格 JS 音源插件导入
- 浅色 / 深色主题与主题色自定义
- 播放记忆、启动自动续播、倍速播放

### 开源
- 首次公开发布，添加 MIT 许可证、README 与 CI
