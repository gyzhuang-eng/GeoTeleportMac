# GeoTeleport Development Plan

> Single source of truth for the GeoTeleport project. A developer picking up
> this repo should be able to orient from this file alone. When this plan
> changes, change this file; do not fork planning notes into other docs.

---

## 0. Handoff Snapshot (read this first)

**You are the next engineer on this project.** The repo has been prepared
specifically for handoff. Here is what you need to know in 60 seconds:

- **Branch to work on:** `v3-no-python-foundation`. `main` is the untouched
  baseline — do not start from `main`.
- **HEAD commit on this branch** represents Phase A complete: the UI, state
  model, agent boundary, typed readiness model, and the developer-machine
  injection/tunnel path described in §3 are all in place and build clean.
- **Your first task is B.1** (§12, item 1). Do *not* jump straight to B.3.
  B.1 is three small, safe, independently-shippable edits that make the
  current dishonest state honest before any real migration begins.
- **Do not ship the current DMG to users.** Today's code fails on any Mac
  without Xcode or without `pymobiledevice3` installed. That is the gap
  Phase B closes. See §2 for why the prior framing was misleading.
- **The load-bearing open decision is §7.** Pick the device-core technology
  before starting B.3. Write the decision into §7 of this file and commit.

### Day-1 verification checklist

Before writing any new code, confirm your environment is sane:

```bash
# 1. You are on the right branch
git rev-parse --abbrev-ref HEAD          # expect: v3-no-python-foundation

# 2. Working tree is clean
git status                                # expect: nothing to commit

# 3. The app builds
xcodebuild -project GeoTeleportMac.xcodeproj \
  -scheme GeoTeleportMac -configuration Debug build

# 4. The self-checks still pass on the built app
APP="build/DerivedData/Build/Products/Debug/GeoTeleportMacV3.app/Contents/MacOS/GeoTeleportMac"
# (or wherever xcodebuild placed it — check DerivedData output path)
"$APP" --v3-self-check-tunnel-log-parser
"$APP" --v3-self-check-injection-transport
"$APP" --v3-self-check-xcode-location-harness

# 5. Launch the app once on your dev machine (with Xcode + pymobiledevice3
#    installed) and confirm the UI renders and USB detection fires.
```

If any of the above fails, stop and diagnose before starting B.1. A green
checklist is the contract between the previous engineer and you.

### What is NOT your job on day 1

- Do not touch `main`. Do not merge `v3-no-python-foundation` anywhere yet.
- Do not rewrite Phase A code "for cleanliness." The typed readiness /
  gate / blocker / next-action model in §3 is load-bearing and the
  Phase B work plugs into it at the agent-service seam.
- Do not start Phase C (packaging, signing, DMG) before Phase B is green.
  Signing a device stack that does not work is wasted ceremony.
- Do not add features. Phase B is replacement work, not feature work.

---

## 1. What We Are Building

GeoTeleport is a desktop app that lets end users fake the GPS location on a
USB-connected iPhone.

**Target user.** A non-technical iOS user. They download an installer, plug in
their iPhone with a Lightning/USB-C cable, and expect the app to work without
installing Python, Xcode, `pymobiledevice3`, `pipx`, Homebrew, or any developer
toolchain.

**Current platform.** macOS, shipped as a signed, notarized `.dmg`.

**Next platform.** Windows, same iOS workflow. The macOS work must not paint us
into a Mac-only corner; the device-side logic should be extractable into a
cross-platform core.

**Out of scope.**
- Android targets (host or device).
- Jailbreak-only features.
- Cloud sync, accounts, remote control, team features.
- Wireless (non-USB) workflows until the USB path is fully shippable.

---

## 2. User Reality Check (why prior planning needs correction)

Prior iterations of this plan were organized around the slogan "no Python." In
a consumer-DMG context that slogan is insufficient and in parts misleading:

1. **The consumer has no Xcode.** Our current primary injection path runs
   `xcodebuild test` against an XCTest harness. That works on a developer's
   Mac. On a clean consumer Mac there is no `xcodebuild`. The current code
   will fail immediately for every target user.
2. **The consumer has no `pymobiledevice3`.** The "product-owned tunnel
   controller" still shells out to `pymobiledevice3 remote tunneld` for iOS
   17+ RemoteXPC tunneling. On a consumer Mac that binary is absent.
3. **macOS App Sandbox will not host this workflow.** `xcodebuild`, arbitrary
   subprocess spawning, and raw USB control are incompatible with a sandboxed
   Mac App Store build. Distribution must be Developer ID + notarization; MAS
   is not a viable channel for V3.
4. **Windows has neither Python nor Xcode nor `pymobiledevice3`.** Any
   architecture that keeps shelling out to these tools will need to be
   rebuilt for Windows. That argues for a bundled native device core now.

The honest label for the work so far is therefore:

- `no-Python *UI*` — achieved (the app no longer scans for or instructs users
  about `python3`, `pipx`, or `pymobiledevice3`).
- `no-Python *runtime*` — NOT achieved (the tunnel controller still executes
  `pymobiledevice3`).
- `no-Xcode *runtime*` — NOT achieved (the injection path still executes
  `xcodebuild test`).
- `shippable DMG` — NOT achieved.

Everything below is organized around closing those three gaps.

---

## 3. Current State Snapshot

**Active branch:** `v3-no-python-foundation`
**App identity (isolated from `main`):**
- Product name: `GeoTeleportMacV3`
- Bundle id: `com.test.GeoTeleportMac.v3`
- Defaults keys namespaced with `v3.`
**Build artifact:**
`build/DerivedData/Build/Products/Debug/GeoTeleportMacV3.app`

### What already works on a developer machine

- SwiftUI `ContentView` no longer owns `Process` execution, dependency
  scanning, `ioreg`/`pgrep` calls, or Terminal AppleScript launches.
- `V3RuntimeCoordinator` + typed service protocols sit between the UI and the
  backend (`DeviceMonitoring`, `TunnelManaging`, `LocationInjecting`,
  `DiagnosticsProviding`).
- Two backend tracks exist: `legacyPreview` (retained for regression
  comparison) and the default `noPythonStub` track.
- A child-process agent boundary works end-to-end: the app re-executes its own
  binary with `--v3-agent`, and app↔agent communicates over stdin/stdout with
  a typed JSON protocol (`V3DeviceAgentProtocol`).
- Typed readiness model drives the UI and diagnostics: `DeviceAgentAvailability`,
  `DeviceSessionState`, `ConnectionHealth`, `SessionBlocker`, `nextAction`,
  `DeviceAgentReadinessGate`, refresh intent/scope/focus, typed tunnel
  `requirement/lifecycle/session/health`, `protocolHint`, injection transport
  contract, `DeviceInfoTransportServiceStack` with two slots (reserved
  typed-metadata + USB-bootstrap stub).
- USB device detection via `system_profiler SPUSBDataType` with `ioreg` fallback.
- Tunnel health verification layered as: startup-log readiness markers →
  `lsof` listener discovery → TCP connect → session-handshake probe →
  expected-RSD endpoint verification.
- Primary injection path: a materialized `GeoTeleportLocationHarness` XCTest
  package under `~/Library/Application Support/
  com.test.GeoTeleportMac.v3/GeneratedArtifacts/GeoTeleportLocationHarness`,
  run via `xcodebuild test` keyed by an `xcdevice`-resolved identifier.
- Self-checks: `--v3-self-check-tunnel-log-parser`,
  `--v3-self-check-injection-transport`,
  `--v3-self-check-xcode-location-harness`.

### What does NOT work for the target DMG user

- The Xcode-backed injection path fails on any Mac without Xcode installed.
- The tunnel controller fails on any Mac without `pymobiledevice3` installed.
- The DMG has no code-signing, no notarization, no entitlements design, no
  first-run onboarding, no privileged-helper story.
- Multi-device is detected as a blocker but not presented as a selectable UI.
- The JSON agent protocol has no `schemaVersion` field; a mismatched app/agent
  pair would fail in hard-to-diagnose ways.
- No consumer-Mac end-to-end validation has been performed.

---

## 4. Target Architecture

```
┌────────────────────────────────────────────────────────────────┐
│ App shell (SwiftUI)                                            │
│   - Renders from typed state only                              │
│   - Zero process / shell / toolchain knowledge                 │
├────────────────────────────────────────────────────────────────┤
│ Domain & coordination (Swift)                                  │
│   - V3AppModel, V3RuntimeCoordinator                           │
│   - Typed blockers / gates / readiness / next-actions          │
│   - Diagnostics store                                          │
├────────────────────────────────────────────────────────────────┤
│ Device Agent boundary (JSON protocol, versioned)               │
│   - Request/Response are typed, schema-versioned               │
│   - Transported via child-process today; XPC-ready tomorrow    │
├────────────────────────────────────────────────────────────────┤
│ Device Core (BUNDLED INSIDE THE DMG — this is the missing piece)│
│   - USB enumeration                                            │
│   - Lockdown-style device info                                 │
│   - iOS 17+ RemoteXPC / RSD tunnel lifecycle                   │
│   - simulate-location set / clear                              │
│   - No host-toolchain dependency                               │
│   - Cross-platform-compilable (mac today, Windows later)       │
├────────────────────────────────────────────────────────────────┤
│ OS plumbing (per host)                                         │
│   - macOS: IOKit / libusb / code-signed helper if needed       │
│   - Windows: WinUSB / libusbK / driver assistant               │
└────────────────────────────────────────────────────────────────┘
```

Key architectural invariants:

- **The app shell never knows how the device is reached.** It renders typed
  state. Swapping the device core is a single-seam change.
- **No shell-out to user-installed tools.** The bundled device core owns
  everything USB/protocol-related.
- **Core is portable.** Anything the device core needs from the OS goes
  through a small host-adapter layer. The core itself must compile on
  Windows with only the adapter changed.

---

## 5. Phase Roadmap

### Phase A — UI & state foundation ✅ DONE

Refactor out of the monolithic `ContentView`, introduce the agent boundary,
establish the typed readiness model. This is complete. Do not reopen Phase A
work without a concrete cause.

### Phase B — Shippable device core 🔴 NEXT, BLOCKING EVERYTHING ELSE

Replace both `pymobiledevice3` shell-out and the `xcodebuild` injection path
with a bundled native device core that requires zero user toolchain.

Phase B is split into three deliverables that must land in order:

**B.1 — Make the current state honest in the UI.**
- Detect `xcodebuild` availability; add blocker code `xcodeToolchainMissing`.
- Detect a usable `pymobiledevice3`; add blocker code `pymobiledevice3Missing`.
- When either is missing, the UI must render a concrete, non-technical message
  and the app must not silently spin.
- Add `schemaVersion: Int` to every `DeviceAgentRequest` / `DeviceAgentResponse`.
  Mismatch between app and agent must fail fast with a typed error.
- Explicitly mark the `pymobiledevice3 remote tunneld` call site as
  `TEMPORARY_CLI_BRIDGE` in code and in this plan. This is not the shipping
  implementation.

**B.2 — Choose the device-core technology.** Decision-making rubric in §7.
Lock the choice by writing the decision into §7 of this file. Until this is
decided, B.3 cannot start.

**B.3 — Implement the bundled device core.** Covers the four capabilities the
app needs:
1. USB device enumeration (replaces `system_profiler` + `ioreg`).
2. Lockdown-style device info fetch, iOS 17+ compatible.
3. RemoteXPC / RSD tunnel lifecycle for iOS 17+ (replaces the
   `pymobiledevice3 remote tunneld` shell-out).
4. `simulate-location` set / clear (replaces the XCTest harness injection).

Each capability is wired behind the existing agent boundary by replacing the
current adapter inside `V3DeviceAgentService`. The app code above the agent
boundary should not change during Phase B.

**Phase B exit criteria.**
- The DMG build runs on a Mac that has never had Xcode, `pymobiledevice3`,
  Python, Homebrew, or `pipx` installed.
- `set` and `clear` location succeed against a real iOS 17+ device over USB
  on that clean Mac.
- No subprocess spawn targets a user-installed binary outside the `.app`
  bundle.

### Phase C — DMG packaging & first-run UX

- Developer ID signing for every binary the `.app` ships.
- Notarization + stapling for the DMG.
- Hardened runtime + minimum required entitlements documented.
- First-launch assistant:
  - Explain "enable Developer Mode on your iPhone" for iOS 16+.
  - Explain "trust this Mac" prompt on the device.
  - Detect and explain "iPhone is locked" / "no USB connection" states.
- Distinguish "no device" from "device connected but not trusted" in the UI.
- Drop the remaining Terminal / AppleScript code paths entirely.

### Phase D — Consumer-Mac validation

- Clean-install tests on at least two macOS versions, two iPhone models, and
  two iOS major versions (including one iOS 17+).
- Sparse but real crash/telemetry path (opt-in), scoped to device-core
  failures only; no PII.
- Support-artifact export: the user can attach a diagnostics bundle without
  running Terminal.

### Phase E — Cross-platform core extraction

Restructure so the device core is a standalone library with a stable C / FFI
boundary. The macOS host shrinks to: SwiftUI shell + domain model + FFI
adapter to the core. This is the point at which the codebase stops being
"a Mac app" and starts being "a product with a Mac front-end."

### Phase F — Windows port

- Windows host: pick the UI stack (likely WinUI 3, or Tauri if a shared web
  UI makes more sense after Phase E).
- Windows USB driver story: WinUSB vs libusbK; assess whether a driver
  installer is needed.
- Reuse the device core from Phase E unchanged except for the host adapter.
- Installer: MSIX or signed `.exe`/`.msi`.
- Windows-side first-run UX parallels Phase C.

---

## 6. Phase Status at a Glance

| Phase | Scope                                  | Status        |
|-------|----------------------------------------|---------------|
| A     | UI/state/agent boundary                | ✅ DONE       |
| B.1   | Honest blockers, protocol versioning   | 🔴 TODO       |
| B.2   | Device-core tech decision              | 🔴 TODO       |
| B.3   | Bundled device core implementation     | 🔴 TODO       |
| C     | DMG signing, notarization, first-run   | ⬜ NOT STARTED |
| D     | Consumer-Mac validation                | ⬜ NOT STARTED |
| E     | Cross-platform core extraction         | ⬜ NOT STARTED |
| F     | Windows port                           | ⬜ NOT STARTED |

A previous revision of this plan marked Phases 1–3 as "complete in practice."
That claim conflated "implemented on a developer machine" with "shippable."
The table above reflects shippability.

---

## 7. Device-Core Technology Decision (Phase B.2)

This is the load-bearing decision of the whole product. It must be made
before Phase B.3 starts.

### Option 1 — Bundle `pymobiledevice3` + embedded Python inside the .app

- **How.** Ship an embedded Python framework and `pymobiledevice3` as a
  code-signed helper binary inside `Contents/Helpers`. Treat it as a private
  implementation detail; never let the user see it.
- **Pros.** Fastest route to a shippable DMG. iOS 17+ RSD support is already
  working. Smallest code change from today.
- **Cons.** Adds ~60–100 MB to the DMG. Code-signing nested Python
  frameworks under hardened runtime is fiddly. Still not cross-platform in
  any meaningful sense; Windows gets nothing reusable. Long-term anchor to
  Python.

### Option 2 — `libimobiledevice` (C)

- **How.** Link `libimobiledevice` + `libusbmuxd` as bundled dylibs.
- **Pros.** Mature, cross-platform, no Python. Existing Swift ↔ C FFI story
  is easy.
- **Cons.** iOS 17+ RSD / tunneld support upstream is incomplete; you end up
  carrying a fork. Long tail of modern-iOS regressions to chase.

### Option 3 — Rust device stack (e.g. `idevice-rs` family)

- **How.** Build the device core in Rust, expose a C ABI or UniFFI binding,
  consume from Swift on mac and from the Windows host later.
- **Pros.** Aligns directly with the Windows roadmap; one core, two hosts.
  Modern iOS 17 RSD work is landing in this ecosystem. Rust toolchain
  cross-compiles cleanly to Windows.
- **Cons.** Longest short-term path. iOS 17 coverage is still maturing;
  expect contribution work upstream. Team must accept Rust as a permanent
  part of the stack.

### Option 4 — Roll our own Swift / C++ RemoteXPC stack

- **Pros.** Full control.
- **Cons.** Months of work before the first packet. Do not choose this
  unless the team has excess engineering capacity and a strategic reason.

### Recommended sequencing

Unless time-to-ship is the dominant constraint, **pick Option 3 (Rust)** and
accept one extra quarter of bring-up. This is the only option that gives
Phase F a real foundation.

If time-to-ship dominates, ship **Option 1 first** as a private helper to get
a DMG into users' hands, and run Option 3 in parallel as the "real"
implementation. Plan to cut over in a minor version after Option 3 reaches
parity. Do not adopt Option 1 without writing a dated replacement commitment
in this section.

**DECISION:** _(to be filled in when the team decides — commit this change
and reference the commit in release notes.)_

---

## 8. Packaging & Distribution Strategy

- **Channel.** Developer ID + notarized DMG. Not Mac App Store.
- **Signing surface.** The `.app`, the bundled device core binary, any
  helper tools, and the DMG itself. All must be signed with the same
  Developer ID Application identity and pass `spctl -a -vv` and
  `stapler validate`.
- **Hardened Runtime.** Enabled. Required entitlements documented in the
  repo at build time, not spread across Xcode UI state.
- **Auto-update.** Deferred to post-Phase-C. Initial releases are manual
  DMG downloads; add a Sparkle-style updater once Phase D validation is
  green on real users.
- **Windows (Phase F).** Signed `.exe` installer (MSI or MSIX). Driver
  installation — if WinUSB cannot attach without one — gets its own
  first-run step.
- **Do not** target the Mac App Store; `xcodebuild`, sub-process spawning,
  raw USB control, and any privileged helper design are all sandbox hostile.
  If App Store distribution ever becomes a goal, it is a separate product.

---

## 9. Branch & Delivery Strategy

- `main` — the currently shipping product baseline. Do not destabilize.
- `v3-no-python-foundation` — long-lived integration branch for everything
  in this plan. Merges from short-lived topic branches.
- Topic branches off `v3-no-python-foundation`:
  - `v3/honest-blockers` (Phase B.1)
  - `v3/core-decision` (Phase B.2 — docs-only PR capturing the decision)
  - `v3/device-core-<tech>` (Phase B.3, name reflects the chosen option)
  - `v3/dmg-signing` (Phase C)
  - `v3/cross-platform-core` (Phase E)
  - `v3/windows-host` (Phase F)

Do not merge `v3-no-python-foundation` back to `main` until at minimum
Phases B, C, D are green. A half-done V3 on `main` is worse than shipping V2.

---

## 10. Risks & Mitigations

| Risk                                                            | Mitigation                                                               |
|-----------------------------------------------------------------|--------------------------------------------------------------------------|
| iOS 17+ RSD protocol keeps moving                               | Pick the tech that is most actively maintained (Option 3 favored)        |
| USB access requires privileged helper on macOS                  | Design for a SMJobBless / SMAppService helper from day one of Phase B.3  |
| Windows driver story blocks Phase F                             | Scope a WinUSB proof-of-concept during Phase E, not after                |
| Option 1 (bundled Python) gets entrenched                       | Dated replacement commitment must be in §7 before Option 1 ships         |
| DMG gets flagged by Gatekeeper due to helper signing            | Notarize every binary separately, run signing verification in CI         |
| Users enable Developer Mode incorrectly / don't trust the Mac   | First-run assistant (Phase C) covers these states explicitly             |
| Multi-device connected simultaneously                           | Turn the existing `multipleDevices` blocker into a selection UI in Phase C |
| App/agent protocol drift once agent is a separate signed binary | `schemaVersion` in Phase B.1; typed failure on mismatch                  |

---

## 11. Definition of Done for V3 (macOS)

All of the following must be true before a V3 DMG is offered to users:

1. A clean Mac with no Xcode, no Python, no `pymobiledevice3`, and no
   Homebrew can run the DMG and successfully set and clear a location on a
   connected iOS 17+ iPhone.
2. The app bundle contains every binary it needs; no runtime subprocess
   targets a user-installed tool.
3. The DMG is Developer ID signed and notarized; hardened runtime is
   enabled; `spctl` and `stapler` pass.
4. The UI speaks product language only — no mention of Python,
   `pymobiledevice3`, Terminal, `pipx`, or `xcodebuild` anywhere visible to
   the user.
5. Failure states are typed, user-actionable, and do not expose stack
   traces or raw shell output.
6. Multi-device detection leads to a selection UI, not a dead-end blocker.
7. Diagnostics can be exported as a single file without the user opening
   Terminal.
8. Agent protocol carries `schemaVersion`; mismatched versions fail with a
   clear error.

Definition of Done for V3 (Windows) is a separate milestone, gated on
Phase E completion. At minimum it mirrors items 1, 2, 4, 5, 6, 7 on
Windows.

---

## 12. Where to Start (concrete next commits)

In execution order for whoever picks this up next:

### Step 1 — Add honest blockers (branch: `v3/honest-blockers`)

Today the app shows a spinning "probing" state on any Mac that lacks Xcode
or `pymobiledevice3`. That is the single most user-hostile behavior and it
is trivial to fix. This is your first commit.

Concrete implementation sketch:

- In `V3DeviceAgentService.swift`, add a `ToolchainProbe` helper that runs
  these three checks once per probe cycle and caches the result:
  - `xcode-select -p` exits 0 *and* the returned path is not
    `/Library/Developer/CommandLineTools` (that path means CLT only, no
    Xcode).
  - `xcrun xcodebuild -version` exits 0.
  - `which pymobiledevice3` finds a binary, and `pymobiledevice3 --version`
    exits 0.
- In `V3DeviceAgentModels.swift`, add three cases to
  `DeviceAgentAvailabilityBlocker`:
  - `xcodeToolchainMissing`
  - `pymobiledevice3Missing`
  - `bundledDeviceCoreMissing` *(placeholder the Phase B.3 work will flip
    on once the native core replaces the other two)*
- In `V3NoPythonBackendStub.swift`, map each blocker to a user-facing
  `nextAction` string that speaks product language. Examples:
  - `xcodeToolchainMissing` → "GeoTeleport requires Xcode on this build.
    The shipping version will not. (internal: Phase B.3)"
  - `pymobiledevice3Missing` → "GeoTeleport requires pymobiledevice3 on
    this build. The shipping version will not. (internal: Phase B.3)"
- Add a unit-test-style self-check at the agent entrypoint:
  `--v3-self-check-toolchain-probe` that prints each probe's result and
  exits non-zero if the probe machinery itself is broken (not if a tool is
  absent — absence is a valid result).
- In `ContentView.swift`, ensure the status card renders these blockers as
  first-class states, not as generic "backend unavailable."

Exit criterion for Step 1: on a Mac with Xcode uninstalled (or
`sudo xcode-select --reset` used to point at CLT), the app launches, does
not spin, and the status card explains the gap in one sentence.

### Step 2 — Version the agent protocol (branch: `v3/protocol-version`)

- Add `schemaVersion: Int` at the top of both `DeviceAgentRequest` and
  `DeviceAgentResponse` in `V3DeviceAgentProtocol.swift`. Define
  `currentSchemaVersion = 1` as a single source of truth.
- In `V3ChildProcessDeviceAgentClient.swift`, reject any response whose
  `schemaVersion` does not match `currentSchemaVersion`, returning a
  typed `DeviceAgentFailure.schemaVersionMismatch(expected:, got:)`.
- Mirror this on the agent side in `V3DeviceAgentEntrypoint.swift`:
  reject incoming requests with an unknown version.
- Add `--v3-self-check-agent-protocol-version` that round-trips a request
  at the current version and confirms the matcher logic rejects `0` and
  `currentSchemaVersion + 1`.

This is throwaway-looking work that will save hours once the agent becomes
a separately signed binary in Phase C.

### Step 3 — Annotate the temporary CLI bridge

- In `V3DeviceAgentService.swift`, find the `pymobiledevice3 remote tunneld`
  invocation inside the product-owned tunnel controller. Add above it:

  ```swift
  // TEMPORARY_CLI_BRIDGE: shells out to user-installed pymobiledevice3.
  // This does NOT work on consumer Macs and must be replaced by the
  // bundled device core (see docs/v3-no-python-foundation-plan.md §5 Phase
  // B.3). Do not add features here.
  ```

- In `XcodeTestLocationInjectionTransportAdapter`, add the same marker on
  the `xcodebuild test` invocation, referencing Phase B.3.
- Grep for `TEMPORARY_CLI_BRIDGE` must be zero-result after Phase B.3 lands.
  This is a mechanical gate, not a judgment call.

### Step 4 — Decide the device-core tech (branch: `v3/core-decision`)

- Docs-only PR. Fill in the `DECISION:` line in §7 of this file.
- The PR description must say why the losing options were rejected. This
  is not ceremony — it stops the next engineer from re-litigating the
  choice in three months.
- Do not start Step 5 before this PR lands.

### Step 5 — Phase B.3 proof-of-concept (branch: `v3/device-core-<tech>`)

- First PR: one end-to-end capability only. Enumerate a connected iPhone
  and return its UDID through the existing agent boundary, with **zero
  code changes above the agent seam**.
- This is the test that the chosen technology can actually talk to the
  device. If it cannot, re-open §7 — do not paper over the gap.
- After the proof-of-concept merges, follow the capability order in §5:
  enumerate → device info → tunnel lifecycle → simulate-location → typed
  diagnostics. Each capability ships as its own PR with a self-check that
  exercises it headlessly.

### Step 6 — Retire the XCTest harness as the primary path

- Once B.3 can inject a location, demote
  `XcodeTestLocationInjectionTransportAdapter` behind a debug flag
  (`V3_DEV_ENABLE_XCTEST_HARNESS=1` in the environment, for example).
- At the end of Phase C, delete `XcodeTestLocationInjectionTransportAdapter`,
  `XcodeLocationHarnessPackage` (including the embedded source strings),
  and the `--v3-self-check-xcode-location-harness` self-check in a single
  commit. The `GeoTeleportLocationHarness/` directory on disk is already
  gone as of the handoff commit; nothing else should reference it.

After Step 6, follow the roadmap. Phase C work is blocked on Phase B and
should not start early — packaging a device core that does not work yet is
wasted signing.

---

## 13. Code Map for Picking Up

Primary files, in the order a new developer should read them:

- `GeoTeleportMac/ContentView.swift` — the UI surface; renders from state.
- `GeoTeleportMac/V3AppModel.swift` — domain state, drives the UI.
- `GeoTeleportMac/V3RuntimeCoordinator.swift` — wires model to backend.
- `GeoTeleportMac/V3BackendModels.swift` — `BackendTrack`, session/blocker
  enums shared across the boundary.
- `GeoTeleportMac/V3DeviceAgentProtocol.swift` — JSON contract (add
  `schemaVersion` here).
- `GeoTeleportMac/V3DeviceAgentClient.swift` — protocol the app calls.
- `GeoTeleportMac/V3ChildProcessDeviceAgentClient.swift` — current transport
  (child-process over stdin/stdout).
- `GeoTeleportMac/V3DeviceAgentEntrypoint.swift` — `--v3-agent` and
  self-check entry points.
- `GeoTeleportMac/V3DeviceAgentService.swift` — this is the file that Phase
  B.3 mostly edits. Contains the current `pymobiledevice3`-backed tunnel
  controller and the `XcodeTestLocationInjectionTransportAdapter`.
- `GeoTeleportMac/V3DeviceAgentModels.swift` — typed agent models
  (availability, readiness gate, tunnel requirement/lifecycle/session/health,
  device-info transport probe, etc.).
- `GeoTeleportMac/V3LegacyCLIBackend.swift`, `V3LegacyDeviceTransport.swift`,
  `V3LegacyLocationTransport.swift` — retained only for the `legacyPreview`
  track. Do not add features here.
- `GeoTeleportMac/V3NoPythonBackendStub.swift` — adapter that translates
  agent responses into backend-track state.
- The XCTest harness is **not** a separate on-disk package anymore. The
  source of the harness (Package manifest, library source, test source) is
  embedded as Swift string literals inside `V3DeviceAgentService.swift`'s
  `XcodeLocationHarnessPackage` enum. At runtime those strings are
  materialized into
  `~/Library/Application Support/com.test.GeoTeleportMac.v3/GeneratedArtifacts/GeoTeleportLocationHarness/`
  and `xcodebuild test` is run against that materialized copy. The on-disk
  `GeoTeleportLocationHarness/` directory at the repo root was removed
  during handoff because it was redundant with the embedded strings and
  the plan explicitly retires this harness by end of Phase C.

Build & verify after any Swift change:

```
xcodebuild -project GeoTeleportMac.xcodeproj \
  -scheme GeoTeleportMac -configuration Debug build
```

Relevant self-checks (run against the built `.app`):

- `--v3-self-check-tunnel-log-parser`
- `--v3-self-check-injection-transport`
- `--v3-self-check-xcode-location-harness` (goes away in Phase C)
- add `--v3-self-check-agent-protocol-version` as part of Phase B.1

---

## 14. Change Log for this Plan

Record material changes here so a new reader can see how the plan evolved
without trawling git history.

- **2026-04-23 — Rewrite.** Replaced the "no-Python foundation" framing with
  a consumer-DMG framing. Demoted the XCTest harness and the
  `pymobiledevice3`-backed tunnel controller from "primary" to "temporary
  CLI bridge." Introduced Phases B.1–B.3, C, D, E, F. Added §7 tech-decision
  rubric. Consolidated prior `.omx/notepad.md` working notes into this file
  and deleted that file so this plan is the single source of truth.
- **2026-04-23 — Handoff commit.** Squashed the accumulated Phase A work
  (18 modified Swift files, 1 deleted file) into a single handoff commit on
  `v3-no-python-foundation` so the next engineer starts from a clean HEAD
  that matches §3's Current State Snapshot. Deleted the redundant
  `GeoTeleportLocationHarness/` directory (source is embedded in
  `V3DeviceAgentService.swift`). Added `.omx/` to `.gitignore`. Added §0
  Handoff Snapshot with day-1 verification checklist and expanded §12
  with per-step branch names and concrete implementation sketches for
  Phase B.1 through Phase B.3.
