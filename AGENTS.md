# Agent notes (Mudi)

This file is for coding agents working in this repo. Product/plan authority is `docs/plan/active_plan.md`.

## Pi tool timeouts are seconds

In this Pi environment, the bash tool `timeout` parameter is **seconds**, not milliseconds.

- Confirm from the tool schema (`timeout` described as seconds) before using large numbers.
- Ordinary commands (`rg`, `git`, `ls`): 15–30.
- Simulator `xcodebuild` generate/test: 180–240.
- Never use five-digit timeouts (e.g. 15000, 300000) — those are hours, not minutes.

If a command needs longer, split it or tell the user; do not “wait forever”.

## Xcode build products

Do **not** create a new DerivedData directory per iteration (`/tmp/mudi-phase6-foo`, `/tmp/mudi-phase7-bar`, …). That previously produced 400+ folders and ~200GB under `/tmp`.

- Reuse **one** path for local agent builds, e.g. `/tmp/mudi-build` (simulator) and `/tmp/mudi-build-device` (device install only).
- After a phase is archived/merged, delete stale `/tmp/mudi-*` trees and leftover `~/Library/Developer/Xcode/DerivedData/Mudi-*` hashes from removed worktrees.
- Prefer `xcodebuild -derivedDataPath /tmp/mudi-build` so products do not accumulate under default DerivedData.

## Devices vs simulator

- Default: XCTest and `xcodebuild test` on the **simulator** (booted sim such as `Mudi-iPhone17Pro`).
- Physical devices **only** when the user asks to install, or the active plan’s 手工出口 explicitly requires it.
- Do not run device XCTest “just in case”.
- Mimikyu (iPhone): `00008150-001265CE0E99401C`. Ditto (iPad): `00008103-001844D83E80801E`.
- Signing: user picks the Xcode Team; do not ask for the Team ID. Preserve it when regenerating the project (`scripts/generate-xcodeproj.sh`).

## Cursor Cloud

Cloud Agents run on Linux. Xcode, the iOS Simulator, `xcodebuild`, and XcodeGen do not run there, so `make bootstrap` and `make test-core` are macOS paths. `make test-core` goes through `mise`, and the locked XcodeGen build is macOS-only.

The Cloud Agent install puts Swift 6.4.1 on the default `PATH` (`/usr/local/bin/swift`) via Swiftly from swift.org. Verify the pure-Swift domain package with:

```sh
swift test --package-path Packages/HerdrKit
```

Do not let `swiftly` write a repository-root `.swift-version`. macOS builds use the Xcode toolchain; this repo does not pin a Swift version.

## Plan and git

- One active plan: `docs/plan/active_plan.md`. Do not implement `future/` “while here”.
- Do not archive/rotate a phase, merge to `main`, or push unless the user confirms.
- Tests first per the rotating-dev-plan skill. Herdr CLI + captured JSON are the wire contract; do not invent commands or fields.
- Prefer Chinese in conversation with the user.
