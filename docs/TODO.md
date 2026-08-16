# TODO

## P0 — 2026-08-15 codebase audit follow-up

- [x] F1 + F2：建立版本化 `scripts/verify.sh`，固定執行 deterministic `swift test`、正式 `.xcodeproj` Debug build、shipping Fixture boundary source/binary check，以及 staged／unstaged `git diff --check`；腳本明確移除 live／Archive acceptance opt-in，平常只顯示摘要，失敗才輸出 bounded log。
- [x] F5：README、HANDOFF 與驗證腳本的暫存／module-cache／DerivedData位置統一由 `${TMPDIR}` 解析，不再硬編碼 `/tmp`。
- [x] F6：已新增 `docs/DELETE_ACCEPTANCE.md`，以read-only SQLite證據整理已完成的single／batch Delete人工驗收、runtime、Preview/token hash、dual-absence contract、Trash membership removal、Deleted tombstone與Report；沒有為了補文件重做不可逆Delete。
- [x] F4：`tmp/debug/` 已遷移到受 Git 追蹤的 `docs/debug/`，並以分類索引保存。
- [x] Shipping boundary：正式App固定Codex Live；Fixture只留獨立test-support target，packaging與統一驗證腳本持續阻止Fixture重新連入shipping App。
- [x] 建立不啟動shipping App／不連Codex的獨立Xcode App test target，直接編譯同一份`SessionManagerModel.swift`，覆蓋預設Codex Active、Project＋Status組合、checkbox selection可見性清理與Trash-only Select All；`scripts/verify.sh`固定執行正式App build＋App-layer tests。
- [x] 移除 `try! DiagnosticLogStore()`，以可測試bootstrap在磁碟初始化失敗時改用bounded in-memory emergency buffer；App啟動會警告一次，Settings持續顯示「本次Log未寫入磁碟且離開即消失」，Refresh不得清除這個persistence warning，且不自動合併舊磁碟Log。
- [x] 實測統一驗證並提供opt-in版本化pre-commit hook：目前開發機全新cache約40秒、已有cache約6–7秒；`configure_git_hooks.sh`需明確enable且不覆蓋既有`core.hooksPath`，repository不預設強制啟用。
- [ ] Repository建立remote後，再新增呼叫同一`./scripts/verify.sh`的CI；目前不維護第二套GitHub Actions專用驗證邏輯。
- [x] 決策：不主動重構三個Authorization coordinator的共用骨架。它位於安全關鍵路徑、淨收益有限；只有出現真實drift或必要共同變更時才另案評估。

## P0 — 下一個 thread 優先處理

- [x] 建立正式 `CodexAppServerProvider`，第一版只開 `sessions()` 與 diagnostics。
- [x] 調查並記錄 Codex App Server 的官方 list/read/archive/unarchive/delete method、schema 與 version handshake。
- [x] 為 App Server transport 建 synthetic protocol fixture captures，不在 deterministic tests 依賴使用者真實 sessions。
- [x] 完成 pinned/current/running/descendant safety-state audit；只開啟已驗證的 descendant count 與 running 正向證據，其餘 unavailable 並維持 mutation disabled。
- [x] 新增 Codex Live mode switch、connection health 與 capability badges；inventory adapter 維持 read-only。
- [x] 把 UI action disable logic 改為 selection × state × provider capability 的交集。
- [x] 為 selection 顯示 blocked reason，不只在 Preview alert 報錯。
- [x] Live inventory 加入 cursor pagination、跨頁 ID 去重、repeated-cursor detection 與 10,000 筆／collection hard cap。
- [x] 分離 Desktop Project、Working Folder、Trust Folder 與 Git metadata；Project 由 `local-projects` root 配對，trust 只由官方 `config/read` 提供。
- [x] 建立 SQLite schema v1 proposal、transaction migration、backup/restore/rollback tests，尚不接 app 或 mutation。
- [x] 建立 typed checkpoint／Trash／Preview／Report repository，驗證原子寫入、完整 frozen item set 與 checkpoint monotonicity。
- [x] 建立純 Core read-only reconciler 與 Active／Archive／Trash／conflict／missing／unavailable matrix tests。
- [x] 建立逐欄位 protection evidence contract 與 Inspector：Protected／Verified clear／Unavailable、來源、理由；unknown false 不得冒充 clear。
- [x] 建立 protection authority source/scope policy：manager-process idle 不得冒充 cross-host clear，source/scope mismatch 與 duplicate observation fail closed。
- [x] 建立第一個 live Archive slice 的 typed readiness gate 與 UI：精確單選、active Codex root、runtime/checkpoint、官方 interface、protection、零 descendants、executor 分離；只有全部 permits attempt 才能建立 Preview。
- [x] 建立 module-internal single-Archive executor contract 與 synthetic process fixture：exact payload、canonical manifest、preflight drift、zero descendants、no blind retry、fresh readback 與 unknown outcome。

## P1 — Safety and correctness

- [x] SQLite Preview persistence 已有 manifest hash、expiry 與 provider inventory hash；不重複在 read-only UI domain 增加第二份 hash。
- [x] 以 runtime version／reconciliation timestamp-bound canonical Preview model 建立 executor drift check。
- [x] 建立 SQLite authorization coordinator，強制 Preview 先持久化並 atomically claim 為 `executing`、executor 只消費 exact claimed record，並把 success/failure/unknown itemized Report 原子落盤後 consume Preview。
- [x] 建立 unresolved `executing` reconciliation；Report persistence failure／crash 後只允許 original-checkpoint-bound official inventory readback 與 atomic Report repair，型別上無 Archive capability，普通 refresh 也不覆蓋 claim checkpoint。
- [x] 建立 test-only isolated-session acceptance harness 與人工 runbook；已執行一次真實 request 並得到 verified `-32600` failure + Active readback，success path 尚未完成 live acceptance。
- [x] 為 isolated acceptance 增加 exact-ID、最長 5 分鐘、完整 pinned list 與 cross-host/current 人工 attestation；只在 test target，不能覆蓋 positive protection 或開 production capability。
- [x] 建立可重跑的 stable App Server contract audit；schema presence 只做 compatibility evidence，跨 host idle/current authority 仍人工 fail-closed。
- [x] 定義並持久化 root＋descendant affected-set batch atomicity：全批 preflight、deterministic execution-unit order、first failure/partial/unknown stop，以及 batch/root/affected-item 三層 `notAttempted` finalization；SQLite v3 已原子保存 plan/member/report 並阻止 single-item replay。這條較早的 affected-set path 尚未接 executor/history/UI；一般 zero-descendant checkbox batch 已另行完成。
- [x] single-item executor 已實作 timeout 後 fresh exact-ID inventory readback且不盲目 retry；coordinator/facade/UI/recovery/harness 已完成，success path 仍待 App 可見 live acceptance。
- [x] 執行一次真實 isolated Archive request：App Server `-32600` 後 fresh readback 證明 Active、沒有 retry。Desktop writer ownership 與 upstream 同型測試支持 active-writer 診斷；舊 Report 未保存原始 RPC message。新程式會保存完整 message，並在逐字符合時分類 `archive_request_busy_active_writer`。
- [x] 把 writer clearance 從 running/current 拆成獨立 typed readiness authority；要求 exact ID、runtime、inventory hash 與不早於 checkpoint 的 observation，現行 separate-stdio provider 明確回報 unavailable。
- [x] 拆開 manager operation intent、native lifecycle mutation 與 Trash membership mutation；Archive ↔ Trash 不重複送 native request，SQLite v4/history 保留 distinct `move_to_archive` intent。
- [x] 將 native Archived 的 Archive ↔ Trash manager classification 接到 Live UI：frozen Preview、確認前 fresh official inventory、checkpoint/manifest/membership drift fail-closed、SQLite membership/Report/Preview 同 transaction，commit 後精確 readback；沒有 provider lifecycle transport。
- [x] 驗證官方 control-socket/shared-host route：Desktop bundled 0.147.0-alpha.6.5 實際仍是 parent-owned default stdio；managed daemon socket 不存在，現有 install 無 installer-managed standalone daemon，短生命週期 Unix listener + proxy 也未完成 WebSocket handshake。不得把另一個 socket host 當 Desktop writer。
- [x] 重構 Archive readiness：不得把 `idle` 當成 writer-free；positive writer/running/current 仍 block，unknown 使用 typed `attemptMayFail`，只適用 allow-listed one-shot Archive + fresh readback/no-retry contract。Core/UI 與 tests 已完成。
- [x] 將 SQLite save/claim／Preview factory／Archive executor／recovery 的 aggregate `protectionComplete` 改為 operation-specific preflight；pinned／pinned-descendant unknown 仍 fail closed，running/current unknown 只進入 one-shot + fresh readback/no-retry contract。
- [x] 取得 pinned／pinned-descendant evidence：Codex Desktop `pinned-thread-ids` inventory 前後一致快照 + 完整 graph；未知、漂移或衝突時仍 fail closed。
- [x] 接上 production single-root Archive facade/executor/Preview/confirmation/report UI；完整呈現 success、Busy failure 與 unknown，且 App 無法取得底層 mutation transport。
- [ ] 完成 App 可見的 live Archive success／Busy／unknown acceptance；新 runtime 實際提供 `isPinned` 後重新 audit exact version，並要求與 Desktop source 一致。
- [x] 將 unresolved `executing` readback-only recovery 接到 app startup／refresh；沿用完整 official snapshot、先保留 claim checkpoint、Report consume 後再 refresh，且不得 retry Archive。
- [x] 接通 manager Archive → Active 的 native Restore：single-item durable Preview、explicit Confirm、allow-listed `thread/unarchive`、fresh Active readback、itemized Report與 readback-only recovery；不要求 typed token 或 Archive-only protection evidence。
- [x] 接通 Active → Trash 與 Trash → Active：SQLite v5 durable `add/remove` membership intent、SQLite v6 frozen working-directory evidence、migration backup/rollback、native Archived/Active success 後原子 membership／Report／Preview finalization、failure/unknown 保留原 intent、readback-only crash recovery與 SwiftUI Preview/Report。
- [x] 接通單筆與checkbox batch Trash → Deleted：audited 0.147.0 `thread/delete`、destructive token＋Copy、operation-specific protection/zero-descendant preflight、cross-host running/current unknown的`attemptMayFail`、one-shot request、complete inventory＋exact-ID absence雙 readback、SQLite v8 Deleted tombstone、failure/unknown 保留Trash，以及readback-only crash recovery。Archive不得直接Delete。
- [x] SQLite v8 migration解除`delete_report_id`單筆唯一限制，讓一份exact-selection Delete batch Report可原子建立多筆tombstone；包含v7 backup、成功migration與failure rollback tests。
- [ ] 對 descendant 操作建立完整 affected-set Preview（Core exact graph planner、checkpoint hash、SQLite v2 persistence 與 prepared factory 已完成；尚待 read-only UI，既有 single-item executor 明確拒絕）。
- [x] 為每個 session row 加入 checkbox；只有 Trash Bin 顯示三態 Select All checkbox bar、shown／selected count 與 Clear Selection，其他 Status 只有逐列 checkbox。Search／scope／refresh 不保留看不見的 selection。
- [x] 修正 AppKit 三態 checkbox 撐高 Trash selection bar 的 layout；保存 Session table 欄寬，並隔離 Sidebar footer 與長清單內容。
- [x] 保存左右 pane 寬度與 Sidebar 收合狀態：以 App-owned `NSSplitViewController`、固定 autosave identity 與 unconstrained `NSHostingController` 取代不穩定的 SwiftUI dynamic key；已驗證三欄全高 layout、toolbar、search、sidebar toggle 與 300／807／300 frame 跨重啟 readback。保留 `--legacy-navigation-split` 診斷回退。
- [x] 讓 Archive、Move to Trash、Restore、Move to Archive、Delete Permanently 全部支援同 provider checkbox selection batch；native batch以一份multi-item Preview/token一次claim，全批preflight後依frozen順序執行，第一個failure/unknown後停止且剩餘項目記為`batch_not_attempted`。Manager-only Archive ↔ Trash維持原子batch。
- [x] Empty Trash把當下已勾選、且經目前search／scope顯示的完整Trash manager IDs凍結進Preview，不在執行時重新查詢；只有Trash Bin額外提供Select All。
- [ ] 增加 current task self-protection integration test。
- [ ] 若未來可接入涵蓋 all relevant hosts 的 running/current authority，將其用於事前精確阻擋與改善成功率；它是可選強化，不再是送出 allow-listed Archive 的必要條件。
- [ ] 增加 pinned descendant、running drift、external unarchive、external delete tests。
- [ ] 增加 duplicate title / duplicate project fixture，驗證 UI 與 report 始終以 ID 識別。
- [ ] Report 新增 known bytes、verified released bytes、unknown-size count、error code。
- [ ] 報表可匯出 JSON / CSV，但 SQLite 仍是 canonical state；Markdown 只做輸出，不做 pending list。

## P1 — Persistence and reconciliation

- [x] 選用 macOS system `libsqlite3`，記錄選擇理由與 transaction migration strategy。
- [x] 建立 v3 schema：既有 checkpoint/Trash/Preview/Report/items，加上 batch plans/units/items/reports；含 v1 affected-set 與 v2 batch migration。
- [x] 建立 backup before migration、單檔 backup 驗證與可逆 Core restore API。
- [ ] 建立 restore command/UI；不得在 store 仍開啟時 restore。
- [x] 建立 Trash/Preview/Report typed CRUD repository 與 transaction tests，仍不接 live mutation。
- [x] 建立 snapshot coordinator：完整 inventory 才能 advance authoritative reconciliation，partial/failure/stale 不覆蓋 authoritative checkpoint。
- [x] 建立 reconciliation presentation model，可表示 active+Trash conflict 與 membership-only missing/unavailable，不壓回普通 `SessionCollection`。
- [x] 以 bundle-ID Application Support path在Codex Live第一次reload時bootstrap production store；test-only Fixture不建立資料庫。
- [x] 接 SwiftUI read-only refresh；顯示 checkpoint disposition、coverage、SQLite path 與 conflict/unavailable rows。
- [x] 設計 read-only conflict resolution proposal：完整 identity、checkpoint evidence、選項、必要證據與 blocked reasons；不自動改 native state 或 SQLite intent。
- [x] 實作 Active + Trash 的 Accept Native Restore Apply：durable frozen confirmation、fresh inventory、runtime/inventory/manifest/完整 membership-set drift check、原子 membership removal／Report／Preview consume與逐筆 readback；Coordinator 無 provider transport。
- [ ] 實作其他 conflict resolution Apply：Reapply Trash Intent 需要官方 lifecycle call/readback；Externally Missing acknowledgement 需要 authoritative exact-ID absence contract。
- [x] App 啟動與 Live refresh 時 reconcile local membership vs provider inventory。
- [x] conflict UI：native active + local trash、native absent + pending、unknown provider state；Accept Native Restore 可 Apply，其餘僅 Review。
- [x] 接入官方 `thread/read(includeTurns=false)` exact-ID readback；成功精確 ID 可證明 Present，所有未文件化 error fail closed 為 Unavailable。
- [x] 建立 exact-ID failure taxonomy、RPC code evidence 與 typed absence contract gate；裸 `.absent` status 不足以證明 absence。
- [ ] 建立官方文件與 version-gated tests 可證明的 exact-ID not-found contract；完成前不得產生 Absent evidence。
- [x] 定義 provider-scoped report retention：預設保留最新 500 份完整 history bundle，Report commit 同 transaction pruning，並有 rollback／非目標資料保護測試。
- [x] 加入 `⌘,` Settings General／Logs：持久化bounded JSONL、30天／10,000筆／20 MB retention、privacy denylist、主要operation events、filters/detail/Copy/JSONL export與Core tests。
- [x] 定義 Core-only migration/pre-restore backup retention assessment 與 physical compaction proposal；不得自動 `VACUUM` 或刪 backup。
- [x] 將 typed maintenance disposition/reason 與 compaction estimate 接成 Live-only read-only sheet；shipping App固定Live且UI沒有mutation controls。
- [ ] 建立 backup candidates 的 frozen confirmation／readback／macOS Trash executor，以及 pre-backup + verified replacement 的明確授權 compaction executor。
- [ ] 不保存 conversation body；只保存 lifecycle 所需 metadata 與 evidence。

## P2 — UX polish

- [ ] Empty Trash 支援全選後仍產生精確 itemized Preview。
- [ ] Project group、date range、title query 可用來建立 selection，但 confirmation 後不得重新查詢擴張範圍。
- [ ] Batch selection summary 顯示完整 IDs 或可展開清單。
- [x] Inspector 顯示 provider capability、raw-vs-manager state explanation 與逐欄位 protection evidence。
- [x] Report history query Core：provider／operation／outcome／完成時間 filters、keyset pagination、summary consistency validation。
- [x] Privacy-safe JSON／CSV export Core：完整 native ID；title／project／自由文字 error 預設遮罩；hash 與 conversation content 不進 export model。
- [x] Report history/search UI、全部 matching retained reports export、save panel 與使用者可見 privacy disclosure。
- [x] Report History Clear Filtered Reports：filter-bound frozen IDs、typed token、Live single-provider transaction、bundle drift rollback與 exact readback；不碰 Trash/checkpoint/pending Preview/native session。
- [x] Toolbar 展開全部 lifecycle actions、session row context menu、即時 disabled hover blocked reason，以及 Sidebar disclosure + 緊湊 Status Filter／單一 Browse By scope 雙層篩選；sidebar counts 一次掃描、Agent Systems 收合值可見。
- [x] Test-only Fixture harness使用bounded、純in-memory report ledger驗證跨多次operation history；不bootstrap production SQLite。
- [ ] Trash retention age badge，但不自動永久刪除。
- [ ] Archive / Trash / Restore 快捷鍵與 VoiceOver labels。
- [ ] Dark mode、Dynamic Type、keyboard-only、localization QA。
- [x] App icon（完整 macOS 16–1024 px asset catalog 與 DMG readback）。
- [ ] 正式 empty/error/loading states。

## P2 — Engineering

- [x] 建立 production data-source build boundary：shipping app 直接啟動 Codex Live，移除 Fixture/Live UI switch；Fixture拆到獨立test-support target，並由source／target linkage／Release binary verifier證明正式App無法到達。
- [x] 移除與正式 Xcode App 同名的 SwiftPM command-line executable；Package 只保留 Core/tests，避免 Xcode 誤選無 bundle identifier 的 runnable。
- [ ] 把 Xcode app target 的 shared SwiftUI sources 配置自動檢查。
- [ ] Remote CI：repository建立remote後，呼叫已完成的`./scripts/verify.sh`；format/lint可另行加入，不複製Swift/Xcode/schema驗證流程。
- [ ] 加入 provider contract test kit。
- [ ] Diagnostic Logs 加入可選的 project／user path redaction；現有結構化 logging、bounded retention 與 sensitive metadata denylist 已完成。
- [ ] crash diagnostics 不包含 session conversation content。
- [ ] Signed helper / XPC threat model。

## Done in POC

- [x] Namespaced session identity。
- [x] Fixture provider and capability model。
- [x] Active / Archive / Trash / Deleted state mapping。
- [x] Archive → Trash direct transition。
- [x] Trash → Archive without native unarchive。
- [x] Delete only from Trash。
- [x] Protection, confirmation mismatch, preview drift tests。
- [x] Multi-provider batch rejection。
- [x] Preview and statistical itemized report UI。
- [x] Full session IDs throughout lifecycle UI。

## Definition of done for live permanent delete

只有下列全部成立，才可把 Delete Permanently 從 feature flag 後開啟：

- [x] official API compatibility verified for exact audited runtime 0.147.0
- [x] pinned/current/running/descendant preflight verified
- [x] durable Trash membership reconciled
- [x] frozen Preview and destructive typed confirmation verified：可逆 lifecycle 使用 explicit Confirm，Delete 使用 typed token
- [x] exact-ID runtime readback verified by Delete-specific dual-evidence contract
- [x] timeout/incomplete/unknown readback recovery tested；證據不足只允許 read-only retry，不重送 mutation。
- [x] released-space wording does not claim or estimate freed bytes
- [x] isolated real-session single／batch acceptance已完成並記錄於`docs/DELETE_ACCEPTANCE.md`；較舊完整Report已清除，只保留tombstone evidence，未為補文件重跑Delete。
- [x] implementation documentation and SQLite v8 backup／rollback tests updated
