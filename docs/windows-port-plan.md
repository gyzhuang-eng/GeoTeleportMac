# GeoTeleport Windows Port Plan

This file tracks Phase F implementation work. The macOS V3 baseline is the
reference behavior: one USB-connected iPhone, no Python/Xcode/Homebrew-style
toolchain, bundled native device core, diagnostics export, and user-actionable
failure states.

## Initial Direction

Use the existing Rust `native-device-core` as the shared device layer. It
already builds as a `cdylib` on macOS, which maps to a `.dll` on Windows once
the Windows target and crate dependencies are validated.

UI stack decision: start with a thin native `.NET Windows Forms` host. This is
not the final design ceiling, but it avoids NuGet-heavy WinUI/Tauri setup while
we prove the native-core and USB path. The host lives in
`windows-host/GeoTeleportWindows` and calls `geoteleport_device_core.dll` through
the existing C ABI.

- Prove `native-device-core` compiles for Windows as a CLI plus DLL.
- Prove USB enumeration and lockdown device-info on a Windows machine with
  Apple Mobile Device Support installed.
- Decide whether iOS 17+ RSD can ride the same host USB stack or needs a driver
  assistant path.
- Keep the Windows UI thin until the USB story is proven.

## Work Packages

### F1 — Rust Core Windows Build

- Local Windows command:

  ```powershell
  ./scripts/build_windows_core.ps1 -Release
  ```

- CI entry point: `.github/workflows/native-device-core-windows.yml`.
- Expected artifact names:
  - `geoteleport-device-core.exe`
  - `geoteleport_device_core.dll`
- Verify exported C ABI names:
  - `gte_enumerate_ios_devices`
  - `gte_device_info`
  - `gte_set_location`
  - `gte_clear_location`
  - `gte_free_string`
- Current local blocker: this macOS machine does not have `rustup`, so Windows
  target installation / cross-build validation must run on Windows or CI.

### F2 — Host USB Baseline

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

Installer decision is blocked on F2:

- If Apple Mobile Device Support is sufficient, ship a normal app installer and
  document that dependency clearly.
- If a custom driver path is required, treat driver setup as its own first-run
  workflow and support artifact category.

Current packaging state: `publish_windows_host.ps1` creates a self-contained
publish directory containing `GeoTeleportWindows.exe`,
`geoteleport_device_core.dll`, and the CLI helper. MSI/MSIX/EXE installer
selection remains blocked on F2.

## Definition of Done

- A clean Windows machine can run GeoTeleport without Python or developer tools.
- The app can enumerate a USB-connected iPhone and show device info.
- iOS <= 16 set/clear works through the shared native core.
- iOS 17+ set/clear works through the bundled daemon helper or returns a typed,
  user-actionable blocker.
- Diagnostics export includes Windows host USB state and native-core errors.
