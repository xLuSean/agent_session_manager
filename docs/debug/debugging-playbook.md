# Debugging Playbook

## Triage sequence

1. 保存完整 UI message、所選 full native session ID 與當下時間。
2. 判斷錯誤發生階段：inventory、Preview prepare、persistence、confirmation／claim、provider
   request、readback、Report persistence、UI presentation。
3. 唯讀查 manager SQLite：checkpoint、Preview status、Report outcome、item readback。
4. 若 lifecycle 可能已呼叫，不從 alert 或 list count 猜結果；以 durable Report 加 fresh official
   native readback為準。
5. 檢查 GUI 實際 executable／environment，不從 shell `which` 推論。
6. 用 focused regression test 重現 production-like timestamp、version drift、actor reentrancy、
   incomplete evidence 與 error injection。
7. 跑 focused tests、完整 Swift tests、`git diff --check`、Xcode Debug build。
8. 若結論改變，更新正式 docs；此目錄只保留可搜尋的踩雷細節。

## Useful read-only SQL

```sql
SELECT provider, runtime_version, inventory_complete, protection_complete,
       refreshed_at, last_error_code
FROM provider_checkpoints;
```

```sql
SELECT id, operation, manager_intent, status, created_at, expires_at
FROM operation_previews
WHERE provider = 'codex'
ORDER BY created_at DESC;
```

```sql
SELECT id, preview_id, operation, outcome, started_at, completed_at, error_code
FROM operation_reports
WHERE provider = 'codex'
ORDER BY completed_at DESC;
```

```sql
SELECT r.id AS report_id, r.outcome, i.native_session_id,
       i.observed_native_state, i.evidence_at, i.error_code
FROM operation_reports r
JOIN operation_items i ON i.report_id = r.id
WHERE r.preview_id = '<exact-preview-id>';
```

以上只能唯讀使用。不要用 ad-hoc `UPDATE`／`DELETE` 修 manager state，也不要直接查改 Codex
內部 storage 來繞過 lifecycle interface。

## Useful repository searches

搜尋 pattern 若含 Markdown backticks，必須把整個 pattern 放在 single quotes；double quotes 或未引用的
backticks 會被 zsh 當成 command substitution 執行。這次搜尋 stale `NavigationSplitView` 文件時曾因此
誤執行一個不存在的 `NavigationSplitView` command；沒有造成檔案或 App state 變更，但屬於可避免的
shell quoting 錯誤。

```bash
rg -n "<exact error text>" macos/AgentSessionManager/Sources \
  macos/AgentSessionManager/Tests
```

```bash
rg -n "runtimeVersion|checkpoint|operationPreview|operationReport" \
  macos/AgentSessionManager/Sources/AgentSessionManagerCore
```

```bash
rg -n "Task \{|keyboardShortcut\(.defaultAction\)|isSubmitting" \
  macos/AgentSessionManager/Sources/AgentSessionManager
```

## Verification commands

```bash
cd macos/AgentSessionManager
swift test
```

```bash
cd macos/AgentSessionManager/App/AgentSessionManager
xcodebuild -quiet -project AgentSessionManager.xcodeproj \
  -scheme AgentSessionManager -configuration Debug build
```

```bash
git diff --check
git status --short
```

## Reporting template

- Observed UI symptom:
- Exact stage where it failed:
- Provider request sent: yes / no / unknown
- Preview ID and durable status:
- Report ID and outcome:
- Exact native ID and readback state:
- Root cause:
- Fix:
- Regression test:
- Full test/build result:
- Remaining unknowns:
