# Security Policy

Agent Session Manager can perform lifecycle operations, including permanent deletion, on agent
sessions. Security reports should protect real session data and must not create additional destructive
operations solely to demonstrate an issue.

## Supported Versions

Before the first stable release, only the latest release and the current `main` branch receive security
fixes. Older snapshots are not supported.

## Reporting a Vulnerability

Do not report a vulnerability through a public GitHub issue.

Use the repository's GitHub private vulnerability reporting entry point (`Security` → `Report a
vulnerability`). If that entry point is unavailable, open a public issue requesting a private contact
channel without including vulnerability details, logs, screenshots, session IDs, local paths, project
names, or account information.

Include the affected version, macOS version, expected safety property, observed behavior, impact, and
the smallest non-destructive reproduction that you can provide. Use fixtures or sessions you own.

## Relevant Security Issues

- Unauthorized archive, restore, trash, or permanent-delete operations.
- Bypassing pinned, running, current-task, descendant, Preview, confirmation, or exact-selection
  protection.
- Treating an unknown lifecycle outcome as success or automatically retrying an ambiguous mutation.
- Exposure of local session metadata, diagnostic logs, project names, paths, or identifiers.
- Injection or path-handling issues involving the Codex runtime, exports, packaging, or SQLite storage.

## Safe Disclosure

- Redact real session IDs, local paths, project names, account information, and unrelated log content.
- Do not access, modify, or delete sessions that you do not own.
- Do not publish exploit details before a fix or mitigation is available.
- Do not attach the App's SQLite database, Codex state files, JSONL files, or unredacted diagnostics.

Reports made in good faith and within these boundaries are welcome. No response or resolution timeline
is guaranteed.
