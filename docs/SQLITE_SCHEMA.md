# ASM 資料庫

ASM 自有 SQLite 保存管理意圖與操作證據，不是 Codex 對話資料庫，不保存對話本文，也不是 session 是否存在的權威來源。官方與 Desktop 邊界見[架構](ARCHITECTURE.md)及[安全規則](SAFETY.md)。

## 身份與位置

正式 App 在 Application Support 的 bundle 專屬目錄使用 state.sqlite，第一次 live reload 時初始化並 reconciliation。Fixture target 不建立 production database。

| 項目 | 約定 |
| --- | --- |
| 目前 schema | 22，以 SQLiteStateStore.currentSchemaVersion 為準 |
| application_id | 1095978289（ASM1） |
| SQLite 來源 | macOS SDK libsqlite3，透過 CSQLite3 匯入 |
| 主檔／備份權限 | 0600 |
| 主檔 journal | WAL |
| 備份 journal | DELETE，單檔可獨立開啟 |

[SQLiteStateStore.swift](../macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift) 是欄位、約束、索引及升版 SQL 的唯一精確來源。本頁解釋資料責任，不複製 DDL。高於支援的版本或不符的 application_id 會拒絕開啟，不自動降版。

## 現行資料表分工

| 表／表組 | 保存內容與約束 |
| --- | --- |
| provider_checkpoints | inventory hash、runtime、更新時間、清單與保護完整性；不是 credentials |
| trash_memberships | 精確 ID 與 Manager Trash 意圖；原生 Archived 不自動等於 Trash |
| deleted_sessions | 官方刪除或受審外部刪除確認的 tombstone，連到 Delete Report；不表示 Desktop 清理完成 |
| operation_previews／operation_items／operation_reports | frozen identity、manager intent、有效期、claim 狀態、逐筆結果及 consume |
| archive_batch_plans／units／items／reports | descendant-aware 計畫、固定順序與原子 finalization；存在資料模型不表示 shipping executor 已放行 |
| codex_ghost_repair_bulk_previews | 完整批次 Preview 與 checksummed payload，單憑保存不具 mutation authority |
| codex_ghost_repair_bulk_confirmation_challenges／receipts | 一次整批確認、精確 lineage 與 receipt；確認不是 execution claim |
| codex_ghost_repair_bulk_frozen_plan_sources | selected-only source，與新 Preview 原子保存；缺少相符來源的舊 Preview 不產生 production plan |
| codex_ghost_repair_bulk_live_execution_journal | backup-bound plan、claim、最多一次 attempt、terminal 或 closed_before_attempt |
| codex_desktop_cleanup_bindings | canonical Delete Report 與同組 Bulk 計畫的不可變關聯 |
| retired_history_keys | 已清詳細紀錄的最小防重複識別；INSERT triggers 拒絕舊 ID 重用 |

Ghost 表名是歷史內部識別字，不是另一項產品功能。v10–v13 的早期 Ghost／Category A 表及 v17 draft journal 留作相容讀回與測試；不得刪除升版定義、把舊 record 升格成新授權，或恢復第二條 shipping mutation 入口。

## 保存與交易約束

Preview 凍結完整 native ID、manager key、預期狀態／保護、inventory hash、操作意圖、有效期與必要 membership-set hash。時間先正規化為毫秒。一般 lifecycle 保存 confirmation token hash，不保存明文；歷史 bulk challenge payload 的確認文字是受限相容資料，不得重新解讀為目前授權。

同一 transaction 保存 Preview header 與 items；claim 是一次狀態轉移。Report 的 exact item set、結果與 consume 必須一起完成；任何不符全部 rollback。Trash add／remove 與 Deleted tombstone 只能依正式成功證據在同一 finalization 套用，不能先改清單再補報告。

archive batch claim 同時鎖定所有 member Preview，不能被 single-item API 再消費；finalization 要符合 terminal-prefix policy。完整 payload hash、語意 digest 與 indexed columns 讀回交叉驗證，不能另建寬鬆 decoder。

Bulk receipt 只保存確認事實；live journal 分為 prepared、claimed、attempted、terminal、closed_before_attempt，attempt count 限 0–1。關閉未執行計畫保存獨立 closure，不偽造 claim 或 terminal Report。fresh recovery 只 compare-and-set 同一現行 schema record，不做 bootstrap／migration 或改 journal mode。

## Desktop cleanup binding

binding 的主鍵是 canonical Delete Report ID，綁定完整 tombstone 集合、Bulk request／operation／receipt／plan／backup、原 prepared journal hash、精確 ID／分類及正規化時間。插入時同一 transaction 核對 tombstones、receipt lineage、計畫時間及全部目標，之後只能讀回同一 binding，不換新計畫。

它不存第二套 Desktop 成功旗標。畫面由原 tombstone、binding 與經驗證 journal 推導 pending、recovery required、closed／not verified、unknown 或原時間點 verified。

一般 Report History 清理不移除關聯 tombstone、binding 或 Bulk journal；v22 的完整成功群組清理才可一併處理。不能沿用舊版「所有 retention 永遠保留 tombstone」的描述，也不能只刪報告就把未解計畫丟掉。

## 升版與還原

開啟較舊 store 時，先以 Online Backup API 建立並驗證升版前備份；每個 migration 分別在 transaction 內更新 schema 與 user_version。單一步驟失敗會 rollback，不能聲稱整條多版本升級鏈全部回到最初版本。既有 payload bytes 與舊紀錄證據保留，不因升版自動確認、執行或關閉。

v22 新增完成紀錄清理及 retired_history_keys，最小識別不隨詳細紀錄消失。用新版升級後，不再以不支援版本的舊 App 開同一資料庫。

Core 還原能力要求先關閉 store、驗證來源、建立 pre-restore backup，再透過 Online Backup 與還原後驗證處理。完整使用者還原／備份清理 executor 尚在[後續方向](ROADMAP.md)；不要直接覆蓋主檔或刪 sidecar 充當還原。

## 完成紀錄保留

Deleted 清單移除與實體歷史清理分開。`retired_history_keys` 的 `deleted-list:<managerKey>` 命名空間保存清單移除標記，無需 schema 升版。`visibleDeletedSessions` 僅供畫面使用；內部 `deletedSessions` 與 cleanup linkage 仍取得完整 tombstone，保留 claim／復原與原批次關聯。確認使用五分鐘有效的凍結列 fingerprint，來源改變就停止。此操作不刪報告、計畫、Codex 資料或備份，也不改變既有報告清理資格。

[CompletedHistoryRetention.swift](../macos/AgentSessionManager/Sources/AgentSessionManagerCore/CompletedHistoryRetention.swift) 共用自動與手動清理的 Preview、fingerprint、完整群組驗證與回讀。

- App 啟動／重新整理成功後檢查超過 30 天的完整成功紀錄，同次執行最多每天一次。
- 可清包含已驗證 Deleted 及相符 Ghost 計畫／確認／執行／報告，另含獨立成功操作與完整成功 Archive batch。
- 未完成、unknown、失敗、缺乏證據、舊版不支援形狀或部分選取的群組保留；操作中或需要恢復時整次清理延後。
- 先保存 request／preview／manifest／operation／batch 等最小退休識別，再清詳細群組，避免舊操作重用。
- 一般 Report 的 500 份上限只移除安全可清者；受保護資料可超過上限，不丟證據或因此拒絕新操作。
- 清理不碰 Codex session、備份檔或全域設定 pending／verified 檔，不自動 VACUUM，也不報未量測的釋放空間。

Deleted 與 Report History 的入口與確認步驟見使用手冊，不在 schema 文件重複。

## 查詢、診斷與維護

歷史使用 completed_at／ID 的 keyset 分頁、精確操作與結果 filters、轉義搜尋；頁面有界，完整 native ID 保留。匯出是既有結果的副本，不建立新操作；預設避免 title、project、任意錯誤本文、token 與 hash，CSV 需防公式注入。即使匯出已遮蔽其他欄位，ID 仍可能是私人資料。

DiagnosticLogStore 與 lifecycle SQLite 分開，以 JSONL 保存有界診斷事件：30 天、10,000 筆或 20 MiB 任一先到即清最舊事件；檔案 0600。它不保存 prompt、conversation body、token 或原始 payload，不能替代正式 Report。

備份維護目前是唯讀評估：保護近期及每類最新備份，未知時間／權限等不確定候選保留。Compaction 只評估 freelist 與可能收益；真正備份清理／還原／壓縮需要另行設計凍結預覽、確認與驗證，不以資料庫變大為由自動執行。
