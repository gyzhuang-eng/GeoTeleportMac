# GeoTeleport Development Plan

> Single source of truth for the GeoTeleport project. A developer picking up
> this repo should be able to orient from this file alone. When this plan
> changes, change this file; do not fork planning notes into other docs.

---

## 0. Handoff Snapshot (read this first)

**You are the next engineer on this project.**
Last updated: **2026-04-25**. Branch: `v3/device-core-rust`.

### Where we are in 60 seconds

B.1, B.2, and B.3 are complete. The Rust binary (`native-device-core`) handles
USB enumeration, lockdown device info, iOS ≤ 16 simulate-location, and iOS 17+
persistent DVT daemon (`ios17-location-daemon`) managed by
`NativeDeviceCoreIos17LocationController` in the main app process. **Phase B
exit criteria are fully met.**

Phase C code-level work is done:
- Hardened Runtime enabled, entitlements created, Rust binary bundled at
  `Contents/Helpers/`.
- **Multi-device selection UI** — `DevicePickerSheet`, `selectedDeviceUDID`
  (UserDefaults), `GTM_PREFERRED_DEVICE_UDID` env-var bridging.
- **Honest blockers** — `xcodeToolchainMissing`, `pymobiledevice3Missing`,
  `bundledDeviceCoreMissing` fully wired.
- **Developer Mode guidance** for iOS 16+ in `readinessSummary`.
- **XCTest harness deleted** — `XcodeTestLocationInjectionTransportAdapter`,
  `XcodeLocationHarnessPackage`, and the harness self-check are gone.
- **Legacy backend deleted** — `legacyPreview` track, `V3LegacyCLIBackend`,
  `V3LegacyDeviceTransport`, `V3LegacyLocationTransport`, `V3TunnelLauncher`
  (Terminal AppleScript), tunnel banner, and all compatibility-message branches
  removed. Only `noPythonStub` remains.

**Remaining Phase C work:**
- Obtain a Developer ID Application certificate and sign the app + helper binary.
- Notarize and staple the DMG.
- Test on a clean macOS install (no Xcode, no Python, no pymobiledevice3).

### Day-1 verification checklist

```bash
# 1. Correct branch
git rev-parse --abbrev-ref HEAD          # expect: v3/device-core-rust

# 2. Rust binary builds
cd native-device-core && cargo build && cd ..

# 3. App builds
xcodebuild -project GeoTeleportMac.xcodeproj \
  -scheme GeoTeleportMac -configuration Debug build

# 4. Non-hardware self-checks all pass (run against the built .app binary)
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "GeoTeleportMacV3" \
  -path "*/MacOS/GeoTeleportMacV3" | head -1)
"$APP" --v3-self-check-toolchain-probe         # 4 cases
"$APP" --v3-self-check-tunnel-log-parser        # 4 cases
"$APP" --v3-self-check-injection-transport      # 8 cases
"$APP" --v3-self-check-agent-protocol-version   # 3 cases
"$APP" --v3-self-check-native-device-core-injection  # 6 cases
# Total: 25 cases, all must pass
```

If any check fails, stop and diagnose before writing new code.

### Your first task (Phase C / D continuation)

Code-level Phase C and most of Phase D are complete. The app has:
- Single noPython backend, multi-device selection, honest blockers
- Diagnostics export via NSSavePanel (session state + debug log + telemetry)
- Opt-in telemetry path for device-core failures (no PII)
- All 25 non-hardware self-check cases pass

Remaining work before ship:
1. **Developer ID code signing** (optional — user can run unsigned with Gatekeeper bypass).
2. **Test on a clean macOS install.** A VM with no Xcode, no Python, no `pymobiledevice3`.
3. **Delete the pymobiledevice3 fallback.** `EndpointBackedInjectionTransportCommandAdapter`
   and `ProductOwnedTunnelStateController` still use `V3LegacyCLIPathResolver`. These
   are dead for nativeRsd/nativeLockdown but remain as a compatibility fallback.
   Once native paths are proven stable on clean macOS, remove them.

### What is NOT your job right now

- Do not touch `main`.
- Do not rewrite or "clean up" Phase A/B code that already works.
- Capability 5 (typed diagnostics from Rust) is a nice-to-have, not blocking.

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

**Active branch:** `v3/device-core-rust`
**App identity (isolated from `main`):**
- Product name: `GeoTeleportMacV3`
- Bundle id: `com.test.GeoTeleportMac.v3`
- Defaults keys namespaced with `v3.`

### Build output locations

There is exactly **one** place build products live. All builds — whether triggered
from the Xcode IDE (Cmd+B) or from `xcodebuild` on the command line — go to
Xcode's standard DerivedData folder:

```
~/Library/Developer/Xcode/DerivedData/GeoTeleportMac-<hash>/Build/Products/
  Debug/GeoTeleportMacV3.app      ← default dev build (Cmd+B, xcodebuild Debug)
  Release/GeoTeleportMacV3.app    ← release build (Product → Archive, or xcodebuild Release)
```

The `<hash>` suffix is generated by Xcode and stays stable as long as the
project is open from the same path.

**Never** pass `-derivedDataPath build/DerivedData` (or any project-local path)
to `xcodebuild`. Doing so creates a second stale build tree inside the repo
directory that is gitignored but wastes disk space and causes confusion.
The self-check commands in §0 already use the correct path via `find ~/Library/Developer/Xcode/DerivedData`.

To find the Debug binary quickly:
```bash
find ~/Library/Developer/Xcode/DerivedData -name "GeoTeleportMacV3" \
  -path "*/MacOS/GeoTeleportMacV3" | head -1
```

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

**Infrastructure complete (2026-04-24):**
- ✅ Hardened Runtime enabled (`ENABLE_HARDENED_RUNTIME = YES`).
- ✅ `GeoTeleportMac.entitlements` (debug) and
  `GeoTeleportMac.distribution.entitlements` (release, no `get-task-allow`) created.
- ✅ Rust binary bundled at `Contents/Helpers/` via `PBXShellScriptBuildPhase`
  that runs `cargo build [--release]` and copies + signs the output.
- ✅ `resolveBinaryPath` checks `Contents/Helpers/` first (DMG path), falls
  back to dev-build `#filePath` path.
- ✅ First-run UX: `device-info` failures classified into "iPhone locked" /
  "not trusted / tap Trust" / generic; message shown in status card and guidance.
- ✅ `needsTunnel` no longer blocks `.nativeRsd` / `.nativeLockdown` transports.

**Remaining:**
- Developer ID signing for every binary the `.app` ships.
- Notarization + stapling for the DMG (`notarytool submit`).
- Test on a clean macOS install (no Xcode, no Python, no `pymobiledevice3`).
- Multi-device selection UI (the `multipleDevices` blocker currently dead-ends).
- Explain "enable Developer Mode on your iPhone" for iOS 16+ in the UI.
- Drop the remaining Terminal / AppleScript code paths (guarded by
  `legacyPreview` track, not user-reachable on `noPythonStub`).

### Phase D — Consumer-Mac validation

- Clean-install tests on at least two macOS versions, two iPhone models, and
  two iOS major versions (including one iOS 17+). *(blocked by signing)*
- **Sparse but real crash/telemetry path (opt-in) — ✅ DONE.** Scoped to
  device-core failures only; no PII. `V3TelemetryStore` writes sanitized JSONL
  to `Application Support/com.test.GeoTeleportMac.v3/telemetry/`. Opt-in toggle
  in the debug log panel. Events cover: ios17 daemon launch/timeout/output/
  command failures, native lockdown injection failures, and USB enum failures.
  UDIDs, coordinates, and serials are redacted from summaries.
- **Support-artifact export — ✅ DONE.** Export button in debug log panel saves
  a `.txt` file via `NSSavePanel` containing session state dump, debug log,
  and telemetry events.

### Phase E — Cross-platform core extraction 🟡 IN PROGRESS

**Rust library:** `native-device-core` now produces both a CLI binary and a C FFI
dynamic library (`libgeoteleport_device_core.dylib`). Shared logic lives in
`src/core.rs`; FFI exports in `src/lib.rs`; CLI shim in `src/main.rs`.

**C FFI surface** (5 exports):
- `gte_enumerate_ios_devices()` → JSON
- `gte_device_info(udid)` → JSON
- `gte_set_location(udid, lat, lon)` → JSON
- `gte_clear_location(udid)` → JSON
- `gte_free_string(ptr)` → void

**Swift FFI wrapper** (`NativeDeviceCoreFFI.swift`): Uses `dlopen`/`dlsym` to
load the dylib at runtime. Throwing API: `enumerateDevices()`, `deviceInfo(udid:)`,
`setLocation(udid:lat:lon:)`, `clearLocation(udid:)`. Dylib resolution mirrors
the binary path lookup: `Contents/Helpers/` first, then `Contents/MacOS/`,
then the developer build tree.

**Process replacement:** `NativeDeviceCoreMetadataProbe.fetchAttachedMobileDevices()`,
`NativeDeviceCoreInjectionTransportAdapter.setLocation()`/`.clearLocation()`,
and `NativeDeviceCoreDeviceInfoTransportService.probeTransport()` now prefer FFI
when the dylib is available, falling back to Process-based shell-out for
development without the FFI dylib. The `ios17-location-daemon` continues to
use Process (inherently long-running, needs stdin/stdout pipes).

**Xcode:** build phase copies both the binary and dylib to `Contents/Helpers/`
and signs them with Hardened Runtime when code signing is active.

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
| B.1   | Honest blockers, protocol versioning   | ✅ DONE       |
| B.2   | Device-core tech decision              | ✅ DONE (Rust, §7) |
| B.3   | Bundled device core implementation     | ✅ DONE (Phase B exit criteria met) |
| C     | DMG signing, notarization, first-run   | 🟡 IN PROGRESS |
| D     | Consumer-Mac validation                | 🟡 IN PROGRESS |
| E     | Cross-platform core extraction         | 🟡 IN PROGRESS |
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

**DECISION:** `2026-04-23` — pick **Option 3 (Rust device stack)** for B.3.
Reject Option 1 because shipping an embedded Python helper would keep the
consumer runtime anchored to the same class of bridge we are trying to delete.
Reject Option 2 because iOS 17+ RSD/tunneld coverage is still too fork-heavy.
Reject Option 4 because greenfield Swift/C++ RemoteXPC is too slow for this
phase. Short-term POC scope stays narrow: prove UDID enumeration through the
existing agent seam first, then expand capability-by-capability.

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

### Step 5 — Phase B.3 proof-of-concept (branch: `v3/device-core-rust`) 🔵 IN PROGRESS

Capability order (each ships with a headless self-check):

1. **USB enumeration** ✅ DONE — `native-device-core enumerate-ios-devices` walks
   usbmuxd, returns UDID array, wired behind `NativeDeviceCoreMetadataProbe`.
   Self-check: `--v3-self-check-native-device-core-enumeration`.

2. **Lockdown device info** ✅ DONE — `native-device-core device-info <udid>` opens
   lockdown on the specified device (port 62078 via usbmuxd) and returns
   `DeviceName`, `ProductVersion`, `DeviceClass`, `ProductType` as JSON.
   `NativeDeviceCoreDeviceInfoTransportService` (in `V3DeviceInfoTransportService.swift`)
   is now the first slot in `DeviceInfoTransportServiceStack`; the `udid` field
   has been added to `DeviceAgentUSBIdentityProbe` and is threaded in from
   `SystemUSBProbe.deviceIdentifier`. This replaces the Xcode/xcdevice dependency
   for device metadata on developer machines.
   Self-check: `--v3-self-check-native-device-core-device-info`.

3. **RemoteXPC / RSD tunnel lifecycle** ✅ DONE (Rust + Swift) —
   `native-device-core ios17-location-daemon <udid>` establishes CDTunnel via
   `CoreDeviceProxy::connect`, creates an in-process jktcp TCP stack
   (`create_software_tunnel` → `to_async_handle`), connects to the device's RSD
   port, performs `RsdHandshake`, connects to `com.apple.instruments.dtservicehub`
   via `RsdHandshake::connect::<RemoteServerClient>`, opens a
   `LocationSimulationClient` DVT channel, and loops reading `set <lat> <lon>` /
   `clear` commands from stdin, writing `READY` / `OK` / `ERROR: …` responses to
   stdout. Location stays simulated while stdin is open.
   Added features `dvt` and `io-std` to `Cargo.toml`. New enum cases `nativeRsd`
   in `DeviceAgentInjectionTransportState` and
   `DeviceAgentInjectionTransportContractPhase`. For iOS 17+ devices,
   `NativeDeviceCoreInjectionTransportAdapter.probeTransport` returns `.nativeRsd`.
   **Swift daemon lifecycle** — `NativeDeviceCoreIos17LocationController` (final
   class, owned by `NoPythonBackendStub` via `Ios17BackendState` box) manages the
   persistent `ios17-location-daemon` process. Dedicated reader thread consumes
   stdout line-by-line using blocking `availableData`; commands are sent via stdin
   with `DispatchSemaphore`-guarded line reads and configurable timeouts (15 s
   startup, 10 s per command). Session is keyed by UDID and auto-restarted on UDID
   change or process death. `NoPythonBackendStub.setLocation`/`.clearLocation`
   route iOS 17+ directly to the controller before calling the single-shot agent.
   Device state (UDID + iOS major) is cached in `Ios17BackendState` on every
   `fetchConnectedDevice`/`deviceProbe` call; `NSLock` guards concurrent access
   from background probe and teleport queues.

4. **simulate-location set / clear** ✅ DONE (iOS ≤ 16) — `native-device-core
   set-location <udid> <lat> <lon>` and `clear-location <udid>` subcommands
   added. Uses `LocationSimulationService::connect(&provider)` via
   `UsbmuxdProvider` (reads pairing file from usbmuxd, starts lockdown TLS
   session, opens `com.apple.dt.simulatelocation`). iOS 17+ exits code 3
   (TEMPORARY_LIMITATION). Swift: `NativeDeviceCoreInjectionTransportAdapter`
   prepended to `InjectionTransportServiceStack`; returns `.nativeLockdown`
   state for iOS ≤ 16 + UDID + binary present, `.unavailable` for iOS 17+
   (falls through to XcodeTestHarness). New enum cases `nativeLockdown` in
   `DeviceAgentInjectionTransportState` and
   `DeviceAgentInjectionTransportContractPhase`. Exit code 3 from binary maps
   to `transportUnimplemented` failure code in Swift.
   Self-check: `--v3-self-check-native-device-core-injection` (6 cases after
   B.3 tunnel bypass landed).
   Step 6 can now begin.

5. **Typed diagnostics** ⬜ TODO — structured error reporting from the Rust layer
   into the Swift typed model. Nice-to-have; not blocking Phase B exit criteria.

6. **Tunnel bypass for nativeRsd / nativeLockdown** ✅ DONE — `buildTunnelAssessment`
   now short-circuits to `readinessGate: .ready` / `tunnelRequirement: .notRequired`
   for `.nativeRsd` transport, mirroring the existing `.xcodeTestHarness` bypass.
   `ios17-location-daemon` manages CDTunnel + RSD internally; no external
   `pymobiledevice3 remote tunneld` process is needed. Added `NullTunnelStateController`
   stub and self-check case `ios17-nativeRsd-tunnel-bypasses-external-tunneld`
   (gate=ready, req=notRequired, blockers=[]). The `TEMPORARY_CLI_BRIDGE` code
   path in `ProductOwnedTunnelStateController` is now dead for all nativeRsd and
   nativeLockdown sessions. **Phase B exit criteria are met.**

### Step 6 — Retire the XCTest harness as the primary path ✅ DONE

`XcodeTestLocationInjectionTransportAdapter` is now demoted behind
`V3_DEV_ENABLE_XCTEST_HARNESS=1`. `InjectionTransportServiceStack.defaultServices()`
checks `ProcessInfo.processInfo.environment["V3_DEV_ENABLE_XCTEST_HARNESS"]` at
runtime; absent the flag, only `NativeDeviceCoreInjectionTransportAdapter` and
`EndpointBackedInjectionTransportCommandAdapter` are included.

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
- **2026-04-24 — B.3 capability 2: lockdown device info.** Added
  `device-info <udid>` subcommand to `native-device-core` (Rust). Queries
  `DeviceName`, `ProductVersion`, `DeviceClass`, `ProductType` via lockdown
  port 62078 over usbmuxd (no pairing file required for these values). Added
  `NativeDeviceCoreDeviceInfoTransportService` as the primary slot in
  `DeviceInfoTransportServiceStack`; added `udid` field to
  `DeviceAgentUSBIdentityProbe` threaded from `SystemUSBProbe.deviceIdentifier`.
  New self-check: `--v3-self-check-native-device-core-device-info`. This
  eliminates the Xcode/xcdevice dependency for device metadata on developer
  machines and on the eventual consumer DMG. Updated §6 status and §12 Step 5
  with capability checklist.
- **2026-04-24 — B.3 capability 4: simulate-location set/clear (iOS ≤ 16).**
  Added `set-location <udid> <lat> <lon>` and `clear-location <udid>` Rust
  subcommands using `LocationSimulationService::connect` via `UsbmuxdProvider`
  (reads pairing file, TLS lockdown session, `com.apple.dt.simulatelocation`).
  Added `pair` and `rustls` features to `native-device-core/Cargo.toml`.
  iOS 17+ exits code 3 (TEMPORARY_LIMITATION). Added
  `NativeDeviceCoreInjectionTransportAdapter` as the first service in
  `InjectionTransportServiceStack`; returns `.nativeLockdown` for iOS ≤ 16
  devices, `.unavailable` for iOS 17+ (falls through to XcodeTestHarness).
  New enum cases `nativeLockdown` in `DeviceAgentInjectionTransportState` and
  `DeviceAgentInjectionTransportContractPhase`. Binary exit code 3 maps to
  `transportUnimplemented` in Swift. New self-check:
  `--v3-self-check-native-device-core-injection` (5 cases, all pass).
- **2026-04-24 — B.3 capability 3: ios17-location-daemon end-to-end complete.**
  Rust: `ios17-location-daemon <udid>` subcommand — CDTunnel + jktcp + RSD
  handshake + DVT `LocationSimulationClient`, stdin/stdout command loop, `READY`
  signal. Swift: `NativeDeviceCoreIos17LocationController` (final class) owns
  and restarts the daemon process; `Ios17BackendState` box (NSLock-guarded) holds
  UDID + major version across calls; `NoPythonBackendStub.setLocation` /
  `.clearLocation` route iOS 17+ directly to the controller. iOS 17+ probe
  confidence upgraded to "high". All `PHASE_B3_TODO` markers removed. All 5
  non-hardware self-check suites (24 cases) pass.
- **2026-04-24 — Handoff snapshot updated (§0).** Rewrote §0 to reflect
  current state: B.1/B.2/B.3-caps-1–4 complete; single remaining Phase B
  blocker is the `TEMPORARY_CLI_BRIDGE` (`pymobiledevice3 remote tunneld`) at
  `V3DeviceAgentService.swift` ~line 3285. Day-1 checklist updated with current
  branch name, self-check commands, and explicit "your first task" pointer.
- **2026-04-24 — B.3 capability 6: nativeRsd tunnel bypass — Phase B complete.**
  `DeviceAgentAssessmentFactory.makeTunnelAssessment` now short-circuits to
  `readinessGate: .ready` / `tunnelRequirementResult.state: .notRequired` when
  the injection transport is `.nativeRsd`, exactly mirroring the existing
  `.xcodeTestHarness` bypass. `ios17-location-daemon` owns CDTunnel + jktcp +
  RSD internally; no external `pymobiledevice3 remote tunneld` process is
  needed or consulted for iOS 17+ sessions. Added `NullTunnelStateController`
  (self-check stub) and new case `ios17-nativeRsd-tunnel-bypasses-external-tunneld`
  to `--v3-self-check-native-device-core-injection` (now 6 cases, all pass).
  `TEMPORARY_CLI_BRIDGE` comment updated to note the code path is dead for
  nativeRsd/nativeLockdown. Phase B status updated to ✅ DONE in §6.
- **2026-04-24 — Phase C started: Hardened Runtime, bundle lookup, first-run UX.**
  (1) Fixed `V3AppModel.needsTunnel` to exempt `.nativeRsd` and `.nativeLockdown`
  from the iOS 17+ tunnel requirement check (matching the existing `.xcodeTestHarness`
  exemption). (2) Updated `NativeDeviceCoreMetadataProbe.resolveBinaryPath` and the
  equivalent helper in `V3DeviceInfoTransportService.swift` to check
  `Bundle.main/Contents/Helpers/geoteleport-device-core` first (shipped DMG
  location), with `Contents/MacOS/` as a fallback, before the developer
  `#filePath` build-tree path. (3) Created `GeoTeleportMac/GeoTeleportMac.entitlements`
  with `com.apple.security.app-sandbox = false` and `get-task-allow = true`
  (debug). Set `ENABLE_HARDENED_RUNTIME = YES` and `CODE_SIGN_ENTITLEMENTS` in
  both Debug and Release configurations in `project.pbxproj`. (4) Improved
  first-run UX: `NativeDeviceCoreDeviceInfoTransportService` now classifies
  `device-info` failures into "iPhone is locked", "iPhone not trusted", or
  generic — message surfaces in `readinessSummary` (shown in the status card)
  and `nextAction` (guidance area). Removed stale "Device info transport is not
  implemented yet" message from `makeDeviceAssessment`.
- **2026-04-24 — Phase C: Rust binary bundled, signing infrastructure complete.**
   Added `PBXShellScriptBuildPhase` "Build & Bundle Rust Helper" to
   `project.pbxproj` — runs `cargo build` (debug) or `cargo build --release`
   during each Xcode build, copies the binary to
   `$(CONTENTS_FOLDER_PATH)/Helpers/geoteleport-device-core`, and signs it with
   `$EXPANDED_CODE_SIGN_IDENTITY --options runtime` when code signing is active.
   Added `ENABLE_USER_SCRIPT_SANDBOXING = NO` to allow `cargo` to read
   `Cargo.toml` during the build. Created
   `GeoTeleportMac/GeoTeleportMac.distribution.entitlements` (no `get-task-allow`)
   and wired it to the Release configuration; Debug retains `get-task-allow = true`
   for debugger attachment. Bundle lookup confirmed working: self-check
   `native-device-core-binary-present` reports the `Contents/Helpers/` path.
   All 25 non-hardware self-check cases pass (6+4+8+3+4) on both Debug and
   Release builds. Remaining Phase C gate: Developer ID signing + notarization +
   clean-Mac test.
- **2026-04-25 — Phase C: multi-device selection, honest blockers, Developer Mode UX.**
   (1) **Multi-device selection UI**: `DevicePickerSheet.swift` (new SwiftUI sheet),
   `multipleDevicesBanner` in `ContentView`, `selectedDeviceUDID` in `V3AppModel`
   with UserDefaults persistence (`v3.selectedDeviceUDID`), `GTM_PREFERRED_DEVICE_UDID`
   environment variable passed through `V3ChildProcessDeviceAgentClient` to the agent
   subprocess, `allDevices: [DevicePickerEntry]` collected by `SystemUSBProbe` and
   wired into `DeviceSnapshot.availableDevices`. `.sheet` and `.onChange` wiring in
   `ContentView` auto-presents the picker on multiple-device detection.
   (2) **Honest blockers**: `xcodeToolchainMissing`, `pymobiledevice3Missing`,
   `bundledDeviceCoreMissing` added as `SessionBlocker` cases and `DeviceAgentAssessmentBlockerCode`
   cases. `ToolchainProbe` (Rust struct with `run()`) probes `xcode-select`,
   `xcodebuild`, `pymobiledevice3`, and native-device-core; blockers map to
   `backendUnavailable` / `offline` states and surface user-facing messages via
   `V3AppModel.nextAction`. Self-check `--v3-self-check-toolchain-probe` validates
   probe machinery (4 cases).
   (3) **Developer Mode UX**: `readinessSummary` in `makeDeviceAssessment` now
   appends "Ensure Developer Mode is enabled on your iPhone (Settings → Privacy
   & Security → Developer Mode)." for iOS 16+ devices with resolved metadata.
   All 25 non-hardware self-check cases pass. Updated §0 Handoff Snapshot.
- **2026-04-25 — Phase C cleanup: XCTest harness and legacy backend deleted.**
   **XCTest harness** (`XcodeTestLocationInjectionTransportAdapter`,
   `XcodeLocationHarnessPackage`, `XcodeHarnessBuildSelfCheckResult`,
   `runXcodeLocationHarnessSelfCheckReport`, `--v3-self-check-xcode-location-harness`,
   `V3_DEV_ENABLE_XCTEST_HARNESS` guard) fully removed from `V3DeviceAgentService.swift`
   and `V3DeviceAgentEntrypoint.swift` (680 lines deleted).
   **Legacy backend** (`V3LegacyCLIBackend.swift`, `V3LegacyDeviceTransport.swift`,
   `V3LegacyLocationTransport.swift`, `V3LegacyDiagnostics.swift`,
   `V3TunnelLauncher.swift`) deleted. `BackendTrack.legacyPreview` enum case
   removed; `V3BackendProvider` simplified to single `noPythonStub` path.
   `V3RuntimeCoordinator` — removed `resolvedCLIPath` field and
   `LegacyCLIBackend` cast. `V3AppModel` — removed `resolvedCLIPath` property
   and all `.legacyPreview` default parameter values. `ContentView` — removed
   `tunnelLauncher`, `tunneldBanner`, `launchTunneldInTerminal`,
   `showsLegacyTunnelBanner`, `tunneldCommand`, `detectedCliPath`,
   `tunneldHintDismissed`, and all legacyPreview guard branches.
   `V3LegacyCLIPathResolver` retained (used by `EndpointBackedInjectionTransportCommandAdapter`
   and `ProductOwnedTunnelStateController` for the pymobiledevice3 fallback path).
   Build succeeds; all 25 non-hardware self-check cases pass.
- **2026-04-25 — Phase D: diagnostics export.** "Export" button added to the debug
   log panel. Uses `NSSavePanel` to let users save a `GeoTeleport_Diagnostics_*.txt`
   file containing: host/OS info, full `V3SessionDiagnostics` session state dump
   (backend track, session state, health, readiness gate, all three assessment
   layers with blocker codes, tunnel state, injection transport, last location
   command record), and the complete debug log. No Terminal required.
- **2026-04-25 — Phase D: telemetry path (opt-in).** `V3TelemetryStore` (new file)
   writes sanitized JSONL entries to
   `~/Library/Application Support/com.test.GeoTeleportMac.v3/telemetry/device_core_events.jsonl`
   when the user opts in. PII redaction strips UDIDs (40-hex), coordinates
   (decimal patterns), and serial suffixes from summaries. Opt-in checkbox in the
   debug log panel with event count display and clear button. Telemetry wired into
   7 failure paths: `NativeDeviceCoreIos17LocationController` (binary missing,
   launch failure, daemon timeout, unexpected startup output, no response, command
   failure) and `nativeDeviceCoreRunForInjection` (exit code ≠ 0, process launch
   error). Max 500 entries / 5 MB file with automatic oldest-entry rotation.
   Telemetry content included in diagnostics export. Updated §0 Handoff Snapshot
   and Phase D status to IN PROGRESS.
- **2026-04-25 — Phase E: Rust C FFI library + Swift FFI wrapper.**
   (1) **Rust:** Added `[lib]` to `Cargo.toml` (`crate-type = ["cdylib", "staticlib"]`).
   Extracted shared core logic into `src/core.rs` (`enumerate_ios_devices_core()`,
   `device_info_core()`, `set_location_core()`, `clear_location_core()`, helpers).
   Created `src/lib.rs` with 5 C FFI exports (`gte_enumerate_ios_devices`,
   `gte_device_info`, `gte_set_location`, `gte_clear_location`, `gte_free_string`)
   using `#[no_mangle] pub extern "C"`. Refactored `src/main.rs` to use `mod core`
   directly (same-package library linking avoids crate name resolution issues).
   Both binary and dylib compile cleanly.
   (2) **Swift:** Created `NativeDeviceCoreFFI.swift` — uses `dlopen`/`dlsym` to
   load `libgeoteleport_device_core.dylib` at runtime. Throwing API wraps each
   FFI call with proper string cleanup. Dylib path resolution mirrors binary path
   lookup (`Contents/Helpers/` → `Contents/MacOS/` → dev tree). PII-safe error
   reporting via `NativeDeviceCoreFFIError` struct.
   (3) **Wiring:** `NativeDeviceCoreMetadataProbe.fetchAttachedMobileDevices()`,
   `NativeDeviceCoreInjectionTransportAdapter.setLocation()`/`.clearLocation()`,
   and `NativeDeviceCoreDeviceInfoTransportService.probeTransport()` now prefer FFI
   when dylib is available (`NativeDeviceCoreFFI.isAvailable`), falling back to
   `Process`-based shell-out. `NativeDeviceCoreIos17LocationController` continues
   using Process (long-running daemon).
   (4) **Xcode:** Build phase copies `libgeoteleport_device_core.dylib` alongside
    the binary to `Contents/Helpers/` and signs both. Build succeeds; all 25
    self-check cases pass. Updated Phase E status to IN PROGRESS.
- **2026-04-25 — Phase E cleanup: pymobiledevice3 fallback fully deleted.**
    Removed ~2200 lines across 8 files: `EndpointBackedInjectionTransportCommandAdapter`,
    `ProductOwnedTunnelStateController`, `LegacyObservedTunnelStateController`,
    `SystemProcessProbe`, `TunnelStateControlling` protocol, `TunnelStateControllerStack`,
    `NullTunnelStateController`, `InjectionTransportCommandInvocation`,
    `InjectionTransportCommandFailureKind`, two self-check reports. Deleted files:
    `V3LegacyCLIPathResolver.swift`, `V3ShellCommandRunner.swift`. Removed two
    self-check entrypoints. Cleaned `DeviceAgentInjectionTransportState` (dropped
    `.endpointBackedStub`/`.endpointBackedCommand`). Removed `pymobiledevice3`
    probe from `ToolchainProbe`. `InjectionTransportServiceStack` now only contains
    `NativeDeviceCoreInjectionTransportAdapter`. Simplified `makeTunnelAssessment`
    to nativeRsd-only. No pymobiledevice3 shell-out paths remain. Build succeeds;
    all 13 self-check cases pass (4+3+6).

