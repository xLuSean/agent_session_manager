# SwiftUI Layout and Persistence Pitfalls

## Table row focus不能共用checkbox batch selection

SwiftUI `Table(_:selection:)`若直接綁到batch `Set<String>`，點任一非checkbox cell也會由Table改寫整份
selection；使用者先勾多筆後只是點標題查看Inspector，就會看似無故取消其他checkbox。

修復：Table改綁獨立的single `focusedSessionID`，只控制藍色row focus與Inspector；batch
`selection`只由row checkbox、Trash Select All、Clear Selection或明確context-menu action改動。
Checkbox欄不能只用`TableColumn.width(_:)`或相同min／ideal／max限制；macOS SwiftUI Table仍可能
保留約100 pt的平台minimum，造成控制項左右大片空白。可靠修復是移除獨立checkbox欄，把24 pt
checkbox symbol與28×28 hit target併入Session cell最左側。欄寬持久化從六欄遷移成五欄時只丟棄
舊checkbox寬度，保留Session、Project、Working Folder、State與Updated原有的使用者拖曳值。

## NSViewRepresentable 沒有限高會撐開 VStack

### 症狀

Trash Bin 的 `Select all filtered` 出現在一大片空白中央，真正的 session table 被推到視窗下半部。

### 成因

三態 checkbox 使用 `NSViewRepresentable` 包裝 `NSButton`。若沒有固定 intrinsic proposal，SwiftUI
在 `VStack` 中可能把 hosting row 當成可垂直擴張，接收剩餘高度後再把 checkbox 置中。

### 修正

- checkbox 使用 vertical `fixedSize`。
- selection bar 明確限制 content height，再加固定 padding。
- 不用 `Spacer()` 或整體 `maxHeight: .infinity` 製造 table 上方空間。

## SwiftUI TableColumn 沒有 resize binding

### 限制

`TableColumn.width` 只能提供初始/min/ideal/max width；沒有 binding 可取得使用者拖曳後的欄寬。

### 修正

- 在 Table background 放置不攔截事件的 AppKit probe。
- 只配對 probe frame 中且 column count 完全一致的 `NSTableView`，避免抓到 sheet 裡的 table。
- 不再同時啟用 `NSTableView` native autosave；SwiftUI 的 `TableColumn.width` 啟動 layout 會和 native
  restore 競爭，造成已恢復的值又被初始 ideal widths 覆寫。
- `UserDefaults.array` 逐項解析數值，不把整個陣列強制 cast 成 `[NSNumber]`；型別不符時不得誤判成
  「首次啟動」並覆寫現有 key。
- 監聽 `NSTableView.columnDidResizeNotification`；非使用者 resize 重新套回 frozen widths，不保存
  SwiftUI 啟動暫態尺寸。
- 以 local mouse monitor 精確辨識 Table header 的 mouse-down；`NSTableHeaderView` 會在自己的 nested
  event-tracking loop 直接消耗 drag／mouse-up，所以 local monitor 不保證收到 mouse-up，實測
  `columnDidResizeNotification` 也沒有送達 probe。
- header mouse-down 後以加入 `.common` run-loop mode 的短週期 timer，在 AppKit tracking loop 期間
  取樣實際欄寬；只有欄寬真的改變才保存，並以 global left-button state 結束追蹤。這避免把 window
  layout 或啟動暫態尺寸誤存成使用者偏好。
- 恢復值仍 clamp 到每個 `NSTableColumn` 的 min/max。

2026-08-14 的實際症狀是左右 pane 已能保存，但 table key 每次仍回到
`34／340／150／160／110／110`。隔離 bundle
`com.sean.AgentSessionManager.TableWidthTest` 以真正 plist real 寫入
`34／420／180／210／130／120` 後，修正版啟動沒有覆寫，畫面 header 採用新欄寬；完整關閉再啟動
readback 仍是相同六個值。第一次用 `defaults write -array` 注入時，CLI 把數字寫成 string，不能拿來
判定 production numeric decoding；改用 plist `<real>` 後才是有效驗證。

後續真實拖曳驗證推翻了「restore 通過就代表完成」：畫面中的 Session 欄可以從 340 拖到 420，
但舊實作的正式 key 仍停在 340。加入 tracking-loop 取樣後，同一隔離 bundle 的真實 header drag
會依序捕捉 350…420，最終 key 為 `34／420／150／160／110／110`；完全關閉 process 再啟動後，
readback 仍為相同值，畫面也採用 420。這才同時證明 capture、persistence 與 restore 三段成立。

最終亦由使用者在正式 Xcode Run 流程確認：重新編譯啟動後手動拖曳欄位，使用 `⌘Q` 完整離開，
再次 Run 時欄寬維持上一次的位置。這排除了隔離 bundle、自動化 CGEvent 或預寫 plist 才能成功的
可能，正式開發流程的 end-to-end 驗證通過。

## NavigationSplitView pane width

不要用 `GeometryReader` 在 layout pass 中把 pane 寬度持續寫回 `@AppStorage`。App 啟動時，
`NavigationSplitView` 會先產生 minimum／ideal 暫態尺寸；這個值若被當成使用者設定保存，就會把
上一次拖曳的寬度覆蓋掉，看起來像「重新編譯後回到預設」。

SwiftUI 會替 `NavigationSplitView` 產生包含泛型 view type 的動態 autosave key；Xcode 重新編譯後
不一定消失，但該 key 可能保存和目前 window 不一致的舊 frame，不能當成穩定 product contract。

AppKit background probe 不一定會連到 SwiftUI 私下建立的 split view；連 probe 自己的固定 key 都沒有
出現時，繼續調整 mouse event／resize notification 條件沒有意義。實際證據顯示 SwiftUI 的動態
`NSSplitView Subview Frames …, SidebarNavigationSplitView` key 會在 drag 後正確更新 frame widths，
但下一次 Xcode Run 不一定正確 restore。

另一個陷阱是把保存值傳給 `navigationSplitViewColumnWidth(ideal:)`：`ideal` 只是 layout hint，寬視窗
下 SwiftUI 仍可能把 Inspector 撐到 `max`，接著又把這個結果覆寫回保存值。因此保存成功不代表恢復
成功。

從 AppDelegate 遞迴尋找 SwiftUI private split仍可能完全找不到；固定 key停在舊值就是直接證據。
曾嘗試以 App-owned `NSSplitViewController` + 三個 `NSHostingController` 取代主容器，雖然能持有公開
AppKit split，但 hosting views 採用 intrinsic height，三欄縮成視窗中央的一條，toolbar／全高layout
也被破壞，因此立即撤回。

第一次 App-owned split 失敗不是 `NSSplitViewController` 本身無法使用，而是三個
`NSHostingController` 保留預設 sizing options。SwiftUI 因而把 intrinsic/min/max content size 轉成
Auto Layout constraints，hosted content 在 split pane 裡只以自身尺寸置中，造成三欄縮成視窗中央一條。

修正版先以啟動參數隔離成 prototype，並同時做到：

- 每個 `NSHostingController.sizingOptions = []`，pane 尺寸完全由 AppKit split 管理。
- 每個 SwiftUI root 使用 `frame(maxWidth: .infinity, maxHeight: .infinity)` 填滿 pane。
- Sidebar／content／Inspector 的 minimum、maximum 與 holding priority 分開設定。
- `NSSplitView.autosaveName` 固定為 `AgentSessionManager.MainSplit.v1`，不含 SwiftUI 泛型 type 名稱。
- Sidebar toolbar button 透過 responder chain 呼叫目前視窗的 `toggleSidebar(_:)`，避免多視窗一起切換。
- 保留 `--legacy-navigation-split`，需要時可回到舊容器診斷。

驗證證據：初次完整 layout 產生 218／909／280 frame；把 prototype key 模擬為
300／807／300 後，完整關閉再啟動仍 read back 相同三組 frame，畫面也確實採用該寬度。精確以
Accessibility ID `mainSidebarToggle` 操作後，autosave 先記錄 Sidebar `YES` collapsed，再展開回
300／807／300。Toolbar、search、Session table、Sidebar footer 與 Inspector 都維持全高正常。

完成驗證後已升為預設容器，並刪除手動寫入的測試 autosave key，避免把測試用 300／807／300
冒充使用者偏好。使用者第一次自行拖曳後，AppKit 會把實際 divider frames 保存到相同固定 key；
Xcode rebuild 不會改變 bundle ID 或這個 key。

`NSTableView` 欄寬只使用 `layout.sessionTable.columnWidths.v1` 自訂 numeric array；舊版
`layout.sessionTable.columnWidths.v1.native` AppKit autosave 資料不再讀寫，避免 native restore 與
SwiftUI initial width 互相覆蓋。

## Window resize 被 content intrinsic size 反向限制

### 表面現象

正式DMG啟動後拖曳主視窗邊界，視窗看起來無法正常縮放，反而像是內部三欄內容在被壓縮。Pane divider
本身仍可拖曳，因此容易誤判成split autosave問題。

### 根因

主Scene只設定SwiftUI root的`minWidth`／`minHeight`，沒有明確宣告window resizability與root的無限
maximum；`NSViewControllerRepresentable`也沿用預設size proposal。另一方面，三個AppKit split item的
minimum thickness合計接近原本1080 pt的window minimum。結果是content sizing與window sizing互相
反饋，而不是單純讓root採用外部window的新尺寸。

### 修復

- Scene明確使用`.windowResizability(.contentMinSize)`。
- Root frame同時設定minimum與`maxWidth/maxHeight = .infinity`，由window主導實際大小。
- `PersistentMainSplitView.sizeThatFits`直接採用外部proposal，只在低於860 × 560時套用合理minimum。
- Sidebar／content／Inspector最小寬度分別調整為190／400／240，legacy `NavigationSplitView`使用同一組
  pane下限。
- 固定`NSSplitView.autosaveName`與使用者已保存的divider比例不變；這次修正不清空layout偏好。

App-layer修改仍必須以正式`.xcodeproj` build驗證，不能只看Core `swift test`。
