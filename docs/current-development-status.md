# GeoTeleport Current Development Status

Last updated: 2026-04-28
Active branch: `v3/windows-host`

This is the current handoff document. The longer historical plan remains in
`docs/v3-no-python-foundation-plan.md`; use this file first for day-to-day
decisions.

## Current Product State

GeoTeleport V3 has two working host builds backed by the shared Rust
`native-device-core`.

### macOS

Status: shippable as an unsigned local DMG.

What works:

- Native SwiftUI map HUD.
- Bundled Rust helper and C ABI dylib inside `GeoTeleportMacV3.app`.
- USB device enumeration and device info through the bundled core.
- iOS 16 and earlier set/clear through lockdown simulate-location.
- iOS 17 and later set/clear through bundled `ios17-location-daemon`.
- Multi-device picker.
- Diagnostics export and opt-in device-core telemetry.
- Local release output is organized under `dist/macos/`.

Build and package:

```bash
./build_dmg.sh
```

Outputs:

```text
dist/macos/GeoTeleportMacV3.app
dist/macos/GeoTeleportMacV3.dmg
```

Known limitations:

- The macOS build is ad-hoc signed and not notarized.
- First launch requires the user to allow the app in System Settings ->
  Privacy & Security.
- No auto-update mechanism exists.

### Windows

Status: functional package validated locally on Windows; installer still not
done.

What works:

- Thin .NET Windows Forms host with WebView UI.
- UI is localized to Chinese.
- Published package is organized under `dist/windows/GeoTeleportWindows-win-x64`.
- NASM discovery covers `LOCALAPPDATA\bin\NASM`.
- Rust core builds as Windows CLI plus DLL.
- Windows host calls the C ABI DLL for enumeration, device info, set, and clear.
- iOS 17+ path falls back to bundled `geoteleport-device-core.exe
  ios17-location-daemon`.
- Windows host package has been tested through `publish_windows_host.ps1`.

Build and package on Windows:

```powershell
.\scripts\publish_windows_host.ps1
```

Output:

```text
dist\windows\GeoTeleportWindows-win-x64\
```

Known limitations:

- No installer yet. Users run the publish folder directly.
- Apple Mobile Device Support dependency needs a clean-machine validation pass.
- CI workflows may build packages, but hardware behavior still requires real
  Windows + iPhone validation.
- Windows diagnostics are basic compared with macOS session diagnostics.

## What Is Left

Highest priority:

1. **Windows installer**
   Decide and implement installer format: MSI, MSIX, or self-extracting EXE.
   The installer must include the Windows host, `geoteleport_device_core.dll`,
   `geoteleport-device-core.exe`, `wwwroot`, and first-run dependency guidance.

2. **Clean Windows validation**
   Test on a machine without Rust, .NET SDK, NASM, Python, Xcode, or developer
   tools. Confirm whether Apple Mobile Device Support alone is enough for:
   USB enumeration, lockdown device info, iOS <= 16 set/clear, and iOS 17+
   daemon set/clear.

3. **macOS signing and notarization**
   Move from ad-hoc unsigned DMG to Developer ID signed and notarized
   distribution if public user distribution is the goal.

4. **Release UX documentation**
   Write user-facing install/run instructions for both platforms. Keep the
   developer docs separate from support docs.

Medium priority:

5. **Windows diagnostics parity**
   Add structured diagnostics export similar to macOS: host OS, package version,
   selected device, native-core result JSON, daemon stderr, and recent UI log.

6. **Versioning**
   Introduce a release version source shared by macOS app metadata, Windows
   package name, diagnostics, and release notes.

7. **Product naming cleanup**
   Decide whether the shipping name remains `GeoTeleportMacV3` or becomes a
   platform-neutral `GeoTeleport`.

Lower priority:

8. **Auto-update**
   Evaluate Sparkle for macOS and an installer/update story for Windows.

9. **Web/mobile remote controller**
   Possible future architecture: browser UI talks to a local desktop agent.
   A pure iOS/web implementation cannot directly modify system-wide iPhone GPS.

## Files To Read First

Core:

- `native-device-core/src/core.rs`
- `native-device-core/src/lib.rs`
- `native-device-core/src/main.rs`

macOS:

- `GeoTeleportMac/ContentView.swift`
- `GeoTeleportMac/V3DeviceAgentService.swift`
- `GeoTeleportMac/NativeDeviceCoreFFI.swift`
- `build_dmg.sh`

Windows:

- `windows-host/GeoTeleportWindows/Program.cs`
- `windows-host/GeoTeleportWindows/wwwroot/index.html`
- `windows-host/GeoTeleportWindows/wwwroot/app.js`
- `windows-host/GeoTeleportWindows/wwwroot/style.css`
- `scripts/build_windows_core.ps1`
- `scripts/publish_windows_host.ps1`

CI:

- `.github/workflows/macos-dmg.yml`
- `.github/workflows/native-device-core-windows.yml`
- `.github/workflows/windows-host.yml`

## Current Review Notes

- Project-local duplicate `GeoTeleportMacV3.app` copies were cleaned up; the
  only project-local release app should be `dist/macos/GeoTeleportMacV3.app`.
- Xcode global DerivedData can still regenerate app copies when building from
  Xcode. Those are cache products, not release artifacts.
- `build_dmg.sh` intentionally uses project-local `build/DerivedData` for
  repeatable scripted packaging, then deletes the intermediate Release app after
  copying the final app to `dist/macos`.
- PowerShell scripts must stay ASCII-only because Windows PowerShell can parse
  UTF-8-without-BOM scripts incorrectly on some machines.
- GitHub Actions artifact upload paths now match `dist/macos` and
  `dist/windows`.
