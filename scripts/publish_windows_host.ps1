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
需要 dotnet，但当前 PATH 中找不到。

请在 Windows 上安装 .NET 8 SDK：
  winget install -e --id Microsoft.DotNet.SDK.8

然后关闭并重新打开 PowerShell，再验证：
  dotnet --info
"@
}

& (Join-Path $repoRoot "scripts\build_windows_core.ps1") -Target $target -Release -QuietArtifacts

Write-Host "=> 正在发布 GeoTeleport Windows版..."
if (Test-Path -LiteralPath $publishDir) {
    Write-Host "=> 正在清理已有发布目录："
    Write-Host "   $publishDir"
    Remove-Item -LiteralPath $publishDir -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null
dotnet publish $hostProject -c $Configuration -r $Runtime --self-contained true /p:PublishSingleFile=true -o $publishDir
if ($LASTEXITCODE -ne 0) {
    throw "dotnet publish 失败，退出码 $LASTEXITCODE。"
}

$coreDll = Join-Path $coreDir "target\$target\release\geoteleport_device_core.dll"
$coreExe = Join-Path $coreDir "target\$target\release\geoteleport-device-core.exe"

Copy-Item $coreDll $publishDir -Force
Copy-Item $coreExe $publishDir -Force

Write-Host "=> Windows 主程序包已就绪："
Write-Host "   $publishDir"
Write-Host "=> 启动："
Write-Host "   $publishDir\GeoTeleportWindows.exe"
