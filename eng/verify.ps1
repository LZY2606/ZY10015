# eng/verify.ps1 — Windows 薄入口。核心步骤与参数只在 eng/verify.sh 中维护，
# 本脚本仅定位 POSIX shell（Git for Windows 自带的 Git Bash 即可）并转发参数。
$ErrorActionPreference = 'Stop'

$shell = Get-Command sh.exe -ErrorAction SilentlyContinue
if (-not $shell) { $shell = Get-Command bash.exe -ErrorAction SilentlyContinue }
if (-not $shell) {
    Write-Error "未找到 sh/bash。请安装 Git for Windows（自带 Git Bash）后重试；核心验证逻辑在 eng/verify.sh。"
    exit 127
}

& $shell.Source (Join-Path $PSScriptRoot 'verify.sh') @args
exit $LASTEXITCODE
