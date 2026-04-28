# GeoTeleport Windows Port Plan

This file tracks Phase F implementation work. The macOS V3 baseline is the
reference behavior: one USB-connected iPhone, no Python/Xcode/Homebrew-style
toolchain, bundled native device core, diagnostics export, and user-actionable
failure states.

Current status as of 2026-04-28: the Windows package baseline is working and
has been validated locally. Remaining Windows work is installer selection,
clean-machine validation, and diagnostics hardening.

## Initial Direction

Use the existing Rust `native-device-core` as the shared device layer. It
already builds as a `cdylib` on macOS, which maps to a `.dll` on Windows once
the Windows target and crate dependencies are validated.

UI stack decision: start with a thin native `.NET Windows Forms` host. This is
not the final design ceiling, but it avoids NuGet-heavy WinUI/Tauri setup while
we prove the native-core and USB path. The host lives in
`windows-host/GeoTeleportWindows` and calls `geoteleport_device_core.dll` through
the existing C ABI.

- ✅ Prove `native-device-core` compiles for Windows as a CLI plus DLL.
- ✅ Publish a self-contained Windows host folder.
- ✅ Validate the host package locally on Windows.
- 🟡 Prove USB enumeration and lockdown device-info on a clean Windows machine
  with only Apple Mobile Device Support installed.
- 🟡 Decide whether iOS 17+ RSD can ride the same host USB stack or needs a
  driver assistant path.
- 🟡 Keep the Windows UI thin until the installer and dependency story are
  proven.

## Work Packages

### F1 — Rust Core Windows Build

Status: baseline done.

- Local Windows command:

  ```powershell
  winget install -e --id Rustlang.Rustup
  winget install -e --id NASM.NASM
  winget install -e --id Microsoft.DotNet.SDK.8

  # Reopen PowerShell after installing Rust.
  ./scripts/build_windows_core.ps1 -Release

  # If link.exe or MSVC tools are missing:
  winget install -e --id Microsoft.VisualStudio.2022.BuildTools --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
  ```

- CI entry point: `.github/workflows/native-device-core-windows.yml`.
- Windows CI installs `nasm` because the Rust TLS/native crypto dependency can
  require assembler support while compiling `aws-lc-sys`.
- Expected artifact names:
  - `geoteleport-device-core.exe`
  - `geoteleport_device_core.dll`
- Verify exported C ABI names:
  - `gte_enumerate_ios_devices`
  - `gte_device_info`
  - `gte_set_location`
  - `gte_clear_location`
  - `gte_free_string`
- Current note: Windows build has been validated on a real Windows machine.
  CI can catch compile/package regressions, but hardware behavior still needs
  real Windows + iPhone validation.

### F2 — Host USB Baseline

Status: partially validated; clean-machine dependency story still open.

- Test with Apple Mobile Device Support installed from iTunes / Apple Devices.
- Record whether usbmuxd-compatible access is enough for:
  - USB enumeration
  - Lockdown device-info
  - iOS <= 16 simulate-location
  - iOS 17+ RSD tunnel bootstrap
- If any capability needs lower-level USB access, isolate it behind a Windows
  host adapter before adding UI work.

### F3 — UI Host Decision

Decision: `.NET Windows Forms` thin host for Phase F bring-up.

Implemented host capabilities:

- Enumerate USB iPhone devices through `gte_enumerate_ios_devices`.
- Fetch device info through `gte_device_info`.
- Set / clear location through `gte_set_location` and `gte_clear_location`.
- For iOS 17+, fall back to `geoteleport-device-core.exe ios17-location-daemon`
  when the FFI reports that the daemon path is required.
- Export local diagnostics as a text file.
- Chinese-localized WebView UI with map, presets, status card, and collapsible
  log.
- Package output under `dist/windows/GeoTeleportWindows-win-x64`.

Run/publish command:

```powershell
./scripts/publish_windows_host.ps1
```

Longer-term UI criteria still apply if this graduates to WinUI:

- Native driver/setup UX and installer support.
- Low-friction DLL FFI.
- Stable auto-update / installer story.
- Ability to keep the app compact and operational rather than marketing-style.

### F4 — Installer

Status: not started.

Installer decision is blocked on clean-machine F2:

- If Apple Mobile Device Support is sufficient, ship a normal app installer and
  document that dependency clearly.
- If a custom driver path is required, treat driver setup as its own first-run
  workflow and support artifact category.

Current packaging state: `publish_windows_host.ps1` creates:

```text
dist/windows/GeoTeleportWindows-win-x64/
  GeoTeleportWindows.exe
  geoteleport_device_core.dll
  geoteleport-device-core.exe
  wwwroot/
```

MSI/MSIX/EXE installer selection remains blocked on F2.

### F5 — Windows Diagnostics

Status: basic only.

Current diagnostics export includes host OS basics, selected device UDID, and UI
log text. Still needed:

- Native-core result JSON history.
- Daemon stderr/stdout capture summary.
- Apple Mobile Device Support detection.
- Package version and build timestamp.
- Clear next-action guidance for missing Apple device services.

## Definition of Done

- A clean Windows machine can run GeoTeleport without Python or developer tools.
- The app can enumerate a USB-connected iPhone and show device info.
- iOS <= 16 set/clear works through the shared native core.
- iOS 17+ set/clear works through the bundled daemon helper or returns a typed,
  user-actionable blocker.
- Diagnostics export includes Windows host USB state and native-core errors.
- Installer is selected and produces a user-facing artifact.
