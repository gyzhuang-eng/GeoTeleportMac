param(
    [string]$Target = "x86_64-pc-windows-msvc",
    [switch]$Release,
    [switch]$QuietArtifacts
)

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$coreDir = Join-Path $repoRoot "native-device-core"

function Get-NasmCommand {
    $cmd = Get-Command nasm -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    $candidateDirs = @()
    if ($env:ProgramFiles) {
        $candidateDirs += (Join-Path $env:ProgramFiles "NASM")
    }

    $programFilesX86 = [Environment]::GetEnvironmentVariable("ProgramFiles(x86)")
    if ($programFilesX86) {
        $candidateDirs += (Join-Path $programFilesX86 "NASM")
    }
    if ($env:LOCALAPPDATA) {
        $candidateDirs += (Join-Path $env:LOCALAPPDATA "bin\NASM")
    }

    foreach ($dir in $candidateDirs) {
        $candidate = Join-Path $dir "nasm.exe"
        if (Test-Path $candidate) {
            $env:PATH = "$dir;$env:PATH"
            return $candidate
        }
    }

    return $null
}

if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw @"
需要 cargo，但当前 PATH 中找不到。

请在 Windows 上安装 Rust stable：
  winget install -e --id Rustlang.Rustup

然后关闭并重新打开 PowerShell，再验证：
  cargo --version
  rustup target add $Target

如果后续构建错误提到 link.exe 或 MSVC 工具，请安装 C++ Build Tools：
  winget install -e --id Microsoft.VisualStudio.2022.BuildTools --override "--passive --wait --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"
"@
}

if ($Target -like "*windows*") {
    $nasmCommand = Get-NasmCommand
    if (-not $nasmCommand) {
        throw @"
Windows 原生核心构建需要 nasm，但当前 PATH 中找不到。

请在 Windows 上安装 NASM：
  winget install -e --id NASM.NASM

然后关闭并重新打开 PowerShell，再验证：
  nasm -v
"@
    }

    Write-Host "=> 使用 NASM：$nasmCommand"
}

$args = @("build", "--target", $Target)
if ($Release) {
    $args += "--release"
}

Push-Location $coreDir
try {
    Write-Host "=> 正在构建 native-device-core，目标：$Target..."
    cargo @args
    if ($LASTEXITCODE -ne 0) {
        throw "cargo build 失败，退出码 $LASTEXITCODE。"
    }

    $profile = if ($Release) { "release" } else { "debug" }
    $artifactDir = Join-Path $coreDir "target\$Target\$profile"
    $exe = Join-Path $artifactDir "geoteleport-device-core.exe"
    $dll = Join-Path $artifactDir "geoteleport_device_core.dll"

    if (!(Test-Path $exe)) {
        throw "缺少预期的 CLI 产物：$exe"
    }
    if (!(Test-Path $dll)) {
        throw "缺少预期的 DLL 产物：$dll"
    }

    Write-Host "=> Windows 核心产物已就绪。"
    if (-not $QuietArtifacts) {
        Write-Host "   $exe"
        Write-Host "   $dll"
    }
}
finally {
    Pop-Location
}
