# Debug Knowledge Index

Last updated: 2026-08-15 (Asia/Taipei)

這個目錄保存 Agent Session Manager 開發期間的踩雷紀錄、證據與修復經驗，並由 Git
正式追蹤。它從被 `.gitignore` 排除的 `tmp/debug/` 遷入 `docs/debug/`，避免重要知識只留在
單一工作目錄；內容仍是除錯知識庫，不取代 Architecture、Safety、Handoff、Roadmap 或 TODO。

## 分類

| 主題 | 文件 | 搜尋關鍵字 |
| --- | --- | --- |
| 狀態與使用者意圖 | [state-model.md](state-model.md) | Archive, Trash, manager intent, native state |
| 安全與 outcome 證據 | [safety-and-evidence.md](safety-and-evidence.md) | fail closed, readback, no retry, SQLite report |
| Codex runtime 與 transport | [codex-runtime-and-transport.md](codex-runtime-and-transport.md) | userAgent, --version, PATH, writer, App Server |
| SQLite 與 frozen Preview | [sqlite-and-timestamps.md](sqlite-and-timestamps.md) | millisecond, Date, manifest, transaction, Preview |
| Lifecycle UI 與 async 防重入 | [lifecycle-ui-reentrancy.md](lifecycle-ui-reentrancy.md) | duplicate submit, consumed, isSubmitting, actor reentrancy |
| Permanent Delete lifecycle | [permanent-delete-lifecycle.md](permanent-delete-lifecycle.md) | thread/delete, dual readback, protectionComplete deadlock, operation-specific gate, tombstone, no retry, recovery |
| Native checkbox batch | [native-checkbox-batch.md](native-checkbox-batch.md) | batch, preflight, batch_not_attempted, SQLite v8, tombstone grouping |
| Diagnostic Logs | [diagnostic-logging.md](diagnostic-logging.md) | Report History, JSONL, retention, redaction, Unified Logging, Xcode target |
| SwiftUI layout 與尺寸記憶 | [swiftui-layout-and-persistence.md](swiftui-layout-and-persistence.md) | NSViewRepresentable, TableColumn, pane width, UserDefaults |
| Xcode target 與 App bundle | [xcode-target-selection.md](xcode-target-selection.md) | missing bundle identifier, SwiftPM executable, scheme, window tabs |
| Shipping Fixture 邊界 | [shipping-fixture-boundary.md](shipping-fixture-boundary.md) | Codex Live, test-only target, target linkage, Release binary, DMG |
| Local Git hooks | [local-git-hooks.md](local-git-hooks.md) | pre-commit, verify.sh, core.hooksPath, opt-in, build cache |
| 實戰診斷流程 | [debugging-playbook.md](debugging-playbook.md) | SQL, checklist, Xcode, tests, triage |

## 目前最重要的結論

- Codex Archive 與 Manager Trash 是不同使用者意圖，即使 native state 同為 Archived。
- `initialize.result.userAgent` 是 client identity，不是 Codex runtime authority。
- Runtime 必須取自同一個即將執行 App Server 的 Codex executable 的 `--version`。
- Frozen Preview 的時間必須在 manifest hashing 前正規化到 SQLite 毫秒精度。
- UI 顯示錯誤不代表 lifecycle 失敗；durable Report 加 fresh native readback 才是 outcome。
- Async confirmation 需要 UI latch 與 model guard 兩層防重入。
- SwiftUI macOS App 必須從正式 `.app` target 啟動；不要保留同名 SwiftPM executable 讓 Xcode 誤選。
- 所有不確定 lifecycle outcome 都不得自動 retry。
- Diagnostic Logs只是bounded App timeline，不是lifecycle outcome authority；成功與否仍以durable Report加fresh native readback為準。
- Swift Package tests只涵蓋Core；新增SwiftUI檔案後還必須加入正式Xcode App target並build該`.xcodeproj`。
- 隱藏 Fixture UI 不等於移除 Fixture；必須拆成 test-only target，並同時驗證 App source、Xcode linkage 與 Release binary。
- Permanent Delete只能從Manager Trash開始；Archive不得直接Delete。0.147.0只有在complete inventory省略exact ID且exact `thread/read`同時回傳`-32600 / thread not loaded: <id>`時，才能建立Deleted tombstone。
- `protectionComplete`是彙總診斷，不能直接當作Delete的絕對gate。positive pinned/running/current與unknown pin/descendant仍阻擋；只有cross-host running/current unknown時顯示`attemptMayFail`並允許one-shot Delete，failure／unknown保留Trash且不retry。
- 複合 Active ↔ Trash 只在 native success readback 後原子套用 SQLite membership；failure／unknown
  保留原 intent，crash recovery只讀不重送。
- Native checkbox batch必須以一份multi-item Preview/token凍結完整selection並先做全批preflight；
  Codex逐筆執行遇到non-success即停止。SQLite v8讓同一Delete batch Report可關聯多筆tombstone。
- Active → Trash 的 frozen Preview 必須帶 working directory；否則成功建立的 membership 會失去原
  Project 位置。舊資料只允許唯一 basename 對應，不可猜測。
- SwiftUI `ideal width` 不會強制恢復 divider，private split introspection也可能抓不到。第一次
  App-owned split 因 `NSHostingController` 的預設 intrinsic sizing 把三欄壓縮；修正版將
  `sizingOptions` 清空、讓 root 填滿 pane，並以固定 `NSSplitView` autosave identity 完成 divider／
  Sidebar 收合狀態跨重啟記憶。`--legacy-navigation-split` 保留為診斷回退。
- SwiftUI Table 的啟動 layout 會發出程式化 column resize；不能把每次 resize 都當成使用者操作。
  `NSTableHeaderView` 的 nested tracking loop 也可能讓 local monitor 收不到 mouse-up、probe 收不到
  resize notification。修正版從 header mouse-down 開始，以 `.common` run-loop timer 只保存實際變動
  的欄寬，並以 left-button state 結束；隔離 bundle 已完成真實 340→420 拖曳與完整重啟 readback，
  使用者也已在正式 Xcode Run 中確認 `⌘Q` 後再次 Run 仍保留欄寬。

## 已證實的第一筆 real Restore success

- Native session ID: `01900000-0000-7000-8000-000000000007` (synthetic public placeholder)
- Manager Report outcome: `success`
- Readback native state: `active`
- Evidence timestamp: omitted from the public repository
- 當時 UI 隨後出現錯誤，是成功後的第二次 UI execute 被 consumed Preview 擋下，
  不是第二次 native request，也不是 Restore 失敗。
