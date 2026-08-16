# Codex App Server Compatibility

## Verified baseline

- Contract verification date: 2026-08-13
- Live transport verification date: 2026-08-13
- Local CLI: `codex-cli 0.147.0`
- Desktop-bundled CLI: `codex-cli 0.147.0-alpha.6.5`
- Runtime observed through `initialize`: Codex Desktop 0.147.0 on macOS arm64
- Official documentation: <https://developers.openai.com/codex/app-server/>
- Official manual snapshot SHA-256: `c34b6eebca92d1626a7515df9c229006ed0617b9c7daf5fba4712282c6644734`
- Version-specific schema command:

  ```bash
  codex app-server generate-json-schema --out <temporary-directory>
  ```

- Repeatable project audit:

  ```bash
  scripts/audit_app_server_contract.sh
  ```

The generated schema is a verification input, not a checked-in runtime dependency. Tests use small synthetic protocol captures and never depend on the user's real sessions.
The project audit never turns schema presence into mutation authorization: process-scoped runtime status cannot prove cross-host idle/current clearance.

## Read-only methods used by this app

The Phase 1 transport has a private method allowlist:

1. `initialize`
2. `initialized` notification
3. `config/read`
4. `thread/list`（interactive inventory 與獨立 all-source descendant inventory）
5. `thread/read`（只有使用者開啟 Conflict Resolution Preview 時依完整 ID 呼叫，`includeTurns=false`）

It does not contain a generic public JSON-RPC request API and does not call `config/write`, `config/batchWrite`, `thread/archive`, `thread/unarchive`, `thread/delete`, `thread/metadata/update`, or any turn method. The provider may report that an exact allow-listed runtime schema contains `thread/archive` / `thread/unarchive`; this is diagnostic evidence only and is separate from its always-false execution capability.

`thread/list` is called separately for active and archived threads with:

- `sourceKinds: ["cli", "vscode"]`
- `sortKey: "updated_at"`
- `sortDirection: "desc"`
- `useStateDbOnly: true`
- 50 items per page, following each opaque `nextCursor` until it is `null`
- at most 200 pages / 10,000 unique IDs per collection as a hard safety bound

The adapter passes each cursor back unchanged, deduplicates native IDs across pages, and stops normally only when `nextCursor` is `null`. A repeated cursor or the hard page limit marks the provider `Degraded`; it never enables the default JSONL scan-and-repair path to fill gaps.

## Compatibility findings

| Field or capability | Official docs | Local 0.147.0 schema/runtime | App behavior |
|---|---|---|---|
| Active / archived inventory | `thread/list` with `archived` filter | Verified | Available |
| Full native ID | `thread.id` | Verified | Displayed unchanged |
| Title | `thread.name`, otherwise preview | Verified | Uses name, then first preview line capped at 120 characters |
| Desktop project | `.codex-global-state.json` → `local-projects` | Verified read-only Desktop catalog | Longest project root ancestor is matched to each working folder; unavailable on read failure/no match |
| Git repository metadata | `thread.gitInfo.originUrl` | Optional; verified | Kept distinct and not used as Project fallback |
| Working folder | `thread.cwd` | Verified | Displayed unchanged and grouped separately |
| Trust folder | `config/read` → `projects.<path>.trust_level` | Verified | Longest configured ancestor is matched to each working folder |
| Runtime status | `thread.status`; `thread/loaded/list` lists process-loaded IDs | Stable schema verified | `active` is positive running evidence; non-active cannot rule out another host and remains unknown |
| Writer authority | Public transports allow clients to connect to one App Server; `thread/unsubscribe` only removes the current connection and unloads after a grace period when it is the last subscriber | Process inspection shows Desktop launches its bundled `codex ... app-server --analytics-default-enabled` without `--listen`, therefore using default stdio owned by the Desktop parent. The documented managed control socket is absent, and `daemon start` cannot run from this Homebrew/Desktop installation because the official installer-managed standalone binary is missing. | Exact-ID/runtime/inventory-hash/checkpoint-bound authority is Unavailable; this prevents advance success prediction but does not remove the official Archive interface. Positive writer evidence blocks; otherwise an allow-listed one-shot request may safely return Busy |
| Pin state | Current docs show `thread/list` results with `isPinned`; Codex Desktop also persists its ordered `pinned-thread-ids` UI list | `isPinned` is absent from locally generated stable `Thread` and observed list results. The Desktop list matched all 13 user-identified pinned Codex IDs and order during 2026-08-14 live acceptance. | Read-only Desktop state is sampled before and after inventory; exact membership must match. Missing/malformed/duplicate/drifted state or conflict with a future `isPinned` value is Unavailable. |
| Descendant count | `parentThreadId`; stable source kinds include sub-agents | Verified with bounded all-source active + archived inventory | Available only when both all-source collections finish without truncation |
| Pinned descendant | Requires complete graph and complete pin states | Bounded all-source graph plus consistent Desktop pin snapshot verified | Known only when the graph reaches its final cursors and every node resolves a non-conflicting pin value |
| Current thread | No authoritative cross-host field established | Not established | Unavailable |
| Size | Not part of stable list contract | Not returned | Unknown; app does not inspect rollout paths |
| Exact-ID existence | `thread/read` reads a stored thread without resuming/subscribing | Success verified for a listed ID | Present evidence; `includeTurns=false` |
| Exact-ID absence | Official docs describe `thread/read` success but do not define a general stable not-found discriminator | On audited 0.147.0, missing exact UUID returns JSON-RPC `-32600`, `thread not loaded: <id>` | Generic Conflict Review still treats this as Unavailable. Delete-specific finalization accepts it only when a newer complete active+archived inventory from the same runtime also omits the exact ID; neither signal alone proves Deleted. |
| Archive / unarchive interface | Current manual documents `thread/archive` and `thread/unarchive`; archive may also archive spawned descendants | Both methods and their notifications are present in generated 0.147.0 stable schema; synthetic process verifies both exact payloads and empty responses | Separate production facades wrap internal Archive/Restore executors, are allow-listed only for audited 0.147.0 builds, send at most once, and require newer exact-ID inventory readback. Archive remains pin-evidence gated. Active → Trash adds manager membership only after Archived success; Trash → Active removes it only after Active success |
| Delete interface | Generated stable schema defines `thread/delete` with exact `threadId` and empty response; notification carries the deleted `threadId` | Present in audited 0.147.0 schema; fake missing-ID probe established the exact version-scoped absence discriminator without mutating a real session | Guarded single/batch facade accepts only Manager Trash; each item sends at most once and requires dual absence readback. Archive cannot call Delete directly. |

The `notFound` strings present elsewhere in the generated 0.147.0 schema belong to unrelated typed enums such as `CollabAgentStatus`; they are not a general `thread/read` contract. The app matches `thread not loaded: <exact id>` only inside the version-allow-listed Delete executor/recovery and only together with complete list absence; all other callers keep it Unavailable.

## Transport notes

- The client launches `codex app-server --listen stdio://` and performs the required handshake.
- Runtime authority does not come from `initialize.result.userAgent`: that value identifies the requesting client and is observed as `agent_session_manager/...` for this App. Before inventory, exact readback or lifecycle execution, the adapter runs `--version` on the exact selected Codex executable and accepts only a strict `codex-cli <version>` result. The checkpoint stores that selected-executable version; lifecycle execution repeats the probe and still requires the exact audited allow-list.
- Official docs also describe WebSocket and Unix-socket transports, including a default App Server control socket. Sharing one documented lifecycle host would improve pre-attempt writer visibility, but is not required to submit an official Archive request that can safely succeed or return Busy. It does not prove that Codex Desktop's private IPC socket implements that contract, and the app never guesses that equivalence.
- A 2026-08-13 live process check found Desktop's bundled App Server running as a child of ChatGPT with no `--listen` argument, so its transport is the default parent-owned stdio rather than the documented control socket. The default managed socket at `~/.codex/app-server-control/app-server-control.sock` was absent.
- `codex app-server daemon start` was tested read-only up to startup and refused because this installation lacks the official installer-managed `~/.codex/packages/standalone/current/codex`; the project did not install another Codex distribution. A short-lived `/tmp` Unix listener plus `app-server proxy --sock` probe also failed to establish the documented WebSocket upgrade (`httparse invalid token`). The probe sent only initialization and `thread/loaded/list`, performed no lifecycle mutation, and was stopped and trashed. This version-specific failure is not treated as shared-host evidence.
- JSON-RPC stdout uses `poll(2)` plus POSIX `read(2)`. Foundation `FileHandle.read(upToCount:)` was rejected after a live test showed indefinite pipe blocking.
- Child stderr is sent to a non-blocking sink. Leaving stderr on an undrained pipe can deadlock stdout.
- `F_SETNOSIGPIPE` converts a closed child stdin into a thrown error instead of terminating the app.
- Each JSON-RPC request has its own 45-second deadline.
- `thread/read` is launched only for explicit Conflict Review. A successful response must return the exact requested ID and is tagged `exact_match`. Any different ID, timeout, transport error, decode error, or undocumented missing-ID RPC error is typed as Unavailable with a structured evidence kind; RPC failures retain the numeric code.
- `thread/archive` is isolated behind a public single-root facade whose transport and executor remain internal; the read-only inventory provider still cannot mutate. An empty RPC response is acknowledgement, not success; the executor requires a complete post-attempt active/archived inventory containing the full exact ID, and never retries an uncertain request. The 2026-08-13 isolated request proved `-32600` rejection plus Active readback while Desktop still owned an `idle` task. Upstream App Server archive tests map this ownership conflict to `thread <id> already has an active writer`; the acceptance's old Report did not retain its original RPC message, so that mapping remains a strongly supported diagnosis rather than verbatim evidence from the run.
- `thread/unarchive` is isolated behind a different public Archive/Trash facade. It freezes Archived state and exact identity, sends at most once, and requires a newer Active readback. Trash adds a durable `.remove` membership intent and frozen membership-set hash; success removes membership in the same Report/Preview transaction, while failure/unknown preserve it. Readback-only recovery cannot call unarchive but can finish this local finalization.
- `thread/delete` is isolated behind a Trash-only facade. Provider-wide `protectionComplete` is not its eligibility gate because a manager-owned App Server cannot prove cross-host running/current negative state. Positive pinned/running/current/pinned-descendant and unknown pin/pinned-descendant evidence still block; running/current unknown is disclosed as `attemptMayFail`. Each exact ID is submitted at most once, and only complete inventory absence plus the allow-listed exact not-loaded readback creates a Deleted tombstone. Failure or unknown retains Manager Trash and is never retried automatically.
- `ExactSessionReadbackEvidence.provesAbsence` requires `.absent` + `documented_not_found` + a contract whose provider, exact runtime version and RPC code match the evidence, plus a non-empty identifier and HTTPS official source. Conflict planning uses this computed proof instead of trusting status alone. No Codex contract is registered for 0.147.0.
- Inspector evidence is field-specific and three-state: Protected, Verified clear, or Unavailable. Pin prefers emitted `thread/list.isPinned` and otherwise uses the start/end-consistent Codex Desktop `pinned-thread-ids` snapshot; disagreement is unavailable. Running accepts only local `status.active` as positive evidence; pinned-descendant clearance requires a complete graph and every descendant pin value; current-task identity remains unavailable.
- Archive readiness keeps exact-ID/runtime/checkpoint-bound writer evidence as useful prediction and positive protection. Missing or non-matching clearance evidence is an explicit `attemptMayFail` risk instead of verified clearance or a universal prohibition; affected-set factory, SQLite save/claim, single-item executor, recovery, production facade, and SwiftUI Preview/confirmation/Report flow use the same operation-specific contract.
- Shutdown is bounded: close stdin, interrupt the child, wait briefly, then kill only that app-owned child if necessary.
- The explicit live smoke test needs permission for the child App Server to initialize its own `~/.codex` state runtime. A restricted workspace sandbox can deny that SQLite initialization; the provider reports unavailable and does not fall back to fixture data or direct file reads.

## Gate for future work

Do not bypass the current UI gate. The control-socket investigation is complete and is no longer a prerequisite: a shared lifecycle host would improve prediction, but a separate official App Server can still submit `thread/archive`, with an occupied writer producing a safe rejection. Readiness, Preview construction, SQLite persistence/claim, executor preflight, production facade, SwiftUI confirmation/report, and startup/refresh readback-only recovery now share one operation-specific contract: writer/running/current unknown remains `attemptMayFail`, all positive protection still blocks, and pinned/pinned-descendant unknown still fails closed. The current 0.147.0 App Server omits pin data, but the separately audited Desktop persistent-state adapter now supplies it when two reads agree; Create Preview is therefore available to eligible non-pinned roots. A future runtime `isPinned` implementation must still pass schema/runtime audit, and any disagreement with Desktop state fails closed.
