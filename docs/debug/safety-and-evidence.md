# Safety and Outcome Evidence

## Trash → Archive不可沿用Archived → Trash的protection gate

兩者都走manager-only coordinator、native state也都保持Archived，但安全方向相反：Archived → Trash
新增待刪意圖，應要求完整protection；Trash → Archive取消待刪意圖，是更安全的分類轉換，只需要完整
inventory與membership/checkpoint drift驗證。若`PersistentOperation`用「不是Archive/Restore/Delete」的
排除式條件，`moveToArchive`會在Preview save/claim時錯誤拋出`requires a complete protection checkpoint`，
即使UI eligibility已允許。修復應使用明確的`operation == .moveToTrash`，並以
`protectionComplete=false`的prepare＋claim＋execute回歸測試覆蓋整條SQLite路徑。

## 不可跨越的界線

- 不直接修改 Codex JSONL、SQLite、cache、rollout 或內部 session 檔案。
- Native lifecycle 只經正式 App Server interface，並執行 readback。
- Manager-owned SQLite 可以唯讀診斷，不可為了讓測試通過而手動修資料。
- Preview 漂移時整批 fail closed，不偷偷縮小 selection。
- 不確定的 mutation 絕不盲目重送。

## 內部 Preview credential 不等於使用者必須輸入 token

Frozen Preview 的 confirmation token／hash 仍是重要的內部安全機制：它把 execute 綁定到精確 selection、
Preview version 與一次性 claim，避免 stale 或不同批次被誤送。但對 Archive、Restore、Move to Trash、
Move to Archive 這些可逆操作，在同一個 App 視窗顯示 token 再要求使用者複製貼上，並沒有增加有意義的
安全邊界，只增加操作摩擦。

因此 UI 採風險分級：可逆操作保留 frozen Preview、明確 Confirm、內部 credential、drift gate 與逐筆
readback；Permanent Delete、清除 Report History 等不可逆操作才要求使用者輸入畫面上的精確 token。
不要因為 Core coordinator 接受 token，就直接推論所有 UI 都必須顯示 token 欄位。

## UI 不是 outcome truth

判斷 Archive／Restore 是否真的成功時，證據優先順序：

1. Durable Preview status
2. Durable itemized Report outcome
3. Report item 的 exact native ID 與 observed native state
4. Fresh official inventory／exact-ID readback
5. UI list count 只能作為提示，不能單獨證明 outcome

## Preview status 的意義

- `prepared`：尚未 claim；不能推論 native request 已送出。
- `executing`：可能已送出 request；只允許 readback-only recovery，不能 replay。
- `consumed`：已有對應 completion Report，必須查看 Report outcome。
- 已過期的 `prepared` row 即使仍保留作 audit，也不能再 claim。

## RPC acknowledgement 不是成功

- Archive success 需要較新的完整 readback 顯示 exact ID 為 Archived。
- Restore success 需要較新的完整 readback 顯示 exact ID 為 Active。
- 明確 rejection 加未變 native state可以是 failure。
- Timeout、stale、missing identity、partial inventory 或無法證明的狀態都是 unknown。
- Unknown 不 retry。

## Separate writer host 的修正認知

早期誤把 shared writer host 當成任何 Archive request 的必要條件。後來證實獨立 App
Server 仍可送正式 `thread/archive`；若 writer 被另一 host 佔用，可安全拒絕為 Busy。

因此：

- Shared host 改善事前預測，但不是 one-shot attempt 的必要條件。
- Positive protection 仍阻擋。
- 缺少跨 host writer/running/current clearance 是顯示風險，不是假造 clearance。
- 一次 request、fresh readback、no retry 仍是必要 contract。
