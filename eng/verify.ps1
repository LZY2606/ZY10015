<#
.SYNOPSIS
  Windows thin entry point for NCalc verification. All stages and parameters
  live in the single POSIX core, eng/verify.core.sh.
.DESCRIPTION
  Runs the same pipeline as eng/verify.sh on Windows. Requires Git for Windows
  sh.exe (provided by the Git installer) and the SDK pinned by global.json.
  Set NVERIFY_AOT=true to run the Native AOT matrix leg.
#>
[CmdletBinding()]
param([switch]$Aot)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'verify.core.sh'

$sh = Get-Command sh.exe -ErrorAction SilentlyContinue
if (-not $sh) {
    Write-Error "sh.exe (Git for Windows) was not found on PATH. Install Git for Windows and retry."
    exit 127
}

$env:NVERIFY_AOT = if ($Aot) { 'true' } else { 'false' }
& $sh.Path $script
exit $LASTEXITCODE
