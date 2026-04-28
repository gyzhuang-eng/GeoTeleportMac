param(
    [string]$Runtime = "win-x64",
    [string]$Configuration = "Release",
    [string]$OutputRoot = ""
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$hostProject = Join-Path $repoRoot "windows-host\GeoTeleportWindows\GeoTeleportWindows.csproj"
$coreDir = Join-Path $repoRoot "native-device-core"
$target = "x86_64-pc-windows-msvc"
if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $OutputRoot = Join-Path $repoRoot "dist\windows"
}
$packageName = "GeoTeleportWindows-$Runtime"
$publishDir = Join-Path $OutputRoot $packageName

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw @"
dotnet is required but was not found in PATH.

Install the .NET 8 SDK on Windows:
  winget install -e --id Microsoft.DotNet.SDK.8

Then close and reopen PowerShell, and verify:
  dotnet --info
"@
}

& (Join-Path $repoRoot "scripts\build_windows_core.ps1") -Target $target -Release -QuietArtifacts

Write-Host "=> Publishing GeoTeleport Windows host..."
if (Test-Path -LiteralPath $publishDir) {
    Write-Host "=> Cleaning existing publish path:"
    Write-Host "   $publishDir"
    Remove-Item -LiteralPath $publishDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
dotnet publish $hostProject -c $Configuration -r $Runtime --self-contained true /p:PublishSingleFile=true -o $publishDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish failed with exit code $LASTEXITCODE."
}

$coreDll = Join-Path $coreDir "target\$target\release\geoteleport_device_core.dll"
$coreExe = Join-Path $coreDir "target\$target\release\geoteleport-device-core.exe"

Copy-Item $coreDll $publishDir -Force
Copy-Item $coreExe $publishDir -Force

Write-Host "=> Windows host package ready:"
Write-Host "   $publishDir"
$launchPath = Join-Path $publishDir "GeoTeleportWindows.exe"
Write-Host "=> Launch:"
Write-Host "   $launchPath"
