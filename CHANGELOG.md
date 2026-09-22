# VBox 更新日志

> 自动生成于每次 CI 构建，记录所有功能变更和修复。

---

## 2026-09-22（v3.1552）

### 新增
- **lx-music 音乐桥接引擎**：以 Node 独立进程 + 独立端口（lx 58083 / 健康 58084）托管刀源、念心两个 lx 协议插件，通过 `LXBridgeEngine` 接入网络音乐。视频/网盘/kstore 音乐源全程零接触，lx 进程启停不影响 kstore 主链路。
- **多源并发竞速回退**（P2-B1）：解析 lx 直链时对插件声明的多平台并发请求（单平台 6s 超时、整体 8s 上限、并发上限 4），首个成功即返回，弱网自动降级。
- **时长展示**（P2-B2）：lx 搜索结果歌曲行显示 `mm:ss` 时长（由插件 `interval` 格式化串解析），无该元数据不显示，不影响既有歌手/来源展示。
- **元数据映射**（P2-B3）：lx 搜索结果的 `picture→封面`、`singer→歌手`、`albumName→专辑`、`qualitys→可发音质` 全量对齐到歌曲条目。
- **多音质切换**（P3-C1）：正在播放页提供音质档位切换，重新走 lx `musicUrl` 拉取对应直链，`replaceCurrentItem` 无缝衔接并保留播放进度（±3s 内）。
- **滚动歌词**（P3-C2）：完整型插件（刀源）歌曲显示按时间轴高亮的同步歌词；念心等无歌词插件优雅降级整区隐藏。
- **备份还原适配**（P1-A6）：`RemoteSourcesSnapshot` 新增 `lxPlugins` 字段，备份/还原覆盖 lx 插件，还原不丢源、开关两态均不丢源。

### 兼容性
- `MusicQueueItem` 与 `VodItem` 均改为显式 `decodeIfPresent` 解码，新增字段缺失时回退默认值，旧队列/旧源存档安全解码，不破坏历史会话。
- **主动降级**：lx 未就绪时音乐入口提示「lx 源暂不可用」，视频搜索/视频源/普通音乐源完全不受影响。
- 远程源 `spider_sources.json` 已上架刀源/念心条目（type 3、group music），老版本 App 遇到 `lxMusic` 条目安全跳过而非崩溃。

---

## 2026-07-10

### 修复
- **神秘电影**: 修复 `MysteryMovieMainView` 缺少 `import AVKit` 导致编译失败
- **神秘电影**: 修复播放 404 — m3u8 URL 从硬编码改为从详情页 HTML 动态抓取，支持 4 种提取策略
- **神秘电影**: 修复分类只显示一页 — 分页 URL 改为尝试 3 种格式（`-` / `/` / `?page=`），`hasMore` 阈值从 20 降到 10
- **神秘电影**: 修复 `svc.baseURL` → `svc.host` 编译错误
- **四虎视频 + 香肠派对**: 修复播放失败 — `DoubanImageProxyServer.isAllowedStreamURL` 白名单拒绝四虎/香肠的 CDN 域名，新增 `sihu`/`xcp`/`mystery` provider 跳过白名单
- **神秘电影**: 修复闪退 — `MysteryMoviePlayerView` 重写为 AVPlayer 直接播放，移除 `VodItem` → `VideoDetailView` → `SpiderManager` 崩溃链路
- **XCPService**: `title`/`remarks` 从 `let` 改为 `var`（允许多次赋值）
- **XCPService**: `stringByReplacingMatches` 参数类型修复（`NSString` → `String`）
- **XCPService**: `NSString` 隐式转换修复
- **SihuVideoService**: `currentBaseURL` 从 `private` → `internal`，修复视图层访问
- **XCPService**: `currentHost` 从 `private` → `internal`，修复视图层访问
- **SihuVideo**: 添加 `Equatable` 协议
- **SihuVideoView**: `playEpisode()` 变量名遮蔽修复

### 新增
- **香肠派对**: 完整对接（`XCPService.swift` + `XCPView.swift`），4 分类 + 分页 + AVPlayer 播放
- **四虎视频**: 完整对接（`SihuVideoService.swift` + `SihuVideoView.swift`），54 分类 + 分页 + AVPlayer 播放
- **DoubanImageProxyServer**: 新增 `sihu-stream` / `xcp-stream` / `mystery-stream` 路由

---

## 2026-07-09

### 修复
- **SB聚合**: flv.js 双 CDN 容灾（bootcdn → unpkg）
- **每日大赛**: probeHost JS 跳转页跟进失败后 fallthrough 修复
- **每日大赛**: probeHost 导航页检测（`isNavigationPage()`）+ Case 3 fallthrough 修复
- **每日大赛**: nzmknoycm.cc 302 重定向域名稳定性修复

### 新增
- **福利专区**: 域名设置功能（`WelfareSettingsView` + `WelfareDomainStore`），支持自定义替换失效域名
- **色播聚合**: 新增平台（`SBAggregationService` + `SBAggregationView`），直播聚合分类显示和播放
- **神秘电影**: 平台集成（`MysteryMovieService` + `MysteryMovieMainView`）

---

## 2026-07-08

### 修复
- 每日大乱斗/大赛/神秘电影封面图不显示（`@UA@Referer` 头注入）
- 去除平台顶部分类导航和小分类按钮的背景框
- 每日大赛分类数据不显示（四个问题修复）
- 香蕉秀/DailyBattle UI 去背景 + 短视频滑动修复
- 福利首页 Tab 导航上移 + 浅色模式修复
- 域名设置保存按钮 + 每日大赛导航页线路自动发现

### 新增
- 每日大乱斗平台集成（`DailyBattleService` + `DailyBattleMainView`）
- 每日大赛平台对接（复用 DailyBattleService 多站点架构）
- 观看历史和收藏弹窗支持左滑删除

---

## 2026-07-07

### 重构
- 福利页 UI 重设计 + 24 个 Python 爬虫平台对接
- 福利页移除非核心平台代码，保留 MissAV / 香蕉秀
- 长按排序功能恢复
- 直播播放走代理

### 新增
- 福利设置页增加直播代理地址配置
- 22 平台路由 + 皮肤适配

---

> 📝 此日志由 CI 自动维护，每次构建时从 git commit 历史生成。
> 最后更新: 2026-07-10
