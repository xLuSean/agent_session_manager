# Codex Runtime and Transport Pitfalls

## `userAgent` 被誤認為 runtime version

### 症狀

Inventory complete，但 authoritative checkpoint 的 `runtime_version` 是 `NULL`，Restore
因此停用。

### 錯誤假設

曾把 `initialize.result.userAgent` 中看似 `Codex Desktop/0.147.0` 的內容當成 App Server
runtime authority。

### 真正語意

`userAgent` 會依 initialize 的 client identity 形成。Agent Session Manager 實際觀察到的是
`agent_session_manager/...`。它是 client diagnostics，不是 Codex executable 版本。

### 正確修復

1. Resolve exact Codex executable。
2. 對同一 executable 執行 `--version`。
3. 只接受嚴格格式 `codex-cli <version>`。
4. 把版本綁入 diagnostics、inventory snapshot 與 authoritative checkpoint。
5. Lifecycle execution 前再次 probe 同一 executable。
6. Unknown／未 audit version 一律 unavailable。

## GUI `PATH` 與 shell `PATH` 不相同

同一台機器觀察到：

- Homebrew standalone：`codex-cli 0.147.0`
- ChatGPT bundled：`codex-cli 0.147.0-alpha.6.5`

GUI app 的 `PATH` 取決於 launcher，可能讓 bundled alpha runtime 排在使用者 standalone
install 前面。Shell 的 `which codex` 不能證明 GUI 實際使用哪個 executable。

目前 resolver：

- 明確 configuration 優先。
- Conventional standalone paths 優先於 launcher-inherited `PATH`。
- Inspector 分開顯示 Runtime 與 Client user agent。

## App Server transport 的已知界線

- Inventory client 啟動 app-owned `codex app-server --listen stdio://`。
- Desktop 自己的 App Server 是另一個 parent-owned process。
- Process-local idle／not-loaded 不能證明 Desktop 沒有 writer ownership。
- `thread/unsubscribe` 只影響當前 connection，不等同跨 host release。
- Control socket／shared daemon 可改善 ownership visibility，但目前不是安全 one-shot Archive
  request 的 prerequisite。

## Debug rule

版本、schema、method 與 error semantics 都是 drift-prone。每個 allow-list version 必須重新
audit；不能因為字串看起來像版本就把 capability 打開。
