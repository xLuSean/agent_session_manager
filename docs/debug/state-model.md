# State Model Pitfalls

## Archive 與 Trash 不能合併

### 踩雷

Codex 只有 native Active／Archived，沒有 native Trash Bin。若直接把 Archived 當成
Trash，就無法區分「半永久保留」與「待刪除」。

### 正確模型

- Native Active／Archived：Codex 的存在與 lifecycle truth。
- Manager Archive：使用者想長期保留；native state 是 Archived。
- Manager Trash：使用者想待刪；native state 仍是 Archived，加上 manager-owned SQLite
  的 Trash membership。
- Archive → Trash、Trash → Archive：只改 manager intent，不呼叫 Codex lifecycle API。
- Archive → Active：正式 `thread/unarchive`。
- Active → Trash：保存 `.moveToTrash + .add`，先送一次 `thread/archive`；只有 fresh Archived
  readback success 才加入 Trash membership。
- Trash → Active：保存 `.restore + .remove` 與完整 membership-set hash，先送一次
  `thread/unarchive`；只有 fresh Active readback success 才移除 membership。
- Permanent Delete：只能接受目前確實屬於 Manager Trash 的 exact selection。

### 可重用原則

Provider-native state 與產品層的使用者意圖是兩個維度。即使目前映射到相同 native
state，也不能因此合併。

## 複合 lifecycle + manager intent 的順序

### 容易犯的錯

先加入／移除 Trash membership，再呼叫 Codex。若 request 被 Busy 拒絕、timeout，或 App 在
Report 前中斷，UI 會呈現一個沒有 native 證據支持的 manager 狀態。

### 現在的 contract

1. Preview 先把 native operation、membership `add/remove`、exact item set、checkpoint、token
   與 manifest durable freeze。
2. Claim 成 `executing` 後最多送一次 lifecycle request。
3. Fresh native readback 決定 success/failure/unknown。
4. 只有 success 才在同一 SQLite transaction 套用 membership、寫 Report、consume Preview。
5. Failure/unknown 不改 membership。
6. App 中斷時 recovery 只有 readback capability；不能重送 request，但能完成第 4 步。

## Active + Manager Trash conflict

### 成因

Codex 已是 Active，但 manager SQLite 還保留 Trash membership。

### 已完成的 resolution

Accept Native Restore 會重新取得 fresh complete inventory，確認 exact session 仍為 Active，
再以 transaction 只移除 manager membership、寫 Report 並 consume Preview。這條路徑不持有
provider mutation transport，因此不會送 `thread/unarchive`。

### 尚未完成

- Reapply Trash Intent
- Externally Missing acknowledgement

## 全 inventory hash 不能直接當 single-item preflight gate

### 症狀

Active → Trash 的 Preview 正常，但輸入 token 後立刻得到
`archive_state_drift: provider inventory hash changed`，provider request 根本沒有送出。

### 踩雷

Canonical provider inventory hash 包含所有 sessions，也包含 title、updatedAt、project 等顯示資料。
Preview 到 confirmation 之間只要另一個 session 有活動，或目標標題等非 lifecycle 欄位更新，整個
hash 就會不同。這不等於 exact target 或保護範圍漂移。

### 修正

- Inventory hash 繼續綁定 durable Preview、manifest 與 claim-time checkpoint。
- Native single-item preflight 不比較 fresh 全 inventory hash equality。
- Archive 送出前仍重驗 exact native ID、Active state、完整 protection hash、descendant known/count。
- Restore 送出前仍重驗 exact native ID 與 Archived state。
- 真正的 target/protection/descendant drift 仍在 provider request 前 fail closed。

### 可重用原則

Snapshot identity 與 mutation authorization scope 不一定相同。全域 hash 適合做 durable provenance，
不適合拿來否決只影響一個 exact ID 的操作；preflight 應比較最小但完整的安全關聯證據。
