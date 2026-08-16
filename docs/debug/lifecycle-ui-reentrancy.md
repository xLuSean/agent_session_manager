# Lifecycle UI and Async Reentrancy Pitfalls

## Restore 成功，但 UI 顯示 Preview mismatch

### 表面現象

- Archive list count 少一個。
- UI 隨後顯示：`Displayed Restore Preview differs from its frozen SQLite record.`

### Durable evidence

- Preview status：`consumed`
- Restore Report：`success`
- Report item native state：`active`
- Exact native session ID：`01900000-0000-7000-8000-000000000007`（synthetic public placeholder）
- Evidence time：omitted from the public repository

所以第一次 Restore 確實成功；Archive count 減一是正確結果。

### 根因

Confirmation sheet 在第一次 async execution 進行期間仍保留可觸發的 default-action button。
第一個 call 完成、consume Preview 並寫 success Report 後，第二個 UI execute 進來。第二個 call
讀到 Preview 已不是 `prepared`，因此在 provider transport 前被擋下並顯示 mismatch。

SQLite claim 保住了 provider exactly-once，沒有第二次 `thread/unarchive`；但 UX 錯把第二個
安全拒絕顯示成整體失敗。

## 修復

### Sheet layer

- Button action 同步設定 `isSubmitting = true`，再建立 Task。
- 執行中停用 confirmation、Cancel 與 default keyboard action。
- 顯示「執行並驗證 exact-ID readback」ProgressView。
- 失敗且同一 Preview 仍存在時才解除 latch，允許使用者處理明確 failure。

### Model layer

- Archive 與 Restore 各保留 executing Preview ID。
- 第二個 call 在任何 `await` 前就被 model guard 忽略。
- `defer` 只清除同一 Preview 的 in-flight marker。

## 為什麼需要兩層

Swift MainActor／actor 在 `await` 時可重入。UI disabled 是 UX，不能單獨當 domain safety。
Model guard 是第二層；SQLite prepared → executing atomic claim 是最終 exactly-once boundary。

## 同型風險

任何具有 confirmation token、default keyboard shortcut、async Task 的 sheet 都要檢查：

- 是否在 Task 建立前同步 latch？
- Cancel 是否在 mutation in flight 時停用？
- Model 是否防止 actor reentrancy？
- Durable claim 是否原子且不可 replay？
- 成功後 report presentation 是否會與舊 sheet binding 競爭？

## Manager-only operation 成功，但 Preview sheet 看起來沒反應

### 表面現象

- `Trash Bin → Archive` 的 Preview 沒顯示 confirmation token。
- 按下 `Move to Archive` 後舊 Preview 留在畫面，像是沒執行。

### Durable evidence

SQLite 顯示當次 Preview 已轉為 `consumed`，且對應 Operation Report 已完成；
Trash membership 也已移除。所以 mutation 成功，故障位於 sheet presentation。

### 根因與修復

- 非 destructive 的 `OperationPreviewSheet` 把 token 隱藏，並在程式內自動代入；這違反「所有 mutation 都要人工輸入 frozen Preview token」的規則。
- Model 同時把 `pendingPreview = nil` 與 `latestReport = report` publish 給同一個 root View 上的兩個 `.sheet`，SwiftUI 會讓舊 Preview 停留或吞掉新 Report。
- 修復後所有 operation 都顯示 Copy + token input，exact match 前按鈕停用；UI/model 同時防重入並顯示 ProgressView。
- 成功 Report 先進 queue，等 Preview `.sheet` 的 `onDismiss` 再 publish，保證呈現順序是 Preview 關閉 → Report 開啟。

### 第二次實測：Report 已寫入，但 exact readback 報錯

Sheet queue 修復後，`Trash Bin → Archive` 仍可能顯示：
`Manager-only commit completed, but exact Report readback failed.`
唯讀 SQLite 證據顯示 Preview 已 `consumed`、Report 與 items 都為 `success`、
Trash membership 已移除，所以不可重試。

根因不是 sheet queue，而是 manager-only commit 使用 raw `Date()` 建立回傳的
`PersistentOperationReport`；SQLite ISO-8601 讀回只保留毫秒。例如記憶體時間是
`.380123`，durable row 是 `.380`，mutation transaction 已 commit，但 transaction 外的
`reportReadback == committed` 會失敗。

修復是在 SQLite commit boundary 一開始將 `completedAt` 轉成
`PersistentTimestamp.canonical`，再共用於 membership timestamp、Report header 與 item evidence。
Manager-only Archive/Trash 與 Accept Native Restore 都套用相同規則，並以
`110.123456` 這類 sub-millisecond fixture 驗證 exact readback。

## Trash → Archive 第一次因 unrelated inventory drift 失敗

### 表面現象與持久證據

- 第一份 `Move to Archive` Preview 保持 `prepared`，沒有Report，也沒有移除Trash membership。
- Diagnostic Logs連續記錄：`Provider inventory drifted after manager-only Preview.`
- Refresh後建立第二份Preview，同一筆Trash → Archive成功並寫入success Report。

因此第一次確實是安全地「沒有執行」，第二次才成功；不是第一次已commit卻錯報失敗，也沒有重送任何
Codex lifecycle request。Trash → Archive本來就是manager-only classification，Codex native state全程維持
Archived。

### 根因

執行前的fresh official inventory會advance SQLite checkpoint。舊gate要求目前的「整個provider inventory
hash」必須和Preview建立時完全相同；只要任何無關session新增、刪除或metadata改變，就會拒絕本次
selection，即使目標session與Trash membership完全沒變。這是把global drift誤當成target drift。

### 修復

- Fresh snapshot仍是必要的pre-commit evidence。
- Coordinator只對frozen selection逐筆比對manager key、native ID、Archived state、title、project、working
  directory與protection hash；任何目標漂移仍整批fail closed。
- SQLite transaction要求剛驗證的完整checkpoint在commit前沒有再次改變，並繼續原子檢查exact Trash
  membership、manifest、Report與Preview consume。
- 無關session造成global inventory hash改變時，只要exact targets維持一致就可繼續。
- Tests同時覆蓋「unrelated inventory drift可通過」與「exact target drift整批拒絕」。
