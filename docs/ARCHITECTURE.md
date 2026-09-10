# 架構

ASM 是原生 macOS SwiftUI App。它讀取 Codex 對話清單，用自己的 SQLite 保存管理意圖與操作證據；官方 lifecycle、Desktop 殘留清理及全域設定清理是分開的權限邊界。刪除判準見[安全規則](SAFETY.md)，資料表見[資料庫](SQLITE_SCHEMA.md)。

## 元件分工

```text
SwiftUI View
  └─ MainActor model：選取、預覽、送出鎖、畫面狀態
      ├─ 唯讀 provider → 官方 App Server inventory / exact read
      ├─ lifecycle coordinator → 受限的 Archive / Restore / Delete facade
      ├─ Ghost coordinator → 掃描、凍結批次、確認、備份、一次清理
      ├─ global-state coordinator → 獨立 diff 確認與逐檔套用
      └─ manager SQLite → 意圖、預覽、claim、逐筆報告、恢復紀錄
```

View 不呼叫 shell、SQL 或通用 RPC。唯讀 provider 不暴露 mutation API；各操作透過獨立受限 facade。Fixture 與 research harness 在獨立 target，不能因隱藏 UI 就宣稱未進 shipping binary；來源、Xcode 連結和 binary 都要驗證。

## 清單來源與分類

[CodexAppServerProvider.swift](../macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexAppServerProvider.swift) 擁有 transport 與 runtime 准入。唯讀方法限制為 initialize／initialized、config/read、thread/list，以及明確 review／readback 用的 thread/read(includeTurns=false)，不提供通用公開 request 入口。

active 與 archived 分開分頁讀取，互動清單使用 cli／vscode 來源、updated_at 遞減、useStateDbOnly=true。每頁 50 筆，每個 collection 最多 200 頁／10,000 個唯一 ID。游標原樣傳回、依 ID 去重；只有 nextCursor 結束才算完整。重複游標、截斷或上限標為 Degraded，不改用 JSONL 掃描修補，也不推進完整 checkpoint。

精確 `0.153.4` 另有唯讀的空摘要補入器：從 `state_5.sqlite` 找出 `preview=''` 的 cli／vscode 候選（最多 1,000 筆），要求受支援目錄中、檔名含精確 ID 的 JSONL 對話檔存在，並逐 ID 使用 `thread/read(includeTurns:false)`。ID、sessionId、cwd、非暫存狀態與置頂證據須相符，前後候選資料須一致，才依 canonical archived 欄位補入清單；任何失敗不發布部分完整 inventory。其他版本不套用此相容邏輯。補入標籤只供顯示與搜尋，不是操作授權。

完整 inventory 與 lifecycle-only readback 都使用相同補入器，避免 Archive 後漏項被誤認為不存在。canonical spawn edges 顯示候選有子對話時，子對話保護標為未知，既有 executor 仍拒絕。`0.153.4` 的官方精確 not-loaded 回應還須核對 canonical ID 缺席，以及 sessions／archived_sessions 中沒有同 ID 檔案；不可讀、連結、超出遍歷上限或殘留都使缺席證據不可用。這些檢查不修改 Codex 資料，也不取代後續 Desktop／全域設定清理。

子對話保護使用獨立 all-source active／archived inventory；它不是主要瀏覽清單。置頂資訊須符合前後一致的 Desktop pin snapshot，並與官方欄位沒有衝突。未知不能當成未置頂；跨主機 running／current 缺乏負面證據時保持未知。

Project 來自 Desktop local-projects 的路徑對應；Working Folder 是 thread.cwd；Trust Folder 來自 config/read 中最長符合的設定路徑。Git metadata 不是 Project fallback。未知大小不估算，也不為顯示容量而讀 rollout 內容。

管理狀態由原生狀態與本機意圖合成：

| 官方觀察 | ASM 意圖 | 呈現 |
| --- | --- | --- |
| Active | 無 Trash membership | Active |
| Archived | 無 Trash membership | Archive |
| Archived | 有 Trash membership | Trash Bin |
| Active | 有 Trash membership | Conflict |
| 完整清單缺席 | 有既有管理紀錄 | 待查外部刪除，不直接認定 Deleted |
| 清單不完整／不可用 | 任意 | Unavailable，保留既有意圖 |

Reconciliation 是純判斷，再以 manager transaction 保存 checkpoint／結果。inventory completeness 與 protection completeness 是不同欄位；未知計數不顯示成 0。時間先正規化為 SQLite 毫秒精度再參與 hash。

## 官方 lifecycle

正常路徑為：凍結 Preview → 保存與回讀 → 明確確認 → durable claim → 最多一次官方 request → 較新正式回讀 → 原子保存 Report 與 consume Preview。

Archive／Restore 各自要求 Archived／Active 回讀。Move to Trash 保存延後的 add 意圖；Trash Restore 保存 remove 意圖；只有原生成功才在 Report transaction 修改 membership。Reapply Trash 另綁完整 membership-set hash，成功也不增減原意圖。

一般 checkbox batch 凍結同一組完整 ID，先全批檢查，再依固定順序逐筆官方 request；遇第一個 failure／unknown 停止，其餘標 notAttempted。這與 Ghost 的單一資料庫交易不同，不能宣稱官方多個 request 跨項目原子化。含子對話的 affected-set 模型與 tables 不代表正式 executor 已放行，未支援範圍仍拒絕。

批次每筆操作後使用 lifecycle-only readback：新的 App Server 連線、完整分頁的 Active／Archive 清單，保留截斷與重複游標檢查；Delete 另需精確 ID 不存在證據。不重讀專案、信任設定、全來源子對話圖。這些保護資料明確標為 unavailable，不得用此回讀授權新操作；全批 preflight 和 recovery 仍使用完整 inventory。

中斷後的 lifecycle recovery 只有 inventory／exact-read 能力，不能重新送 Archive、Restore 或 Delete。證據足夠才能完成同一操作的 manager finalization；不完整或漂移保留 executing。UI acknowledgement 或通知不直接產生成功。

## Delete 接續 Desktop 清理

官方 Delete 的成功子集必須有完整的 canonical absence 證據。ASM 保存 tombstone 與原 Report，再把這整組成功 ID 交給 Desktop cleanup；失敗或不明項目不混入。

每個移交 ID 只能是已無殘留或可清理的已分類 Ghost。任一 blocked／unconfirmed 使整組停止；部分已無殘留仍留在原範圍，以 alreadyAbsent 報告，不縮小選取。

Final Review 後、執行前，manager 保存不可替換的 canonical-to-Bulk binding，綁定原 Delete Report、ID 集合、receipt、plan、verified backup 與原 journal hash。已存在 binding 只能回到同一操作，不能換新計畫。完成狀態由 tombstone、binding 與原 journal 推導，不另保存第二套成功旗標，也不把歷史結果說成當下全域不存在。

## Ghost 掃描與執行

掃描以 version-bound 本機 canonical 資料的私人暫存副本、官方 exact read 及完整保護清單分類；正式入口另有存在對話的 present control，讀取控制失敗不發布部分可操作清單。不建立長期 Snapshot 或要求 Deleted witness。

畫面 scan identity、selection 與 inventory digest 共同凍結範圍。使用者確認一次，App 內部保存 Preview、challenge、receipt；awaitingShutdown 後的繼續按鈕承接相同授權，不是第二次確認。Final Review 才取得驗證備份並準備一次執行。

| 階段 | 可做的事與限制 |
| --- | --- |
| 未確認掃描 | 可調整選取；切換人工模式清空選取 |
| 已確認、計畫準備前 | 鎖住原 ID；因資料庫占用可明確重新檢查，不重送官方 Delete |
| prepared | 已綁定計畫與備份；不能直接丟棄並重建，需要原操作的關閉或執行規則 |
| claimed／attempted | 最多一次 attempt；不重新確認或重送，只能同一操作回讀／恢復 |
| terminal | 查看原結果；新掃描不會重啟舊操作 |
| closed_before_attempt | 明確關閉未執行計畫，不冒充刪除成功 |

preparing／running 期間同步送出鎖與 model guard 同時防重入，並阻擋選取、dismiss、disable 和 reset。成功結果更新待處理清單與計數，保留報告；不背景重新掃描。

## 恢復與未執行計畫關閉

查看 previous-operation 只讀 manager journal；未完成時回報 recovery required，不順帶讀寫 Codex 或結案。

獨立 fresh recovery 使用原 claimed／attempted 計畫與新唯讀證據，只能補寫同一 journal 的結果。manager transaction 重新比對 phase、identity、plan／receipt／claim／attempt digests，再 compare-and-set 與回讀。claimed 且證明未套用可記 notAttempted；attempted 必須依原計畫的前後狀態判定，混合或不足證據不能標 success。prepared 沒有 claim，不能造一份 claim 或 terminal Report 來結案。

prepared 的關閉是獨立 manager-only 確認：凍結原 plan、receipt、backup、全部目標與 journal hash，保存 closure，attempt count 保持 0。它不刪 session 或歷史，也不授權再次執行。寫入回覆不明時查證同一 closure intent，不盲目重試。冷啟動遺失原 challenge 後的 receipt-only discovery 尚列於[後續方向](ROADMAP.md)。

一次執行、fresh recovery 與計畫關閉共用 manager 儲存目錄上的 nonblocking advisory lock，驗證持有目錄的 device／inode。此鎖只協調採用同一機制的 ASM，不是 Codex 官方全域維護鎖，因此不能取代 Codex owner 與資料庫占用檢查。

## 全域設定清理

[CodexGlobalStateCleanup.swift](../macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexGlobalStateCleanup.swift) 是清理成功後的獨立入口。預覽只在記憶體保留五分鐘，綁定精確 ID、來源 bytes 與待移除語意 diff。套用時重新檢查不存在證據、關閉狀態及來源，再保存私人備份與 pending／verified 紀錄，逐檔原子更新。

主檔與 .bak 不是跨檔交易；部分完成需保留證據，不自動還原。這些紀錄與備份不納入一般 manager Report 的保留清理。

## UI 開發約束

- 列焦點、checkbox selection 與搜尋獨立；確認範圍不得隨搜尋改變。
- Preview 與 Report 使用單一呈現狀態，不能同時疊兩個送出入口；同步 latch 必須在 await 前設置。
- 主視窗最小 860 × 560；結果 sheet 依可用螢幕限制尺寸，長內容在中間捲動，底部動作固定可見。
- 清單保留 title 與完整 ID；不可用 title 不猜測，完整身份不可只靠截斷標題。
- hover 資訊不得搶焦點或攔截點擊；checkbox 的點擊區保持列內，不用透明覆蓋層破壞選取。
- 原因由 model 提供，不能只用顏色表達或把不支援操作無聲隱藏。
- 分隔位置與欄寬保存；視窗恢復不改啟動預設 Active。
- SwiftUI target membership、編譯測試及人工畫面檢查是不同驗證，不相互取代。
