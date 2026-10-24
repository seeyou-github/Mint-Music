# 两个网易插件为什么一个能放 VIP、一个只有 30 秒

> 对比对象
> - `D:\Download\MusicFree-网易[星海]-v1.6.js`（platform: `星海-网易`，作者 万去了了）
> - `D:\Download\MusicFree-网易-vip仅30秒.js`（platform: `MF-网易-无vip`，描述就写着「vip只能听30秒」）
>
> 结论：**星海用的是「你自己的账号」（或第三方代理的账号），而 vip仅30秒 用的是「插件里写死的一个非 VIP 账号」；更关键的是，它解析你填的 cookie 时有个下标 bug，导致你就算填了 VIP cookie 也传不出去。**

---

## 一、实测证据（直接打网易 EAPI）

请求 `/eapi/song/enhance/player/url/v1`，`level=exhigh`，目标歌曲 `2722343303`（`fee=1`，VIP 歌）：

| 请求 | songCode | size | freeTrialInfo | 有 URL |
| --- | --- | --- | --- | --- |
| 匿名（不带 cookie） | `-110` | 0 | — | ❌ |
| 匿名 + `trialMode=23` | `-110` | 0 | — | ❌ |
| **插件内置 cookie** | `200` | **481,115** | **`{start:0, end:30}`** | ✅ 30 秒片段 |
| **插件内置 cookie + `trialMode=23`** | `200` | **481,115** | **`{start:0, end:30}`** | ✅ 30 秒片段 |

同一账号请求免费歌（`fee=0`）：`size=9,187,245`（约 9 MB），**没有** `freeTrialInfo` → 完整曲目。

也就是说：

1. 内置的 `MUSIC_U`（610 字符那串）是一个**能登录、但不是 VIP** 的账号 → VIP 歌只给 `end:30` 的试听片段，正好 30 秒。
2. `trialMode: "23"` **不是**决定性因素（有无它对非 VIP 账号结果完全一样）；它只是把「我要试听版」写进了请求，属于雪上加霜，不是根因。

---

## 二、两个插件的取流路径

### 星海 v1.6（能放 VIP）

```js
// 不内置 Cookie，由用户在 userVariables 里填 music_u
const MUSIC_U = readUserMusicU();

getMediaSource: async (musicItem, quality) => {
  if (hasCookie()) {
    // ① 有 cookie：官方 eapi，用「你自己的」账号
    const params = { ids: ..., level: QUALITY_MAP_EAPI[quality] || 'exhigh', encodeType: 'flac' };
    const data = await eapiRequest('/api/song/enhance/player/url/v1', params);   // 没有 trialMode
    return { url: data.data[0].url.split('?')[0], headers: {...} };
  }
  // ② 没有 cookie：走第三方代理
  const gd = await requestCustomApi('get_song_player_url', { id, br });          // zrcdy.dpdns.org
  const realUrl = await fetchRealPlayUrl(gd.url);                                // music-api.gdstudio.xyz
  return { url: realUrl, headers: { 'User-Agent': 'Mozilla/5.0' } };
}
```

- **cookie 来自用户**，所以你的会员权益直接生效；
- 请求参数里**没有** `trialMode`；
- 不填 cookie 时走代理（代理用自己的账号解析），实测这条链路目前不稳（返回「GD API 未返回播放链接」），所以真正让它能放 VIP 的，是**你填的 cookie**。

### vip仅30秒（只能试听）

```js
// EAPI 里拼 cookie
let music_a = String(music_u || "").match(/(MUSIC_[UA]=|^)([^;]+)/i)
music_u = "os=pc; appver=9.0.25; " +
  (music_a ? "MUSIC_U=" + music_a[1]                       // ← 取的是前缀，不是 token
           : "MUSIC_U=0034B44F...（写死的 610 字符 token）");

// 取流
let _ = await EAPI("/api/song/enhance/player/url/v1", {
  ids: ..., level: qualityMap[quality],
  trialMode: "23",        // ← 显式声明试听
});
if (_ && _[0] && _[0].url) return { url: ... };             // 有 url 就直接返回（试听片段）
if (_ && _[0] && _[0].code == 404) return await KUWO(...);  // 灰色歌 → 去酷我搜同名
return await getMediaProxys(...);                           // 5 个公益 API（需要卡密）
```

三个问题叠加：

1. **内置账号非 VIP** → 官方只给 30 秒；
2. **`trialMode: "23"`** → 明确要试听版；
3. **cookie 解析 bug** → 你填的 VIP cookie 传不出去（见下）。

---

## 三、cookie 解析 bug（为什么你填了也没用）

原代码 `music_a[1]` 取的是**正则的第一组**（`MUSIC_U=` 这个前缀），而 token 在 `music_a[2]`。实测三种填法：

| 你在 userVariables 填的 | 实际发出去的 Cookie | 结果 |
| --- | --- | --- |
| （不填） | `MUSIC_U=0034B44F…`（内置非 VIP） | 30 秒 |
| `MUSIC_U=你的token` | `MUSIC_U=MUSIC_U=` | 等于没登录 |
| `你的token` | `MUSIC_U=`（空） | 等于没登录 |
| `os=pc; MUSIC_U=你的token; …`（整串粘贴） | `MUSIC_U=os=pc` | 等于没登录 |

所以这个插件**永远用不上你自己的账号**，只能吃内置那个非 VIP 账号的 30 秒试听。

---

## 四、修补版

`D:\Download\MusicFree-网易-vip仅30秒-fixed.js`，两处改动：

1. **cookie 解析**：优先抓 `MUSIC_U=<token>` / `MUSIC_A=<token>`，抓不到就把整段当裸 token，四种填法都能正确传下去；
2. **去掉 `trialMode: "23"`**。

验证（同一套 harness，把请求头里的 Cookie 打出来）：

```
原版     + 填 cookie      → Cookie: os=pc; appver=9.0.25; MUSIC_U=            ← 空
修补版   + 填 cookie      → Cookie: os=pc; appver=9.0.25; MUSIC_U=TESTTOKEN123
修补版   + 填 MUSIC_U=xxx → Cookie: os=pc; appver=9.0.25; MUSIC_U=TESTTOKEN123
修补版   + 整串粘贴       → Cookie: os=pc; appver=9.0.25; MUSIC_U=TESTTOKEN123
修补版   + 不填           → Cookie: os=pc; appver=9.0.25; MUSIC_U=<内置非 VIP>
```

**用法**：装上 `-fixed.js` 后，在插件设置里把用户变量 `music_u` 填成**你自己**的 `MUSIC_U`（登录 music.163.com → F12 → Application → Cookies → 复制 `MUSIC_U` 的值；整串粘贴也认）。

> 诚实的边界：我这边没有 VIP 账号，无法端到端验证「VIP cookie + 修补版 = 完整播放」。能确定的是——**修补前你的 cookie 根本发不出去**（这是必要条件），修补后它会原样发出去；至于能不能放完整版，取决于你这个账号本身有没有会员。

---

## 五、注意事项

- 你截图里音源列表显示的是「网易-显大小(分页修复)」，而这个文件的 `platform` 是 `MF-网易-无vip`——两者是同一作者的不同打包版本。**分析针对你给的这份文件**；如果装的不是同一份，先看插件管理里的 `platform` / `version` 对不对得上。
- 内置的那个 `MUSIC_U` 是别人的账号，随时可能失效（失效后会走到「酷我搜同名」兜底，反而能放完整版，但音质/版本可能不对）。
- 公益 API（ikunshare 需要卡密、haitangw、onrender）都不保证可用，实测 `onrender` 返回 503。
- 用第三方账号/代理解析 VIP 版权歌曲存在合规风险，长期方案还是填自己的会员 cookie。
