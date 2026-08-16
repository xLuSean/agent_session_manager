# Agent instructions

本專案管理可能被永久刪除的 agent sessions。所有實作都必須遵守下列規則。

## Non-negotiable safety rules

- 預設只使用 fixture provider；不得悄悄切換為 live data。
- 不得直接修改或刪除 agent system 的 JSONL、SQLite、cache 或內部 session 檔案。
- Live adapter 必須使用該 agent system 支援的正式 lifecycle interface，並進行 readback。
- 永久刪除只接受目前屬於 manager Trash Bin 的 session。
- pinned、running、current 或具有 pinned descendant 的 session 不得 archive、trash 或永久刪除。
- 所有 mutation 必須經過 frozen Preview、精確 selection、明確 Confirm、執行與逐筆 readback report。只有不可逆的永久刪除、清除稽核歷史或同等 destructive action 要求使用者輸入 exact confirmation token；Archive、Restore 與 Archive ↔ Trash 等可逆 lifecycle 操作不要求 typed token。
- Preview 後狀態若漂移，整個 batch fail closed；不得偷偷縮小 batch 後繼續。
- Archive 與 Trash Bin 是不同的使用者意圖，即使 provider 的 native state 相同也不得合併。
- UI 與 report 永遠顯示完整 native session ID。
- Provider 不支援或無法確認某項 capability 時，UI 必須顯示 unavailable 並禁止相關 mutation。

## Development workflow

- 先修改並測試 `AgentSessionManagerCore`，再接 SwiftUI。
- 新增 live adapter 時先交付 read-only inventory、fixture tests 與 reconciliation tests；mutation 是另一個明確 phase。
- 新增 provider 時不得假設 Codex 的 archive / delete semantics 適用於其他 agent system。
- 任何 storage schema 變更都需要 migration、backup 與 rollback 測試。
- README、Architecture、Roadmap、TODO 與 Handoff 必須跟著重大設計變更更新。
