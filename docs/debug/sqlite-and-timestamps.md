# SQLite and Frozen Preview Pitfalls

## Sub-millisecond `Date` 造成 Preview readback mismatch

### 症狀

`Persisted Restore Preview readback differs from the frozen Preview.`

### 根因

Swift `Date()` 帶有 sub-millisecond 精度；SQLite ISO-8601 欄位只保存毫秒。記憶中的
Preview 與讀回 Preview 表示同一時刻，但 `Equatable` 精確比較不同。

原測試都使用整秒 fixture time，因此沒有覆蓋 production-only precision drift。

### 修復

- `PersistentTimestamp.canonical` 統一為毫秒。
- `createdAt`、`expiresAt` 必須在 manifest hashing 前 canonicalize。
- 適用於 Native Archive、Native Restore、manager-only Archive／Trash、conflict resolution、
  affected-set Preview factory。
- Repository validation 拒絕未 canonicalize 的 Preview timestamps。
- Preview insert、item insert 與 exact readback equality 放在同一 transaction；不一致會整筆
  rollback，不留下半成功 prepared record。
- 回歸測試使用帶 `123456` 微秒的 production-like timestamp。

## 為什麼不能在 persistence 後才修時間

Preview timestamp 參與 manifest hash。若先用奈秒值算 hash，寫入時才截成毫秒，durable
record 的 hash input 已改變，之後 claim／drift check 必定不一致。正規化必須發生在 hash 前。

## 舊 prepared rows

舊版在 transaction commit 後才做 readback comparison，因此失敗時可能留下 prepared row。
這不代表 provider request 已送出。Row 過期後不能 claim，也不阻擋新的 exact Preview。

不要直接以 SQL 刪除來「修復」。若未來需要清理，必須設計正式、可 audit、可確認的
manager-state maintenance flow。

## Schema／migration 原則

## v5 durable Trash membership intent

### 為什麼要新欄位

`operation=restore` 無法單獨分辨 Archive → Active 與 Trash → Active；執行／recovery 當下再查
membership並猜使用者原意，會破壞 frozen Preview contract。v5 在 `operation_previews` 加入
nullable `trash_membership_mutation`，只接受 `add/remove`。

### 舊 Preview 相容陷阱

若直接把新 optional 欄位加入所有 manifest JSON，即使值是 `null`，v1-v4 已保存的 hash 也會
全部改變。修復方式：mutation 為 `nil` 時沿用舊 Manifest payload；只有新的 `add/remove`
Preview 使用 V2 payload並把 intent綁入hash。Migration不回填舊row，避免猜測舊intent。

### 原子 finalization

- Active → Trash success：驗證 item success + Archived readback + membership 不存在，再 insert。
- Trash → Active success：重算完整 membership-set hash + 驗證 exact membership + Active readback，
  再 delete。
- Membership effect、Report insert、item results與 Preview consume同transaction。
- Transaction失敗保留 `executing` Preview，下一次只能readback recovery，不能 replay provider call。
- v4→v5 與故意失敗的 migration都要驗證 backup與rollback。

## v6 frozen working-directory evidence

### 症狀

Active session 成功移到 Trash 後，Trash Bin 的 Project 欄顯示 `—`。直接查看 manager SQLite 會發現
`trash_memberships.project_id_at_entry` 與 `working_directory_at_entry` 都是 `NULL`。

### 根因與修復

Active → Trash 的 membership 只有在 native Archived readback 成功後才建立，但 frozen Preview item
原本沒有 working directory，finalization 因而只能插入 `NULL`。v6 在 `operation_items` 新增 nullable
`expected_working_directory`，Archive affected-set 建立 Preview 時凍結 `thread.cwd`，成功 finalization
再把同一 frozen value 寫入 membership。v5→v6 migration 必須先 backup，且有 rollback test。

舊 membership 不直接回填；UI 只在 live cwd basename 能唯一對應目前 Desktop Project catalog 時補回
Project 顯示。若有兩個候選就維持空白，避免猜錯。

- Schema 變更需要 migration、backup 與 rollback tests。
- Timestamp encoding resolution 是 contract，不只是 formatting detail。
- 任何 frozen hash input 都要先轉成 durable canonical representation。
- Save API 應在 transaction 內完成 exact readback，呼叫端的額外 readback只是 defense in depth。
