# 安全規則與批次契約

本文件定義不可因 UI 簡化或文件收斂而削弱的規則。它不授權操作真實資料；目前實測範圍見[驗收狀態](VALIDATION.md)，操作見[使用手冊](USER_GUIDE.md)。

## 資料與權限分界

| 邊界 | 可以做什麼 | 不能據此推論 |
| --- | --- | --- |
| 官方 App Server | 經操作專屬版本准入，封存、還原、刪除並正式回讀 | RPC acknowledgement／列表漏項不代表刪除成功 |
| ASM 自有 SQLite | 保存管理意圖、凍結範圍、claim、結果與復原證據 | Deleted 紀錄不代表 Desktop／設定／備份已全清 |
| Desktop 私有資料庫 | 只依已驗證版本與 schema，清除精確已確認 Ghost 殘留 | 不能一般化為任意 SQL 修復或刪除所有未知關聯 |
| 全域設定 JSON | 成功結果後另看 diff、另確認，只移除已知 session 專屬欄位 | 對話確認不自動授權設定清理 |
| 備份與歷史 | 備份保留復原證據；ASM 完成紀錄依安全保留規則清理 | 清紀錄不等於清備份、釋放 bytes 或安全抹除 |

完整 provider／native ID 是身份，title、project、cwd 或搜尋不是授權。預覽須綁定操作、版本、清單 checkpoint、保護證據、精確目標與有效期；執行不能重新查詢擴張或悄悄縮小範圍。

## 官方 lifecycle 的保護

- 永久刪除只能從 Manager Trash Bin 開始；Archive 是保留，不是等待刪除。
- 已知置頂、執行中、目前對話或置頂子對話都阻擋。置頂／子對話證據未知或衝突也阻擋；不支援的子對話 affected-set 不送 request。
- 跨主機 running／current／writer 未知不是「已確認無占用」。只在已准入的操作契約下明示 attemptMayFail，允許官方單次 request 安全拒絕；不能用這項例外繞過私有 DB 維護檢查。
- 確認後先 durable claim，每個 ID 最多送一次 request。官方 batch 全批 preflight，第一個 failure／unknown 後停止，剩餘列 notAttempted；不把多個 RPC 稱為原子批次。
- Archive／Restore 成功分別要求較新、完整、同 runtime、同完整 ID 的 Archived／Active 回讀。
- Delete 成功須同時有較新的完整 active＋archived inventory 缺席，以及該操作准入版本的精確不存在回應。timeout、自由文字 404、清單漏項或不符 ID 都不能替代。
- 外部刪除確認使用獨立的 readback-only 契約，不呼叫 Delete，也不借用其他版本的缺席判準。
- 官方操作失敗或未知不改 Trash 意圖；成功的 membership／tombstone 與 Report 在同一 ASM transaction 保存。恢復只回讀原操作，不再次送出。

## Ghost 判準：兩個訊號一致

候選只限 Desktop catalog 的 host_id = 'local'。不能用「不是某個已知雲端 host」的黑名單；雲端對話沒有本機 canonical row 是正常狀態。

在已驗證 runtime／schema 下，確認 Ghost 必須同時符合：

1. 目前本機 canonical state 的 threads 中沒有精確 ID。
2. 官方 thread/read 回傳 error，code 為 -32600，message 完整等於 thread not loaded: <同一 ID>。

成功 result 中的 status.type = notLoaded 代表對話存在，**與上述 error 意思不同**。逾時、其他錯誤、缺席證據不足或互相矛盾一律保留並列明原因。missing_candidate、UI 沒顯示、只查 active 列表或 inventory 漏項，都不能單獨進入 eligibility 判斷。

完整官方清單另負責 present、pin 與 descendant 保護。canonical 仍在或官方讀得到的對話不能強制清除。掃描先使用 App Server 取得精確證據；寫入階段停止 App Server，不能一邊為檢查重開 writer、一邊改資料庫。

批次 Ghost 清理在 Final Review 及交易內刪除前，另從固定位置重新讀取釘選狀態。任何選中對話已被釘選，或釘選資訊缺失、格式不明、檔案不安全或讀取期間變動，都停止整批清理；不沿用掃描時的未釘選結論。既有操作的結果核對仍只讀取結果證據，不因事後釘選變化而重新執行清理。

## 私有 DB 維護時窗

Ghost Delete 保持預設關閉、Experimental、runtime／schema 鎖定且 fail closed；短觀察窗與 SQLite 鎖不是官方 maintenance lease。

實際寫入前，App 必須：

1. 停止自己持有的 Codex transport，要求 Desktop、CLI、App Server 及編輯器整合退出。
2. 驗證相關程序、五組 DB handle、檔案穩定觀察與 profile 條件；transaction 前再查。單次 lsof 零持有者不夠，短生命週期 writer 可能已關閉連線。
3. 核對 schema、integrity、目標資格、容量與備份權限，取得整批共用的完整備份並驗證 hash 與可讀性。
4. 所有 gate 通過後才建立一次 mutation claim；owner／容量等前置唯讀診斷不消耗 claim。

已確認但尚未準備計畫的 owner 阻擋，可關閉 Codex 後明確重新檢查同一批。已準備、已 claim、可能已執行、漂移或 unknown 不回到新確認或新計畫。ASM 的協作鎖不能約束不支援該鎖的舊版本或 Codex 程序。

## 分類、範圍與交易

基本分類為 ordinary Category A、automation Category B，以及不支援的關聯形狀。檢查包括 inbox、timeline、scan entries、自動化 target、摘要、turns 與 items；多列或未知 shape 不能略過。

- A：受支援的本機 catalog row，無自動化執行與其他受保護關聯；刪除精確 catalog row。
- B：catalog 與唯一 automation run／definition 符合已驗證形狀；刪除 catalog，run 保留並改為 ARCHIVED／auto，整批同一執行時間。自動化定義、排程及啟用／暫停狀態不動。
- 人工確認模式：僅另允許已知 session 摘要與受支援的暫停排程案例，仍不解除其他保護。每 session 最多 100 筆摘要，精確內容 hash 與數量都綁入確認；相同筆數但內容改變仍停止。

整個 Ghost batch 使用一個 BEGIN IMMEDIATE 交易，不做逐列 UI 迴圈。任一 precondition、row count 或回讀不符，交易 rollback。摘要清理涵蓋 attached DB，但不同 WAL 資料庫的交易不保證斷電時跨檔原子性；中斷後依證據判定，不宣稱必定全有或全無。

已選 catalog row 在 Final Review 前消失時，ID 仍保留：A 報 alreadyAbsent，B 即使 catalog 已無，仍完成必要的 run 封存。原本已無殘留的 ID 重新出現或重要證據漂移，整批停止。

catalog_revision 與 local sync-state observation_sequence 只增加**實際刪除的 catalog row 數**，不按選取數或 automation-only action 數增加；catalog row 自身同名欄位不是此 counter。watermark、未選 rows、自動化定義與 readback-only DB 必須不變。人工摘要模式唯一額外可改的是已凍結摘要範圍。

### 哪些漂移需要停止

ID／host 置換、automation identity／不受支援狀態、受保護關聯、schema、integrity 或資格證據改變會停止。title、cwd、read state、recency、observation 與非資格相關時間等顯示／同步 metadata 不能單獨取消整批確認。

掃描與執行前核對使用相同 canonical evidence representation，不能比較 raw whole-row hash 與 redacted whole-row hash。完整來源由驗證備份保護；不以寬鬆顯示欄位規則略過真正的目標漂移。

## 大量批次的產品完成條件

產品要一次掃描、分類、選取、確認並清除大量 Ghost，不能退化成逐筆右鍵或 1–2 筆 canary。初始 frozen Preview／executor 上限為 500；未經新的資源證據與使用者同意，不能降到 148 以下。

必須具備：

- 自動偵測與分類；Select All Eligible、累積 checkbox、selected-only、總選取數與阻擋原因。
- 單一 frozen manifest，綁定整組 ID、分類、預期效果、版本／schema 與保護證據；不 silent shrink。
- 一次整批確認與共用驗證備份；Preview、challenge、receipt、Final Review 是內部步驟，不要求逐筆 token、Snapshot、貼 UUID 或人工比 hash。
- 混合 A／B／alreadyAbsent 的整批交易，以及完整逐筆 success、failure、unknown、notAttempted 回報。
- 確定性測試含精確 148 筆混合案例，另覆蓋 1、2、10、500、超限、任一筆漂移、busy、中斷與冷啟動恢復。
- 既有 Ghost 大量清理之後，另驗證正常 session 經 App Delete、官方回讀、Desktop 回讀及 Codex cold start 不留下新 Ghost，才可宣稱整個產品目標完成。

歷史手動大量清理、新 App 小批次實測與大量隔離測試是不同證據，不能合併宣稱大量 App 實機驗收完成。實際完成與缺口只更新驗收狀態。

安全檢查由 App 承擔，不增加長篇人工實驗。真實資料 gate 不阻擋一般 UI、fixture 或隔離程式開發；Codex 仍開啟也不是停止產品實作的理由。沒有影響結果的新問題，不新增實驗、換 DMG／token 重跑或擅自選真實對話補測。

## 全域設定清理白名單

只在對話清理成功後，另凍結及確認 diff，移除下列位置中精確歸屬所選 ID 的資料：

- 根層 map：thread-project-assignments、thread-workspace-root-hints、thread-projectless-output-directories、thread-writable-roots。
- 根層 ID 陣列：projectless-thread-ids。
- electron-persisted-atom-state 下的 map：prompt-history、heartbeat-thread-permissions-by-id、thread-descriptions-v1。

主檔與 .bak 分別審閱。未知格式停止，不遞迴刪除所有字串命中，也不動全域專案定義、其他對話、自動化排程或工作資料夾。預覽在記憶體保留五分鐘，來源 bytes 改變就失效；取消或無變更不建立備份。

套用前重驗缺席、owner、來源與備份；每份 JSON 原子更新，但兩檔可能部分完成。pending／verified 記錄與私人備份保留，不自動重試、還原或隨 30 天 Report 清理。差異不得進一般 log 或公開 repository。

## 停止、恢復與保存證據

claim 後不能 retry、換 SQL、自動 restore、縮小 selection 或以新操作覆蓋 unknown。恢復與未執行計畫關閉各有獨立、精確綁定的 manager 流程，見[架構](ARCHITECTURE.md)。

備份不能直接蓋回正在使用的資料庫；WAL／SHM／journal 與新主檔不匹配可能損壞資料。還原需專門的關閉、備份與驗證流程，不在失敗時自動執行。

清除 Deleted 清單只保存顯示移除標記，不刪內部復原證據，也不把 unknown 改成 success。實體完成紀錄清理仍只處理有完整成功證據的群組，保留未解狀態與最小防重複標記，見[資料庫](SQLITE_SCHEMA.md)。磁碟釋放量只報已驗證數字，未知不估算；備份仍有私人資料時不宣稱安全抹除。
