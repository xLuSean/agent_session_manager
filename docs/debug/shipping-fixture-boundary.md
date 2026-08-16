# Shipping Fixture Boundary

Last updated: 2026-08-15 (Asia/Taipei)

## 問題

只把 Fixture／Live 切換按鈕藏起來，仍可能讓 `FixtureSessionProvider` 隨 Core module 一起編入
正式 App。這會造成兩個風險：shipping binary 仍帶著測試資料與 mutation 行為，以及未來程式碼
可意外重新接回 Fixture product mode。

## 修正

- 正式 SwiftUI App 固定建構 Codex Live model，不讀 launch environment 來切換資料來源。
- `FixtureSessionProvider` 與 `FixtureOperationHistoryLedger` 從 Core 移到獨立
  `AgentSessionManagerFixtures` Swift target。
- Core tests 明確依賴 Fixtures target；Xcode App target只依賴 `AgentSessionManagerCore`。
- Sidebar、banner、Report History、Maintenance 與 conflict flow 移除所有 Fixture product branch。
- Xcode scheme 不再注入 data-source environment variable，Debug／Release 行為一致。

## 驗證方式

`scripts/verify_shipping_boundary.sh` 同時檢查三層邊界：

1. App Swift sources 不得引用 Fixture module、provider、ledger或舊資料來源切換符號。
2. `.xcodeproj` shipping target 不得連結 `AgentSessionManagerFixtures`。
3. 傳入 Release `.app` 時，掃描 executable strings，不得包含 Fixture implementation symbols。

`scripts/package_dmg.sh` 在 Release build 前與取得 `.app` 後都執行這項驗證。若任何一層失敗，
DMG packaging 立即停止。

## 踩雷結論

- 「預設 Live」與「沒有 Fixture」是不同保證；前者只是 runtime choice，後者是 build boundary。
- SwiftPM target分離後，跨module使用的 Core models需要明確 `public init`，否則test-support target無法建構fixture資料。
- `swift test` 只證明 package graph；App-layer改動仍必須跑正式 `.xcodeproj` Debug/Release build。
- Release binary檢查是最後一道防線，但不能取代source與target linkage檢查；三者都需要。
