# SQLite State Store v8

## Status and boundary

`SQLiteStateStore` 是 manager-owned lifecycle metadata store。Shipping App固定使用Codex Live，第一次live reload時bootstrap store並執行reconciliation；獨立test-only Fixture target不建立production database。Native Archive／Restore／Active ↔ Trash／Trash → Deleted的單筆與checkbox batch都以本store執行Preview-first claim／Report-after consume。SQLite v5凍結membership `add/remove` intent；v6凍結working directory；v7新增durable Deleted tombstone；v8允許同一batch Delete Report ID對應多筆tombstone。只有official Delete雙readback證明每個exact identity absent時，才在同一transaction移除成功項目的Trash membership、建立tombstone、寫Report並consume Preview。

這個資料庫是 manager-owned lifecycle metadata store，不是 Codex/Claude 的 session database，也不讀寫它們的 JSONL、SQLite、cache 或 rollout files。Native provider 仍是 session 是否存在及其 native state 的權威來源；local store 只保存 manager intent 與 readback evidence。

## Library choice

使用 macOS SDK 內建的 `libsqlite3`，透過 SwiftPM `CSQLite3` system-library target 匯入：

- 不增加第三方 package、下載、vendored binary 或額外 runtime。
- 直接使用 SQLite transaction、`PRAGMA user_version`、integrity check 與 Online Backup API。
- SwiftPM 與 local-package Xcode app 使用同一份 Core source。

不要把這項選擇改成直接操作 agent system 自己的 SQLite；兩者的 ownership 與安全邊界完全不同。

## Schema identity

- Current schema version：`8`
- `PRAGMA application_id`：`1095978289`（ASCII `ASM1`）
- Database 與 backup permissions：`0600`
- Live store journal：WAL
- Backup journal：DELETE，確保每份 backup 都是可獨立開啟的單一檔案

Version 大於 Core 支援版本、或 versioned database 的 `application_id` 不符時，open 會 fail closed。

## Tables

### `provider_checkpoints`

保存 reconciliation 所需的 provider inventory hash、runtime version、refresh time、inventory/protection completeness 與最後診斷。它不保存 provider credentials。

### `trash_memberships`

保存 manager Trash Bin 的 membership intent：provider、完整 native session ID、namespaced manager key、進入 Trash 時的 title/project/working-directory metadata、native state、inventory hash 與 reconciliation timestamps。

Archive 與 Trash 不會因 native state 都是 archived 而合併；只有存在此 membership 的 session 才屬於 manager Trash Bin。

### `deleted_sessions`

保存經 verified Permanent Delete 後的 durable manager tombstone：provider、完整native ID、manager key、刪除當時title/project/working directory、known size、frozen provider hash、evidence timestamp與Delete Report ID。`delete_report_id`在v8是可重複的audit grouping key，因為一份batch Report可證明多個exact IDs。它不保存conversation body，也不宣稱filesystem bytes已釋放。Tombstone與Report History retention／clear解耦；清除歷史不會讓Deleted collection消失。

### `operation_previews`

保存 frozen Preview header：legacy-compatible `operation`、distinct `manager_intent`、optional `trash_membership_mutation`、status、confirmation token **hash**、manifest hash、provider inventory hash、optional affected-set hash、expiry、item/size summary。`trash_membership_mutation` 只用於需要 native success readback後才可套用的 `add/remove`；它會綁進新版 manifest。不得保存明文 confirmation token。

### `operation_items`

保存 Preview 的逐筆 frozen identity、expected state/protection hash、project ID 與 working directory；Archive affected set 另保存 selected-root／descendant role、parent native ID 與 depth。執行後可附加 report ID、observed state、verified released bytes、evidence time 與 error。完整 native ID 永遠保留。

### `operation_reports`

保存 execution/readback summary：legacy-compatible `operation`、distinct `manager_intent`、outcome、counts、verified released bytes、completeness 與 report-level error。每個 report 對應一個 Preview。`Move to Archive` 在 manager history 中維持獨立 intent，不會冒充一般 Archive；舊 `operation` 欄仍保存舊 schema 可接受的相容值。

### `archive_batch_plans` / `archive_batch_units` / `archive_batch_items`

保存 descendant-aware Archive batch 的 canonical frozen plan。Plan 綁定 provider checkpoint、confirmation token hash、manifest hash、有效期與 exact counts；units 依 root manager key保存 deterministic ordinal、member Preview 與 affected-set hash；items 保存每個 member Preview 的 exact identity 與 item ordinal。任何一筆都不保存明文 confirmation token。

Plan claim 必須在同一 transaction 將 plan 與全部 member Previews 從 `prepared` 改為 `executing`。被 batch 引用的 Preview 不得由 single-item claim/report API 消費，避免同一 native mutation authorization 被兩條路徑 replay。

### `archive_batch_reports`

保存 batch-level terminal outcome、timestamps、attempted/success/failure/unknown/not-attempted counts 與 errors。Unit/item disposition 與 evidence 同 transaction 寫入原 plan tables，且全部 member Previews 一次 consume；不完整或不符合 terminal-prefix policy 的 finalization 全批 rollback。

## Data minimization

允許的資料只限 lifecycle 所需 metadata 與 evidence：

- provider、full native session ID、manager key
- title、project ID、working directory（需要 diagnostics/export redaction policy）
- native/manager state、protection/inventory hash
- timestamps、counts、known/verified bytes、error code/message

禁止保存 conversation body、prompt/response content、credentials、auth tokens、明文 confirmation token，或 agent system 私有資料庫的 raw rows。

## Migration contract

1. 在 caller 指定的 dedicated manager path 開啟 database。
2. 驗證 `user_version` 與 versioned database 的 `application_id`。
3. 既有 database 只要需要 migration，先用 SQLite Online Backup API 產生 sibling backup。
4. Backup 設為 `0600` 並正規化成單一 DELETE-journal SQLite file。
5. 以 `BEGIN IMMEDIATE` 執行完整 migration chain；schema、`application_id` 與 `user_version` 在同一 transaction 內提交。
6. 任一步失敗即 `ROLLBACK`，不接受部分 schema。
7. Migration 完成後執行 `PRAGMA integrity_check`，live store 再切到 WAL。
8. Migration backup 不自動刪除；operation-report retention 不適用於 backup。唯讀 maintenance assessment 只會列出候選，沒有自動 pruning 或 executor。

Migration chain目前是v0→v1→v2→v3→v4→v5→v6→v7→v8。v6→v7只新增空的`deleted_sessions` table與時間索引，不從舊missing rows猜測Deleted；v7→v8以transaction重建該table，保留所有既有tombstone並將`delete_report_id`從UNIQUE改為indexed non-unique grouping key。每次migration前先備份；任一步失敗時原版本schema/data保持不變，且backup可還原。

## Restore contract

`restoreBackup(from:to:)` 是 Core API，尚無 UI：

1. caller 必須先關閉 destination 的 `SQLiteStateStore`。
2. 驗證 source integrity、schema version 與 `application_id`。
3. 若 destination 已存在，先建立 `pre-restore` safety backup。
4. 使用 SQLite Online Backup API restore，不用不完整的 main-file copy。
5. 驗證 restored destination integrity，並維持 `0600`。

因此 restore 本身仍可用 `pre-restore` backup 回復。未來 UI 必須明確顯示兩個檔案、版本與驗證結果。

## Typed repository contract

Core 已提供 typed checkpoint、Trash membership、Preview 與 Report records：

- Checkpoint timestamp 不可倒退；同一 timestamp 若內容不同也 fail closed，避免 inventory history 分叉。
- Trash membership 與 provider checkpoint 在同一 transaction 保存；checkpoint 必須是 complete，且 inventory hash 必須相同。
- 重複保存既有 Trash membership 只更新 `last_reconciled_at`，不覆蓋最初進入 Trash 的 title、path、state、hash 或 timestamp evidence。
- Preview header 與所有 frozen items 在同一 transaction insert。Archived → Trash會增加待刪意圖，仍要求complete inventory + protection checkpoint；Trash → Archive只取消待刪意圖，因此只要求complete inventory。Allow-listed native Archive與Permanent Delete要求complete inventory，並由各自factory/executor套用operation-specific protection（positive protection與pinned／pinned-descendant unknown阻擋，running/current unknown可保留為Busy／rejection risk）。
- Archive affected-set Preview 必須有且只有一個 depth 0 selected root；每個 descendant 都必須指向已存在的 parent、depth 大於 0，且全部 item 重新計算出的 canonical hash 必須精確匹配 header `affected_set_hash`。任何缺項、重複、斷裂 parent 或 hash tampering 都在 transaction 前 fail closed。
- Repository API 只接受 `confirmationTokenHash`，沒有明文 token parameter 或 column。
- `confirmationTokenHash` 是 internal Preview/claim credential，不等於 UI typed-confirmation policy。可逆 lifecycle 在使用者按下 Confirm 後由 model 傳入 internal credential；不可逆 Delete／History clear 才將 token 顯示並要求 exact input。
- Report item set 必須與 frozen Preview 完全相同；report insert、逐筆 readback evidence 與 Preview `consumed` 狀態在同一 transaction 提交。
- 不完整 item set、重複 manager key、provider/hash mismatch、負數 bytes 或 state 不合法時不留下部分寫入。

### Archive batch authorization and finalization

- Batch plan 只能引用已持久化、同一 Codex provider/checkpoint/token 的 prepared Archive affected-set Previews；root、items、hashes 與 canonical manifest 必須逐筆精確相符。
- Save plan、units、items 是單一 transaction；ordinal、identity 或 reference 不完整時不留下任何 batch row。
- Claim 會再次驗證 expiry、token、checkpoint、manifest 與所有 member Previews，並原子把 plan + members 改成 `executing`；錯誤 token、漂移或 replay 不改任何狀態。
- Member Preview 存在 unresolved prepared/executing batch 時，single-item claim/report API fail closed。
- Final report 必須覆蓋 exact unit/item sets，維持 deterministic terminal prefix；只有 `success`／`failure`／`unknown` 是 attempted，剩餘項目必須是沒有 evidence 的 `notAttempted`。
- Batch report、unit/item disposition/evidence、plan consume 與所有 member Preview consume 在同一 transaction。零 attempted 的全批 preflight rejection可直接從 prepared finalization；任何 native attempt 後則必須先成功 claim。
- 這些 tables 是 durable authorization/audit evidence；目前尚未接 provider executor、operation-history query/export/retention 或 SwiftUI。

### Operation history retention

- `OperationHistoryRetentionPolicy.production` 預設每個 provider 保留最新 500 個 Report。
- 排序使用 `completed_at DESC, id DESC`；ID 是相同完成時間的 deterministic tie-breaker。
- 每次 `saveOperationReport` 都在同一 `BEGIN IMMEDIATE` transaction 內完成 Report insert、Items readback、Preview consume 與超額 pruning，因此 commit 後不會暫時超過上限。
- 顯式 `pruneOperationHistory(for:)` 可整理既有 database，使用相同 transaction contract。
- Pruning 單位是完整 bundle：先刪對應 `operation_items`，再刪 `operation_reports`，最後只刪 `status=consumed` 的 `operation_previews`。任一 row count 或狀態不符就整批 rollback。
- Provider checkpoint、Trash membership、沒有 Report 的 prepared/executing/expired/cancelled Preview，以及其他 provider 的 history 都不在刪除範圍。
- API 回傳 deleted Report IDs、Preview IDs、Item count 與 retained count，供未來 diagnostics/readback 使用。
- 這是 logical row retention；不自動執行 `VACUUM` 或刪 migration/pre-restore backups。物理 compaction 與 backup retention 需要另一份明確 policy 和使用者授權。

Diagnostic Logs不新增SQLite table或schema migration。它們位於同一bundle-ID Application Support目錄中的獨立`diagnostic-events.jsonl`，採30天／10,000筆／20 MiB retention；因此log corruption、pruning或export不參與checkpoint、Trash、Preview、Report、Deleted tombstone或migration transaction。

### SQLite maintenance assessment

`SQLiteStateStore.maintenanceAssessment` 是 Core-only、唯讀 proposal，不會 checkpoint WAL、刪檔、移動檔案或執行 `VACUUM`。

Backup retention policy：

- 只辨識 database sibling directory 中，符合 app 自己完整命名格式的 migration／pre-restore regular file；symlink、directory、相近檔名與其他檔案忽略。
- 每份辨識到的 backup 都以 read-only SQLite connection 驗證 integrity、支援的 schema version 與 versioned database 的 `application_id`；migration 檔名宣告的 source version 必須與檔案內容一致。
- Production policy 對 migration 與 pre-restore **各自至少保留最新 3 份 verified、0600 backup**；其餘 verified、0600 backup 也必須年滿 30 天才列為 Trash candidate。
- unreadable、integrity failure、version mismatch、unsupported version、application-ID mismatch、非 0600、近期或 future-dated backup 全部 protected，不會成為 candidate。
- 一次 assessment 最多接受 100 個 candidates；超過即整份 assessment fail closed，不截斷後繼續。
- Candidate 是 read-only evidence，不是刪除授權。未來 executor 必須凍結精確 URL/identity、再次 readback、取得明確確認，並以 macOS Trash 做可回復移除。
- Core 會為每份 backup 回傳 typed disposition/reason；SwiftUI Maintenance sheet 直接顯示這份 evidence，不在 UI 重算 policy。Sheet 只在既有 Live manager store 可用時讀取，且沒有任何 mutation control。

Physical compaction policy：

- 只讀 `page_size`、`page_count` 與 `freelist_count`；estimate 為 free-list pages × page size，不宣稱等於 Finder 可立即釋出的精確 bytes。
- Production threshold 必須同時達到估計可回收 16 MiB 與 database logical pages 的 20%，才標記 `eligible_for_explicit_preview`。
- Proposal 固定描述未來的 `vacuum_into_verified_replacement` strategy；不得在開啟中的 store 原地自動 `VACUUM`。
- 未來 execution 必須先關閉 store、建立 pre-compaction backup、產生獨立 replacement、驗證 integrity/schema/application ID、再走可回復的 replacement 與 readback。Assessment 的 `executionAuthorized` 永遠是 false。

### Operation history query and export

- `operationHistory(_:)` 是 manager SQLite 的唯讀 query，不呼叫 provider，也不修改 lifecycle state。
- 可組合篩選 provider、operation、outcome、inclusive `completedFrom...completedThrough`，以及 report ID、preview ID、native session ID、manager key、title、project ID、結構化 error code 的 escaped case-insensitive contains search；limit 必須為 1...500。
- 排序固定為 `completed_at DESC, id DESC`，下一頁使用同一組欄位的 keyset cursor，不使用會因新 Report 插入而漂移的 offset。
- Query 會把 `operation_reports` 與已消耗的 `operation_items` identity/readback evidence 組回 typed entry，並驗證 item/outcome/verified-bytes summary；不一致時 fail closed。
- Export model 不會讀取或包含 `confirmation_token_hash`、`manifest_hash`、`provider_inventory_hash`、`expected_protection_hash`，也不包含 conversation content。
- JSON／CSV private default 保留完整 native session ID 與結構化稽核欄位，但省略 title、project ID 與自由文字 error message。Operation history schema 本身沒有 working directory 欄位。
- CSV 固定一個 item 一列、重複 report summary，所有 cell 都 quoting，可能觸發 spreadsheet formula 的開頭字元會 neutralize。
- SwiftUI Report History sheet 每頁載入 50 份，Load More 沿 cursor 追加；export 則讀完全部符合條件的 retained reports，交給 macOS save panel 選擇實際路徑。獨立test-only Fixture target使用bounded in-memory ledger驗證相同query/export contract；其資料不屬於 SQLite schema，也沒有 serialization。
- Clear Filtered Reports 先將目前 filter 的完整 Report IDs 凍結並要求 typed confirmation；Live 限定單一 provider，在一個 transaction 中精確刪除對應 Report、result items 與 consumed Preview。任一 ID/item count 漂移會 rollback，commit 後逐 ID readback；checkpoint、Trash membership、prepared/executing Preview與其他 Report均保留。

Repository 由 Live read-only snapshot coordinator 使用；SwiftUI 不直接執行 SQL。

## Read-only reconciliation contract

`SessionStateReconciler` 是純 Core function，不讀寫 SQLite，也不呼叫 provider：

- Provider inventory 不得自行宣告 manager Trash；Trash intent 只來自 SQLite membership。
- native archived + membership → Trash。
- native active + membership → external-restore conflict，禁止 lifecycle Preview。
- complete inventory 未觀察到 membership session → externally missing。
- incomplete inventory 未觀察到 membership session → unavailable，絕不推定 deleted。
- inventory/protection 不完整、conflict、unavailable 或 protection block 時，`isStableForLifecyclePreview=false`。
- duplicate manager key、provider mismatch 或損壞 membership identity 立即 fail closed。

## Snapshot coordinator contract

`SessionSnapshotCoordinator` 已封裝一次完整 read-only refresh：

1. 呼叫 provider `sessions()`；失敗時不寫 SQLite。
2. 在同一 provider actor refresh 後讀取 typed diagnostics。
3. 使用排序後的 provider sessions、exact Archive scope parent/native-state nodes 與 graph completeness 產生 SHA-256 inventory hash；manager `isTrashMember` 不參與 native hash。只改變 descendant identity 或 native state 也一定改變 checkpoint hash。
4. 讀取 frozen SQLite Trash membership set並呼叫純 reconciler。
5. `inventoryComplete=false` 時只回傳 in-memory diagnostics/result，不覆蓋上次 authoritative checkpoint，也不更新 membership reconciliation time。
6. 完整 snapshot 的 checkpoint、timestamp 與整組 Trash membership `last_reconciled_at` 在同一 transaction 提交。
7. Membership set 在 reconcile 與 commit 之間漂移、checkpoint 時間倒退、同 timestamp 不同 hash 時，整批 fail closed。
8. `protectionComplete=false` 不妨礙保存完整 inventory checkpoint。Archived → Trash仍ineligible；Trash → Archive可建立並claim Preview，因為它只取消Manager Trash意圖。Allow-listed native Archive與Permanent Delete只有在逐項pinned／pinned-descendant evidence已知且所有positive protection為false時，才能建立/claim Preview。running/current unknown不會被改寫成clear，而是保留在frozen protection hash並進入one-shot Busy／rejection-risk contract。

`connectionState=degraded` 不等於 inventory incomplete；Project catalog 或 descendant graph degraded 與 session-list pagination completeness 是不同維度。因此 authoritative policy 只讀 typed `inventoryComplete`，不解析 diagnostics message 字串。

## Tested guarantees

- 新 database 建立 v4 schema、application ID 與 private permissions。
- 既有 v0/v1/v2/v3 database 在 migration 前產生可獨立讀取的 backup。
- 注入中途 SQL failure 時，整個 migration rollback，既有 row 保留、部分 table 不存在。
- Restore 前先建立 safety backup，並能精確回到 migration 前 schema/data。
- v1 Preview 經 v2/v3/v4 migration 後仍可讀；v2→v3 與 v3→v4 backup/rollback、manager-intent backfill/round trip、affected-set round trip、canonical hash tampering、斷裂 parent 與 transaction rollback 都有 tests。
- Batch plan/report round trip、manifest tampering、persisted Preview reference drift、wrong-token/replay claim、single-item bypass 與 incomplete finalization rollback 都有 tests。
- Provider-scoped retention 只保留最新 N 個完整 operation bundles；自動 pruning、顯式 idempotent pruning、非目標資料保護與中途錯誤 rollback 都有 tests。
- History query 的 filters、同時間 ID tie-break、跨頁無重複／遺漏、invalid bounds，以及 JSON／CSV privacy/escaping 都有 tests。
- Backup assessment 的精確檔名／symlink boundary、數量與年齡門檻、candidate hard cap、損壞與 mislabeled backup 保護，以及 assessment 前後檔案完全不變都有 tests。
- Compaction assessment 的 page/freelist 計算、threshold recommendation 與前後 statistics 不變都有 tests。

## App integration

- Production path 透過 `FileManager` 解析 user Application Support，再加上穩定 bundle-ID directory：`com.sean.AgentSessionManager/state.sqlite`。
- 未 sandbox 的目前 build 對應 `~/Library/Application Support/com.sean.AgentSessionManager/state.sqlite`；未來 sandbox build 會自然解析到 container 的 Application Support。
- Test-only Fixture target不bootstrap store。
- Shipping App的Codex Live bootstrap或reconciliation失敗時fail closed，不fallback到未同步raw inventory或Fixture。
- UI 使用 `SessionPresentation`，不把 active+Trash conflict 壓成 Active，也不把 membership-only missing row 宣告成 Deleted。
- Sidebar 顯示 checkpoint advanced / unchanged / not advanced；Inspector 顯示 SQLite path、inventory/protection coverage 與 reconciliation explanation。

## Not implemented yet

- Reapply Trash Intent 與 Externally Missing conflict resolution Apply
- corruption recovery UI
- backup candidate 的 frozen Preview／readback／macOS Trash executor 與 restore UX
- explicitly authorized physical SQLite compaction executor（pre-backup、verified replacement、rollback/readback）

不得因 schema 已存在就繞過現有 live lifecycle evidence gate。

單筆authorization coordinator先保存prepared Preview，再於SQLite transaction claim為`executing`。一般checkbox native batch則保存一份multi-item Preview並一次claim，全批preflight後逐筆執行；同一份itemized Report原子套用成功membership/tombstone effects並consume Preview。若App中斷，batch recovery只讀官方inventory（Delete另讀exact ID）而不重送。Schema v3另支援完整Archive root＋descendant affected-set結構與batch authorization/finalization；這個descendant batch尚未接provider executor，和已完成的zero-descendant checkbox batch不同。

Single-item manager Archive → Active Restore重用相同 Preview／claim／Report／consume schema與 manifest hasher，但 `operation=restore`、frozen native state為 Archived，且 claim不要求 destructive protection checkpoint。它沒有 Trash membership mutation，所以 success Report可直接 consume Preview。Interrupted execution沿用同一 readback-only reconciler，以 Active證明 success、仍 Archived記為 unknown，且不重送 lifecycle request。

SQLite v5 已表達 Active → Trash `.add` 與 Trash → Active `.remove` frozen membership intent；v6 另保存 frozen working directory，讓成功 `.add` 建立的 membership 帶有原始位置證據。新版 manifest綁定非空新欄位。Native success後membership effect／Report／Preview consume同transaction；failure/unknown保留原membership。Crash recovery沿用executing Preview完成相同本機finalization，不能重送provider request。
