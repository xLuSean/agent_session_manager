# Diagnostic Logging

## Report History 與 Logs 不可合併

Report History 是 lifecycle outcome authority，必須綁定 frozen Preview、逐筆 readback 與完整bundle retention。
Diagnostic Logs只是App timeline，能說明Refresh、Preview、execution、recovery或storage發生過什麼，但不能用來證明
Archive／Restore／Delete成功。兩者放在同一table或共用clear/prune contract，會讓diagnostics故障影響安全狀態。

## 獨立bounded JSONL

Diagnostic Logs放在bundle-ID Application Support目錄的`diagnostic-events.jsonl`，不修改`state.sqlite` schema。
平時append；count、age、size任一上限觸發時，只保留最新events並原子重寫。檔案固定0600；corrupt JSONL line
在load時丟棄並重寫clean retained set。App不能因log初始化或寫入失敗而無法啟動，必須退回bounded memory並在
Settings揭露錯誤。

## Privacy boundary

不要記錄conversation text、confirmation token、prompt、request payload或message body。Metadata限制key/value數量
與長度，且含token/payload/conversation/prompt/body/content的key直接排除。這個denylist只是第二層防線；caller
仍不可把敏感值塞進自由文字message。

## Xcode target 陷阱

Swift Package只包含Core與tests；macOS App由`App/AgentSessionManager/AgentSessionManager.xcodeproj`明確列出
SwiftUI source files。新增App-layer Swift檔時，只有`swift test`或package scheme build成功不代表App有編譯該檔；
必須同步加入PBXFileReference、PBXBuildFile與Sources phase，並用正式`.xcodeproj` scheme驗證。

## 必要驗證層次

- Core tests要覆蓋count／age／byte retention、corrupt-line recovery、0600權限與sensitive metadata denylist。
- `git diff --check`只能驗證文字格式，不能證明SwiftUI source已被App target編譯。
- 最後必須用`AgentSessionManager.xcodeproj`的正式App scheme build；只跑`swift test`或Swift Package scheme不夠。
- Settings顯示的Diagnostic Logs不能取代Report History。即使JSONL無法初始化而退回bounded memory，App仍須可啟動，且lifecycle authority不得改變。

## 磁碟初始化失敗不是一般 refresh error

- 磁碟JSONL無法開啟時，舊檔保持不動；本次啟動只使用bounded in-memory emergency buffer，兩者不宣稱同步，也不自動合併。
- Persistence degradation必須與一般snapshot／append error分開保存。成功refresh記憶體snapshot不得清除「本次Log未落盤」狀態。
- App啟動時警告一次；Settings General與Logs持續顯示警告，明說記憶體Log會在App離開後消失。
- `DiagnosticLogBootstrap`回傳store與typed persistence status，使磁碟成功／失敗路徑都能用Core tests驗證；fallback store由non-throwing `productionInMemory()`建立，不再使用`try!`。
