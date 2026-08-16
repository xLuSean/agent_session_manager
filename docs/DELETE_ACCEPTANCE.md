# Permanent Delete acceptance evidence

## Status

單筆與checkbox batch的Trash → Deleted人工驗收已完成。本文件整理既有的App-owned SQLite證據與使用者測試回報；建立本文件時沒有再送出`thread/delete`，也不把補文件當成重新執行不可逆操作的授權。

驗收範圍是Codex runtime `0.147.0`。私有驗收紀錄確認single與batch finalization都曾完成；public
repository只保留安全契約與合成範例，不公開真實Report／Preview ID、時間、項目數、tombstone統計或
runtime checkpoint。下方資料明確標示為mock data，不應被引用為某次真實操作的readback證據。

## Safety contract

Permanent Delete只有在以下條件全部成立時才可能成功：

1. Selection中的每一筆都必須屬於Manager Trash Bin；Active或Archive不能直接Delete。
2. 一份persisted Preview凍結完整selection、identity、native state、protection evidence、manifest與期限；確認後不得偷偷縮小batch。
3. Delete要求使用者輸入exact confirmation token。SQLite只保存token hash，不保存或輸出token明文。
4. 每一筆在送出前都重做operation-specific preflight：pinned與pinned-descendant必須known clear、descendant count必須verified zero，任何positive running/current evidence都阻擋。Cross-host running/current unknown只代表request可能失敗，不得冒充verified clear。
5. 每一筆最多送出一次official `thread/delete`；failure或unknown後停止batch，後續項目標為`batch_not_attempted`，不得自動retry。
6. Success必須同時取得fresh complete inventory omission與audited exact-ID readback absence。只有其中一項時是unknown，不得標成success。
7. Success finalization在同一SQLite transaction中移除Trash membership、建立Deleted tombstone、保存itemized Report並consume Preview。Failure或unknown保留Trash intent。
8. Startup recovery只做readback，不重送Delete。

實作契約位於：

- `CodexNativeBatchCoordinator.swift`：batch逐筆執行、雙absence分類與stop-on-non-success。
- `DeleteMutationExecutor.swift`：單筆operation-specific preflight與雙absence readback。
- `SQLiteStateRepositories.swift`：成功後原子移除Trash membership、建立Deleted tombstone並保存Report。

## Sanitized evidence example

以下全部是mock data，只示範durable evidence的結構。真實私有驗收資料不包含在public repository。

| Evidence | Synthetic readback example |
| --- | --- |
| Report ID | `00000000-0000-4000-8000-000000000001` |
| Preview ID | `00000000-0000-4000-8000-000000000002` |
| Operation / intent | `permanently_delete` / `permanently_delete` |
| Preview state | `consumed` |
| Preview item count | 2 (synthetic) |
| Token / manifest evidence | hashes present; plaintext omitted |
| Report outcome | `success` |
| Report counts | total 2、succeeded 2、failed 0、unknown 0 (synthetic) |
| Item readback | both synthetic items are `success` with `observed_native_state = absent` |
| Completion | `2026-01-01T00:00:02.000Z` (synthetic) |

Mock item evidence times are `2026-01-01T00:00:01.000Z` and `2026-01-01T00:00:02.000Z`。這個
範例只說明同一batch Report如何關聯多筆Deleted tombstone，不代表任何真實session或目前Trash狀態。

### Private acceptance summary

- 私有人工驗收涵蓋single與multi-item batch。
- 精確項目數、Report groups、timestamps與tombstone totals已從public文件移除。
- 真實成功仍以版本化實作要求的fresh complete inventory omission、exact-ID readback absence與原子
  SQLite finalization為準；上方mock table不構成獨立證明。
- Aggregate protection checkpoint不是Delete的唯一gate；operation-specific positive protection與
  unknown pin／pinned-descendant仍阻擋，cross-host running/current unknown只進入one-shot／fresh-readback
  合約。

## Evidence limitations

- 私有人工驗收確認Delete與batch Delete可用，但public repository不保存可識別的SQLite snapshot。
- `operation_items`只保存最終`absent`；雙absence仍由版本化程式契約要求，mock table不等同兩份原始
  response。
- Public文件無法重建任何真實Preview、token hash、manifest、Report item或Deleted tombstone。
- 文件沒有直接讀寫Codex的JSONL、SQLite、cache或內部session檔案。

## When acceptance must be repeated

不要只為了文件、日常build或DMG重新執行Delete。只有下列安全契約發生實質變更，且使用者另外明確授權一個可犧牲的exact session時，才需要新的人工驗收：

- Codex runtime或`thread/delete`／exact-ID absence contract改變。
- Delete success分類不再要求兩份fresh absence evidence。
- Batch ordering、stop-on-non-success或no-retry行為改變。
- Trash membership、Deleted tombstone、Preview／Report finalization transaction或相關schema migration改變。
- Shipping App的Fixture boundary或provider wiring改變到可能影響live mutation route。

任何新驗收都必須建立新的frozen Preview、使用新的typed token、保存完整Report，且unknown結果只能readback調查，不能重送Delete。
