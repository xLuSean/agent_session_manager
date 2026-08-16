# Packaging and distribution

## Local DMG

Run from the repository root:

```bash
./scripts/package_dmg.sh
```

The script first verifies that App sources and Xcode linkage cannot reach the Fixture implementation. It then builds Release for the current Mac architecture, verifies the built executable has no Fixture implementation symbols, checks bundle metadata and the ad-hoc signature, creates and verifies a compressed DMG, mounts it read-only, checks the app and `/Applications` link, then prints its byte count and SHA-256 digest.

Artifacts are written under `dist/`, which is ignored by Git. Rebuilding the same version moves the prior exact DMG to macOS Trash before replacement.

The default artifact name matches the current pre-release tag:

```text
Agent-Session-Manager-0.1.3-alpha.1-<architecture>.dmg
```

The bundle version still comes from Xcode's `MARKETING_VERSION`. The packaging
script appends the current `alpha.1` release suffix. Override the suffix for a
later pre-release without changing the bundle version:

```bash
RELEASE_SUFFIX_OVERRIDE=alpha.2 ./scripts/package_dmg.sh
```

Set an explicitly empty suffix for a stable artifact such as
`Agent-Session-Manager-0.1.3-arm64.dmg`:

```bash
RELEASE_SUFFIX_OVERRIDE= ./scripts/package_dmg.sh
```

This local artifact starts directly in Codex Live, exactly like the Xcode Debug scheme. There is no Fixture/Live product switch and no launch environment override. Fixture implementations live in the separate `AgentSessionManagerFixtures` Swift target for deterministic tests and internal harnesses only; the shipping Xcode App target does not link that target.

## Local installation

Open the DMG and drag `AgentSessionManager.app` to `Applications`. The app resolves the Codex CLI from the inherited `PATH`, `/opt/homebrew/bin/codex`, or `/usr/local/bin/codex`, so Finder launch does not require Xcode.

This package is ad-hoc signed and intended for the same developer Mac. It is not notarized.

## Post-install UI smoke

`xcodebuild`、codesign與DMG mount驗證不會操作真實視窗。每個本機DMG安裝後仍需從`/Applications`
直接啟動並人工確認：

- 拖曳主視窗外框放大與縮小；root必須跟隨window resize，不得只壓縮內部三欄內容。
- 視窗可縮至860 × 560的product minimum，超過minimum時可自由放大。
- 完整退出再開啟後，Status預設為Active；All Sessions仍可手動選擇。
- Agent Systems位於Sidebar最上方並顯示必選的`Codex Live`；沒有All Agents、Fixture row或product-mode switch。
- Sidebar／Inspector divider與Session table column widths仍保存上次使用者設定。

這份smoke只驗證UI與shipping boundary，不應為了打包測試而執行任何live lifecycle mutation。

## Public distribution gate

Do not present a local DMG as a public release. Distribution to other users still requires:

- an Apple Developer ID Application certificate;
- hardened runtime and reviewed entitlements;
- signing the app and DMG with the Developer ID identity;
- Apple notarization and stapling;
- verification with `codesign`, `spctl`, `stapler`, and a clean-Mac install test;
- an architecture decision (`arm64` only or Universal 2);
- privacy/support text, versioning, and release notes.
- continued enforcement of the completed production data-source boundary through `scripts/verify_shipping_boundary.sh` and clean Release verification.

Fixture is not a public product mode. A release candidate that links Fixture support, starts in Fixture, or exposes a Fixture/Live switch fails this distribution gate and must not be published.
