# Xcode Target and App Bundle Pitfalls

## 症狀

- Xcode 顯示 `Cannot index window tabs due to missing main bundle identifier`。
- Console 同時可能出現 `com.apple.linkd.autoShortcut` Code 4097 與
  `layoutSubtreeIfNeeded` recursion 警告。
- Build 成功，但 Run 後沒有正常 App 視窗，或看起來像 App 立即退出。

## 這次的原因

專案同時有兩個同名 runnable：

1. Xcode project 的正式 `AgentSessionManager.app` target。
2. Swift Package 的 `AgentSessionManager` command-line executable product。

第二個 target 雖然編譯相同 SwiftUI source，卻不是 macOS `.app` bundle；Xcode 若誤選它，
`Bundle.main.bundleIdentifier` 會缺失，AppKit 的 window/tab 行為也不是正式 App lifecycle。
`com.apple.linkd.autoShortcut` 訊息是伴隨的系統服務警告，不是這次無法開啟視窗的主要原因。

## 如何確認

- 檢查正式 build product：
  `AgentSessionManager.app/Contents/Info.plist` 必須有
  `CFBundleIdentifier = com.sean.AgentSessionManager` 與 `CFBundlePackageType = APPL`。
- 直接執行正式 bundle 內的 binary；若能持續執行並顯示視窗，App 本身沒有立即 crash。
- Xcode console 出現 `missing main bundle identifier` 時，優先查 scheme/product，而不是先追
  `linkd.autoShortcut`。

## 修復

- 從 `Package.swift` 移除同名 executable product/target。
- Swift Package保留`AgentSessionManagerCore`、獨立test-support `AgentSessionManagerFixtures`與tests。
- SwiftUI App 只由正式 `.xcodeproj` target 建立與執行。
- Shipping App固定建構Codex Live model；不再依賴`ASM_XCODE_DEBUG`或launch environment切換資料來源，Debug／Release行為一致。

## 驗證

- `swift test` 仍能完整編譯並執行 Core tests。
- `xcodebuild ... -scheme AgentSessionManager -configuration Debug ... test` 同時成功build正式App並執行standalone App tests。
- Xcode scheme 不再有同名 SwiftPM executable 可誤選。

## App state tests不得以shipping App為test host

`SessionManagerModel`測試若使用正式App作`TEST_HOST`，XCTest可能啟動SwiftUI App、建立視窗並觸發
`ContentView.task { reload() }`，使一般驗證碰到live Codex inventory。正確做法是standalone
`AgentSessionManagerAppTests.xctest`：把同一份production `SessionManagerModel.swift`加入test target，
注入in-memory DiagnosticLogStore，不包含`AgentSessionManagerApp.swift`、`ContentView.swift`或App host。
shared scheme仍build正式App，因此App source編譯與model狀態測試兩層都會執行。

### Xcode UI acceptance（2026-08-15）

重新開啟正式`.xcodeproj`後由使用者在Xcode執行`Product > Test`／`⌘U`。最新
`Test-AgentSessionManager-2026.08.15_15-38-17-+0800.xcresult` readback為My Mac arm64、
4 passed、0 failed、0 skipped；四個`SessionManagerModelTests`逐項皆為Passed。這證明shared
scheme的Test action不只在CLI可用，Xcode UI也能正確發現並執行standalone test bundle。
