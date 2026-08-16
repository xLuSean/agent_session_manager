# Codebase 稽核報告

- **日期**：2026-08-15
- **範圍**：整個 repository（Core、App、Tests、docs、scripts）
- **性質**：唯讀稽核。除本報告外未修改任何檔案。
- **稽核基準**：`AGENTS.md` 的 "Non-negotiable safety rules"，逐條尋找程式碼中的強制點（enforcement point），並驗證是否可被繞過。
- **交叉比對**：所有發現皆已對照 `docs/TODO.md` 與 `docs/ROADMAP.md`，已追蹤項目不重複列為發現。

### 修訂記錄

| 版本 | 變更 |
|---|---|
| rev.4 | **擴充 F2**，新增 F2.1–F2.4：記錄「本專案目前無 git remote」這個決定可選方案的前提、三種 CI 方案比較、檢查腳本的必要內容，以及 live 測試不會被誤觸發等實作注意事項。 |
| rev.3 | **新增 F6**（Delete 無 acceptance runbook，且 lifecycle success path 從未對真實 Codex 執行過）。第 0 節加入「現存缺陷 0」的讀法限定與「本報告不是 bug list」聲明；6.1 處理順序納入 F6。 |
| rev.2 | **修正 F3**。初稿依據函式名稱比對，將四個 `CodexNative*Coordinator` 合計 2,536 行整體描述為「近同構重複」。逐一比對實作內容後確認該描述錯誤：實際重複僅約 456 行（三個 Authorization coordinator 的骨架），其餘為需求驅動的真實差異。結論段的處理順位一併調整，F3 由「需審慎評估」改為「建議維持現狀」。 |
| rev.1 | 初版。 |

---

## 0. 摘要

這個 codebase 的安全紀律**紮實且經得起驗證**。`AGENTS.md` 列出的每一條 non-negotiable rule 都能在程式碼中找到對應的強制點，且沒有找到繞過路徑。文件與程式碼之間沒有發現數字或行為上的落差。

主要風險不在核心邏輯的正確性，而在**工程防護網**：App 層有 6,468 行程式碼不在 SwiftPM build 之內、沒有任何測試覆蓋，而且專案沒有 CI。今天這些程式碼是能正常編譯的，所以這是一個「真實但尚未引爆」的缺口。

| 項目 | 結果 |
|---|---|
| 安全不變量稽核 | 9 項全部通過 |
| 發現（未被追蹤） | 6 項（2 高、1 中高、1 中、2 低） |
| 現存缺陷 | **0** |

> ### ⚠️ 「現存缺陷 0」的正確讀法
>
> 本次為**靜態稽核**：App 只經過編譯，從未啟動；未對真實 Codex 送出任何 lifecycle request；`swift test` 中 3 個 skipped 測試正是唯一會接觸真實 Codex 的 live smoke tests。
>
> 因此本報告能證明的上限是「**程式碼表達了正確的意圖，且找不到繞過路徑**」，而非「系統在真實環境中行為正確」。
>
> 依專案自身紀錄，lifecycle 的**成功路徑從未對真實 Codex 完整執行過一次**（唯一的真實世界證據是 2026-08-13 的一次 Archive rejection）。詳見 **F6**。
>
> **本報告不是 bug list。** F1–F6 中沒有任何一項是「程式碼寫錯了」，全部是防護網缺口或知識保存問題；唯一涉及改動程式碼的 F3，本報告明確建議**不要動**。

---

## 1. 基本事實

### 1.1 規模

| 區塊 | 行數 | 檔案數 |
|---|---|---|
| `Sources/AgentSessionManagerCore` | 16,310 | 35 |
| `Sources/AgentSessionManager`（App／SwiftUI） | 6,468 | 17 |
| `Tests/AgentSessionManagerCoreTests` | 11,154 | 30 |
| **合計** | **33,932** | **82** |

最大的五個檔案：

| 檔案 | 行數 |
|---|---|
| `SQLiteStateRepositories.swift` | 2,365 |
| `SessionManagerModel.swift` | 1,925 |
| `CodexAppServerProvider.swift` | 1,503 |
| `SessionTableView.swift` | 1,020 |
| `CodexNativeBatchCoordinator.swift` | 865 |

### 1.2 建置與測試實測結果

兩項都在本次稽核中實際執行過，不是引用文件說法。

**Swift Package 測試**

```bash
cd macos/AgentSessionManager
CLANG_MODULE_CACHE_PATH="$TMPDIR/asm-clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$TMPDIR/asm-spm" \
swift test --disable-sandbox
```

結果：**258 tests executed, 0 failures, 3 skipped**（3 個 skipped 為需要 `AGENT_SESSION_MANAGER_LIVE_TEST=1` 的 live smoke test，屬預期行為）。

**Xcode App target 建置**

```bash
cd macos/AgentSessionManager/App/AgentSessionManager
xcodebuild -project AgentSessionManager.xcodeproj \
  -scheme AgentSessionManager \
  -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/asm-dd" build
```

結果：**BUILD SUCCEEDED，0 warnings**。

### 1.3 其他

- Git：45 commits，工作區乾淨，分支 `main`。
- CI：**不存在**（無 `.github/` 目錄）。
- `dist/`：14 MB，4 個版本的 DMG，未進版控（`.gitignore` 已排除，屬正常）。
- `tmp/`：68 KB，12 份除錯筆記，未進版控（見發現 F4）。

---

## 2. 安全不變量稽核結果

以下逐條對應 `AGENTS.md` 的規則。每一項都附上程式碼證據位置。

### A1 — Unknown 絕不冒充 Verified clear ✅

**規則**：「Provider 不支援或無法確認某項 capability 時，UI 必須顯示 unavailable 並禁止相關 mutation。」

搜尋全樹所有可能把「未知」壓成「否」的預設值（`?? false` / `?? true`），只找到 3 處，方向全部正確：

| 位置 | 內容 | 判定 |
|---|---|---|
| `SessionStateReconciler.swift:171` | `protectionAllowsPreview = session.map { !$0.protection.blocksLifecycleMutation } ?? false` | session 為 nil → `false` → `stable = false` → **拒絕** Preview。fail-closed |
| `SessionPresentation.swift:132` | `descendantCountKnown = live?.descendantCountKnown ?? false` | 無 live session → 「不確定」。同段 `protection` fallback 為四個 `*Known: false`（全 unknown）。fail-closed |
| `SessionTableView.swift:692` | 欄寬追蹤 timer 的 `?? true` | 非安全路徑，UI 行為 |

**結論**：未發現 unknown 被當成 verified clear 的洩漏點。

### A2 — 不寫入任何 agent system 檔案 ✅

**規則**：「不得直接修改或刪除 agent system 的 JSONL、SQLite、cache 或內部 session 檔案。」

以廣義動詞集搜尋全樹（含 Swift 層 grep 看不到的 C API）：
`removeItem` / `trashItem` / `moveItem` / `copyItem` / `replaceItemAt` / `createDirectory` / `OutputStream` / `write(to:` / `createFile` / `FileHandle(forWritingTo:` / `sqlite3_backup_*`

非測試碼中的**所有**寫入點及其目的地：

| 位置 | 目的地 | 判定 |
|---|---|---|
| `DiagnosticLog.swift:349, 371` | 自有 `diagnostic-events.jsonl` | manager-owned |
| `DiagnosticLog.swift:382` | 自有 Application Support 目錄 | manager-owned |
| `SQLiteStateStore.swift:107, 212` | 自有 store／backup 目錄 | manager-owned |
| `SQLiteStateStore.swift:409-413` | `sqlite3_backup_*`：自有 `state.sqlite` → 自有 backup | manager-owned |
| `CodexAppServerProvider.swift:798` | 子行程 **stdin pipe**（非檔案） | 正常 JSON-RPC |

非測試碼中**完全沒有** `removeItem`、`trashItem`、`moveItem`、`copyItem`。

讀取 Codex 資料的路徑皆為唯讀：
- `CodexAppServerProvider.swift:553` 讀 `.codex-global-state.json` 使用 `Data(contentsOf:)`
- `SQLiteMaintenance.swift:395` 驗證 backup 使用 `SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX`

### A3 — Maintenance 不自動刪 backup、不自動 VACUUM ✅

**文件宣稱**（README）：「永不自動刪 backup 或執行 `VACUUM`。」

在 `SQLiteMaintenance.swift` 中搜尋 `VACUUM` / `removeItem` / `trashItem`，只命中兩行**文件註解**：

- `:133` — `In-place automatic VACUUM is not allowed.`
- `:165` — `the database, checkpointing WAL, deleting files, or running VACUUM.`

沒有任何實際呼叫。此宣稱以「不存在」的方式獲得驗證。

### A4 — Permanent Delete 只接受 manager Trash ✅

**規則**：「永久刪除只接受目前屬於 manager Trash Bin 的 session。」

強制點在 `CodexNativeDeleteCoordinator.swift:267-282`，為五重連續 guard：

1. `memberships.first(where: { $0.managerKey == managerKey })` — 必須在 manager Trash membership 中精確存在
2. `membership.nativeSessionID == session.nativeID` — native ID 必須一致
3. `session.nativeState == .archived` — native 狀態必須是 Archived
4. `session.descendantCountKnown && session.descendantCount == 0` — descendant 數必須「已知」且為零
5. `!session.protection.blocksDeleteAttempt` — protection 不得阻擋

另在 `prepare()`（`:41-46`）額外要求 `operation == .permanentlyDelete`、`trashMembershipMutation == .remove`、`items.count == 1`、`expectedNativeState == .archived`。

第 3 點與 `AGENTS.md` 的「Archive 必須先移到 Trash 才能刪除」互相支撐。未找到繞過路徑。

### A5 — 各 operation 的 guard 差異是刻意設計 ✅

稽核中發現三個 lifecycle operation 的 guard 清單不同，經查證為**設計意圖**而非疏漏：

| Operation | Guard 清單 | 位置 |
|---|---|---|
| Archive | `nativeState == .active`、`!isTrashMember`、`descendantCountKnown && == 0` | `CodexNativeArchiveCoordinator.swift:137, 144` |
| Restore | 僅 `nativeState == .archived` | `CodexNativeRestoreCoordinator.swift:280` |
| Delete | 完整五重（見 A4） | `CodexNativeDeleteCoordinator.swift:267` |

Restore 的豁免明載於文件：

- `docs/SAFETY.md:12`：「Restore 是可逆的 Archived → Active，仍須 exact state/readback，但不使用破壞性操作的 clearance gate。」
- `README.md:9`：「Restore 不是破壞性操作，不套用 Archive-only pin/running/descendant gate。」

程式碼與文件一致。**非缺陷。**

（附帶觀察：Archive 的 protection 檢查不在 coordinator inline，而是委派給 `ArchiveAffectedSetPreviewFactory.makePreparedPreview()` 與 `authorization.prepare()`。兩者都有強制，但強制點分散在不同層 —— 見發現 F3。）

### A6 — SQLite transaction 紀律 ✅

- Transaction helper 集中於 2 處：`SQLiteStateRepositories.swift:2122` 與 `SQLiteStateStore.swift:272`
- 模式正確：`BEGIN IMMEDIATE` → body → `COMMIT`，`catch` 中 `try? ROLLBACK` 後 rethrow
- Migration 迴圈（`SQLiteStateStore.swift:272-285`）每個 migration step 各自為一個 transaction，含 `PRAGMA application_id` 與 `user_version` 更新
- `sqlite3_step` 與 `sqlite3_finalize` 呼叫數平衡（Repositories 2:2、StateStore 3:3）
- 統一使用 `defer { sqlite3_finalize(statement) }`（`:305, 358, 375`）與 `defer { sqlite3_close_v2(...) }`，錯誤路徑不洩漏 statement
- `PRAGMA busy_timeout = 5000`（`SQLiteStateStore.swift:122`）

### A7 — Concurrency 正確 ✅

- `SessionManagerModel` 宣告為 `@MainActor final class ... : ObservableObject`（`SessionManagerModel.swift:37-38`），所有 UI 狀態變更在 main actor 上
- Core 使用 `actor`（例：`DeleteAuthorizationCoordinator`，`CodexNativeDeleteCoordinator.swift:18`）
- 資料模型廣泛標註 `Sendable`，注入的閉包標註 `@Sendable`
- 未發現 `@unchecked Sendable` 逃生口

雖然 `Package.swift` 使用 `swiftLanguageVersions: [.v5]`（未開啟 strict concurrency checking），實際隔離設計是正確的。

### A8 — 文件數字與程式碼一致 ✅

| 文件宣稱 | 程式碼 | 位置 |
|---|---|---|
| 每 provider 保留 500 份 Report | `maximumReportsPerProvider: 500` | `PersistentStateModels.swift:393` |
| Diagnostic 10,000 events | `maximumEvents: 10_000` | `DiagnosticLog.swift:66` |
| Diagnostic 30 天 | `maximumAge: 30 * 24 * 60 * 60` | `DiagnosticLog.swift:67` |
| Diagnostic 20 MB | `maximumBytes: 20 * 1_024 * 1_024` | `DiagnosticLog.swift:68` |

**未發現任何 doc drift。**

### A9 — `try!` 經查證為可證明安全 ✅

`SessionManagerModel.swift:135` 的 `self.diagnosticLogStore = try! DiagnosticLogStore()` 初看是 crash 風險，且與 README「若檔案初始化失敗，App 仍可啟動」的宣稱疑似矛盾。逐行檢查 `DiagnosticLog.swift:137-190` 後確認**不會 throw**：

1. `throw DiagnosticLogStoreError.invalidRetentionPolicy` — 需要 retention 常數 ≤ 0。`.production` 三個常數皆為正（見 A8），不觸發。
2. `try Data(contentsOf: fileURL)` — 被 `if let fileURL, fileManager.fileExists(...)` 包住。無參數建構時 `fileURL` 為 `nil`，短路跳過。
3. `try Self.rewrite(...)` — 被 `if needsRewrite, let fileURL` 包住。同樣因 `fileURL == nil` 短路跳過。

fallback 路徑確實是純記憶體、不碰檔案系統的。**非缺陷**，但屬於「靠上下文才成立」的寫法（見 C3）。

---

## 3. 發現

以下 5 項皆**未**出現在 `docs/TODO.md` 或 `docs/ROADMAP.md`（F2 部分列於 TODO，但優先級評估不同）。

### F1 — App 層 6,468 行不在 SwiftPM build 內，且零測試覆蓋

**嚴重度**：高（潛伏）

**證據**

`Package.swift` 只宣告三個 target：

```swift
.systemLibrary(name: "CSQLite3", ...)
.target(name: "AgentSessionManagerCore", dependencies: ["CSQLite3"])
.testTarget(name: "AgentSessionManagerCoreTests", ...)
```

`Sources/AgentSessionManager/` 的 17 個 SwiftUI 檔案**不屬於任何 SwiftPM target**。它們只被 Xcode 專案以跨目錄相對路徑引用，於 `App/AgentSessionManager/AgentSessionManager.xcodeproj/project.pbxproj` 確認：

```
path = ../../Sources/AgentSessionManager/SessionManagerModel.swift
path = ../../Sources/AgentSessionManager/SessionTableView.swift
... （共 17 筆）
```

30 個測試檔全部屬於 `AgentSessionManagerCoreTests`，App 層測試檔數為 **0**。

**今日實際狀態**

`xcodebuild` 實測 **BUILD SUCCEEDED、0 warnings**。這是一個**真實但尚未引爆**的缺口，目前沒有實際破損。

**影響**

`swift test` 全綠**不代表** App 層能編譯。未被任何自動化檢查覆蓋的包括：

- `SessionManagerModel.swift`（1,925 行）—— 所有 lifecycle facade 的接線點，Preview／Confirm／Report 的 UI 狀態機
- `SessionTableView.swift`（1,020 行）
- `ReportHistoryView.swift`（662 行）
- 其餘 14 個檔案

風險情境：修改 Core 的公開 API 簽名 → 258 個測試依然全綠 → App 層編譯失敗 → 直到手動開 Xcode 才發現。對一個會永久刪除使用者資料的 App，這條回饋迴路過長。

**與既有追蹤的關係**

`docs/TODO.md`「P2 — Engineering」有「把 Xcode app target 的 shared SwiftUI sources 配置自動檢查」。該項針對的是**設定漂移**（pbxproj 引用是否與磁碟一致），與本項的「App 層完全沒有編譯／測試驗證」是不同問題。

**建議方向**（未實作）

- 短期成本最低：把 `xcodebuild` 加進與 `swift test` 並列的固定驗證步驟。
- 中期：評估將 App 層抽出可測試的 SwiftPM target，或為 `SessionManagerModel` 的狀態轉換加上測試。

### F2 — 無 CI，且優先級評估偏低

**嚴重度**：中高

**證據**：無 `.github/` 目錄，repository 中不存在任何 CI 設定。

**與既有追蹤的關係**：`docs/TODO.md`「P2 — Engineering」已列「CI：`swift test`、Xcode build、format/lint、schema migration tests」。

**本報告的不同意見**：此項不應為 P2。結合 F1，目前**沒有任何自動化機制**能偵測 App 層編譯失敗；唯一的防線是開發者記得手動開 Xcode。對於一個明確以「安全地永久刪除資料」為核心價值的 App，`xcodebuild` 應與 `swift test` 同列 P0/P1。

且此刻是導入成本最低的時機 —— 兩項驗證今天都是綠的，建立基準線不需要先修任何東西。

#### F2.1 — 本專案的關鍵前提：目前沒有 git remote

```
$ git remote -v
（空）
```

此 repository 為純本機專案，沒有任何遠端。這直接影響可選方案：**GitHub Actions 等傳統 CI 的運作前提是「push 到遠端後，由遠端的機器執行檢查」**，沒有遠端就沒有執行者。

因此在建立遠端之前，能取得 CI 價值（不依賴開發者記得手動驗證）的方式如下。

#### F2.2 — 三種可行方案

| 方案 | 前置條件 | 自動化程度 | 進版控 |
|---|---|---|---|
| A. 檢查腳本（`scripts/verify.sh`） | 無 | 手動執行 | ✅ 可 |
| B. git `pre-commit` hook | 無 | 每次 commit 自動 | ❌ `.git/hooks/` 不進版控 |
| C. GitHub Actions | 需先建立 GitHub remote 並 push | 每次 push 自動 | ✅ 可 |

**建議路徑**：先做 A（可進版控、任何人 clone 都拿得到），確認 `xcodebuild` 在本機的實際耗時後，再決定是否掛成 B。若未來建立 GitHub remote，C 可直接沿用 A 的腳本內容。

#### F2.3 — 檢查腳本的必要內容

兩段缺一不可。第二段的 `xcodebuild` 是**目前唯一會編譯到 App 層那 6,468 行的機制**（見 F1）。

```bash
#!/bin/sh
set -e

cd macos/AgentSessionManager

echo "==> swift test (Core)"
CLANG_MODULE_CACHE_PATH="${TMPDIR}asm-clang" \
SWIFTPM_MODULECACHE_OVERRIDE="${TMPDIR}asm-spm" \
swift test --disable-sandbox

echo "==> xcodebuild (App)"
cd App/AgentSessionManager
xcodebuild -project AgentSessionManager.xcodeproj \
  -scheme AgentSessionManager \
  -destination 'platform=macOS' \
  -derivedDataPath "${TMPDIR}asm-dd" \
  build

echo "==> OK"
```

#### F2.4 — 實作時的注意事項

1. **live 測試不會被誤觸發**。3 個 live smoke tests 需要 `AGENT_SESSION_MANAGER_LIVE_TEST=1` 才執行；腳本未設定該變數，因此它們會照常 skip。**不會對真實 Codex 送出任何 request**。此點對本專案尤其重要 —— 自動化驗證絕不應成為意外觸發 live mutation 的途徑。

2. **使用 `${TMPDIR}` 而非硬編碼 `/tmp`**（見 F5）。這讓腳本在受限環境中也能運作。

3. **`derivedDataPath` 指向 `${TMPDIR}`**，避免在 repository 內產生建置產物。

4. **速度是唯一取捨**。實測 `swift test` 為 1.8 秒；`xcodebuild` 增量建置顯著較久。若掛成 pre-commit hook 後覺得過慢，可只在 hook 中執行 `swift test`，將 `xcodebuild` 保留為手動或改用 push 前執行。

5. **本次稽核未建立上述任何檔案**。以上為方案說明，非既成事實。

### F3 — 三個 Authorization coordinator 的骨架重複

**嚴重度**：中（可維護性，非當前缺陷）

**範圍界定（本項曾被高估，此為修正後版本）**

初稿將四個 `CodexNative*Coordinator` 合計 2,536 行整體列為「近同構重複」。逐一比對實作後確認**該描述錯誤**：其中大部分是需求驅動的真實差異。實際重複集中在三個 Authorization coordinator，約 456 行。

**真正重複的部分**

| 型別 | 位置 | 約行數 |
|---|---|---|
| `ArchiveAuthorizationCoordinator` | `ArchiveAuthorizationCoordinator.swift:20-186` | ~166 |
| `RestoreAuthorizationCoordinator` | `CodexNativeRestoreCoordinator.swift:18-168` | ~150 |
| `DeleteAuthorizationCoordinator` | `CodexNativeDeleteCoordinator.swift:18-158` | ~140 |
| **小計** | | **~456** |

三者成員完全對應：`prepare()` / `execute()` / `makeReport()` / `executionErrorCode()`。

`execute()` 骨架逐段相同：`claimOperationPreviewForExecution` → `executor.execute` → `catch` 建構 failure result → `makeReport` → `saveOperationReport(requiringPreviewStatus: .executing)`。

`executionErrorCode()` 是最機械式的重複 —— 同一組 switch case，差別僅在字串前綴：

```swift
// CodexNativeRestoreCoordinator.swift:153
case .expired: return "restore_preview_expired"
case .confirmationMismatch: return "restore_confirmation_mismatch"
case .checkpointMismatch: return "restore_checkpoint_mismatch"

// CodexNativeDeleteCoordinator.swift:141
case .expired: return "delete_preview_expired"
case .confirmationMismatch: return "delete_confirmation_mismatch"
case .checkpointMismatch: return "delete_checkpoint_mismatch"
// Delete 另有 protectedSession、descendantScopeChanged 兩個獨有 case
```

**明確不屬於重複的部分**

以下差異是需求驅動的。把它們算成「重複」會導致錯誤的重構決策：

1. **Delete 多出約 265 行獨有的 recovery 子系統** —— `CodexDeleteExecutionRecoveryReadback`（`:471`）、`DeleteExecutionRecoveryReconciler`（`:517`，含 `loadContext`、`classify`）、`CodexNativeDeleteRecoveryCoordinator`（`:709`）。原因：Delete 的 absence 證明需要「完整 inventory 省略該 ID」+「`thread/read` 回傳精確 `-32600`」雙重證據，Archive／Restore 只需確認狀態是否翻轉。這是真實的語意差異，不是複製。

2. **`CodexNativeBatchCoordinator` 是不同的演算法，不是單筆版的複製**。它定義統一的 `CodexNativeBatchLifecycle` protocol（archive／restore／delete／exactDeleteRead 四個動詞在同一介面），並實作單筆版完全沒有的邏輯：`executeFrozenPrefix`、`executeOne`、`classifyDelete`、`notAttempted`、`batchWarnings`、`validateWholeBatchPreflight` 等 14 個 private method，處理「全批 preflight → 凍結順序逐筆執行 → 第一個非成功即停止 → 其餘標記 `batch_not_attempted`」。將其列為單筆流程的重複是錯誤歸類。

3. **能共用的部分已經被抽出**。`NativeArchiveReportItem` 已透過 typealias 被另外兩者共用（`CodexNativeRestoreCoordinator.swift:168`、`CodexNativeDeleteCoordinator.swift:158`）；`ArchiveExecutionHasher`、`PersistentOperationPreview` / `PersistentOperationReport` 亦為共用型別。作者已經抽出了容易抽的部分。

**已排除的疑慮**

稽核中曾懷疑各 coordinator 的 fail-closed guard 清單可能已漂移不一致。逐一比對後**確認沒有不一致缺陷** —— 差異都是刻意且與文件相符的（見 A5）。

**實際風險**

1. **同步風險**：`execute()` 骨架與 `executionErrorCode()` 若需修正（例如新增一個所有 operation 都該有的 error 分類，或改變 report 持久化的失敗處理），需手動同步三處，**編譯器不強制一致性**。
2. **稽核成本**：同類不變量的強制點分散在不同層級 —— Delete 把 protection 檢查寫在 coordinator inline（`CodexNativeDeleteCoordinator.swift:275-278`），Archive 則委派給 `ArchiveAffectedSetPreviewFactory.makePreparedPreview()` 與 `authorization.prepare()`。兩者都確實強制，但驗證「所有破壞性操作都檢查了 protection」時無法在一處看全。

**追蹤狀態**：`docs/TODO.md` 與 `docs/ROADMAP.md` 皆未提及此重構。

**注意**：這是安全關鍵路徑。可行的最小改動是抽出共用的 authorization 骨架（約 456 行 → 一份泛型化實作 + 三份 operation-specific 設定），淨收益約 300 行。收益未必大於重構風險，列出是為了讓此風險被明確知悉，而非建議立即動手。

### F4 — `tmp/debug/` 的 12 份除錯知識未進版控

**嚴重度**：低（但損失不可逆）

**證據**

`.gitignore` 最後一行為 `tmp/`，`git ls-files tmp` 回傳空。但 `tmp/debug/` 含 68 KB、12 份明顯是刻意累積的知識資產：

```
debugging-playbook.md          safety-and-evidence.md
permanent-delete-lifecycle.md  lifecycle-ui-reentrancy.md
state-model.md                 sqlite-and-timestamps.md
codex-runtime-and-transport.md native-checkbox-batch.md
swiftui-layout-and-persistence.md
xcode-target-selection.md      diagnostic-logging.md
README.md
```

**影響**：這些檔案不在版控中。換機器、清理暫存目錄或 `git clean -x` 都會永久遺失。從檔名判斷，其內容（尤其 `permanent-delete-lifecycle.md`、`safety-and-evidence.md`）與 `docs/` 中的正式文件屬同一等級的設計知識。

**追蹤狀態**：`docs/ROADMAP.md` 與 `docs/TODO.md` 皆未提及。

### F5 — README／HANDOFF 的測試指令硬編碼 `/tmp` 路徑

**嚴重度**：低

**證據**：`README.md` 與 `docs/HANDOFF.md` 的建置指令使用

```
CLANG_MODULE_CACHE_PATH=/tmp/agent-session-manager-clang-cache
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/agent-session-manager-swiftpm-cache
```

**影響**：在受限或沙箱化環境中，這兩個路徑不可寫，`swift test` 會失敗。實測時的錯誤訊息為：

```
error: You don't have permission to save the file "output-file-map.json"
       in the folder "AgentSessionManagerCore.build"
```

此訊息指向 `.build` 目錄，看起來像是專案損壞，實際上是 module cache 路徑不可寫所致 —— 對不熟悉專案的人會造成明顯誤導。

**建議方向**：改用 `${TMPDIR}`，在一般與受限環境皆可運作。

### F6 — Delete 沒有 acceptance runbook，且本報告的「0 缺陷」須以此限定

**嚴重度**：高

**這一項同時是發現與對本報告結論的限定條件，請與第 0 節摘要合併閱讀。**

**已被追蹤的部分（不重複列為發現）**

- `docs/TODO.md:42`：「完成 App 可見的 live Archive success／Busy／unknown acceptance」—— **未勾選**
- `docs/ROADMAP.md:110`：「單筆與 checkbox batch Trash → Deleted 已完成；**isolated live batch acceptance 待完成**」
- `docs/ARCHIVE_ACCEPTANCE.md:5`：2026-08-13 對一個可犧牲 session 送出過一次真實 Archive，App Server 以 `-32600` 拒絕，fresh readback 證明仍為 Active。文件本身誠實記載「這不是 Archive success」。

亦即：**lifecycle 的成功路徑，從未對真實 Codex 完整執行過一次。** 目前唯一的真實世界證據是一次 rejection。

**未被追蹤的部分（本報告的發現）**

`docs/` 中存在 `ARCHIVE_ACCEPTANCE.md`，但**不存在 `DELETE_ACCEPTANCE.md`**。

這造成一個不對稱：

| 操作 | 可逆性 | acceptance runbook | 真實執行紀錄 |
|---|---|---|---|
| Archive | 可逆 | ✅ 完整（含 success criteria、失敗分類、不得重跑條款） | 1 次（rejection） |
| Permanent Delete | **不可逆** | ❌ **不存在** | **0 次** |

Archive 是可逆操作，卻有完整的驗收流程文件。Permanent Delete 是全系統唯一不可逆的操作，卻既無驗收 runbook，也從未對真實 Codex 執行過。此不對稱在 `TODO.md` 與 `ROADMAP.md` 中皆未被記錄為待辦。

**對本報告結論的限定**

第 0 節的「現存缺陷 0」必須理解為：

> **程式碼在靜態檢查下表達了正確的意圖 —— 不等同於系統在真實環境中行為正確。**

本次稽核的性質決定了這個界線：

- App 只經過**編譯**，從未啟動或操作
- 未對真實 Codex 送出**任何**一個 lifecycle request
- `swift test` 中 3 個 skipped 測試，正是唯一會接觸真實 Codex 的 live smoke tests

因此 A4（Permanent Delete 五重 gate）的結論應讀作「gate 的邏輯正確且找不到繞過路徑」，而非「Permanent Delete 已被驗證能安全運作」。前者是本次稽核能證明的上限。

**建議方向**：在 Permanent Delete 進入真實使用前，比照 `ARCHIVE_ACCEPTANCE.md` 的格式建立 `DELETE_ACCEPTANCE.md`，明確定義可犧牲 session 的準備方式、success criteria、以及哪些結果**不算**成功。此項純為文件工作，不涉及程式碼變更。

---

## 4. 觀察（非缺陷）

### C1 — 文件密度

`README.md` 為 21 KB，`docs/` 另有約 180 KB。文件的**準確度極高**（所有可驗證的數字與行為宣稱都通過查證），但單一段落經常超過 500 字且技術密度極高，對新加入者的門檻偏高。

這是刻意取捨的結果（面向 agent handoff 而非人類 onboarding），列出僅供參考。

### C2 — 最大檔案

`SQLiteStateRepositories.swift` 2,365 行為全專案最大。內部組織清晰（13 個 transaction 進入點各自獨立），目前未造成問題，但屬未來拆分的自然候選。

### C3 — `try!` 的上下文依賴

如 A9 所述，`SessionManagerModel.swift:135` 的 `try!` 目前可證明安全，但其安全性依賴於「`DiagnosticLogStore` 的無參數建構恰好不會 throw」這個非區域性事實。若未來有人在該 init 中新增一條與 `fileURL` 無關的 throw 路徑，此處會變成 App 啟動時的 crash，而編譯器不會警告。

改為 `try?` 搭配明確 fallback 可移除此耦合。屬防禦性改善，非現存缺陷。

---

## 5. 稽核方法與可重現性

### 5.1 執行的驗證指令

```bash
# 測試（實測通過：258 tests, 0 failures, 3 skipped）
cd macos/AgentSessionManager
CLANG_MODULE_CACHE_PATH="$TMPDIR/asm-clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$TMPDIR/asm-spm" \
swift test --disable-sandbox
```

```bash
# App 建置（實測通過：BUILD SUCCEEDED, 0 warnings）
cd macos/AgentSessionManager/App/AgentSessionManager
xcodebuild -project AgentSessionManager.xcodeproj \
  -scheme AgentSessionManager \
  -destination 'platform=macOS' \
  -derivedDataPath "$TMPDIR/asm-dd" build
```

### 5.2 稽核涵蓋範圍

**已驗證**

- `AGENTS.md` 全部 11 條 non-negotiable safety rules 的程式碼強制點
- 全樹檔案系統寫入點（廣義動詞集，含 C API）
- 全樹 fail-open 預設值（`?? false` / `?? true` / force unwrap）
- SQLite transaction、statement 生命週期、migration 結構
- Concurrency 隔離標註
- 文件數值宣稱 vs 程式碼常數
- 三個 lifecycle operation 的 guard 清單交叉比對
- 四個 `CodexNative*Coordinator` 的型別與方法逐一比對（用以界定 F3 的實際重複範圍，而非僅比對函式名稱）

**未驗證（本次範圍外）**

- **Live mutation 行為**：3 個需 `AGENT_SESSION_MANAGER_LIVE_TEST=1` 的測試未執行，未對真實 Codex 送出任何 lifecycle request。
- **UI 執行期行為**：App 僅建置，未啟動、未操作。SwiftUI 的狀態轉換、sheet 流程、鍵盤與 VoiceOver 行為皆未測。
- **實際 SQLite migration 在真實資料上的行為**：僅檢查程式碼結構與既有測試，未在真實 `state.sqlite` 上執行 v0→v8 migration。
- **效能與大型 library 行為**：未測 10,000 筆上限附近的實際表現。

### 5.3 稽核限制

本次稽核為靜態程式碼分析加建置驗證。「未找到繞過路徑」意指在上述方法的涵蓋範圍內未發現，不等同形式化證明不存在。特別是 A4（Permanent Delete gate）的結論建立在對呼叫路徑的人工追蹤上，若存在未被本次搜尋覆蓋的間接呼叫路徑，可能未被涵蓋。

---

## 6. 結論

程式碼品質與安全紀律高於一般個人專案的水準。`AGENTS.md` 定義的安全模型不只是文件宣示，而是在程式碼中確實被強制執行，且經得起針對性的繞過嘗試。文件的準確度尤其罕見 —— 所有可驗證的宣稱都通過查證，沒有發現任何 doc drift。

真正需要投資的方向不是修 bug（本次未發現現存缺陷），而是**建立工程防護網**：

1. **F1 + F2** 應合併處理，且優先級高於目前 TODO 中的 P2 定位。把 `xcodebuild` 納入固定驗證是單一成本最低、收益最高的改動，而且今天兩項驗證都是綠的，正是建立基準線的最佳時機。
2. **F4** 成本極低（移出 `tmp/` 或調整 `.gitignore`），但避免的是不可逆的知識損失。
3. **F3** 的範圍在複查後大幅縮小：重複集中在三個 Authorization coordinator 的骨架（約 456 行），抽出後淨收益約 300 行。四個 `CodexNative*Coordinator` 之間的其餘差異均為需求驅動的真實差異（Delete 的雙重 absence 證明、Batch 的多筆 stop-on-prefix 演算法），不應納入重構範圍。由於位於安全關鍵路徑且收益有限，**不建議主動重構**；列出僅為讓同步風險被明確知悉。

### 6.1 建議的處理順序

| 順位 | 項目 | 成本 | 風險 | 理由 |
|---|---|---|---|---|
| 1 | F4（`tmp/debug/` 進版控） | 極低 | 無 | 避免不可逆的知識損失 |
| 2 | F1 + F2（`xcodebuild` 納入固定驗證 / CI） | 低 | 無 | 今天兩項驗證皆綠，建立基準線不需先修任何東西 |
| 3 | F6（建立 `DELETE_ACCEPTANCE.md`） | 低 | 無 | 純文件工作。Permanent Delete 進入真實使用前的必要前置 |
| 4 | F5（`${TMPDIR}`） | 極低 | 無 | 順手修正誤導性錯誤訊息 |
| — | F3（授權器骨架） | 中 | **中高** | 收益約 300 行，位於安全關鍵路徑。建議維持現狀 |

前四項**都不需要修改任何現有程式碼**：兩項是新增設定或文件，一項是調整 `.gitignore`，一項是改 README 的環境變數。
