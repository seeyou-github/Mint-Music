# 洛雪音源适配说明

## 目标

本项目的洛雪音源宿主需要尽量对齐 Sollin-Music 的实现方式，让用户导入的 LX 音源脚本可以稳定使用搜索、播放地址、封面与歌词能力。

参考源码：

- `D:\软件\下载\Sollin-Music-Desktop-main\Sollin-Music-Desktop-main\electron\lxSourcePreload.ts`
- `D:\软件\下载\Sollin-Music-Desktop-main\Sollin-Music-Desktop-main\electron\lxSourceRuntime.ts`
- `D:\软件\下载\Sollin-Music-Desktop-main\Sollin-Music-Desktop-main\electron\lxSourceShared.ts`
- `D:\软件\下载\Sollin-Music-Desktop-main\Sollin-Music-Desktop-main\src\services\lxSource.ts`

## 宿主契约

`lx_plugin_converter.dart` 现在按 Sollin 的 `lx` 全局对象形态注入：

- `lx.request(url, options, callback)` 支持洛雪常用回调签名 `(err, resp, body)`，同时兼容 Promise 调用。
- `lx.send('inited', { sources })` 使用单次初始化守卫，重复初始化会拒绝。
- `lx.on('request', handler)` 保存音源脚本注册的请求处理器。
- `lx.EVENT_NAMES`、`lx.currentScriptInfo`、`lx.version`、`lx.apiVersion`、`lx.env` 均已补齐。
- `lx.utils.buffer`、`lx.utils.crypto`、`lx.utils.zlib` 对齐洛雪脚本常用工具入口。

## 请求与结果归一化

洛雪脚本的 `musicUrl` 请求统一转为：

```json
{
  "source": "tx",
  "action": "musicUrl",
  "info": {
    "type": "320k",
    "musicInfo": {}
  }
}
```

播放地址结果兼容以下形态：

- 裸字符串：`https://...`
- `{ "url": "https://..." }`
- `{ "data": { "url": "https://..." } }`
- `{ "body": { "data": { "url": "https://..." } } }`

## 歌曲元数据

`Song.lx` 用于保存插件搜索结果里的平台特定字段，后续获取播放地址、歌词、封面时会完整回传给脚本。重点字段包括：

- `songmid`、`songId`、`hash`
- `albumId`、`albumMid`、`strMediaMid`
- `copyrightId`、`interval`
- `types`、`_types`、`typeUrl`
- `lrcUrl`、`mrcUrl`、`trcUrl`

这样可以避免“搜索能搜到，但播放地址或歌词拿不到”的问题。

## 原生桥接

`js_engine_service.dart` 提供以下桥接能力：

- HTTP：统一返回 `body`、`statusCode`、`headers`。
- MD5：JS 侧同步实现，避免洛雪脚本把 Promise 当字符串使用。
- AES：Dart 侧用 `pointycastle` 实现 CBC/ECB + PKCS7。
- RSA：Dart 侧解析 PEM 公钥并按 `RSA_NO_PADDING` 左填充到密钥长度后加密。
- zlib：Dart 侧用 `archive` 实现 inflate/deflate，JS 侧以字节数组返回。

## 已知边界

Flutter JS 通道本身是异步模型，因此 AES、RSA、zlib 通过 Promise 返回。大多数洛雪脚本在网络与加密流程中本来就是异步链路；如果遇到极少数脚本同步调用 AES/RSA 并立即 `.toString()`，后续需要补纯 JS AES/RSA 实现。

---

# 音源能力声明协议（插件作者必读）

> 权威定义在 `lib/features/plugin/domain/plugin_types.dart`（`PluginSourceInfo` /
> `SourceLoginSpec` / `SourceCredentialSpec` / `SourceLoginState`），本文是面向插件作者的
> 完整说明。**新写插件照这里填即可；少写字段不会报错，会按下面的缺省规则处理。**

## 1. 为什么需要声明

宿主不再「假装每个音源都支持全部音质」。音质切换菜单、下载音质菜单、需登录档位的置灰，
全部由插件在 `sources[id]` 里声明的字段驱动。插件不声明，界面就只能回退到平台默认档位
并标注「未声明」，用户很可能选到插件根本给不出的音质。

## 2. 完整声明示例

```js
const sources = {
  wy: {
    // ===== 必填 =====
    name: '网易云音乐',       // 展示名
    type: 'music',            // 固定 'music'，表示这是一个音乐音源

    // ===== 能力声明 =====
    // 插件支持哪些 action（小写匹配）。缺省 = ['musicUrl']。
    // musicUrl  播放 / 下载地址（必需）
    // loginStatus 主动查询登录态（可选，填了就支持「检测登录态」按钮）
    // 其余：musicSearch / lyric / pic / sheet / topList …
    actions: ['musicUrl', 'musicSearch', 'lyric', 'loginStatus'],

    // ===== 音质声明（本协议重点）=====
    // 播放音质：音质切换菜单只显示这里列出的档位，**数组顺序即菜单顺序**。
    // 宿主不会帮你补档位，也不会打乱顺序。
    qualitys: ['128k', '320k', 'flac', 'flac24bit'],

    // 下载音质：下载菜单 + 下载音质校验用这个列表。
    // 不写 = 等于 qualitys（老插件行为完全不变）。
    downloadQualitys: ['128k', '320k', 'flac'],

    // 登录门槛：高音质依赖登录态时才写。
    login: {
      required: true,                  // 高音质是否必须登录
      freeQualitys: ['128k', '320k'],  // 未登录时**真的**还能播的档位
      state: 'loggedOut',              // 静态初始态，运行时会被检测结果覆盖
    },

    // 需要用户填写的凭据。宿主会在「插件管理 → 该插件」渲染输入框，
    // 并在脚本执行前通过 lx.getUserVariables() 注入。
    credentials: [
      {
        key: 'MUSIC_U',                 // 变量名，插件侧用 vars.MUSIC_U 取
        label: 'MUSIC_U',               // 输入框标题
        secret: true,                   // true = 密码样式（cookie/token 都该是 true）
        hint: '浏览器登录 music.163.com → F12 → Application → Cookies 里复制 MUSIC_U',
      },
    ],
  },
};
lx.send('inited', { sources });
```

## 3. 字段逐项说明

### 3.1 `qualitys`（播放音质）

| 项目 | 规则 |
| --- | --- |
| 作用 | 「音质切换」菜单的数据源；同时是播放时的目标音质 |
| 顺序 | 数组顺序 = 菜单顺序，宿主不排序 |
| 缺省 | 不写 → 宿主回退到该平台默认档位，并在插件管理页标注「未声明」 |
| 义务 | 列表里的档位必须是插件**真的能给**的。给了却给不出，会触发下面的「音质不匹配」拒绝逻辑 |

### 3.2 `downloadQualitys`（下载音质）

| 项目 | 规则 |
| --- | --- |
| 作用 | 下载音质菜单、批量下载音质选择、下载任务的音质校验 |
| 缺省 | 不写 → 等于 `qualitys` |
| 典型场景 | 站点「能播 320k，但下载只放 128k」，只写 `['128k']` 即可，菜单就不会误导用户 |

### 3.3 `login`（登录门槛）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `required` | bool | 高音质是否依赖登录。`false` / 不写 = 不做登录限制 |
| `freeQualitys` | string[] | 未登录时仍真实可用的档位。**必须准**，写大了用户会以为能免费听无损 |
| `state` | string | 静态初始态：`loggedIn` / `loggedOut` / `expired` / `unknown` |

宿主置灰规则（很重要，避免插件作者困惑）：

- 只有登录态**确定为** `loggedOut` 或 `expired` 时，才会把
  「`qualitys` 里但不在 `freeQualitys` 里」的档位置灰。
- 登录态是 `unknown`（默认）时**永远不会置灰**——宿主不知道就不拦，宁可让用户试。
- 置灰的档位点了不发请求，只弹提示引导去填凭据。

### 3.4 `credentials`（凭据）

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `key` | string | 变量名，插件里用 `vars[key]` 读 |
| `label` | string | 输入框标题，缺省用 `key` |
| `secret` | bool | `true` 时输入框打码（cookie / token / api key 都应该 `true`） |
| `hint` | string | 输入框下方灰色帮助文案，写清楚去哪儿拿 |

存储与安全：凭据保存在本地设置（明文 JSON，键 `plugin_credentials`），
**会随备份文件一起导出**。插件管理页有固定警示文案提示用户不要分享备份。
请勿在凭据里存与登录无关的大块数据。

### 3.5 音质键名规范

宿主认的规范键（大小写不敏感，统一转小写）：

```
64k  128k  192k  320k  flac  flac24bit
hires  atmos  master  24bit  sq  dsd
```

另外这几个别名会被归一化（只在语义完全等价时才用，其他标签保持原样）：

| 别名 | 归一化为 |
| --- | --- |
| `low` | `64k` |
| `standard` | `128k` |
| `high` / `hq` | `320k` |
| `super` / `lossless` | `flac` |

> 不要自造新档位（例如 `mp3`、`aac`、`vbr`）。宿主会把它当成未知标签原样显示，用户看不懂，
> 也没法参与登录置灰和下载校验。

## 4. 登录态：三个上报通道

插件可以任选其一或组合使用，优先级从高到低：

1. **主动查询 action（最可靠）**
   ```js
   module.exports.requestLoginStatus = async (sourceId) => {
     if (!getMusicU()) return { state: 'loggedOut' };
     try {
       const res = await queryAccount();           // 你的账号接口
       return { state: 'loggedIn', account: res.nickname };
     } catch (e) {
       return { state: 'expired', message: 'MUSIC_U 已失效，请重新获取' };
     }
   };
   ```
   - 只在 `actions` 里声明了 `loginStatus` 时宿主才会调用。
   - 返回值可以是对象，也可以是 JSON 字符串；宿主认的键：
     `state | status | login`，账号名 `account | nickname`。
   - 超时 5 秒；抛错 / 返回 `unknown` 时宿主保持 `unknown`，不会误置灰。

2. **运行时推送**
   ```js
   lx.send('loginStatus', { source: 'wy', state: 'loggedIn', account: 'xxx' });
   lx.send('login',       { sourceId: 'wy', state: 'expired' });   // 两种事件名都认
   ```

3. **静态声明**：`sources[id].login.state`，只在宿主加载插件时读一次，之后被上面两种覆盖。

状态取值语义：

| 值 | 含义 | 宿主行为 |
| --- | --- | --- |
| `loggedIn` | 已登录 | 高音质解锁 |
| `loggedOut` | 确认未登录 | 受限档位置灰 |
| `expired` | 有凭据但已失效 | 受限档位置灰，提示重新获取 |
| `unknown` | 不知道（缺省） | **不置灰**，正常请求 |

## 5. 插件侧读取凭据

宿主在插件脚本执行**之前**就写好全局变量，两种读法都可：

```js
function readUserVariables() {
  const vars = (typeof lx.getUserVariables === 'function' && lx.getUserVariables()) || {};
  const fallback =
    (lx.currentScriptInfo && lx.currentScriptInfo.userVariables) || {};
  return Object.keys(vars).length ? vars : fallback;
}

const cookie = readUserVariables().MUSIC_U || '';
```

注意：
- 用户保存凭据后宿主会热更新（不重启插件进程），下一次请求就能拿到新值。
- 值可能是空字符串，`key` 也可能不存在，务必给缺省值。

## 6. 宿主对播放请求的调度（插件需要知道的行为）

### 6.1 数据源自动换源

- 只有**数据源**（`type` 为 `music` 且被标记为数据源的插件）才会自动换源。
  普通播放插件（MusicFree 格式同理）**禁止**跨插件换源。
- 同平台播放源列表由宿主自动发现：遍历已启用插件里所有非数据源、平台 id 匹配的音源，
  按**插件安装时间升序**排；用户可在插件管理页手动拖动调整，越靠上优先级越高。
- 播放时按该顺序**串行**尝试，每个源 **10 秒**超时，全部失败才停止播放并提示。
- 某个源失败后会被本次播放记住（同一首歌不会反复撞同一个坏源）；切歌 / 改顺序 / 全部失败
  后自动清空。

### 6.2 音质校验

宿主会拿插件返回的音质和请求的音质对比。插件返回的档位低于请求档位时，
宿主记一条失败并尝试下一个源。因此：

- **不要为了「有返回」而谎报音质**。要 320k 给 128k 就老实说 128k（或者抛错说明降级原因）。
- 相反，如果站点只支持「降级返回」，正确做法是**在插件里先判断再抛错**，让宿主去换源，
  而不是返回一个标着 320k 实际 128k 的地址。

## 7. 异常处理约定（这一节最容易踩坑）

| 场景 | 正确做法 |
| --- | --- |
| **VIP 歌曲返回试听片段** | **不要抛错**。照常返回 URL 继续播放，最多打一条日志说明「返回的是试听片段」 |
| 真的拿不到地址（无版权 / 接口报错） | `throw new Error('人话说明')`，message 会直接给用户看 |
| 参数不合法（不支持的 source / action / 音质） | `throw new Error('不支持的音源：xx')` |
| 网络超时 | 让 Promise reject 或 `throw`，宿主按失败处理并换源 |
| 返回空字符串 / `undefined` | **禁止**。宿主会当成失败，但错误信息会很难懂 |
| 需要 referer 等请求头 | 返回 `{ url, headers: { Referer: '...' } }`，宿主会带上 |
| 试听 / 降级要提示用户 | 用 `console.log('[wy] ...')`，别用 `throw` 打断播放 |

错误文案要求：一句话说清「哪个环节 + 为什么 + 用户能做什么」。反例：`Error: 10001`。
正例：`网易云未返回播放地址：该歌曲为 VIP 专属且登录已失效，请重新填写 MUSIC_U`。

## 8. 自测清单

新增 / 修改插件后，至少确认这几条：

- [ ] `lx.send('inited', { sources })` 里的 `qualitys` 与实际能返回的档位一致
- [ ] 下载能力弱于播放时，单独写了 `downloadQualitys`
- [ ] `login.freeQualitys` 是未登录时**真的**能播的档位
- [ ] `credentials` 的 `hint` 说清了去哪儿拿；`secret: true` 没漏
- [ ] `actions` 里声明了 `loginStatus` 且 `module.exports.requestLoginStatus` 真的存在
- [ ] 试听片段：返回 URL 不抛错
- [ ] 无版权 / 需要 VIP：抛带人话的 Error，不返回空 URL
- [ ] 请求不支持的 `source` / `action` 时明确拒绝，而不是静默返回空

参考实现：`D:\Download\音源\LX_网易云官方_播放下载.js`（v1.1.0，声明了
`downloadQualitys` + `login` + `credentials` + `loginStatus`，并正确处理试听片段）。
