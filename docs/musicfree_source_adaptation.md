# MusicFree 音源适配说明

## 目标

在「设置 - 插件管理 - 添加插件」中，除了澜音（cr）与洛雪（lx）格式，还可以直接导入
MusicFree 格式的音源插件，并复用本项目的搜索、播放地址、封面与歌词能力。

参考源码与示例插件：

- MusicFree 源码：`D:\Code\Android_MusicFree`（`src/core/pluginManager/*.ts`、`src/types/plugin.d.ts`）
- 示例插件：`猫头猫 哔哩哔哩 0.3.0.js`、`网易 128k可听vip.js`

## 两种格式的差异

| | 澜音（cr）/ 洛雪（lx） | MusicFree（mf） |
| --- | --- | --- |
| 模块系统 | 直接调用宿主注入的 `cerumusic` / `lx` 全局对象 | CommonJS（`require()` + `module.exports`） |
| 第三方依赖 | 无（脚本自带） | `axios`、`cheerio`、`crypto-js`、`dayjs`、`he`、`qs`、`big-integer` 等 |
| 音源声明 | 脚本显式声明每个音源的 `sourceId` | 只声明一个 `platform` 名称，需要推导音源 id |
| 播放地址 | `musicUrl(source, info, quality)` | `getMediaSource(musicItem, quality)`，音质键为 `low/standard/high/super` |

因此 MusicFree 插件无法直接在 QuickJS 里执行：需要先注入一个 CommonJS 兼容运行时，
再通过适配器把 MusicFree 契约翻译成本项目的插件契约。

## 实现结构

```
assets/plugin_modules/
  musicfree_runtime.js    # require 注册表 + axios 适配层 + 浏览器/Node 垫片
  musicfree_adapter.js    # MusicFree 契约 -> 本项目契约（所有 MusicFree 插件共用）
  crypto-js.js  dayjs.js  he.js  qs.js  big-integer.js  cheerio.js
```

- **适配器与插件源码分离存储**：安装 MusicFree 插件时，插件文件里保存的是适配器脚本，
  原始插件源码另存为 `<插件文件>.source.js`。适配器随 App 升级自动刷新
  （`PluginService._prepareStoredPluginCode`），用户不会停留在旧适配器上。
- **运行时注入顺序**（`PluginHost.loadPlugin`）：
  1. `injectCeruMusicApi()` 注入宿主 API；
  2. `ensurePluginModules()` 注入 MusicFree 运行时与插件 `require()` 到的依赖；
  3. 宿主创建 `module` / `exports`；
  4. 执行适配器（安装 `module.exports` 捕获器、声明契约）；
  5. 在块作用域内执行原始插件源码（`module.exports = {...}` 被捕获器截获）。

### 导出捕获

MusicFree 插件以 `module.exports = {...}` 作为导出方式，而本项目宿主只认
`module.exports.sources` / `pluginInfo` / `sourceActions` 等字段。适配器用
`Object.defineProperty(module, 'exports', { get, set })` 把 `module.exports` 改造成访问器：

- **读取**时返回适配器自己实现的契约对象；
- **写入**时截获原始插件导出，供契约内部使用；
- 全局 `exports` 被重定向到 `__mfLegacyExports`，兼容 `exports.foo = ...` 写法。

`pluginInfo` / `sources` / `sourceActions` 使用惰性 getter：宿主在 30 秒轮询
`module.exports.sources` 与读取元数据都发生在原始插件执行之后，因此能拿到真实数据。

### 音源 id 推导

MusicFree 插件只有 `platform` 名称（如「网易128k」「bilibili」），本项目需要稳定 id。
推导规则同时存在于两侧，必须保持同步：

- Dart：`lib/features/plugin/domain/source_id_mapping.dart`（`SourceIdMapping`）
- JS：`assets/plugin_modules/musicfree_adapter.js`（`__mfSourceIdFromName`）

规则：精确别名 → 关键字（网易/netease/163→`wy`、酷狗/kugou→`kg`、酷我/kuwo→`kw`、
qq→`tx`、咪咕/migu→`mg`、汽水/qsvip→`qsvip`）→ 名称中的 ASCII 片段 → 原始名称。
不再使用 Dart `hashCode`，否则 JS 侧无法复现同一个 id。

### 音质映射与回退

本项目音质标签（`128k` / `320k` / `flac`）与 MusicFree 音质键
（`standard` / `high` / `super`，另有 `low`）互转。`getMediaSource` 只实现部分音质时
（例如「网易128k」只实现 `standard`），适配器按 `请求音质 → standard → high → low → super`
依次尝试，并回填实际拿到的音质标签，避免「能搜到但播不了」。

### musicItem 往返

MusicFree 的 `getMediaSource` / `getLyric` 需要原始 `musicItem`。搜索结果里把它放在
`extra.musicItem`（`MusicInfoForPlugin.extra`），随 `Song.lx` 往返；缺少时用扁平字段
拼一个最小 `musicItem` 兜底（覆盖「内置源搜索 + MusicFree 插件解析播放地址」场景）。

### 依赖注入

`JsEngineService.detectRequiredModules()` 用正则从原始插件源码里提取 `require('xxx')`，
再由 `ensurePluginModules()` 从资产里读出对应 UMD 文件，包成
`(function(){ var module = {exports:{}}; ... __mfRegisterModule(name, module.exports); })()`
后求值注册。未收录的模块返回空对象（与 MusicFree 官方运行时一致）。

`axios` 由运行时按 `cerumusic.request` 桥自行实现（默认导出可调用、`.default` 自引用、
`paramsSerializer`、`responseType`、`validateStatus`、非 2xx 抛 `isAxiosError` 等），
避免引入完整 axios 打包产物。单个依赖注入失败不会中断插件加载，只记录日志并降级，
避免「一个可选依赖拖垮整个插件」。

### 发现页（榜单 / 推荐歌单）

MusicFree 的发现接口接收的是「条目对象」而不是 id：

| MusicFree 方法 | 适配器契约 | 说明 |
| --- | --- | --- |
| `getTopLists()` | `getTopLists()` → `[{id,name,group,coverUrl,description}]` | 分组结果按组名扁平化 |
| `getTopListDetail(topListItem, page)` | `getTopListDetail(id, page)` → `{isEnd,songs,sheet}` | 原始条目按 id 反查缓存 |
| `getRecommendSheetTags()` | `getRecommendSheetTags()` → `[{name,tags:[{id,name}]}]` | `pinned` 放在「推荐」组 |
| `getRecommendSheetsByTag(tagItem, page)` | `getRecommendSheetsByTag(id, page)` → `{isEnd,playlists}` | 歌单 id 同上命名空间 |
| `getMusicSheetInfo(sheetItem, page)` | `getMusicSheetInfo(id, page)` → `{isEnd,songs,sheet}` | 插件回传的续页字段会合并回缓存条目 |

适配器在内存里缓存最近一次拿到的原始条目（`__mfTopListRawCache` /
`__mfSheetTagRawCache` / `__mfSheetRawCache`），按 id 反查后再传给插件；缓存缺失
（例如 App 重启后用持久化 id 打开）时退化为最小 `{ id, title }` 对象——目前见到的
插件都只依赖 `id`。歌单详情里插件回传的 `_trackIds` 一类续页状态会合并回缓存，
避免第二页重新拉整张歌单。任何一步失败都只记日志并返回空结果，不会让插件整体失败。

`capabilities` 暴露插件是否实现了 `topList` / `sheets` / `sheetDetail`。宿主据此决定
该音源是否出现在发现页音源选择器里（没有浏览能力的音源选进去只会是空页面）。

由于本项目的歌单详情页只有一个路由参数，插件来源的歌单 id 会带上音源前缀：

```
mf:sheet:<sourceId>:<Uri.encodeComponent(rawId)>   // 推荐歌单
mf:board:<sourceId>:<Uri.encodeComponent(rawId)>   // 榜单
```

`MusicSourceManager.getPlaylistDetail()` 按前缀路由到插件，榜单卡片与歌单卡片共用
同一条详情链路（内置源仍走原来的 `wy_` / `kg_` 前缀与 `getLeaderboardDetail` 兜底）。

插件来源的歌单 / 榜单详情支持翻页：`getPlaylistDetailPage(playlistId, page)` 按页请求
`getMusicSheetInfo` / `getTopListDetail`，歌单详情页滚动到底部时自动追加下一页，
由插件回传的 `isEnd` 决定何时停止。内置源仍是一次性返回全量歌曲（`isEnd == true`），
不参与翻页。整页都是不可播放歌曲（例如插件过滤掉 VIP 曲目）时会自动往后翻，
最多连续跳过 5 页，避免卡住或无限请求。

内置源优先：当同一个音源 id 同时有内置实现与插件实现（例如同时启用「网易云」内置源
与一个网易 MusicFree 插件）时，发现页使用内置源的榜单 / 歌单实现，而搜索仍然优先走
插件。

### 内置音源的启用与卸载

内置音源无法真正从安装包里删除，所以「设置 → 插件管理」里对内置音源（网易云 /
酷狗 / 酷我 / QQ / 咪咕）提供两种操作：

* **开关**：加入 `disabled_builtin_sources`，该音源不再出现在音源选择器、聚合搜索
  与发现页；
* **卸载**：加入 `removed_builtin_sources`，从列表里移除，可通过「恢复内置音源」
  一键找回。

两者都只影响「能不能被选中」，不影响已经存在歌曲的播放解析（收藏 / 歌单里的网易
歌曲仍然可以正常取播放地址）。状态变化后会清空搜索与歌单缓存，避免陈旧结果里混进
已关闭音源的数据。

### 多插件同时启用

早期版本只允许启用一个插件（澜音 / 洛雪插件通常覆盖全部音源，互相冲突），但
MusicFree 插件往往是单平台的（一个 bilibili 插件 + 一个网易插件），因此改为允许
同时启用多个。多个插件声明同一个音源时，由 `MusicSourceManager` 按插件列表顺序
取第一个匹配的宿主。

## 当前范围

已支持：搜索、播放地址、封面、歌词、音质回退，以及发现页的榜单与推荐歌单。

暂不支持：`getArtistWorks` / `getAlbumInfo` / `importMusicSheet` 等扩展方法——本项目
的插件契约没有对应落点。cheerio 仍然会注入，以免这类插件在加载阶段因缺少依赖而失败。

插件来源的歌单 / 榜单详情会随滚动自动翻页（每页由插件决定，网易插件为 40 条）；
内置源一次性返回全量歌曲，因此不存在翻页概念。

