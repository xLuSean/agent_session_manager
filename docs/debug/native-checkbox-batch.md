# Native Checkbox Batch

Last updated: 2026-08-14 (Asia/Taipei)

## 使用者需求

- 每個一般 lifecycle action 都能對 checkbox exact selection 執行。
- 只有 Trash Bin 額外提供 Select All；其他 Status 仍可逐列勾選。
- Archive 不可直接永久刪除；Delete eligibility 永遠從 Manager Trash membership 開始。

## 踩雷：不能用 UI 連續呼叫單筆 coordinator 冒充 batch

這會產生多個 token、分散的 Preview，且無法在第一個 provider request 前證明整個 selection 都合格。
修復方式是把整個 selection 保存成一份 multi-item `PersistentOperationPreview`：

1. Preview 凍結全部 manager/native IDs、source state、protection/membership evidence與一個token。
2. SQLite 一次 claim 整份 Preview。
3. fresh complete inventory 對全部 items 做 preflight；任何一筆 drift 都是零 request。
4. Codex沒有跨thread transaction，因此依frozen manager-key順序逐筆執行。
5. 第一個failure／unknown後停止；剩餘item寫`batch_not_attempted`，不縮小batch後繼續。
6. 一份itemized Report原子consume Preview並套用成功item的membership/tombstone effect。

## 踩雷：SQLite v7 `delete_report_id UNIQUE`

單筆Delete時，一份Report只建立一個tombstone，所以v7將`deleted_sessions.delete_report_id`設為
UNIQUE看似合理。Batch Delete成功兩筆時，同一Report ID必須關聯兩個tombstone，第二筆會得到：

```text
UNIQUE constraint failed: deleted_sessions.delete_report_id
```

正式修復是SQLite v8 migration：transaction內重建`deleted_sessions`，保留provider/native ID與
manager key唯一性，但把`delete_report_id`改為non-unique indexed audit grouping key。Migration前仍建立
backup；成功migration與故意失敗rollback都有測試。不要為每個item偽造獨立Report ID。

## Outcome 與 recovery

- 全批preflight失敗：全部`batch_preflight_rejected`，零mutation。
- 前綴部分成功後遇到failure：Report為`partial`，後續`batch_not_attempted`。
- 任一attempted item unknown：Report為`unknown`，後續不送。
- Crash後只用完整inventory重新分類；Delete另要求exact-read absence。Recovery沒有archive、unarchive或
  delete replay路徑。
- Codex先前成功的item不能rollback，因此不得把sequential batch描述成atomic provider transaction；
  SQLite Report／membership finalization本身仍是atomic。

## 已覆蓋測試

- 第二筆Archive failure後第三筆沒有request。
- 全批preflight drift時沒有任何provider mutation。
- Active → Trash batch成功後加入全部membership。
- Trash → Active batch成功後移除全部membership。
- 多筆Trash → Deleted皆有dual-absence時，同一Report建立多筆tombstone。
