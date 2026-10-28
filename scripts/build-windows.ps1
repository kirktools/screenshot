# Windows 原生构建/便携包；不安装、不提权、不发布。
[CmdletBinding()]
param(
    [ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64',
    [switch]$Development,
    [switch]$Launch
)
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$version = (Get-Content VERSION -Raw).Trim()
if ($version -notmatch '^\d+\.\d+\.\d+$') { throw 'VERSION 必须为 x.y.z' }
$flavor = if ($Development) { 'development' } else { 'release' }
$output = Join-Path '.build/windows' "$Runtime-$flavor"
# 只重启当前工作区的开发副本；不停止日常版或其他工作区的程序。
if ($Development -and $Launch) {
    $developmentExe = [IO.Path]::GetFullPath((Join-Path $output 'Screenshot.exe'))
    foreach ($process in @(Get-Process -Name Screenshot -ErrorAction SilentlyContinue)) {
        try {
            if ($process.Path -and [string]::Equals($process.Path, $developmentExe, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Host '正在重启当前工作区的开发版…'
                Stop-Process -Id $process.Id -ErrorAction Stop
                if (!$process.WaitForExit(5000)) { throw '当前开发版尚未退出，请关闭后重试' }
            }
        } finally { $process.Dispose() }
    }
}
# 输出路径仅由受限参数组成，不清理工作区其他目录。
if (Test-Path $output) { Remove-Item $output -Recurse -Force }
$publish = @('publish','platforms/windows/Screenshot.Windows/Screenshot.Windows.csproj','-c','Release','-r',$Runtime,'--self-contained','true','-o',$output,'-p:ContinuousIntegrationBuild=true','-p:DebugType=None','-p:DebugSymbols=false')
if ($Development) { $publish += '-p:DefineConstants=DEVELOPMENT' }
& dotnet @publish
if ($LASTEXITCODE -ne 0) { throw 'Windows 应用构建失败' }
Copy-Item LICENSE (Join-Path $output 'LICENSE.txt')
$sdkRoot = Split-Path (Get-Command dotnet).Source -Parent
$notices = Join-Path $sdkRoot 'ThirdPartyNotices.txt'
$runtimeLicense = Join-Path $sdkRoot 'LICENSE.txt'
if (!(Test-Path $notices) -or !(Test-Path $runtimeLicense)) { throw 'SDK 缺少第三方声明，拒绝生成不完整安装包' }
[IO.File]::WriteAllText((Join-Path (Resolve-Path $output) 'ThirdPartyNotices.txt'), ([IO.File]::ReadAllText($runtimeLicense) + "`n`n" + [IO.File]::ReadAllText($notices)))
$expected = @('LICENSE.txt','Screenshot.exe','ThirdPartyNotices.txt')
$actual = @(Get-ChildItem $output -File | Select-Object -ExpandProperty Name | Sort-Object)
if (Compare-Object $expected $actual) { throw '单文件便携包存在非预期文件，请检查发布配置' }
if ($Development) {
    if ($Launch) { Start-Process (Join-Path (Resolve-Path $output) 'Screenshot.exe') }
    Write-Host "开发版已生成：$output"
    exit 0
}
New-Item dist -ItemType Directory -Force | Out-Null
$arch = $Runtime.Replace('win-','')
$archive = "Screenshot-$version-Windows-$arch.zip"
Compress-Archive -Path (Join-Path $output '*') -DestinationPath (Join-Path dist $archive) -Force
Copy-Item (Join-Path dist $archive) (Join-Path dist "Screenshot-Windows-$arch.zip")
$lines = @($archive,"Screenshot-Windows-$arch.zip") | ForEach-Object { "$( (Get-FileHash (Join-Path dist $_) -Algorithm SHA256).Hash.ToLowerInvariant())  $_" }
[IO.File]::WriteAllLines((Join-Path (Resolve-Path dist) "SHA256SUMS-Windows-$arch.txt"),$lines,[Text.UTF8Encoding]::new($false))
Write-Host "已生成：dist/$archive（包含完整许可证与 .NET 第三方声明）"
