# 跨平台数据同步（歌单 + 附加数据 + 播放进度）

本文说明 Mint-Music 通过 WebDAV 做跨设备同步的完整设计：远端文件布局、快照协议、合并规则、触发与节流、失败处理，以及代码位置。

歌单同步是原有功能，本次只在它前后串入「附加数据」和「播放进度」两份新数据，歌单协议本身没有改动。

---

## 1. 同步范围

| 数据 | 远端文件名 | 合并方式 |
| --- | --- | --- |
| 歌单 / 收藏 / 自建歌单 | `playlist.meta.json` + `playlist.<sha256>.json.gz`（原有） | 原有逻辑（歌曲并集、删除墓碑、按条目更新时间） |
| 黑名单（歌曲 / 歌手 / 白名单） | `extras.meta.json` + `extras.<sha256>.json.gz` | 逐条 LWW（最后修改时间），删除记墓碑 |
| 电台分类 / 电台 / 随机电台 | 同上（同一份 extras 快照） | 逐条 LWW |
| 电台封面文件 | `radio-covers/<sha256>.img` | 内容寻址，按摘要去重 |
| 播放进度 | `progress.meta.json` + `progress.<sha256>.json.gz` | 同一首歌取最大进度；`clearedAt` 划界 |

不参与同步：本地扫描目录、缓存目录、下载文件、歌词缓存、播放队列、会话、登录态、桌面歌词窗口位置等本机专属数据。设置项本身仍由原有「自动同步 → 配置备份包（zip）」路径覆盖。

---

## 2. 远端布局

所有文件都写在 WebDAV 根地址下（与备份包同一目录）：

```text
<webdav url>/
  playlist.meta.json               歌单指针（原有）
  playlist.<sha256>.json.gz        歌单快照（原有）
  extras.meta.json                 附加数据指针
  extras.<sha256>.json.gz          附加数据快照
  progress.meta.json               播放进度指针
  progress.<sha256>.json.gz        播放进度快照
  radio-covers/<sha256>.img        电台封面（内容寻址）
  auto-mintmusic-backup.zip        自动配置备份（原有）
  <设备名>/...                     手动 / 定时配置备份（原有）
```

### 2.1 指针文件

`extras.meta.json` / `progress.meta.json` 是唯一可变文件，约 200~300 字节，**不压缩**：

```json
{
  "schema": 1,
  "epoch": "uuid",
  "revision": 12,
  "digest": "<未压缩 JSON 的 sha256>",
  "size": 12345,
  "updatedAt": 1730000000000,
  "writer": "<设备 id>"
}
```

- `epoch`：数据集标识。远端被重置 / 换账号时变新值，客户端据此丢弃旧基线。
- `revision`：每次成功回推 +1，仅用于观察 / 排障。
- `digest`：指向的 `.json.gz` 对应的**未压缩 JSON** 的 sha256。压缩字节依赖 zlib 实现，跨平台不稳定，所以摘要取解压后的内容。
- `etag`：只在内存里，来自 GET 响应头，用于 `If-Match`。

### 2.2 写入顺序与并发

固定顺序：**先传快照（不可变，重名幂等）→ 再用 `If-Match` 条件写指针**。

- 指针写入时带上一轮读到的 ETag；服务器返回 `412 Precondition Failed` 说明别的设备刚更新过，客户端重新「下拉 + 合并 + 回推」，最多 4 次（`ExtrasSyncService._maxSyncAttempts` / `ProgressSyncService._maxSyncAttempts`）。
- 服务器不给 ETag 时降级为普通 PUT，写完再读一次指针复核；仍不一致就按 412 处理。
- 指针永远指向一份完整快照，任何时刻中断都不会留下「指针指向半个文件」的状态。

### 2.3 快照清理

- 指针切换成功后，旧快照保留最近 2 份 + 10 分钟宽限，然后删除（`gcDataSnapshots`）。
- 电台封面按「当前快照仍然引用的摘要」保留，其余删除（`gcDataFiles('radio-covers', ...)`）。

---

## 3. 快照格式

### 3.1 附加数据 `extras`

```json
{
  "schema": 1,
  "blacklist": {
    "songs":     [{"title": "...", "artist": "...", "changedAt": 1730000000000}],
    "artists":   [{"name": "...", "changedAt": 1730000000000}],
    "whitelist": [{"title": "...", "artist": "...", "changedAt": 1730000000000}]
  },
  "radio": {
    "categories": [{"id": "...", "name": "...", "changedAt": 1730000000000}],
    "stations":   [{"id": "...", "name": "...", "coverUrl": "...", "coverDigest": "<sha256>",
                    "categoryId": "...", "sourceIds": [...], "tags": [...], "keywords": [...],
                    "createTime": "...", "updateTime": "...", "changedAt": 1730000000000}],
    "random":     {"id": "...", "...": "..."}
  },
  "tombstones": {
    "blacklist.songs": {"<normalize(title)|normalize(artist)>": 1730000000000}
  }
}
```

要点：

- 各列表按 key 排序后输出，保证同一份内容得到同一个摘要。
- key 规则：
  - 黑名单歌曲 / 白名单：`normalize(title)|normalize(artist)`（沿用 `BlacklistEntry.key`）；
  - 黑名单歌手：`normalize(name)`；
  - 电台分类 / 电台：`id`；
  - 随机电台：固定 `random`。
- `coverPath` 是本地文件路径，不同步；`coverDigest` 是封面文件的 sha256，
  指向 `radio-covers/<coverDigest>.img`。空串表示该电台没有封面；没有这个
  字段的是旧快照，合并时保留本机已有封面路径。
- `changedAt` 为 0 / 缺失时不会写进快照，避免同一内容在不同设备上因 `null` 字段产生摘要差异。

### 3.2 播放进度 `progress`

```json
{
  "schema": 1,
  "clearedAt": 1730000000000,
  "items": [
    {"songId": "...", "ratio": 0.46, "positionMs": 46000,
     "durationMs": 100000, "updatedAt": 1730000000000}
  ]
}
```

- `ratio`：0~1 的「最远听到哪」，只增不减。
- `clearedAt`：用户在「最近播放」页点「清除」的时间；`updatedAt <= clearedAt` 的进度视为已删除。0 表示从未清空。
- 排序规则同 extras：按 `songId` 排序。

---

## 4. 变更检测：中心化 diff 日志（extras）

黑名单 / 电台的模型里没有「更新时间」字段，为了不改动所有业务入口，同步层用一个独立的变更日志推断：

- 存储：`settings.json` 的 `extras_sync_journal_v1`；
- 内容：
  - `baseline`：scope → key → 上次同步时的内容 sha256；
  - `changedAt`：scope → key → 最后一次内容变化时间；
  - `tombstones`：scope → key → 删除时间。
- 每次同步先把「当前内容」与 `baseline` 对比：
  - 内容不同 → 写 `changedAt = now`，清掉同 key 的墓碑；
  - 上次有、这次没有 → 写墓碑 `now`；
  - 超过 90 天的墓碑自动清掉。
- 应用完远端后，以「当前内容」重建 `baseline`，**不重新打时间戳**，避免把远端数据误判成本地新改动。
- 电台的 `coverDigest` 不参与基线比较（换封面时 `updateTime` 会变，足够触发变更），避免升级后首轮同步把所有电台都打成「新改动」。
- 只在日志真的有变化时才写盘，避免同步自己写 settings → 又触发一轮同步的循环。

这套机制的好处：任何入口（包括以后新增的入口）改了数据都能被下一次同步发现；删除后应用马上被杀，下次对比基线仍能发现缺失项。代价：首次同步（没有基线）会把现有内容整体视为「本地新改动」，按本地优先处理。

---

## 5. 合并规则

### 5.1 extras：逐条 LWW + 墓碑

对每个 scope 取「本地 key 并集远端 key」，逐条比较时间：

```text
stamp(item) = max(item.changedAt, tombstone[key])
```

- 两边时间相同：本地优先（远端只补充本地没有的条目）。首次同步两边都是 0 时也走这条，结果稳定。
- 本地时间更大：采用本地（有则保留，无则删除）。
- 远端时间更大：采用远端（有则写入，无则删除本地）。
- 删除时间超过 90 天：墓碑不再传播，条目可以重新被创建。

### 5.2 播放进度：取最大进度

- key 为 `songId`，逐首取 `ratio` 较大者；`ratio` 相同取 `updatedAt` 较新者。
- `clearedAt = max(本地, 远端)`。
- 丢弃 `updatedAt <= clearedAt` 的条目；应用到本地数据库时，也删除本机 `updated_at <= clearedAt` 的行。
- 不做逐条 LWW：用户关心的是「这首歌听过多少」，不应因为某台设备刚从头播了几秒就把进度降回去。

### 5.3 电台的本地字段

- 电台封面：
  - 快照只带 `coverDigest`（封面文件内容 sha256），文件本身放在 `radio-covers/<digest>.img`，按内容寻址、重复上传幂等。
  - 回推前先补传被快照引用的封面文件，再写快照、最后写指针；下载失败 / 摘要不符时撤销「已上传」标记，下次同步会重试。
  - 应用远端时：本地已有同摘要文件直接复用；没有就从远端下载，校验 sha256 后落到 `config/setting/radio_covers/<digest>.img`，并把 `coverPath` 指向它；下载失败退回远端 `coverUrl`（网络地址）缓存。
  - `coverPath` 本身仍不同步；换封面 / 删电台后，本机不再被引用的旧缓存文件会被删掉。
  - `coverDigest` **不参与变更时间戳**（换封面时 `updateTime` 一定会变），避免升级后首次同步把所有电台误判成本地新改动。合并时若胜出的一侧没有封面摘要、但 `coverUrl` 非空，会沿用另一侧的摘要；只有 `coverUrl` 被清空才视为用户主动删除封面。
  - 远端封面文件缺失不影响其它数据：本轮跳过、保留本地现状，并在下次发布时重新补传。

---

## 6. 触发与节流

| 触发 | 行为 | 超时 / 失败 |
| --- | --- | --- |
| 手动「同步」按钮（歌单页 / 设置页「立即同步」） | 歌单 → extras → 进度 依次拉取合并；启用自动同步时还会备份配置 | 共用一个 2 分钟 `SyncAttempt`；失败弹框，「重新同步」立即重试 |
| 启动自动同步（开关开启） | 延迟 1 分钟后走与手动相同的三段同步（`PlaylistSyncService.scheduleDelayed`） | 2 分钟；失败弹框可重试 |
| 歌单自动同步（收藏等增删改） | 歌单同步成功后，再单独跑一次 extras + 进度（独立 2 分钟，失败只记日志） | 不打断歌单同步状态 |
| 任意设置写盘（`AppPreferences.onWrite`） | 延迟 1 → 3 → 5 分钟同步 extras（`DelayedSync`，标志文件 `sync_extras.pending`，退出后启动补跑） | 失败只记日志 |
| 播放进度记录（切歌 / 暂停 / 停止 / 退出 / 自然播完） | 距上次进度推送满 10 分钟才推；不满则定时到点再推 | 失败同样等 10 分钟，不升级退避 |
| 清空播放进度 | 记录 `clearedAt` 后立即推送，不受 10 分钟限制 | 失败只记日志 |
| 退出应用 | **不发起网络同步**：落盘后只在 `AppData/temp` 写 `sync_exit.pending` 标记（≤1 秒），关窗立即返回 | 标记写失败只记日志 |
| 下次启动（存在退出标记） | 检测到 `sync_exit.pending` 后跳过延迟，立即补一次完整同步（歌单 + extras + 进度），成功后删除标记 | 失败保留标记，下次启动再试 |

### 6.1 进度节流细节

播放进度只在现有节点记录（不是在位置流里每秒记录）：

- `PlaybackController._reportProgressNow`：切上一首 / 下一首 / 暂停 / 停止 / 退出；
- `_recordCompletedListen`：自然播完（记 100%）；
- 设置「外观设置 → 歌曲列表 → 标记歌曲播放状态」关闭时完全不记录，也就不会同步。

`DataSyncCoordinator` 内存里维护 `_lastProgressPush`：

```text
记录进度 → 若距上次推送 < 10 分钟，安排一个到点触发的 Timer
          若已满 10 分钟（或从没推过），立即推送
推送开始   → _lastProgressPush = now（成功 / 失败都算）
失败       → 下一次记录（或 10 分钟后的重试）再试，固定间隔，不做 1→3→5 升级
```

清空进度走 `_progressForce`：取消等待中的 Timer，立即执行一次。

### 6.2 退出时不打网络

桌面端关窗要等 Dart 端 `didRequestAppExit()` 返回才真正销毁窗口；如果在里面等
WebDAV 往返，窗口会明显卡在「未关闭」状态。所以退出流程只做本地落盘：

1. `settleListenSession()` 把当前收听时长结算进延迟写队列；
2. `AppDatabase.flushAll()` / `checkpointAll()` 与 `AppPreferences.flushNow()` 落盘；
3. `DataSyncCoordinator.markExitSyncPending()` 只在 `AppData/temp` 写
   `sync_exit.pending`（自动同步开启且 WebDAV 已配置时），不发起请求。

下次启动时 `App` 检测到该标记会取消除正常启动同步的 1 分钟延迟，立即走一次
完整同步（歌单 → extras → 进度）；成功后才删除标记，失败保留到下次启动。
Android 端没有桌面端的退出握手，本来就不会在退出时同步，行为一致。

### 6.3 防回环

同步过程会写 `settings.json`（同步状态、变更日志、`clearedAt`），而 `onWrite` 又会触发自动同步。协调器用 `_busy` 标志：

- 同步进行中的设置写盘不会再排一次 extras 同步；
- 同步结束后若期间有新进度记录，再按 10 分钟规则补排。
- 进度节流时间只存在内存里，不为了记「上次推送时间」而反复写设置。

---

## 7. 播放进度与本地数据库

### 7.1 本地存储

`AppData/db/mintmusic.db` 的 `song_play_progress` 表：

```sql
song_id TEXT PRIMARY KEY,
ratio REAL, position_ms INTEGER, duration_ms INTEGER, updated_at INTEGER
```

- 写入按 6 秒合并（`DeferredWriter`），切后台 / 退出 / 同步前强制 `flush()`。
- 一年未更新且未收藏的进度会被清理（`pruneOldProgress`），收藏过的歌永久保留。

### 7.2 远端合并落库

`PlayProgressStore.mergeRemote(items, clearedAt:)`：

1. 读本机 `song_id / ratio / updated_at`；
2. 远端条目中 `updatedAt <= clearedAt` 的跳过；
3. 本机没有、或远端 `ratio` 更大的才写入；`ratio` 相同则取 `updatedAt` 较新的一份（与快照合并口径一致，避免本地库和快照长期对不上）；
4. 事务内先删除 `updated_at <= clearedAt` 的本地行，再批量 upsert；
5. 有变化时返回 `true`，协调器随后 `flush()` 并调用 `PlayedProgressNotifier.reload()` 刷新界面。

### 7.3 清空进度

「最近播放」页的清除操作：

1. 清空内存状态与数据库；
2. `ProgressSyncService.markCleared()` 把当前时间写进 `settings.json` 的 `play_progress_cleared_at_v1`；
3. `DataSyncCoordinator.progressCleared()` 立即推送；
4. 其它设备下次拉取时，`clearedAt` 之前的进度会被删除。

---

## 8. 失败与恢复

| 场景 | 行为 |
| --- | --- |
| 指针 412（其它设备抢先） | 重新拉取 + 合并 + 回推，最多 4 次 |
| 快照摘要不匹配 | 视为下载失败，重试一次（`readDataSnapshot` 内置），仍失败则报错 |
| 指针损坏（缺字段 / 非法 JSON） | extras / progress 直接报错，提示删除对应的 `*.meta.json` 后重试；不会猜内容覆盖云端 |
| 指针 schema 不兼容 | 抛 `DataSnapshotSchemaException`，提示升级客户端 |
| 同步中用户点「停止」 / 超时 | `SyncAttempt` 取消底层 HTTP 请求；已下载但未写入的数据丢弃 |
| 自动同步失败 | 底部提示（歌单 / 设置流程）或仅日志（后台 extras / 进度）；进度等 10 分钟再试 |
| 退出时（下次启动补同步）失败 | 静默，保留 `sync_exit.pending` 标记，下次启动继续补；本地数据已落盘 |
| 设置文件读失败 / 被清空，数据读成空但基线仍匹配 | 「本地整体为空」在记变更日志**之前**判断，强制走合并；合并仍会带上本机墓碑，所以用户确实删光了照样能删远端，不会把云端覆盖成空 |
| 本地内容与远端快照一致、但本地基线丢失（还原备份 / 清过设置） | 不下载快照，直接补记 `DataSyncState`，下一轮就能走「无改动」早退 |

### 8.1 恢复建议

- `extras.meta.json` / `progress.meta.json` 损坏：删除对应指针（以及可能的 `.json.gz` 快照），下次同步会按「远端初始化」重建；本地数据会作为新内容上传。
- 换 WebDAV 账号：旧 `epoch` 不匹配，客户端会重新建立指针；建议先备份。
- 关闭「自动同步」：作废等待中的歌单 / extras 延迟同步与配置备份标志，避免以后打开时按旧标志补跑。

---

## 9. 代码地图

| 文件 | 职责 |
| --- | --- |
| `lib/core/backup/data_snapshot.dart` | 通用快照协议：`DataSnapshotMeta`、`DataSnapshotCodec`、`DataSyncState(Store)`、`syncDeviceId()` |
| `lib/core/backup/webdav_service.dart` | WebDAV 读写基础；新增 `readDataMeta` / `readDataSnapshot` / `writeDataSnapshot` / `writeDataMeta` / `readOptionalDataFile` / `writeDataFile` / `ensureDataDir` / `gcDataSnapshots` / `gcDataFiles` |
| `lib/core/backup/extras_sync_service.dart` | 附加数据快照构建、变更日志、合并、落库、电台封面上传 / 下载 / 清理 |
| `lib/core/backup/progress_sync_service.dart` | 播放进度快照、10 分钟语义之外的全部合并逻辑、`clearedAt` |
| `lib/core/backup/data_sync_coordinator.dart` | 编排：手动 / 启动 / 自动歌单同步后串入 extras + 进度；设置写盘延迟调度；进度 10 分钟节流；退出只写 `sync_exit.pending` 标记；provider 刷新 |
| `lib/features/player/data/play_progress_store.dart` | 本地进度表；新增 `mergeRemote` |
| `lib/features/player/application/play_progress_providers.dart` | 记录进度后通知协调器；清空后写 `clearedAt` 并立即推送 |
| `lib/features/library/application/playlist_providers.dart` | 手动同步（`syncPlaylistsNow`）与自动歌单同步成功后串入附加数据同步 |
| `lib/shared/widgets/playlist_sync_button.dart` | 「立即同步」按钮：歌单 → 附加数据 → 可选配置备份 |
| `lib/app/app.dart` | 启动延迟同步：歌单 → 附加数据 + 进度；发现退出标记时跳过延迟立即补同步 |
| `lib/main.dart` | `onWrite` 同时挂配置备份与附加数据调度；关窗只写 `sync_exit.pending` 标记，不打网络 |
| `lib/features/settings/presentation/backup_restore_content.dart` | 「自动同步」说明文案与开关 |

---

## 10. 已知限制

- **首次同步**：没有变更日志时，本地内容整体视为「本地新改动」，与远端冲突时本地优先。
- **播放进度只增不减**：不支持「某台设备进度故意回退」；清空是唯一的回退手段，且是全局清空。
- **进度键是 `songId`**：插件歌曲 id、本地歌曲 id 的跨设备一致性取决于音源 / 扫描结果；同一首歌在不同设备解析出不同 id 时不会合并。
- **配置备份与快照是两套数据**：`auto-mintmusic-backup.zip` 仍按原逻辑包含完整配置；extras / progress 快照与它互不依赖，还原备份不会重置同步基线（还原后 extras 会被视为本地新改动，可能覆盖远端）。
- **退出不打网络**：关窗只写 `sync_exit.pending` 标记（不等同步结果）；下次启动看到标记才补一次完整同步，失败则保留标记继续等下次启动。