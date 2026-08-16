# Permanent Delete lifecycle 踩雷與修復紀錄

Last updated: 2026-08-14 (Asia/Taipei)

## 1. 「schema有thread/delete」不等於「空response就是成功」

- 本機`codex-cli 0.147.0`生成schema含stable `thread/delete`。
- Request只有exact `threadId`，response是空object，另有`thread/deleted`notification。
- 空response／notification都不足以證明資料之後真的不存在；timeout也可能是request已套用但ack遺失。

修復：request最多一次，之後必須做兩份較新的官方readback：

1. complete active＋archived inventory不含exact manager/native ID。
2. `thread/read(includeTurns=false)`對同一ID回傳精確`-32600`與`thread not loaded: <id>`。

只有兩者同runtime、同ID、都晚於mutation attempt才是success。任一缺失／矛盾就是unknown，不retry。

## 2. Generic not-loaded error不能全域當作Absent

一般Conflict Review仍沒有官方通用not-found typed contract。若全域把任何`thread not loaded`升級為Absent，transport failure、版本漂移或不同error message都可能誤刪manager intent。

修復：只在exact allow-listed 0.147.0 Delete executor／recovery內匹配完整message，且必須與complete inventory absence成對。其他caller仍回報Unavailable。

## 3. Archive與Trash都是native Archived，但Delete authorization不同

Codex native state無法表達使用者是「長期保留」或「準備刪除」。若只檢查`nativeState == archived`，Archive會被誤當成Delete candidate。

修復：Delete Preview必須同時找到SQLite `trash_memberships` exact record，並凍結完整membership-set hash。Archive row必須先用另一份manager-only Preview移到Trash；不能直接Delete。

## 4. Delete後row不能只從live inventory消失

若success只移除Trash membership，reload後session會完全消失，Deleted sidebar永遠是0；若用Report History重建Deleted，使用者清除Report History又會讓Deleted消失。

修復：SQLite v7新增`deleted_sessions` durable tombstone；v8將`delete_report_id`改為可重複的indexed grouping key，使一份batch Report可對應多筆tombstone。Native absence success時，在同一transaction：

- 移除exact Trash membership；
- 插入Deleted tombstone；
- 寫itemized Report；
- consume Preview。

Tombstone不以foreign key依賴operation report，因此history retention／clear不會移除Deleted collection。

## 5. 不可宣稱released bytes

`thread/delete`證明provider identity absence，不代表我們量到rollout/cache實際釋放多少磁碟空間。

修復：Delete Report固定`releasedBytesComplete=false`、item bytes為`nil`；UI明確說不估算或宣稱released disk space。

## 6. Crash recovery不能持有Delete transport

若App在request後、Report commit前中斷，Preview停在`executing`。直接retry可能把已刪除的session再送一次Delete，並使結果更難判定。

修復：`CodexNativeDeleteRecoveryCoordinator`只依賴read-only inventory／exact-read protocol，型別上沒有`delete()`。雙absence可補寫success；雙Present可補寫unknown；證據不足保留executing，等下次唯讀recovery。

## 7. Swift Package test不會自動驗證Xcode App file list

新增`NativeDeleteSheets.swift`後，Core tests全過但Xcode App build找不到sheet symbol，因正式`.xcodeproj`使用明確PBX file/build list。

修復：同步加入PBXFileReference、PBXBuildFile、group children與PBXSourcesBuildPhase，並必須跑完整`xcodebuild`，不能只靠`swift test`。

## 8. 驗證重點

- SQLite v6→v7 migration有pre-migration backup；故意失敗會rollback並保留backup。
- Success需要雙absence，且只送一次Delete。
- RPC rejection＋雙Present為failure；inventory-only absence為unknown。
- Protection drift在request前停止。
- Success才移除Trash並建立tombstone；failure／unknown保留Trash。
- Interrupted recovery不重送Delete；absence不足時Preview維持executing。
- 完整Xcode Debug App build成功。

## 9. 把aggregate protectionComplete當成Delete gate會造成永久死鎖

症狀：Manager Trash已正確選取，`thread/delete` capability與Trash membership也都存在，
但Delete按鈕仍停用，只顯示「Refresh a complete Codex inventory with protection」。重複Refresh不會改善。

根因：`protectionComplete`是provider-wide彙總診斷，要求pinned、running、current與descendant
證據全部已知。Manager啟動的App Server與Codex Desktop不是同一個lifecycle host，因此
running/current negative evidence通常無法跨host證明。把這個aggregate欄位同時硬接在UI、Preview
persistence、單筆executor與batch preflight上，等於讓Live Delete永遠無法開始；這不是Codex沒有
Delete API，而是manager自己的gate過度保守。

修復改為operation-specific Delete policy：

- 已知`pinned`、`running`、`current`或`hasPinnedDescendant`為true：阻擋。
- `pinned`或pinned-descendant evidence未知／漂移：阻擋。
- running/current只有cross-host unknown：保留為`attemptMayFail`警告，不偽裝成clear；允許送出一次
  official `thread/delete`。
- provider拒絕、readback仍Present或outcome無法證明：failure／unknown，保留Manager Trash，絕不
  自動retry。
- 只有fresh complete inventory absence與exact-ID absence同時成立，才移除Trash membership並建立
  Deleted tombstone。

這項政策必須在UI eligibility、Preview claim、單筆／batch preflight與recovery validation一致；
只改按鈕會讓Preview或executor在下一層再次被相同的aggregate gate擋住。

回歸測試必須涵蓋：cross-host running/current unknown可嘗試一次、unknown pin仍阻擋、positive
protection drift在request前停止、Delete rejection保留Trash，以及batch遇到non-success後停止。
