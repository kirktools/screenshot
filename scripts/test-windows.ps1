[CmdletBinding()]
param([ValidateSet('auto','win-x64','win-arm64')][string]$Runtime = 'auto')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
if ($Runtime -eq 'auto') { $Runtime = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'win-arm64' } else { 'win-x64' } }
& "$PSScriptRoot/build-stitch-core.ps1" -Runtime $Runtime
$core = [IO.Path]::GetFullPath(".build/windows/shared-core/$Runtime")
& dotnet run --project platforms/windows/Screenshot.Tests -c Release "-p:SharedCoreDirectory=$core"
if ($LASTEXITCODE -ne 0) { throw '共享核心与 Windows 适配回归失败' }
