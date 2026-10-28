# 原生 Windows 编译共享 Swift 核心。输出仅为 DLL/许可证，不含另一套算法。
[CmdletBinding()]
param([ValidateSet('win-x64','win-arm64')][string]$Runtime = 'win-x64')
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)
$arch = $Runtime.Replace('win-','')
$hostArch = if ([Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'x64' }
if ($arch -ne $hostArch) { throw '共享核心当前使用对应架构的 Windows 原生构建；请使用双架构 CI 产物。' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$visualStudio = & $vswhere -latest -products '*' -property installationPath
if (!$visualStudio) { throw '需要 Visual Studio C++ 构建工具和 Windows SDK' }
$batch = Join-Path $visualStudio 'Common7/Tools/VsDevCmd.bat'
# 只导入编译环境，不输出完整环境变量或凭据。
$environment = & cmd.exe /d /s /c "call `"$batch`" -no_logo -arch=$arch -host_arch=$hostArch >nul && set"
if ($LASTEXITCODE -ne 0) { throw '无法准备 MSVC 编译环境' }
foreach ($line in $environment) {
    if ($line -match '^([^=]+)=(.*)$') { [Environment]::SetEnvironmentVariable($matches[1],$matches[2],'Process') }
}
$output = [IO.Path]::GetFullPath(".build/windows/shared-core/$Runtime")
New-Item $output -ItemType Directory -Force | Out-Null
& swiftc -O -emit-library -module-name StitchCoreABI -debug-prefix-map "$PWD=/_/screenshot" Sources/StitchCore/StitchMatcher.swift Sources/StitchCore/ContinuousStitchTracker.swift platforms/interop/StitchCoreABI.swift -o (Join-Path $output 'StitchCoreABI.dll')
if ($LASTEXITCODE -ne 0) { throw '共享 Swift 核心编译失败' }
# 递归收集实际导入的 Swift/CRT DLL；不把整个 SDK 或 Foundation 打进应用。
$swiftRoot = Join-Path $env:LOCALAPPDATA 'Programs/Swift'
$roots = @($swiftRoot, 'C:/Library/Developer', $env:VCToolsRedistDir) | Where-Object { $_ -and (Test-Path $_) }
function Machine([string]$path) {
    $stream = [IO.File]::OpenRead($path); $reader = [IO.BinaryReader]::new($stream)
    try { $stream.Position=0x3c; $offset=$reader.ReadInt32(); $stream.Position=$offset+4; return $reader.ReadUInt16() } finally { $reader.Dispose() }
}
$machine = if ($arch -eq 'arm64') { 0xaa64 } else { 0x8664 }
$queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue((Join-Path $output 'StitchCoreABI.dll'))
$seen = @{}
while ($queue.Count) {
    $file = $queue.Dequeue()
    foreach ($line in @(& dumpbin.exe /nologo /dependents $file)) {
        if ($line -notmatch '^\s+([A-Za-z0-9_.+-]+\.dll)\s*$') { continue }
        $name=$matches[1]
        if ($seen.ContainsKey($name)) { continue }; $seen[$name]=$true
        if ($name -match '^(api-ms-|ext-ms-)' -or ($name -notmatch '^(swift|BlocksRuntime|dispatch|vcruntime|msvcp|concrt)' -and (Test-Path (Join-Path $env:SystemRoot "System32/$name")))) { continue }
        $found = @($roots | ForEach-Object { Get-ChildItem $_ -Filter $name -Recurse -ErrorAction SilentlyContinue } | Where-Object { (Machine $_.FullName) -eq $machine }) | Select-Object -First 1
        if (!$found) { throw "未找到同架构依赖：$name" }
        Copy-Item $found.FullName (Join-Path $output $name) -Force
        $queue.Enqueue((Join-Path $output $name))
    }
}
# .lib/.exp 等编译产物不进入分发目录。
Get-ChildItem $output -File | Where-Object { $_.Extension -ne '.dll' } | Remove-Item
$dlls = @(Get-ChildItem $output -Filter '*.dll')
Write-Host ("共享核心依赖：" + (($dlls | Select-Object -ExpandProperty Name) -join ', '))
Write-Host ("共享核心与运行时字节：" + (($dlls | Measure-Object Length -Sum).Sum))
# 只诊断 SDK 许可证相对文件名，后续完整随包附带。
foreach ($root in $roots) {
    Get-ChildItem $root -File -Recurse -Include '*LICENSE*','*NOTICE*' -ErrorAction SilentlyContinue | Select-Object -First 20 | ForEach-Object { Write-Host ("SDK license: " + [IO.Path]::GetRelativePath($root,$_.FullName)) }
}
if ($env:GITHUB_ENV) { "SharedCoreDirectory=$output" | Out-File $env:GITHUB_ENV -Append -Encoding utf8 }
