# 仅在隔离 GitHub CI 安装固定的官方 Swift SDK，不修改安全策略。
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true') { throw '本机请按 Swift 官方 Windows 安装说明配置 Swift 6.3+，此入口仅用于 CI。' }
$arch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
$variant = if ($arch -eq 'arm64') { 'windows10-arm64' } else { 'windows10' }
# 官方下载；固定摘要对应 microsoft/winget-pkgs 的 Swift.Toolchain/6.4.1 清单。
$expected = if ($arch -eq 'arm64') { 'FAFF6A12CDAE099D76372CA971B0C83B13280AD704E1022FAA599DBE0B146E64' } else { '9382E14919EEAE5E7B5DBFE0575452FE2154178E089A595C8B44D03960D91D59' }
$installer = Join-Path $env:RUNNER_TEMP 'screenshot-swift-6.4.1.exe'
Invoke-WebRequest "https://download.swift.org/swift-6.4.1-release/$variant/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-$variant.exe" -OutFile $installer
if ((Get-FileHash $installer -Algorithm SHA256).Hash -ne $expected) { throw 'Swift SDK 摘要不符，拒绝执行' }
$process = Start-Process $installer -ArgumentList '/quiet','/norestart' -Wait -PassThru
if ($process.ExitCode -notin @(0,3010)) { throw "Swift SDK 安装失败：$($process.ExitCode)" }
$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs/Swift'
$roots = @($swiftRoot, 'C:/Library/Developer', 'C:/Program Files/Swift') | Where-Object { Test-Path $_ }
$compiler = @($roots | ForEach-Object { Get-ChildItem $_ -Filter swiftc.exe -Recurse -ErrorAction SilentlyContinue }) | Select-Object -First 1
if (!$compiler) { throw '未找到安装后的 swiftc' }
$env:Path = "$($compiler.DirectoryName);$([Environment]::GetEnvironmentVariable('Path','User'));$env:Path"
foreach ($key in @('SDKROOT','SWIFTFLAGS')) {
    $value = [Environment]::GetEnvironmentVariable($key,'User')
    if ($value) { [Environment]::SetEnvironmentVariable($key,$value,'Process'); "$key=$value" | Out-File $env:GITHUB_ENV -Append -Encoding utf8 }
}
$compiler.DirectoryName | Out-File $env:GITHUB_PATH -Append -Encoding utf8
foreach ($path in ([Environment]::GetEnvironmentVariable('Path','User') -split ';')) { if ($path) { $path | Out-File $env:GITHUB_PATH -Append -Encoding utf8 } }
& $compiler.FullName --version
if ($LASTEXITCODE -ne 0) { throw 'Swift 编译器无法运行' }
