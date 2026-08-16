# Roadmap

Roadmap 以 safety gate 而不是日期排序。前一 phase 的 exit criteria 未完成，不開啟下一 phase 的 destructive capability。

## Phase 0 — Fixture POC

狀態：**完成**

- [x] Swift Package Core library/tests + 正式 Xcode SwiftUI App target；已移除容易與 `.app` scheme 混淆的同名 SwiftPM command-line executable
- [x] Provider protocol 與 capability model
- [x] Archive / Trash / Deleted manager collections
- [x] Preview / confirmation / report flow
- [x] 可逆 lifecycle 使用 explicit Confirm；不可逆 Delete／History clear 使用 typed token
- [x] pinned / running / current / pinned descendant model
- [x] full session ID in table, inspector, Preview, Report
- [x] fixture-only banner與明確 no-live-session boundary
- [x] lifecycle core tests
- [x] standalone Xcode App-layer tests：同時build正式App並測試`SessionManagerModel`狀態，不以shipping App作test host、不連live provider
- [x] architecture, safety, UI, roadmap, TODO, handoff docs

Exit criteria：app 能編譯、tests 全過、fixture lifecycle 可操作、沒有真實 session access。

## Phase 1 — Codex read-only inventory

狀態：**進行中（paginated read-only inventory 已完成）**

目標：只讀列出 live Codex tasks，絕不 mutation。

- [x] 建立 `CodexAppServerProvider` read-only adapter。
- [x] 使用官方 App Server `thread/list` interface，不掃描 JSONL 當 canonical source。
- [x] 解析 active / archived、title、Desktop project、working folder、folder trust、updated time、full ID；Project 只由 `local-projects` root 配對，不由 trust 或 Git origin 推定。
- [x] 驗證 safety-state 來源：descendant graph 可由完整 all-source inventory 驗證；`status.active` 只提供 running 正向證據；本機 0.147.0 的 pinned、跨 host running=false、current 仍 unavailable，且 mutation 維持 disabled。
- [x] capability probe、connection diagnostics 與 Codex version reporting。
- [x] 早期開發 UI 曾提供 Fixture / Codex Live switch；production boundary完成後已從shipping App移除，Live inventory adapter維持read-only。
- [x] unavailable/unknown 欄位不得被推定為 false。
- [x] Inspector 以逐欄位三態 evidence 顯示 protection verdict、來源與 fail-closed 理由。
- [x] 加入 cursor pagination，正常讀到 `nextCursor=null`；以 10,000 筆／collection hard cap 與 repeated-cursor detection 保持有界。

Exit criteria：多次 refresh 可與 Codex Desktop UI / App Server readback 對照；任何欄位不確定時 mutation capability 仍為 false。

## Phase 2 — Durable manager state and reconciliation

狀態：**進行中（SQLite v8、reconciliation、單筆與checkbox batch的Archive／Restore／Active ↔ Trash／Trash → Deleted finalization已完成）**

目標：建立 Archive 與 Trash intent 的可靠 local source of truth。

- [x] SQLite v8 schema、v0→…→v8 transaction migration、migration前backup與可逆Core restore；v4保存distinct manager intent，v5保存success-only Trash membership `add/remove` intent，v6保存frozen working-directory evidence，v7保存verified Deleted tombstone，v8支援一份batch Delete Report對應多筆tombstone。
- [x] Migration backup / failure rollback / restore safety backup tests。
- [x] Typed provider checkpoint、Trash membership、operation Preview/Report repositories 與 transaction tests。
- [x] 純 Core reconciliation matrix：normal、external restore conflict、externally missing、incomplete/unavailable。
- [x] Snapshot coordinator：canonical hash、complete-only authoritative commit、partial/failure/stale fail closed。
- [x] Production store lazy bootstrap、conflict-capable presentation model 與 Live read-only app integration。
- [x] Conflict resolution proposal：frozen evidence、可考慮選項、必要證據與 blocked reasons。
- [x] Active + Manager Trash 的 Accept Native Restore：durable token Preview、fresh inventory、完整 drift check、原子 membership removal／Report／Preview consume與 readback；無 provider transport。
- [x] Official `thread/read` exact-ID presence evidence；undocumented missing/error results remain Unavailable。
- [x] Exact-ID failure taxonomy、RPC code evidence 與 version-exact absence contract gate；0.147.0 因官方未定義 not-found discriminator 而維持無 contract。
- [x] Trash membership、operation Preview、Report、provider checkpoint persistence primitives。
- [x] App 啟動 / refresh reconciliation。
- 外部 archive / delete conflict Apply 與 authoritative absence readback（Accept Native Restore、proposal/UI 與 exact presence 已完成）。
- [x] Report history/search UI、privacy-safe JSON／CSV export 與 macOS save panel（不包含 conversation content；Fixture 不建立 production store）。
- [x] Report History Clear Filtered Reports：frozen exact IDs、typed confirmation、transaction bundle deletion、drift rollback與 readback；保留所有 lifecycle state。
- [x] Test-only Fixture bounded ephemeral Report ledger：重用history query/export model，test process退出時清空，不寫production SQLite。
- [x] Provider-scoped bounded report retention：預設 500 份，完整 bundle 原子 pruning 與 rollback tests。
- [x] Settings Diagnostic Logs：獨立0600 JSONL、30天／10,000 events／20 MB三重retention、sensitive metadata denylist、corrupt-line recovery、Unified Logging mirror、filters/detail/Copy/Export UI。
- [x] SQLite maintenance proposal + read-only UI：精確 verified/0600 backup inventory、每類 3 份／30 天 retention gate、100 candidates hard cap，以及 16 MiB／20% physical compaction assessment；沒有 executor。
- [x] native Archived session 的 Archive ↔ Trash manager-only execution：fresh complete inventory、frozen manifest、protection gate、membership drift check、原子 Report/Preview consume 與 post-commit readback；不具備 Codex lifecycle capability。

Exit criteria：crash/relaunch、schema migration、state corruption recovery、external change scenarios 都有 tests。

## Phase 3 — Safe Archive / Trash / Restore mutations

狀態：**進行中（manager-only Archive ↔ Trash、single-item native Archive，以及 manager Archive → Active native Restore 已接 production path）**

目標：開啟可恢復的 lifecycle operation，仍不永久刪除。

- [x] 以本機 0.147.0 generated schema 驗證 `thread/archive` / `thread/unarchive` interface，且與 manager execution capability 分離。
- [x] 第一個 operation slice 的 typed readiness assessor：exact single selection、active Codex root、stable reconciliation、完整 checkpoint/runtime binding、exact readback、protection、零 descendants、executor gate。
- [x] 新增獨立 writer-authority gate：evidence 綁 exact native ID、runtime、inventory hash 與 authoritative checkpoint；separate-process idle/readback 不得解鎖。
- [x] Live UI 顯示逐項 readiness verdict；readiness 本身不送 lifecycle request，全部 permits attempt 後才進入 persisted Preview／explicit Confirm。
- [x] 建立 typed protection authority scope：窄 scope positive observation 可保護，只有完整 authority scope 的 negative observation 可 clear；Codex process-local idle 不得解鎖。
- [x] 建立 module-internal single-Archive executor contract：runtime-bound canonical manifest、完整 preflight、zero-descendant gate、一次官方 request、fresh exact-ID inventory readback，以及 success/failure/timeout/stale/unknown synthetic tests。
- [x] 建立 manager/native operation plan：Active → Trash 映射一次 Archive；Archive → Trash 與 Trash → Archive 僅改 membership；Trash → Active 映射 Unarchive；Delete 僅接受 Trash。Capability 依實際 native/membership mutation 分開檢查。
- [x] 接通 Archive → Trash 與 Trash → Archive 的 production SwiftUI path；它只操作 manager SQLite，Codex native state readback 必須持續為 Archived。
- [x] 建立 SQLite authorization coordinator：prepared Preview 先原子落盤並 claim 為不可 replay 的 `executing`，execution 後 success/failure/unknown itemized Report 原子 consume exact frozen item set。
- [x] 建立 unresolved `executing` reconciliation：crash 或 Report persistence failure 後只做 original-checkpoint-bound official inventory readback/report repair；recovery 型別沒有 mutation capability，證據不足保留 executing。
- [x] 建立 descendant-aware affected-set planner 與 SQLite v2 persistence：exact root/descendants、parent/native state、role/depth、checkpoint binding 與 canonical hash；現有 executor 明確拒絕，尚無 UI/batch mutation。
- [x] 定義並持久化 non-transactional provider 的 batch atomicity contract：全批 preflight、deterministic root order、first non-success stop、batch/unit/item 三層 partial/unknown/not-attempted finalization，以及 SQLite v3 plan/member/report 原子 claim/consume；仍無 transport/executor/UI。
- [x] 查證官方 Unix/WebSocket control-socket route：本機 Desktop 0.147.0-alpha.6.5 仍由 ChatGPT parent 以 default stdio 啟動；managed socket 不存在，Homebrew/Desktop install 無法啟動 installer-managed daemon，短生命週期 Unix listener + proxy 亦未完成 WebSocket handshake。Shared host 只改善事前 writer visibility，不是官方 Archive attempt 的必要條件。
- [x] 使用 test-only harness 送出一次真實 isolated Archive：2026-08-13 App Server 以 `-32600` 拒絕，readback 證明仍為 Active；已驗證 failure report 與 no-retry。Desktop writer ownership 與 upstream 同型測試支持 active-writer 診斷，但舊 Report 未保存原始 RPC message；Archive success path 尚未完成本 App 的 live acceptance。
- [x] 將 readiness 改為 operation-specific：positive writer/running/current 仍阻擋；unknown 顯示 `attemptMayFail` 並只允許 allow-listed Archive 的 one-shot + fresh-readback contract，不得標成 Verified clear。Core/UI typed verdict 與 tests 已完成。
- [x] 將 affected-set Preview factory、SQLite save/claim、single-item executor 與 recovery 的 aggregate `protectionComplete` gate 改為相同 operation-specific contract；positive protection 仍阻擋，pinned／pinned-descendant unknown 仍 fail closed，running/current unknown 只可 one-shot + fresh readback/no-retry。
- [x] 取得 pinned 與 pinned-descendant evidence：雙讀一致的 Codex Desktop `pinned-thread-ids` + 完整 all-source graph；缺失、漂移或雙來源衝突仍禁止 Archive。
- [x] App Server single-root Archive integration：public facade 封裝 internal transport／authorization／executor；SwiftUI 已接 persisted Preview、explicit Confirm、one-shot execution 與 success／failure／unknown Report。本機 runtime 仍由 pin evidence gate 阻擋。
- [ ] 完成 App 可見 Archive success／Busy failure／unknown live acceptance；未來 runtime pin contract 上線後仍須重新 audit exact version與雙來源一致性。
- [x] 將 readback-only unresolved `executing` recovery 接到 app startup／refresh：沿用第一個完整 official snapshot、保留原 checkpoint、補寫 Report 後再 refresh；facade 無 Archive capability，多筆 executing fail closed。
- [x] 接通 manager Archive → Active 的 single-item native Restore：durable Preview/token/claim、一次 `thread/unarchive`、fresh Active readback、success/failure/unknown Report與 readback-only crash recovery；Restore 不套用 Archive-only protection gate。
- [x] Active → Trash／Trash → Active：SQLite v5 durable freeze membership `add/remove` intent，v6另凍結working directory；native Archived／Active success、SQLite membership、Report與 Preview consume使用可恢復的原子 finalization，failure/unknown不改 membership且 recovery不重送 lifecycle request。
- Active → Archive、Active/Archive → Trash、Trash → Active/Archive。
- persistence 已有 manifest hash／expiry／provider inventory hash；production facade 已強制 Preview-first claim 與 Report-after consume，readback-only unresolved execution recovery 也已接 app startup／refresh。
- [x] 所有一般zero-descendant lifecycle operation的row-checkbox multi-selection batch executor與history/UI mapping；只有Trash Bin提供三態Select All checkbox bar，其他Status只有逐列checkbox。Descendant affected-set batch仍是另一個未完成scope。
- unknown outcome readback，不盲目 retry。
- statistical and itemized report persistence。
- 與 `codex-retire-sessions` skill 的 parity suite。

Exit criteria：success／Busy failure／unknown／crash recovery 與 failure injection 均有驗證；pinned／pinned descendant 永不被 mutation，running/current writer conflict 由 positive pre-block 或官方 Busy rejection 保持原狀。

## Phase 4 — Permanent delete / Empty Trash

目標：只從 Trash 執行 verified permanent deletion。

狀態：**單筆與checkbox batch Trash → Deleted已完成；既有single／batch人工驗收與持久證據已整理於`DELETE_ACCEPTANCE.md`。**

- [x] 風險分級 confirmation：Archive、Restore 與 Archive ↔ Trash 使用 frozen Preview + explicit Confirm；Permanent Delete 與 Report History clear 保留 typed confirmation token、Copy button 與 destructive affordance。
- [x] exact-ID delete via audited official App Server `thread/delete`。
- [x] 單筆雙 readback，判定 absent / failed / unknown。
- [x] 不宣稱或估算 released disk bytes；Archive仍明確回報 0 B released。
- [x] 單筆 unknown／interrupted readback-only recovery workflow，不重送Delete。
- [x] checkbox batch／Empty Trash exact filtered selection與partial/`batch_not_attempted` report。
- [x] Delete operation-specific protection gate：positive protection與unknown pin／pinned-descendant阻擋；cross-host running/current unknown顯示`attemptMayFail`並允許one-shot request。
- retention policy Preview（自動建立 Preview，不自動確認）。

Exit criteria：不得從 Active/Archive 呼叫 delete；timeout、version drift、partial completion 均有可稽核 report。

## Phase 5 — Multi-agent provider SDK

目標：在不假設共同 semantics 的前提下支援其他 agent system。

- provider discovery and registration。
- capability-driven UI。
- per-provider state mapping documentation。
- provider conformance tests。
- 新增獨立的 ChatGPT conversation provider：Chat／Work 與 Codex 雖位於同一個桌面 App 並共用 OpenAI 帳號，仍須使用各自的 inventory、identity namespace 與 lifecycle semantics；不得把 Codex App Server `thread/list` 視為一般 ChatGPT conversation history。
- 在 ChatGPT 沒有可驗證的官方 conversation lifecycle interface 前，相關 inventory 與 Archive／Delete capability 一律標示 unavailable，不讀寫 ChatGPT 內部資料庫、cache 或其他私有檔案。
- mixed-provider batch remains prohibited unless future transaction semantics can prove safety。

Exit criteria：至少第二個 provider 完成 read-only；若第二個 provider 為 ChatGPT，必須證明 inventory 不混入 Codex history；其 mutation 必須另行通過 safety review。

## Phase 6 — Distribution and operations

- sandboxed frontend + scoped helper/XPC architecture。
- [x] Local ad-hoc signed DMG script、mounted-content readback 與 SHA-256 output。
- [x] Public app target 移除 Fixture product mode：啟動直接進 Codex Live，不顯示 Fixture/Live switch，shipping target 不可到達 `FixtureSessionProvider`；Fixture support拆到獨立target，只留在 deterministic tests 與內部開發 harness。
- Developer ID signing、notarization、Universal 2 decision、clean-Mac acceptance 與 auto-update。
- privacy disclosure and diagnostics export。
- observability without conversation-content leakage。
- backup/restore UX。
- compatibility matrix and release rollback。

## Long-term relationship with the skill

在 app 未達 parity 前，`codex-retire-sessions` skill 是真實操作 fallback。當 app 成為 canonical manager 後，skill 應縮成：

- 呼叫 app/helper 的同一 typed API，或
- 只做自然語言 selection → Preview request。

skill 與 app 不應各自維護 Trash membership 或 report ledger，避免雙重 source of truth。
