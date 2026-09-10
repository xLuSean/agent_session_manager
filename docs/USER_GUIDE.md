# 使用手冊

本手冊供使用者操作 ASM 與回報問題；不是要求重新刪除一批資料。已完成的實測及指定 DMG 見[驗收狀態](VALIDATION.md)，自行建置見[開發指南](DEVELOPMENT.md)。

## 開啟正確版本

先退出其他版本的 ASM，再從指定 DMG 開啟 AgentSessionManager.app，或使用已確認版本的安裝位置。不要同時開兩份，也不要透過 Dock／Spotlight 誤開舊版。dist/ 只交付 DMG，不另放 App。

出現「資料庫版本高於支援版本」時先確認 App 版本，不刪除或降版資料庫。若 macOS 阻擋未公證 App，回報原始提示，不停用 Gatekeeper。

## 瀏覽與選取

App 使用 Codex Live，啟動預設顯示 Active。狀態可搭配一個瀏覽範圍：Project、Working Folder 或 Trust Folder。專案、實際工作資料夾及信任設定是不同資料，不能互相代替；無法取得的欄位不猜測補值。

Codex 0.153.4 有些對話因摘要為空而漏列，但仍能依 ID 讀取。ASM 核對本機資料與官方讀取後，將它們補入 Active／Archive，標示 `Desktop automation · local supplement` 或 `Local supplement · official ID verified`。可搜尋 `local supplement` 找到這些對話，或用標題／完整 ID 比對；若找不到，先清除專案、資料夾等範圍限制，再重新整理。

這些是仍存在的對話，不是 Ghost。刪除方式相同：在主清單選取 → Move to Trash → 到 Trash Bin 執行 Delete。補入標籤不取消置頂、執行中及子對話保護；若官方已回報找不到、但本機資料列或任何同 ID 對話檔仍存在，ASM 不會宣告刪除已驗證，也不會自動再送 Delete。

點選列是查看詳細資訊，checkbox 才是操作選取。搜尋只篩選顯示，不清除既有選取；確認前用 Show Selected Only 核對完整範圍，或用 Clear Selection 清空。標題方便比對，完整 session ID 才是識別依據。

切換 Active、Archive、Trash Bin、Deleted 等狀態分類時，會清空搜尋及操作選取，但保留專案／資料夾範圍。沒有符合搜尋的結果時，顯示 No Matching Records 並提供 Clear Search；這不代表該分類完全沒有紀錄。單獨清除搜尋不會取消原本的勾選。

輸入搜尋文字後，各分類會顯示 Select all search results，可全選或取消勾選目前顯示的搜尋結果；專案、資料夾、狀態與 Show Selected Only 篩選仍有效，其他已勾選項目保持不變。沒有搜尋文字時，只有 Trash Bin 保留 Select all filtered。全選只是勾選，不會立刻執行操作，也不解除置頂等保護。

| 狀態 | 用途與操作 |
| --- | --- |
| Active | 可封存，或移入 Trash Bin |
| Archive | 保留的封存對話；可 Restore 或移入 Trash Bin |
| Trash Bin | 等待刪除；可 Restore、改為保留封存，或建立永久刪除預覽 |
| Deleted | ASM 的刪除紀錄，不是可還原的垃圾桶 |
| Conflict／Unavailable | 有狀態衝突或證據不足；先檢視，不視為已刪除 |

### 對話檔大小

主列表的 Conversation Size 會背景加總同一 ID 在 `sessions` 與 `archived_sessions` 的新舊對話檔；詳細資訊顯示相同數字。列表上方的 Sort 可選 Recently updated、Conversation size: largest first 或 smallest first。排序不改變搜尋與勾選，未知大小固定排最後。

數字是對話檔的邏輯大小，不包含專案、共用資料庫、備份及操作報告，也不是保證可回收的磁碟空間。Deleted 列同樣檢查目前剩餘檔案，不顯示刪除前的歷史大小。「—」表示尚未算完、讀取失敗或檔案歸屬不明；例如同一檔名含多個 session ID 時不猜測分配。「0 B」表示本次盤點未找到有大小的匹配對話檔，不是完整刪除驗證。結果保存在記憶體，對話持續增加內容時可按重新整理更新。

人工檢查不必刪對話：比較一筆對話在列表及詳細資訊的大小，再切換兩種大小排序，確認搜尋結果與勾選不變；清除搜尋後選 Recently updated 回到原本順序。

## 檢查 Codex 相容性

### build 16：更新前後的精簡驗收

1. **先不要更新 Codex。** 安裝 compatibility-build16 DMG，開啟 ASM 並重新整理 Codex Live。
2. 到 Settings → Compatibility，按 Check Compatibility，記下 CLI、Desktop App 版本及各功能結果；再按 Run Isolated Compatibility Tests，完成後截圖。
3. 關閉並重開 ASM：相同環境應沿用結果，不自動重跑行為測試。
4. 更新 Codex，開啟 Codex 後回到 ASM 並重新整理：應提示環境變更／重新檢查，不可直接沿用舊的通過結果。
5. 再執行 Check Compatibility 與隔離測試，重開 ASM，確認新環境的結果保存。回報更新前後版本、結果及提醒畫面即可；這次不必刪除任何真實對話。

**此版驗收範圍是版本偵測、提醒、快取及 CLI 功能驗證。新版 Desktop 殘留清理的自動放行尚未完成；即使 synthetic self-test 顯示 passed，也不代表未知 Desktop 版本已可清理。** 若遇到未支援的新結構，正確行為是顯示原因並保持限制。

Settings → Compatibility → Check Compatibility 會在本機檢查 ASM 選用的 CLI、Desktop 執行檔及資料庫結構，分別顯示瀏覽、封存／還原、官方刪除與 Desktop 清理的結果。不連網、不讀取對話本文，也不建立或刪除對話。

Desktop database checks 分別列出 Desktop 目錄、摘要、官方狀態與對話歷史四個資料庫的檢查結果。「讀不到」與「結構改變」會分開顯示；即使版本號相同，缺少必要資料表／欄位或出現未支援的索引、觸發器、外鍵，也不會把 Desktop 清理標示為相容。這仍是必要結構檢查，不是完整 SQL 定義或新版 Desktop 重開行為的驗收。

最多保留 15 組本機環境的檢查結果；重開 ASM、重新整理或回到前景時，比對執行檔指紋、Desktop App 簽章涵蓋的資源／內嵌程式及資料庫結構，不重跑介面生成或行為測試。相同環境直接沿用，切回仍在快取中的舊環境也可沿用。同版本但 App 或 CLI 更換仍要求重查；新增對話不會單獨讓結果失效。遇到新的執行檔時只讀取版本，以便提醒使用者。Desktop application 區域另顯示 App 本身的版本及 build，與 bundled CLI 版本不同；驗證程式內容不代表驗證發布者身分或行為相容性，且不開啟網路驗證。

ASM 的檢查規則更新也會讓舊結果失效。本次規則版本升至 4，修正 App 探索與已知 UNIQUE 索引誤判，因此先前的結果須重新確認一次；不代表每次開啟都要重跑測試。ASM 依 bundle ID 找已註冊的 Codex App，也涵蓋名為 ChatGPT.app 的 Codex。簽章未通過會另行提示，不推翻既有已支援版本的結構判斷，也不放行未知 Desktop 版本。

環境改變、沒有保存結果或部分功能未通過時，主畫面會顯示版本及原因，提供 Review Compatibility 入口。build 16 起，有舊結果但目前環境尚未檢查時，另外跳出明確提醒；啟動即開始比對，不必先等待清單載入。Later 收起詳細提醒但保留入口；同次使用對同一個環境只跳出一次，環境再次改變或重開 ASM 後會重新提醒。檢查頁列出目前版本與保存結果的版本，按 Check Compatibility 才執行完整的唯讀檢查。檢查失敗不解除既有操作限制，也不會因 Desktop 清理未通過而停用整個瀏覽介面。

完成介面檢查後，可另按 Run Isolated Compatibility Tests…，確認後才執行隔離行為測試。ASM 在新的暫存目錄，用執行檔副本建立測試對話，分別驗證封存／還原與刪除；每步由新程序讀回，刪除另核對測試資料庫與已知對話檔缺席。測試程序不能連網、取得登入憑證或讀寫私人對話，不需要為此關閉正在使用的 Codex。失敗不重送操作，畫面顯示未通過的階段；缺少必要介面則不執行該組測試。

同次檢查會執行 Desktop cleanup SQL self-test：以已識別欄位建立假資料並存入獨立暫存目錄，核對備份內容與重新開啟、指定對話清理、其他對話與自動化設定保留，以及失敗後回復；最後將備份還原成另一份測資比對。僅使用正式清理共用 SQL，不操作真實對話；暫存測資會嘗試移至 macOS 垃圾桶。這不等於完整結構、正式備份管線、新版 Desktop 實機重開或斷電恢復驗收，即使顯示 passed，也不會單憑此結果開放新版 Desktop 清理。

行為結果與同一組環境一起保存；重新檢查相同環境的介面不會抹除仍有效的行為結果。測試用目錄（含執行檔副本）結束後移至 macOS 垃圾桶，可由使用者正常清理；無法移入時會顯示暫存資料夾名稱，不永久刪除。

原始碼已接上逐功能放行：本機隔離測試通過後，畫面顯示 Verified on this device，清單自動更新；封存／還原與官方刪除各自判定，不需要只為新增版本號重建 ASM。預覽綁定當時的環境，確認後若換了執行檔、資料目錄或支援證據，就必須重新檢查及建立預覽；中斷恢復只核對結果，不重送操作。

這不代表 Desktop 私人資料庫清理已通過；它仍有獨立限制，因此「官方刪除可用」不等於「完整 Delete 已驗證」。既有受支援版本也仍須通過每次操作的資料與範圍檢查。新版原始碼尚未打包，舊 DMG 不含這個入口。

## 封存、還原與一般刪除

點選 Archive 後直接進入確認頁，不再先顯示 Archive Readiness 清單。對話標題、完整 ID 和還原說明保留在確認頁；技術檢查說明收在 How this operation is checked。檢查不通過時會阻止操作並說明原因，省略中間頁不會解除保護或自動送出封存。

只選確定要操作的對話，檢查 Preview 的標題、完整 ID、數量及警告。Archive 是保留封存，Move to Trash 是等待刪除，兩者不是同一個使用意圖。依畫面提示關閉 Codex 再繼續，保持 ASM 開啟；完成後依結果提示重開 Codex 查看。

永久刪除只從 Trash Bin 開始：

1. 核對目標，必要時先 Move to Trash。
2. 在 Trash Bin 建立永久刪除預覽，依畫面確認完整範圍；確認後不另從搜尋結果增減對象。
3. 官方 Delete 成功後，App 接續同批已證實不存在項目的 Desktop 殘留清理。不要再次送 Delete。
4. 區分「官方刪除成功」與「Desktop 清理已驗證」；單一 Success／Absent 不代表兩段都完成。
5. 如需清除剩餘 session 設定，從 Review Desktop Cleanup Result 進入獨立的設定 diff 確認。
6. 全部需要的步驟完成後重開 Codex，確認側欄、搜尋及封存清單未再出現這些項目。

若整批部分失敗，保留逐筆結果；未執行、不明與失敗不能當作已刪除。Conflict 的接受原生狀態、重套 Trash 或確認外部刪除各有不同作用，必須依預覽說明，不以清單漏項直接確認刪除。

## 掃描既有 Ghost

Ghost 是官方對話已不存在、Desktop 仍留索引等資料的情況；不是所有未顯示的對話，也不是備份或 ASM log。

1. 開啟 Settings → General → Ghost Delete。
2. 開啟 Enable Bulk Ghost Delete，再按 Open Bulk Ghost Delete…。
3. **實際按一次 Scan for Ghosts**，等到 Scan complete。只開視窗不等於已掃描。
4. 先看分類與保留原因；掃描不代表已備份或已清除。

掃描階段 Codex 可先開著，不需要先刪一般對話、建立 Snapshot 或手動貼 UUID。

| 數字 | 意義 |
| --- | --- |
| Observed | 本次檢查的 Desktop 目錄項目 |
| Confirmed ghosts | 已確認是 Ghost，但不一定可清除 |
| Eligible | 尚未清除、可選入範圍的項目 |
| Kept / unresolved | 保留或尚未釐清的項目，不全是 Ghost |
| Not ghosts | 已分類為不是 Ghost |

Confirmed ghosts 與其他分類重疊，不要把五個數字全部相加。Eligible 為 0 時不能清除；搜尋沒有結果也不等於沒有 Ghost。

Show 分類選單預設顯示 Needs attention，隱藏正常對話。可切換 Eligible ghosts、Blocked ghosts、Local session data — kept、Other unconfirmed、Active、Archive 或 All scanned items；每類顯示剩餘筆數。Active／Archive 依本次官方掃描分類，不依 ASM 舊狀態猜測。篩選只改變顯示，不跳過安全檢查，也不變更選取。

用明顯標示的搜尋欄查 title、完整 ID、blocked 或 unconfirmed：

| 提示 | 意義 |
| --- | --- |
| Local session data exists — kept | 本機仍有對話資料，保留 |
| Exact read skipped because local session data exists | 因資料仍在略過讀取，不是讀取失敗 |
| Codex can read this session — kept | 官方讀得到對話，不允許清除 |
| Exact-read absence could not be verified | 不存在證據不足，不推論為資料損壞 |
| Conversation summaries still exist — kept | 一般模式保留摘要，可另檢視人工確認模式 |
| Automation or catalog state is outside the supported cleanup policy | 不符合既有清理規則，不等於資料庫損壞 |

### 人工確認／強制清除

Manual confirmation / force cleanup of known session residue 預設關閉；切換模式會清空選取，需要重選。

它只放行已知、限定範圍的 session 摘要與受支援的暫停排程案例；列上會顯示待刪摘要數。可讀對話、本機仍有資料、證據不足、置頂、有子對話或其他不支援的關聯仍受保護，並非略過所有檢查。

只清選定 session 的索引與已確認摘要。該次自動化執行紀錄會標為封存；自動化設定、未來排程、啟用／暫停狀態及其他 session 摘要不變。確認視窗的 MANUAL REVIEW 必須說明這個範圍。

## 清除既有 Ghost

先保存其他工作的進度。這會修改真實 Desktop 殘留，不是移到一般垃圾桶；備份由 App 檢查。

1. 選取已核對項目；若要處理全部符合資格者，用 Select All Eligible。
2. 切到 All scanned items、清空搜尋，再用 Selected only 核對完整清單與 eligible selected 數量。Select All Eligible 會選取本次掃描所有符合資格者，不限目前分類。
3. 按 Clear Selected Ghosts…，核對數量與人工模式的摘要範圍，再按一次 Confirm Cleanup；不符就 Cancel。
4. 出現 Close Codex to continue 後，正常退出 Codex Desktop、CLI、編輯器整合及會開啟 Codex 連線的工具。不要強制終止不明程序。保持 ASM 與 DMG 開啟。
5. 按 Codex Is Closed — Start Cleanup。App 自動檢查、驗證備份、執行並逐筆回讀。
6. 處理中不重按、不重開 Codex、不關閉 ASM 或推出 DMG；若出現版本更新或未知提示，停止並回報。

Terminal outcome: success 必須涵蓋完整確認範圍。成功項目只留在結果區，不再列為待清除；這是依本次結果更新畫面，不是重新掃描整個資料庫。

需要時先做下節的設定清理，再重開 Codex，檢查側欄、搜尋及封存清單；人工模式另確認自動化排程及啟用／暫停狀態未變。畫面不存在只是 UI 證據，完整驗收還要核對逐筆結果及唯讀資料。

### 因資料庫占用停止

**只有計畫準備前**被占用檢查擋下，才可保留原範圍繼續：

1. 保持 ASM 開啟，完全退出仍連線的 Codex 工具。
2. 按 Codex Is Closed — Recheck and Continue。這只重新驗證原批次，不重送官方 Delete、不重新選取。
3. 若仍占用，清理尚未執行；排除後再按。完成後不能重複執行。

資料漂移、預覽逾期、unknown、可能已執行或需要恢復，不適用這個入口。保留原結果，不重新 Delete、縮小批次、換舊 App 或手動改資料庫。

## 全域設定差異預覽

對話／Desktop 清理完成後，Review Global-State Diff… 是**獨立確認**，不會自動套用。

- 保持 Codex 與相關 CLI／編輯器停止。檢查完整 ID、標題與主檔、.bak 各欄位的待移除內容。
- 紅色 − 是要移除的資料；---／+++ 是清理前／後的檔案標籤，不是刪掉再建立整份檔案。未變內容省略，避免 JSON 排版雜訊。
- Cancel 不改來源、不產生操作備份，也不恢復已刪對話。確認後才按 Apply This Diff。
- 超過 5 分鐘或來源內容改變，舊預覽作廢，需重新檢視。沒有符合資料時不改檔、不建立備份。
- 只移除已知、精確歸屬該 ID 的設定。未知欄位、其他對話提及 ID 的文字、自動化定義／排程及實際工作資料夾不動。
- 兩份 JSON 各自原子更新，不是跨檔交易；中斷可能部分完成，保留備份，不自動重試或還原。

備份位於 ASM Application Support 的 GlobalStateCleanup/<preview ID>/，含舊私人資料，目前不自動清除。這不是安全抹除；不要把私人 diff 或備份提交到公開 repo。

## Deleted 與操作紀錄

Deleted 是 ASM 的刪除歷史清單，不可再 Archive、Restore 或 Delete。移除清單項目不會操作 Codex，也不會刪除備份；內部報告與復原證據另行保留，不等於抹除所有 ASM 資料。

手動清除：

1. 在 Deleted 勾選紀錄，按 Clear Selected Records…；或用 Clear All List Records 移除所有清單紀錄，不限搜尋結果。
2. 檢查筆數。舊紀錄缺少成功報告也可移除，只選部分批次不會擴大選取或影響內部整批復原。
3. Cancel 不變更。確認後清單與數量更新，重開 ASM 後仍應保持結果。
4. Clear Completed Operation History… 是另外的實體資料清理入口，只處理完整成功群組；未完成、不明、失敗與缺乏證據者仍保留。Report History 的 Clear Completed Reports… 只處理無受保護關聯的成功報告。

超過 30 天且完整成功的操作歷史可自動清理；操作中或需要恢復時延後。清空 Deleted 清單不會把未完成操作改成成功，也不會使其報告變得可清除。

一般報告的 500 份上限只限制可安全移除者；受保護紀錄可超過上限。最小防重複執行標記仍保留，備份不在此清理範圍，也不保證立即釋放磁碟空間。儲存細節見[資料庫](SQLITE_SCHEMA.md)。

## 畫面檢查與回報

需要驗證 UI 時，優先使用既有報告，不為畫面測試刪除對話：

- 主視窗可縮至 860 × 560，放大時內容跟隨；重開預設 Active，欄寬與分隔位置仍保留。
- 結果標題、底部 Done 與清理按鈕完整可見；中間長文字可捲動，不把按鈕推出螢幕。
- 搜尋欄明顯；每列同時顯示標題與完整 ID，未知標題標示 Title unavailable，不猜測。
- 清除後待處理清單與數量同步更新，歷史結果仍可查看。

回報使用版本、實際按過的按鈕、停在哪一階段、完整提示與分類數量。執行過才回報逐筆結果、是否重開及是否重現；未執行不要推測。私人 ID 與截圖私下保存。

失敗、unknown、不完整、持續處理中或刪後重現時，保留畫面與原紀錄，先診斷，不重按或強制退出。沒有待驗證問題時，不必重跑本手冊。
