# 音乐源维护记录

记录 vbox 网络音乐“音乐源”的故障排查、移除与修复情况，便于后续回溯。

> 记录人：开发排查 ｜ 最近更新：2026-09-23

---

## 移除记录

### 2026-09-23 · 移除「轮回|舞曲」（音乐）

- **源名称**：轮回|舞曲 ［music］
- **配置 key**：`nodejs_musicalunhui`（蜘蛛 `op0` / api `csp_MusicAiLunHuiGuard`）
- **宿主站点**：`https://www.dj92.cc`
- **现象**：首页七个分类标签（电音House/中文舞曲/外文舞曲/酒吧风格/串烧舞曲/私改舞曲/大赛作品）始终显示，但点击后无任何歌曲数据。
- **根因**：数据源站下线。实测 `www.dj92.cc` 域名已无法解析（DNS `NXDOMAIN`）；裸域 `dj92.cc` HTTPS 证书过期、`/djlist/` 返回 404，HTTP 走代理 502，站点已不再下发列表内容。分类标签为蜘蛛内写死，故仍显示。
- **处理**：从 `vbox/Resources/noderuntime/wexfnwconfig.json` 的站点清单移除该源（站点数 96 → 95），避免展示一个无法出数据的源。
- **备注**：待确认 `dj92.cc` 迁移后的新域名后，可将蜘蛛常量 `nY` 改指向新站恢复；否则保持移除。

---

## 修复记录（历史，供参考）

- 2026-09-23 · 修复「酷听|音乐」分类数据为空：库 `kstore_index.js` 内 `ZKt` 捕获 POST 会话 Cookie、`s5` 增加自动通过“安全验证”勾选（45hk WAF）。
- 2026-09-23 · 修复「梨园|戏曲」点播失败：`ll()` 支持附加请求头，`play()` 请求与播放器 header 补站点 `Referer/Origin`。

---

## 音乐源批量修复（2026-09-23，已存本地，未推送）

涉及文件：蜘蛛库 `vbox/Resources/noderuntime/bundles/kstore_index.js`；App 端 `vbox/Models/SpiderModels.swift`、`vbox/Services/SpiderManager.swift`。

### App 端（Swift）通用修复

1. **`PlayerContentResult` 支持 `url` 数组**：酷狗/酷我/网易/QQ 蜘蛛 `play` 均返回“音质标签+链接”交替的多线路数组。原模型仅声明 `url: String?`，遇到数组整体解码失败导致“播放失败，正在切换下一首”。现兼容字符串与数组两种形态，并保留完整列表。
2. **`fetchMusicPlayUrl` 解析播放占位符**：新增 `resolvePlayPlaceholder`——`vod_play_url` 若为 `名字$真实链接` 直接取直链；若为 `名字$编码ID` 则解码后走 `play` 接口；新增 `firstPlayableURL` 从 `urls/url/playUrl` 中挑第一个 `http(s)://` 可用地址。
3. **`expandDetailItem` 展开多曲条目**：蜘蛛 `detail` 返回的 `vod_play_url` 常用 `#` 分隔多条 `歌名$编码ID`（歌手热歌 / 歌单 / 榜单 / KTV合集）。原逻辑整体当一首歌处理，点击后直接播放合集或失败。现拆分为独立 `VodItem`，逐首播放。

### 蜘蛛端逐源修复

| 源 | 现象 | 根因 | 处理 |
|---|---|---|---|
| 蜻蜓电台 `musicaiqingting` | 播放无反应 | `detail` 返回 `title$id` 占位符，App 端需二次解析才能拿到直链 | 方案A：`detail` 直接返回真实直播流地址 `https://lhttp-hw.qtfm.cn/live/<id>/64k.mp3` |
| 糖豆舞蹈 `musicaitangdou` | 点击播放无反应、无进度 | `detail` 返回 `cdn_source$url` 占位符 | Swift `resolvePlayPlaceholder` 直接提取 `$` 后真实直链（ucloud/qiniu 双线路） |
| 小狗KTV `musicaikg` | 点合集直接播放合集本身 | 合集/榜单 `detail` 返回嵌套集合 | Swift `expandDetailItem` 将合集内 `歌名$song对象` 逐首展开；`play` 返回酷我多线路数组 |
| 小酷音乐 `musicaikuwoa` | 点歌手直接播放歌手 | 歌手 `detail` 返回整段热歌 `#` 列表 | Swift `expandDetailItem` 展开为歌手全部歌曲（如周杰伦 13+ 首）再逐首播放 |
| 小易音乐 `musicaiwy` | 播放失败“正在切换下一首” | `play` 返回网易多线路数组，模型解码失败 | Swift `PlayerContentResult` 支持 `url` 数组 + `firstPlayableURL` 取首条直链 |
| 小秋音乐 `musicaiqq` | 播放失败“正在切换下一首” | 同上（QQ 多线路数组解码失败） | 同上；榜单链路实测返回真实 m4a/mp3 直链。注：个别 QQ 隐私歌单接口返回 `check privacy error!`，属源站限制，歌曲列表为空属正常 |
| 易听音乐 `musicai163` | 有分类但无对应音乐数据 | ① 45hk WAF 人机验证仅尝试一次，会话未建立导致列表为空；② `play` 签名 key 用服务器本地时间（UTC）生成，与站点要求的北京时间（UTC+8）不符，返回 `{"msg":-1}` | ① `s5` 验证改为最多 8 轮重试并持续更新 Cookie；② `der()` 改用 `getUTC*` 显式 +8h 生成北京时间 key（URL 时间戳实测 `20260923192154`，直链 `m8.music.126.net/...` 可播） |

### 验证结论

对每个源模拟 App 端调用链 `category → detail → play`：

- 糖豆舞蹈：`detail` 返回双直链（ucloud/qiniu 带签名）→ Swift 取直链直接可播。
- 小狗KTV：榜单首曲 `play` 返回 `无损FLAC/320K/128K` 三条酷我直链。
- 小酷音乐：歌手详情展开 13+ 首热歌；单曲 `play` 返回酷我多线路直链。
- 小易音乐：歌单展开全曲目；单曲 `play` 返回网易 FLAC/320K/128K 直链。
- 小秋音乐：飙升榜展开全曲目；单曲 `play` 返回 QQ `isure6.stream.qqmusic.qq.com` 直链。
- 易听音乐：`category(playlists)` 出歌单 → `detail` 出全曲目 → `play` 返回 `m8.music.126.net` 带北京时间签名的直链。
- 蜻蜓电台：`detail` 直接返回 `lhttp-hw.qtfm.cn/live/.../64k.mp3` 直播流地址。

以上修复均已保存本地文件，未做任何推送。
