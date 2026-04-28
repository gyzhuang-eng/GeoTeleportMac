param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [switch]$Release
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreDir = Join-Path $repoRoot "native-device-core"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw @"
cargo is required but was not found in PATH.

Install Rust stable on Windows:
  winget install -e --id Rustlang.Rustup

Then close and reopen PowerShell, and verify:
  cargo --version
  rustup target add $Target

If a later build error mentions link.exe or MSVC tools, install C++ Build Tools:
  winget install -e --id Microsoft.VisualStudio.2022.BuildTools --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
"@
}

if ($Target -like "*windows*" -and -not (Get-Command nasm -ErrorAction SilentlyContinue)) {
    throw @"
nasm is required for the Windows native core build but was not found in PATH.

Install NASM on Windows:
  winget install -e --id NASM.NASM

Then close and reopen PowerShell, and verify:
  nasm -v
"@
}

$args = @("build", "--target", $Target)
if ($Release) {
    $args += "--release"
}

Push-Location $coreDir
try {
    Write-Host "=> Building native-device-core for $Target..."
    cargo @args
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build failed with exit code $LASTEXITCODE."
    }

    $profile = if ($Release) { "release" } else { "debug" }
    $artifactDir = Join-Path $coreDir "target\$Target\$profile"
    $exe = Join-Path $artifactDir "geoteleport-device-core.exe"
    $dll = Join-Path $artifactDir "geoteleport_device_core.dll"

    if (!(Test-Path $exe)) {
        throw "Expected CLI artifact missing: $exe"
    }
    if (!(Test-Path $dll)) {
        throw "Expected DLL artifact missing: $dll"
    }

    Write-Host "=> Windows core artifacts ready:"
    Write-Host "   $exe"
    Write-Host "   $dll"
}
finally {
    Pop-Location
}
