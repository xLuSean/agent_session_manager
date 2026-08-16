# Safety Model

## Safety objective

任何 session lifecycle mutation 都必須是精確、可預覽、可確認、可驗證且可稽核的。系統在資訊不足、狀態漂移或 provider 行為不確定時，選擇不動。

Confirmation 依可逆性分級。Archive、Restore、Move to Trash、Move to Archive 仍必須先凍結 exact Preview、由使用者按下明確 Confirm、防重入執行並逐筆 readback，但不要求 typed token。底層 one-time credential 只用於綁定 Preview/claim。Permanent Delete、Report History clear 與未來同等不可逆 action 才要求使用者輸入 exact token。

## Invariants

1. **Pinned 永不 retire/delete**：pinned session 或含 pinned descendant 的 parent 不可 Archive、Trash、Delete。
2. **Current / running 不 retire/delete**：正在執行或承載目前操作的 session 不可 Archive、Trash 或 Delete；Restore 是可逆的 Archived → Active，仍須 exact state/readback，但不使用破壞性操作的 clearance gate。
3. **Delete only from Trash**：只有 manager Trash Bin member 可進入永久刪除 Preview。
4. **Archive is retention**：Archive item 不因時間或空間政策自動成為 delete candidate。
5. **Exact identity**：所有 selection、Preview、Report 顯示完整 provider 與 native session ID；title 只供辨識，不是唯一鍵。
6. **Frozen manifest**：確認對象是 Preview 時凍結的 item list，不是在 Execute 時重新跑 title/project/time query。
7. **Fail closed on drift**：任一 item 的 state/protection 與 Preview 不同，batch 停止並要求新 Preview。

Provider inventory hash 仍用來綁定 durable Preview、manifest 與 claim-time checkpoint，但 native
single-item preflight 不要求「整個 provider inventory」逐 byte 相同。該 hash 包含其他 sessions 與
title／updatedAt 等顯示資料，將它直接當 mutation gate 會讓無關活動造成 false drift。送出 lifecycle
request 前必須精確重驗 selected native ID、expected native state、protection evidence 與 descendant
scope；這些 frozen item evidence 任一漂移仍 fail closed。
8. **Official lifecycle interface only**：不得直接改 JSONL、SQLite、cache 或 rollout file。
9. **Readback defines success**：API call 回傳成功不等於操作完成；必須重新觀察 target state。
10. **Provider isolation**：一個 batch 不跨 agent system，避免不同 lifecycle semantics 混在同一 confirmation。
11. **No silent batch shrinking**：所有 lifecycle operation 都可接受使用者以 row checkbox 建立的 multi-selection，但任一 item 不合格時整批不執行；不得自動移除 blocked item 後繼續。只有 Trash Bin 可以提供 Select All checkbox bar／Empty Trash，且確認前必須把當下選中的完整 manager IDs 凍結，不在執行時重新查詢。

## Threats and mitigations

| Threat | Mitigation |
|---|---|
| 同名 session 選錯 | 完整 session ID、Desktop project、working folder、provider、updated time 一起顯示 |
| Preview 後 session 被 pin | Execute 前重新讀 protection；漂移即整批停止 |
| Archive 被當成 Trash | 用 local Trash membership 表達 intent，不以 native archived 單獨判定 |
| App Server call timeout，結果未知 | 不盲目重送；以 exact ID readback 判定，仍未知則 report `unknown` |
| Parent 變動連帶 descendants | Preview 列 descendants；pinned descendant hard block；readback 整棵受影響範圍 |
| Provider 版本改變 | startup capability probe、contract tests、unsupported fail closed |
| Local state 損壞 | SQLite migration、transaction、backup、reconcile；native runtime 仍是存在性的真相 |
| UI 誤觸永久刪除 | Trash-only、destructive styling、逐批 token、完整 Preview |
| 跨 provider ID 撞號 | namespaced manager key `<provider>:<nativeID>` |

## Reporting contract

Archive、Trash、Restore 與 Delete 都應產生相同結構的 report：

- operation / provider / timestamp / preview ID / batch ID
- total count
- success count
- failure count
- known bytes affected
- verified bytes released
- unknown-size count
- itemized: ID、title、project、working folder、before、target、observed、result、error

Archive / Move to Trash 通常只改 lifecycle state，應回報 `0 B released`，不能把 rollout file 原始大小誤稱為已清出的空間。永久刪除的 released bytes 也只能在刪除前後測量方式可靠且 provider 支援時回報；否則標示 unknown。

Manager-owned operation history 預設每個 provider 保留最新 500 份。Pruning 必須把 Report、對應 consumed Preview 與 Items 視為一個 bundle，在同一 transaction 刪除並回報完整 ID；不得碰 checkpoint、Trash membership、未完成 Preview 或其他 provider。Logical pruning 不自動執行 `VACUUM`，避免一般 report commit 觸發長時間整庫重寫。

Diagnostic Logs與Report History分離。Logs只協助診斷App launch、inventory、Preview、execution、recovery與storage，不能用來宣告lifecycle成功；成功仍由durable Report與fresh native readback證明。`diagnostic-events.jsonl`固定0600，依30天／10,000筆／20 MiB三重上限prune，且禁止metadata key包含token、payload、conversation、prompt、body或content。不得把conversation內容、confirmation token、request payload或message body寫入message來繞過denylist。

使用者主動清除 history 時也使用相同 bundle boundary，但目標必須是 filter 查詢後凍結的精確 Report ID set，並要求一次性 confirmation token。確認後如果任一 ID 消失、新增或 bundle item count 漂移，整批 fail closed；成功後逐 ID 讀回 absent。這不等於清空 Trash，也不修改 provider checkpoint 或 Codex session。

Manager-owned SQLite maintenance 目前也只有唯讀 proposal。Backup candidate 必須是 exact sibling filename、regular non-symlink、permissions 0600、integrity/schema/application-ID verified，且 migration filename version 與內容一致；production 每類至少保留最新 3 份，額外 backup 滿 30 天才可列候選，超過 100 個候選整份 fail closed。損壞、無法驗證、非 0600、近期與 future-dated backup 永遠 protected。Maintenance sheet 只呈現 Core typed evidence，沒有 action controls。Assessment 不刪 backup；未來只能在另一個明確確認流程中把凍結的 exact files 移到 macOS Trash。

Physical compaction 只讀 page/freelist statistics。預設必須同時估計可回收至少 16 MiB 與 20% logical pages 才建議建立 explicit Preview；不得在一般 open/report/refresh 流程原地 `VACUUM`。未來 executor 必須先關閉 store、建立可回復 backup、建立與驗證獨立 replacement，再 replacement/readback；目前 assessment 永遠不授權 execution。

History export 的 private default 只保留稽核所需的完整 native session ID、enum state、counts、bytes、timestamp 與結構化 error code。Session title、project ID、report/item 自由文字 error 預設不輸出；working directory 不存在於 operation history tables。Confirmation-token hash、manifest hash、provider inventory hash 與 protection hash 永遠不屬於 export model。CSV 所有欄位都做 RFC 4180 quoting，且以 `'` neutralize 可能被 spreadsheet 當成公式的開頭字元。較敏感文字只能由 caller 明確建立非預設 policy 才能加入，目前沒有 UI 暴露此選項。

## Current guarantees

Test-only Fixture harness（不連結進 shipping App）：

- 不讀 `~/.codex`。
- 不連 App Server。
- 不執行 shell deletion。
- 所有 mutation 只存在 test process 記憶體，重新啟動即回到 fixture。
- Report note 明確標示沒有變更真實 agent session。
- 多次 operation history 只存在 bounded in-memory ledger；test process退出即清空，不建立／寫入 production SQLite。Ledger 不保存 working directory、confirmation token、hashes 或 conversation content，且不宣稱 released bytes complete。

Shipping App（Codex Live-only）：

- 只啟動官方 `codex app-server`。Read-only provider allowlist只有`initialize`、`initialized`、`config/read`、`thread/list`與明確readback使用的`thread/read`；獨立native Archive／Restore／Delete facade才能在各自persisted confirmation claim後多呼叫一次`thread/archive`／`thread/unarchive`／`thread/delete`，底層mutation transport不對App公開。
- `thread/list` 固定使用 `useStateDbOnly=true`，避免預設 scan-and-repair。
- 只列穩定 interactive sources，active / archived 分別沿 opaque cursor 讀到結束；每個 collection 有 10,000 筆 hard safety cap，重複 cursor 或截斷時顯示 degraded。
- 不讀 rollout path 的內容或大小，不保存 conversation body。
- read-only provider的archive / unarchive / delete execution capabilities仍全部為false；App只能透過operation-specific受限facade執行已稽核runtime的單筆或exact-selection batch lifecycle request。Manager-only coordinator只增刪本機Trash membership，沒有provider transport。
- `SessionCapabilities` 分開表示 native interface 是否已由特定 runtime contract 驗證，以及 manager executor 是否可用；前者成立不會自動打開後者。
- Live Archive toolbar action 先開啟 type-safe readiness review；逐項顯示 exact selection、runtime/checkpoint、readback、writer authority、protection、descendant 與 executor verdict。全部通過時才能建立 persisted Preview，再由獨立 sheet 要求使用者 review 並按下 explicit Confirm；Archive 不要求 typed token，readiness 畫面本身不送 lifecycle request。
- `ArchiveAuthorizationCoordinator`、`ArchiveMutationExecutor`、mutation transport 與 `ArchiveExecutionRecoveryReconciler` 都是 Core internal；App 只能建構受限的 `CodexNativeArchiveCoordinator` 與 readback-only recovery facade。Coordinator 強制 Preview 先落盤並 claim 為不可 replay 的 `executing`；executor 只允許單筆、零 descendant、allow-listed runtime，request 最多一次；RPC acknowledgement 不算 success，readback 必須較新、完整、相同 runtime 與完整 native ID。Stale、timeout、missing 或 still-active acknowledgement 一律 unknown。Report 原子落盤後 consume Preview；若寫入失敗則保留 unresolved `executing`。下一次 Live refresh 先保留 claim checkpoint並取得完整 snapshot，recovery facade 驗證原 checkpoint/manifest 後只補寫 success/unknown Report；它型別上沒有 `archive()`，不能重送。證據不足保留 executing 供下次 readback；成功 consume 後才由第二次 normal refresh advance checkpoint。多筆 executing 記錄不會被自動挑選或縮小。
- Native Restore 使用分離的 internal transport/executor與 public `CodexNativeRestoreCoordinator`。它接受單一 stable manager Archive 或 Trash、凍結 exact Archived identity/runtime/inventory/manifest/token；Trash 另凍結完整 membership set 與 durable `.remove` intent。最多送一次 `thread/unarchive`；只有較新的 Active readback是 success。成功時 membership removal、Report與 Preview consume同 transaction；failure/unknown保留 membership。Interrupted recovery只有 inventory capability，不能重送 Restore，但能依原 intent完成相同 finalization。Restore不要求 Archive-only protection clearance。
- Active → Trash 使用 native Archive facade 與 durable `.add` intent。只有 fresh Archived readback success 才在 Report transaction加入 membership；Busy/failure/unknown都不建立 Trash。Crash recovery只讀、不重送 Archive，且仍遵守同一條 success-only finalization。
- Permanent Delete只接受Manager Trash；Archive不得直接Delete。它要求pin與pinned-descendant evidence已知且clear、零descendant，任何positive pinned/running/current/pinned-descendant都阻擋。跨host running/current negative evidence未知時保留為`attemptMayFail`，不偽裝成clear，但可最多送一次official `thread/delete`。只有fresh complete inventory省略exact ID，且同runtime exact read同時回傳audited `-32600 / thread not loaded: <id>`才算success。Success時Trash removal、Deleted tombstone、Report與Preview consume同transaction；failure/unknown保留Trash。Recovery只有readback能力，不重送Delete；released bytes不估算。
- Archive → Trash 與 Trash → Archive 必須先 durable frozen Preview；確認時 fresh official inventory 必須完整，checkpoint、manifest、selection membership 或 protection 任一漂移就整批 fail closed。SQLite membership、itemized Report、Preview consumption 必須同 transaction，commit 後逐項 readback。這條路徑沒有 provider transport。
- 其他 UI lifecycle action 依selection、transition與capability禁用；core provider仍固定拒絕直接live lifecycle mutation。
- Active + Manager Trash conflict 可 Apply Accept Native Restore：fresh complete inventory 仍須精確顯示 Active，且 durable Preview 的 runtime、inventory hash、manifest、完整 Trash membership set 與 token 全部相符；transaction 只移除 manager membership並原子寫 Report／consume Preview，Coordinator 沒有 provider transport。Reapply Trash Intent 與 Externally Missing resolution 仍只有 read-only proposal。
- Complete list inventory 未觀察到 session 只代表 Externally Missing；沒有官方 exact-ID absence readback 時不得宣告 Deleted。
- `thread/read` 成功、response ID 完全相符且 evidence kind 為 exact match 才能證明 Present。Failure 保存 typed kind 與 RPC code，但不解析自由文字來判斷 absence。即使 status 被設成 Absent，沒有官方來源、精確 runtime version、RPC code 全部相符的 `ExactSessionAbsenceContract`，`provesAbsence` 仍是 false。官方未定義穩定 not-found code 前，missing-ID RPC error、timeout、transport error 與 decode error全部是 Unavailable。
- pin、current、pinned descendant 無法確認時明確標記 unavailable，不推定為 false。Running 只接受 `status.active` 的正向證據；非 active 不推定為未執行。Inspector 的每個欄位都顯示 Protected／Verified clear／Unavailable、來源與理由；只有 Verified clear 才是 mutation clearance evidence。
- Descendant count 只在 all-source active / archived inventory 都完整時標記 verified；截斷或錯誤時 fail closed。
- Project、Working Folder、Trust Folder 使用不同來源；Project 只能由 Desktop `local-projects` root 配對，Git origin 或 trust entry 不得冒充 Project。

## Conditions before enabling live mutation

- Readiness report 的所有項目都必須允許 attempt：positive protection、pinned unknown、pinned-descendant unknown 或一般 unavailable 一律 fail closed；只有 allow-listed Archive contract 的 writer/running/current unknown 可維持明示的 `attemptMayFail`。
- Writer clearance 若宣稱 Verified clear，必須來自 exact-ID、runtime/inventory-hash/checkpoint-bound 的官方 lifecycle-host／all-relevant-hosts authority；獨立 stdio App Server 的 idle/notLoaded/readback 不足以解鎖。缺少 clearance 只能走一次 Busy-risk request，不能顯示為 clear。
- Codex read-only inventory 能穩定取得 active / archived / pinned / running / current / descendant state。
- 完成 protocol capture 與版本 compatibility matrix。
- Reconciliation 與 persistence 有 migration/backup tests。
- App Server archive / unarchive / delete 均有 success、failure、timeout-unknown、partial-result tests。
- Preview expiry/hash 與 drift detection 完成。
- Prepared Preview 先落盤、executor 結果再以 exact frozen item set 原子提交 Report／consume Preview 的 coordinator，以及 readback-only unresolved `executing` reconciliation 都已完成並接入 production refresh；可見 live acceptance 仍待 runtime pin contract。
- Test-only isolated Archive harness 使用獨立 mutation opt-in、完整 UUID／title／cwd／confirmation 與 sacrificial naming gate；一般 live smoke 不會觸發。2026-08-13 已得到一次 verified rejection + Active readback；success path 尚未完成 live acceptance。
- Current task 可被可靠排除。
- 逐筆 readback 與 statistical report 完成。
- 使用真實但可犧牲的 isolated fixture sessions 做人工驗收。
