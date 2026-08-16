# Isolated Archive acceptance

## Status

這是 Phase 3 的 test-only、人工、一次一筆驗收流程。2026-08-13 曾對一個明確可犧牲 session 送出一次真實 Archive；App Server 以 `-32600` 拒絕，fresh readback 證明 session 仍為 Active。這不是 Archive success，但已驗證一個正式且允許的 terminal result：Busy/rejection 會保存為 failure、session 維持原狀，而且不會 retry。Readiness、Preview factory、SQLite claim、executor、production facade、SwiftUI confirmation/report 與 recovery 已使用同一 operation-specific attempt contract。2026-08-14 的 Desktop `pinned-thread-ids` 雙讀一致性 adapter 已補足 pin 與 pinned-descendant evidence；eligible non-pinned single root 現可由 App 建立 Preview。Shared writer host 仍不是必要條件。

最強診斷是 target 雖顯示 `idle`，Codex Desktop 仍持有該 session 的 writer，而獨立 manager App Server 因 writer ownership 拒絕 Archive。OpenAI upstream 的同型 archive test 對這個情況回覆 `-32600: thread <full-id> already has an active writer`，與本次 code 相符；但本次舊 Report 只保存 `-32600` 而沒有保存原始 RPC message，因此不能把該字串當成本次逐字 readback。`idle` 只表示沒有執行中的 turn，不代表跨 host writer 已釋放。Busy 是安全的 execution failure，不得以 `thread/read`、等待或自動 retry 繞過；若使用者稍後再試，必須建立全新 Preview 並重新確認。

## Hard boundary

- Harness 只存在於 Swift test target，不編入 production App 或 Core public API。
- 一般 `swift test` 與 `AGENT_SESSION_MANAGER_LIVE_TEST=1 swift test` 都不會送出 Archive。
- 只接受一個完整 native UUID；不接受 project、日期、title query 或模糊 selection。
- Session title 必須以 `[ASM-ISOLATED-ARCHIVE]` 開頭，而且逐字等於 frozen expected title。
- Working directory 必須是 absolute path，basename 必須以 `asm-isolated-archive-` 開頭，而且逐字等於 session cwd。
- 要求 complete official inventory、allow-listed runtime、完整 protection evidence、Active、非 protected、descendant count verified 且為 0。
- 確認字串包含完整 native ID：`ARCHIVE-ISOLATED-<UPPERCASE-UUID>`。
- Authority expiry 必須是未來最多 5 分鐘內的 ISO-8601 instant；每次 preflight/readback 都重驗，過期即停止。
- Operator 必須逐字聲明其他 Codex hosts 已停止、target 不是 current，並提供完整 pinned UUID 清單（空清單使用 `NONE`）。若環境 `CODEX_THREAD_ID` 等於 target、provider 回報 pinned/running/current/pinned-descendant true，或 pinned 清單含 target，一律硬擋，attestation 不能覆蓋。
- Harness 走正式 Preview-first SQLite claim、一次 Archive、fresh official inventory readback、Report-after consume 流程；未知 outcome 不會 retry。
- Harness 只驗證 Archive retention，不執行 delete、Trash、restore 或 unarchive。

## Preconditions

人工執行前必須先在隔離的 working directory 建立一個可犧牲 Codex session，並確認它不是目前 task、沒有 sub-agent/descendant、不 pinned、不在其他 Codex process 執行。建立 session 不屬於 harness 的權限；harness 不會自動挑選或建立測試品。

先以正常 Live read-only inventory 確認以下精確值：

- 完整 native session ID
- 完整 title
- 完整 working directory
- runtime version
- inventory/protection completeness
- pinned、running、current、pinned-descendant 與 descendant count evidence

任何 evidence unavailable 都應停止，不要設定 mutation opt-in。

## Exact invocation

以下是格式範本，不是可直接執行的實際授權。必須把三個 placeholder 換成剛建立、可犧牲 session 的精確值：

```bash
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE='I_UNDERSTAND_THIS_ARCHIVES_ONE_REAL_DISPOSABLE_SESSION' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_SESSION_ID='<FULL-UUID>' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_EXPECTED_TITLE='[ASM-ISOLATED-ARCHIVE] <EXACT-TITLE>' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_WORKING_DIRECTORY='/absolute/path/asm-isolated-archive-<fixture>' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_CONFIRMATION='ARCHIVE-ISOLATED-<UPPERCASE-FULL-UUID>' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_AUTHORITY_EXPIRES_AT='<ISO-8601-WITHIN-5-MINUTES>' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_OTHER_HOSTS_STOPPED='I_ATTEST_ALL_OTHER_CODEX_HOSTS_ARE_STOPPED_FOR_<UPPERCASE-FULL-UUID>' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_TARGET_NOT_CURRENT='I_ATTEST_TARGET_IS_NOT_CURRENT_<UPPERCASE-FULL-UUID>' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_COMPLETE_PINNED_IDS='NONE' \
AGENT_SESSION_MANAGER_ARCHIVE_ACCEPTANCE_PIN_CHECK_COMPLETE='I_ATTEST_PINNED_LIST_IS_COMPLETE_FOR_<UPPERCASE-FULL-UUID>' \
swift test --disable-sandbox \
  --filter ArchiveIsolatedSessionAcceptanceTests/testLiveArchiveOfExplicitIsolatedSessionWhenSeparatelyAuthorized
```

執行前必須再次逐字檢查 shell history 中的 payload。`COMPLETE_PINNED_IDS` 若非空，使用 comma-separated full UUIDs，不得省略其他 pinned tasks。不要使用 shell command substitution、glob、lookup script 或「第一筆符合」來填入 ID／expiry／pinned list。

## Success criteria

只有以下全部成立才算 acceptance success：

1. Gate 接受精確 isolated identity 與完整 safety evidence。
2. SQLite prepared Preview 先落盤並 claim 為 `executing`。
3. Official Archive request 最多送一次。
4. Fresh complete official inventory 以完整 ID 讀回 Archived。
5. Itemized Report outcome 為 success、observed state 為 Archived、released bytes 為 0。
6. Report 與 item results 原子落盤，Preview 為 consumed。
7. Test output 保存完整 Report ID、Preview ID 與 native ID，供人工簽核。

任何 throw、unknown、failure 或 evidence unavailable 都不是 acceptance success，也不得直接重跑 mutation。RPC rejection 的完整 server message 必須寫入 itemized Report；`already has an active writer` 應分類為 `archive_request_busy_active_writer`。若 SQLite 保留 `executing`，只允許使用 readback-only recovery；若 Report outcome unknown，應保存結果並先調查。

## After acceptance

一次成功只證明單一 runtime 與單一 isolated session 的 Archive success path；一次 verified Busy 只證明 failure path。兩者都不會單獨開啟 production capability。仍需 review：

- pinned 與 pinned-descendant evidence 是否已具有 production-grade authority
- running/current/writer unknown 是否只被呈現為 may-return-Busy，且 positive evidence 仍會在 request 前阻擋
- App construction path 是否保持 exact Preview/confirmation/readback UX
- crash/relaunch recovery 是否在 production bootstrap 前執行
- operation history 與使用者可見 report 是否完整
- 與既有 `codex-retire-sessions` skill 的安全 parity
