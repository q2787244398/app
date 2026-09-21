import Foundation
import GRDB

class DatabaseManager {
    static let shared = DatabaseManager()

    private var dbPool: DatabasePool!

    private init() {
        setupDatabase()
    }

    private func setupDatabase() {
        let fileManager = FileManager.default
        let appSupport = try! fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = appSupport.appendingPathComponent("vbox.sqlite3")

        do {
            dbPool = try DatabasePool(path: dbURL.path)

            try migrator.migrate(dbPool)
            print("[DatabaseManager] 数据库初始化成功: \(dbURL.path)")
            
            // 首次启动时迁移 UserDefaults 中的旧订阅 URL
            migrateUserDefaultsIfNeeded()
        } catch {
            print("[DatabaseManager] 数据库初始化失败: \(error)")
        }
    }

    // MARK: - Migrator

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            // zhanyuan 表
            try db.create(table: "zhanyuan") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("searchUrl", .text).notNull()
                t.column("searchUA", .text).notNull()
                    .defaults(to: "Mozilla/5.0 (Linux; Android 12; Redmi K30 Pro Build/SKQ1.220303.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/99.0.4844.88 Mobile Safari/537.36")
                t.column("playUA", .text).notNull().defaults(to: "")
                t.column("websearchurl", .text).notNull().defaults(to: "")
                t.column("searchname", .text).notNull().defaults(to: "")
                t.column("searchid", .text).notNull().defaults(to: "")
                t.column("searchpic", .text).notNull().defaults(to: "")
                t.column("searchstarr", .text).notNull().defaults(to: "")
                t.column("detaillist", .text).notNull().defaults(to: "")
                t.column("detailxl", .text).notNull().defaults(to: "")
                t.column("detailjs", .text).notNull().defaults(to: "")
                t.column("detailjsurl", .text).notNull().defaults(to: "")
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("updatedAt", .integer).notNull()
                t.uniqueKey(["name"])
            }

            // apiyuan 表
            try db.create(table: "apiyuan") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("searchurl", .text).notNull()
                t.column("searchua", .text).notNull().defaults(to: "")
                t.column("detailurl", .text).notNull().defaults(to: "")
                t.column("detailua", .text).notNull().defaults(to: "")
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.uniqueKey(["name"])
            }

            // subscription 表
            try db.create(table: "subscription") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("dyname", .text).notNull()
                t.column("dyurl", .text).notNull().unique()
                t.column("dyzz", .text).notNull().defaults(to: "")
                t.column("lastSyncAt", .integer).notNull()
            }

            // favorite 表
            try db.create(table: "favorite") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("laiyuan", .text).notNull().defaults(to: "")
                t.column("imgurl", .text).notNull().defaults(to: "")
                t.column("detailurl", .text).notNull().defaults(to: "")
                t.column("detailua", .text).notNull().defaults(to: "")
                t.column("xianlu", .integer).notNull().defaults(to: 0)
                t.column("jishu", .integer).notNull().defaults(to: 0)
                t.column("addedAt", .integer).notNull()
            }

            // history 表
            try db.create(table: "history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("laiyuan", .text).notNull().defaults(to: "")
                t.column("imgurl", .text).notNull().defaults(to: "")
                t.column("detailurl", .text).notNull().defaults(to: "")
                t.column("detailua", .text).notNull().defaults(to: "")
                t.column("xianlu", .integer).notNull().defaults(to: 0)
                t.column("jishu", .integer).notNull().defaults(to: 0)
                t.column("progress", .double).notNull().defaults(to: 0)
                t.column("lastPlayedAt", .integer).notNull()
            }

            // settings 表
            try db.create(table: "settings") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull().defaults(to: "")
                t.column("updatedAt", .integer).notNull()
            }

            // jiexisetting 表
            try db.create(table: "jiexisetting") { t in
                t.column("bianma", .text).primaryKey()
                t.column("zhuurl", .text).notNull().defaults(to: "")
                t.column("beiurl", .text).notNull().defaults(to: "")
            }

            // search_history 表
            try db.create(table: "search_history") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("keyword", .text).notNull()
                t.column("searchedAt", .integer).notNull()
            }
        }

        migrator.registerMigration("v2_add_dyurl") { db in
            // zhanyuan 表：添加 dyurl 列，重建唯一约束为 (name, dyurl)
            try db.execute(sql: """
                CREATE TABLE zhanyuan_v2 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    searchUrl TEXT NOT NULL,
                    searchUA TEXT NOT NULL DEFAULT 'Mozilla/5.0 (Linux; Android 12; Redmi K30 Pro Build/SKQ1.220303.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/99.0.4844.88 Mobile Safari/537.36',
                    playUA TEXT NOT NULL DEFAULT '',
                    websearchurl TEXT NOT NULL DEFAULT '',
                    searchname TEXT NOT NULL DEFAULT '',
                    searchid TEXT NOT NULL DEFAULT '',
                    searchpic TEXT NOT NULL DEFAULT '',
                    searchstarr TEXT NOT NULL DEFAULT '',
                    detaillist TEXT NOT NULL DEFAULT '',
                    detailxl TEXT NOT NULL DEFAULT '',
                    detailjs TEXT NOT NULL DEFAULT '',
                    detailjsurl TEXT NOT NULL DEFAULT '',
                    isActive BOOLEAN NOT NULL DEFAULT 1,
                    updatedAt INTEGER NOT NULL,
                    dyurl TEXT NOT NULL DEFAULT '',
                    UNIQUE(name, dyurl)
                )
            """)
            try db.execute(sql: "INSERT INTO zhanyuan_v2 SELECT id, name, searchUrl, searchUA, playUA, websearchurl, searchname, searchid, searchpic, searchstarr, detaillist, detailxl, detailjs, detailjsurl, isActive, updatedAt, '' FROM zhanyuan")
            try db.execute(sql: "DROP TABLE zhanyuan")
            try db.execute(sql: "ALTER TABLE zhanyuan_v2 RENAME TO zhanyuan")

            // apiyuan 表：添加 dyurl 列，重建唯一约束为 (name, dyurl)
            try db.execute(sql: """
                CREATE TABLE apiyuan_v2 (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    searchurl TEXT NOT NULL,
                    searchua TEXT NOT NULL DEFAULT '',
                    detailurl TEXT NOT NULL DEFAULT '',
                    detailua TEXT NOT NULL DEFAULT '',
                    isActive BOOLEAN NOT NULL DEFAULT 1,
                    dyurl TEXT NOT NULL DEFAULT '',
                    UNIQUE(name, dyurl)
                )
            """)
            try db.execute(sql: "INSERT INTO apiyuan_v2 SELECT id, name, searchurl, searchua, detailurl, detailua, isActive, '' FROM apiyuan")
            try db.execute(sql: "DROP TABLE apiyuan")
            try db.execute(sql: "ALTER TABLE apiyuan_v2 RENAME TO apiyuan")

            print("[DatabaseManager] v2 迁移完成：zhanyuan/aphiyuan 添加 dyurl 列，唯一约束改为 (name, dyurl)")
        }

        migrator.registerMigration("v3_add_download") { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS download (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL,
                    laiyuan TEXT NOT NULL DEFAULT '',
                    imgurl TEXT NOT NULL DEFAULT '',
                    detailurl TEXT NOT NULL DEFAULT '',
                    playurl TEXT NOT NULL DEFAULT '',
                    jishu INTEGER NOT NULL DEFAULT 0,
                    progress REAL NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'pending',
                    filePath TEXT NOT NULL DEFAULT '',
                    fileSize INTEGER NOT NULL DEFAULT 0,
                    downloadedSize INTEGER NOT NULL DEFAULT 0,
                    addedAt INTEGER NOT NULL
                )
            """)
            print("[DatabaseManager] v3 迁移完成：创建 download 表")
        }

        migrator.registerMigration("v4_add_download_columns") { db in
            try db.execute(sql: "ALTER TABLE download ADD COLUMN sourceType TEXT")
            try db.execute(sql: "ALTER TABLE download ADD COLUMN engineKey TEXT")
            try db.execute(sql: "ALTER TABLE download ADD COLUMN vodId TEXT")
            try db.execute(sql: "ALTER TABLE download ADD COLUMN headers TEXT")
            print("[DatabaseManager] v4 迁移完成：download 表新增 sourceType/engineKey/vodId/headers 字段")
        }

        return migrator
    }

    // MARK: - UserDefaults 数据迁移

    /// App 升级后首次启动，将 UserDefaults 中的旧订阅 URL 迁移到 SQLite
    private func migrateUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        let migrationKey = "vbox_sqlite_migration_done"
        guard !defaults.bool(forKey: migrationKey) else { return }

        // 读取旧订阅 URL 列表
        let urlsKey = "subscribed_config_urls"
        guard let oldURLs = defaults.stringArray(forKey: urlsKey), !oldURLs.isEmpty else {
            defaults.set(true, forKey: migrationKey)
            return
        }

        let now = Int64(Date().timeIntervalSince1970)
        var migratedCount = 0

        do {
            try dbPool.write { db in
                for url in oldURLs {
                    // 检查是否已存在
                    let existing = try SubscriptionRecord
                        .filter(SubscriptionRecord.Columns.dyurl == url)
                        .fetchOne(db)
                    if existing == nil {
                        // 从 URL 提取订阅名称
                        let name = (url as NSString).lastPathComponent
                            .replacingOccurrences(of: ".json", with: "")
                            .replacingOccurrences(of: ".txt", with: "")
                        let record = SubscriptionRecord(
                            dyname: name,
                            dyurl: url,
                            dyzz: "",
                            lastSyncAt: 0  // 标记为未同步，下次启动时会重新下载
                        )
                        try record.save(db)
                        migratedCount += 1
                    }
                }
            }
            print("[DatabaseManager] ✅ 迁移完成: \(migratedCount)/\(oldURLs.count) 个订阅 URL 已写入 SQLite")
        } catch {
            print("[DatabaseManager] ❌ 迁移失败: \(error)")
        }

        // 标记迁移完成
        defaults.set(true, forKey: migrationKey)
    }

    // MARK: - Zhanyuan CRUD

    func saveZhanyuanSites(_ sites: [ZhanyuanSite], dyurl: String) {
        guard !sites.isEmpty else {
            print("[DatabaseManager] saveZhanyuanSites: 站点列表为空，跳过（保留现有数据）")
            return
        }
        do {
            // 事务保护：只删除同订阅源的旧记录，再插入新记录
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM zhanyuan WHERE dyurl = ?", arguments: [dyurl])
                for site in sites {
                    try site.insert(db)
                }
            }
            print("[DatabaseManager] 保存 zhanyuan 站点完成: \(sites.count) 个 (dyurl=\(dyurl.prefix(50)))")
        } catch {
            print("[DatabaseManager] 保存 zhanyuan 失败，数据已回滚: \(error)")
        }
    }

    /// 清空指定订阅源的 zhanyuan 数据（dyurl 为空时清空全部）
    func clearZhanyuanSites(dyurl: String) {
        guard !dyurl.isEmpty else {
            print("[DatabaseManager] clearZhanyuanSites: dyurl 为空，跳过")
            return
        }
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM zhanyuan WHERE dyurl = ?", arguments: [dyurl])
            }
            print("[DatabaseManager] 已清空 zhanyuan 表中 dyurl=\(dyurl.prefix(50)) 的记录")
        } catch {
            print("[DatabaseManager] 清空 zhanyuan 失败: \(error)")
        }
    }

    /// 清空全部 zhanyuan 数据（无订阅源时调用）
    func clearAllZhanyuanSites() {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM zhanyuan")
            }
            print("[DatabaseManager] 已清空全部 zhanyuan 表")
        } catch {
            print("[DatabaseManager] 清空 zhanyuan 失败: \(error)")
        }
    }

    /// 清空指定订阅源的 apiyuan 数据
    func clearApiYuanSites(dyurl: String) {
        guard !dyurl.isEmpty else {
            print("[DatabaseManager] clearApiYuanSites: dyurl 为空，跳过")
            return
        }
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM apiyuan WHERE dyurl = ?", arguments: [dyurl])
            }
            print("[DatabaseManager] 已清空 apiyuan 表中 dyurl=\(dyurl.prefix(50)) 的记录")
        } catch {
            print("[DatabaseManager] 清空 apiyuan 失败: \(error)")
        }
    }

    /// 清空全部 apiyuan 数据（无订阅源时调用）
    func clearAllApiYuanSites() {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM apiyuan")
            }
            print("[DatabaseManager] 已清空全部 apiyuan 表")
        } catch {
            print("[DatabaseManager] 清空 apiyuan 失败: \(error)")
        }
    }

    /// 清空 subscription 表（删除订阅源时调用）
    func clearAllSubscriptions() {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM subscription")
            }
            print("[DatabaseManager] 已清空 subscription 表")
        } catch {
            print("[DatabaseManager] 清空 subscription 失败: \(error)")
        }
    }

    /// 删除指定订阅源的 subscription 记录
    func clearSubscription(url: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql: "DELETE FROM subscription WHERE url = ?", arguments: [url])
            }
            print("[DatabaseManager] 已删除 subscription 记录: \(url.prefix(50))")
        } catch {
            print("[DatabaseManager] 删除 subscription 失败: \(error)")
        }
    }

    func queryActiveZhanyuanSites() -> [ZhanyuanSite] {
        do {
            return try dbPool.read { db in
                try ZhanyuanSite
                    .filter(ZhanyuanSite.Columns.isActive == true)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询 zhanyuan 失败: \(error)")
            return []
        }
    }

    func queryAllZhanyuanSites() -> [ZhanyuanSite] {
        do {
            return try dbPool.read { db in
                try ZhanyuanSite
                    .order(ZhanyuanSite.Columns.name.asc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询全部 zhanyuan 失败: \(error)")
            return []
        }
    }

    func updateZhanyuanActive(name: String, isActive: Bool) {
        do {
            try dbPool.write { db in
                try ZhanyuanSite
                    .filter(ZhanyuanSite.Columns.name == name)
                    .updateAll(db, ZhanyuanSite.Columns.isActive.set(to: isActive))
            }
        } catch {
            print("[DatabaseManager] 更新 zhanyuan 状态失败: \(error)")
        }
    }

    // MARK: - ApiYuan CRUD

    func saveApiYuanSites(_ sites: [ApiYuanSite], dyurl: String) {
        do {
            try dbPool.write { db in
                for site in sites {
                    try site.save(db, onConflict: .replace)
                }
            }
            print("[DatabaseManager] 保存 \(sites.count) 个 apiyuan 站点 (dyurl=\(dyurl.prefix(50)))")
        } catch {
            print("[DatabaseManager] 保存 apiyuan 失败: \(error)")
        }
    }

    func queryActiveApiYuanSites() -> [ApiYuanSite] {
        do {
            return try dbPool.read { db in
                try ApiYuanSite
                    .filter(ApiYuanSite.Columns.isActive == true)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询 apiyuan 失败: \(error)")
            return []
        }
    }

    func queryAllApiYuanSites() -> [ApiYuanSite] {
        do {
            return try dbPool.read { db in
                try ApiYuanSite
                    .order(ApiYuanSite.Columns.name.asc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询全部 apiyuan 失败: \(error)")
            return []
        }
    }

    func updateApiYuanActive(name: String, isActive: Bool) {
        do {
            try dbPool.write { db in
                try ApiYuanSite
                    .filter(ApiYuanSite.Columns.name == name)
                    .updateAll(db, ApiYuanSite.Columns.isActive.set(to: isActive))
            }
        } catch {
            print("[DatabaseManager] 更新 apiyuan 状态失败: \(error)")
        }
    }

    // MARK: - Subscription CRUD

    func saveSubscription(_ record: SubscriptionRecord) {
        do {
            try dbPool.write { db in
                try record.save(db, onConflict: .replace)
            }
        } catch {
            print("[DatabaseManager] 保存订阅记录失败: \(error)")
        }
    }

    func querySubscriptions() -> [SubscriptionRecord] {
        do {
            return try dbPool.read { db in
                try SubscriptionRecord
                    .order(SubscriptionRecord.Columns.id.asc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询订阅记录失败: \(error)")
            return []
        }
    }

    func updateSubscriptionSyncTime(dyurl: String, timestamp: Int64) {
        do {
            try dbPool.write { db in
                try SubscriptionRecord
                    .filter(SubscriptionRecord.Columns.dyurl == dyurl)
                    .updateAll(db, SubscriptionRecord.Columns.lastSyncAt.set(to: timestamp))
            }
        } catch {
            print("[DatabaseManager] 更新同步时间失败: \(error)")
        }
    }

    func deleteSubscription(dyurl: String) {
        do {
            try dbPool.write { db in
                try SubscriptionRecord
                    .filter(SubscriptionRecord.Columns.dyurl == dyurl)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除订阅记录失败: \(error)")
        }
    }

    // MARK: - Favorite CRUD

    func addFavorite(_ record: FavoriteRecord) {
        do {
            try dbPool.write { db in
                try record.save(db)
            }
        } catch {
            print("[DatabaseManager] 添加收藏失败: \(error)")
        }
    }

    func removeFavorite(id: Int) {
        do {
            try dbPool.write { db in
                try FavoriteRecord
                    .filter(FavoriteRecord.Columns.id == id)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除收藏失败: \(error)")
        }
    }

    func queryFavorites() -> [FavoriteRecord] {
        do {
            return try dbPool.read { db in
                try FavoriteRecord
                    .order(FavoriteRecord.Columns.addedAt.desc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询收藏失败: \(error)")
            return []
        }
    }

    func isFavorite(detailurl: String, xianlu: Int, jishu: Int) -> Bool {
        do {
            return try dbPool.read { db in
                let count = try FavoriteRecord
                    .filter(FavoriteRecord.Columns.detailurl == detailurl)
                    .filter(FavoriteRecord.Columns.xianlu == xianlu)
                    .filter(FavoriteRecord.Columns.jishu == jishu)
                    .fetchCount(db)
                return count > 0
            }
        } catch {
            return false
        }
    }

    /// 根据 detailurl + laiyuan 查询收藏记录，返回 id（用于取消收藏）
    func isFavorite2(detailurl: String, laiyuan: String) -> Int? {
        do {
            return try dbPool.read { db in
                try FavoriteRecord
                    .filter(FavoriteRecord.Columns.detailurl == detailurl)
                    .filter(FavoriteRecord.Columns.laiyuan == laiyuan)
                    .fetchOne(db)?.id
            }
        } catch {
            return nil
        }
    }

    // MARK: - History CRUD

    func addOrUpdateHistory(_ record: HistoryRecord) {
        do {
            try dbPool.write { db in
                if let existing = try HistoryRecord
                    .filter(HistoryRecord.Columns.detailurl == record.detailurl)
                    .filter(HistoryRecord.Columns.xianlu == record.xianlu)
                    .filter(HistoryRecord.Columns.jishu == record.jishu)
                    .fetchOne(db)
                {
                    var updated = existing
                    updated.name = record.name
                    updated.laiyuan = record.laiyuan
                    updated.imgurl = record.imgurl
                    updated.detailua = record.detailua
                    updated.progress = record.progress
                    updated.lastPlayedAt = record.lastPlayedAt
                    try updated.update(db)
                } else {
                    try record.save(db)
                }
            }
        } catch {
            print("[DatabaseManager] 保存历史记录失败: \(error)")
        }
    }

    func queryHistory() -> [HistoryRecord] {
        do {
            return try dbPool.read { db in
                try HistoryRecord
                    .order(HistoryRecord.Columns.lastPlayedAt.desc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询历史记录失败: \(error)")
            return []
        }
    }

    func deleteHistory(id: Int) {
        do {
            try dbPool.write { db in
                try HistoryRecord
                    .filter(HistoryRecord.Columns.id == id)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除历史记录失败: \(error)")
        }
    }

    func clearHistory() {
        do {
            try dbPool.write { db in
                try HistoryRecord.deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 清空历史记录失败: \(error)")
        }
    }

    // MARK: - Settings CRUD

    func setSetting(key: String, value: String) {
        do {
            try dbPool.write { db in
                try UserSetting(
                    key: key,
                    value: value,
                    updatedAt: Int64(Date().timeIntervalSince1970)
                ).save(db, onConflict: .replace)
            }
        } catch {
            print("[DatabaseManager] 保存设置失败: \(error)")
        }
    }

    func getSetting(key: String) -> String? {
        do {
            return try dbPool.read { db in
                try UserSetting
                    .filter(UserSetting.Columns.key == key)
                    .fetchOne(db)?.value
            }
        } catch {
            print("[DatabaseManager] 读取设置失败: \(error)")
            return nil
        }
    }

    func deleteSetting(key: String) {
        do {
            try dbPool.write { db in
                try UserSetting
                    .filter(UserSetting.Columns.key == key)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除设置失败: \(error)")
        }
    }

    // MARK: - JiexiSetting CRUD

    func saveJiexiSetting(_ record: JiexiSetting) {
        do {
            try dbPool.write { db in
                try record.save(db, onConflict: .replace)
            }
        } catch {
            print("[DatabaseManager] 保存解析设置失败: \(error)")
        }
    }

    func queryJiexiSettings() -> [JiexiSetting] {
        do {
            return try dbPool.read { db in
                try JiexiSetting.fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询解析设置失败: \(error)")
            return []
        }
    }

    func deleteJiexiSetting(bianma: String) {
        do {
            try dbPool.write { db in
                try JiexiSetting
                    .filter(JiexiSetting.Columns.bianma == bianma)
                    .deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 删除解析设置失败: \(error)")
        }
    }

    // MARK: - SearchHistory CRUD

    func addSearchHistory(keyword: String) {
        do {
            try dbPool.write { db in
                try SearchHistoryRecord(
                    keyword: keyword,
                    searchedAt: Int64(Date().timeIntervalSince1970)
                ).save(db)
            }
        } catch {
            print("[DatabaseManager] 保存搜索历史失败: \(error)")
        }
    }

    func querySearchHistory(limit: Int = 20) -> [SearchHistoryRecord] {
        do {
            return try dbPool.read { db in
                try SearchHistoryRecord
                    .order(SearchHistoryRecord.Columns.searchedAt.desc)
                    .limit(limit)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询搜索历史失败: \(error)")
            return []
        }
    }

    func clearSearchHistory() {
        do {
            try dbPool.write { db in
                try SearchHistoryRecord.deleteAll(db)
            }
        } catch {
            print("[DatabaseManager] 清空搜索历史失败: \(error)")
        }
    }

    // MARK: - Download CRUD

    func addDownload(_ record: DownloadRecord) {
        do {
            try dbPool.write { db in
                try record.save(db, onConflict: .replace)
            }
            print("[DatabaseManager] 添加下载: \(record.name)")
        } catch {
            print("[DatabaseManager] 添加下载失败: \(error)")
        }
    }

    func queryDownloads() -> [DownloadRecord] {
        do {
            return try dbPool.read { db in
                try DownloadRecord
                    .order(DownloadRecord.Columns.addedAt.desc)
                    .fetchAll(db)
            }
        } catch {
            print("[DatabaseManager] 查询下载列表失败: \(error)")
            return []
        }
    }

    func updateDownloadProgress(id: Int, progress: Double, downloadedSize: Int64, status: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    UPDATE download SET progress = ?, downloadedSize = ?, status = ? WHERE id = ?
                """, arguments: [progress, downloadedSize, status, id])
            }
        } catch {
            print("[DatabaseManager] 更新下载进度失败: \(error)")
        }
    }

    func updateDownloadPath(id: Int, path: String, fileSize: Int64 = 0, status: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    UPDATE download SET filePath = ?, fileSize = ?, status = ?, progress = 1.0 WHERE id = ?
                """, arguments: [path, fileSize, status, id])
            }
        } catch {
            print("[DatabaseManager] 更新下载路径失败: \(error)")
        }
    }

    func updateDownloadStatus(id: Int, status: String) {
        do {
            try dbPool.write { db in
                try db.execute(sql: """
                    UPDATE download SET status = ? WHERE id = ?
                """, arguments: [status, id])
            }
        } catch {
            print("[DatabaseManager] 更新下载状态失败: \(error)")
        }
    }

    func deleteDownload(id: Int) {
        do {
            try dbPool.write { db in
                try DownloadRecord
                    .filter(DownloadRecord.Columns.id == id)
                    .deleteAll(db)
            }
            print("[DatabaseManager] 删除下载: id=\(id)")
        } catch {
            print("[DatabaseManager] 删除下载失败: \(error)")
        }
    }

    func clearDownloads() {
        do {
            try dbPool.write { db in
                try DownloadRecord.deleteAll(db)
            }
            print("[DatabaseManager] 已清空下载列表")
        } catch {
            print("[DatabaseManager] 清空下载失败: \(error)")
        }
    }

    // MARK: - 备份还原辅助（批量清空）

    func clearAllFavorites() {
        do {
            try dbPool.write { db in
                try FavoriteRecord.deleteAll(db)
            }
            print("[DatabaseManager] 已清空收藏表")
        } catch {
            print("[DatabaseManager] 清空收藏失败: \(error)")
        }
    }

    func clearAllJiexiSettings() {
        do {
            try dbPool.write { db in
                try JiexiSetting.deleteAll(db)
            }
            print("[DatabaseManager] 已清空解析设置表")
        } catch {
            print("[DatabaseManager] 清空解析设置失败: \(error)")
        }
    }

    /// 删除指定的设置键（覆盖策略还原个人设置时使用）
    func deleteSettings(keys: [String]) {
        guard !keys.isEmpty else { return }
        do {
            try dbPool.write { db in
                try UserSetting
                    .filter(UserSetting.Columns.key.in(keys))
                    .deleteAll(db)
            }
            print("[DatabaseManager] 已删除 \(keys.count) 个设置键")
        } catch {
            print("[DatabaseManager] 删除设置失败: \(error)")
        }
    }
}
