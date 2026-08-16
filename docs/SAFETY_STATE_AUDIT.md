# Codex Safety-State Audit

## Scope and evidence

- Audit date: 2026-08-14
- Official OpenAI Docs: <https://developers.openai.com/codex/app-server/>
- Local runtime: `codex-cli 0.147.0`
- Local schema commands:

  ```bash
  codex app-server generate-json-schema --out <temporary-stable-directory>
  codex app-server generate-json-schema --experimental --out <temporary-experimental-directory>
  ```

Generated schemas are temporary verification evidence, not checked-in dependencies. The app does not inspect session JSONL, SQLite, cache, rollout contents, or conversation bodies.

The repeatable stable-schema audit is:

```bash
scripts/audit_app_server_contract.sh
```

It reports field and method presence, but deliberately leaves cross-host idle/current authority incomplete. A schema field by itself is not sufficient evidence to enable mutation.

## Findings

| Safety state | Official/current protocol | Local 0.147.0 evidence | App decision |
|---|---|---|---|
| Pinned | Current docs show `Thread.isPinned`; Desktop UI also persists an ordered `pinned-thread-ids` list | Stable generated `Thread` and live list omit `isPinned`. Desktop state matched all 13 user-identified pinned Codex IDs and UI order during live acceptance. | Read the Desktop list before and after inventory; matching exact membership is provider-persistent evidence. Missing/malformed/duplicate/drifted state or conflict with future `isPinned` is Unavailable. |
| Running | `Thread.status` has `active`; `thread/loaded/list` returns IDs currently loaded in memory by that App Server | Both exist in stable schema, but this app starts a separate manager-owned App Server process | `active` is positive evidence; every non-active result remains unknown because it cannot exclude another host |
| Active writer | Lifecycle RPC can return `-32600: thread <id> already has an active writer` when another host owns the rollout writer, even while Desktop presents the task as `idle` | Upstream App Server archive tests confirm the exact message; the 2026-08-13 acceptance confirmed `-32600` + Active readback while Desktop owned the task, but its old Report did not retain the original message | Positive writer evidence blocks before request. If writer state is unavailable, an allow-listed one-shot Archive may be attempted and may return Busy; rejection plus fresh Active readback is a verified failure, never retried |
| Current task | No cross-host current-thread identity is documented | No authoritative field in the stable or experimental thread schema | Unavailable |
| Descendant count | `parentThreadId` is returned; stable `ThreadSourceKind` includes interactive, exec, appServer, and sub-agent kinds | Verified in stable schema and synthetic capture | A second bounded all-source active + archived inventory builds the graph; available only after both reach final cursor |
| Pinned descendant | Requires both a complete descendant graph and complete pin states | Complete bounded graph is joined to the consistent Desktop pin snapshot | Verified only when graph coverage and every node pin value are complete; otherwise Unavailable |

The experimental `ancestorThreadId` filter is present locally, but Phase 1 does not enable experimental API. The stable all-source inventory is sufficient for read-only descendant counts and keeps protocol usage narrower.

## Fail-closed rules

- All-source truncation, repeated cursor, timeout, decode error, or RPC error makes descendant count unavailable and degrades provider health.
- A non-active runtime status never becomes `isRunning = false, known = true`.
- A separate App Server's non-active/not-loaded state, successful `thread/read`, or absence from its process-local loaded list never becomes verified writer clearance.
- Missing, malformed, drifted, or conflicting pin evidence remains unknown; current evidence remains unknown.
- Unknown protection state blocks Archive, Trash, and permanent deletion even if future UI code accidentally enables an action.
- Live read-only provider mutation capabilities remain false; only the separate production facade can hold Archive transport.
- A verified native Archive interface is only compatibility evidence; it is not manager execution authorization. The readiness gate and facade preflight both enforce this separation.

## Reverification triggers

Repeat this audit when the local Codex version changes, the official App Server contract changes, the app switches from a manager-owned child process to a shared daemon, or any live mutation phase begins.

The audit is intentionally not a single boolean feature gate. A newer schema that adds `isPinned` still requires a contract review before it can clear pin and pinned-descendant protection. Cross-host running/current unknown must remain visible and must never be presented as false; for an allow-listed Archive contract it may instead be handled as a provider-enforced Busy risk with one request and authoritative readback.

## Typed authority boundary

`ProtectionAuthorityPolicy` 現在會在 `SessionProtection` 前驗證每筆 observation 的 kind/source/scope：

- `thread/list.status` 只標為 `managerProcess`；`active=true` 會保護，但 non-active 不會成為 known false。
- 雙讀一致的 Codex Desktop `pinned-thread-ids` 或 runtime 實際提供的 `thread/list.isPinned`，屬 `providerPersistentState`，可清除單一 session pin state；兩者同時存在時必須一致。
- 完整 descendant graph 加上每個 node 的 resolved pin value，屬 `completeProviderGraph`，可清除 pinned-descendant state。
- running/current 的 false 只接受尚未接入的 `allRelevantHosts` source；缺少該 evidence 不得顯示 Verified clear，但 allow-listed Archive 可將它映射為 may-return-Busy，而不是直接宣告不可呼叫 API。
- duplicate facts、錯誤 kind/source/scope 或 mapping failure 一律 fail closed。

這層讓 Desktop pin adapter 可以安全接入，且沒有創造 0.147.0 仍缺少的跨-host running/current evidence。Mutation 仍只能經過獨立 facade、frozen Preview、confirmation、preflight與readback。
