param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [switch]$Release
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreDir = Join-Path $repoRoot "native-device-core"

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "cargo is required. Install Rust stable before building the Windows core."
}

$args = @("build", "--target", $Target)
if ($Release) {
    $args += "--release"
}

Push-Location $coreDir
try {
    Write-Host "=> Building native-device-core for $Target..."
    cargo @args

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
