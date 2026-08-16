# Agent Session Manager

Agent Session Manager 是一個 macOS 原生 POC，用一致的 UI 管理不同 agent system 的 session lifecycle，並在產品層明確分開：

- **Archive**：使用者刻意保留、暫時不顯示在 Active 的 session。
- **Trash Bin**：準備淘汰、等待永久刪除的 session。
- **Deleted**：經過 Preview、確認、執行與 readback 驗證後，原生 provider 已回報不存在的 session。

正式 App（Xcode Debug、Release 與 DMG）啟動後直接進入 **Codex Live**，不再提供 Fixture product mode 或資料來源切換 UI。Fixture implementation 已拆到獨立的 `AgentSessionManagerFixtures` Swift target，只供 deterministic tests 與內部 test harness 使用；shipping App target 不連結也無法到達它。Live inventory 由 read-only provider 透過官方 App Server `initialize`、paginated `thread/list` 與 `config/read` 取得；Project 則只讀 Codex Desktop `.codex-global-state.json` 的 `local-projects` 目錄。Native Active → Archive／Trash、manager Archive／Trash → Active，以及 Trash → Deleted 都支援 checkbox exact-selection batch，並走受 frozen Preview／explicit Confirm／internal credential／readback 保護的 official lifecycle path。Permanent Delete 只接受 Manager Trash，Archive 必須先以另一份 Preview 移到 Trash。Delete 每筆最多送一次 `thread/delete`，只有 fresh complete inventory 與 exact-ID readback共同證明 absence 才原子移除 membership並建立 durable Deleted tombstone；failure／unknown後停止batch、保留未成功的Trash intent且不retry。Delete採operation-specific protection：positive pinned/running/current與unknown pin／pinned-descendant阻擋；cross-host running/current unknown保留為`attemptMayFail`而不造成永久禁用。Native state 已是 Archived 的 session，也可透過 frozen Preview在 Archive ↔ Trash 間切換而不重複送 lifecycle request。Codex Desktop `pinned-thread-ids` 以 inventory 前後雙讀一致的方式提供 pin evidence；未知、漂移或雙來源衝突仍 fail closed。Restore 不是破壞性操作，不套用 Archive-only pin/running/descendant gate。

Confirmation UX 依影響分級：Archive、Restore、Move to Trash 與 Move to Archive 都可逆，使用者 review frozen Preview 後只需按下明確 Confirm。Preview 仍有 internal one-time credential 綁定 exact selection，但不顯示或要求使用者輸入。Permanent Delete、Report History clear 與未來同等不可逆 action 才保留 typed confirmation token。

## POC 已包含

- SwiftUI 三欄 UI：library / agent / Desktop project / trust folder / working folder、session table、inspector。
- 顯示完整 session ID，避免同名 session 無法辨識。
- Archive、Trash Bin、Deleted 為不同 manager collection。
- Preview sheet：總數、已知大小、逐筆 ID、前後狀態與警告。可逆操作使用明確 Confirm；不可逆刪除另要求 typed token。
- Report sheet：總數、成功數、失敗數、逐筆最終狀態。
- pinned、running、current、pinned descendant 保護模型，以及逐欄位 Protected／Verified clear／Unavailable evidence。
- confirmation mismatch 與 preview drift 防護。
- provider capability model，為未來支援其他 agent system 預留界面。
- 一般 deterministic core tests、需明確啟用的 live read-only smoke tests，以及使用獨立 mutation opt-in 的 isolated Archive acceptance test。一般與 live read-only test 都不會啟動 acceptance mutation。
- Codex App Server read-only provider、version/runtime diagnostics 與 protocol fixture captures。
- Shipping App 固定使用 Codex Live；Fixture provider 與 ephemeral history ledger 僅存在獨立 test-support target。
- protection unknown state：無法確認時顯示 unavailable，不當成 `false`。
- location metadata 分離：Project 來自完整 Desktop `local-projects` catalog（即使目前 0 個 session 也保留）、Working Folder 來自 `thread.cwd`、Trust Folder 來自 `config/read`。Git origin 不冒充 Project。Trash row 優先保留 frozen project/path evidence；舊資料只有在 working-folder basename 唯一對應目前 Project 時才安全補回顯示。
- Phase 2 SQLite v8 safety slice：manager-owned metadata schema、v0→…→v8 transaction migration、migration 前單檔 backup、integrity check、可逆 Core restore API 與 failure rollback tests；v4保存distinct manager intent，v5保存native success後才可套用的Trash membership `add/remove` intent，v6納入working directory，v7新增verified Deleted tombstone，v8允許同一批次Delete Report對應多筆tombstone。
- Lifecycle operation plan：明確拆開使用者意圖、Codex native lifecycle request 與 manager Trash membership。Active → Trash 需要一次 native Archive；Archive → Trash 與 Trash → Archive 都只改 manager membership，不重複送 native request；Trash → Active 才送 Unarchive，永久刪除只接受 Trash。
- SQLite maintenance proposal：唯讀辨識／驗證 migration 與 pre-restore backups，預設每類至少保留 3 份且滿 30 天才列為 Trash candidate；以 page/freelist statistics 估算 compaction，永不自動刪 backup 或執行 `VACUUM`。
- Read-only Maintenance sheet：只在既有 Codex Live manager store 可用時開啟，逐份顯示 protected/candidate typed reason、完整 backup path、verification/0600 evidence 與 compaction estimate；沒有 mutation controls。
- Typed persistence repositories：checkpoint 不可倒退、Trash intent 只接受完整 inventory、Preview header/items 原子保存、Report 必須精確匹配 frozen item set 後才在同一 transaction consume Preview。
- Bounded operation history：每個 provider 預設只保留最新 500 份完整 Report／consumed Preview／Items bundle；Report commit 與 pruning 在同一 transaction，checkpoint、Trash membership、未完成 Preview 與其他 provider 不受影響。
- Report History：toolbar 以 provider／operation／outcome／完成時間與 report/session/title/project/error code 搜尋，採 deterministic keyset pagination；shipping App 讀 manager SQLite。macOS save panel 可匯出全部符合條件的 JSON／CSV。Export 保留完整 native session ID，預設隱藏 title、project ID 與自由文字 error，且不輸出任何 confirmation、manifest 或 protection hash。Test-only Fixture target 另有 bounded process-local ledger coverage。
- Report History 可清除目前 filter 精確匹配的 frozen Report IDs；必須輸入一次性 confirmation token。Shipping App 在同一 transaction 刪除 Report／items／consumed Preview並逐 ID readback，保留 Trash membership、checkpoint 與所有未完成 Preview。
- `⌘,` Settings 提供 General／Logs 分頁。General 顯示 Report History 每 provider 500 份與 Diagnostic Logs 30 天／10,000 events／20 MB retention；Logs 可依 level/category搜尋、查看bounded metadata、重複Copy單筆事件並匯出全部 retained JSONL。診斷檔獨立位於同一Application Support目錄的`diagnostic-events.jsonl`，使用0600權限並同步寫入macOS Unified Logging；它不是lifecycle outcome authority，也不保存conversation content、confirmation token、prompt、request payload或message body。
- Session table 的 Archive／Trash／Restore／Move to Archive／Delete Permanently 全部展開於 toolbar 並加入右鍵選單；disabled toolbar action 仍可 hover 顯示具體原因。永久刪除與 Report 清除的 token 輸入區使用高對比 action-required panel。
- Sidebar最上方是必選的Agent Systems，不提供All Agents；目前保留`Codex Live`，未來可和Claude並列，Fixture不會因此回到shipping App。啟動時Status預設Active；Agent System可同時搭配Status與一個Project／Trust Folder／Working Folder scope，只有後三種Browse By彼此互斥。各分類筆數由一次inventory scan建立，避免大型session library逐列重掃；Agent Systems收合時仍顯示目前system。每個sidebar item的完整row都是hit target，不留下可見但無法點擊的空白。
- Session table 會保存使用者拖曳後的欄寬。主視窗三欄由 App-owned `NSSplitViewController` 管理，使用固定 autosave identity 保存 Sidebar／Inspector divider 與 Sidebar 收合狀態；Xcode rebuild 不會改變該 identity。Trash 的 Select All bar 固定為緊湊高度，AppKit checkbox 不再把 Table 推到視窗下半部。Sidebar footer 使用不透明 bar 與分隔線，長清單不會和 health/checkpoint 狀態重疊。
- Read-only reconciliation：合併 live inventory 與 SQLite Trash membership，明確區分 Active、Archive、Trash、external restore conflict、externally missing 與 unavailable，並以專用 presentation rows 呈現在 SwiftUI。
- Snapshot coordinator：以正式 `inventoryComplete` / `protectionComplete` 診斷欄位建立 canonical hash；完整 snapshot 才能原子提交 checkpoint 與 frozen Trash membership set，partial/failure/stale snapshot 不覆蓋 authoritative state。
- Production store bootstrap：shipping App 啟動後以 `FileManager` 解析 `Application Support/com.sean.AgentSessionManager/state.sqlite`，並在第一次 live reload 建立 manager-owned store。
- Diagnostic Log storage：App 可將 launch、Refresh、Preview、mutation、readback/recovery與storage events寫入獨立bounded JSONL；若檔案初始化失敗，App仍可啟動並在Settings顯示in-memory fallback與錯誤。
- Conflict resolution Apply：Active + Manager Trash 可選擇 Accept Native Restore；凍結完整 ID、checkpoint hash、runtime、整個 Trash membership set 與 internal Preview credential，確認前 fresh inventory，然後只移除 manager SQLite membership、原子寫入逐筆 Report 並 readback。使用者 review 後直接按下 Confirm；Codex 已經是 Active，不送任何 native lifecycle request。Reapply Trash Intent 與 Externally Missing resolution 仍不可 Apply。
- Test-only Fixture conflict coverage：內部 harness 可用 `[Demo Conflict] Restored outside Session Manager` 驗證 Accept Native Restore flow；這段支援不會連結進 shipping App。
- Exact-ID readback：一般 Conflict Review 透過官方 `thread/read` 且固定 `includeTurns=false`；成功且 evidence kind 為 exact match 才能證明 Present，generic RPC error仍不能單獨宣告 Absent。Permanent Delete 使用更窄的 0.147.0 audited contract：只有同一 runtime 的 fresh complete active+archived inventory省略 exact ID，且 `thread/read` 同時回傳精確 `-32600 / thread not loaded: <id>`，才可證明 Deleted；任一證據不足皆為 unknown。
- Protection evidence：Inspector 固定列出四個保護欄位、三態 verdict、權威來源與 fail-closed 理由；未知的 `false` 絕不顯示成 Verified clear。Pin 由唯讀 Codex Desktop `pinned-thread-ids` 前後一致快照解析，並與完整 descendant graph 合併；缺欄、格式錯誤、membership 漂移或與未來 `thread/list.isPinned` 衝突時維持 unavailable。
- Protection authority scope：Core 把來源 scope 型別化為 manager process、provider persistent state、complete provider graph 或 all relevant hosts。任何可信 `true` 都能立即保護；未知的 `false` 仍不能顯示為 Verified clear。Codex `status.active` 目前只屬 manager process，因此 idle 仍是 unavailable。對 allow-listed Codex Archive，readiness 將這個 unavailable 顯示成「官方 request 可能被 Busy 拒絕」的 attempt risk，而不是偽裝成 writer-free；pinned 與 pinned descendant 仍必須有權威 clear evidence。
- Archive readiness review：第一個 live mutation slice 僅接受一個 active Codex root session，Core type-safe gate 逐項驗證 exact selection、stable reconciliation、完整 checkpoint/runtime binding、官方 Archive/readback interface、四種 protection、零 descendants 與 manager executor。Writer／running／current unknown 使用 `attemptMayFail` verdict；positive protection、pinned unknown 與 pinned-descendant unknown 仍會阻擋。全部通過時 UI 才顯示 Create Preview；readiness 畫面本身不送 request。
- Archive attempt outcome：官方 `thread/archive` 可以成功，也可以因 session 仍有 active writer 而被拒絕。拒絕加上 fresh Active readback 是正常且安全的 failure；unknown 絕不算 success，任何結果都不自動 retry。Shared lifecycle host 只改善事前成功率判斷，不是送出 Archive 的必要條件。
- Native Archive execution pipeline：App 只能建構 public single-root facade，不能取得底層 mutation transport。Facade 先原子保存 prepared Preview，再 claim exact persisted record 為 `executing`，之後才允許 internal executor 以 allow-listed runtime、canonical manifest、完整 preflight、零 descendants、一次 `thread/archive` 與較新的 exact-ID inventory readback 執行；success、failure、unknown 均原子保存 itemized Report 並 consume Preview。SwiftUI 已接 Create Preview、明確 Confirm 與 itemized Report，Archive 不要求 typed token。Crash／Report 寫入失敗會保留不可 replay 的 `executing` record；下一次 Codex Live refresh 會先保留原 checkpoint，再把同一份完整 official snapshot 交給 readback-only recovery facade。它只能補寫 success/unknown Report，絕對無法重送 Archive；完成後才允許第二次 refresh 推進 checkpoint。
- Native Restore execution pipeline：接受單一、穩定的 Archive 或 Trash session。Facade 凍結 exact ID／Archived state／runtime／inventory hash／manifest／token；Trash 另凍結完整 membership set 與 `.remove` intent。Claim 後最多送一次 `thread/unarchive`，只有較新的完整 Active readback算成功；同一 SQLite transaction 才移除 Trash membership、寫 Report並 consume Preview。RPC rejection + Archived readback為 failure；unknown與failure保留 membership且不 retry。中斷 recovery只讀不重送，也能完成同一原子 finalization。
- Descendant-aware affected set：Live all-source graph 現在保留每個 session 的 parent 與 native state；canonical checkpoint hash 綁定完整 graph。純 Core planner 可凍結 root＋所有 descendants，SQLite v2 原子保存 role／parent／depth 與 `affectedSetHash`，並拒絕 graph/state/protection 不完整或雜湊漂移。現有 single-item executor 會明確拒絕這種 Preview；尚未接 UI 或 batch mutation。
- Native checkbox batch：同provider選取集合保存為一份多item frozen Preview並一次claim；全批preflight在第一個request前完成，之後依manager key順序逐筆呼叫官方lifecycle method。第一個failure／unknown後停止，剩餘item以`batch_not_attempted`進入同一份Report；中斷recovery只readback、不重送。Archive ↔ Trash manager-only batch沿用原子SQLite transaction；Codex沒有跨session native transaction，因此先前成功的native item不會假裝可rollback。SQLite v3 descendant-root batch plan仍保留給未來affected-set execution。

## 快速開始

### Xcode App

```bash
open macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj
```

選擇 shared `AgentSessionManager` App scheme 後按 Run。Swift Package 提供
`AgentSessionManagerCore`、獨立的 test-support `AgentSessionManagerFixtures` 與 tests，不再建立同名 command-line executable，避免 Xcode
誤跑沒有 `.app` bundle identifier 的 SwiftPM product。

執行完整的本機驗證（不設定live／mutation opt-in，因此不會送出lifecycle request）：

```bash
./scripts/verify.sh
```

此腳本會依序執行Core tests、正式Xcode App Debug build與獨立App-layer tests、Fixture shipping
boundary source/binary檢查，以及staged／unstaged whitespace檢查。App tests直接編譯同一份
`SessionManagerModel.swift`，但不啟動shipping App、不執行Live reload也不連Codex。成功時只顯示
摘要；失敗時顯示bounded log。

完整驗證也可選擇在每次commit前自動執行；repository不會預設啟用，也不會覆蓋既有的自訂
`core.hooksPath`：

```bash
./scripts/configure_git_hooks.sh enable
./scripts/configure_git_hooks.sh status
./scripts/configure_git_hooks.sh disable
```

啟用後，版本化的`.githooks/pre-commit`會呼叫同一份`./scripts/verify.sh`，失敗時阻止commit但不會
改動staged內容。2026-08-15在目前開發機的實測為全新cache約40秒、已有cache約6–7秒；實際時間會
隨硬體與build cache而變化。這些都是本機腳本化測試，不會呼叫LLM或產生LLM成本。

若只需單獨執行Swift Package tests：

```bash
cd macos/AgentSessionManager
ASM_TEMP_BASE="${TMPDIR:-/tmp}"
CLANG_MODULE_CACHE_PATH="${ASM_TEMP_BASE%/}/agent-session-manager-clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${ASM_TEMP_BASE%/}/agent-session-manager-swiftpm-cache" \
swift test --disable-sandbox
```

Live smoke test 另需設定 `AGENT_SESSION_MANAGER_LIVE_TEST=1`，並讓 App Server 可存取自己的 `~/.codex` state runtime；受限 workspace sandbox 會使該測試 fail closed，而不是退回 fixture 或直接讀內部檔案。

### Xcode app

開啟：

```text
macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj
```

選擇 scheme `AgentSessionManager`、destination `My Mac`，按 Run。

### 本機 DMG

不透過 Xcode 啟動時，可在 repository root 建立本機測試 DMG：

```bash
./scripts/package_dmg.sh
```

產物位於 `dist/`；流程會先驗證 App sources／target linkage 與 Release binary 都無 Fixture implementation，再執行 Release build、ad-hoc signing、DMG verify、唯讀掛載與內容 readback。Xcode Debug 與 DMG 都直接啟動 Codex Live。這是同一台開發 Mac 使用的 local build，尚未做 Developer ID signing 或 Apple notarization；完整 contract 見 [`docs/PACKAGING.md`](docs/PACKAGING.md)。

## 重要安全邊界

下段的single-root facade描述仍適用於精確單選；多選由`CodexNativeBatchCoordinator`接手，同樣只接受zero-descendant items，並在第一個request前完成全批preflight。它不是Codex原生transaction：逐筆最多送一次，non-success後停止，crash recovery只readback。

Live App 使用 read-only Codex inventory、manager SQLite reconciliation，並已開啟 native Archived session 的 manager-only Archive ↔ Trash 分類，以及 Active + Manager Trash conflict 的 Accept Native Restore。這些 manager-only 操作沒有 provider lifecycle transport。Native Active → Archive 則走獨立、只允許單筆的 official App Server facade：必須先保存 frozen Preview、由使用者按下明確 Confirm、claim 後只送一次 `thread/archive`，再以較新的完整 inventory readback 分類 success／failure／unknown，絕不自動 retry。Codex Live 第一次 reload 會 bootstrap store，完整 snapshot 原子 advance checkpoint，partial/failure/stale 不覆蓋 authoritative state；若存在 unresolved `executing` Preview，普通 refresh 也不覆蓋其 claim-time checkpoint。Live inventory 對 Active 與 Archived interactive threads 分別沿 `nextCursor` 讀到 `null`，每頁 50 筆；為防止損壞 cursor 或版本漂移造成無限迴圈，每個 collection 仍有 200 頁／10,000 筆的 hard safety cap，重複 cursor 或達上限時標示 `Degraded`。Project catalog 仿照 Agent Skill Butler，只讀 Desktop `local-projects`，再以最長 project root ancestor 配對 `thread.cwd`；讀取失敗或無匹配時顯示 unavailable，不退回 Git origin 或 trust entry。Descendant count 由第二組同樣有界的 all-source `thread/list` 建立，包含 stable sub-agent source kinds，只有完整讀到最後一頁才標示 Verified。官方最新文件已描述 `thread/list.isPinned`，但本機 `codex-cli 0.147.0` 的生成 `Thread` schema 與實際結果仍未提供它；app 保留版本感知的 optional decode，同時唯讀解析 Codex Desktop `pinned-thread-ids`。Pin 清單在 inventory 前後 membership 必須一致，並與 all-source graph 一起進入 canonical checkpoint hash；任何缺失、格式錯誤、漂移或雙來源衝突都 fail closed。0.147.0 schema 已確認 `thread/archive`、`thread/unarchive` 與 `thread/read`。`status.active` 只能正向證明 manager-owned process 觀察到 running，不能用非 active 狀態排除 Desktop 另一個 process；current task 也沒有跨 host 權威欄位。這些 unknown 不會被冒充成 Verified clear，而是由 allow-listed 官方 Archive request 的 Busy rejection contract 承接。Pinned session 與含 pinned descendant 的 root 仍硬擋；非 pinned root 則不再因缺少 pin data 一律擋在 Preview 前。

未來 Codex integration 必須透過官方 App Server lifecycle API。禁止直接編輯或刪除 `~/.codex/sessions` JSONL、SQLite、cache 或其他內部檔案。

## Security

請勿透過公開 Issue 回報安全漏洞，也不要附上未遮罩的 session ID、專案名稱、本機路徑、SQLite、
JSONL 或 diagnostic logs。回報方式、支援範圍與安全揭露邊界見 [`SECURITY.md`](SECURITY.md)。

## License

本專案依 [Apache License 2.0](LICENSE) 授權，允許個人與商業使用、修改及散布；重新散布與衍生作品
必須遵守授權中的 attribution、NOTICE 與 modified-file notice 要求。原始作者資訊見
[`NOTICE`](NOTICE)。

## 文件索引

- [架構](docs/ARCHITECTURE.md)
- [安全模型](docs/SAFETY.md)
- [UI 規格](docs/UI_SPEC.md)
- [Roadmap](docs/ROADMAP.md)
- [DMG 打包與公開發佈門檻](docs/PACKAGING.md)
- [TODO](docs/TODO.md)
- [新 thread 交接](docs/HANDOFF.md)
- [App Server compatibility](docs/APP_SERVER_COMPATIBILITY.md)
- [Isolated Archive acceptance](docs/ARCHIVE_ACCEPTANCE.md)
- [Permanent Delete acceptance evidence](docs/DELETE_ACCEPTANCE.md)
- [Safety-state audit](docs/SAFETY_STATE_AUDIT.md)
- [SQLite state store v8](docs/SQLITE_SCHEMA.md)

## 專案狀態

Phase 0 fixture POC已完成；Phase 1 read-only inventory **進行中**；Phase 2已把SQLite v8、typed repositories、manager intent／membership history、Deleted tombstone、Maintenance、Report History、reconciler與Live refresh接入app。Phase 3已接上單筆與checkbox batch的Archive／Restore／Active ↔ Trash／Trash → Deleted；都有persisted exact-selection Preview、明確 Confirm、全批preflight、deterministic stop-on-non-success、逐筆Report與readback-only recovery。Archive不能直接刪除；Permanent Delete只接受Trash且每筆要求雙absence readback，既有single／batch人工驗收與SQLite evidence已記錄於`docs/DELETE_ACCEPTANCE.md`。Production data-source build boundary已完成：shipping Release直接進Codex Live、無Fixture切換UI，且source／target linkage／Release binary verifier都會阻止Fixture進入App。下一步重新打包並驗證DMG；之後接續Archive可見live acceptance、Report History批次呈現微調與下一版runtime稽核。既有`codex-retire-sessions` skill在app達到完整安全parity前仍是正式fallback。
