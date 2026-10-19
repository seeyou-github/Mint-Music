# Changelog

## [未发布]

### 新增
- 支持导入 MusicFree 格式音源插件（内置 CommonJS 运行时与 axios/cheerio/crypto-js/dayjs/he/qs/big-integer 依赖）
- MusicFree 插件音源 id 自动推导（网易/QQ/酷狗/酷我/咪咕/汽水等平台名映射到内置音源 id）
- MusicFree 音质自动回退（插件只实现部分音质时按 请求音质 → standard → high → low → super 尝试）
- MusicFree 插件支持发现页内容：榜单（`getTopLists` / `getTopListDetail`）与推荐歌单（`getRecommendSheetTags` / `getRecommendSheetsByTag` / `getMusicSheetInfo`）
- 插件支持同时启用多个：单平台的 MusicFree 插件（如 bilibili + 网易）可以一起使用，声明同一音源时按插件列表顺序取第一个宿主
- 插件管理页新增「内置音源」区块：内置音源可关闭开关、可卸载，并支持「恢复内置音源」
- Windows 版加入 media_kit（libmpv）桌面音频后端
- 设置-播放设置新增「当前音源播放失败自动切换音源」开关（默认关闭）
- Windows 端支持鼠标侧键「后退」：与系统返回键等效，可关闭弹窗并返回上一页
- Windows / 宽屏下播放器移入左侧导航栏底部：第一行封面 + 曲名 / 歌手（曲名过长滚动，点击打开播放页），第二行剩余时间，第三行播放控件

### 修复
- 修复 Windows 版任何播放/试听校验都抛 `MissingPluginException`（just_audio 在桌面端没有原生实现）
- 修复发现页音源切换不显示已导入的 MusicFree 音源（现在列出实现了榜单 / 推荐歌单的插件音源）
- 桌面端不再初始化 audio_service / audio_session（两者都没有 Windows 实现），改为直接创建播放器 handler
- 插件测试在缺少音频后端时只提示「当前平台无法试听校验」，不再把播放地址误判为插件失败
- 播放失败不再自动播放下一首：当前音源失败、或换源后所有音源都失败时停止播放，交由用户手动操作（「自动切换音源」默认关闭）
- 修复 MusicFree 插件歌单 / 榜单详情滚动到底不再加载：现在按插件回传的 `isEnd` 逐页追加（内置源仍一次返回全量）
- 修复 MusicFree 插件的榜单 / 歌单封面发糊：适配器统一把网易 CDN 的 `?param=NyN` 缩略图提升到 400x400（与内置音源一致），并补全协议
- 修复 Windows / 宽屏下二级页面（歌单详情、榜单详情、搜索、播放页、设置子页面等）遮挡左侧导航栏：导航栏改为常驻在路由外层，二级页面只占用右侧内容区

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
