# GeoTeleport Development Plan

> Single source of truth for the GeoTeleport project. A developer picking up
> this repo should be able to orient from this file alone. When this plan
> changes, change this file; do not fork planning notes into other docs.

---

## 0. Handoff Snapshot (read this first)

**You are the next engineer on this project.**
Last updated: **2026-04-30**. Branch: `v3/device-core-rust-macos`.

### Where we are in 60 seconds

B.1, B.2, and B.3 are complete. The Rust binary (`native-device-core`) handles
USB enumeration, lockdown device info, iOS ≤ 16 simulate-location, and iOS 17+
persistent DVT daemon (`ios17-location-daemon`) managed by
`NativeDeviceCoreIos17LocationController` in the main app process. **Phase B
exit criteria are fully met.**

For iOS 17+ / iOS 26, location simulation depends on the device exposing the
DVT service over RSD. That requires Developer Mode on the iPhone and a developer
image path available to the device. The app now reads `developerModeEnabled`
from native `device-info` / `developer-mode-status` and blocks the injection
transport when it is `false`, instead of waiting for
`ios17-location-daemon` to fail with RSD `ServiceNotFound`.

Phase C code-level work is done:
- Hardened Runtime enabled, entitlements created, Rust binary bundled at
  `Contents/Helpers/`.
- **Multi-device selection UI** — `DevicePickerSheet`, `selectedDeviceUDID`
  (UserDefaults), `GTM_PREFERRED_DEVICE_UDID` env-var bridging.
- **Honest blockers** — migration-era Xcode / `pymobiledevice3` blockers were
  wired, and current runtime readiness centers on the bundled device core.
- **Developer Mode preflight** for iOS 17+ / iOS 26: native device-core queries
  `mobile_image_mounter`, propagates `developerModeEnabled` into the session,
  and blocks native RSD injection until the phone reports Developer Mode enabled.
- **XCTest harness deleted** — `XcodeTestLocationInjectionTransportAdapter`,
  `XcodeLocationHarnessPackage`, and the harness self-check are gone.
- **Legacy backend deleted** — `legacyPreview` track, `V3LegacyCLIBackend`,
  `V3LegacyDeviceTransport`, `V3LegacyLocationTransport`, `V3TunnelLauncher`
  (Terminal AppleScript), tunnel banner, and all compatibility-message branches
  removed. Only `noPythonStub` remains.
- **pymobiledevice3 fallback deleted** — `EndpointBackedInjectionTransportCommandAdapter`,
  `ProductOwnedTunnelStateController`, `V3LegacyCLIPathResolver`, and
  `V3ShellCommandRunner` are gone. Native device-core is the only runtime path.
- **Immersive HUD UI redesign** — full-window map surface with floating glass
  controls and fixed `NativeMapView` center/span refresh behavior.

**macOS validation is complete for the supported preconditions.** iOS 17+ /
iOS 26 users must enable Developer Mode on the phone before location injection
can expose DVT. The primary focus now shifts to **Phase F: Windows Port**.

### Day-1 verification checklist

```bash
# 1. Correct branch
git rev-parse --abbrev-ref HEAD          # expect: v3/device-core-rust-macos

# 2. Rust binary builds
cd native-device-core && cargo build && cd ..

# 3. App builds
xcodebuild -project GeoTeleportMac.xcodeproj \
  -scheme GeoTeleportMac -configuration Debug build

# 4. Non-hardware self-checks all pass (run against the built .app binary)
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "GeoTeleportMacV3" \
  -path "*/MacOS/GeoTeleportMacV3" | head -1)
"$APP" --v3-self-check-toolchain-probe
"$APP" --v3-self-check-native-device-core-enumeration
"$APP" --v3-self-check-native-device-core-device-info
"$APP" --v3-self-check-agent-protocol-version   # 3 cases
"$APP" --v3-self-check-native-device-core-injection
# All must pass. Some case counts vary depending on attached hardware.
```

If any check fails, stop and diagnose before writing new code.

### Your first task (Phase F)

Phase C and Phase D (macOS validation) are complete. The macOS app is fully functional as a DMG package containing a bundled Rust helper.

Your first task is to **begin Phase F planning and implementation for Windows**:
1. **Windows UI Stack:** Decide between WinUI 3 (native) vs Tauri (reusable web UI).
2. **Host USB Setup:** Determine if usbmuxd (iTunes) is sufficient or if WinUSB/libusbK needs to be integrated for RSD communication.
3. **Core Integration:** Prepare `native-device-core` compilation as a DLL to bridge via FFI on Windows.

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

**Current platform.** macOS, distributed as an unsigned `.dmg` / `.app` for
now. Users must intentionally bypass the macOS warning on first launch.

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

1. **The consumer has no Xcode.** Earlier builds used `xcodebuild test`
   against an XCTest harness. That worked on a developer's Mac but failed on
   clean consumer Macs. The harness is now deleted.
2. **The consumer has no `pymobiledevice3`.** Earlier builds used
   `pymobiledevice3 remote tunneld` for iOS 17+ RemoteXPC tunneling. That
   fallback is now deleted.
3. **macOS App Sandbox will not host this workflow.** Arbitrary subprocess
   spawning and raw USB control are incompatible with a sandboxed Mac App Store
   build. Distribution is outside the Mac App Store; the current project choice
   is unsigned distribution with explicit user bypass of the macOS warning.
4. **Windows has neither Python nor Xcode nor `pymobiledevice3`.** Any
   architecture that keeps shelling out to these tools will need to be
   rebuilt for Windows. That argues for a bundled native device core now.

Those runtime gaps are now closed:

- `no-Python *UI*` — achieved.
- `no-Python *runtime*` — achieved; no `pymobiledevice3` fallback remains.
- `no-Xcode *runtime*` — achieved; the XCTest harness is deleted.
- `unsigned DMG` — accepted for this build; users bypass the macOS warning
  intentionally.

Everything below tracks the completed macOS release baseline and Windows planning.

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

### What already works

- SwiftUI `ContentView` renders from typed state and now uses a full-window
  map HUD layout with floating controls.
- `V3RuntimeCoordinator` + typed service protocols sit between the UI and the
  backend (`DeviceMonitoring`, `TunnelManaging`, `LocationInjecting`,
  `DiagnosticsProviding`).
- Only the `noPythonStub` backend track remains; legacyPreview was deleted.
- A child-process agent boundary works end-to-end: the app re-executes its own
  binary with `--v3-agent`, and app↔agent communicates over stdin/stdout with
  a typed JSON protocol (`V3DeviceAgentProtocol`).
- Typed readiness model drives the UI and diagnostics: `DeviceAgentAvailability`,
  `DeviceSessionState`, `ConnectionHealth`, `SessionBlocker`, `nextAction`,
  `DeviceAgentReadinessGate`, refresh intent/scope/focus, typed tunnel
  `requirement/lifecycle/session/health`, `protocolHint`, and native injection
  transport contract.
- Rust `native-device-core` owns USB enumeration, lockdown device info,
  iOS <= 16 simulate-location, and the iOS 17+ DVT daemon.
- Swift prefers the C FFI dylib for short-lived native-core calls; the iOS 17+
  daemon remains a managed long-running helper process.
- Multi-device selection, Developer Mode guidance, diagnostics export, and
  opt-in telemetry are wired.
- Self-check entry points cover toolchain probe machinery, native enumeration,
  native device-info, native injection, and agent protocol versioning.

### What does NOT work for the target DMG user

- Unsigned builds show the standard macOS warning. That is an accepted product
  choice for now; the first-run instructions must tell users how to bypass it.

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
│   - macOS: IOKit / libusb / bundled helper if needed           │
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

### Phase B — Shippable device core ✅ DONE

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
- Earlier Phase B.1 work explicitly marked the `pymobiledevice3 remote tunneld`
  call site as `TEMPORARY_CLI_BRIDGE`. That marker should now be zero-result
  in code because the fallback has been deleted.

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
  that runs `cargo build [--release]`, copies the output, and signs helper
  artifacts when an expanded signing identity is present.
- ✅ `resolveBinaryPath` checks `Contents/Helpers/` first (DMG path), falls
  back to dev-build `#filePath` path.
- ✅ First-run UX: `device-info` failures classified into "iPhone locked" /
  "not trusted / tap Trust" / generic; message shown in status card and guidance.
- ✅ `needsTunnel` no longer blocks `.nativeRsd` / `.nativeLockdown` transports.

### Phase D — Consumer-Mac validation

- **Clean consumer-Mac validation — ✅ DONE.** Validated from the unsigned DMG
  on a clean Mac with no developer toolchain and with both iOS 17+ and iOS <= 16
  device paths. See the 2026-04-28 change-log entry.
- **Sparse but real crash/telemetry path (opt-in) — ✅ DONE.** Scoped to
  device-core failures only; no PII. `V3TelemetryStore` writes sanitized JSONL
  to `Application Support/com.test.GeoTeleportMac.v3/telemetry/`. Opt-in toggle
  in the debug log panel. Events cover: ios17 daemon launch/timeout/output/
  command failures, native lockdown injection failures, and USB enum failures.
  UDIDs, coordinates, and serials are redacted from summaries.
- **Support-artifact export — ✅ DONE.** Export button in debug log panel saves
  a `.txt` file via `NSSavePanel` containing session state dump, debug log,
  and telemetry events.

### Phase E — Cross-platform core extraction ✅ DONE

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

**Xcode:** build phase copies both the binary and dylib to `Contents/Helpers/`.

### Phase F — Windows port

1. **Host USB/Driver Setup.** Research `usbmuxd` (iTunes) sufficiency vs WinUSB/libusbK for RSD.
2. **UI Selection.** WinUI 3 (native) vs Tauri (reusable web UI).
3. **Core Integration.** Compile `native-device-core` as DLL and bridge via FFI.
4. **Daemon.** Port process management logic to Windows.
5. **Installer.** MSIX, MSI, or EXE.

---

## 6. Phase Status at a Glance

| Phase | Scope                                  | Status        |
|-------|----------------------------------------|---------------|
| A     | UI/state/agent boundary                | ✅ DONE       |
| B     | Bundled device core (Rust)             | ✅ DONE       |
| C     | DMG packaging, first-run UX            | ✅ DONE       |
| D     | Consumer-Mac validation                | ✅ DONE       |
| E     | Cross-platform core extraction         | ✅ DONE       |
| F     | Windows port                           | 🟡 IN PROGRESS (Planning) |

A previous revision of this plan marked Phases 1–3 as "complete in practice."
That claim conflated "implemented on a developer machine" with "shippable."
The table above reflects shippability.

---

## 7. Device-Core Technology Decision (Phase B.2)

This is the load-bearing decision of the whole product. It must be made
before Phase B.3 starts.

### Option 1 — Bundle `pymobiledevice3` + embedded Python inside the .app

- **How.** Ship an embedded Python framework and `pymobiledevice3` as a
  bundled helper binary inside `Contents/Helpers`. Treat it as a private
  implementation detail; never let the user see it.
- **Pros.** Fastest route to a shippable DMG. iOS 17+ RSD support is already
  working. Smallest code change from today.
- **Cons.** Adds ~60–100 MB to the DMG. Bundling nested Python frameworks is
  fiddly. Still not cross-platform in any meaningful sense; Windows gets
  nothing reusable. Long-term anchor to Python.

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

- **Channel.** Unsigned DMG / app distribution. Not Mac App Store.
- **First-run warning.** macOS will warn that the app cannot be verified.
  This is accepted for the current build; release notes and onboarding must
  tell users to bypass the warning intentionally.
- **Auto-update.** Deferred to post-Phase-C. Initial releases are manual
  DMG downloads; add a Sparkle-style updater once Phase D validation is
  green on real users.
- **Windows (Phase F).** Installer format is still open (MSI, MSIX, or
  `.exe`). Driver installation — if WinUSB cannot attach without one — gets
  its own first-run step.
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
  - `v3/dmg-packaging` (Phase C)
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
| Users are confused by unsigned macOS warning                    | Document the bypass clearly in release notes and first-run instructions  |
| Users enable Developer Mode incorrectly / don't trust the Mac   | First-run assistant (Phase C) covers these states explicitly             |
| Multi-device connected simultaneously                           | Turn the existing `multipleDevices` blocker into a selection UI in Phase C |
| App/agent protocol drift once agent is a separate bundled helper | `schemaVersion` in Phase B.1; typed failure on mismatch                 |

---

## 11. Definition of Done for V3 (macOS)

All of the following must be true before a V3 DMG is offered to users:

1. A clean Mac with no Xcode, no Python, no `pymobiledevice3`, and no
   Homebrew can run the DMG and successfully set and clear a location on a
   connected iOS 17+ iPhone.
2. The app bundle contains every binary it needs; no runtime subprocess
   targets a user-installed tool.
3. The unsigned first-run flow is documented clearly enough that users can
   bypass the macOS warning without Terminal.
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

## 12. Where to Start (current next commits)

In execution order for whoever picks this up next:

### Step 1 — Windows planning continuation (Phase F)

- Decide the Windows UI stack and installer path.
- Scope the USB driver / usbmuxd dependency story.
- Keep `native-device-core` changes portable and routed through host adapters.

Completed work that should not be reopened without a concrete bug:

- Honest blockers and schema-versioned agent protocol.
- Rust native device core for enumeration, device info, iOS <= 16 location,
  and iOS 17+ daemon location.
- XCTest harness, legacy backend, Terminal/AppleScript launcher, and
  `pymobiledevice3` fallback deletion.
- Diagnostics export, opt-in telemetry, C FFI dylib, and Swift FFI wrapper.

---

## 13. Code Map for Picking Up

Primary files, in the order a new developer should read them:

- `GeoTeleportMac/ContentView.swift` — the HUD UI surface; renders from state.
- `GeoTeleportMac/NativeMapView.swift` — native map implementation used by the
  full-window HUD.
- `GeoTeleportMac/GlassTheme.swift` — shared glass styling for the redesigned UI.
- `GeoTeleportMac/V3AppModel.swift` — domain state, drives the UI.
- `GeoTeleportMac/V3RuntimeCoordinator.swift` — wires model to backend.
- `GeoTeleportMac/V3BackendModels.swift` — `BackendTrack`, session/blocker
  enums shared across the boundary.
- `GeoTeleportMac/V3DeviceAgentProtocol.swift` — schema-versioned JSON contract.
- `GeoTeleportMac/V3DeviceAgentClient.swift` — protocol the app calls.
- `GeoTeleportMac/V3ChildProcessDeviceAgentClient.swift` — current transport
  (child-process over stdin/stdout).
- `GeoTeleportMac/V3DeviceAgentEntrypoint.swift` — `--v3-agent` and
  self-check entry points.
- `GeoTeleportMac/V3DeviceAgentService.swift` — native device-agent service,
  probes, assessments, and self-checks.
- `GeoTeleportMac/V3DeviceAgentModels.swift` — typed agent models
  (availability, readiness gate, tunnel requirement/lifecycle/session/health,
  device-info transport probe, etc.).
- `GeoTeleportMac/V3NoPythonBackendStub.swift` — adapter that translates
  agent responses into backend-track state.
- `GeoTeleportMac/NativeDeviceCoreFFI.swift` — Swift `dlopen` / `dlsym` wrapper
  for the Rust C ABI dylib.
- `native-device-core/src/core.rs` — shared Rust device-core logic.
- `native-device-core/src/lib.rs` — C ABI exports.
- `native-device-core/src/main.rs` — CLI and iOS 17 daemon entry points.

Build & verify after any Swift change:

```
xcodebuild -project GeoTeleportMac.xcodeproj \
  -scheme GeoTeleportMac -configuration Debug build
```

Relevant self-checks (run against the built `.app`):

- `--v3-self-check-toolchain-probe`
- `--v3-self-check-native-device-core-enumeration`
- `--v3-self-check-native-device-core-device-info`
- `--v3-self-check-native-device-core-injection`
- `--v3-self-check-agent-protocol-version`

---

## 14. Change Log for this Plan

Record material changes here so a new reader can see how the plan evolved
without trawling git history.

- **2026-04-28 — Clean-run blocker cleanup and macOS DMG workflow.** Runtime
  availability now blocks only on the bundled native device core; Xcode and
  `pymobiledevice3` are retained only as deprecated compatibility blocker codes
  and are not probed on the consumer path. Removed the remaining Xcode metadata
  fallback from device enrichment. Added `build_dmg.sh` and a `macos-dmg`
  GitHub Actions workflow so the unsigned macOS DMG can be downloaded from
  branch builds. Lowered the macOS deployment target to 14.0 so CI can build
  on standard GitHub macOS runners instead of requiring the local Xcode 26 SDK.

- **2026-04-28 — Phase C/D validation complete (macOS).** Successfully completed clean-Mac validation. Generated `GeoTeleportMacV3.dmg` and tested on a pristine macOS machine with no developer toolchain (no Xcode, Python, Homebrew, or pymobiledevice3). Successfully performed hardware tests for both iOS 17+ and iOS 16- devices, confirming USB enumeration, device info fetching, and location setting/clearing. The macOS product is now shippable as an unsigned app. Phase F (Windows port) is now the primary objective.
- **2026-04-30 — iOS 26 routing hardening.** Fixed the practical iOS 26 location
  path by treating unknown iOS versions as unresolved instead of iOS <= 16.
  When enumeration does not include `ProductVersion`, the app now performs a
  native `device-info <udid>` lookup and routes iOS 17+ / iOS 26 set-clear
  commands through `ios17-location-daemon`. Direct native lockdown injection is
  allowed only after a concrete iOS major version below 17 is known.
- **2026-04-30 — iOS 26 daemon startup hardening.** The iOS 26 path now keeps
  `ios17-location-daemon` stderr and exit status visible in Swift diagnostics
  instead of collapsing early process exit into a generic readiness timeout.
  Rust daemon startup retries the CoreDeviceProxy + software tunnel + RSD +
  DVT LocationSimulation stack three times before failing, and error strings now
  include the underlying `Socket(Os { ... })` detail that `idevice` hides behind
  `device socket io failed`. Hardware validation still requires retrying on a
  connected iOS 26 device; the expected success path is `nativeRsd -> READY ->
  set/clear OK`, and any remaining failure should now name the failing layer.

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
- **2026-04-24 — Phase C started: bundle lookup, first-run UX.**
  (1) Fixed `V3AppModel.needsTunnel` to exempt `.nativeRsd` and `.nativeLockdown`
  from the iOS 17+ tunnel requirement check (matching the existing `.xcodeTestHarness`
  exemption). (2) Updated `NativeDeviceCoreMetadataProbe.resolveBinaryPath` and the
  equivalent helper in `V3DeviceInfoTransportService.swift` to check
  `Bundle.main/Contents/Helpers/geoteleport-device-core` first (shipped DMG
  location), with `Contents/MacOS/` as a fallback, before the developer
  `#filePath` build-tree path. (3) Created `GeoTeleportMac/GeoTeleportMac.entitlements`
  with `com.apple.security.app-sandbox = false` and `get-task-allow = true`
  (debug), plus a release entitlements file without `get-task-allow`. (4) Improved
  first-run UX: `NativeDeviceCoreDeviceInfoTransportService` now classifies
  `device-info` failures into "iPhone is locked", "iPhone not trusted", or
  generic — message surfaces in `readinessSummary` (shown in the status card)
  and `nextAction` (guidance area). Removed stale "Device info transport is not
  implemented yet" message from `makeDeviceAssessment`.
- **2026-04-24 — Phase C: Rust binary bundled.**
   Added `PBXShellScriptBuildPhase` "Build & Bundle Rust Helper" to
   `project.pbxproj` — runs `cargo build` (debug) or `cargo build --release`
   during each Xcode build, copies the binary to
   `$(CONTENTS_FOLDER_PATH)/Helpers/geoteleport-device-core`.
   Added `ENABLE_USER_SCRIPT_SANDBOXING = NO` to allow `cargo` to read
   `Cargo.toml` during the build. Created
   `GeoTeleportMac/GeoTeleportMac.distribution.entitlements` (no `get-task-allow`)
   and wired it to the Release configuration; Debug retains `get-task-allow = true`
   for debugger attachment. Bundle lookup confirmed working: self-check
   `native-device-core-binary-present` reports the `Contents/Helpers/` path.
   All self-check suites passed on both Debug and Release builds. Remaining
   release gate: clean-Mac test.
- **2026-04-25 — Phase C: multi-device selection, honest blockers, Developer Mode UX.**
   (1) **Multi-device selection UI**: `DevicePickerSheet.swift` (new SwiftUI sheet),
   `multipleDevicesBanner` in `ContentView`, `selectedDeviceUDID` in `V3AppModel`
   with UserDefaults persistence (`v3.selectedDeviceUDID`), `GTM_PREFERRED_DEVICE_UDID`
   environment variable passed through `V3ChildProcessDeviceAgentClient` to the agent
   subprocess, `allDevices: [DevicePickerEntry]` collected by `SystemUSBProbe` and
   wired into `DeviceSnapshot.availableDevices`. `.sheet` and `.onChange` wiring in
   `ContentView` auto-presents the picker on multiple-device detection.
   (2) **Honest blockers**: `xcodeToolchainMissing`, `pymobiledevice3Missing`,
   `bundledDeviceCoreMissing` added as migration-era `SessionBlocker` cases and
   `DeviceAgentAssessmentBlockerCode` cases. Current runtime availability only
   blocks on the bundled native device core; no Xcode or `pymobiledevice3` runtime
   probe remains on the consumer path. Self-check `--v3-self-check-toolchain-probe`
   validates native-core probe machinery.
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
    the binary to `Contents/Helpers/`. Build succeeds; all self-check suites
    pass. Updated Phase E status to IN PROGRESS.
- **2026-04-25 — Phase E cleanup: pymobiledevice3 fallback fully deleted.**
   Removed `EndpointBackedInjectionTransportCommandAdapter`,
   `ProductOwnedTunnelStateController`, `LegacyObservedTunnelStateController`,
   `SystemProcessProbe`, `TunnelStateControlling`, `TunnelStateControllerStack`,
   `NullTunnelStateController`, `InjectionTransportCommandInvocation`, and
   `InjectionTransportCommandFailureKind`. Deleted `V3LegacyCLIPathResolver.swift`
   and `V3ShellCommandRunner.swift`. Removed the `pymobiledevice3` probe from
   `ToolchainProbe`; `InjectionTransportServiceStack` now only contains
   `NativeDeviceCoreInjectionTransportAdapter`. No `pymobiledevice3` shell-out
   paths remain. Build succeeds; current non-hardware self-checks pass.
- **2026-04-27 — Immersive HUD UI Redesign.**
   Refactored `ContentView.swift` into a full-screen map layout (Immersive HUD Layout). The map now spans the entire window (`edgesIgnoringSafeArea`), with control panels floating as dark-mode glassmorphic layers in the corners.
   - Top-left: Device state and CLI environment connection.
   - Top-right: Search bar, latitude/longitude input, and a grid of preset cities.
   - Bottom-center: The main execute button and status message card.
   Also patched an issue with `updateNSView` where periodic UI refreshes would cause the `NativeMapView` to snap back to an old center coordinate by introducing a `lastSwiftUICenter` / `lastSwiftUISpan` tracking mechanism in the `Coordinator`.
- **2026-04-27 — Release docs updated for unsigned distribution.**
   Current distribution assumes an unsigned app and explicit user bypass of the
   macOS warning. `README.md` now carries product-facing first-run instructions.
   Clean consumer-Mac validation was the main release gate at this point.
- **2026-04-30 — iOS 26 Developer Mode preflight for native RSD injection.**
   The iOS 26 failure mode was verified on a connected device:
   `developer-mode-status` returned `developerModeEnabled:false`,
   `mounter list` returned no mounted developer image, and
   `ios17-location-daemon` failed because RSD did not advertise
   `com.apple.instruments.dtservicehub` (`ServiceNotFound`). Rust
   `native-device-core` now enables `mobile_image_mounter`, adds
   `developer-mode-status <udid>`, emits `developerModeEnabled` from
   `device-info`, and preflights the daemon before creating CDTunnel/RSD/DVT.
   Swift propagates this into `DeviceSnapshot` and treats iOS 17+ with
   Developer Mode disabled as an injection transport blocker instead of
   "Ready For Injection". Added a self-check case for the disabled state.
