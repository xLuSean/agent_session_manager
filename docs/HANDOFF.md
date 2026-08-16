# Handoff for the next Codex thread

## Current result

這個 repository 已完成 Agent Session Manager 的 Phase 0 macOS POC、Phase 1 paginated read-only inventory，並把Phase 2 SQLite v8、typed repositories、distinct manager-intent history、durable membership add/remove intent與working-directory evidence、Deleted tombstone、bounded history、Report History/search/export、reconciler與snapshot coordinator接到Live app。Phase 3已支援Active → Archive／Trash、manager Archive／Trash → Active、Manager Trash → Deleted的單筆與checkbox batch。Delete使用one-shot-per-item official `thread/delete`、雙absence readback、v8 tombstone與readback-only recovery；Archive仍不可直接刪除。

Shipping App（Xcode Debug、Release與DMG）固定從 **Codex Live** 啟動，不再提供Fixture product mode或Data Source切換。Fixture provider與ephemeral ledger已拆到獨立`AgentSessionManagerFixtures` target，只供deterministic tests／internal harness；Xcode App target不連結。Read-only inventory provider只透過官方App Server列出inventory；operation-specific facade才可在durable claim後送Archive／Restore／Delete。Native batch先全批preflight，再依frozen順序逐筆送出，遇到failure/unknown即停止且不retry。Archive → Trash、Trash → Archive與Accept Native Restore只改manager SQLite。SQLite v8讓membership effect、working-directory evidence、batch Delete tombstones與Report/Preview維持原子transaction。

Confirmation UX 已改為風險分級：Archive、Restore、Move to Trash、Move to Archive 都是可逆操作，必須 review frozen exact-selection Preview 並按下明確 Confirm，但不要求 typed token。底層仍以 internal one-time credential 綁定 Preview/claim。Permanent Delete、Report History clear 與未來同等不可逆 action 才顯示 Copy + exact token input。

`⌘,` Settings現在有General與Logs。Diagnostic Logs使用獨立0600 `diagnostic-events.jsonl`，記錄App launch、Refresh、Preview、execution/readback、recovery、storage與error；三重retention為30天／10,000 events／20 MB。UI支援level/category/search、detail、persistent Copied feedback與JSONL export。Logs不是lifecycle outcome authority，且sensitive metadata denylist與bounded fields有Core tests。

Test-only Fixture harness保留`[Demo Conflict] Restored outside Session Manager` coverage；它不建立production SQLite、不呼叫Codex，也不會出現在shipping UI。

## Start here

1. 讀 `README.md`。
2. 讀 `AGENTS.md` 的 non-negotiable safety rules。
3. 讀 `docs/ARCHITECTURE.md` 與 `docs/SAFETY.md`。
4. 讀 `docs/APP_SERVER_COMPATIBILITY.md`，了解目前本機 schema 與 unavailable protection 欄位。
5. 讀 `LifecycleMutationReadiness.swift`、`CodexNativeArchiveCoordinator.swift`、`ArchiveAuthorizationCoordinator.swift`、`ArchiveMutationExecutor.swift`、`ArchiveExecutionRecoveryReconciler.swift`、`docs/SQLITE_SCHEMA.md`、`docs/APP_SERVER_COMPATIBILITY.md` 與 `docs/ARCHIVE_ACCEPTANCE.md`；已完成一次真實 rejection acceptance，但 success path 尚未驗證，不要繞過 pin/runtime gate。
6. 不要把 manager-only classification 誤當成 Codex lifecycle authority；下一個 native mutation 仍須獨立 safety phase。

## Build and test

完整、非live的固定驗證入口：

```bash
./scripts/verify.sh
```

腳本明確移除`AGENT_SESSION_MANAGER_LIVE_TEST`與`AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE`
opt-in，並執行Swift tests、正式Xcode App build＋獨立`SessionManagerModel` App-layer tests、shipping
Fixture boundary與diff whitespace checks。App tests在standalone `xctest`中使用in-memory diagnostics，
不啟動shipping App、不執行Live reload也不連Codex。

只執行Swift Package tests時：

```bash
cd macos/AgentSessionManager
ASM_TEMP_BASE="${TMPDIR:-/tmp}"
CLANG_MODULE_CACHE_PATH="${ASM_TEMP_BASE%/}/agent-session-manager-clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="${ASM_TEMP_BASE%/}/agent-session-manager-swiftpm-cache" \
swift test --disable-sandbox
```

Swift Package包含Core、獨立Fixtures test-support library與tests。請從正式`.xcodeproj`執行macOS App；不要再建立或執行同名SwiftPM command-line product，否則SwiftUI runtime沒有`.app` bundle identifier，Xcode console會出現window-tab indexing／layout recursion警告且視窗可能無法開啟。

`.xcodeproj`另有`AgentSessionManagerAppTests` standalone unit-test target。它直接把production
`SessionManagerModel.swift`編入test bundle，覆蓋預設Codex Active、Project＋Status雙層篩選、
checkbox可見性清理與Trash-only Select All；test target沒有App host，不能觸發`ContentView.task`。
2026-08-15已由Xcode UI `⌘U`驗證4 passed、0 failed、0 skipped。

Repository另提供opt-in的版本化pre-commit hook，預設不啟用，也不覆蓋既有自訂hooks path：

```bash
./scripts/configure_git_hooks.sh enable
./scripts/configure_git_hooks.sh status
./scripts/configure_git_hooks.sh disable
```

Hook只呼叫同一份`./scripts/verify.sh`，不維護第二套驗證邏輯。2026-08-15在目前開發機實測全新
cache約40秒、已有cache約6–7秒；啟用與否是每個working copy的local Git設定，不隨commit傳播。

Live smoke test 必須明確設定 `AGENT_SESSION_MANAGER_LIVE_TEST=1`，且執行環境需允許子 App Server 存取自己的 `~/.codex` state runtime。workspace sandbox 阻擋該 SQLite 初始化時，測試會 fail closed；應取得 scoped permission 後重跑，不可改讀 JSONL/SQLite 來繞過。

或開啟：

```text
macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj
```

Scheme：`AgentSessionManager`

Destination：`My Mac`

## Important files

- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/Models.swift`
  - identity、collections、protection、capabilities、operations、Preview/Report。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/SessionProvider.swift`
  - provider protocol 與 routing service。
- `macos/AgentSessionManager/Sources/AgentSessionManagerFixtures/FixtureSessionProvider.swift`
  - POC reference lifecycle implementation 與 demo data。
- `macos/AgentSessionManager/Sources/AgentSessionManagerFixtures/FixtureOperationHistoryLedger.swift`
  - 每 provider 500 份的 process-local Fixture history、Preview/Report validation、shared filters/search/keyset/export routing；沒有 serialization 或 SQLite I/O。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexAppServerProvider.swift`
  - paginated App Server transport、read-only mapping 與 diagnostics；RPC method 為 private allowlist。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateStore.swift`
  - manager-owned SQLite v8 schema、v0→…→v8 transaction migration、backup/integrity/restore；v4保存distinct manager intent，v5保存native-success-only membership `add/remove` intent，v6保存frozen working directory，v7保存verified Deleted tombstone，v8支援batch Report對多筆tombstone，由Live coordinator lazy bootstrap。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ArchiveAffectedSet.swift`
  - exact root/descendant graph planner、role/parent/depth persistence conversion、canonical affected-set hash 與 prepared-only factory；沒有 provider mutation capability。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ArchiveBatchAtomicity.swift`
  - non-transactional provider 的全批 preflight、deterministic sequential units、first non-success stop，以及 batch/unit/item finalization；沒有 transport/UI。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ArchiveBatchPersistence.swift`
  - canonical durable batch plan/report types、manifest hash 與 exact identity/ordinal conversion。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ArchiveBatchStateRepositories.swift`
  - SQLite v3 batch save/claim/finalize/readback，原子 claim/consume member Previews，並阻止 single-item replay；沒有 provider side effect。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ProtectionAuthority.swift`
  - typed protection source/scope policy；narrow positive 可保護，只有完整 authority scope 的 negative observation 可 clear。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteMaintenance.swift`
  - 精確 backup inventory/verification/0600 evidence、每類 3 份 + 30 天 retention candidate gate、typed decision reason、100 candidate fail-closed cap，以及 16 MiB + 20% physical compaction assessment；只產生 proposal。
- `macos/AgentSessionManager/Sources/AgentSessionManager/MaintenanceView.swift`
  - Live-only async read-only assessment sheet；顯示每份完整 backup path/evidence/reason 與 compaction estimate，沒有 action controls。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/PersistentStateModels.swift`
  - typed checkpoint、Trash membership、frozen Preview／Report，以及 operation-history retention policy/result。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/SQLiteStateRepositories.swift`
  - monotonic checkpoint、atomic Trash/Preview/Report CRUD、provider-scoped complete-bundle history pruning，以及 filtered/keyset history query；沒有 provider side effect。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/OperationHistoryExport.swift`
  - history query/result types 與 JSON／CSV exporter；private default 遮蔽 title、project ID、自由文字 error，永遠不接受 Preview hashes。
- `macos/AgentSessionManager/Sources/AgentSessionManager/ReportHistoryView.swift`
  - manager SQLite history filters/search、50-row keyset pages、itemized detail、privacy disclosure 與 JSON／CSV save panel。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/SessionStateReconciler.swift`
  - live snapshot + Trash intent 的純 read-only conflict matrix。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/SessionSnapshotCoordinator.swift`
  - complete-only authoritative checkpoint policy、canonical inventory hash 與 atomic membership reconciliation commit。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/SessionPresentation.swift`
  - normal/conflict/missing/unavailable 的 UI-safe row model。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/StateStoreLocation.swift`
  - bundle-ID Application Support lifecycle SQLite與Diagnostic Log path resolver。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/DiagnosticLog.swift`
  - bounded/privacy-filtered JSONL event model、actor store、retention、corrupt-line recovery、0600 persistence與export。
- `macos/AgentSessionManager/Sources/AgentSessionManager/SettingsView.swift`
  - General retention disclosure與Logs filters/table/detail/Copy/JSONL export。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ConflictResolution.swift`
  - read-only resolution proposal、frozen evidence、option readiness 與 fail-closed planner。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ConflictResolutionCoordinator.swift`
  - Accept Native Restore 的 durable token Preview、membership-set drift check、原子 membership/Report/Preview transaction；無 provider transport。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ExactSessionReadback.swift`
  - Present / Absent / Unavailable、failure taxonomy、RPC code 與 version-exact typed absence contract；generic error 或裸 Absent status 不得冒充 absence。
- `macos/AgentSessionManager/Sources/AgentSessionManagerCore/ProtectionEvidence.swift`
  - 四個 protection 欄位的三態 verdict、provider-specific source 與 fail-closed explanation。
- `macos/AgentSessionManager/Sources/AgentSessionManager/SessionManagerModel.swift`
  - SwiftUI application state。
- `macos/AgentSessionManager/Sources/AgentSessionManager/SessionTableView.swift`
  - table、search、toolbar operations。
- `macos/AgentSessionManager/Sources/AgentSessionManager/OperationPreviewSheet.swift`
  - Preview、typed permanent-delete confirmation、Report。
- `macos/AgentSessionManager/Sources/AgentSessionManager/ConflictResolutionPreviewSheet.swift`
  - Active + Trash 的 explicit Confirm Apply（無 typed token），以及 Externally Missing 的唯讀 evidence/option review。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/AgentSessionManagerCoreTests.swift`
  - lifecycle safety tests。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/SQLiteStateStoreTests.swift`
  - schema v4、private permissions、v1/v2/v3 migration backup/compatibility、failure rollback 與 reversible restore tests。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ArchiveAffectedSetTests.swift`
  - exact descendant closure、protection/state gates、persistence round trip、hash tampering/rollback 與 single-item executor boundary。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ArchiveBatchAtomicityTests.swift`
  - overlap/order、preflight rejection、success/failure/partial/unknown/not-attempted、itemized identity coverage 與 invalid sequence tests。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ArchiveBatchPersistenceTests.swift`
  - plan/report round trip、manifest/reference drift、atomic claim、wrong-token/replay、single-item bypass 與 incomplete finalization rollback tests。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/SQLiteMaintenanceTests.swift`
  - exact filename/symlink boundary、損壞與 mislabeled backup 保護、count/age/candidate limit，以及 compaction assessment 無 mutation tests。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/PersistentStateRepositoryTests.swift`
  - typed round-trip、checkpoint monotonicity、atomic Preview/Report 與 incomplete checkpoint rejection。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/OperationHistoryRetentionTests.swift`
  - 自動／顯式 pruning、provider 與未完成 Preview 隔離、完整 bundle 刪除、invalid limit 與 transaction rollback。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/OperationHistoryExportTests.swift`
  - filters、keyset pagination/tie-break、invalid query，以及 JSON／CSV privacy、escaping 與 formula neutralization。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/FixtureOperationHistoryLedgerTests.swift`
  - Fixture report conversion、released-bytes honesty、filters/search/keyset、provider-scoped retention、failure atomicity 與 clear。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/SessionStateReconcilerTests.swift`
  - normal/conflict/missing/unavailable matrix 與 fail-closed input validation。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/SessionSnapshotCoordinatorTests.swift`
  - complete/partial/provider failure/stale/idempotent snapshots、stable hash 與 opt-in live coordinator persistence。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/SessionPresentationTests.swift`
  - conflict 與 membership-only rows 不被誤分類。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/StateStoreLocationTests.swift`
  - stable bundle-ID path 與 path-like identifier rejection。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ConflictResolutionPlannerTests.swift`
  - conflict option matrix、exact-ID deletion blocker、incomplete inventory 與 normal-state rejection。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ConflictResolutionCoordinatorTests.swift`
  - Accept Native Restore success、token/checkpoint/full-membership drift、refresh timestamp 與 transaction rollback。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/FixtureConflictResolutionTests.swift`
  - Demo Conflict 標示、錯誤 token 不變與 process-local Accept Native Restore。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ProtectionEvidenceTests.swift`
  - unknown false 不得成為 Verified clear，以及 Codex/Fixture evidence source mapping。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ProtectionAuthorityTests.swift`
  - process-local positive/negative asymmetry、cross-host clear、pin/graph clear，以及 duplicate/source-scope mismatch fail-closed tests。
- `macos/AgentSessionManager/Tests/AgentSessionManagerCoreTests/ArchiveIsolatedSessionAcceptanceTests.swift`
  - test-only exact-ID mutation harness；short-lived operator authority、complete pinned list、current/positive protection override prevention、Preview-first/Report-after。

## Design decisions already made

- App 名稱：Agent Session Manager；repository：`agent_session_manager`。
- 以 provider adapter 擴充其他 agent system，不把 Codex 寫死在 UI。
- Archive 是保留；Trash 是 manager-owned pending deletion intent。
- Codex 若沒有 native Trash，Archive 與 Trash 可共享 native archived state，但 local membership 必須分開。
- 不使用人工 CSV/Markdown 維護 pending list；SQLite v8、typed CRUD、distinct manager-intent／membership-effect、Deleted tombstone、Report History、reconciler、單筆與checkbox native Archive／Restore／Delete及Active ↔ Trash finalization已建立。0.147.0的archive/unarchive/delete只可經受限facade使用；Delete只接受Trash，positive protection與unknown pin／pinned-descendant fail closed；只有cross-host running/current unknown進入one-shot `attemptMayFail`。
- Archive → Trash 不必 Restore。
- Trash → Archive 不必 native unarchive；Trash → Active 才 Restore。
- `SessionOperationPlan` 已把 native lifecycle 與 Trash membership 分開；Archive ↔ Trash 是 manager-only，Active → Trash 才需要 native Archive。
- 永久刪除只從 Trash。
- pinned session 無論政策或時間都不能 retire/delete。
- 每次 operation 都必須有統計與 itemized report，且完整顯示 session ID。
- Archive 不釋放 rollout 空間，report 應是 0 B released；不能把 affected size 說成 released size。
- App 達 parity 前，`codex-retire-sessions` skill 仍是 live-operation fallback。

## Known limitations

- Live已接manager-only Archive ↔ Trash，以及native Archive／Restore／Active ↔ Trash／Trash → Deleted的單筆與checkbox batch。Native batch以一份multi-item Preview/token凍結selection，全批preflight後依manager-key順序執行；failure/unknown停止，後續`batch_not_attempted`。Delete只接受Manager Trash並逐筆要求known-clear pin／pinned-descendant、零descendant、無positive running/current與雙absence readback；cross-host running/current unknown會明示可能失敗，但不再造成永久禁用。SQLite v8允許一份batch Report原子建立多筆Deleted tombstone；既有single／batch人工驗收與證據已整理於`DELETE_ACCEPTANCE.md`，沒有為補文件重跑Delete。Startup recovery只有readback不重送。Production data-source build boundary已完成；眼前下一步是重新打包並驗證DMG，之後做Archive可見live acceptance與history呈現微調。Reapply Trash Intent與Externally Missing Apply仍未實作。
- Live inventory 會沿 cursor 讀完 active / archived；極端情況仍受每個 collection 10,000 筆 hard cap 保護，且尚未提供漸進式載入 UI。
- 官方最新文件已描述 `thread/list.isPinned`，但本機 Codex 0.147.0 與 Desktop bundled 0.147.0-alpha.6.5 的生成 schema/runtime 尚未提供。App 現在唯讀解析 Desktop `.codex-global-state.json` 的 `pinned-thread-ids`，inventory 前後 membership 必須一致；live acceptance 精確對上使用者列出的 13 個 pinned Codex sessions。Pin list 與完整 all-source graph 共同提供 pinned／pinned-descendant evidence並進入 inventory hash；缺欄、malformed、duplicate、drift 或與未來 `isPinned` 衝突都 unavailable。`status.active` 仍只提供 running 正向證據。跨-host running/current/writer unknown 不得顯示為 clear；Core readiness、affected-set factory、SQLite save/claim、single-item executor、facade 與 recovery 使用相同 operation-specific contract，將它們保留為 allow-listed Archive 的 Busy risk；positive evidence 與 pinned 類 unknown 仍 blocked。
- Native single-item preflight 不再把全 provider inventory hash equality 當 mutation gate；該 hash 含無關 sessions 與顯示欄位，曾在 Active → Trash confirmation 產生 `archive_state_drift` false failure。現在 exact target identity/state、Archive protection hash 與 descendant scope 仍逐項 fail closed，無關 inventory drift 可通過。
- 本機 0.147.0 generated schema 與官方 manual 均包含 `thread/archive` / `thread/unarchive`。Production-facing `CodexNativeArchiveCoordinator` 已封裝 internal transport／authorization／executor，SwiftUI 已接 Preview-first、explicit Confirm、one-shot request、fresh inventory readback 與 Report-after consume。一次私有 isolated acceptance request 曾被 `-32600` 明確拒絕，fresh readback 證明 target 仍為 Active；Desktop writer ownership 與 upstream 同型測試強力支持 active-writer 診斷，但舊 Report 未保存原始 message。Eligible non-pinned single root 現可進入 Create Preview；synthetic pinned session仍正確顯示 Blocked。
- 官方 App Server 文件描述 stdio/WebSocket/Unix socket 與 default control socket，但沒有把 Codex Desktop 私有 `~/.codex/ipc/ipc.sock` 宣告成可共用 lifecycle endpoint。2026-08-13 process readback 顯示 Desktop bundled `codex-cli 0.147.0-alpha.6.5` 由 ChatGPT parent 啟動 `app-server --analytics-default-enabled`，沒有 `--listen`，因此仍是 parent-owned default stdio；documented managed socket 不存在。Homebrew/Desktop install 也不能啟動要求 installer-managed standalone binary 的 daemon；短生命週期 `/tmp` Unix listener + `proxy --sock` 只送 initialize/loaded-list，server 回報 WebSocket upgrade `httparse invalid token`，沒有 lifecycle mutation，probe 已停止並移到 Trash。這些結果保留為 transport evidence，但 shared host 只改善 writer visibility，不是 Archive attempt 的必要條件；不得再把它列為 production gate。
- All-source inventory已保留exact parent/native-state graph並納入checkpoint hash；Core/SQLite可凍結完整descendant affected set。一般zero-descendant checkbox batch已接provider executor/history/UI；SQLite v3的root＋descendant affected-set batch仍未接provider executor，因此不可與已完成的一般multi-item batch混淆。
- Project 只使用 Codex Desktop `local-projects` 目錄，依最長 project root ancestor 配對 session cwd；無匹配時顯示 unavailable，不以 Git origin 或 trust entry 回退。Working Folder 與 Trust Folder 是獨立分類。
- Test-only Fixture report沒有實際released bytes，因為沒有disk mutation。
- Xcode project 只是本機 POC app target，尚未 Developer ID sign/notarize，也沒有 sandboxed helper。
- `scripts/package_dmg.sh` 可產生同機使用的 ad-hoc signed local DMG，並在build前後驗證Fixture shipping boundary、bundle metadata、signature、DMG、read-only mount contents 與 SHA-256；公開發佈仍未 Developer ID sign/notarize。
- App icon 已接入 Xcode asset catalog；仍沒有 localization、accessibility QA 或 CI。
- UX已展開完整lifecycle toolbar、session context menu、即時disabled hover blocked reason與不可逆action的高對比typed-token panel。Sidebar最上方是必選Agent Systems，不提供All Agents；目前固定顯示`Codex Live`，未來Claude可並列，Fixture仍是test-only。Status啟動預設Active；Agent System可同時搭配Status與一個Project／Trust／Working Folder scope，只有後三者互斥。Agent Systems收合時顯示目前值。Sidebar counts由一次`SidebarMetrics`掃描建立；item使用連續full-row hit targets。Report History可用frozen matching IDs + typed token清除完整bundles，不影響manager lifecycle state或Codex。

## Suggested next-thread prompt

> 請接續 `/Users/example/Projects/agent_session_manager`。先完整閱讀README.md、AGENTS.md與docs核心文件。SQLite v8與operation-specific單筆／checkbox batch Archive／Restore／Delete已接production；Delete只接受Manager Trash，每筆最多送一次`thread/delete`，complete inventory＋exact-ID absence共同證明成功後才原子移除membership並建立Deleted tombstone；既有single／batch人工驗收已記錄於`docs/DELETE_ACCEPTANCE.md`，不要只為重驗而再次刪除。Native batch先全批preflight、依frozen順序執行、non-success後停止，startup recovery只讀不重送。Production data-source boundary已完成：shipping App固定Codex Live，Fixture拆到test-only target，packaging會驗證source／linkage／Release binary。下一步重新打包並驗證DMG，之後處理Archive可見live acceptance。不得把unknown標成success、自動retry、縮小batch、讓Archive直接Delete，或讀寫agent system session JSONL/SQLite/cache。

## First verification in the new thread

- Confirm repository path and working tree status。
- Run deterministic core tests before editing；live smoke 必須透過 `AGENT_SESSION_MANAGER_LIVE_TEST=1` 明確 opt in。
- Build the Xcode scheme。
- Inspect current Codex App Server documentation/runtime methods live；IDs and schemas are version-sensitive。
- Verify `scripts/verify_shipping_boundary.sh`仍通過，且任何新增App dependency都沒有把`AgentSessionManagerFixtures`重新連入shipping target。
