# GeoTeleportMac

GeoTeleportMac is a native macOS SwiftUI app for setting a USB-connected iPhone's simulated GPS location. The current V3 branch is built around a bundled Rust `native-device-core`, so target users do not need Python, Xcode, Homebrew, `pipx`, or `pymobiledevice3`.

## Current State

- Native SwiftUI HUD over a full-window `MKMapView`.
- USB device discovery and device-info flow are routed through the bundled Rust helper / C FFI path.
- iOS 16 and earlier use native lockdown simulate-location.
- iOS 17 and later use the bundled `ios17-location-daemon` path managed by the app process.
- Multi-device selection, diagnostics export, debug log, and opt-in device-core telemetry are wired.
- Distribution is currently unsigned; users must intentionally bypass the macOS first-run warning.

See [docs/v3-no-python-foundation-plan.md](docs/v3-no-python-foundation-plan.md) for the active development handoff and release checklist.

## Build

Use Xcode's standard DerivedData location. Do not pass a project-local `-derivedDataPath`.

```bash
cd native-device-core
cargo build
cd ..

xcodebuild -project GeoTeleportMac.xcodeproj \
  -scheme GeoTeleportMac -configuration Debug build
```

The Xcode build phase also builds and bundles the Rust helper into:

```text
GeoTeleportMacV3.app/Contents/Helpers/geoteleport-device-core
GeoTeleportMacV3.app/Contents/Helpers/libgeoteleport_device_core.dylib
```

## Verify

After building the app:

```bash
APP=$(find ~/Library/Developer/Xcode/DerivedData -name "GeoTeleportMacV3" \
  -path "*/MacOS/GeoTeleportMacV3" | head -1)

"$APP" --v3-self-check-toolchain-probe
"$APP" --v3-self-check-native-device-core-enumeration
"$APP" --v3-self-check-native-device-core-device-info
"$APP" --v3-self-check-agent-protocol-version
"$APP" --v3-self-check-native-device-core-injection
```

Hardware-dependent checks may report fewer cases when no iPhone is attached.

## Package

Create a local unsigned DMG from a Release build:

```bash
./build_dmg.sh
```

## Windows 核心构建

在 Windows 上先安装本地构建依赖：

```powershell
winget install -e --id Rustlang.Rustup
winget install -e --id NASM.NASM
winget install -e --id Microsoft.DotNet.SDK.8
```

安装 Rust 后关闭并重新打开 PowerShell，确保 `cargo` 已进入 `PATH`。然后构建共享 Rust 核心产物：

```powershell
./scripts/build_windows_core.ps1 -Release
```

如果 Rust 构建后续提示缺少 `link.exe` 或 MSVC 工具链，请安装 C++ Build Tools：

```powershell
winget install -e --id Microsoft.VisualStudio.2022.BuildTools --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
```

发布轻量 Windows 主程序，并把原生核心产物复制到同一目录：

```powershell
./scripts/publish_windows_host.ps1
```

Windows 包会输出到仓库根目录下这个简短路径：

```text
dist/windows/GeoTeleportWindows-win-x64/
```

该目录包含 `GeoTeleportWindows.exe`、`geoteleport_device_core.dll`，以及 iOS 17+ daemon 路径需要的 `geoteleport-device-core.exe`。

## Unsigned First Run

For the current unsigned build, macOS will block the first launch. Open it intentionally through System Settings:

1. Try opening `GeoTeleportMacV3.app` once.
2. Open System Settings -> Privacy & Security.
3. In the security warning for GeoTeleportMacV3, choose Open Anyway.
4. Confirm the launch dialog.

This is a temporary distribution choice for this build, not a Mac App Store flow.

## Project Layout

```text
GeoTeleportMac/
  ContentView.swift                 SwiftUI HUD
  NativeMapView.swift               AppKit MKMapView bridge
  GlassTheme.swift                  shared glass styling
  IOKitUSBMonitor.swift             event-driven USB refresh trigger
  V3RuntimeCoordinator.swift        app/backend coordination
  V3DeviceAgentService.swift        native device-agent service and self-checks
  NativeDeviceCoreFFI.swift         Swift wrapper for the Rust C ABI dylib
native-device-core/
  src/core.rs                       shared Rust device-core logic
  src/lib.rs                        C ABI exports
  src/main.rs                       CLI and iOS 17 daemon entry points
docs/
  v3-no-python-foundation-plan.md   active development handoff
  windows-port-plan.md              Phase F Windows port plan
```

## License

MIT (see [LICENSE](LICENSE)).
