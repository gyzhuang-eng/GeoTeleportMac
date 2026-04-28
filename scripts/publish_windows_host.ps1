param(
    [string]$Runtime = "win-x64",
    [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$hostProject = Join-Path $repoRoot "windows-host\GeoTeleportWindows\GeoTeleportWindows.csproj"
$coreDir = Join-Path $repoRoot "native-device-core"
$target = "x86_64-pc-windows-msvc"

& (Join-Path $repoRoot "scripts\build_windows_core.ps1") -Target $target -Release

Write-Host "=> Publishing GeoTeleport Windows host..."
dotnet publish $hostProject -c $Configuration -r $Runtime --self-contained true /p:PublishSingleFile=true

$publishDir = Join-Path $repoRoot "windows-host\GeoTeleportWindows\bin\$Configuration\net8.0-windows\$Runtime\publish"
$coreDll = Join-Path $coreDir "target\$target\release\geoteleport_device_core.dll"
$coreExe = Join-Path $coreDir "target\$target\release\geoteleport-device-core.exe"

Copy-Item $coreDll $publishDir -Force
Copy-Item $coreExe $publishDir -Force

Write-Host "=> Windows host package ready:"
Write-Host "   $publishDir"
