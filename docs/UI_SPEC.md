# UI Specification

## Information architecture

主視窗使用 App-owned 三欄 `NSSplitViewController`，三個 pane 仍分別承載既有 SwiftUI Sidebar、
Session table 與 Inspector。`NSHostingController.sizingOptions` 必須維持空集合，讓 AppKit split 擁有
pane 尺寸，不得讓 SwiftUI intrinsic/min/max content constraints 再把三欄壓成非全高 layout。

Split 使用固定 `AgentSessionManager.MainSplit.v1` autosave identity，保存使用者拖曳後的左側 Sidebar、
右側 Inspector divider 與 Sidebar 收合狀態。中間 Session table 的 Session／Project／Working Folder／
State／Updated 等欄寬另行保存。視窗總寬不足時仍以各 pane／column 的 minimum width 為界；可用
`--legacy-navigation-split` 啟動參數暫時回到舊 SwiftUI 容器做故障排查。

### Sidebar

- Agent Systems位於Sidebar最上方並且必選一種provider，不提供`All Agents`。即使目前只有一種system也維持顯示；shipping App固定呈現`Codex Live`列，未來接入Claude時在同一section並列。Agent System可和Status及一個Project／Trust Folder／Working Folder browsing scope同時套用，不屬於Browse By互斥範圍。
- Agent Systems收合時在section label右側顯示目前system，不要求使用者重新展開確認。
- Status Filter：All Sessions、Active、Archive、Trash Bin、Pinned、Deleted，App啟動時預設Active。Status是緊湊的accent row，使用filter圖示與目前值badge與Browse By區隔。它可與目前Agent System及一個Project／Trust Folder／Working Folder browsing scope同時套用；三種browsing scope彼此互斥，切換時不清除Status或Agent System。
- Sidebar item 使用連續、等高的 full-width row hit targets；label、count、左右空間與可見的上下 row 空間都能觸發同一 selection，不保留假性可點擊空白。
- Projects：完整顯示 Codex Desktop `local-projects` 目錄並保留 `project-order`；即使目前 0 個 session 也顯示。Live session 以最長 project root ancestor 配對；Trash row 優先使用進入 Trash 時凍結的 project/path evidence。舊 membership 若沒有 project ID，只在 working-folder basename 唯一對應目前 Project 時補回；多個候選維持空白，不以 Git origin 或 trust entry 猜測。
- Trust Folders：從 Codex `config/read` trust entries 產生，顯示 trusted / untrusted。
- Working Folders：從 `thread.cwd` 產生，與 Project、Trust Folder 可交叉篩選。
- Shipping App不提供Fixture切換；`Codex Live`是Agent Systems browsing入口，不是Fixture／Live product-mode switch。啟動後仍固定連Codex Live，各browse/status類別維持可開闔Disclosure section。
- 底部固定顯示 connection health、Codex Live、capability 摘要，以及最近一次 SQLite checkpoint disposition。

### Session table

- Title
- 完整 native session ID
- Project
- Working Folder
- Manager state
- Last updated
- pinned icon

支援 multi-selection 與 title / ID / project / folder 搜尋。每個 session row 都有獨立 checkbox，使用者不必按 Command／Shift 即可逐筆勾選；所有 lifecycle action 都必須能對這些同 provider selections 建立 batch Preview。只有 Trash Bin 在列表上方提供三態 Select All checkbox bar；Active、Archive 與其他 Status 只有 row checkbox，不提供全選。Trash Select All 只選取當下畫面中符合現有 search／scope filters 的 Trash rows，並清楚顯示 shown／selected count。所有 batch action 以精確 selection keys 建立 Preview，不在確認後重新執行搜尋條件，也不自動排除不合格 item 後縮小批次。

Trash Select All bar 必須維持固定緊湊高度。AppKit-backed checkbox 不得接受 parent 提供的無限垂直
proposal，避免 bar 吃掉中間可用高度並把 Table 推到視窗底部。

Session row 右鍵選單提供與目前 selection/state 相符的 Archive readiness、Move to Trash、Restore、Move to Archive 與 Delete Permanently。Toolbar 不以 ellipsis menu 收合 lifecycle actions；相同五種操作全部展開。Toolbar 使用滑入即顯示的自訂 hover help，不等待 macOS 原生 help tag 延遲；disabled action 也由外層 hit target 顯示具體 blocked reason。

自訂 hover help 使用 nonactivating、`ignoresMouseEvents` 的 AppKit floating panel，不得使用互動式 popover；panel 以可讀寬度顯示、避開來源按鈕並限制在螢幕範圍內，提示出現時第一次點擊仍必須直接觸發原按鈕。

Live mode 顯示「inspect real evidence; no lifecycle request is sent」banner。正常 refresh 會沿 cursor 讀完 interactive 與 all-source active / archived inventory，再與本機 lifecycle membership snapshot 對帳；若因 hard safety cap 或重複 cursor 截斷，health 顯示 degraded，不把 subset 冒充完整 inventory，也不前移 checkpoint。Descendants 只有 all-source graph 完整時顯示數字，否則顯示 unavailable。native Archived 的 Archive ↔ Trash 可建立 production Preview；畫面明示只改 manager SQLite、Codex 維持 Archived，完成後顯示逐筆 readback Report。

Manager state 除 Active、Archive、Trash Bin、Deleted、Unavailable 外，也可顯示 Conflict 與 Externally Missing。兩者都不得降級成 Active 或 Deleted。

### Inspector

- provider 與完整 ID
- Desktop project name / root
- working folder
- matched trust folder / trust state
- native state / manager state
- updated time / measurable size / descendants
- pinned / running / current / pinned descendant protection
- provider capability，以及每個 protection 欄位的 Protected／Verified clear／Unavailable verdict、來源與理由
- reconciliation explanation、inventory/protection coverage 與 checkpoint disposition
- Live store 完成 lazy bootstrap 後的 SQLite path
- Conflict / Externally Missing 顯示 Review Resolution Preview；一般與 unavailable row 不顯示可執行 resolution
- Live 單選可開啟 Archive Readiness：顯示完整 native ID、每個 typed requirement 的 Ready／May fail／Blocked／Unavailable 與理由。若全部 permits attempt，顯示 Create Preview；它只落盤 frozen Preview，不送 request。下一個 sheet 要求使用者 review exact frozen selection 並按下明確 Confirm，不需輸入 token；確認後才送一次 Archive，最後顯示 success／failure／unknown itemized Report。

### Conflict resolution Preview

- Active + Trash 明確標示 manager-only Apply；Externally Missing 維持 read-only，只有 Done。
- 顯示 provider、完整 native ID、observed conflict/native state、reconciliation timestamp、inventory hash 與 runtime。
- Active + Trash：Accept Native Restore 顯示 Ready to apply 與明確 Confirm；說明只移除 App Trash marker、Codex 已經是 Active且不送 lifecycle request。Reapply Trash Intent 在 protection 或 provider lifecycle evidence 不足時顯示 Blocked。
- Test-only Fixture harness可提供一筆標題以 `[Demo Conflict]` 開頭的 Active + Trash row，驗證相同Preview／Confirm／Report flow；shipping App不包含這筆demo或相關UI branch。
- Conflict / Externally Missing 被選取時，Inspector 在 title 下方立即顯示橘色 action panel 與 full-width prominent `Review Resolution Preview`，不得藏在 Location、Lifecycle、Protection 等長內容之後。
- Externally Missing：Keep Pending 是無 mutation proposal；Acknowledge External Deletion 在缺少 authoritative exact-ID absence readback 時顯示 Blocked。
- 每個選項列出未來 Apply 前必須重新驗證的 evidence，以及是否會改 native state 或 manager SQLite state。
- 開啟 Review 時以 `thread/read(includeTurns=false)` 取得 exact-ID evidence；顯示 Present / Absent / Unavailable、evidence kind、RPC code、absence proof、observed time 與 detail。現行 Codex compatibility 只會權威產生 Present；未文件化 missing error 顯示 Unavailable。即使內部 status 是 Absent，沒有 version-exact typed contract 時 UI 仍顯示 absence proof `Not established`。

### Preview sheet

- operation 與 provider
- total count / known size
- warnings
- itemized ID 與 before → target
- Archive、Restore、Move to Trash、Move to Archive 為可逆操作：需要 frozen Preview 與明確 Confirm，不顯示、不要求輸入 token。Permanent Delete 仍顯示 generated token + Copy button，動作按鈕在 exact token 相符前停用
- async execution 期間停用 confirmation controls 並顯示進度；成功後先完整關閉 Preview sheet，再顯示逐筆 Report，避免兩個 sheet binding 競爭
- 未來 live mode 顯示 Preview expiry 與 runtime reconciliation timestamp

### Report sheet

- total / succeeded / failed
- itemized ID、observed final state、error
- released space 與 unknown-size 統計（無可靠provider measurement時必須顯示unknown，不得估算）

## Actions by current collection

| Collection | Primary actions |
|---|---|
| Active | Archive, Move to Trash |
| Archive | Restore, Move to Trash |
| Trash Bin | Restore, Move to Archive, Delete Permanently |
| Deleted | View report only |
| Conflict | Refresh / diagnose only |
| Externally Missing | Refresh / diagnose only |
| Unavailable | Refresh / diagnose only |

所有上表 lifecycle 操作都必須支援 row-checkbox multi-selection batch。Checkbox selection與table row focus必須是兩個獨立狀態：只有點checkbox／Select All／Clear Selection才可增減batch selection；點標題、其他cell或另一列只改變Inspector目前查看的session，不得取消已勾選項目。若任一 selected session 不符合該 transition、provider、protection 或 capability，整批在 Preview／preflight 前 fail closed；UI 應逐項顯示 blocked reason。只有 Trash Bin 額外顯示三態 Select All checkbox bar／Empty Trash，且全選範圍必須在 Preview 中凍結成完整 IDs。macOS SwiftUI Table會對獨立欄套用過大的平台minimum，因此checkbox應併入Session欄最左側，維持固定對齊與方形hit target，但不保留一整欄空白。

已知 Pinned / running / current / pinned descendant 不應只在 Preview 報錯；正式 UI 也應先顯示 lock reason 並禁用危險 action。Unknown pin／pinned-descendant同樣阻擋。Delete遇到cross-host running/current unknown時應保持可用，並在Preview顯示one-shot `attemptMayFail`警告；不能把unknown顯示成verified clear。Core仍須再次驗證，不能信任UI gating。

目前toolbar已依inventory mode、selection、state transition與provider capability禁用action並顯示blocked reason。每個immediate hover提示必須以完整action名稱開頭，再顯示停用原因；不得只顯示`Select at least one`等無法辨識圖示的文字。Live Archive精確單選仍先開readiness review；多選直接建立全批evidence-gated Preview。Active → Trash、Archive／Trash → Active及Trash → Deleted皆支援checkbox native batch；Archived → Trash與Trash → Archive走manager-only atomic Preview。Trash → Archive只取消Manager Trash意圖，不要求aggregate protection checkpoint。只有Trash Bin額外顯示Select All，其他Status仍以逐列checkbox精確選取。Live inventory provider的mutation capability固定為false，所有mutation只能經獨立coordinator。

## Visual language

- Active：green
- Archive：blue
- Trash Bin：orange
- Deleted：red
- Conflict / Externally Missing：red
- Unavailable：secondary gray
- Protection：Protected 使用 orange lock、Verified clear 使用 green shield、Unavailable 使用 secondary question-mark shield
- Codex Live：eye banner；degraded / unavailable health 不使用成功色
- Destructive confirmation：red role + typed token；Delete Permanently 與 Report History clear 都使用高對比 action-required panel、可選取 token、明確輸入欄與 blocked button help。

## Settings (`⌘,`)

- General 分頁固定揭露 retention：Report History 每 provider 500份完整bundle；Diagnostic Logs最多30天、10,000 events、20 MB，任一先到即移除最舊event。
- Logs 分頁提供level/category即時篩選、全文/ID/metadata搜尋、time/level/category/event table、單筆完整ID與metadata detail、可重複Copy，以及全部retained JSONL Export。
- Copy成功後在目前selection存續期間維持Copied，但按鈕持續可用；selection改變才重設。
- Logs不提供lifecycle mutation或另一份Report History；必須明示diagnostics不是outcome authority，且不保存conversation、token、prompt、payload或message body。
- Persistent file不可用時App仍啟動，Settings顯示in-memory fallback與錯誤；不以log failure阻擋session lifecycle安全流程。

## Current limitations

- Live refresh 會一次讀完 cursor pages；尚未提供漸進式載入或進度 UI，極大 inventory 可能需要等待。
- Conflict resolution 的 Accept Native Restore 已有 frozen Preview + Confirm Apply，不要求 typed token；它只改 manager SQLite membership並產生 itemized Report。Reapply Trash Intent 與 Externally Missing resolution 沒有 Apply，也不會自動改寫 native lifecycle。
- Toolbar 的 Report History讀manager SQLite，可篩provider／operation／outcome／時間、搜尋identity/title/project/error code、每頁載入50份並查看完整itemized evidence。JSON／CSV export讀完全部matching retained reports後開啟save panel，畫面固定揭露private-default redaction。Test-only Fixture ledger僅供Core contract tests，不出現在shipping UI。
- Report History 的 Clear Filtered Reports 會先凍結目前 filter 的完整 Report ID set，再要求輸入一次性 confirmation token。Live 只允許單一 provider 的 frozen set；Report/items/consumed Preview 同 transaction 刪除並逐 ID readback，Trash membership、checkpoint、prepared/executing Preview 與 Codex session 不在刪除範圍。任何 drift 或 bundle corruption 整批 rollback。
- Toolbar 的 Maintenance只在既有manager store可用時啟用。Sheet顯示SQLite path、recognized/protected/candidate counts、candidate bytes、policy、每份完整backup path、kind/time/size/verification/0600 evidence、Core typed disposition/reason，以及logical/reclaimable pages、ratio、threshold與future strategy。頂部固定揭露maintenance assessment本身為read-only；沒有Trash/Delete/Compact/Authorize control。Refresh只重跑assessment。
- 官方最新文件已描述 `isPinned`，但本機 0.147.0 schema/runtime 未提供；UI 的 Pin evidence 改由雙讀一致的 Desktop `pinned-thread-ids` 顯示，缺失、漂移或衝突仍為 Unavailable。`status.active` 可顯示 Running Protected；非 active 仍顯示 running Unavailable/May fail。完整 graph + resolved pin values 可顯示 pinned-descendant Verified clear；eligible non-pinned root 可出現 Create Preview。未知的 `false` 不得顯示成 Verified clear。Trash → Archive 是移除待刪 intent，不送 native lifecycle request。
- Permanent Delete、Report History clear 與未來同等不可逆 action 才要求 typed confirmation token；這些 sheet 的 token 顯示欄右側提供立即可用的 Copy button。成功寫入 macOS pasteboard 後，該 token 在目前確認畫面存續期間持續顯示 Copied；按鈕保持啟用，可隨時再次寫入剪貼簿。它不代替使用者在輸入欄貼上並完成確認。
