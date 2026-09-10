# 開發指南

這份文件集中建置、驗證、打包與診斷。App 操作見[使用手冊](USER_GUIDE.md)，不可繞過的資料邊界見[安全規則](SAFETY.md)，交付版本見[驗收狀態](VALIDATION.md)。

## 開發環境與建置

需要 macOS 14 以上、完整 Xcode 與其命令列工具、Swift 5.10 工具鏈及 Node.js。SQLite 使用 macOS SDK 的 libsqlite3；Swift Package 沒有外部套件依賴。

正式 App 專案位於：

```text
macos/AgentSessionManager/App/AgentSessionManager/AgentSessionManager.xcodeproj
```

使用 Xcode 的 AgentSessionManager scheme 建置與執行。Shipping App 直接使用 Codex Live，沒有 Fixture／Live 切換或啟動環境覆寫。測試用 Fixture 屬於獨立 target，不能連結進正式 App。

## 驗證入口

從 repository 根目錄執行：

```bash
./scripts/verify.sh
```

這是一般開發的單一驗證入口，涵蓋腳本、shipping Core、research Core、正式 App 的獨立測試與 shipping boundary。它不授權真實對話操作；runner 會移除 live acceptance 環境開關，不能為了讓一般測試通過而加回去。

針對性開發可先執行：

```bash
swift test --package-path macos/AgentSessionManager
./scripts/verify_shipping_boundary.sh
node scripts/verify_documentation.mjs
```

最後一個指令檢查八份文件與本機連結。腳本測試也可單獨執行：

```bash
node --test scripts/tests/*.test.mjs
```

### scripts 的分工

- 根層只留驗證、打包、相容性稽核、Git hooks 與版本限定的隔離驗收入口；隔離 runner 仍需當次明確授權，不隨一般驗證執行真實刪除。
- lib/ 只放相容性稽核的共用邏輯；fixtures/ 保留目前回歸測試引用的去識別版本證據。
- tests/ 按功能測試相容性、打包前置檢查、隔離 runner、安全邊界與 repository 維護；tests/support/ 是測試專用的來源讀取與檢查，不是可執行的清理工具。
- verify.sh 自動納入所有頂層 *.test.mjs，並繼續執行既有 Swift、App 與 shipping boundary 驗證。

E／M4f 階段性實驗、舊手動 Python 清理器、一次性 canary 授權與文件措辭測試已退役，不搬到另一個 archive 目錄。Git 保存歷史。仍有效的版本／來源配對、present control、備份與 receipt 綁定、批次規模、一次執行與 UI 入口檢查改按功能保留，直接檢查現行 Swift 來源；不再先把程式改回歷史狀態才測。這些靜態檢查補充而不取代 Swift 的實際行為測試，原有 Swift 測試未因此刪除。

目錄準備以現行 FixedDirectoryPrepareCoordinator 為準。已被取代的 E47 測試介接層、E56 ExistingRootPrepareCoordinator 及其專用 Swift 測試已移除，歷史留在 Git；現行目錄準備、碰撞／符號連結保護與重複執行防護測試保留。研究模式不是保留失效原型的理由，但舊資料庫升級、歷史紀錄讀取及復原所需的相容程式不在移除範圍。

E24 的 DisposableCoordinator／DisposableExecutor 及專用 Core、App 演練測試也已退役。共用 DisposableBundle 仍供快照研究測試使用，其路徑與符號連結保護測試獨立保留；目前批次清理的交易、備份、部分失敗與不重送測試，以及舊操作紀錄讀取均不變。

Core 測試通過不代表 SwiftUI 已連入 Xcode target。修改 App 或共用 UI 來源時，需用正式專案建置及 App 測試；畫面是否可用則由使用者依手冊人工確認。只有文件與連結調整時，檢查文件和受影響的腳本測試即可，不重建 DMG。

部分隔離測試以 macOS Trash 清除自己建立的暫存測資。在受限沙箱執行時，若失敗位置是 dispose／trash 或清理後檔案仍存在，先核對權限，再授權重跑同一驗證；不改用永久刪除、不跳過斷言，也不開啟 live acceptance 開關。

## Codex 更新後

先執行唯讀稽核，不先要求使用者關閉 Codex 或挑對話測刪：

```bash
./scripts/run_codex_update_compatibility_audit.sh
```

它分別辨認 Desktop 內建 runtime、ASM 實際選用的 provider runtime，以及 Desktop SQLite 契約。公開 schema 與固定 metadata-only 查詢只提供相容性證據，不讀 session row、不寫 SQLite、不送出 lifecycle request，也不改 allow-list。

檢查報告的三種判斷：ready 可進下一個已授權步驟；review_required 需要人工檢視差異；blocked 保持停止。即使 schema 相容，新版本也只是待審候選，不能直接放行 Delete。稽核的零讀取／零寫入欄位應維持 session_rows_read、sqlite_writes、lifecycle_requests_sent 為 0，mutation_authority 為 none。

Ghost 分項的 ready_current_build 表示符合目前程式契約；candidate_requires_runtime_admission 表示仍需版本准入；blocked_schema_drift 表示資料庫結構不符，不能繞過。這些是診斷結果，不是刪除授權。

只需要 lifecycle 診斷時：

```bash
./scripts/run_codex_lifecycle_update_audit.sh
./scripts/verify_lifecycle_runtime_compatibility.sh archive move-to-trash permanent-delete
```

實際准入以 [CodexAppServerProvider.swift](../macos/AgentSessionManager/Sources/AgentSessionManagerCore/CodexAppServerProvider.swift) 的 supportsVerifiedLifecycleContract、supportsVerifiedDeleteContract 與 supportsVerifiedExternalDeletionReadbackContract 為準。三者獨立，Archive 通過不能推論 Delete 通過。版本取自實際 executable 的 --version，不取 initialize 的 userAgent，也不猜 GUI 與互動 shell 使用同一份 CLI。

需要新版本不可逆驗收時，另行取得精確範圍授權並使用隔離資料。一般驗證、schema 稽核與歷史成功紀錄都不能代替這項授權。

## 版本與本機候選版

版本唯一來源為 `macos/AgentSessionManager/App/AgentSessionManager/Config/Version.xcconfig`，Debug／Release 共用。包含對外三段版本、獨立 build 與 `ASM_RELEASE_SUFFIX`；不使用日期、Git commit 數或功能名稱當版號。

- 一般候選增加 patch 與 build；舊 patch 小於 100 時，第一個新候選從 100 開始。`--next-minor` 明確增加 minor、patch 回到 100；build 不歸零。
- 後綴預設保持原值（例如 `alpha.1`），不自動增加 alpha 序號。`--final` 產生下一個無後綴候選，不等於驗收通過。major 或 alpha／beta 通道變更須另外檢查並提交版本檔。
- patch 上限 999，build 為 1…9999；達上限停止，不自動歸零。這是本專案政策，不是平台通用限制。
- 一般編譯、測試、`plan`、`finalize` 不增加版本。下一版由 `plan` 計算，文件中的檔名只是範例。

```bash
./scripts/release.sh plan
./scripts/release.sh prepare
# 人工測試確切 DMG 後，將下方占位路徑換成它的 manifest：
./scripts/release.sh finalize dist/<exact>.dmg.candidate.json --tested
```

`prepare` 要求乾淨的 `main`，更新版本、跑完整驗證、只提交版本檔，再從該 commit 匯出來源打包；此時不建立 tag。開發分支必須明確使用 `plan --local`／`prepare --local`，產物會標記為本機用途，不能 finalize 成公開候選。公開前先完成私人歷史整理，再從整理後的 `main` 產生新候選。

每個候選在忽略於 Git 的 `dist/` 產生三份檔案：

```text
Agent-Session-Manager-0.1.100-alpha.1-arm64.dmg
Agent-Session-Manager-0.1.100-alpha.1-arm64.dmg.sha256
Agent-Session-Manager-0.1.100-alpha.1-arm64.dmg.candidate.json
```

build 不放在檔名或 tag，保存在 App「關於」、bundle metadata 與 manifest。manifest 包含版本、build、後綴、架構、來源 commit／tree、預期 tag、成品大小及 SHA-256。校驗碼不是數位簽章或隱私審查證明。

打包檢查 Xcode 來源／binary 出貨邊界、Release 編譯、bundle 版本與來源識別、ad-hoc 簽署、DMG 完整性、唯讀掛載 metadata 及 Applications 連結；不開啟 App 或刪除對話。不接受 `VERSION_OVERRIDE`、`BUILD_NUMBER_OVERRIDE`、`RELEASE_SUFFIX_OVERRIDE`、`ARCHITECTURE_OVERRIDE`。

`finalize` 核對三份檔案及當下 HEAD 後建立本機附註 tag；已存在且證據相同時回報完成，不移動既有標籤。`--tested` 代表操作者確認已人工驗收，不會代替人測試。版本工具不 push、不連 GitHub，也不代表公開前的資安／私人歷史檢查已完成。

同名成品直接拒絕覆蓋。驗證失敗保留版本差異；版本 commit 後失敗視為已消耗號碼。中斷或失敗留下 `dist/.release-lock/transaction.json`，須先檢查來源、成品與紀錄，再將這個確切 lock 目錄移至 Trash；不自動重播打包。`package_dmg.sh [--local]` 只打包已提交的目前版本、不加號，且僅適用於沒有同名成品或中斷交易的情況。

明確安排 lifecycle canary 時，必須使用專用入口：

```bash
./scripts/package_lifecycle_canary_dmg.sh
```

它會在建置前檢查所需操作的 runtime 准入；失敗時不得改用通用打包入口繞過。不要因純文件變更或為了增加驗收次數而製作 canary。

## 問題診斷

1. 私下保存完整提示、完整 session ID、操作及時間，先確認失敗位於讀取、預覽、保存、確認、執行、回讀或結果呈現。
2. 唯讀查看 ASM 原操作與逐筆報告。若 request 可能已送出，RPC acknowledgement、通知、log、畫面或總數都不能代替正式回讀。
3. 核對實際 runtime 與資料庫版本，再以最小的合成測資重現；未知或部分完成不自動重試。
4. App 重入問題同時檢查同步送出鎖與 model guard；時間／hash 問題檢查是否先正規化為 SQLite 毫秒精度。
5. 不以手改 SQLite、換舊 App、刪除 Snapshot 或執行歷史腳本繞過保護。資料庫占用只有計畫準備前可依原確認範圍重新檢查。

診斷 log 是有容量限制的時間線，不是刪除結果的權威證據；不能包含對話內容、prompt、token 或原始 provider payload。提交 issue 前移除私人資訊。

## 發行範圍

目前交付是本機 ad-hoc DMG，未經 Apple 公證；開源不等於公開二進位發行。若未來明確需要對外散布，再安排 Developer ID、hardened runtime／entitlements、公證與 stapling、codesign／spctl 驗證、架構選擇及 clean-Mac 安裝驗收。正式 binary 仍不得包含 Fixture。

### 公開原始碼前的必要檢查

- 審查準備公開的完整內容、圖片、授權資訊與提交歷史；憑證格式搜尋、測試通過或部分資安掃描都不代表全庫審查通過。
- `.handoff/`、本機報告、資料庫與打包輸出不納入來源提交。交接筆記留在本機，不作為產品現況文件。
- 若開發歷史含私人資料，將審查過的乾淨內容 squash 到 `main`，並確認私人提交不是其祖先。一般 merge 不會消除歷史。
- 公開前重新核對 `main`、預計推送的提交及標籤；不要推送舊開發分支、備份 refs、所有標籤或使用 mirror push。若私人歷史曾經上傳，先停止並另行處理；squash 無法收回已上傳的內容。
- 本機的遠端追蹤分支可能過期。取得明確連線／推送授權前，不把本機檢查稱為遠端公開狀態驗證。

2026-09-10 的逐檔靜態審查已涵蓋歷史快照 `2d3e5c5` 的全部 341 個追蹤檔案，範圍與限制見[驗收紀錄](VALIDATION.md)。後續修改與其測試另有紀錄，不自動繼承該次全庫審查結論。開發歷史已於 `e28914d` squash 整合到 `main`，最終檔案內容保持一致；已知含個資的開發提交與檔案物件不在該 `main` 的可追溯歷史中。舊提交識別碼僅作歷史驗收註記，不是發布用 refs。

依使用者決定保留本機 reflog 與 `refs/codex/turn-diffs/*`；它們不屬於一般 `git push origin main` 的推送範圍，不需為原始碼發布而清空。不要使用 mirror push 或分享完整 `.git`。本機遠端追蹤資訊不代表已驗證 GitHub 現況；網路與發布仍由使用者操作。
