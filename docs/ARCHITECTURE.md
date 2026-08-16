# Architecture

## 1. 目標與邊界

Agent Session Manager 提供跨 agent system 的 lifecycle UI，但不把各 provider 的內部資料格式當成共同 API。共同層只定義使用者意圖、可驗證狀態與安全 invariant；每個 provider adapter 負責把這些意圖映射到官方支援的 lifecycle operation。

Phase 0 的目標是驗證：

1. Archive 與 Trash Bin 能否在 UI、資料模型與轉換上清楚分開。
2. Preview → Confirm → Execute → Readback → Report 是否可成為所有 mutation 的固定管線。
3. pinned / running / current / descendant protection 是否能在 core 層 fail closed。
4. 多 agent 架構是否能在不稀釋 provider 差異的情況下擴充。

Phase 0 不含 live discovery、persistence、background process 或真實刪除。Phase 1 已加入 opt-in read-only discovery；Phase 2 已把 manager-owned SQLite v8 schema/migration、typed repositories、reconciliation 與 snapshot coordinator 接到 Live refresh；v6凍結working directory，v7新增verified Delete後的durable Deleted tombstone，v8允許一份batch Report關聯多筆tombstone。Phase 3已接上production-facing單筆與checkbox batch Archive／Restore／Delete facade及Active ↔ Trash membership finalization；Archive不能直接Delete，只有Manager Trash可進入Delete Preview。

## 2. 元件分層

```text
SwiftUI App
  ├─ Sidebar / Table / Inspector
  ├─ Preview Sheet
  └─ Operation Report
          │
          ▼
SessionManagerModel (@MainActor)
          │
          ▼
AgentSessionManagerService (actor)
  ├─ routes by namespaced manager key
  ├─ rejects mixed-provider batches
  └─ aggregates provider inventory
          │
          ▼
SessionProvider protocol
  ├─ CodexAppServerProvider (shipping read-only inventory)
  └─ OtherAgentProvider (future)

AgentSessionManagerFixtures (separate test-support target)
  ├─ FixtureSessionProvider
  ├─ FixtureOperationHistoryLedger
  └─ not linked by the shipping Xcode App target

SQLiteStateStore (Core, wired to Codex Live)
  ├─ manager lifecycle metadata only
  ├─ transaction migration + backup/restore
  ├─ typed checkpoint / Trash / Preview / Report repositories
  ├─ read-only backup retention / physical compaction assessment
  └─ no conversation body / no provider private state

SessionStateReconciler (pure Core, presented by Live read-only mode)
  ├─ live inventory + SQLite Trash membership
  ├─ normal / conflict / unavailable classification
  └─ no SQLite write / no provider lifecycle call

SessionSnapshotCoordinator (Core, wired only to Live read-only refresh)
  ├─ provider sessions() → typed diagnostics
  ├─ canonical inventory + exact parent/native-state graph hash
  ├─ complete snapshot → atomic checkpoint commit
  └─ partial / failure / stale → no authoritative state advance

SessionOperationPlan (pure Core)
  ├─ manager intent → optional native lifecycle request
  ├─ manager intent → optional Trash membership mutation
  └─ invalid source collection → fail closed before Preview

ArchiveAffectedSetPlanner (pure Core; single-root path wired)
  ├─ freezes selected root + every descendant from the exact scope graph
  ├─ persists role / parent / depth + canonical affected-set hash in SQLite v2
  └─ incomplete graph/state/protection or drift → no prepared Preview

ArchiveBatchAtomicityPolicy (pure Core, dormant)
  ├─ one complete affected set = one provider execution unit
  ├─ all-unit preflight → deterministic sequential execution
  └─ first failure/partial/unknown stops; remainder = explicit notAttempted

ArchiveMutationExecutor (Core internal)
  ├─ separate mutation transport; not owned by the read-only provider
  ├─ frozen manifest + full preflight + one Archive request + fresh readback
  └─ reachable only through the internal authorization coordinator or tests

ArchiveAuthorizationCoordinator (Core internal)
  ├─ persist prepared Preview → atomic claim as executing
  ├─ invoke executor once → persist Report + consume Preview atomically
  └─ unresolved executing record blocks blind replay after crash/write failure

ArchiveExecutionRecoveryReconciler (Core internal, readback-only)
  ├─ validates original checkpoint + frozen manifest
  ├─ owns inventory readback capability only; no archive()
  └─ atomic success/unknown Report repair or leaves executing unchanged

CodexNativeArchiveCoordinator (public production facade)
  ├─ App-visible prepare / execute only; no generic mutation transport
  ├─ exact coordinated snapshot + SQLite Preview binding
  └─ SwiftUI Preview / explicit Confirm / success-failure-unknown Report

RestoreMutationExecutor + CodexNativeRestoreCoordinator
  ├─ manager Archive only; exact Archived identity + complete inventory/runtime
  ├─ one thread/unarchive request + fresh Active readback; no automatic retry
  └─ readback-only interrupted-execution recovery; manager Trash excluded
```

### SwiftUI layer

只負責selection、filters、使用者操作與呈現。UI不直接呼叫agent CLI，不存取agent session files，也不自行推導native state。Sidebar最上方是必選且獨立的Agent System filter，不提供All Agents；目前固定有`Codex Live`，未來Claude provider可並列。Status啟動時預設Active，並可和Agent System及一個`SidebarBrowsingScope`交叉套用；`SidebarBrowsingScope`只表示Project、Trust Folder或Working Folder，三者彼此互斥。這是provider browsing UI，不會把Fixture重新連回shipping target。`SidebarMetrics`在session／status／scope變動時以一次bounded scan建立各status、system、project與folder counts，render不為每個sidebar row重掃inventory。

### Application model

`SessionManagerModel` 是 MainActor state owner。它固定使用Codex Live，持有畫面所需的 inventory、selection、Preview、Archive readiness、Report 與錯誤狀態。Archive先呼叫純Core readiness assessor，全部permits attempt後才透過`CodexNativeArchiveCoordinator`建立persisted Preview與執行explicit confirmation。Active → Trash使用同一Archive facade但凍結`.add` intent。Restore接受stable Archive或Trash rows；Trash會凍結`.remove` intent與membership set，成功後才移除。

`AgentSessionManagerAppTests`是standalone Xcode unit-test target，直接把同一份production
`SessionManagerModel.swift`編入test bundle並連結Core。它沒有App host，不包含App entry point或
`ContentView.task`，因此固定驗證不會建立視窗、reload live inventory或連Codex。shared scheme的
Test action同時build完整shipping App並執行model狀態測試，補上`swift test`只涵蓋Core的缺口。

### Core service

`AgentSessionManagerService` 是 provider registry 與 routing boundary：

- manager key 使用 `<agent-system>:<native-session-id>` namespacing。
- 一個 operation 不允許跨 provider batch。
- provider 未註冊時回報 unavailable，而不是猜測 fallback。
- `AgentSessionManagerService` 不知道 provider 的 JSONL、private SQLite 或 App Server transport 細節。`SessionManagerModel` 在第一次live reload建立隔離的manager-owned `SQLiteStateStore`與coordinator；SwiftUI不直接執行SQL。

### Provider adapter

`SessionProvider` 暴露三個操作：

```swift
func sessions() async throws -> [AgentSession]
func preview(operation: SessionOperation, managerKeys: [String]) async throws -> OperationPreview
func execute(preview: OperationPreview, confirmationToken: String) async throws -> OperationReport
```

Core 的 `confirmationToken` 是一次性 Preview credential，綁定 exact frozen selection 與 claim；不代表每個 UI action 都要求使用者手動輸入。可逆 lifecycle 由 model 在使用者按下 Confirm 後傳入 internal credential；Permanent Delete 等不可逆 action 才接受 typed token。

`CodexAppServerProvider`只實作`sessions()`與diagnostics；`preview()`／`execute()`固定回報unsupported，production mutation只能走operation-specific facade。Fixture provider是獨立`AgentSessionManagerFixtures` target內的in-memory reference implementation，只供deterministic tests與內部harness。未來provider必須保持相同contract，但Preview與Execute前後都要從runtime重新解析可驗證狀態。

### Codex read-only transport

`CodexAppServerClient` 每次 refresh 啟動一個 app-owned `codex app-server --listen stdio://` child process，完成 `initialize` / `initialized` handshake 後，inventory 只呼叫 `config/read` 與 `thread/list`；使用者明確開啟 Conflict Review 時才另起 read-only transport 呼叫 `thread/read(includeTurns=false)`。另外只讀 `<codexHome>/.codex-global-state.json` 的 Desktop `local-projects` 專案目錄；這不是 session lifecycle state，也不作任何寫入：

- 主表的 active 與 archived 各自沿 server `nextCursor` 重複 request，直到 cursor 為 `null`，並只讀穩定的 interactive sources：`cli`、`vscode`。
- 另一組 active / archived inventory 使用本機 stable schema 的完整 `ThreadSourceKind`，包含 sub-agent kinds，只建立 descendant graph，不把子 threads 加進主表。
- `useStateDbOnly=true`，不啟用預設 JSONL scan-and-repair。
- 每頁 50 筆；四個 collection 各自最多 200 頁／10,000 筆。All-source 任一 collection 截斷時 descendant count 顯示 unavailable，provider 標記 degraded。
- 跨頁 native ID 去重；若 active / archived 兩次查詢之間發生外部漂移，較晚觀察到的 archived state 優先，避免 duplicate-key crash。
- read-only provider transport 沒有公開 generic request API，也無法取得 mutation protocol；另一個 module-internal `CodexArchiveSource` 只由受限 Archive facade 內部持有。

位置資料不混用：

- Project 僅來自 Codex Desktop `local-projects`；sidebar 保留完整 catalog 與 `project-order`，session 則以最長 project root ancestor 配對 `Thread.cwd`。Catalog 不可用或無匹配時就是 unavailable。
- Working Folder 直接使用 `Thread.cwd`，不稱為 Project。
- Trust Folder 來自 `config/read` 的 `projects.<path>.trust_level`，以最長 ancestor path 配對 session cwd。
- Git origin 是 repository metadata，不作為 Project 的 fallback。
- `config/read` 不可用時 trust 顯示 unavailable，不把 cwd 推定為 trusted。

stdout 使用 `poll(2)` + POSIX `read(2)`，每個 request 有獨立 deadline；child shutdown 有界。完整相容性結果見 `APP_SERVER_COMPATIBILITY.md`。

安全狀態使用不對稱證據：`Thread.status.type == active` 可正向標記該 session running；其他 status 不能排除另一個 Desktop/App Server process 正在執行，所以維持 unknown。Pin 由 Codex Desktop `pinned-thread-ids` 的 inventory 前後一致快照供應，若未來 `Thread.isPinned` 同時出現則必須相符。Descendant count 只有 all-source graph 完整時才 verified；pinned-descendant 還同時要求每個 descendant 的 pin state 已知。詳細結論見 `SAFETY_STATE_AUDIT.md`。

## 3. 核心資料模型

### Native state 與 manager collection

`NativeSessionState` 描述 provider 可觀察到的狀態：

- `active`
- `archived`
- `absent`
- `unavailable`

`SessionCollection` 描述使用者在 Agent Session Manager 中看到的 collection：

- `active`
- `archive`
- `trash`
- `deleted`
- `unavailable`

在 Codex 的預期 mapping 中，Archive 與 Trash 可能同樣對應 native `archived`。差異來自 manager-owned Trash membership：

```text
native active                             → Active
native archived + trashMembership=false  → Archive
native archived + trashMembership=true   → Trash Bin
native absent                             → Deleted
```

這個 mapping 是刻意的折衷：Codex 沒有原生 Trash Bin，所以 app 用一份 machine-readable state 記錄「這個 archived session 是保留，還是待刪」。它不是人工維護的 CSV / Markdown 清單。

`SessionOperationPlan` 進一步把 manager collection 轉換與 provider side effect 分開：Active → Archive/Trash 才需要 native Archive；Archive → Trash 與 Trash → Archive 只增刪 manager Trash membership；Archive/Trash → Active 需要 native Unarchive；只有 Trash → Deleted 能使用 native Delete。Capability check 依實際 plan 評估，不會因 Archive → Trash 而錯誤要求 native Archive capability。

Archive → Trash 與 Trash → Archive 已有獨立 `ManagerOnlyOperationCoordinator` production path。它不持有 `SessionProvider` 或 lifecycle transport，因此型別上無法送 `thread/archive`、`thread/unarchive` 或 `thread/delete`。Preview 會凍結完整 manager key/native ID、checkpoint inventory hash、runtime、expiry、protection hash 與 distinct manager intent；確認時 SwiftUI 先完成一次新的官方 inventory refresh。只有 complete inventory 能繼續，SQLite 再驗證 checkpoint hash、manifest、selection membership 與 protection。membership 變更、逐筆 Report 和 Preview consumption 在同一 transaction；commit 後重新讀回三者，不能以空回應推定成功。

### Session protection

`SessionProtection` 包含：

- `isPinned`
- `isRunning`
- `isCurrent`
- `hasPinnedDescendant`

每個 protection field 另有 `Known` 狀態。未知或 unavailable 不等於 `false`，並會 fail closed 阻擋危險 mutation。

`ProtectionEvidenceBuilder` 把 value + Known 投影成不含歧義的三態 evidence：

- `Protected`：已知且 protection 成立。
- `Verified clear`：已知且 protection 不成立。
- `Unavailable`：缺少權威來源；即使底層 Bool 是預設 `false` 也不能當成 clear。

Codex evidence 同時保留來源：pin 接受 `thread/list.isPinned` 或通過雙讀一致性驗證的 Desktop `pinned-thread-ids` provider-persistent-state snapshot，雙來源不一致時 fail closed；running 只接受本 process 的 `status.active` 正向證據；pinned descendant 必須有完整 all-source graph 且所有 pin 值已知；current task 在沒有跨 host 權威欄位時維持 unavailable。Inspector 直接顯示 verdict、source 與理由。

任何一項成立時，Archive、Move to Trash、Delete Permanently 都應 fail closed。Restore 與 Trash → Archive 是離開危險狀態，因此可以允許，但 live adapter 仍需 readback。

### Provider capabilities

`SessionCapabilities` 不假設每個 agent 都能 list / archive / unarchive / delete，也不假設能讀出 pinned / running / descendants。Native lifecycle interface 與 manager execution capability 是不同欄位：本機 0.147.0 generated schema 可讓 `hasNativeArchiveInterface` 成立，但 `canArchive` 仍為 false。UI 必須依 capability 禁用執行；若保護資訊不可驗證，mutation 不應被視為安全可用。

`ProtectionAuthorityPolicy` 是 protection boolean 前的 authority boundary。每筆 observation 明確帶 source 與 scope（fixture provider、provider persistent state、manager process、complete provider graph、all relevant hosts）。合法的窄 scope `true` 足以保護，因為已觀察到風險；`false` 只有在 scope 覆蓋該欄位完整權威範圍時才會轉成 known clear。Codex pin 可由 provider persistent state clear，pinned descendant 可由 complete graph + complete pin states clear，但 running/current 的 clear 必須來自 all relevant hosts；manager-owned App Server 的 non-active 絕不會解鎖。Source/kind/scope mismatch 或 duplicate observation fail closed，Codex mapping 若解析失敗則維持 unavailable。Operation-specific execution policy 可以在不把 unavailable 偽裝成 clear 的前提下，將 allow-listed Archive 的 running/current/writer unknown 表示為「可能被 provider 以 Busy 拒絕」；pinned 與 pinned descendant 不適用這項例外。

### Live Archive readiness gate

`ArchiveMutationReadinessAssessor` 是純 Core、無副作用的第一個 Phase 3 gate，只評估一個 active Codex root session。它凍結目前 exact selection 的 evidence view，逐項檢查 stable reconciliation、完整 inventory/checkpoint、相同 runtime version 與非空 inventory hash、已 allow-list 的 `thread/archive` contract、`thread/read`、writer authority、pinned/running/current/pinned-descendant protection，以及零 descendants。最後一項獨立檢查 manager executor。

`LifecycleWriterAuthorityEvidence` 與 running status 分離，必須綁定完整 native ID、目前 runtime、完整 inventory hash 及不早於 authoritative checkpoint 的 observation。只有持有該 writer domain 的官方 lifecycle host，或真正涵蓋 all relevant hosts 的 authority，才能回報 `verifiedClear`；另一個獨立 App Server process 的 `idle`、`notLoaded`、`thread/loaded/list` 或 readback success 都不能產生這份 evidence。現行 provider 每次以 stdio 啟動獨立 App Server，所以 readiness 固定顯示 Writer authority unavailable；這仍是正確的 evidence 顯示，但不再被視為官方 Archive API 永遠不可呼叫的理由。

`LifecycleMutationReadiness.isEvidenceReady` 刻意不包含 executor，方便區分「runtime evidence 已足夠」與「app 已獲准執行」。Typed `attemptMayFail` 讓 writer/running/current unknown 保持可見但不冒充 satisfied，並且只適用於 allow-listed `thread/archive`、一次 request、fresh readback 與 no-retry contract；positive evidence 仍 blocked，pinned／pinned-descendant unknown 仍 unavailable。`isExecutionEnabled` 只有在所有項目都為 satisfied/attemptMayFail 且 executor satisfied 時成立。Live store 建立後 App 會建構受限的 production facade，所以 executor item 可 satisfied；雙讀一致的 Desktop pin snapshot 已讓 eligible non-pinned root 通過 pin gate；任何 pinned session、pinned descendant、pin drift 或 pin source conflict 仍停在 readiness。Runtime contract 採 exact-version allow-list；未知、較舊或未重新稽核的未來版本一律 unavailable。

`ArchiveAffectedSetPlanner` 把 descendant 操作的 selection 從「root + count」提升為精確結構。`CodexAppServerProvider` 從同一次 all-source inventory 保留每個 native ID 的 parent 與 Active/Archived state，`SessionSnapshotCoordinator` 將完整 graph 納入 checkpoint hash。只有 inventory/graph 完整、root 為 Active、每個 affected item 的 pinned 與 pinned-descendant evidence 都已知且所有 positive protection 都為 false 時，internal factory 才能產生 prepared Preview；running/current unknown 會保留在 protection hash 中，但不再因 aggregate `protectionComplete=false` 阻止 allow-listed Archive attempt。SQLite v2 會原子保存每筆 role、parent、depth 與 canonical `affectedSetHash`。Graph、state 或持久化資料被改動時會 fail closed。SwiftUI 目前只建構零 descendant 的 single-root Preview；descendant affected-set 仍沒有 UI，而且 single-item executor 在任何 provider request 前明確拒絕它。

`ArchiveBatchAtomicityPolicy` 定義 provider 沒有 native batch transaction 時的誠實語意。每個 selected root 與其完整 affected set 是不可拆分的 execution unit；所有 units 必須先以同一 frozen checkpoint 完成 preflight，之後才按 root manager key deterministic 執行。第一個 failure、affected-set partial 或 unknown 後立即停止，不嘗試 rollback 已成功的 provider request，也不繼續擴大不確定範圍。Finalization 保留 batch outcome、每個 root unit disposition 與每個 affected item readback；未執行的 unit/item 使用獨立 `notAttempted`，不冒充 failure 或 unknown。SQLite v3 會原子保存 canonical batch plan／units／items／report，claim 時同時把所有 member Previews 改為 `executing`，finalize 時再依 exact frozen sets 一次 consume；member Preview 不能改走 single-item claim/report API。Policy/persistence 不持有 transport、不呼叫 provider，也還沒有 executor、history/UI 或 App construction path。

### Native Archive executor contract

`ArchiveMutationExecutor` 與 `ArchiveMutationTransport` 都是 Core 的 internal 型別，App target 不能建構。第一個 slice 只接受一份已由 SQLite claim 的 `executing` Preview 與一個 active Codex root session；它重新計算 runtime/reconciliation-bound canonical manifest、驗證 confirmation hash、要求完整且未漂移的 inventory checkpoint，並拒絕任何 descendant。Preflight 使用 operation-specific protection：positive pinned/running/current/pinned-descendant 一律阻擋，pinned 或 pinned-descendant unknown 也阻擋；running/current unknown 保留為風險，允許送出一次正式 request。正式 payload 僅能經獨立的 `CodexArchiveSource` 送出一次 `thread/archive(threadId:)`。

RPC acknowledgement 不是成功證據。Executor 不盲目 retry，且只接受晚於 mutation attempt、完整、相同 runtime、相同完整 native ID 的 inventory readback；Archived 才是 success，明確 RPC rejection 加 Active readback是 failure，其餘 stale、timeout、missing identity 或未觀察到 Archived 都是 unknown。2026-08-13 的 isolated acceptance 顯示 Desktop task 即使呈現 `idle` 仍可能持有 rollout writer；獨立 App Server 回覆 `-32600` 且 readback 保持 Active。OpenAI upstream 的同型 archive test 把 writer ownership conflict 回報為 `thread <id> already has an active writer`，但本次舊 Report 未保存原始 message，因此這是最強診斷而不是本次逐字證據。Executor 只在 server message 逐字符合時保存為 `archive_request_busy_active_writer`，並保留完整 message；writer 釋放後仍須新 Preview／新確認，不自動 retry。Synthetic fake-process payload、failure injection 與 production-facade tests 已涵蓋 success、Busy failure 與 pin-unknown pre-block。

`ArchiveAuthorizationCoordinator` 把 persistence 變成執行的必要前置條件：先原子保存 prepared Preview，再由 SQLite transaction 核對 exact record、expiry、完整 inventory checkpoint、operation-specific protection eligibility 與 inventory hash，並只把 `prepared` claim 成 `executing` 一次。Executor 只接受 claimed `executing` Preview。完成後，success、failure、unknown 都用既有 repository 原子保存 itemized Report、填入 frozen items 並 consume Preview。若 native request 後 App crash 或 Report 寫入失敗，`executing` record 保留且不能再次 claim；它必須由後續 reconciliation 解決，不能重送 Archive。Public `CodexNativeArchiveCoordinator` 是 App 唯一能建構的 production boundary；它封裝 internal authorization／transport，驗證顯示中的 Preview 與 SQLite frozen record 完全相符，並只公開 prepare/execute。

`ArchiveExecutionRecoveryReconciler` 是獨立的 audit repair boundary。它只依賴 `ArchiveExecutionRecoveryReadback`；production implementation 持有 read-only `CodexInventorySource`，無法取得 `CodexArchiveSource` 或呼叫 `archive()`。Recovery 先確認 SQLite 仍保留 claim-time inventory checkpoint，並用它重算包含 `affectedSetHash` 的 frozen manifest；aggregate `protectionComplete` 可以是 false，因為 mutation 已經發生或 outcome 未知，此處只能 readback，不能再送 request。之後只接受完整、同一 allow-listed runtime、晚於 Preview 的 official inventory。Exact Archived 補寫 success；仍 Active 或完整 inventory 未回傳 exact ID 則補寫 unknown，且不把 list absence 宣告為 deleted；incomplete、stale、runtime/checkpoint drift 或 unavailable 則完全不寫並保留 `executing`，允許之後再做唯讀 readback。

Native Archive／Restore 的送出前 preflight 以 frozen exact-item evidence 為 drift boundary，而不是要求
fresh provider inventory hash 與 Preview 時完全相同。全 inventory hash 含其他 sessions 以及 title、
updatedAt 等非授權欄位，只負責 durable snapshot／manifest binding；preflight 仍硬性重驗 target ID、
native state，Archive 另重驗完整 protection hash 與 descendant scope。無關 session 活動或標題更新
不再阻擋 exact-ID lifecycle request。

App 已透過 `CodexNativeArchiveRecoveryCoordinator` 接上這條路徑。`SessionSnapshotCoordinator` 先回傳 `.skippedExecutingRecovery` 並保留 claim checkpoint；recovery facade 取得 bounded exact executing Preview set，只有一筆 production-supported single-root 時才沿用該次 official snapshot 補寫 Report。成功 consume 後，App 再做一次 normal refresh 推進 checkpoint並顯示帶有 recovered 標記的 Report。零筆不寫；多筆、batch、manifest/runtime/evidence 不符都 fail closed，不選第一筆、不重送 Archive。

### Native Restore executor contract

`RestoreMutationExecutor` 與 `CodexRestoreMutationTransport` 是另一組 Core internal boundary，只能由 public `CodexNativeRestoreCoordinator` 建構。它接受 `nativeState=archived` 的單一 manager Archive 或 Trash session；Preview 凍結 exact manager/native ID、Archived state、runtime、inventory hash、canonical manifest、expiry 與 confirmation hash。Trash → Active 另以 SQLite v5 欄位保存 `.remove` intent，並把完整 Trash membership set hash綁進 frozen item。Restore 是離開保留狀態的可逆操作，因此不套用 Archive-only pinned/running/current/descendant prohibition，但完整 inventory、相同 allow-listed runtime、未漂移 exact identity與 Archived state仍是必要條件。

Claim 後最多送一次 `thread/unarchive(threadId:)`。較新的完整 readback 精確顯示 Active 才算 success；明確 RPC rejection且仍 Archived是 failure；timeout、stale、missing identity、acknowledged-but-still-Archived或其他無法證明結果一律 unknown，不自動 retry。`CodexNativeRestoreRecoveryCoordinator` 共用只讀 lifecycle recovery reconciler：Active 可補寫 success，仍 Archived則補寫 unknown，永遠不能重送 `thread/unarchive`。

Active → Trash 以 `.moveToTrash + .add` 保存複合意圖，先執行同一受限 native Archive；只有 fresh Archived readback success 才在 `saveOperationReport` transaction加入 membership。Trash → Active 則以 `.restore + .remove` 保存意圖；只有 Active success 才在同一 transaction驗證 frozen membership set、移除 exact membership、寫 Report並 consume Preview。Failure/unknown完全不改 membership。若 native request 後 App 中斷，executing Preview保存意圖；readback-only recovery只能依新 inventory完成相同 finalization，不能重送 Archive／Restore。

### Native Permanent Delete executor contract

`CodexNativeDeleteCoordinator` 的單筆路徑只接受已有durable Manager Trash membership、native state仍為Archived、pin與pinned-descendant evidence已知且clear、沒有positive running/current signal、零descendant的Codex session。`CodexNativeBatchCoordinator`套用相同逐筆資格，將整個checkbox selection凍結為一份multi-item Preview。跨lifecycle host無法取得running/current negative evidence時不偽裝成clear，而是以`attemptMayFail`警告允許一次正式Delete；positive protection仍一律阻擋。Archive row無法直接建立Delete Preview；必須先用獨立manager-only Preview移到Trash。Preview凍結exact manager/native IDs、runtime/checkpoint、完整membership-set hash、working directories、manifest、expiry與destructive token。

Claim後每個item最多呼叫一次audited `thread/delete(threadId:)`，不因timeout、acknowledgement error或未知結果重送。Batch先以一份fresh inventory完成全批preflight，再依frozen manager-key順序執行；第一個failure／unknown後不再送後續request。Success需要同一allow-listed runtime的較新complete active+archived inventory省略exact ID，且`thread/read`同時回傳精確`-32600 / thread not loaded: <id>`。只有success items會在同一SQLite transaction移除Trash membership並建立v8 Deleted tombstone；同一batch Report ID可關聯多筆tombstone。所有item結果與Preview consume一起提交，released bytes永遠標示incomplete/unknown。

`CodexNativeDeleteRecoveryCoordinator`只持有read-only inventory/exact-read source，沒有Delete mutation interface。Interrupted executing Preview只有雙absence證據完整時補寫success；雙Present可補寫unknown；evidence unavailable/contradictory則保留executing供下次唯讀recovery，絕不重送Delete。

### Native checkbox batch contract

Native batch以單一multi-item `PersistentOperationPreview`保存exact selection與一個confirmation token，claim會一次把整份Preview切到`executing`。第一個provider request前，fresh complete inventory必須逐筆證明identity、source native state及operation-specific protection皆未漂移；任一item不合格時整批`batch_preflight_rejected`且零request。Codex沒有跨thread transaction，因此執行採deterministic sequential prefix；第一個failure／unknown後，剩餘items寫入`batch_not_attempted`，不會縮小selection後繼續。先前成功item仍按readback結果提交membership/tombstone，Report outcome為partial或unknown，不宣稱rollback。

中斷時`CodexNativeBatchCoordinator.recoverPending`只分類新的完整inventory（Delete另要求exact-read absence），沒有archive/unarchive/delete replay路徑。Archive與Trash、Trash與Archive的manager-only多選仍由既有單一SQLite transaction處理，沒有provider request。

## 4. Lifecycle state machine

```text
Active ── Archive ───────────────▶ Archive
  │                                  │
  └──── Move to Trash ───────┐       └── Move to Trash
                             ▼
                         Trash Bin
                          │      │
              Restore ────┘      └──── Move to Archive
                 ▼                         ▼
               Active                    Archive

Trash Bin ── Delete Permanently ──▶ Deleted
```

不允許：

- Active → Deleted
- Archive → Deleted
- Deleted → 任一 collection（未來若 provider 有 recovery，必須定義另一套 semantics）
- Protected session → Archive / Trash / Deleted

Archive → Trash 不需要先 Restore。Trash → Archive 只改 manager intent，不需要 native unarchive。

## 5. Mutation transaction

每次 mutation 都分成兩個明確階段。

### Preview

1. 解析精確 namespaced IDs。
2. 拒絕空 selection 與 mixed-provider batch。
3. 讀取當下 native state、manager state、protection 與 descendants。
4. 驗證 capability 與 state transition。
5. 凍結 item manifest，包含完整 ID、title、project identity、working directory、before、target 與可測大小。
6. 產生 internal one-time Preview credential、warnings 與統計；只有不可逆 action 將 credential 顯示為 typed confirmation token。

Preview 不是「試執行」，也不會 mutation；它是使用者確認的 frozen manifest。

### Execute and readback

1. 驗證 internal credential 與 Preview identity；不可逆 action 額外要求使用者輸入 exact token。
2. 重新確認每筆狀態與 protection 未漂移。
3. 若任一筆漂移，整批停止，不做部分 mutation。
4. 呼叫 provider 官方 lifecycle operation。
5. 重新 list/readback 每筆 native state。
6. 只有觀察到 target state 的項目標記 success。
7. 產生 total / success / failure / bytes / itemized report。

Test-only Fixture provider在同一actor內模擬完整mutation contract。Production App的inventory provider仍是read-only；native Archive／Restore只能經各自受限facade。Archive pipeline已接Preview-first claim、Report-after transaction與readback-only unresolved execution recovery。Active → Trash沿用此native Archive pipeline並以durable `.add` intent延後membership finalization；Manager Archive／Trash → Active沿用Restore one-shot/readback/recovery管線，Trash以durable `.remove` intent完成success-only原子finalization。

`FixtureOperationHistoryLedger`只存在test-support target；它在Fixture operation成功回傳後，把 Preview／Report 轉成與 SQLite history 相同的 `OperationHistoryEntry`。它以 lock 保護 process-local memory、每 provider 最多 500 份，支援相同 filters/search/keyset/export，且沒有 serialization 或 SQLite API。完整 native ID 保留；working directory、confirmation token 與 hashes 不進 ledger；因 fixture 沒有實際 disk mutation，released bytes 永遠標記 incomplete。test process exit時自然清空。使用者可對目前查詢結果建立 exact-ID clear Preview；確認 token、單一 provider 與 frozen Report ID set 會在 model／SQLite boundary 再次驗證，並以單一 transaction 刪除完整 consumed Report／Preview／Items bundles。選取漂移或中途錯誤會 rollback；checkpoint、Trash membership、prepared/executing Preview 與 provider sessions 都不在刪除範圍。

`DiagnosticLogStore` 是與 lifecycle SQLite 分離的App-owned actor。它以JSONL保存App launch、inventory refresh、Preview、execution、recovery、storage與bounded error events，並採30天、10,000筆、20 MiB任一先到即移除最舊event的retention。平時append；遇到retention或corrupt line時原子重寫retained set，檔案權限固定0600。Metadata限制32組、key 64字元、value 1,024字元，token/payload/conversation/prompt/body/content key直接排除；message上限4,096字元。Settings只把這份timeline當diagnostics，Report History仍是唯一lifecycle audit outcome authority。

## 6. Manager-owned persistence

建議 canonical app state。目錄使用 bundle ID，避免 display name 改名造成 state path 漂移：

```text
~/Library/Application Support/com.sean.AgentSessionManager/
  state.sqlite
  diagnostic-events.jsonl
  state.sqlite.backup-v<version>-<timestamp>-<uuid>.sqlite3
  state.sqlite.pre-restore-<timestamp>-<uuid>.sqlite3
```

目前 target `ENABLE_APP_SANDBOX=NO`，所以解析結果是上述 home-relative path；`StateStoreLocation` 已透過 `FileManager` 解析 Application Support。若正式 distribution 改成 sandbox，會自然解析到 container 的 Application Support，不能另行硬編碼路徑。

Phase 2 v3 schema 已建立：

- `provider_checkpoints`: inventory hash、runtime version、completeness 與 diagnostics。
- `trash_memberships`: provider key、完整 native ID、進入 Trash 時的 metadata 與 reconciliation time。
- `operation_previews`: frozen manifest header、expiry、inventory/affected-set hash 與 confirmation-token hash。
- `operation_items`: 每筆 frozen expected state、affected-set role/parent/depth 與執行後 observed/readback evidence。
- `operation_reports`: execution/readback result summary。
- `archive_batch_plans`: canonical batch manifest、checkpoint/token binding、status 與 unit/item counts。
- `archive_batch_units`: deterministic root order、member Preview／affected-set binding 與 unit disposition。
- `archive_batch_items`: exact affected item identities、item disposition 與 readback evidence。
- `archive_batch_reports`: batch-level terminal outcome、counts、timestamps 與 errors。

資料庫只保存manager intent與audit evidence，不成為native session是否存在的唯一真相，也不保存conversation body。一般checkbox native batch使用同一份multi-item operation Preview／Report，因此既有history query/export/UI與retention會完整涵蓋；SQLite v3 descendant affected-set batch evidence仍未映射到history UI。Operation history以provider為界，預設保留最新500份完整Report／consumed Preview／Items bundle，並可依provider／operation／outcome／時間與identity/title/project/error code搜尋。Backup maintenance只產生verified、0600、age/count-bounded candidates與typed protected reasons，沒有自動mutation。完整contract見`SQLITE_SCHEMA.md`。

## 7. Reconciliation

Live inventory 可能在 app 外被 archive、restore 或 delete，因此啟動與 refresh 時必須：

1. 從 provider 取得當下 inventory。
2. 以 `<provider, nativeID>` 對上 local membership。
3. native active 但仍在 Trash membership：標記 conflict，禁止 delete，要求人工選擇 Restore intent 或重新 Retire。
4. native absent 且有 pending Trash membership：標記 externally missing；沒有 authoritative exact-ID readback 時不得宣告 Deleted。
5. native archived 且無 Trash membership：顯示 Archive。
6. manager state 找不到 provider record：顯示 unavailable，不自行宣告 Deleted。

Core reconciliation matrix 與 snapshot coordinator 已實作、測試並接到 Live refresh。只有完整 inventory 才能把未觀察到的 Trash membership 分類為 externally missing；不完整 inventory 一律 unavailable。Archive 類 operation 使用 operation-specific protection contract；Restore 仍要求 exact state/readback，但不套用破壞性 clearance gate。

SwiftUI 使用 `SessionPresentation` 顯示 reconciliation result：`native active + Trash membership` 是 Conflict；membership-only row 可顯示 Externally Missing 或 Unavailable，並保留完整 native ID。它們不會被壓回普通 `AgentSession.collection`，也不會被宣告 Deleted。

`ConflictResolutionPlanner` 建立 resolution proposal。Active + Trash 顯示 Accept Native Restore 與 Reapply Trash Intent；Externally Missing 顯示 Keep Pending 與 Acknowledge External Deletion。Proposal 凍結完整 manager key、native ID、checkpoint hash、runtime、reconciliation timestamp、每個選項的必要 evidence 與 blocked reason。

只有 Accept Native Restore 已接 Apply：`ConflictResolutionCoordinator` 不持有 provider 或 transport，將 exact Active session、runtime、inventory hash、整個 manager Trash membership set 與 internal one-time credential 保存成 durable Restore Preview。確認前 SwiftUI 先 fresh official inventory；SQLite transaction 再重算 manifest/membership-set hash，只刪除精確 membership，原子寫入 Active readback Report 並 consume Preview，commit 後逐項讀回。`lastReconciledAt` 的正常 refresh 更新不算 intent drift；其他 membership 實質欄位或 set 變動均整筆 fail closed。Reapply Trash Intent、Externally Missing acknowledgement 仍不可 Apply；list inventory absence 也不等於 authoritative exact-ID deletion readback。

使用者開啟 Conflict Review 時，Codex provider 另以官方 `thread/read`、`includeTurns=false` 讀取完整 ID。成功、response ID 精確相符且 evidence kind 為 `exact_match` 時才證明 Present。Failure 會保留 typed evidence kind 與 RPC code，但不以 error message 字串判斷 absence。`absent` 還必須附 `ExactSessionAbsenceContract`，並讓 provider、精確 runtime version、RPC code、非空 contract identifier 與 HTTPS official source 全部相符，`provesAbsence` 才會成立；Conflict planner 只讀 `provesAbsence`，不信任裸 `.absent` status。0.147.0 尚無官方 not-found discriminator，因此 Acknowledge External Deletion 仍 blocked。

Shipping App啟動後固定使用Codex Live；`SessionManagerModel`以`StateStoreLocation`解析bundle-ID Application Support path，在第一次reload建立store/coordinator，之後每次refresh都走同一coordinator。Bootstrap或reconciliation失敗不fallback到raw inventory或Fixture。Fixture refresh與process-local ledger只存在獨立test target，且不建立production SQLite。

## 8. Process boundary 與 sandbox 方向

正式App已移除Fixture product mode；下一階段process boundary建議拆成：

- sandboxed SwiftUI frontend：inventory、Preview、Report UI。
- narrowly scoped local helper/XPC service：與 agent App Server 溝通。
- helper 只接受 typed lifecycle request，不接受任意 shell command 或任意檔案路徑。

這可縮小 frontend 權限，也讓 provider access、logging、timeouts 與 upgrade compatibility 更容易測試。

## 9. Source layout

```text
macos/AgentSessionManager/
  Package.swift
  Sources/
    AgentSessionManagerCore/
      Models.swift
      SessionProvider.swift
      CodexAppServerProvider.swift
      SQLiteStateStore.swift
      SQLiteStateRepositories.swift
      ArchiveBatchPersistence.swift
      ArchiveBatchStateRepositories.swift
      PersistentStateModels.swift
      SessionStateReconciler.swift
      SessionSnapshotCoordinator.swift
      SessionPresentation.swift
      ConflictResolution.swift
      ExactSessionReadback.swift
      ProtectionAuthority.swift
      StateStoreLocation.swift
    AgentSessionManagerFixtures/
      FixtureSessionProvider.swift
      FixtureOperationHistoryLedger.swift
    CSQLite3/
      module.modulemap
      include/CSQLite3.h
    AgentSessionManager/
      SwiftUI app and views
  Tests/
    AgentSessionManagerCoreTests/
  App/AgentSessionManager/
    AgentSessionManager.xcodeproj
docs/
  ARCHITECTURE.md
  SAFETY.md
  UI_SPEC.md
  ROADMAP.md
  TODO.md
  HANDOFF.md
```
